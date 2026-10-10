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

    func testOnlyProvidersWithAReportAreListed() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "cursor", accountID: "c"),
            report(provider: "anthropic", accountID: "a")
        ])

        XCTAssertEqual(snapshot.providerUsage(now: timestamp).map(\.provider), ["anthropic", "cursor"])
        XCTAssertEqual(UsageSnapshot(generatedAt: timestamp, reportDrafts: []).providerUsage(now: timestamp), [])
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

    func testNoProviderPageExistsForAProviderWithoutAReport() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [report(accountID: "claude-a")])

        XCTAssertNotNil(snapshot.providerDetail(of: "anthropic", now: timestamp))
        XCTAssertNil(snapshot.providerDetail(of: "openai-codex", now: timestamp))
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
        quotas: [UsageQuotaDraft]? = nil
    ) -> UsageReportDraft {
        UsageReportDraft(
            provider: provider,
            sourceAccount: SourceAccountIdentity(accountID: accountID, organizationID: organizationID, projectID: projectID),
            privateDisplayLabel: label,
            fetchedAt: fetchedAt ?? timestamp,
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
