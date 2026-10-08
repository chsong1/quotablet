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
    private(set) var pinnedQuotas = MenuBarPins()
    private(set) var revealsIdentifiers = false
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

    init(
        persistence: AppPersistence = AppPersistence(),
        schedulerInterval: Duration = .seconds(UsagePolicy.refreshIntervalSeconds),
        fetcher: (@Sendable (CLIConfiguration) async throws -> UsageSnapshot)? = nil
    ) {
        self.persistence = persistence
        self.schedulerInterval = schedulerInterval
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

    var menuBarSlots: [MenuBarSlot] {
        guard let snapshot else { return pinnedQuotas.keys.map(MenuBarSlot.missing) }
        return snapshot.menuBarSlots(pins: pinnedQuotas)
    }

    func menuBarBadges(now: Date) -> [MenuBarBadge] {
        MenuBarBadge.badges(for: menuBarSlots, now: now)
    }

    func menuBarAccessibilityLabel(now: Date) -> String {
        let slots = menuBarSlots
        let collectionFreshness = freshness(of: slots).displayLabel(now: now)
        guard !slots.isEmpty else {
            return "Quotablet. No quota is available for the menu bar. \(collectionFreshness)"
        }
        let descriptions = slots.map(Self.accessibilityDescription(of:))
        return "\(descriptions.joined(separator: "; ")). \(collectionFreshness)"
    }

    static func accessibilityDescription(of slot: MenuBarSlot) -> String {
        switch slot {
        case .pinned(let selection):
            return slotDescription(of: selection)
        case .defaulted(let selection):
            return "Selected by default, \(slotDescription(of: selection))"
        case .missing:
            return "Pinned quota unavailable"
        }
    }

    func freshness(for report: UsageReport?) -> UsageFreshness {
        freshness(fetchedAt: report?.fetchedAt)
    }

    // The slots share one freshness: the oldest report among them sets it.
    func freshness(of slots: [MenuBarSlot]) -> UsageFreshness {
        freshness(fetchedAt: slots.compactMap { $0.selected?.report.fetchedAt }.min())
    }

    private func freshness(fetchedAt: Date?) -> UsageFreshness {
        let refreshStatus: UsageRefreshStatus
        if isRefreshing {
            refreshStatus = .refreshing
        } else if lastError != nil {
            refreshStatus = .failed
        } else {
            refreshStatus = .idle
        }
        return UsageFreshness(
            origin: snapshotOrigin,
            fetchedAt: fetchedAt,
            refreshStatus: refreshStatus
        )
    }

    func start() async {
        guard !didStart, !isShuttingDown else { return }
        didStart = true
        let stored = await persistence.load()
        guard !isShuttingDown else { return }

        executablePath = Self.normalizedPath(stored.settings.executablePath)
        pinnedQuotas = stored.settings.pinnedQuotas
        snapshot = stored.snapshot
        snapshotOrigin = stored.snapshot == nil ? nil : .cached
        presentationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                guard let self, !self.isShuttingDown else { return }
                self.presentationDate = Date()
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

    func togglePin(_ key: QuotaPinKey) async {
        guard !isShuttingDown else { return }
        pinnedQuotas = pinnedQuotas.toggling(key)
        await persistSettings()
    }

    func removePin(_ key: QuotaPinKey) async {
        guard !isShuttingDown else { return }
        pinnedQuotas = pinnedQuotas.removing(key)
        await persistSettings()
    }

    func setRevealsIdentifiers(_ reveals: Bool) {
        revealsIdentifiers = reveals
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
        let settings = PersistedSettings(executablePath: executablePath, pinnedQuotas: pinnedQuotas)
        if !(await persistence.save(settings: settings)) {
            persistenceWarning = true
        }
    }

    private static func slotDescription(of selection: SelectedQuota) -> String {
        let provider = ProviderRegistry.displayName(for: selection.report.provider)
        let account = UsageFormatting.accountAlias(selection.accountNumber)
        let remaining = UsageFormatting.remainingText(selection.quota.amount)
        return "\(provider) \(account), \(selection.quota.label), \(remaining)"
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
