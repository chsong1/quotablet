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
        XCTAssertEqual(usage.measured.map(\.report.sourceAccount?.accountID), ["codex-0", "codex-1", "codex-2"])
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
        let detail = try XCTUnwrap(snapshot.providerDetail(of: "anthropic", now: timestamp))

        XCTAssertEqual(usage.accountCount, 2)
        XCTAssertEqual(usage.measured.map(\.report.sourceAccount?.accountID), ["claude-a"])
        XCTAssertEqual(try XCTUnwrap(usage.usedFraction), 0.8, accuracy: 0.0001)
        XCTAssertEqual(usage.spokenSummary, "Claude 80% used across 1 of 2 accounts")
        XCTAssertEqual(detail.accounts.map(\.number), [1, 2])
        XCTAssertEqual(detail.accounts.map(\.capacityFraction), [0.8, nil])
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

    func testOnlyProvidersWithAReportOrAProblemAccountAreListed() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "cursor", accountID: "c"),
            report(provider: "anthropic", accountID: "a")
        ], accountProblems: [RealisticFixture.problem(provider: "xai-oauth")])

        XCTAssertEqual(snapshot.providerUsage(now: timestamp).map(\.provider), ["anthropic", "xai-oauth", "cursor"])
        XCTAssertEqual(UsageSnapshot(generatedAt: timestamp, reportDrafts: []).providerUsage(now: timestamp), [])
    }

    func testAProviderWithReportsAndProblemAccountsKeepsItsFigureAndCountsEachKindOfProblem() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [quota(id: "weekly", windowID: "7d", label: "Claude 7 Day", remainingPercent: 20)]),
            report(accountID: "claude-b", quotas: [quota(id: "weekly", windowID: "7d", label: "Claude 7 Day", remainingPercent: 40)])
        ], accountProblems: [
            RealisticFixture.problem(.disconnected),
            RealisticFixture.problem(.noUsageData),
            RealisticFixture.problem(.noUsageData),
            RealisticFixture.problem(.disconnected, provider: "openai-codex")
        ])

        let usage = try XCTUnwrap(snapshot.providerUsage(now: timestamp).first)

        XCTAssertEqual(usage.provider, "anthropic")
        XCTAssertEqual(usage.accountCount, 2)
        XCTAssertEqual(try XCTUnwrap(usage.usedFraction), 0.7, accuracy: 0.0001)
        XCTAssertEqual(usage.measured.map(\.report.sourceAccount?.accountID), ["claude-a", "claude-b"])
        XCTAssertEqual(usage.disconnectedCount, 1)
        XCTAssertEqual(usage.noUsageDataCount, 2)
        XCTAssertEqual(usage.problemCount, 3)
        XCTAssertEqual(usage.spokenSummary, "Claude 70% used across 2 accounts, 1 account needs sign-in, 2 accounts without usage data")
    }

    func testAProviderWithOnlyProblemAccountsHasNoFigureAndKeepsItsPlaceInTheRegistryOrder() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "cursor", accountID: "cursor-a"),
            report(provider: "openai-codex", accountID: "codex-a")
        ], accountProblems: [
            RealisticFixture.problem(provider: "xai-oauth"),
            RealisticFixture.problem(provider: "anthropic"),
            RealisticFixture.problem(provider: "anthropic"),
            RealisticFixture.problem(.noUsageData, provider: "mistral")
        ])

        let providers = snapshot.providerUsage(now: timestamp)
        let claude = try XCTUnwrap(providers.first)

        XCTAssertEqual(providers.map(\.provider), ["anthropic", "openai-codex", "xai-oauth", "cursor", "mistral"])
        XCTAssertEqual(providers.map(\.accountCount), [0, 1, 0, 1, 0])
        XCTAssertEqual(providers.map(\.problemCount), [2, 0, 1, 0, 1])
        XCTAssertTrue(claude.measured.isEmpty)
        XCTAssertNil(claude.usedFraction)
        XCTAssertFalse(claude.isStale)
        XCTAssertEqual(claude.attention, ProviderAttention(exhaustedAccounts: 0, nearLimitAccounts: 0))
        XCTAssertEqual(claude.spokenSummary, "Claude, 2 accounts need sign-in")
        XCTAssertEqual(providers.last?.spokenSummary, "mistral, 1 account without usage data")
    }

    func testAccountsAreNumberedFromOneAmongTheirProvidersReportsInReportOrder() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "openai-codex", accountID: "codex-a"),
            report(accountID: "claude-a"),
            report(provider: "openai-codex", accountID: "codex-b")
        ])

        let codex = try XCTUnwrap(snapshot.providerDetail(of: "openai-codex", now: timestamp))
        let claude = try XCTUnwrap(snapshot.providerDetail(of: "anthropic", now: timestamp))

        XCTAssertEqual(snapshot.providerUsage(now: timestamp).map(\.provider), ["anthropic", "openai-codex"])
        XCTAssertEqual(codex.accounts.map(\.number), [1, 2])
        XCTAssertEqual(codex.accounts.map(\.report.sourceAccount?.accountID), ["codex-a", "codex-b"])
        XCTAssertEqual(claude.accounts.map(\.number), [1])
    }

    func testAProviderIsStaleOnlyWhenEveryMeasuredAccountIsStale() {
        func isStale(_ accounts: [(fetchedSecondsAgo: TimeInterval, remaining: Double?)]) -> Bool? {
            let drafts = accounts.enumerated().map { index, account in
                report(
                    accountID: "acct-\(index)",
                    fetchedAt: timestamp.addingTimeInterval(-account.fetchedSecondsAgo),
                    quotas: [quota(id: "weekly", windowID: "7d", label: "Claude 7 Day", remainingPercent: account.remaining)]
                )
            }
            return UsageSnapshot(generatedAt: timestamp, reportDrafts: drafts).providerUsage(now: timestamp).first?.isStale
        }

        XCTAssertEqual(isStale([(899, 40)]), false)
        XCTAssertEqual(isStale([(900, 40)]), true)
        XCTAssertEqual(isStale([(3_600, 40), (3_600, 60)]), true)
        XCTAssertEqual(isStale([(3_600, 40), (60, 60)]), false)
        XCTAssertEqual(isStale([(899, 40), (899, 60)]), false)
        XCTAssertEqual(isStale([(900, 40), (900, 60)]), true)
        // An account with no figure adds nothing to the provider's figure, so its age is no reason to dim the figure.
        XCTAssertEqual(isStale([(3_600, 40), (60, nil)]), true)
        XCTAssertEqual(isStale([(3_600, nil), (60, 60)]), false)
        XCTAssertEqual(isStale([(3_600, nil), (3_600, nil)]), false)
    }

    func testAProviderPageMarksTheStaleAccountWhileTheProviderStaysFresh() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", fetchedAt: timestamp.addingTimeInterval(-3_600), quotas: [quota(id: "weekly", windowID: "7d", label: "Claude 7 Day", remainingPercent: 40)]),
            report(accountID: "claude-b", quotas: [quota(id: "weekly", windowID: "7d", label: "Claude 7 Day", remainingPercent: 60)])
        ])

        let detail = try XCTUnwrap(snapshot.providerDetail(of: "anthropic", now: timestamp))

        XCTAssertFalse(detail.usage.isStale)
        XCTAssertEqual(detail.accounts.map(\.isStale), [true, false])
        XCTAssertTrue(detail.hasStaleAccount)
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

    func testCountdownGivesTheTimeLeftPrintedAndSpokenAndSeparatesAPassedResetFromAnUnknownOne() {
        func countdown(minutes: Double) -> ResetCountdown {
            UsageFormatting.countdown(to: timestamp.addingTimeInterval(minutes * 60), now: timestamp)
        }

        XCTAssertEqual(countdown(minutes: 561), .remaining(compact: "9h 21m", spoken: "9 hours 21 minutes"))
        XCTAssertEqual(countdown(minutes: 5_242), .remaining(compact: "3d 15h", spoken: "3 days 15 hours"))
        XCTAssertEqual(countdown(minutes: 5_700), .remaining(compact: "3d 23h", spoken: "3 days 23 hours"))
        XCTAssertEqual(countdown(minutes: 0.5), .remaining(compact: "1m", spoken: "1 minute"))
        XCTAssertEqual(countdown(minutes: 59), .remaining(compact: "59m", spoken: "59 minutes"))
        XCTAssertEqual(countdown(minutes: 60), .remaining(compact: "1h 0m", spoken: "1 hour"))
        XCTAssertEqual(countdown(minutes: 61), .remaining(compact: "1h 1m", spoken: "1 hour 1 minute"))
        XCTAssertEqual(countdown(minutes: 1_440), .remaining(compact: "1d 0h", spoken: "1 day"))
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

    func testWindowsSpellOutTheirLengthForSpeech() {
        let quotas = builtQuotas(from: [
            quota(id: "weekly", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000, label: "Claude 7 Day"),
            quota(id: "fable", windowID: "7d-fable", windowLabel: "7 Day", durationMilliseconds: 604_800_000, label: "Claude 7 Day (Fable)"),
            quota(id: "session", windowID: "5h", windowLabel: "5 Hour", durationMilliseconds: 18_000_000, label: "Claude 5 Hour"),
            quota(id: "models", windowID: "monthly", durationMilliseconds: nil, label: "Cursor Models")
        ])

        XCTAssertEqual(quotas.map(UsageFormatting.spokenLabel(for:)), ["7 day", "7 day Fable", "5 hour", "Cursor Models"])
        XCTAssertEqual(UsageFormatting.spokenDuration(milliseconds: 3_600_000), "1 hour")
        XCTAssertEqual(UsageFormatting.spokenDuration(milliseconds: 129_600_000), "36 hour")
        XCTAssertEqual(UsageFormatting.spokenDuration(milliseconds: 5_400_000), "1.5 hour")
        XCTAssertEqual(UsageFormatting.spokenDuration(milliseconds: 1_800_000), "30 minute")
        XCTAssertEqual(UsageFormatting.spokenDuration(milliseconds: 45_000), "45 second")
        XCTAssertNil(UsageFormatting.spokenDuration(milliseconds: nil))
        XCTAssertNil(UsageFormatting.spokenDuration(milliseconds: 0))
    }

    func testAProviderCountsEachAccountOnceByItsMostUrgentQuota() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [
                quota(id: "session", status: .nearLimit, remainingPercent: 5),
                quota(id: "weekly", windowID: "7d", status: .exhausted, remainingPercent: 0)
            ]),
            report(accountID: "claude-b", quotas: [quota(id: "session", status: .nearLimit, remainingPercent: 8)]),
            report(accountID: "claude-c", quotas: [quota(id: "session", status: .nearLimit, remainingPercent: 9)]),
            report(accountID: "claude-d", quotas: [quota(id: "session", remainingPercent: 70)]),
            report(provider: "openai-codex", accountID: "codex-a", quotas: [quota(id: "weekly", windowID: "7d", status: .nearLimit, remainingPercent: 4)]),
            report(provider: "cursor", accountID: "cursor-a", quotas: [quota(id: "models", remainingPercent: 60)]),
            report(provider: "xai-oauth", accountID: "grok-a", quotas: [
                quota(id: "build", windowID: "1w", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: "Grok 7 Day (Build)", status: .exhausted, remainingPercent: nil)
            ])
        ])

        let attention = Dictionary(uniqueKeysWithValues: snapshot.providerUsage(now: timestamp).map { ($0.provider, $0.attention) })

        XCTAssertEqual(attention["anthropic"], ProviderAttention(exhaustedAccounts: 1, nearLimitAccounts: 2))
        XCTAssertEqual(attention["openai-codex"], ProviderAttention(exhaustedAccounts: 0, nearLimitAccounts: 1))
        XCTAssertEqual(attention["cursor"], ProviderAttention(exhaustedAccounts: 0, nearLimitAccounts: 0))
        // The scoped quota leaves the account unmeasured, and the account still counts.
        XCTAssertEqual(attention["xai-oauth"], ProviderAttention(exhaustedAccounts: 1, nearLimitAccounts: 0))
        XCTAssertEqual(attention["anthropic"]?.badge, AttentionBadge(urgency: .exhausted, count: 1))
        XCTAssertEqual(attention["openai-codex"]?.badge, AttentionBadge(urgency: .nearLimit, count: 1))
        XCTAssertNil(try XCTUnwrap(attention["cursor"]).badge)
        XCTAssertEqual(attention["anthropic"]?.spokenParts, ["1 exhausted", "2 near limit"])
    }

    func testEachAccountsPetalUsesTheQuotaTheProvidersFigureCountsForIt() throws {
        let detail = try XCTUnwrap(RealisticFixture.snapshot().providerDetail(of: "anthropic", now: RealisticFixture.fetchedAt))

        XCTAssertEqual(detail.accounts.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(detail.accounts.compactMap(\.capacityFraction), [1, 0.9, 0.8, 0.7, 0.55])
        XCTAssertEqual(try XCTUnwrap(detail.usage.usedFraction), 0.79, accuracy: 0.0001)
    }

    func testAccountsRankExhaustedByWhenTheyClearThenNearLimitThenTheRestMostUsedFirstWithTiesByNumber() throws {
        func weekly(_ status: UsageLimitStatus, remaining: Double?, resetsInHours: Double?) -> UsageQuotaDraft {
            quota(
                id: "weekly",
                windowID: "7d",
                durationMilliseconds: 604_800_000,
                resetsAt: resetsInHours.map { later(hours: $0) },
                label: "Claude 7 Day",
                status: status,
                remainingPercent: remaining
            )
        }
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            // The account stays blocked until its last exhausted quota resets, so this one clears in 100 hours and not 1.
            report(accountID: "a1", quotas: [
                quota(id: "session", resetsAt: later(hours: 1), label: "Claude 5 Hour", status: .exhausted, remainingPercent: 0),
                weekly(.exhausted, remaining: 0, resetsInHours: 100)
            ]),
            report(accountID: "a2", quotas: [weekly(.exhausted, remaining: 0, resetsInHours: 50)]),
            report(accountID: "a3", quotas: [quota(id: "session", label: "Claude 5 Hour", status: .exhausted, remainingPercent: 0)]),
            report(accountID: "a4", quotas: [weekly(.nearLimit, remaining: 8, resetsInHours: 70)]),
            report(accountID: "a5", quotas: [weekly(.nearLimit, remaining: 5, resetsInHours: 70)]),
            report(accountID: "a6", quotas: [weekly(.available, remaining: 40, resetsInHours: 70)]),
            report(accountID: "a7", quotas: [weekly(.available, remaining: 20, resetsInHours: 70)]),
            report(accountID: "a8", quotas: [weekly(.available, remaining: nil, resetsInHours: 70)]),
            report(accountID: "a9", quotas: [weekly(.available, remaining: 40, resetsInHours: 70)]),
            report(accountID: "a10", quotas: [weekly(.nearLimit, remaining: 5, resetsInHours: 70)]),
            report(accountID: "a11", quotas: [weekly(.exhausted, remaining: 0, resetsInHours: 50)])
        ])

        let detail = try XCTUnwrap(snapshot.providerDetail(of: "anthropic", now: timestamp))

        XCTAssertEqual(detail.accounts.map(\.number), Array(1...11))
        XCTAssertEqual(
            detail.accounts.map(\.clearsAt),
            [later(hours: 100), later(hours: 50), nil, nil, nil, nil, nil, nil, nil, nil, later(hours: 50)]
        )
        XCTAssertEqual(detail.accountsByUrgency.map(\.number), [2, 11, 1, 3, 5, 10, 4, 7, 6, 9, 8])
    }

    func testWindowsKeepTheirShortNamesAndOnlyCollidingQuotasTakeNamesFromTheirLabels() throws {
        func names(provider: String, _ quotas: [UsageQuotaDraft]) throws -> [String] {
            let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [report(provider: provider, accountID: "a", quotas: quotas)])
            return try XCTUnwrap(snapshot.providerDetail(of: provider, now: timestamp)).accounts[0].windows.map(\.name.short)
        }

        XCTAssertEqual(try names(provider: "anthropic", [
            quota(id: "session", windowID: "5h", windowLabel: "5 Hour", label: "Claude 5 Hour"),
            quota(id: "weekly", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000, label: "Claude 7 Day"),
            quota(id: "fable", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000, label: "Claude 7 Day (Fable)")
        ]), ["5h", "7d", "7d Fable"])
        XCTAssertEqual(try names(provider: "xai-oauth", [
            grokPool("SuperGrok Weekly Credits"), grokPool("Grok Build (Weekly)"), grokPool("GrokTasks (Weekly)"), grokPool("Grok Chat (Weekly)")
        ]), ["Credits", "Build", "Tasks", "Chat"])
        XCTAssertEqual(try names(provider: "xai-oauth", [
            quota(id: "session", windowID: "5h", windowLabel: "5 Hour", label: "Grok Session"),
            grokPool("Grok Build (Weekly)"),
            grokPool("GrokTasks (Weekly)")
        ]), ["5h", "Build", "Tasks"])
        XCTAssertEqual(try names(provider: "cursor", [
            quota(id: "models", windowID: "monthly", windowLabel: "Monthly", durationMilliseconds: nil, label: "Cursor Models"),
            quota(id: "other", windowID: "monthly", windowLabel: "Monthly", durationMilliseconds: nil, label: "Other Models")
        ]), ["Cursor Models", "Other Models"])
        // Quotas that nothing tells apart still get a column each.
        XCTAssertEqual(try names(provider: "cursor", [
            quota(id: "a", windowID: "monthly", windowLabel: "Monthly", durationMilliseconds: nil, label: "Cursor Models"),
            quota(id: "b", windowID: "monthly", windowLabel: "Monthly", durationMilliseconds: nil, label: "Cursor Models")
        ]), ["Models", "Models 2"])
    }

    func testACountedNameNeverTakesANameAnotherQuotaAlreadyHasSoEveryWindowKeepsItsColumn() throws {
        func columns(_ labels: [String]) throws -> (names: [String], columns: [String], cells: [Double?]) {
            let quotas = labels.enumerated().map { index, label in
                quota(id: "pool-\(index)", windowID: "1w", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: label, remainingPercent: Double(90 - index * 10))
            }
            let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [report(provider: "xai-oauth", accountID: "a", quotas: quotas)])
            let detail = try XCTUnwrap(snapshot.providerDetail(of: "xai-oauth", now: timestamp))
            let windows = detail.accounts[0].windows
            let cells = detail.windowColumns.map { column in windows.first { $0.name.short == column }?.usedFraction }
            return (windows.map(\.name.short), detail.windowColumns, cells)
        }

        let duplicateFirst = try columns(["Grok Build (Weekly)", "Grok Build (Weekly)", "Grok Build 2 (Weekly)"])
        XCTAssertEqual(duplicateFirst.names, ["Build", "Build 3", "Build 2"])
        XCTAssertEqual(duplicateFirst.columns, ["Build", "Build 3", "Build 2"])
        XCTAssertEqual(duplicateFirst.cells, [0.1, 0.2, 0.3])

        let numberedFirst = try columns(["Grok Build 2 (Weekly)", "Grok Build (Weekly)", "Grok Build (Weekly)"])
        XCTAssertEqual(numberedFirst.names, ["Build 2", "Build", "Build 3"])
        XCTAssertEqual(numberedFirst.cells, [0.1, 0.2, 0.3])
    }

    func testAWindowEntryCarriesItsUsedShareUrgencyAndResetTime() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "cursor", accountID: "cursor-a", quotas: [
                quota(id: "models", windowID: "monthly", windowLabel: "Monthly", durationMilliseconds: nil, resetsAt: later(hours: 20), label: "Cursor Models", status: .exhausted, remainingPercent: nil),
                quota(id: "other", windowID: "monthly", windowLabel: "Monthly", durationMilliseconds: nil, label: "Other Models", status: .nearLimit, remainingPercent: 9),
                quota(id: "idle", windowID: "monthly", windowLabel: "Monthly", durationMilliseconds: nil, label: "Idle Models", remainingPercent: 100),
                quota(id: "unknown", windowID: "monthly", windowLabel: "Monthly", durationMilliseconds: nil, label: "Unknown Models", remainingPercent: nil)
            ])
        ])

        let windows = try XCTUnwrap(snapshot.providerDetail(of: "cursor", now: timestamp)).accounts[0].windows

        XCTAssertEqual(windows.map(\.name.short), ["Cursor Models", "Other Models", "Idle Models", "Unknown Models"])
        XCTAssertEqual(windows.map(\.usedFraction), [1, 0.91, 0, nil])
        XCTAssertEqual(windows.map(\.urgency), [.exhausted, .nearLimit, nil, nil])
        XCTAssertEqual(windows.map(\.resetsAt), [later(hours: 20), nil, nil, nil])
    }

    func testAWindowReadsItsPercentAndCountdownOrOnlyTheCountdownWhenExhausted() {
        func reading(used: Double?, urgency: QuotaUrgency?, resetsInHours: Double?) -> WindowReading {
            WindowEntry(name: WindowName(short: "7d", spoken: "7 day"), usedFraction: used, urgency: urgency, resetsAt: resetsInHours.map { later(hours: $0) })
                .reading(now: timestamp)
        }

        XCTAssertEqual(reading(used: 0.91, urgency: .nearLimit, resetsInHours: 95), .used(percent: "91%", resetsIn: "3d 23h"))
        XCTAssertEqual(reading(used: 0.4, urgency: nil, resetsInHours: 5), .used(percent: "40%", resetsIn: "5h 0m"))
        XCTAssertEqual(reading(used: 1, urgency: .exhausted, resetsInHours: 50), .exhausted(resetsIn: "2d 2h"))
        XCTAssertEqual(reading(used: 1, urgency: .exhausted, resetsInHours: nil), .used(percent: "100%", resetsIn: nil))
        XCTAssertEqual(reading(used: 0, urgency: nil, resetsInHours: nil), .used(percent: "0%", resetsIn: nil))
        XCTAssertEqual(reading(used: nil, urgency: nil, resetsInHours: nil), .used(percent: "—", resetsIn: nil))
        XCTAssertEqual(reading(used: 0.4, urgency: nil, resetsInHours: -1), .used(percent: "40%", resetsIn: "Recheck"))
        XCTAssertEqual(reading(used: 1, urgency: .exhausted, resetsInHours: -1), .exhausted(resetsIn: "Recheck"))
    }

    func testRowsShareOneColumnForEachWindowNameInTheOrderTheyFirstAppear() throws {
        let session = quota(id: "session", windowID: "5h", windowLabel: "5 Hour", label: "Claude 5 Hour")
        let weekly = quota(id: "weekly", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000, label: "Claude 7 Day")
        let fable = quota(id: "fable", windowID: "7d-fable", windowLabel: "7 Day", durationMilliseconds: 604_800_000, label: "Claude 7 Day (Fable)")
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [session, weekly]),
            report(accountID: "claude-b", quotas: [weekly, fable])
        ])

        let detail = try XCTUnwrap(snapshot.providerDetail(of: "anthropic", now: timestamp))

        XCTAssertEqual(detail.windowColumns, ["5h", "7d", "7d Fable"])
    }

    func testAnAccountRowSpeaksItsStatusAndLeadsWithTheWindowsThatNeedAttention() throws {
        let session = quota(id: "session", windowID: "5h", windowLabel: "5 Hour", label: "Claude 5 Hour", remainingPercent: 100)
        let weekly = quota(id: "weekly", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000, resetsAt: later(hours: 95), label: "Claude 7 Day", status: .nearLimit, remainingPercent: 9)
        let fable = quota(id: "fable", windowID: "7d-fable", windowLabel: "7 Day", durationMilliseconds: 604_800_000, label: "Claude 7 Day (Fable)", remainingPercent: 22)
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [quota(id: "session", remainingPercent: 70)]),
            report(accountID: "claude-b", quotas: [session, weekly, fable]),
            report(accountID: "claude-c", fetchedAt: timestamp.addingTimeInterval(-3_600), quotas: [session, weekly, fable]),
            report(accountID: "claude-d", quotas: [
                session,
                quota(id: "fable", windowID: "7d-fable", windowLabel: "7 Day", durationMilliseconds: 604_800_000, label: "Claude 7 Day (Fable)", status: .nearLimit, remainingPercent: 9),
                quota(id: "weekly", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000, resetsAt: later(hours: 50), label: "Claude 7 Day", status: .exhausted, remainingPercent: 0)
            ])
        ])

        let accounts = try XCTUnwrap(snapshot.providerDetail(of: "anthropic", now: timestamp)).accounts

        XCTAssertEqual(accounts[0].accessibilityLabel(accountLabel: "Account 1", now: timestamp), "Account 1, 5 hour 30% used")
        XCTAssertEqual(
            accounts[1].accessibilityLabel(accountLabel: "Account 2", now: timestamp),
            "Account 2, near limit, 7 day 91% used, resets in 3 days 23 hours; 5 hour 0% used; 7 day Fable 78% used"
        )
        XCTAssertEqual(
            accounts[1].accessibilityLabel(accountLabel: "person@example.invalid", now: timestamp),
            "person@example.invalid, near limit, 7 day 91% used, resets in 3 days 23 hours; 5 hour 0% used; 7 day Fable 78% used"
        )
        XCTAssertEqual(
            accounts[2].accessibilityLabel(accountLabel: "Account 3", now: timestamp),
            "Account 3, near limit, 7 day 91% used, resets in 3 days 23 hours; 5 hour 0% used; 7 day Fable 78% used, stale"
        )
        XCTAssertEqual(
            accounts[3].accessibilityLabel(accountLabel: "Account 4", now: timestamp),
            "Account 4, exhausted, 7 day 100% used, resets in 2 days 2 hours; 7 day Fable 91% used; 5 hour 0% used"
        )
    }

    func testThePanelRouteFallsBackToTheFlowerWhenItsProviderLeavesTheSnapshot() {
        let both = UsageSnapshot(generatedAt: timestamp, reportDrafts: [report(accountID: "claude-a"), report(provider: "openai-codex", accountID: "codex-a")])
        let codexOnly = UsageSnapshot(generatedAt: timestamp, reportDrafts: [report(provider: "openai-codex", accountID: "codex-a")])
        let empty = UsageSnapshot(generatedAt: timestamp, reportDrafts: [])
        let claude = PanelRoute.provider("anthropic")

        XCTAssertEqual(claude.resolved(in: both), .provider("anthropic"))
        XCTAssertEqual(claude.resolved(in: codexOnly), .flower)
        XCTAssertEqual(claude.resolved(in: empty), .flower)
        XCTAssertEqual(claude.resolved(in: nil), .flower)
        XCTAssertEqual(PanelRoute.provider("openai-codex").resolved(in: codexOnly), .provider("openai-codex"))
        XCTAssertEqual(PanelRoute.flower.resolved(in: codexOnly), .flower)
    }

    func testAPageStaysOpenForAProviderThatOnlyAProblemAccountNamesAndSuchASnapshotIsNotEmpty() {
        let problemsOnly = UsageSnapshot(generatedAt: timestamp, reportDrafts: [report(provider: "openai-codex", accountID: "codex-a")], accountProblems: [RealisticFixture.problem()])

        XCTAssertEqual(PanelRoute.provider("anthropic").resolved(in: problemsOnly), .provider("anthropic"))
        XCTAssertEqual(PanelRoute.provider("cursor").resolved(in: problemsOnly), .flower)
        XCTAssertTrue(UsageSnapshot(generatedAt: timestamp, reportDrafts: []).isEmpty)
        XCTAssertFalse(UsageSnapshot(generatedAt: timestamp, reportDrafts: [], accountProblems: [RealisticFixture.problem()]).isEmpty)
        XCTAssertFalse(UsageSnapshot(generatedAt: timestamp, reportDrafts: [report(accountID: "claude-a")]).isEmpty)
    }

    func testNoProviderPageExistsForAProviderThatNoReportAndNoProblemAccountNames() {
        let snapshot = UsageSnapshot(
            generatedAt: timestamp,
            reportDrafts: [report(accountID: "claude-a")],
            accountProblems: [RealisticFixture.problem(provider: "xai-oauth")]
        )

        XCTAssertNotNil(snapshot.providerDetail(of: "anthropic", now: timestamp))
        XCTAssertNotNil(snapshot.providerDetail(of: "xai-oauth", now: timestamp))
        XCTAssertNil(snapshot.providerDetail(of: "openai-codex", now: timestamp))
    }

    func testAProviderPageListsEachProblemAccountInOMPOrderAndNumbersThemWithinTheirKind() throws {
        let since = timestamp.addingTimeInterval(-(3 * 3_600 + 12 * 60))
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [], accountProblems: [
            RealisticFixture.problem(.disconnected, reason: "Refresh token not found or invalid", since: since),
            RealisticFixture.problem(.noUsageData, label: "second@example.invalid"),
            RealisticFixture.problem(.disconnected, label: "third@example.invalid"),
            RealisticFixture.problem(provider: "openai-codex")
        ])

        let detail = try XCTUnwrap(snapshot.providerDetail(of: "anthropic", now: timestamp))
        let labels = detail.problems.map { $0.label(revealing: false) }

        XCTAssertTrue(detail.accounts.isEmpty)
        XCTAssertEqual(detail.usage.usedText, "—")
        XCTAssertEqual(detail.problems.map(\.number), [1, 2, 3])
        XCTAssertEqual(labels, ["Disconnected account 1", "Account without usage data", "Disconnected account 2"])
        XCTAssertEqual(detail.problems.map { $0.label(revealing: true) }, ["Disconnected account 1", "second@example.invalid", "third@example.invalid"])
        XCTAssertEqual(detail.problems.map { $0.sinceText(now: timestamp) }, ["since 3h 12m ago", nil, nil])
        XCTAssertEqual(
            detail.problems[0].accessibilityLabel(label: labels[0], now: timestamp),
            "Disconnected account 1, Refresh token not found or invalid, since 3h 12m ago, Sign in again in OMP"
        )
        XCTAssertEqual(
            detail.problems[1].accessibilityLabel(label: labels[1], now: timestamp),
            "Account without usage data, Signed in, but OMP returned no usage"
        )
        XCTAssertEqual(
            detail.problems[2].accessibilityLabel(label: "third@example.invalid", now: timestamp),
            "third@example.invalid, Sign in again in OMP"
        )
    }

    func testAProblemRowSaysJustNowWhenOMPDisabledTheAccountUnderAMinuteAgo() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [], accountProblems: [
            RealisticFixture.problem(since: timestamp.addingTimeInterval(-20)),
            RealisticFixture.problem(since: timestamp.addingTimeInterval(60))
        ])

        let problems = try XCTUnwrap(snapshot.providerDetail(of: "anthropic", now: timestamp)).problems

        XCTAssertEqual(problems.map { $0.sinceText(now: timestamp) }, ["since just now", "since just now"])
    }

    func testAnAccountRowSpeaksItsResetCreditsAfterEverythingElse() throws {
        let session = quota(id: "session", remainingPercent: 70)
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [session]),
            report(accountID: "claude-b", resetCredits: 0, quotas: [session]),
            report(accountID: "claude-c", resetCredits: 1, quotas: [session]),
            report(accountID: "claude-d", fetchedAt: timestamp.addingTimeInterval(-3_600), resetCredits: 2, quotas: [session])
        ])

        let accounts = try XCTUnwrap(snapshot.providerDetail(of: "anthropic", now: timestamp)).accounts

        XCTAssertEqual(accounts.map(\.resetCredits), [nil, nil, 1, 2])
        XCTAssertEqual(accounts[0].accessibilityLabel(accountLabel: "Account 1", now: timestamp), "Account 1, 5 hour 30% used")
        XCTAssertEqual(accounts[1].accessibilityLabel(accountLabel: "Account 2", now: timestamp), "Account 2, 5 hour 30% used")
        XCTAssertEqual(accounts[2].accessibilityLabel(accountLabel: "Account 3", now: timestamp), "Account 3, 5 hour 30% used, 1 reset credit available")
        XCTAssertEqual(
            accounts[3].accessibilityLabel(accountLabel: "Account 4", now: timestamp),
            "Account 4, 5 hour 30% used, stale, 2 reset credits available"
        )
    }

    func testTheHeaderSaysHowOldTheDataIsAndWhatTheRefreshIsDoing() {
        func text(_ status: CollectionStatus, after seconds: TimeInterval) -> String {
            status.text(now: timestamp.addingTimeInterval(seconds))
        }
        let live = CollectionStatus.snapshot(.live, dataDate: timestamp, refresh: .idle)

        XCTAssertEqual(text(live, after: 0), "Updated just now")
        XCTAssertEqual(text(live, after: 59), "Updated just now")
        XCTAssertEqual(text(live, after: 60), "Updated 1m ago")
        XCTAssertEqual(text(live, after: 180), "Updated 3m ago")
        XCTAssertEqual(text(live, after: 7_500), "Updated 2h 5m ago")
        XCTAssertEqual(text(live, after: 90_000), "Updated 1d 1h ago")
        XCTAssertEqual(text(live, after: 7_200), "Updated 2h ago")
        XCTAssertEqual(text(live, after: 86_400), "Updated 1d ago")
        XCTAssertEqual(text(live, after: -30), "Updated just now")
        XCTAssertEqual(text(.snapshot(.cached, dataDate: timestamp, refresh: .idle), after: 7_500), "Saved snapshot · updated 2h 5m ago")
        XCTAssertEqual(text(.snapshot(.live, dataDate: timestamp, refresh: .refreshing), after: 180), "Refreshing · updated 3m ago")
        XCTAssertEqual(text(.snapshot(.cached, dataDate: timestamp, refresh: .refreshing), after: 7_500), "Refreshing · updated 2h 5m ago")
        XCTAssertEqual(text(.snapshot(.cached, dataDate: timestamp, refresh: .failed), after: 7_500), "Refresh failed · data from 2h 5m ago")
        XCTAssertEqual(text(.snapshot(.live, dataDate: timestamp, refresh: .failed), after: 20), "Refresh failed · data from just now")
        XCTAssertEqual(text(.noSnapshot(.idle), after: 0), "Waiting for OMP")
        XCTAssertEqual(text(.noSnapshot(.refreshing), after: 0), "Refreshing OMP")
        XCTAssertEqual(text(.noSnapshot(.failed), after: 0), "Refresh failed")
    }

    func testASnapshotsOldestReportIsTheOldestFetchTimeAndNilWhenNoReportSaysWhen() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "a", fetchedAt: timestamp.addingTimeInterval(-600)),
            report(accountID: "b", fetchedAt: timestamp.addingTimeInterval(-7_200)),
            report(accountID: "c", fetchedAt: timestamp)
        ])

        XCTAssertEqual(snapshot.oldestReportFetchedAt, timestamp.addingTimeInterval(-7_200))
        XCTAssertNil(UsageSnapshot(generatedAt: timestamp, reportDrafts: [], accountProblems: [RealisticFixture.problem()]).oldestReportFetchedAt)
    }

    func testOnlyTheGrokNamespaceReadsAsASharedPoolWithProductUsage() {
        let quotas = builtQuotas(from: [
            quota(id: "xai-oauth:credits:1w", windowID: "1w", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: "SuperGrok Weekly Credits"),
            quota(id: "xai-oauth:product:cursor:1w", windowID: "1w", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: "Cursor (Weekly)"),
            quota(id: "xai-oauth:included:1mo", windowID: "1mo", windowLabel: "Monthly", durationMilliseconds: 2_592_000_000, label: "SuperGrok Monthly Included"),
            quota(id: "xai-oauth:on-demand", windowID: nil, label: "On-demand"),
            // An older fixture or snapshot names a quota by its label, and another provider's id that looks like a product row is none.
            quota(id: "SuperGrok Weekly Credits", windowID: "1w", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: "SuperGrok Weekly Credits"),
            quota(id: "mistral:product:chat:1w", windowID: "1w", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: "Chat (Weekly)")
        ])

        XCTAssertEqual(quotas.map(\.isSharedPool), [true, false, false, false, false, false])
        XCTAssertEqual(quotas.map(\.isProductUsage), [false, true, false, false, false, false])
    }

    func testAProductIsNamedByItsLabelWithoutTheParentheticalThatRestatesTheWindow() {
        let quotas = builtQuotas(from: [
            quota(id: "xai-oauth:product:cursor:1w", windowID: "1w", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: "Cursor (Weekly)"),
            quota(id: "xai-oauth:product:grok-build:1w", windowID: "1w", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: "Grok Build (weekly)"),
            quota(id: "xai-oauth:product:api:1w", windowID: "1w", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: "API"),
            quota(id: "xai-oauth:product:other:1w", windowID: "1w", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: "Other (Pro)")
        ])

        XCTAssertEqual(quotas.map(\.productName), ["Cursor", "Grok Build", "API", "Other (Pro)"])
    }

    func testProductUsageNeverStandsForAnAccountWhateverItsShare() throws {
        // A product above its pool is what the longest-window, most-used rule gets wrong: it would pick the product and report 95%.
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            RealisticFixture.sharedPoolGrok(pool: 20, products: [("Cursor", 95), ("GrokBot", 1), ("API", 1)])
        ])

        let usage = try XCTUnwrap(snapshot.providerUsage(now: timestamp).first)
        let account = try XCTUnwrap(snapshot.providerDetail(of: "xai-oauth", now: timestamp)).accounts[0]

        XCTAssertEqual(usage.measured.map(\.quota.limitID), ["xai-oauth:credits:1w"])
        XCTAssertEqual(try XCTUnwrap(usage.usedFraction), 0.2, accuracy: 0.0001)
        XCTAssertEqual(usage.spokenSummary, "Grok 20% used, 1 account")
        XCTAssertEqual(account.capacityFraction, 0.2)
        XCTAssertEqual(account.mostUsedFraction, 0.2)
    }

    func testProductUsageIsNotCountedAgainInTheFigureOfAProviderWithSeveralAccounts() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            RealisticFixture.sharedPoolGrok(accountID: "grok-a", pool: 20, products: [("Cursor", 18), ("GrokBot", 1), ("API", 1)]),
            RealisticFixture.sharedPoolGrok(accountID: "grok-b", pool: 60, products: [("Cursor", 90), ("API", 10)])
        ])

        let usage = try XCTUnwrap(snapshot.providerUsage(now: timestamp).first)

        // The mean of the two pools. Taking the largest row of each account would give 55%, and adding the products on top of the pools would give 70%.
        XCTAssertEqual(try XCTUnwrap(usage.usedFraction), 0.4, accuracy: 0.0001)
        XCTAssertEqual(usage.accountCount, 2)
        XCTAssertEqual(usage.measured.map(\.quota.limitID), ["xai-oauth:credits:1w", "xai-oauth:credits:1w"])
    }

    func testAGrokProductNamedCursorLeavesTheCursorProviderAndItsAccountsAlone() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            RealisticFixture.sharedPoolGrok(pool: 24, products: [("Cursor", 22), ("GrokBot", 1), ("API", 1)]),
            report(provider: "cursor", accountID: "cursor-a", quotas: [
                quota(id: "cursor:usd:individual-auto", windowID: "monthly", windowLabel: "Monthly", durationMilliseconds: nil, label: "Cursor Models", remainingPercent: 90)
            ])
        ])

        let providers = snapshot.providerUsage(now: timestamp)
        let cursor = try XCTUnwrap(snapshot.providerDetail(of: "cursor", now: timestamp))

        // No field joins the Grok account to the Cursor one, so each stays what its own report says.
        XCTAssertEqual(providers.map(\.provider), ["xai-oauth", "cursor"])
        XCTAssertEqual(providers.map(\.accountCount), [1, 1])
        XCTAssertEqual(try XCTUnwrap(providers[0].usedFraction), 0.24, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(providers[1].usedFraction), 0.1, accuracy: 0.0001)
        XCTAssertTrue(cursor.accounts[0].productUsage.isEmpty)
        XCTAssertEqual(cursor.accounts[0].windows.map(\.name.short), ["Cursor Models"])
    }

    func testTheSharedPoolOutranksTheLegacyMonthlyCounterBesideItAndTheCounterAloneStillStandsForTheAccount() throws {
        let monthly = quota(
            id: "xai-oauth:included:1mo",
            windowID: "1mo",
            windowLabel: "Monthly",
            durationMilliseconds: 2_592_000_000,
            label: "SuperGrok Monthly Included",
            remainingPercent: 30
        )
        let unified = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            RealisticFixture.sharedPoolGrok(pool: 20, extra: [monthly])
        ])
        let legacy = UsageSnapshot(generatedAt: timestamp, reportDrafts: [report(provider: "xai-oauth", accountID: "grok-a", quotas: [monthly])])

        // The monthly counter is longer and more used, so the longest-window rule alone would pick it over the pool OMP's own policy prefers.
        XCTAssertEqual(try XCTUnwrap(unified.providerUsage(now: timestamp).first).measured.map(\.quota.limitID), ["xai-oauth:credits:1w"])
        XCTAssertEqual(try XCTUnwrap(unified.providerUsage(now: timestamp).first?.usedFraction), 0.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(legacy.providerUsage(now: timestamp).first).measured.map(\.quota.limitID), ["xai-oauth:included:1mo"])
        XCTAssertEqual(try XCTUnwrap(legacy.providerUsage(now: timestamp).first?.usedFraction), 0.7, accuracy: 0.0001)
    }

    func testAReportOfOnlyProductUsageLeavesTheAccountUnmeasuredWithoutSummingItsProducts() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            RealisticFixture.sharedPoolGrok(pool: nil, products: [("Cursor", 22), ("API", 1)])
        ])

        let usage = try XCTUnwrap(snapshot.providerUsage(now: timestamp).first)
        let account = try XCTUnwrap(snapshot.providerDetail(of: "xai-oauth", now: timestamp)).accounts[0]

        XCTAssertTrue(usage.measured.isEmpty)
        XCTAssertNil(usage.usedFraction)
        XCTAssertEqual(usage.spokenSummary, "Grok usage unknown, 1 account")
        XCTAssertTrue(account.windows.isEmpty)
        XCTAssertEqual(account.productUsage.map(\.phrase), ["Cursor 22%", "API 1%"])
    }

    func testProductUsageNeverFlagsAnAccountAndTheSharedPoolStillDoes() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            // A product at 100% inside a pool at 40% is a figure to show. It has no limit to run out of.
            RealisticFixture.sharedPoolGrok(accountID: "grok-a", pool: 40, products: [("Cursor", 100)]),
            RealisticFixture.sharedPoolGrok(accountID: "grok-b", pool: 100, products: [("Cursor", 60)])
        ])

        let usage = try XCTUnwrap(snapshot.providerUsage(now: timestamp).first)
        let accounts = try XCTUnwrap(snapshot.providerDetail(of: "xai-oauth", now: timestamp)).accounts

        XCTAssertEqual(snapshot.reports.map(\.accountStatus), [.ok, .exhausted])
        XCTAssertEqual(usage.attention, ProviderAttention(exhaustedAccounts: 1, nearLimitAccounts: 0))
        XCTAssertEqual(accounts.map(\.urgency), [nil, .exhausted])
    }

    func testAProviderPageShowsTheSharedPoolWithItsProductUsageBeneathIt() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            RealisticFixture.sharedPoolGrok(pool: 24, products: [("Cursor", 22), ("GrokBot", 1), ("API", 1)])
        ])

        let detail = try XCTUnwrap(snapshot.providerDetail(of: "xai-oauth", now: timestamp))
        let account = detail.accounts[0]

        // The pool is the only window. The products are not columns of their own, and no remaining amount is made up for them.
        XCTAssertEqual(detail.windowColumns, ["Shared pool"])
        XCTAssertEqual(account.windows.map(\.name.spoken), ["7 day shared pool"])
        XCTAssertEqual(account.windows.map(\.usedFraction), [0.24])
        XCTAssertEqual(account.productUsage.map(\.name), ["Cursor", "GrokBot", "API"])
        XCTAssertEqual(account.productUsage.map(\.usedFraction), [0.22, 0.01, 0.01])
        XCTAssertEqual(account.productUsageSummary, "Cursor 22% · GrokBot 1% · API 1%")
        XCTAssertEqual(
            account.accessibilityLabel(accountLabel: "Account 1", now: timestamp),
            "Account 1, 7 day shared pool 24% used, resets in 5 days 18 hours, product usage reported by OMP: Cursor 22%; GrokBot 1%; API 1%"
        )
    }

    func testGrokAccountsOnTheSharedPoolAndTheOlderShapeAndOtherProvidersMeasureSideBySide() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            RealisticFixture.sharedPoolGrok(accountID: "grok-new", pool: 20, products: [("Cursor", 95)]),
            // The older shape: ids that are only labels, and no scope. Its longest-window, most-used rule is kept.
            report(provider: "xai-oauth", accountID: "grok-old", quotas: [
                quota(id: "SuperGrok Weekly Credits", windowID: "1w", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: "SuperGrok Weekly Credits", remainingPercent: 40),
                quota(id: "Grok Build (Weekly)", windowID: "1w", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: "Grok Build (Weekly)", remainingPercent: 10)
            ]),
            // Looks like a product row, but no other provider is known to report a shared pool.
            report(provider: "mistral", accountID: "mistral-a", quotas: [
                quota(
                    id: "mistral:product:chat:1w",
                    windowID: "1w",
                    windowLabel: "Weekly",
                    durationMilliseconds: 604_800_000,
                    scope: QuotaScope(provider: "mistral", accountID: nil, organizationID: nil, projectID: nil, modelID: nil, tier: nil, windowID: "1w", shared: true),
                    label: "Chat (Weekly)",
                    remainingPercent: 5
                )
            ]),
            report(provider: "cursor", accountID: "cursor-a", quotas: [
                quota(id: "cursor:usd:individual-auto", windowID: "monthly", windowLabel: "Monthly", durationMilliseconds: nil, label: "Cursor Models", remainingPercent: 70)
            ])
        ])

        let providers = Dictionary(uniqueKeysWithValues: snapshot.providerUsage(now: timestamp).map { ($0.provider, $0) })
        let grok = try XCTUnwrap(snapshot.providerDetail(of: "xai-oauth", now: timestamp))

        XCTAssertEqual(providers["xai-oauth"]?.measured.map(\.quota.limitID), ["xai-oauth:credits:1w", "Grok Build (Weekly)"])
        XCTAssertEqual(try XCTUnwrap(providers["xai-oauth"]?.usedFraction), 0.55, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(providers["mistral"]?.usedFraction), 0.95, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(providers["cursor"]?.usedFraction), 0.3, accuracy: 0.0001)
        XCTAssertEqual(grok.accounts.map(\.windows).map { $0.map(\.name.short) }, [["Shared pool"], ["Credits", "Build"]])
        XCTAssertEqual(grok.accounts.map { $0.productUsage.map(\.phrase) }, [["Cursor 95%"], []])
        XCTAssertTrue(try XCTUnwrap(snapshot.providerDetail(of: "mistral", now: timestamp)).accounts[0].productUsage.isEmpty)
    }

    func testGrokReportsThatClaimOneSourceIdentityStaySeparateAndEachKeepsItsOwnProductUsage() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            RealisticFixture.sharedPoolGrok(accountID: "grok-claimed-twice", pool: 20, products: [("Cursor", 10)]),
            RealisticFixture.sharedPoolGrok(accountID: "grok-claimed-twice", pool: 40, products: [("Cursor", 30)])
        ])

        for report in snapshot.reports {
            guard case .transient = report.accountIdentity else {
                XCTFail("An identity that two reports claim names neither of them.")
                return
            }
        }
        let usage = try XCTUnwrap(snapshot.providerUsage(now: timestamp).first)
        let accounts = try XCTUnwrap(snapshot.providerDetail(of: "xai-oauth", now: timestamp)).accounts

        XCTAssertEqual(usage.accountCount, 2)
        XCTAssertEqual(try XCTUnwrap(usage.usedFraction), 0.3, accuracy: 0.0001)
        XCTAssertEqual(accounts.map { $0.productUsage.map(\.phrase) }, [["Cursor 10%"], ["Cursor 30%"]])
    }

    func testAScopeTierNarrowsAClaudeOrCodexQuotaWhateverItsLabelSaysButNotAnotherProvidersPlanTier() throws {
        // As OMP flags them: Claude's whole windows are shared and its meters are not, while a Codex meter is shared like the rest.
        func scope(_ provider: String, tier: String?, shared: Bool?) -> QuotaScope {
            QuotaScope(provider: provider, accountID: nil, organizationID: nil, projectID: nil, modelID: nil, tier: tier, windowID: "7d", shared: shared)
        }
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "anthropic", accountID: "claude-a", quotas: [
                quota(id: "anthropic:7d", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000, scope: scope("anthropic", tier: nil, shared: true), label: "Claude 7 Day", remainingPercent: 70),
                // The scope names the meter and the label does not, so there is no parenthetical for the label rule to read.
                quota(id: "anthropic:7d:fable", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000, scope: scope("anthropic", tier: "fable", shared: nil), label: "Claude 7 Day Fable", remainingPercent: 5)
            ]),
            report(provider: "openai-codex", accountID: "codex-a", quotas: [
                quota(id: "openai-codex:primary", windowID: "7d", windowLabel: "7 days", durationMilliseconds: 604_800_000, scope: scope("openai-codex", tier: nil, shared: true), label: "7 days", remainingPercent: 60),
                quota(id: "openai-codex:spark:primary", windowID: "7d", windowLabel: "7 days", durationMilliseconds: 604_800_000, scope: scope("openai-codex", tier: "spark", shared: true), label: "7 days Spark", remainingPercent: 2)
            ]),
            // The tier of another provider is the name of its plan. It narrows nothing, so the most used window still stands for the account.
            report(provider: "devin", accountID: "devin-a", quotas: [
                quota(id: "daily", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000, scope: scope("devin", tier: "Pro", shared: nil), label: "Weekly Quota", remainingPercent: 40)
            ])
        ])

        let providers = Dictionary(uniqueKeysWithValues: snapshot.providerUsage(now: timestamp).map { ($0.provider, $0) })

        XCTAssertEqual(providers["anthropic"]?.measured.map(\.quota.limitID), ["anthropic:7d"])
        XCTAssertEqual(try XCTUnwrap(providers["anthropic"]?.usedFraction), 0.3, accuracy: 0.0001)
        XCTAssertEqual(providers["openai-codex"]?.measured.map(\.quota.limitID), ["openai-codex:primary"])
        XCTAssertEqual(providers["devin"]?.measured.map(\.quota.limitID), ["daily"])
        XCTAssertEqual(try XCTUnwrap(providers["devin"]?.usedFraction), 0.6, accuracy: 0.0001)
    }

    func testAQuotaInDollarsShowsItsAmountsBesideItsShareAndNeverMixesWithPercentOrOtherUnits() throws {
        let us = Locale(identifier: "en_US")
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            // Shaped like Cursor in OMP 18.12.3: a share with no budget, and a budget in dollars.
            report(provider: "cursor", accountID: "cursor-a", quotas: [
                quota(id: "cursor:usd:individual-auto", windowID: "monthly", windowLabel: "Monthly", durationMilliseconds: nil, label: "Cursor Models", remainingPercent: 100),
                amountQuota(used: 12.4, limit: 553.95)
            ])
        ])

        let account = try XCTUnwrap(snapshot.providerDetail(of: "cursor", now: timestamp)).accounts[0]

        XCTAssertEqual(account.windows.map(\.money?.used), [nil, 12.4])
        XCTAssertEqual(account.windows.map { $0.money?.text(locale: us) }, [nil, "$12.40 of $553.95"])
        XCTAssertEqual(account.windows.map(\.usedFraction)[0], 0)
        XCTAssertEqual(try XCTUnwrap(account.windows[1].usedFraction), 12.4 / 553.95, accuracy: 0.0001)
        let spent = try XCTUnwrap(account.windows[1].money)
        XCTAssertEqual(
            account.accessibilityLabel(accountLabel: "Account 1", now: timestamp),
            "Account 1, Cursor Models 0% used; Credits 2% used, \(spent.text())"
        )

        func money(_ unit: UsageUnit, used: Double? = 3, limit: Double? = 10, remaining: Double? = nil) -> MoneyUsage? {
            MoneyUsage(UsageAmount(used: used, limit: limit, remaining: remaining, usedFraction: nil, remainingFraction: nil, unit: unit))
        }
        // Only a unit named USD is money. OMP names the unit of Grok's on-demand amount "unknown", so it shows only as a share.
        XCTAssertNil(MoneyUsage(nil))
        XCTAssertNil(money(.percent))
        XCTAssertNil(money(.unknown("unknown")))
        XCTAssertNil(money(.missing))
        XCTAssertNil(money(.usd, used: -1))
        XCTAssertEqual(money(.usd, used: nil, limit: 100, remaining: 40)?.used, 60)
        XCTAssertEqual(money(.usd, limit: nil)?.text(locale: us), "$3.00 used")
        XCTAssertEqual(money(.usd, used: 1250, limit: 1250)?.text(locale: us), "$1,250.00 of $1,250.00")

        // A budget in dollars and a share in percent are not one quantity, so two accounts of them average their shares:
        // pooled, 50 of 100 and 30 of 300 would add percent to dollars and give 20%.
        let mixed = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "cursor", accountID: "cursor-a", quotas: [amountQuota(used: 50, limit: 100, unit: .percent)]),
            report(provider: "cursor", accountID: "cursor-b", quotas: [amountQuota(used: 30, limit: 300, unit: .usd)])
        ])
        XCTAssertEqual(try XCTUnwrap(mixed.providerUsage(now: timestamp).first?.usedFraction), 0.3, accuracy: 0.0001)
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
        fetchedAt: Date? = nil,
        resetCredits: Int? = nil,
        quotas: [UsageQuotaDraft]? = nil
    ) -> UsageReportDraft {
        UsageReportDraft(
            provider: provider,
            sourceAccount: SourceAccountIdentity(accountID: accountID, organizationID: organizationID, projectID: projectID),
            privateDisplayLabel: label,
            fetchedAt: fetchedAt ?? timestamp,
            resetCredits: resetCredits,
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

    private func grokPool(_ label: String) -> UsageQuotaDraft {
        quota(id: label, windowID: "1w", windowLabel: "Weekly", durationMilliseconds: 604_800_000, label: label, remainingPercent: 60)
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

final class StatusInkTests: XCTestCase {
    // The container colors are the opaque panel colors the prototype measured behind each status row, over a black and a gray backdrop.
    @MainActor
    func testEachInkReadsAtFourPointFiveToOneOnItsRowInBothAppearances() throws {
        let containers: [(status: AccountStatus, dark: ColorProbe.RGB, light: ColorProbe.RGB)] = [
            (.exhausted, ColorProbe.RGB(bytes: 61, 44, 43), ColorProbe.RGB(bytes: 224, 206, 204)),
            (.nearLimit, ColorProbe.RGB(bytes: 62, 52, 42), ColorProbe.RGB(bytes: 225, 214, 204)),
            (.ok, ColorProbe.RGB(bytes: 48, 48, 48), ColorProbe.RGB(bytes: 214, 214, 214))
        ]

        for container in containers {
            let ink = StatusInk.nsColor(for: container.status)
            let dark = ColorProbe.contrast(try ColorProbe.resolve(ink, in: .darkAqua), container.dark)
            let light = ColorProbe.contrast(try ColorProbe.resolve(ink, in: .aqua), container.light)
            XCTAssertGreaterThanOrEqual(dark, 4.5, "\(container.status) in the dark appearance")
            XCTAssertGreaterThanOrEqual(light, 4.5, "\(container.status) in the light appearance")
        }
    }
}

// Reads a color the way the panel draws it, which is resolved in one appearance and as sRGB.
enum ColorProbe {
    struct RGB {
        let red: Double
        let green: Double
        let blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(bytes red: Double, _ green: Double, _ blue: Double) {
            self.init(red: red / 255, green: green / 255, blue: blue / 255)
        }

        var luminance: Double {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        var saturation: Double {
            let high = max(red, green, blue)
            return high == 0 ? 0 : (high - min(red, green, blue)) / high
        }

        // In degrees from 0 up to 360. Nil for a gray, which has no hue.
        var hue: Double? {
            let high = max(red, green, blue)
            let spread = high - min(red, green, blue)
            guard spread > 0 else { return nil }
            let sector: Double
            switch high {
            case red: sector = ((green - blue) / spread).truncatingRemainder(dividingBy: 6)
            case green: sector = (blue - red) / spread + 2
            default: sector = (red - green) / spread + 4
            }
            let degrees = sector * 60
            return degrees < 0 ? degrees + 360 : degrees
        }
    }

    static func resolve(_ color: NSColor, in name: NSAppearance.Name) throws -> RGB {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        let srgb = try XCTUnwrap(resolved)
        return RGB(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent))
    }

    static func contrast(_ first: RGB, _ second: RGB) -> Double {
        (max(first.luminance, second.luminance) + 0.05) / (min(first.luminance, second.luminance) + 0.05)
    }
}

// Shaped like a real snapshot, with the reports of different providers interleaved. Five Claude accounts use 100%, 90%, 80%, 70% and 55%
// of their 7-day quota, three Codex accounts 97%, 88% and 96%, the Grok account 1%, and the Cursor account 100%.
// Every other quota sits at a value that would change a figure if it were picked.
enum RealisticFixture {
    static let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    // The first `unmeasuredClaudeAccounts` Claude accounts report no amounts at all.
    static func snapshot(unmeasuredClaudeAccounts: Int = 0, accountProblems: [AccountProblem] = []) -> UsageSnapshot {
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
            reportDrafts: [cursor, codex[0], claude[0], grok, claude[1], codex[1], claude[2], claude[3], codex[2], claude[4]],
            accountProblems: accountProblems
        )
    }

    // A Grok account on the weekly shared pool, shaped as OMP 18.12.3 reports it (packages/ai/src/usage/xai-oauth.ts): the credit pool, then a row for
    // each product that draws on it. All of them are shared and sit on the pool's window, so only their ids tell them apart.
    // A nil `pool` leaves the pool out, and `extra` follows the rows.
    static func sharedPoolGrok(
        accountID: String = "grok-a",
        pool: Double?,
        products: [(name: String, used: Double)] = [],
        extra: [UsageQuotaDraft] = []
    ) -> UsageReportDraft {
        var rows: [(id: String, label: String, used: Double)] = []
        if let pool { rows.append((id: "xai-oauth:credits:1w", label: "SuperGrok Weekly Credits", used: pool)) }
        for product in products {
            rows.append((id: "xai-oauth:product:\(product.name.lowercased()):1w", label: "\(product.name) (Weekly)", used: product.used))
        }
        let quotas = rows.map { row in
            UsageQuotaDraft(
                id: row.id,
                label: row.label,
                scope: QuotaScope(provider: "xai-oauth", accountID: nil, organizationID: nil, projectID: nil, modelID: nil, tier: nil, windowID: "1w", shared: true),
                window: QuotaWindow(identity: QuotaWindowIdentity(id: "1w"), label: "Weekly", durationMilliseconds: 604_800_000, resetLabel: nil),
                amount: UsageAmount(
                    used: row.used,
                    limit: 100,
                    remaining: 100 - row.used,
                    usedFraction: row.used / 100,
                    remainingFraction: (100 - row.used) / 100,
                    unit: .percent
                ),
                status: .available,
                resetsAt: fetchedAt.addingTimeInterval(138 * 3_600)
            )
        }
        return report("xai-oauth", accountID, quotas + extra)
    }

    static func problem(
        _ kind: AccountProblemKind = .disconnected,
        provider: String = "anthropic",
        label: String? = nil,
        reason: String? = nil,
        since: Date? = nil
    ) -> AccountProblem {
        AccountProblem(provider: provider, kind: kind, privateDisplayLabel: label, reason: reason, since: since)
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
