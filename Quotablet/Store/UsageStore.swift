import Foundation
import Observation

enum UsagePolicy {
    static let refreshIntervalSeconds: Int64 = 300
}

@MainActor
@Observable
final class UsageStore {
    private enum RefreshOutcome: Sendable {
        case success(UsageSnapshot)
        case failure(OMPClientError)
    }

    private enum RefreshState {
        case idle
        case running(id: UUID, task: Task<RefreshOutcome, Never>)
        case reconfiguring(id: UUID, task: Task<RefreshOutcome, Never>?, requestedPath: String?)
        case stopped
    }


    private(set) var snapshot: UsageSnapshot?
    private(set) var snapshotOrigin: UsageSnapshotOrigin?
    private(set) var lastError: OMPClientError?
    private(set) var persistenceWarning = false
    private(set) var executablePath: String?
    private(set) var hiddenMenuBarProviders: Set<String> = []
    private(set) var logos = ProviderLogoCatalog.empty
    private(set) var revealsIdentifiers = true
    private(set) var presentationDate = Date()

    @ObservationIgnored private let persistence: AppPersistence
    @ObservationIgnored private let fetcher: @Sendable (CLIConfiguration) async throws -> UsageSnapshot
    private var refreshState = RefreshState.idle
    @ObservationIgnored private let schedulerInterval: Duration
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var presentationTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var logoLibrary: ProviderLogoLibrary
    @ObservationIgnored private let presentationInterval: Duration

    init(
        persistence: AppPersistence = AppPersistence(),
        schedulerInterval: Duration = .seconds(UsagePolicy.refreshIntervalSeconds),
        presentationInterval: Duration = .seconds(30),
        fetcher: (@Sendable (CLIConfiguration) async throws -> UsageSnapshot)? = nil
    ) {
        self.persistence = persistence
        self.schedulerInterval = schedulerInterval
        self.presentationInterval = presentationInterval
        logoLibrary = ProviderLogoLibrary(directoryURL: persistence.logosDirectoryURL)
        self.fetcher = fetcher ?? { configuration in
            try await OMPClient().fetch(configuration: configuration)
        }
    }

    var isRefreshing: Bool {
        switch refreshState {
        case .running(_, _), .reconfiguring(_, _, _): true
        case .idle, .stopped: false
        }
    }

    // The providers the menu bar shows: those of the snapshot that the user has not hidden, in the registry's order.
    func menuBarProviders(now: Date) -> [ProviderUsage] {
        shownInMenuBar(snapshot?.providerUsage(now: now) ?? [])
    }

    func menuBarAccessibilityLabel(now: Date) -> String {
        let age = freshness(fetchedAt: snapshot?.oldestReportFetchedAt).displayLabel(now: now)
        let providers = snapshot?.providerUsage(now: now) ?? []
        let shown = shownInMenuBar(providers)
        guard !shown.isEmpty else {
            // Every provider hidden leaves the plain symbol, the same as no provider, so the speech tells the two apart.
            let reason = providers.isEmpty ? "No quota is available for the menu bar." : "Every provider is hidden from the menu bar."
            return "Quotablet. \(reason) \(age)"
        }
        return "\(shown.spokenSummary). \(age)"
    }

    private func shownInMenuBar(_ providers: [ProviderUsage]) -> [ProviderUsage] {
        providers.filter { !hiddenMenuBarProviders.contains($0.provider) }
    }

    // The header names the age of the oldest report, or of the snapshot itself when it holds no report.
    var collectionStatus: CollectionStatus {
        guard let snapshot, let snapshotOrigin else { return .noSnapshot(refreshStatus) }
        return .snapshot(snapshotOrigin, dataDate: snapshot.oldestReportFetchedAt ?? snapshot.generatedAt, refresh: refreshStatus)
    }

    private var refreshStatus: UsageRefreshStatus {
        if isRefreshing { return .refreshing }
        return lastError != nil ? .failed : .idle
    }

    private func freshness(fetchedAt: Date?) -> UsageFreshness {
        UsageFreshness(origin: snapshotOrigin, fetchedAt: fetchedAt, refreshStatus: refreshStatus)
    }

    func start() async {
        guard !didStart, !isShuttingDown else { return }
        didStart = true
        let stored = await persistence.load()
        guard !isShuttingDown else { return }

        executablePath = Self.normalizedPath(stored.settings.executablePath)
        hiddenMenuBarProviders = stored.settings.hiddenMenuBarProviders
        reloadLogosIfChanged()
        snapshot = stored.snapshot
        snapshotOrigin = stored.snapshot == nil ? nil : .cached
        let interval = presentationInterval
        presentationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, !self.isShuttingDown else { return }
                self.presentationDate = Date()
                self.reloadLogosIfChanged()
            }
        }

        await refresh()
        guard !isShuttingDown else { return }
        schedulerTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, !self.isShuttingDown {
                do {
                    try await Task.sleep(for: schedulerInterval)
                } catch {
                    return
                }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard !isShuttingDown else { return }
        switch refreshState {
        case .running(let id, let task):
            let outcome = await task.value
            await accept(outcome, for: id)
        case .idle:
            let id = UUID()
            let configuration = CLIConfiguration(executablePath: executablePath)
            let fetcher = self.fetcher
            let task = Task.detached(priority: .utility) { () -> RefreshOutcome in
                do {
                    return .success(try await fetcher(configuration))
                } catch let error as OMPClientError {
                    return .failure(error)
                } catch {
                    return .failure(.invalidResponse)
                }
            }
            refreshState = .running(id: id, task: task)
            let outcome = await task.value
            await accept(outcome, for: id)
        case .reconfiguring, .stopped:
            return
        }
    }

    func setRevealsIdentifiers(_ reveals: Bool) {
        revealsIdentifiers = reveals
    }

    // Takes a provider out of the menu bar or puts it back. Only the menu bar changes: the panel keeps the provider, and OMP's accounts stay as they are.
    func setShowsInMenuBar(_ shows: Bool, provider: String) async {
        guard !isShuttingDown else { return }
        let hidden = shows ? hiddenMenuBarProviders.subtracting([provider]) : hiddenMenuBarProviders.union([provider])
        guard hidden != hiddenMenuBarProviders else { return }
        hiddenMenuBarProviders = hidden
        await persistSettings()
    }

    func setCLIPath(_ path: String?) async {
        guard !isShuttingDown else { return }
        let normalized = Self.normalizedPath(path)

        let changeID: UUID
        let activeTask: Task<RefreshOutcome, Never>?
        switch refreshState {
        case .running(_, let task):
            guard normalized != executablePath else { return }
            changeID = UUID()
            activeTask = task
            refreshState = .reconfiguring(id: changeID, task: task, requestedPath: normalized)
        case .idle:
            guard normalized != executablePath else { return }
            changeID = UUID()
            activeTask = nil
            refreshState = .reconfiguring(id: changeID, task: nil, requestedPath: normalized)
        case .reconfiguring(let currentID, let task, _):
            refreshState = .reconfiguring(id: currentID, task: task, requestedPath: normalized)
            return
        case .stopped:
            return
        }

        activeTask?.cancel()
        if let activeTask { _ = await activeTask.value }
        guard !isShuttingDown else { return }

        while case .reconfiguring(let currentID, _, let requestedPath) = refreshState, currentID == changeID {
            executablePath = requestedPath
            await persistSettings()
            guard !isShuttingDown,
                  case .reconfiguring(let latestID, _, let latestPath) = refreshState,
                  latestID == changeID
            else { return }
            guard latestPath == requestedPath else { continue }
            refreshState = .idle
            await refresh()
            return
        }
    }

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard !isShuttingDown else { return }
        isShuttingDown = true
        let scheduledTask = schedulerTask
        scheduledTask?.cancel()
        schedulerTask = nil
        let clockTask = presentationTask
        clockTask?.cancel()
        presentationTask = nil

        let activeTask: Task<RefreshOutcome, Never>?
        switch refreshState {
        case .running(_, let task):
            activeTask = task
        case .reconfiguring(_, let task, _):
            activeTask = task
        case .idle, .stopped:
            activeTask = nil
        }
        refreshState = .stopped
        activeTask?.cancel()

        let task = Task { @MainActor [persistence] in
            if let clockTask { await clockTask.value }
            if let scheduledTask { await scheduledTask.value }
            if let activeTask { _ = await activeTask.value }
            await persistence.flush()
        }
        shutdownTask = task
        await task.value
    }

    private func accept(_ outcome: RefreshOutcome, for id: UUID) async {
        guard case .running(let activeID, _) = refreshState, activeID == id else { return }
        refreshState = .idle
        presentationDate = Date()
        switch outcome {
        case .success(let snapshot):
            self.snapshot = snapshot
            snapshotOrigin = .live
            lastError = nil
            if !(await persistence.save(snapshot: snapshot)) {
                persistenceWarning = true
            }
        case .failure(let error):
            guard error != .cancelled else { return }
            lastError = error
        }
    }

    private func persistSettings() async {
        let settings = PersistedSettings(executablePath: executablePath, hiddenMenuBarProviders: hiddenMenuBarProviders)
        if !(await persistence.save(settings: settings)) {
            persistenceWarning = true
        }
    }

    private func reloadLogosIfChanged() {
        if logoLibrary.reloadIfChanged() {
            logos = logoLibrary.catalog
        }
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
