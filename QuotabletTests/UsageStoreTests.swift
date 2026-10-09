import Foundation
import XCTest

@MainActor
final class UsageStoreTests: XCTestCase {
    func testFailureRetainsCachedSnapshotAndEmptySuccessReplacesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = AppPersistence(directoryURL: directory)
        let cached = sampleSnapshot(accountID: "acct-cached")
        let savedSnapshot = await persistence.save(snapshot: cached)
        let savedSettings = await persistence.save(settings: PersistedSettings(executablePath: nil))
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

        await store.refresh()
        XCTAssertEqual(store.snapshot, empty)
        XCTAssertEqual(store.snapshotOrigin, .live)
        XCTAssertNil(store.lastError)

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

    func testASettingsFileWithPinnedQuotasStillDecodesAndASaveNoLongerWritesThemBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = AppPersistence(directoryURL: directory)
        let settingsURL = directory.appendingPathComponent("settings.json")
        let pinned = #"{"executablePath":"/custom/omp","pinnedQuotas":[{"account":{"provider":"anthropic","accountID":"acct-a"},"limitID":"session","window":{"id":"5h"}}]}"#
        try Data(pinned.utf8).write(to: settingsURL)

        let loaded = await persistence.load()
        let saved = await persistence.save(settings: loaded.settings)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: String]

        XCTAssertEqual(loaded.settings, PersistedSettings(executablePath: "/custom/omp"))
        XCTAssertTrue(saved)
        XCTAssertEqual(written, ["executablePath": "/custom/omp"])

        try Data(#"{"executablePath":"/custom/omp","pinnedQuota":"legacy"}"#.utf8).write(to: settingsURL)
        let legacy = await persistence.load()
        XCTAssertEqual(legacy.settings.executablePath, "/custom/omp")

        try Data("{}".utf8).write(to: settingsURL)
        let empty = await persistence.load()
        XCTAssertNil(empty.settings.executablePath)
    }

    func testASavedSnapshotThatStillCarriesPinKeysStillLoads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = sampleSnapshot(accountID: "acct-a")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var reports = try XCTUnwrap(object["reports"] as? [[String: Any]])
        var quotas = try XCTUnwrap(reports[0]["quotas"] as? [[String: Any]])
        quotas[0]["pinKey"] = ["account": ["provider": "anthropic", "accountID": "acct-a"], "limitID": "session-limit", "window": ["id": "5h"]]
        reports[0]["quotas"] = quotas
        object["reports"] = reports
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("usage-snapshot.json"))

        let loaded = await AppPersistence(directoryURL: directory).load()

        XCTAssertEqual(loaded.snapshot?.revision, snapshot.revision)
        XCTAssertEqual(loaded.snapshot?.reports.first?.quotas.first?.label, "Session")
    }

    func testAccessibilityLabelNamesEachProviderWithItsCombinedUsageThenHowOldTheDataIs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await refreshedStore(RealisticFixture.snapshot(), directory: directory)
        let sentences = "Claude 79% used across 5 accounts; Codex 94% used across 3 accounts; Grok 1% used, 1 account; Cursor 100% used, 1 account"

        XCTAssertEqual(store.menuBarAccessibilityLabel(now: fetchedAt), "\(sentences). Provider data under 1m old")
        XCTAssertEqual(store.menuBarAccessibilityLabel(now: fetchedAt.addingTimeInterval(900)), "\(sentences). Stale · Provider data 15m old")

        await store.shutdown()
    }

    func testAccessibilityLabelSaysHowManyAccountsTheFigureCoversWhenSomeAreUnmeasured() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await refreshedStore(RealisticFixture.snapshot(unmeasuredClaudeAccounts: 1), directory: directory)

        XCTAssertEqual(
            store.menuBarAccessibilityLabel(now: fetchedAt),
            "Claude 74% used across 4 of 5 accounts; Codex 94% used across 3 accounts; Grok 1% used, 1 account; Cursor 100% used, 1 account. "
                + "Provider data under 1m old"
        )

        await store.shutdown()
    }

    func testAccessibilityLabelIsPlainBeforeAnySnapshotAndAfterAnEmptyOne() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fetcher = SequencedFetcher([.success(UsageSnapshot(generatedAt: fetchedAt, reportDrafts: []))])
        let store = UsageStore(persistence: AppPersistence(directoryURL: directory)) { configuration in
            try await fetcher.fetch(configuration)
        }

        XCTAssertEqual(store.menuBarAccessibilityLabel(now: fetchedAt), "Quotablet. No quota is available for the menu bar. Waiting for OMP")
        await store.refresh()
        XCTAssertEqual(store.menuBarAccessibilityLabel(now: fetchedAt), "Quotablet. No quota is available for the menu bar. Provider age unknown")

        await store.shutdown()
    }

    private func sampleSnapshot(accountID: String) -> UsageSnapshot {
        sampleSnapshot(accountIDs: [accountID])
    }

    private func sampleSnapshot(accountIDs: [String]) -> UsageSnapshot {
        UsageSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_001),
            reportDrafts: accountIDs.map { sampleReport(accountID: $0) }
        )
    }

    private func sampleReport(accountID: String) -> UsageReportDraft {
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
        return UsageReportDraft(
            provider: "anthropic",
            sourceAccount: SourceAccountIdentity(accountID: accountID, organizationID: nil, projectID: nil),
            privateDisplayLabel: "synthetic@example.invalid",
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            resetCredits: 0,
            quotas: [quota]
        )
    }

    private var fetchedAt: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    private func refreshedStore(_ snapshot: UsageSnapshot, directory: URL) async -> UsageStore {
        let fetcher = SequencedFetcher([.success(snapshot)])
        let store = UsageStore(persistence: AppPersistence(directoryURL: directory)) { configuration in
            try await fetcher.fetch(configuration)
        }
        await store.refresh()
        return store
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
