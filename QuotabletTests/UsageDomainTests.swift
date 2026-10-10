import AppKit
import Foundation
import XCTest

final class UsageDomainTests: XCTestCase {
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
        }
        XCTAssertEqual(Set(snapshot.reports.map(\.id)).count, 4)
    }

    func testAQuotaWithoutAWindowNamesItsWindowUnknown() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "acct-a", quotas: [quota(id: "quota-1", windowID: nil)])
        ])

        XCTAssertEqual(snapshot.reports.first?.quotas.first?.windowDisplayName, "Window unknown")
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

    func testUrgencyFollowsOMPStatusAndAKnownEmptyQuota() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "acct-a", quotas: [
                quota(id: "exhausted-status", status: .exhausted, remainingPercent: 40),
                quota(id: "zero-remaining", status: .available, remainingPercent: 0),
                quota(id: "near-limit", status: .nearLimit, remainingPercent: 12),
                quota(id: "near-limit-and-empty", status: .nearLimit, remainingPercent: 0),
                quota(id: "available-and-low", status: .available, remainingPercent: 3),
                quota(id: "unknown-status", status: .unknown("critical"), remainingPercent: 3),
                quota(id: "missing-status", status: .missing, remainingPercent: nil)
            ])
        ])

        XCTAssertEqual(
            snapshot.reports[0].quotas.map(\.urgency),
            [.exhausted, .exhausted, .nearLimit, .exhausted, nil, nil, nil]
        )
    }

    func testAttentionItemsRankExhaustedFirstBySoonestResetThenNearLimitByLeastRemaining() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            account("acct-a", label: "exhausted, resets in 10h", status: .exhausted, remainingPercent: 0, resetsInHours: 10),
            account("acct-b", label: "near limit 30%, resets in 3h", status: .nearLimit, remainingPercent: 30, resetsInHours: 3),
            account("acct-c", label: "available 2%", status: .available, remainingPercent: 2, resetsInHours: 1),
            account("acct-d", label: "exhausted, resets in 2h", status: .exhausted, remainingPercent: 0, resetsInHours: 2),
            account("acct-e", label: "near limit 10%, resets in 5h", status: .nearLimit, remainingPercent: 10, resetsInHours: 5),
            account("acct-f", label: "near limit 30%, resets in 1h", status: .nearLimit, remainingPercent: 30, resetsInHours: 1)
        ])

        let items = snapshot.attentionItems()

        XCTAssertEqual(items.map(\.selection.quota.label), [
            "exhausted, resets in 2h",
            "exhausted, resets in 10h",
            "near limit 10%, resets in 5h",
            "near limit 30%, resets in 1h",
            "near limit 30%, resets in 3h"
        ])
        XCTAssertEqual(items.map(\.urgency), [.exhausted, .exhausted, .nearLimit, .nearLimit, .nearLimit])
    }

    func testRankingPutsAnUnknownRemainingAndAMissingResetAfterKnownOnes() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            account("acct-a", label: "amount unknown, resets in 1h", status: .nearLimit, remainingPercent: nil, resetsInHours: 1),
            account("acct-b", label: "40% left, no reset", status: .nearLimit, remainingPercent: 40, resetsInHours: nil),
            account("acct-c", label: "40% left, resets in 9h", status: .nearLimit, remainingPercent: 40, resetsInHours: 9)
        ])

        XCTAssertEqual(snapshot.attentionItems().map(\.selection.quota.label), [
            "40% left, resets in 9h",
            "40% left, no reset",
            "amount unknown, resets in 1h"
        ])
    }

    func testAnExhaustedQuotaRanksByResetEvenWhenItsAmountIsUnknown() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            account("acct-a", label: "0% left, resets in 3h", status: .exhausted, remainingPercent: 0, resetsInHours: 3),
            account("acct-b", label: "amount unknown, resets in 1h", status: .exhausted, remainingPercent: nil, resetsInHours: 1)
        ])

        XCTAssertEqual(snapshot.attentionItems().map(\.selection.quota.label), [
            "amount unknown, resets in 1h",
            "0% left, resets in 3h"
        ])
    }

    func testFullTiesKeepTheStableOrderOfProviderThenAccount() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            account("acct-b", provider: "openai-codex", label: "codex b", status: .exhausted, remainingPercent: 0, resetsInHours: 2),
            account("acct-b", label: "claude b", status: .exhausted, remainingPercent: 0, resetsInHours: 2),
            account("acct-a", label: "claude a", status: .exhausted, remainingPercent: 0, resetsInHours: 2)
        ])

        XCTAssertEqual(snapshot.attentionItems().map(\.selection.quota.label), ["claude a", "claude b", "codex b"])
    }

    func testAccountAttentionKeepsOneItemPerAccountItsTopRanked() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "acct-x", quotas: [
                quota(id: "x-5h", resetsAt: later(hours: 1), label: "x 5 Hour near limit", status: .nearLimit, remainingPercent: 5),
                quota(
                    id: "x-7d",
                    windowID: "7d",
                    durationMilliseconds: 604_800_000,
                    resetsAt: later(hours: 18),
                    label: "x 7 Day exhausted",
                    status: .exhausted,
                    remainingPercent: 0
                )
            ]),
            report(accountID: "acct-y", quotas: [
                quota(id: "y-5h", label: "y 5 Hour near limit", status: .nearLimit, remainingPercent: 20)
            ]),
            report(accountID: "acct-z", quotas: [
                quota(
                    id: "z-7d",
                    windowID: "7d",
                    durationMilliseconds: 604_800_000,
                    resetsAt: later(hours: 1),
                    label: "z 7 Day exhausted",
                    status: .exhausted,
                    remainingPercent: 0
                ),
                quota(id: "z-5h", label: "z 5 Hour available")
            ]),
            report(accountID: "acct-w", quotas: [quota(id: "w-5h", label: "w 5 Hour available")])
        ])

        XCTAssertEqual(snapshot.attentionItems().map(\.selection.quota.label), [
            "z 7 Day exhausted",
            "x 7 Day exhausted",
            "x 5 Hour near limit",
            "y 5 Hour near limit"
        ])
        XCTAssertEqual(snapshot.accountAttention().map(\.selection.quota.label), [
            "z 7 Day exhausted",
            "x 7 Day exhausted",
            "y 5 Hour near limit"
        ])
        XCTAssertEqual(snapshot.accountAttention().map(\.selection.report.sourceAccount?.accountID), ["acct-z", "acct-x", "acct-y"])
    }

    func testStatusOverviewOrdersEquallyUsedOKAccountsByResetAndPutsUnknownUsageLast() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            account("acct-a", label: "60% left", status: .available, remainingPercent: 60, resetsInHours: 1),
            account("acct-b", label: "15% left, resets in 9h", status: .available, remainingPercent: 15, resetsInHours: 9),
            account("acct-c", label: "15% left, resets in 2h", status: .available, remainingPercent: 15, resetsInHours: 2),
            account("acct-d", label: "15% left, no reset", status: .available, remainingPercent: 15, resetsInHours: nil),
            account("acct-e", label: "amount unknown", status: .available, remainingPercent: nil, resetsInHours: 1)
        ])

        XCTAssertEqual(snapshot.statusOverview().ok.map(\.lead.quota.label), [
            "15% left, resets in 2h",
            "15% left, resets in 9h",
            "15% left, no reset",
            "60% left",
            "amount unknown"
        ])
    }

    func testProgressReadsTheUsedFractionClampsItAndLeavesAnUnknownAmountEmpty() {
        func amount(usedFraction: Double?, remainingFraction: Double? = nil) -> UsageAmount {
            UsageAmount(
                used: nil,
                limit: nil,
                remaining: nil,
                usedFraction: usedFraction,
                remainingFraction: remainingFraction,
                unit: .percent
            )
        }

        XCTAssertNil(amount(usedFraction: nil).progress)
        XCTAssertEqual(amount(usedFraction: 0).progress, 0)
        XCTAssertEqual(amount(usedFraction: 0.42).progress, 0.42)
        XCTAssertEqual(amount(usedFraction: 1.6).progress, 1)
        XCTAssertEqual(amount(usedFraction: -0.2).progress, 0)
        XCTAssertEqual(amount(usedFraction: nil, remainingFraction: 0.25).progress, 0.75)
    }

    func testAPeriodWordNamesTheLengthOfAWindowThatGivesNoDuration() {
        func length(_ label: String, durationMilliseconds: Double?) -> Double {
            QuotaWindow(identity: QuotaWindowIdentity(id: "w"), label: label, durationMilliseconds: durationMilliseconds, resetLabel: nil)
                .effectiveLengthMilliseconds
        }

        XCTAssertEqual(length("Hourly", durationMilliseconds: nil), 3_600_000)
        XCTAssertEqual(length("daily", durationMilliseconds: nil), 86_400_000)
        XCTAssertEqual(length(" Weekly ", durationMilliseconds: nil), 604_800_000)
        XCTAssertEqual(length("MONTHLY", durationMilliseconds: nil), 2_592_000_000)
        XCTAssertEqual(length("Monthly", durationMilliseconds: 5_000), 5_000)
        XCTAssertEqual(length("Weekly", durationMilliseconds: 0), 604_800_000)
        XCTAssertEqual(length("Quarterly", durationMilliseconds: nil), 0)
    }

    func testAQuotaIsScopedWhenItsLabelEndsInAParentheticalThatNarrowsItsWindow() {
        let quotas = builtQuotas(from: [
            quota(id: "fable", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000, label: "Claude 7 Day (Fable)"),
            quota(id: "build", windowID: "weekly", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: "Grok Build (Weekly)"),
            quota(id: "own", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000, label: "Claude (7 day)"),
            quota(id: "plain", windowID: "monthly", windowLabel: "Monthly", durationMilliseconds: nil, label: "Cursor Models"),
            quota(id: "no-window", windowID: nil, label: "Other Models (Pro)")
        ])

        XCTAssertEqual(quotas.map(\.scopeDetail), ["Fable", nil, nil, nil, "Pro"])
        XCTAssertEqual(quotas.map(\.isScoped), [true, false, false, false, true])
    }

    func testTheCapacityQuotaIsTheLongestWindowThatIsNotScoped() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "acct-a", quotas: [
                quota(id: "session", label: "Claude 5 Hour", remainingPercent: 74),
                quota(id: "weekly", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000, label: "Claude 7 Day", remainingPercent: 30),
                quota(id: "fable", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000, label: "Claude 7 Day (Fable)", remainingPercent: 1)
            ])
        ])

        let usage = try XCTUnwrap(snapshot.providerUsage(now: timestamp).first)

        XCTAssertEqual(usage.measured.map(\.quota.label), ["Claude 7 Day"])
        XCTAssertEqual(try XCTUnwrap(usage.usedFraction), 0.7, accuracy: 0.0001)
    }

    func testEqualWindowsGoToTheMostUsedQuotaThenToTheStableOrder() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "acct-a", quotas: [
                quota(id: "a", windowID: "7d", durationMilliseconds: 604_800_000, label: "Weekly A", remainingPercent: 70),
                quota(id: "b", windowID: "7d", durationMilliseconds: 604_800_000, label: "Weekly B", remainingPercent: 40),
                quota(id: "c", windowID: "7d", durationMilliseconds: 604_800_000, label: "Weekly C", remainingPercent: 40)
            ])
        ])

        let usage = try XCTUnwrap(snapshot.providerUsage(now: timestamp).first)

        XCTAssertEqual(usage.measured.map(\.quota.label), ["Weekly B"])
    }

    func testAMonthlyLabelStandsInForAMissingDurationAndAnUnknownLengthRanksShortest() throws {
        let monthly = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "cursor", accountID: "acct-a", quotas: [
                quota(id: "weekly", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000, label: "Weekly", remainingPercent: 5),
                quota(id: "monthly", windowID: "monthly", windowLabel: "Monthly", durationMilliseconds: nil, label: "Monthly", remainingPercent: 80)
            ])
        ])
        let unknown = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "cursor", accountID: "acct-a", quotas: [
                quota(id: "plan", windowID: "plan", windowLabel: "Plan", durationMilliseconds: nil, label: "Plan", remainingPercent: 5),
                quota(id: "session", windowID: "5h", windowLabel: "5 Hour", durationMilliseconds: 18_000_000, label: "Session", remainingPercent: 90)
            ])
        ])

        XCTAssertEqual(try XCTUnwrap(monthly.providerUsage(now: timestamp).first).measured.map(\.quota.label), ["Monthly"])
        XCTAssertEqual(try XCTUnwrap(unknown.providerUsage(now: timestamp).first).measured.map(\.quota.label), ["Session"])
    }

    func testQuotasWithoutAUsedShareAndScopedOnesLeaveAnAccountUnmeasured() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "acct-a", quotas: [quota(id: "weekly", windowID: "7d", label: "Claude 7 Day", remainingPercent: nil)]),
            report(accountID: "acct-b", quotas: [
                quota(id: "fable", windowID: "7d", windowLabel: "7 Day", label: "Claude 7 Day (Fable)", remainingPercent: 20)
            ])
        ])

        let usage = try XCTUnwrap(snapshot.providerUsage(now: timestamp).first)

        XCTAssertEqual(usage.accountCount, 2)
        XCTAssertTrue(usage.measured.isEmpty)
        XCTAssertNil(usage.usedFraction)
        XCTAssertFalse(usage.isStale)
        XCTAssertEqual(usage.spokenSummary, "Claude usage unknown across 2 accounts")
    }

    func testASingleAccountWithoutAFigureSaysSo() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "cursor", accountID: "cursor-a", quotas: [quota(id: "models", label: "Cursor Models", remainingPercent: nil)])
        ])

        let usage = try XCTUnwrap(snapshot.providerUsage(now: timestamp).first)

        XCTAssertNil(usage.usedFraction)
        XCTAssertEqual(usage.spokenSummary, "Cursor usage unknown, 1 account")
    }

    func testPercentAccountsAverageTheirUsedShares() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [3.0, 12.0, 4.0].enumerated().map { index, remaining in
            report(provider: "openai-codex", accountID: "codex-\(index)", quotas: [
                quota(id: "weekly", windowID: "7d", windowLabel: "7 days", durationMilliseconds: 604_800_000, label: "7 days", remainingPercent: remaining)
            ])
        })

        let usage = try XCTUnwrap(snapshot.providerUsage(now: timestamp).first)

        XCTAssertEqual(try XCTUnwrap(usage.usedFraction), 0.9367, accuracy: 0.0001)
        XCTAssertEqual(usage.accountCount, 3)
        XCTAssertEqual(usage.measured.map(\.accountNumber), [1, 2, 3])
    }

    func testAccountsWithLimitsInOneUnitPoolThemInsteadOfAveragingTheirShares() throws {
        func fraction(_ accounts: [(used: Double, limit: Double)]) throws -> Double {
            let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: accounts.enumerated().map { index, account in
                report(provider: "cursor", accountID: "cursor-\(index)", quotas: [amountQuota(used: account.used, limit: account.limit)])
            })
            return try XCTUnwrap(snapshot.providerUsage(now: timestamp).first?.usedFraction)
        }

        XCTAssertEqual(try fraction([(50, 100), (150, 300)]), 0.5, accuracy: 0.0001)
        // Pooled it is 80 of 400 dollars. The average of 50% and 10% would be 30%.
        XCTAssertEqual(try fraction([(50, 100), (30, 300)]), 0.2, accuracy: 0.0001)
    }

    func testAccountsThatCannotPoolFallBackToTheAverageOfTheirShares() throws {
        func fraction(_ quotas: [UsageQuotaDraft]) throws -> Double {
            let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: quotas.enumerated().map { index, quota in
                report(provider: "cursor", accountID: "cursor-\(index)", quotas: [quota])
            })
            return try XCTUnwrap(snapshot.providerUsage(now: timestamp).first?.usedFraction)
        }

        // A percent limit is a share already, so these average to 30% where pooling would give 18%.
        XCTAssertEqual(
            try fraction([amountQuota(used: 50, limit: 100, unit: .percent), amountQuota(used: 40, limit: 400, unit: .percent)]),
            0.3,
            accuracy: 0.0001
        )
        // Dollars and tokens cannot be added.
        XCTAssertEqual(
            try fraction([amountQuota(used: 50, limit: 100, unit: .usd), amountQuota(used: 30, limit: 300, unit: .tokens)]),
            0.3,
            accuracy: 0.0001
        )
        // A missing unit names nothing, so two of them need not match.
        XCTAssertEqual(
            try fraction([amountQuota(used: 50, limit: 100, unit: .missing), amountQuota(used: 30, limit: 300, unit: .missing)]),
            0.3,
            accuracy: 0.0001
        )
        // An account without a limit leaves the pool with no denominator.
        XCTAssertEqual(
            try fraction([amountQuota(used: 50, limit: 100, unit: .usd), amountQuota(usedFraction: 0.1, unit: .usd)]),
            0.3,
            accuracy: 0.0001
        )
    }

    func testAnUnmeasuredAccountIsCountedButLeftOutOfTheFigure() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [quota(id: "weekly", windowID: "7d", label: "Claude 7 Day", remainingPercent: 20)]),
            report(accountID: "claude-b", quotas: [quota(id: "weekly", windowID: "7d", label: "Claude 7 Day", remainingPercent: nil)])
        ])

        let usage = try XCTUnwrap(snapshot.providerUsage(now: timestamp).first)

        XCTAssertEqual(usage.accountCount, 2)
        XCTAssertEqual(usage.measured.map(\.accountNumber), [1])
        XCTAssertEqual(try XCTUnwrap(usage.usedFraction), 0.8, accuracy: 0.0001)
        XCTAssertEqual(usage.spokenSummary, "Claude 80% used across 1 of 2 accounts")
    }

    func testProvidersFollowTheRegistryOrderWithUnknownOnesLastAndAlphabetical() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "mistral", accountID: "m"),
            report(provider: "cursor", accountID: "c"),
            report(provider: "groq", accountID: "g"),
            report(provider: "xai-oauth", accountID: "x"),
            report(provider: "anthropic", accountID: "a"),
            report(provider: "openai-codex", accountID: "o")
        ])

        XCTAssertEqual(
            snapshot.providerUsage(now: timestamp).map(\.provider),
            ["anthropic", "openai-codex", "xai-oauth", "cursor", "groq", "mistral"]
        )
    }

    func testOnlyProvidersWithAReportAreListed() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "cursor", accountID: "c"),
            report(provider: "anthropic", accountID: "a")
        ])

        XCTAssertEqual(snapshot.providerUsage(now: timestamp).map(\.provider), ["anthropic", "cursor"])
        XCTAssertEqual(UsageSnapshot(generatedAt: timestamp, reportDrafts: []).providerUsage(now: timestamp), [])
    }

    func testAMeasuredAccountKeepsItsNumberAmongItsProvidersReports() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "openai-codex", accountID: "codex-a"),
            report(accountID: "claude-a"),
            report(provider: "openai-codex", accountID: "codex-b")
        ])

        let usage = snapshot.providerUsage(now: timestamp)

        XCTAssertEqual(usage.map(\.provider), ["anthropic", "openai-codex"])
        XCTAssertEqual(usage.map { $0.measured.map(\.accountNumber) }, [[1], [1, 2]])
    }

    func testAProviderIsStaleWhenAMeasuredAccountsDataReachesTheStaleBoundary() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [report(accountID: "acct-a")])
        func isStale(after seconds: TimeInterval) -> Bool? {
            snapshot.providerUsage(now: timestamp.addingTimeInterval(seconds)).first?.isStale
        }

        XCTAssertEqual(isStale(after: 899), false)
        XCTAssertEqual(isStale(after: 900), true)
    }

    func testOnlyAMeasuredAccountsOldDataMakesAProviderStale() {
        func provider(oldAccountRemaining: Double?) -> ProviderUsage? {
            let old = UsageReportDraft(
                provider: "anthropic",
                sourceAccount: SourceAccountIdentity(accountID: "old", organizationID: nil, projectID: nil),
                privateDisplayLabel: nil,
                fetchedAt: timestamp.addingTimeInterval(-3_600),
                resetCredits: nil,
                quotas: [quota(id: "weekly", windowID: "7d", label: "Claude 7 Day", remainingPercent: oldAccountRemaining)]
            )
            return UsageSnapshot(generatedAt: timestamp, reportDrafts: [old, report(accountID: "fresh")]).providerUsage(now: timestamp).first
        }

        XCTAssertEqual(provider(oldAccountRemaining: 40)?.isStale, true)
        XCTAssertEqual(provider(oldAccountRemaining: nil)?.isStale, false)
    }

    func testEachProviderSpeaksItsCombinedUsageAndHowManyAccountsItCovers() {
        let sentences = RealisticFixture.snapshot().providerUsage(now: RealisticFixture.fetchedAt).map(\.spokenSummary)

        XCTAssertEqual(sentences, [
            "Claude 79% used across 5 accounts",
            "Codex 94% used across 3 accounts",
            "Grok 1% used, 1 account",
            "Cursor 100% used, 1 account"
        ])
    }

    func testUsedPercentRoundsToWholeDigitsAndDashesWhatIsUnknown() {
        XCTAssertEqual(UsageFormatting.usedPercent(0.79), "79%")
        XCTAssertEqual(UsageFormatting.usedPercent(0.9367), "94%")
        XCTAssertEqual(UsageFormatting.usedPercent(0.004), "0%")
        XCTAssertEqual(UsageFormatting.usedPercent(0.006), "1%")
        XCTAssertEqual(UsageFormatting.usedPercent(1), "100%")
        XCTAssertEqual(UsageFormatting.usedPercent(1.7), "100%")
        XCTAssertEqual(UsageFormatting.usedPercent(-0.2), "0%")
        XCTAssertEqual(UsageFormatting.usedPercent(nil), "–")
        XCTAssertEqual(UsageFormatting.usedPercent(.nan), "–")
    }

    func testResetPhraseKeepsTheResetDescriptionButStartsWithALowercaseLetter() {
        let inTwoHours = timestamp.addingTimeInterval(7_500)

        XCTAssertEqual(UsageFormatting.resetPhrase(for: inTwoHours, resetLabel: nil, now: timestamp), "resets in 2h 5m")
        XCTAssertEqual(UsageFormatting.resetPhrase(for: inTwoHours, resetLabel: "Renews", now: timestamp), "renews in 2h 5m")
        XCTAssertEqual(UsageFormatting.resetPhrase(for: nil, resetLabel: nil, now: timestamp), "reset unknown")
        XCTAssertEqual(
            UsageFormatting.resetPhrase(for: timestamp.addingTimeInterval(-60), resetLabel: nil, now: timestamp),
            "reset passed · recheck"
        )
    }

    func testProviderRegistryResolvesKnownIdsAndFallsBackToTheRawIdAndItsFirstLetter() {
        XCTAssertEqual(ProviderRegistry.displayName(for: "Anthropic"), "Claude")
        XCTAssertEqual(ProviderRegistry.badgeLetter(for: "openai-codex"), "O")
        XCTAssertEqual(ProviderRegistry.displayName(for: "mistral"), "mistral")
        XCTAssertEqual(ProviderRegistry.badgeLetter(for: "mistral"), "M")
    }

    func testRegistryRanksKnownProvidersInItsOrderThenUnknownOnesAlphabetically() {
        let ids = ["mistral", "Cursor", "groq", "xai-oauth", "anthropic", "openai-codex"]

        XCTAssertEqual(ids.sorted(by: ProviderRegistry.ranksBefore), ["anthropic", "openai-codex", "xai-oauth", "Cursor", "groq", "mistral"])
    }

    func testStatusOverviewMergesAnAccountsQuotasThatShareAnUrgencyAndAResetMinute() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "cursor", accountID: "cursor-a", quotas: [
                quota(id: "models", windowID: "monthly", durationMilliseconds: nil, resetsAt: later(hours: 20), label: "Cursor Models", status: .exhausted, remainingPercent: nil),
                quota(id: "other", windowID: "monthly", durationMilliseconds: nil, resetsAt: later(hours: 20).addingTimeInterval(59), label: "Other Models", status: .exhausted, remainingPercent: 0)
            ])
        ])

        let overview = snapshot.statusOverview()

        XCTAssertEqual(overview.exhausted.map { $0.quotas.map(\.quota.label) }, [["Cursor Models", "Other Models"]])
        XCTAssertEqual(overview.exhausted.map(\.resetsAt), [later(hours: 20)])
        XCTAssertEqual(overview.exhausted.map(\.accountNumber), [1])
        XCTAssertEqual(overview.exhausted.map(\.urgency), [.exhausted])
        XCTAssertTrue(overview.nearLimit.isEmpty)
        XCTAssertTrue(overview.ok.isEmpty)
    }

    func testStatusOverviewKeepsQuotasThatResetAtDifferentTimesOnSeparateLinesEarlierResetFirst() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "cursor", accountID: "cursor-a", quotas: [
                quota(id: "models", windowID: "monthly", durationMilliseconds: nil, resetsAt: later(hours: 30), label: "Cursor Models", status: .exhausted, remainingPercent: 0),
                quota(id: "other", windowID: "monthly", durationMilliseconds: nil, resetsAt: later(hours: 20), label: "Other Models", status: .exhausted, remainingPercent: 0)
            ])
        ])

        let overview = snapshot.statusOverview()

        XCTAssertEqual(overview.exhausted.map { $0.quotas.map(\.quota.label) }, [["Other Models"], ["Cursor Models"]])
        XCTAssertEqual(overview.exhausted.map(\.resetsAt), [later(hours: 20), later(hours: 30)])
    }

    func testStatusOverviewMergesResetsInTheSameMinuteButNotInTheNextOne() {
        let reset = later(hours: 6)
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [
                quota(id: "first", resetsAt: reset, label: "first", status: .exhausted, remainingPercent: 0),
                quota(id: "second", resetsAt: reset.addingTimeInterval(59), label: "second", status: .exhausted, remainingPercent: 0),
                quota(id: "third", resetsAt: reset.addingTimeInterval(60), label: "third", status: .exhausted, remainingPercent: 0)
            ])
        ])

        XCTAssertEqual(snapshot.statusOverview().exhausted.map { $0.quotas.map(\.quota.label) }, [["first", "second"], ["third"]])
    }

    func testStatusOverviewMergesQuotasWithoutAResetTimeOnlyWithEachOther() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [
                quota(id: "a", resetsAt: nil, label: "a", status: .exhausted, remainingPercent: 0),
                quota(id: "b", resetsAt: later(hours: 5), label: "b", status: .exhausted, remainingPercent: 0),
                quota(id: "c", resetsAt: nil, label: "c", status: .exhausted, remainingPercent: 0)
            ])
        ])

        let lines = snapshot.statusOverview().exhausted

        XCTAssertEqual(lines.map { $0.quotas.map(\.quota.label) }, [["b"], ["a", "c"]])
        XCTAssertEqual(lines.map(\.resetsAt), [later(hours: 5), nil])
    }

    func testStatusOverviewListsAnAccountWithAnExhaustedQuotaOnlyUnderExhaustedWhateverElseWorks() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [
                quota(id: "session", label: "Claude 5 Hour", remainingPercent: 80),
                quota(
                    id: "weekly",
                    windowID: "7d",
                    durationMilliseconds: 604_800_000,
                    resetsAt: later(hours: 9),
                    label: "Claude 7 Day",
                    status: .exhausted,
                    remainingPercent: 0
                )
            ]),
            report(accountID: "claude-b", quotas: [quota(id: "session", label: "Claude 5 Hour", remainingPercent: 60)])
        ])

        let overview = snapshot.statusOverview()

        XCTAssertEqual(overview.exhausted.map { $0.quotas.map(\.quota.label) }, [["Claude 7 Day"]])
        XCTAssertEqual(overview.exhausted.map(\.report.sourceAccount?.accountID), ["claude-a"])
        XCTAssertEqual(overview.ok.map(\.report.sourceAccount?.accountID), ["claude-b"])
    }

    func testStatusOverviewKeepsANearLimitAccountOutOfOK() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            account("acct-a", label: "near limit 5%", status: .nearLimit, remainingPercent: 5, resetsInHours: 4),
            account("acct-b", label: "available 50%", status: .available, remainingPercent: 50, resetsInHours: 4)
        ])

        let overview = snapshot.statusOverview()

        XCTAssertEqual(overview.nearLimit.map { $0.quotas.map(\.quota.label) }, [["near limit 5%"]])
        XCTAssertEqual(overview.ok.map(\.lead.quota.label), ["available 50%"])
        XCTAssertTrue(overview.exhausted.isEmpty)
    }

    func testStatusOverviewGivesAnAccountWithBothUrgenciesALineInEachGroup() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [
                quota(id: "session", resetsAt: later(hours: 2), label: "Claude 5 Hour", status: .nearLimit, remainingPercent: 8),
                quota(
                    id: "weekly",
                    windowID: "7d",
                    durationMilliseconds: 604_800_000,
                    resetsAt: later(hours: 9),
                    label: "Claude 7 Day",
                    status: .exhausted,
                    remainingPercent: 0
                )
            ])
        ])

        let overview = snapshot.statusOverview()

        XCTAssertEqual(overview.exhausted.map { $0.quotas.map(\.quota.label) }, [["Claude 7 Day"]])
        XCTAssertEqual(overview.nearLimit.map { $0.quotas.map(\.quota.label) }, [["Claude 5 Hour"]])
        XCTAssertTrue(overview.ok.isEmpty)
    }

    func testStatusOverviewOrdersOKAccountsMostUsedFirstAndLeadsEachWithItsLeastRemainingQuota() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            account("acct-a", label: "60% left", status: .available, remainingPercent: 60, resetsInHours: 1),
            report(accountID: "acct-b", quotas: [
                quota(id: "session", label: "b 5 Hour 90% left", remainingPercent: 90),
                quota(id: "weekly", windowID: "7d", label: "b 7 Day 15% left", remainingPercent: 15)
            ]),
            account("acct-c", label: "unknown", status: .available, remainingPercent: nil, resetsInHours: 1),
            account("acct-d", label: "40% left", status: .available, remainingPercent: 40, resetsInHours: 2)
        ])

        let ok = snapshot.statusOverview().ok

        XCTAssertEqual(ok.map(\.lead.quota.label), ["b 7 Day 15% left", "40% left", "60% left", "unknown"])
        XCTAssertEqual(ok.map(\.accountNumber), [2, 4, 1, 3])
    }

    func testStatusOverviewLeadsAnAccountWithNoKnownUsageByTheStableOrderEvenWhenAnotherQuotaResetsSooner() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "acct-a", quotas: [
                quota(id: "weekly", windowID: "7d", resetsAt: later(hours: 1), label: "weekly", remainingPercent: nil),
                quota(id: "session", windowID: "5h", resetsAt: later(hours: 9), label: "session", remainingPercent: nil)
            ])
        ])

        XCTAssertEqual(snapshot.statusOverview().ok.map(\.lead.quota.label), ["session"])
    }

    func testStatusOverviewCountsLinesNotAccountsOrQuotas() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [
                quota(id: "session", label: "Claude 5 Hour", remainingPercent: 80),
                quota(
                    id: "weekly",
                    windowID: "7d",
                    durationMilliseconds: 604_800_000,
                    resetsAt: later(hours: 9),
                    label: "Claude 7 Day",
                    status: .exhausted,
                    remainingPercent: 0
                )
            ]),
            report(provider: "cursor", accountID: "cursor-a", quotas: [
                quota(id: "models", windowID: "monthly", durationMilliseconds: nil, resetsAt: later(hours: 20), label: "Cursor Models", status: .exhausted, remainingPercent: nil),
                quota(id: "other", windowID: "monthly", durationMilliseconds: nil, resetsAt: later(hours: 20), label: "Other Models", status: .exhausted, remainingPercent: 0)
            ]),
            account("codex-a", provider: "openai-codex", label: "Codex 7 days", status: .nearLimit, remainingPercent: 3, resetsInHours: 110),
            account("codex-b", provider: "openai-codex", label: "Codex 7 days", status: .available, remainingPercent: 12, resetsInHours: 110),
            account("claude-b", label: "Claude 7 Day", status: .available, remainingPercent: 22, resetsInHours: 120),
            account("grok-a", provider: "xai-oauth", label: "Grok Weekly", status: .available, remainingPercent: 99, resetsInHours: 140)
        ])

        let overview = snapshot.statusOverview()

        XCTAssertEqual(overview.exhausted.count, 2)
        XCTAssertEqual(overview.nearLimit.count, 1)
        XCTAssertEqual(overview.ok.count, 3)
        XCTAssertEqual(overview.exhausted.map(\.report.provider), ["anthropic", "cursor"])
        XCTAssertEqual(overview.ok.map(\.report.sourceAccount?.accountID), ["codex-b", "claude-b", "grok-a"])
    }

    func testStatusOverviewLeavesAnAccountWithoutQuotasOutOfEveryGroup() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "empty", quotas: []),
            report(accountID: "claude-b", quotas: [quota(id: "session", remainingPercent: 70)])
        ])

        let overview = snapshot.statusOverview()

        XCTAssertEqual(overview.ok.map(\.report.sourceAccount?.accountID), ["claude-b"])
        XCTAssertEqual(overview.ok.map(\.accountNumber), [2])
        XCTAssertTrue(overview.exhausted.isEmpty)
        XCTAssertTrue(overview.nearLimit.isEmpty)
        XCTAssertTrue(UsageSnapshot(generatedAt: timestamp, reportDrafts: []).statusOverview().isEmpty)
    }

    func testAnAccountTakesTheStatusOfItsMostUrgentQuota() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "acct-a", quotas: [quota(id: "session", remainingPercent: 80)]),
            report(accountID: "acct-b", quotas: [quota(id: "session", status: .nearLimit, remainingPercent: 8)]),
            report(accountID: "acct-c", quotas: [
                quota(id: "session", status: .nearLimit, remainingPercent: 8),
                quota(id: "weekly", windowID: "7d", status: .exhausted, remainingPercent: 0)
            ]),
            report(accountID: "acct-d", quotas: [])
        ])

        XCTAssertEqual(snapshot.reports.map(\.accountStatus), [.ok, .nearLimit, .exhausted, .ok])
        XCTAssertLessThan(AccountStatus.exhausted, .nearLimit)
        XCTAssertLessThan(AccountStatus.nearLimit, .ok)
    }

    func testCountdownGivesBareTextForTheTimeLeftAndSeparatesAPassedResetFromAnUnknownOne() {
        func countdown(minutes: Double) -> ResetCountdown {
            UsageFormatting.countdown(to: timestamp.addingTimeInterval(minutes * 60), now: timestamp)
        }

        XCTAssertEqual(countdown(minutes: 561), .remaining("9h 21m"))
        XCTAssertEqual(countdown(minutes: 5_242), .remaining("3d 15h"))
        XCTAssertEqual(countdown(minutes: 0.5), .remaining("1m"))
        XCTAssertEqual(countdown(minutes: 59), .remaining("59m"))
        XCTAssertEqual(countdown(minutes: 60), .remaining("1h 0m"))
        XCTAssertEqual(countdown(minutes: 1_440), .remaining("1d 0h"))
        XCTAssertEqual(UsageFormatting.countdown(to: nil, now: timestamp), .unknown)
        XCTAssertEqual(countdown(minutes: -1), .passed)
        XCTAssertEqual(countdown(minutes: 0), .passed)
    }

    func testShortLabelNamesTheWindowLengthAndKeepsAParenthetical() {
        let quotas = builtQuotas(from: [
            quota(id: "weekly", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000, label: "Claude 7 Day"),
            quota(id: "fable", windowID: "7d-fable", windowLabel: "7 Day", durationMilliseconds: 604_800_000, label: "Claude 7 Day (Fable)"),
            quota(id: "session", windowID: "5h", windowLabel: "5 Hour", durationMilliseconds: 18_000_000, label: "Claude 5 Hour"),
            quota(id: "weekly-credits", windowID: "weekly", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: "Grok Build (Weekly Credits)"),
            quota(id: "quarterly", windowID: "weekly", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: "Grok Build (Quarterly)"),
            quota(id: "models", windowID: "monthly", durationMilliseconds: nil, label: "Cursor Models"),
            quota(id: "credits", windowID: nil, label: "SuperGrok Weekly Credits")
        ])

        XCTAssertEqual(
            quotas.map(UsageFormatting.shortLabel(for:)),
            ["7d", "7d Fable", "5h", "7d Weekly Credits", "7d Quarterly", "Cursor Models", "SuperGrok Weekly Credits"]
        )
    }

    func testShortLabelDropsAParentheticalThatOnlyRestatesTheWindow() {
        let quotas = builtQuotas(from: [
            quota(id: "build", windowID: "weekly", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: "Grok Build (Weekly)"),
            quota(id: "hourly", windowID: "1h", windowLabel: "1 Hour", durationMilliseconds: 3_600_000, label: "Synthetic window (Hourly)"),
            quota(id: "daily", windowID: "1d", windowLabel: "1 Day", durationMilliseconds: 86_400_000, label: "Synthetic window (daily)"),
            quota(id: "weekly", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000, label: "Synthetic window (WEEKLY)"),
            quota(id: "monthly", windowID: "30d", windowLabel: "30 Day", durationMilliseconds: 2_592_000_000, label: "Synthetic window (Monthly)"),
            quota(id: "quarterly", windowID: "quarterly", windowLabel: " Quarterly ", durationMilliseconds: 7_776_000_000, label: "Synthetic window (quarterly)")
        ])

        XCTAssertEqual(quotas.map(UsageFormatting.shortLabel(for:)), ["7d", "1h", "1d", "7d", "30d", "90d"])
    }

    func testPercentLeftRoundsTheRemainingShareAndSaysNothingWhenItIsUnknown() {
        let dollars = UsageQuotaDraft(
            id: "other",
            label: "Other Models",
            scope: nil,
            window: nil,
            amount: UsageAmount(used: 20, limit: 20, remaining: 0, usedFraction: 1, remainingFraction: 0, unit: .usd),
            status: .available,
            resetsAt: nil
        )
        let quotas = builtQuotas(from: [
            quota(id: "near", remainingPercent: 3),
            dollars,
            quota(id: "unknown", remainingPercent: nil),
            quota(id: "almost-half", remainingPercent: 49.6),
            quota(id: "gone", status: .exhausted, remainingPercent: nil)
        ])

        XCTAssertEqual(quotas.map(UsageFormatting.percentLeft), ["3%", "0%", nil, "50%", "0%"])
    }

    func testAccountTagJoinsTheProviderLetterAndTheAccountNumber() {
        XCTAssertEqual(UsageFormatting.accountTag(provider: "anthropic", number: 1), "C1")
        XCTAssertEqual(UsageFormatting.accountTag(provider: "cursor", number: 1), "U1")
        XCTAssertEqual(UsageFormatting.accountTag(provider: "openai-codex", number: 3), "O3")
        XCTAssertEqual(UsageFormatting.accountTag(provider: "xai-oauth", number: 12), "G12")
        XCTAssertEqual(UsageFormatting.accountTag(provider: "mistral", number: 2), "M2")
    }

    private var timestamp: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    private func later(hours: Double) -> Date {
        timestamp.addingTimeInterval(hours * 3_600)
    }

    private func report(
        provider: String = "anthropic",
        accountID: String?,
        organizationID: String? = nil,
        projectID: String? = nil,
        label: String? = nil,
        quotas: [UsageQuotaDraft]? = nil
    ) -> UsageReportDraft {
        UsageReportDraft(
            provider: provider,
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
        resetsAt: Date? = nil,
        label: String = "Synthetic window",
        status: UsageLimitStatus = .available,
        remainingPercent: Double? = 80
    ) -> UsageQuotaDraft {
        let window = windowID.map {
            QuotaWindow(
                identity: QuotaWindowIdentity(id: $0),
                label: windowLabel ?? $0,
                durationMilliseconds: durationMilliseconds,
                resetLabel: nil
            )
        }
        let amount = remainingPercent.map {
            UsageAmount(used: 100 - $0, limit: 100, remaining: $0, usedFraction: (100 - $0) / 100, remainingFraction: $0 / 100, unit: .percent)
        }
        return UsageQuotaDraft(id: id, label: label, scope: scope, window: window, amount: amount, status: status, resetsAt: resetsAt)
    }

    private func account(
        _ accountID: String,
        provider: String = "anthropic",
        label: String,
        status: UsageLimitStatus,
        remainingPercent: Double?,
        resetsInHours: Double?
    ) -> UsageReportDraft {
        report(provider: provider, accountID: accountID, quotas: [
            quota(
                id: label,
                resetsAt: resetsInHours.map { later(hours: $0) },
                label: label,
                status: status,
                remainingPercent: remainingPercent
            )
        ])
    }

    private func amountQuota(
        used: Double? = nil,
        limit: Double? = nil,
        usedFraction: Double? = nil,
        unit: UsageUnit = .usd
    ) -> UsageQuotaDraft {
        UsageQuotaDraft(
            id: "credits",
            label: "Credits",
            scope: nil,
            window: QuotaWindow(identity: QuotaWindowIdentity(id: "monthly"), label: "Monthly", durationMilliseconds: nil, resetLabel: nil),
            amount: UsageAmount(used: used, limit: limit, remaining: nil, usedFraction: usedFraction, remainingFraction: nil, unit: unit),
            status: .available,
            resetsAt: nil
        )
    }

    private func builtQuotas(from drafts: [UsageQuotaDraft]) -> [UsageQuota] {
        UsageSnapshot(generatedAt: timestamp, reportDrafts: [report(accountID: "acct-a", quotas: drafts)]).reports[0].quotas
    }
}

final class RoundedSquareGeometryTests: XCTestCase {
    func testFillHeightHitsTheEndpointsAndGrowsWithTheFraction() {
        let geometry = RoundedSquareGeometry(side: 14)

        XCTAssertEqual(geometry.fillHeight(forUsedFraction: 0), 0)
        XCTAssertEqual(geometry.fillHeight(forUsedFraction: 1), 14)
        XCTAssertEqual(geometry.fillHeight(forUsedFraction: -0.5), 0)
        XCTAssertEqual(geometry.fillHeight(forUsedFraction: 2), 14)
        let heights = (0...100).map { geometry.fillHeight(forUsedFraction: Double($0) / 100) }
        for (lower, upper) in zip(heights, heights.dropFirst()) {
            XCTAssertLessThan(lower, upper)
        }
    }

    func testFillHeightCoversTheFractionOfTheAreaNotOfTheHeight() {
        let geometry = RoundedSquareGeometry(side: 14)

        for fraction in [0.25, 0.5, 0.75] {
            let height = geometry.fillHeight(forUsedFraction: fraction)
            XCTAssertEqual(sampledShare(of: geometry, below: height), fraction, accuracy: 0.005)
        }
        XCTAssertGreaterThan(geometry.fillHeight(forUsedFraction: 0.25), 3.5)
        XCTAssertEqual(geometry.fillHeight(forUsedFraction: 0.5), 7, accuracy: 0.001)
        XCTAssertLessThan(geometry.fillHeight(forUsedFraction: 0.75), 10.5)
    }

    private func sampledShare(of geometry: RoundedSquareGeometry, below height: CGFloat) -> Double {
        let side = Double(geometry.side)
        let radius = Double(geometry.cornerRadius)
        let steps = 1000
        var filled = 0
        var total = 0
        for row in 0..<steps {
            let y = (Double(row) + 0.5) / Double(steps) * side
            for column in 0..<steps {
                let x = (Double(column) + 0.5) / Double(steps) * side
                let nearestX = min(max(x, radius), side - radius)
                let nearestY = min(max(y, radius), side - radius)
                guard hypot(x - nearestX, y - nearestY) <= radius else { continue }
                total += 1
                if y < Double(height) { filled += 1 }
            }
        }
        return Double(filled) / Double(total)
    }
}

final class StatusGroupsTests: XCTestCase {
    func testAnExhaustedRowReadsItsQuotaItsStatusAndItsReset() {
        let overview = statusOverview([
            report("anthropic", accountID: "claude-a", quotas: [
                quota("Claude 7 Day", windowLabel: "7 Day", status: .exhausted, remainingPercent: 0, resetsInMinutes: 561)
            ])
        ])

        XCTAssertEqual(
            overview.exhausted.map { $0.accessibilityLabel(accountLabel: "Account 1", isStale: false, now: timestamp) },
            ["Claude Account 1, 7 Day exhausted, resets in 9h 21m"]
        )
    }

    func testANearLimitRowAddsTheShareLeftBeforeTheReset() {
        let overview = statusOverview([
            report("openai-codex", accountID: "codex-a", quotas: [
                quota("7 days", windowLabel: "7 days", status: .nearLimit, remainingPercent: 3, resetsInMinutes: 6_605)
            ])
        ])

        XCTAssertEqual(
            overview.nearLimit.map { $0.accessibilityLabel(accountLabel: "Account 1", isStale: false, now: timestamp) },
            ["Codex Account 1, 7 days near limit, 3% left, resets in 4d 14h"]
        )
    }

    func testANearLimitRowWithoutAKnownShareSaysSo() {
        let overview = statusOverview([
            report("openai-codex", accountID: "codex-a", quotas: [
                quota("7 days", windowLabel: "7 days", status: .nearLimit, remainingPercent: nil, resetsInMinutes: 6_605)
            ])
        ])

        XCTAssertEqual(
            overview.nearLimit.map { $0.accessibilityLabel(accountLabel: "Account 1", isStale: false, now: timestamp) },
            ["Codex Account 1, 7 days near limit, remaining unknown, resets in 4d 14h"]
        )
    }

    func testAnOKRowNamesItsLeadQuotaAndTheShareLeft() {
        let overview = statusOverview([
            report("anthropic", accountID: "claude-a", quotas: [
                quota("Claude 7 Day", windowLabel: "7 Day", status: .exhausted, remainingPercent: 0, resetsInMinutes: 561)
            ]),
            report("anthropic", accountID: "claude-b", quotas: [
                quota("Claude 5 Hour", windowLabel: "5 Hour", durationMilliseconds: 18_000_000, remainingPercent: 100),
                quota("Claude 7 Day", windowLabel: "7 Day", remainingPercent: 22, resetsInMinutes: 7_221)
            ])
        ])

        XCTAssertEqual(
            overview.ok.map { $0.accessibilityLabel(accountLabel: "Account 2", isStale: false) },
            ["Claude Account 2, OK, 7 Day, 22% left"]
        )
    }

    func testAGrokRowShowsOnlyTheWindowLengthAndSpeaksTheQuotaNameWhole() {
        let overview = statusOverview([
            report("xai-oauth", accountID: "grok-a", quotas: [
                quota("Grok Build (Weekly)", windowLabel: "Weekly", remainingPercent: 40)
            ])
        ])

        XCTAssertEqual(overview.ok.map { UsageFormatting.shortLabel(for: $0.lead.quota) }, ["7d"])
        XCTAssertEqual(
            overview.ok.map { $0.accessibilityLabel(accountLabel: "Account 1", isStale: false) },
            ["Grok Account 1, OK, Grok Build (Weekly), 40% left"]
        )
    }

    func testAMergedRowJoinsTheNamesOfItsQuotasAndKeepsAProductNameWhole() {
        let overview = statusOverview([
            report("cursor", accountID: "cursor-a", quotas: [
                quota("Cursor Models", windowLabel: "Monthly", durationMilliseconds: nil, status: .exhausted, remainingPercent: nil, resetsInMinutes: 5_242),
                quota("Other Models", windowLabel: "Monthly", durationMilliseconds: nil, status: .exhausted, remainingPercent: 0, resetsInMinutes: 5_242)
            ])
        ])

        XCTAssertEqual(
            overview.exhausted.map { $0.accessibilityLabel(accountLabel: "Account 1", isStale: false, now: timestamp) },
            ["Cursor Account 1, Cursor Models and Other Models exhausted, resets in 3d 15h"]
        )
    }

    func testAStaleRowEndsWithStale() {
        let overview = statusOverview([
            report("anthropic", accountID: "claude-a", quotas: [
                quota("Claude 7 Day", windowLabel: "7 Day", status: .exhausted, remainingPercent: 0, resetsInMinutes: 561)
            ]),
            report("anthropic", accountID: "claude-b", quotas: [
                quota("Claude 7 Day", windowLabel: "7 Day", remainingPercent: 22)
            ])
        ])

        XCTAssertEqual(
            overview.exhausted.map { $0.accessibilityLabel(accountLabel: "Account 1", isStale: true, now: timestamp) },
            ["Claude Account 1, 7 Day exhausted, resets in 9h 21m, stale"]
        )
        XCTAssertEqual(
            overview.ok.map { $0.accessibilityLabel(accountLabel: "Account 2", isStale: true) },
            ["Claude Account 2, OK, 7 Day, 22% left, stale"]
        )
    }

    func testARevealedIdentifierTakesThePlaceOfTheAccountAlias() {
        let overview = statusOverview([
            report("anthropic", accountID: "claude-a", quotas: [
                quota("Claude 7 Day", windowLabel: "7 Day", status: .exhausted, remainingPercent: 0, resetsInMinutes: 561)
            ])
        ])

        XCTAssertEqual(
            overview.exhausted.map { $0.accessibilityLabel(accountLabel: "person@example.invalid", isStale: false, now: timestamp) },
            ["Claude person@example.invalid, 7 Day exhausted, resets in 9h 21m"]
        )
    }

    func testAResetThatPassedOrIsUnknownReadsAsSuch() {
        let overview = statusOverview([
            report("anthropic", accountID: "claude-a", quotas: [
                quota("Claude 7 Day", windowLabel: "7 Day", status: .exhausted, remainingPercent: 0, resetsInMinutes: -5)
            ]),
            report("anthropic", accountID: "claude-b", quotas: [
                quota("Claude 7 Day", windowLabel: "7 Day", status: .exhausted, remainingPercent: 0, resetsInMinutes: nil)
            ])
        ])

        XCTAssertEqual(
            overview.exhausted.map { $0.accessibilityLabel(accountLabel: "Account", isStale: false, now: timestamp) },
            ["Claude Account, 7 Day exhausted, reset passed · recheck", "Claude Account, 7 Day exhausted, reset unknown"]
        )
    }

    func testTheResetFigureAndCaptionFollowTheCountdown() {
        XCTAssertEqual(ResetCountdown.remaining("9h 21m").figure, "9h 21m")
        XCTAssertEqual(ResetCountdown.passed.figure, "Recheck")
        XCTAssertEqual(ResetCountdown.unknown.figure, "—")
        XCTAssertEqual(ResetCountdown.remaining("4d 14h").caption, "resets 4d 14h")
        XCTAssertEqual(ResetCountdown.passed.caption, "reset passed")
        XCTAssertEqual(ResetCountdown.unknown.caption, "reset unknown")
    }

    func testAGroupHeaderReadsItsTitleAndItsLineCount() {
        XCTAssertEqual(AccountStatus.exhausted.headerLabel(count: 2), "Exhausted, 2")
        XCTAssertEqual(AccountStatus.nearLimit.headerLabel(count: 1), "Near limit, 1")
        XCTAssertEqual(AccountStatus.ok.headerLabel(count: 6), "OK, 6")
    }

    func testTheDetailsLabelCountsTheLinesOfEachGroupThatNeedsAttention() {
        func overview(exhausted: Int, nearLimit: Int) -> StatusOverview {
            let outOfQuota = (0..<exhausted).map { index in
                report("anthropic", accountID: "out-\(index)", quotas: [quota("Claude 7 Day", windowLabel: "7 Day", status: .exhausted, remainingPercent: 0)])
            }
            let closeToTheLimit = (0..<nearLimit).map { index in
                report("openai-codex", accountID: "near-\(index)", quotas: [quota("7 days", windowLabel: "7 days", status: .nearLimit, remainingPercent: 3)])
            }
            let healthy = report("cursor", accountID: "fine", quotas: [quota("Cursor Models", windowLabel: "Monthly", remainingPercent: 80)])
            return statusOverview(outOfQuota + closeToTheLimit + [healthy])
        }

        XCTAssertEqual(overview(exhausted: 0, nearLimit: 0).detailsLabel, "Details · all OK")
        XCTAssertEqual(overview(exhausted: 2, nearLimit: 0).detailsLabel, "Details · 2 exhausted")
        XCTAssertEqual(overview(exhausted: 0, nearLimit: 3).detailsLabel, "Details · 3 near limit")
        XCTAssertEqual(overview(exhausted: 1, nearLimit: 4).detailsLabel, "Details · 1 exhausted, 4 near limit")
        XCTAssertEqual(overview(exhausted: 0, nearLimit: 0).detailsSpokenLabel, "Details, all OK")
        XCTAssertEqual(overview(exhausted: 1, nearLimit: 4).detailsSpokenLabel, "Details, 1 exhausted, 4 near limit")
    }

    // The container colors are the opaque panel colors the prototype measured behind each group, over a black and a gray backdrop.
    @MainActor
    func testEachInkReadsAtFourPointFiveToOneOnItsGroupInBothAppearances() throws {
        let containers: [(status: AccountStatus, dark: [Double], light: [Double])] = [
            (.exhausted, [61, 44, 43], [224, 206, 204]),
            (.nearLimit, [62, 52, 42], [225, 214, 204]),
            (.ok, [48, 48, 48], [214, 214, 214])
        ]

        for container in containers {
            let ink = StatusInk.nsColor(for: container.status)
            XCTAssertGreaterThanOrEqual(try contrast(of: ink, in: .darkAqua, against: container.dark), 4.5, "\(container.status) in the dark appearance")
            XCTAssertGreaterThanOrEqual(try contrast(of: ink, in: .aqua, against: container.light), 4.5, "\(container.status) in the light appearance")
        }
    }

    private var timestamp: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    private func statusOverview(_ reports: [UsageReportDraft]) -> StatusOverview {
        UsageSnapshot(generatedAt: timestamp, reportDrafts: reports).statusOverview()
    }

    private func report(_ provider: String, accountID: String, quotas: [UsageQuotaDraft]) -> UsageReportDraft {
        UsageReportDraft(
            provider: provider,
            sourceAccount: SourceAccountIdentity(accountID: accountID, organizationID: nil, projectID: nil),
            privateDisplayLabel: nil,
            fetchedAt: timestamp,
            resetCredits: nil,
            quotas: quotas
        )
    }

    private func quota(
        _ label: String,
        windowLabel: String,
        durationMilliseconds: Double? = 604_800_000,
        status: UsageLimitStatus = .available,
        remainingPercent: Double?,
        resetsInMinutes: Double? = nil
    ) -> UsageQuotaDraft {
        UsageQuotaDraft(
            id: label,
            label: label,
            scope: nil,
            window: QuotaWindow(
                identity: QuotaWindowIdentity(id: windowLabel),
                label: windowLabel,
                durationMilliseconds: durationMilliseconds,
                resetLabel: nil
            ),
            amount: remainingPercent.map {
                UsageAmount(used: 100 - $0, limit: 100, remaining: $0, usedFraction: (100 - $0) / 100, remainingFraction: $0 / 100, unit: .percent)
            },
            status: status,
            resetsAt: resetsInMinutes.map { timestamp.addingTimeInterval($0 * 60) }
        )
    }

    private func contrast(of ink: NSColor, in name: NSAppearance.Name, against background: [Double]) throws -> Double {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = ink.usingColorSpace(.sRGB) }
        let color = try XCTUnwrap(resolved)
        let foreground = luminance(Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
        let backdrop = luminance(background[0] / 255, background[1] / 255, background[2] / 255)
        return (max(foreground, backdrop) + 0.05) / (min(foreground, backdrop) + 0.05)
    }

    private func luminance(_ red: Double, _ green: Double, _ blue: Double) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

// Shaped like a real snapshot, with the reports of different providers interleaved. Five Claude accounts use 100%, 90%, 80%, 70% and 55%
// of their 7-day quota, three Codex accounts 97%, 88% and 96%, the Grok account 1%, and the Cursor account 100%.
// Every other quota sits at a value that would change a figure if it were picked.
enum RealisticFixture {
    static let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    // The first `unmeasuredClaudeAccounts` Claude accounts report no amounts at all.
    static func snapshot(unmeasuredClaudeAccounts: Int = 0) -> UsageSnapshot {
        let claude = [100.0, 90, 80, 70, 55].enumerated().map { index, weeklyUsed -> UsageReportDraft in
            let isMeasured = index >= unmeasuredClaudeAccounts
            return report("anthropic", "claude-\(index)", [
                quota("Claude 5 Hour", window: "5h", windowLabel: "5 Hour", duration: 18_000_000, used: isMeasured ? 100 : nil),
                quota("Claude 7 Day", window: "7d", windowLabel: "7 Day", duration: 604_800_000, used: isMeasured ? weeklyUsed : nil),
                quota("Claude 7 Day (Fable)", window: "7d", windowLabel: "7 Day", duration: 604_800_000, used: isMeasured ? 0 : nil)
            ])
        }
        let codex = [97.0, 88, 96].enumerated().map { index, used in
            report("openai-codex", "codex-\(index)", [quota("7 days", window: "7d", windowLabel: "7 days", duration: 604_800_000, used: used)])
        }
        let grok = report("xai-oauth", "grok-a", [
            quota("SuperGrok Weekly Credits", window: "1w", windowLabel: "Weekly", duration: 604_800_000, used: 1),
            quota("Grok Build (Weekly)", window: "1w", windowLabel: "Weekly", duration: 604_800_000, used: 1),
            quota("GrokTasks (Weekly)", window: "1w", windowLabel: "Weekly", duration: 604_800_000, used: 0)
        ])
        let cursor = report("cursor", "cursor-a", [
            quota("Cursor Models", window: "monthly", windowLabel: "Monthly", duration: nil, used: 100),
            quota("Other Models", window: "monthly", windowLabel: "Monthly", duration: nil, used: 100, unit: .usd)
        ])
        return UsageSnapshot(
            generatedAt: fetchedAt,
            reportDrafts: [cursor, codex[0], claude[0], grok, claude[1], codex[1], claude[2], claude[3], codex[2], claude[4]]
        )
    }

    private static func report(_ provider: String, _ accountID: String, _ quotas: [UsageQuotaDraft]) -> UsageReportDraft {
        UsageReportDraft(
            provider: provider,
            sourceAccount: SourceAccountIdentity(accountID: accountID, organizationID: nil, projectID: nil),
            privateDisplayLabel: nil,
            fetchedAt: fetchedAt,
            resetCredits: nil,
            quotas: quotas
        )
    }

    // `used` is a percentage of a limit of 100. A nil `used` leaves the quota without an amount.
    private static func quota(
        _ label: String,
        window: String,
        windowLabel: String,
        duration: Double?,
        used: Double?,
        unit: UsageUnit = .percent
    ) -> UsageQuotaDraft {
        UsageQuotaDraft(
            id: label,
            label: label,
            scope: nil,
            window: QuotaWindow(identity: QuotaWindowIdentity(id: window), label: windowLabel, durationMilliseconds: duration, resetLabel: nil),
            amount: used.map {
                UsageAmount(used: $0, limit: 100, remaining: 100 - $0, usedFraction: $0 / 100, remainingFraction: (100 - $0) / 100, unit: unit)
            },
            status: .available,
            resetsAt: nil
        )
    }
}
