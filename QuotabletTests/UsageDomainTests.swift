import Foundation
import XCTest

final class UsageDomainTests: XCTestCase {
    func testRepeatedLimitIDsStayDistinctAcrossAccountsAndWindows() {
        let first = report(accountID: "acct-a", quotas: [
            quota(id: "session", windowID: "5h"),
            quota(id: "session", windowID: "7d")
        ])
        let second = report(accountID: "acct-b", quotas: [
            quota(id: "session", windowID: "5h"),
            quota(id: "session", windowID: "7d")
        ])
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [first, second])
        let keys = snapshot.reports.flatMap(\.quotas).compactMap(\.pinKey)

        XCTAssertEqual(keys.count, 4)
        XCTAssertEqual(Set(keys).count, 4)
        XCTAssertNotEqual(snapshot.reports[0].accountIdentity, snapshot.reports[1].accountIdentity)
    }

    func testDuplicateAndMissingAccountIdentitiesRemainTransient() {
        let duplicateA = report(accountID: "acct-shared", organizationID: "org-1", label: "First alias")
        let duplicateB = report(accountID: "acct-shared", organizationID: "org-1", label: "Second alias")
        let missing = report(accountID: nil, label: "private@example.invalid")
        let blank = report(accountID: "   ")
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [duplicateA, duplicateB, missing, blank])

        for report in snapshot.reports {
            guard case .transient = report.accountIdentity else {
                XCTFail("Ambiguous and missing source IDs must not become persistent account identities.")
                return
            }
            XCTAssertNil(report.quotas.first?.pinKey)
        }
        XCTAssertEqual(Set(snapshot.reports.map(\.id)).count, 4)
    }

    func testDuplicateQuotaKeysCannotBePinned() {
        let scope = QuotaScope(
            provider: "anthropic",
            accountID: "acct-a",
            organizationID: "org-1",
            projectID: nil,
            modelID: nil,
            tier: "pro",
            windowID: "5h",
            shared: true
        )
        let duplicate = report(accountID: "acct-a", quotas: [
            quota(id: "shared-meter", windowID: "5h", scope: scope),
            quota(id: "shared-meter", windowID: "5h", scope: scope)
        ])
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [duplicate])
        let quotas = snapshot.reports[0].quotas

        XCTAssertTrue(quotas.allSatisfy { $0.pinKey == nil })
        XCTAssertEqual(Set(quotas.map(\.id)).count, 2)
    }

    func testPersistentPinIgnoresPresentationAndResetChangesButDistinguishesSourceIdentity() throws {
        let scope = QuotaScope(
            provider: "anthropic",
            accountID: "acct-a",
            organizationID: "org-1",
            projectID: "project-1",
            modelID: "claude-sonnet",
            tier: "pro",
            windowID: "5h",
            shared: true
        )
        let changedScope = QuotaScope(
            provider: "anthropic",
            accountID: "acct-a",
            organizationID: "org-1",
            projectID: "project-1",
            modelID: "claude-sonnet",
            tier: "team",
            windowID: "5h",
            shared: true
        )
        let original = report(
            accountID: "acct-a",
            organizationID: "org-1",
            projectID: "project-1",
            label: "First alias",
            quotas: [quota(
                id: "session",
                windowID: "5h",
                windowLabel: "Five Hour",
                durationMilliseconds: 18_000_000,
                scope: scope,
                resetsAt: timestamp
            )]
        )
        let returned = report(
            accountID: "acct-a",
            organizationID: "org-1",
            projectID: "project-1",
            label: "Changed alias",
            quotas: [quota(
                id: "session",
                windowID: "5h",
                windowLabel: "Claude rolling session",
                durationMilliseconds: 36_000_000,
                scope: scope,
                resetsAt: timestamp.addingTimeInterval(3_600)
            )]
        )
        let otherOrganization = report(
            accountID: "acct-a",
            organizationID: "org-2",
            projectID: "project-1",
            quotas: [quota(id: "session", windowID: "5h", scope: scope)]
        )
        let otherProject = report(
            accountID: "acct-a",
            organizationID: "org-1",
            projectID: "project-2",
            quotas: [quota(id: "session", windowID: "5h", scope: scope)]
        )
        let otherScope = report(
            accountID: "acct-a",
            organizationID: "org-1",
            projectID: "project-1",
            quotas: [quota(id: "session", windowID: "5h", scope: changedScope)]
        )
        let otherWindow = report(
            accountID: "acct-a",
            organizationID: "org-1",
            projectID: "project-1",
            quotas: [quota(id: "session", windowID: "7d", scope: scope)]
        )
        let originalKey = try XCTUnwrap(UsageSnapshot(generatedAt: timestamp, reportDrafts: [original]).reports.first?.quotas.first?.pinKey)
        let returnedKey = try XCTUnwrap(UsageSnapshot(generatedAt: timestamp, reportDrafts: [returned]).reports.first?.quotas.first?.pinKey)
        let otherOrganizationKey = try XCTUnwrap(UsageSnapshot(generatedAt: timestamp, reportDrafts: [otherOrganization]).reports.first?.quotas.first?.pinKey)
        let otherProjectKey = try XCTUnwrap(UsageSnapshot(generatedAt: timestamp, reportDrafts: [otherProject]).reports.first?.quotas.first?.pinKey)
        let otherScopeKey = try XCTUnwrap(UsageSnapshot(generatedAt: timestamp, reportDrafts: [otherScope]).reports.first?.quotas.first?.pinKey)
        let otherWindowKey = try XCTUnwrap(UsageSnapshot(generatedAt: timestamp, reportDrafts: [otherWindow]).reports.first?.quotas.first?.pinKey)

        XCTAssertEqual(originalKey, returnedKey)
        XCTAssertNotEqual(originalKey, otherOrganizationKey)
        XCTAssertNotEqual(originalKey, otherProjectKey)
        XCTAssertNotEqual(originalKey, otherScopeKey)
        XCTAssertNotEqual(originalKey, otherWindowKey)
    }

    func testMissingWindowCannotBePinnedAndMissingSavedPinNeverFallsBack() throws {
        let original = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "acct-a")
        ])
        let savedKey = try XCTUnwrap(original.reports.first?.quotas.first?.pinKey)
        let missingWindow = UsageSnapshot(
            generatedAt: timestamp,
            reportDrafts: [report(accountID: "acct-a", quotas: [quota(id: "quota-1", windowID: nil)])]
        )
        let different = UsageSnapshot(generatedAt: timestamp, reportDrafts: [report(accountID: "acct-b")])
        let returned = UsageSnapshot(
            generatedAt: timestamp.addingTimeInterval(60),
            reportDrafts: [report(
                accountID: "acct-a",
                label: "Changed alias",
                quotas: [quota(id: "quota-1", windowID: "5h", windowLabel: "Changed display label", resetsAt: timestamp.addingTimeInterval(60))]
            )]
        )

        XCTAssertNil(missingWindow.reports.first?.quotas.first?.pinKey)
        XCTAssertEqual(missingWindow.reports.first?.quotas.first?.windowDisplayName, "Window unknown")
        XCTAssertEqual(different.summarySelection(pinnedKey: savedKey), .unavailable)
        guard case .pinned(let selection) = returned.summarySelection(pinnedKey: savedKey) else {
            XCTFail("The exact stable key must reconnect when it returns.")
            return
        }
        XCTAssertEqual(selection.report.sourceAccount?.accountID, "acct-a")
        XCTAssertEqual(selection.quota.pinKey, savedKey)
    }

    func testUnknownCurrencyRemainsDistinctFromKnownZeroAndPercentage() {
        let unknownCurrency = UsageAmount(
            used: nil,
            limit: nil,
            remaining: nil,
            usedFraction: nil,
            remainingFraction: 0.62,
            unit: .usd
        )
        let zeroCurrency = UsageAmount(
            used: nil,
            limit: nil,
            remaining: 0,
            usedFraction: nil,
            remainingFraction: nil,
            unit: .usd
        )
        let percentage = UsageAmount(
            used: nil,
            limit: nil,
            remaining: nil,
            usedFraction: nil,
            remainingFraction: 0.62,
            unit: .percent
        )

        XCTAssertNil(unknownCurrency.displayedRemaining)
        XCTAssertFalse(unknownCurrency.isKnownExhausted)
        XCTAssertEqual(zeroCurrency.displayedRemaining, 0)
        XCTAssertTrue(zeroCurrency.isKnownExhausted)
        XCTAssertEqual(percentage.displayedRemaining, 62)
    }

    func testProviderAgeCrossesStaleBoundaryWithoutRefreshing() {
        let freshness = UsageFreshness(
            origin: .live,
            fetchedAt: timestamp,
            refreshStatus: .idle
        )

        XCTAssertFalse(freshness.isStale(at: timestamp.addingTimeInterval(899)))
        XCTAssertTrue(freshness.isStale(at: timestamp.addingTimeInterval(900)))
    }

    private var timestamp: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    private func report(
        accountID: String?,
        organizationID: String? = nil,
        projectID: String? = nil,
        label: String? = nil,
        quotas: [UsageQuotaDraft]? = nil
    ) -> UsageReportDraft {
        UsageReportDraft(
            provider: "anthropic",
            sourceAccount: SourceAccountIdentity(accountID: accountID, organizationID: organizationID, projectID: projectID),
            privateDisplayLabel: label,
            fetchedAt: timestamp,
            resetCredits: nil,
            quotas: quotas ?? [quota(id: "quota-1")]
        )
    }

    private func quota(
        id: String,
        windowID: String? = "5h",
        windowLabel: String? = nil,
        durationMilliseconds: Double? = 18_000_000,
        scope: QuotaScope? = nil,
        resetsAt: Date? = nil
    ) -> UsageQuotaDraft {
        let window = windowID.map {
            QuotaWindow(
                identity: QuotaWindowIdentity(id: $0),
                label: windowLabel ?? $0,
                durationMilliseconds: durationMilliseconds,
                resetLabel: nil
            )
        }
        return UsageQuotaDraft(
            id: id,
            label: "Synthetic window",
            scope: scope,
            window: window,
            amount: UsageAmount(used: 20, limit: 100, remaining: 80, usedFraction: 0.2, remainingFraction: 0.8, unit: .percent),
            status: .available,
            resetsAt: resetsAt
        )
    }
}
