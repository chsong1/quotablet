import Foundation
import XCTest

@MainActor
final class UsageStoreTests: XCTestCase {
    func testFailureRetainsCachedSnapshotAndEmptySuccessReplacesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = AppPersistence(directoryURL: directory)
        let cached = sampleSnapshot(accountID: "acct-cached")
        let pin = try XCTUnwrap(cached.reports.first?.quotas.first?.pinKey)
        let savedSnapshot = await persistence.save(snapshot: cached)
        let savedSettings = await persistence.save(settings: PersistedSettings(executablePath: nil, pinnedQuota: pin))
        XCTAssertTrue(savedSnapshot)
        XCTAssertTrue(savedSettings)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let snapshotMode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("usage-snapshot.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
        XCTAssertEqual(snapshotMode?.intValue, 0o600)

        let empty = UsageSnapshot(generatedAt: Date(timeIntervalSince1970: 1_800_000_100), reportDrafts: [])
        let fetcher = SequencedFetcher([.failure(.timedOut), .success(empty)])
        let store = UsageStore(persistence: persistence) { configuration in
            try await fetcher.fetch(configuration)
        }

        await store.start()
        XCTAssertEqual(store.snapshot, cached)
        XCTAssertEqual(store.snapshotOrigin, .cached)
        XCTAssertEqual(store.lastError, .timedOut)
        XCTAssertEqual(store.pinnedQuota, pin)

        await store.refresh()
        XCTAssertEqual(store.snapshot, empty)
        XCTAssertEqual(store.snapshotOrigin, .live)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.pinnedQuota, pin)
        XCTAssertEqual(store.summarySelection, .unavailable)

        await store.shutdown()
    }

    func testConcurrentRefreshRequestsShareOneFetchAndPublishItsResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = AppPersistence(directoryURL: directory)
        let expected = sampleSnapshot(accountID: "acct-single-flight")
        let fetcher = GatedFetcher(result: expected)
        let store = UsageStore(persistence: persistence) { configuration in
            try await fetcher.fetch(configuration)
        }

        let first = Task { await store.refresh() }
        await fetcher.waitForFirstCall()
        let second = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(50))
        let callsWhileFirstRequestIsBlocked = await fetcher.callCount()
        XCTAssertEqual(callsWhileFirstRequestIsBlocked, 1)

        await fetcher.releaseFirstCall()
        await first.value
        await second.value
        let completedCallCount = await fetcher.callCount()
        XCTAssertEqual(completedCallCount, 1)
        XCTAssertEqual(store.snapshot, expected)

        await store.shutdown()
    }

    func testNewestCLIChoiceWinsAcrossCancelledRefreshReconfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = AppPersistence(directoryURL: directory)
        let expected = sampleSnapshot(accountID: "acct-newest")
        let fetcher = ControlledCLIChangeFetcher(result: expected)
        let store = UsageStore(persistence: persistence) { configuration in
            try await fetcher.fetch(configuration)
        }

        let initialRefresh = Task { await store.refresh() }
        await fetcher.waitForFirstCall()
        let firstChoice = Task { await store.setCLIPath("/first-choice") }
        await fetcher.waitForFirstCancellation()
        let newestChoice = Task { await store.setCLIPath("/newest-choice") }
        await newestChoice.value

        await fetcher.cancelFirstCall()
        await firstChoice.value
        await initialRefresh.value

        let usedPaths = await fetcher.paths()
        let callCount = await fetcher.callCount()
        let stored = await persistence.load()
        XCTAssertEqual(store.executablePath, "/newest-choice")
        XCTAssertEqual(stored.settings.executablePath, "/newest-choice")
        XCTAssertEqual(usedPaths, [nil, "/newest-choice"])
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(store.snapshot, expected)

        await store.shutdown()
    }

    func testShutdownPreventsPendingCLIReconfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = AppPersistence(directoryURL: directory)
        let fetcher = ControlledCLIChangeFetcher(result: sampleSnapshot(accountID: "acct-shutdown"))
        let store = UsageStore(persistence: persistence) { configuration in
            try await fetcher.fetch(configuration)
        }

        let initialRefresh = Task { await store.refresh() }
        await fetcher.waitForFirstCall()
        let shutdown = Task { await store.shutdown() }
        await fetcher.waitForFirstCancellation()
        await store.setCLIPath("/must-not-reconfigure")
        await fetcher.cancelFirstCall()
        await shutdown.value
        await initialRefresh.value

        let callCount = await fetcher.callCount()
        let stored = await persistence.load()
        XCTAssertNil(store.executablePath)
        XCTAssertNil(stored.settings.executablePath)
        XCTAssertEqual(callCount, 1)
        XCTAssertFalse(store.isRefreshing)
    }

    func testShutdownCancelsScheduledRefreshInProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = AppPersistence(directoryURL: directory)
        let fetcher = ScheduledRefreshCancellationFetcher(result: sampleSnapshot(accountID: "acct-scheduler"))
        let store = UsageStore(persistence: persistence, schedulerInterval: .milliseconds(10)) { configuration in
            try await fetcher.fetch(configuration)
        }

        await store.start()
        await fetcher.waitForSecondCall()
        await store.shutdown()

        let callCount = await fetcher.callCount()
        let cancellationCount = await fetcher.cancellationCount()
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(store.isRefreshing)
    }

    private func sampleSnapshot(accountID: String) -> UsageSnapshot {
        let amount = UsageAmount(used: 20, limit: 100, remaining: 80, usedFraction: 0.2, remainingFraction: 0.8, unit: .percent)
        let scope = QuotaScope(
            provider: "anthropic",
            accountID: accountID,
            organizationID: nil,
            projectID: nil,
            modelID: nil,
            tier: nil,
            windowID: "5h",
            shared: false
        )
        let quota = UsageQuotaDraft(
            id: "session-limit",
            label: "Session",
            scope: scope,
            window: QuotaWindow(
                identity: QuotaWindowIdentity(id: "5h"),
                label: "5 Hour",
                durationMilliseconds: 18_000_000,
                resetLabel: nil
            ),
            amount: amount,
            status: .available,
            resetsAt: nil
        )
        let report = UsageReportDraft(
            provider: "anthropic",
            sourceAccount: SourceAccountIdentity(accountID: accountID, organizationID: nil, projectID: nil),
            privateDisplayLabel: "synthetic@example.invalid",
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            resetCredits: 0,
            quotas: [quota]
        )
        return UsageSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_001),
            reportDrafts: [report]
        )
    }
}

private actor SequencedFetcher {
    private var outcomes: [Result<UsageSnapshot, OMPClientError>]

    init(_ outcomes: [Result<UsageSnapshot, OMPClientError>]) {
        self.outcomes = outcomes
    }

    func fetch(_ configuration: CLIConfiguration) async throws -> UsageSnapshot {
        guard !outcomes.isEmpty else { throw OMPClientError.invalidResponse }
        return try outcomes.removeFirst().get()
    }
}

private actor GatedFetcher {
    private let result: UsageSnapshot
    private var calls = 0
    private var firstCall: CheckedContinuation<UsageSnapshot, any Error>?
    private var firstCallWaiter: CheckedContinuation<Void, Never>?

    init(result: UsageSnapshot) {
        self.result = result
    }

    func fetch(_ configuration: CLIConfiguration) async throws -> UsageSnapshot {
        calls += 1
        if calls == 1 {
            firstCallWaiter?.resume()
            firstCallWaiter = nil
            return try await withCheckedThrowingContinuation { continuation in
                firstCall = continuation
            }
        }
        return result
    }

    func waitForFirstCall() async {
        if calls > 0 { return }
        await withCheckedContinuation { continuation in
            firstCallWaiter = continuation
        }
    }

    func releaseFirstCall() {
        firstCall?.resume(returning: result)
        firstCall = nil
    }

    func callCount() -> Int { calls }
}

private actor ControlledCLIChangeFetcher {
    private let result: UsageSnapshot
    private var calls = 0
    private var firstCall: CheckedContinuation<UsageSnapshot, any Error>?
    private var firstCallWaiter: CheckedContinuation<Void, Never>?
    private var firstCancellationWaiter: CheckedContinuation<Void, Never>?
    private var firstCancellationObserved = false
    private var observedPaths: [String?] = []

    init(result: UsageSnapshot) {
        self.result = result
    }

    func fetch(_ configuration: CLIConfiguration) async throws -> UsageSnapshot {
        calls += 1
        observedPaths.append(configuration.executablePath)
        if calls == 1 {
            firstCallWaiter?.resume()
            firstCallWaiter = nil
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    firstCall = continuation
                }
            } onCancel: {
                Task { await self.recordFirstCancellation() }
            }
        }
        return result
    }

    func waitForFirstCall() async {
        if calls > 0 { return }
        await withCheckedContinuation { continuation in
            firstCallWaiter = continuation
        }
    }

    func waitForFirstCancellation() async {
        if firstCancellationObserved { return }
        await withCheckedContinuation { continuation in
            firstCancellationWaiter = continuation
        }
    }

    func cancelFirstCall() {
        firstCall?.resume(throwing: OMPClientError.cancelled)
        firstCall = nil
    }

    func paths() -> [String?] { observedPaths }

    func callCount() -> Int { calls }

    private func recordFirstCancellation() {
        firstCancellationObserved = true
        firstCancellationWaiter?.resume()
        firstCancellationWaiter = nil
    }
}

private actor ScheduledRefreshCancellationFetcher {
    private let result: UsageSnapshot
    private var calls = 0
    private var cancellations = 0
    private var secondCallWaiter: CheckedContinuation<Void, Never>?

    init(result: UsageSnapshot) {
        self.result = result
    }

    func fetch(_ configuration: CLIConfiguration) async throws -> UsageSnapshot {
        calls += 1
        guard calls > 1 else { return result }
        secondCallWaiter?.resume()
        secondCallWaiter = nil
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            cancellations += 1
            throw OMPClientError.cancelled
        }
        return result
    }

    func waitForSecondCall() async {
        if calls > 1 { return }
        await withCheckedContinuation { continuation in
            secondCallWaiter = continuation
        }
    }

    func callCount() -> Int { calls }

    func cancellationCount() -> Int { cancellations }
}
