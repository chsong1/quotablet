import AppKit
import CoreText
import Foundation
import SwiftUI
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
        let pins = MenuBarPins().toggling(savedKey)
        XCTAssertEqual(different.menuBarContent(pins: pins), MenuBarContent(slots: [.missing(savedKey)]))
        guard case .pinned(let selection) = returned.menuBarContent(pins: pins).slots.first else {
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

    func testMenuBarSlotsFollowPinOrderAndAMissingPinKeepsItsPosition() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "acct-a"),
            report(accountID: "acct-b"),
            report(accountID: "acct-c")
        ])
        let keys = try pinKeys(in: snapshot)
        let departed = try pinKeys(in: UsageSnapshot(generatedAt: timestamp, reportDrafts: [report(accountID: "acct-gone")]))[0]
        let pins = MenuBarPins().toggling(keys[2]).toggling(departed).toggling(keys[0])

        XCTAssertEqual(
            described(snapshot.menuBarContent(pins: pins).slots),
            ["pinned:acct-c", "missing:acct-gone", "pinned:acct-a"]
        )
    }

    func testWithNothingToFlagAndEqualUsageTheMenuBarShowsTheFirstQuotaInProviderOrder() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "openai-codex", accountID: "acct-codex"),
            report(provider: "anthropic", accountID: "acct-claude")
        ])
        let empty = UsageSnapshot(generatedAt: timestamp, reportDrafts: [])
        let strayKey = try pinKeys(in: snapshot)[0]

        XCTAssertEqual(described(snapshot.menuBarContent(pins: MenuBarPins()).slots), ["defaulted:acct-claude"])
        XCTAssertEqual(empty.menuBarContent(pins: MenuBarPins()), MenuBarContent(slots: []))
        XCTAssertEqual(empty.menuBarContent(pins: MenuBarPins().toggling(strayKey)), MenuBarContent(slots: [.missing(strayKey)]))
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

    func testWithoutPinsTheMenuBarShowsTheFirstFourAttentionAccountsAndCountsTheRest() {
        let six = attentionSnapshot(accountCount: 6).menuBarContent(pins: MenuBarPins())
        let five = attentionSnapshot(accountCount: 5).menuBarContent(pins: MenuBarPins())
        let four = attentionSnapshot(accountCount: 4).menuBarContent(pins: MenuBarPins())

        XCTAssertEqual(described(six.slots), ["attention:acct-6", "attention:acct-5", "attention:acct-4", "attention:acct-3"])
        XCTAssertEqual(six.slots.compactMap { $0.selected?.quota.label }, Array(repeating: "Claude 7 Day", count: 4))
        XCTAssertEqual(six.hiddenAttentionCount, 2)
        XCTAssertEqual(six.hiddenAttention.map(\.selection.report.sourceAccount?.accountID), ["acct-2", "acct-1"])
        XCTAssertEqual(described(five.slots), ["attention:acct-5", "attention:acct-4", "attention:acct-3", "attention:acct-2"])
        XCTAssertEqual(five.hiddenAttentionCount, 1)
        XCTAssertEqual(described(four.slots), ["attention:acct-4", "attention:acct-3", "attention:acct-2", "attention:acct-1"])
        XCTAssertEqual(four.hiddenAttentionCount, 0)
    }

    func testPinsReplaceAttentionInTheMenuBarAndHideNothing() throws {
        let snapshot = attentionSnapshot(accountCount: 6)
        let fiveHour = try pinKeys(of: snapshot.reports[0])[0]

        let content = snapshot.menuBarContent(pins: MenuBarPins().toggling(fiveHour))

        XCTAssertEqual(described(content.slots), ["pinned:acct-1"])
        XCTAssertEqual(content.hiddenAttentionCount, 0)
    }

    func testWithNothingToFlagTheMenuBarShowsTheMostUsedQuotaBrokenByResetThenStableOrder() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            account("acct-a", label: "60% left", status: .available, remainingPercent: 60, resetsInHours: 1),
            account("acct-b", label: "15% left, resets in 9h", status: .available, remainingPercent: 15, resetsInHours: 9),
            account("acct-c", label: "15% left, resets in 2h", status: .available, remainingPercent: 15, resetsInHours: 2),
            account("acct-d", label: "15% left, no reset", status: .available, remainingPercent: 15, resetsInHours: nil),
            account("acct-e", label: "amount unknown", status: .available, remainingPercent: nil, resetsInHours: 1)
        ])

        let content = snapshot.menuBarContent(pins: MenuBarPins())

        XCTAssertEqual(described(content.slots), ["defaulted:acct-c"])
        XCTAssertEqual(content.hiddenAttentionCount, 0)
    }

    func testWithNoKnownUsageTheMenuBarFallsBackToProviderOrderEvenWhenAnotherQuotaResetsSooner() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            account("acct-codex", provider: "openai-codex", label: "codex", status: .available, remainingPercent: nil, resetsInHours: 1),
            account("acct-claude", label: "claude", status: .available, remainingPercent: nil, resetsInHours: 9)
        ])

        XCTAssertEqual(described(snapshot.menuBarContent(pins: MenuBarPins()).slots), ["defaulted:acct-claude"])
    }

    func testAStaleQuotaStillNeedsAttentionAndItsBadgeStaysStale() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            account("acct-a", label: "exhausted, resets in 3h", status: .exhausted, remainingPercent: 0, resetsInHours: 3)
        ])
        let content = snapshot.menuBarContent(pins: MenuBarPins())

        XCTAssertEqual(described(content.slots), ["attention:acct-a"])
        XCTAssertEqual(MenuBarBadge.badges(for: content, now: timestamp).map(\.isStale), [false])
        XCTAssertEqual(MenuBarBadge.badges(for: content, now: timestamp.addingTimeInterval(900)).map(\.isStale), [true])
    }

    func testTogglingAppendsRemovesAndNeverDuplicatesPins() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "acct-a"),
            report(accountID: "acct-b")
        ])
        let keys = try pinKeys(in: snapshot)
        let both = MenuBarPins().toggling(keys[0]).toggling(keys[1])

        XCTAssertEqual(both.keys, [keys[0], keys[1]])
        XCTAssertEqual(both.toggling(keys[0]).keys, [keys[1]])
        XCTAssertEqual(both.toggling(keys[0]).toggling(keys[0]).keys, [keys[1], keys[0]])
        XCTAssertEqual(both.removing(keys[1]).removing(keys[1]).keys, [keys[0]])
        XCTAssertEqual(both.removing(keys[0]).removing(keys[1]).keys, [])
        XCTAssertTrue(both.contains(keys[1]))
        XCTAssertFalse(both.removing(keys[1]).contains(keys[1]))
    }

    func testDecodingPinsKeepsFirstOccurrenceOrderAndDropsRepeats() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "acct-a"),
            report(accountID: "acct-b")
        ])
        let keys = try pinKeys(in: snapshot)
        let data = try JSONEncoder().encode([keys[1], keys[0], keys[1]])

        let decoded = try JSONDecoder().decode(MenuBarPins.self, from: data)

        XCTAssertEqual(decoded.keys, [keys[1], keys[0]])
    }

    func testAccountNumberStaysHiddenWhenAProvidersSlotsComeFromOneAccount() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "xai-oauth", accountID: "grok-a", quotas: [quota(id: "session"), quota(id: "weekly")]),
            report(provider: "xai-oauth", accountID: "grok-b", quotas: [quota(id: "session"), quota(id: "weekly")])
        ])
        let firstAccount = try pinKeys(of: snapshot.reports[0])
        let secondAccount = try pinKeys(of: snapshot.reports[1])

        XCTAssertEqual(accountNumbers(pinning: firstAccount, in: snapshot), [nil, nil])
        XCTAssertEqual(accountNumbers(pinning: secondAccount, in: snapshot), [nil, nil])
    }

    func testAccountNumberTellsAccountsApartWhenAProvidersSlotsSpanTwoAccounts() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "openai-codex", accountID: "codex-a"),
            report(provider: "xai-oauth", accountID: "grok-a"),
            report(provider: "openai-codex", accountID: "codex-b")
        ])
        let keys = try pinKeys(in: snapshot)

        XCTAssertEqual(accountNumbers(pinning: [keys[0], keys[2]], in: snapshot), [1, 2])
        XCTAssertEqual(accountNumbers(pinning: [keys[2], keys[0]], in: snapshot), [2, 1])
        XCTAssertEqual(accountNumbers(pinning: [keys[0], keys[1], keys[2]], in: snapshot), [1, nil, 2])
        XCTAssertEqual(accountNumbers(pinning: [keys[2]], in: snapshot), [nil])
        XCTAssertEqual(UsageFormatting.accountAlias(snapshot.accountNumber(of: snapshot.reports[2])), "Account 2")
    }

    func testAccountNumberFollowsEachSlotsOwnAccountWhenAProviderMixesAccounts() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "openai-codex", accountID: "codex-a", quotas: [quota(id: "session"), quota(id: "weekly")]),
            report(provider: "openai-codex", accountID: "codex-b")
        ])
        let first = try pinKeys(of: snapshot.reports[0])
        let second = try pinKeys(of: snapshot.reports[1])

        XCTAssertEqual(accountNumbers(pinning: [first[0], first[1], second[0]], in: snapshot), [1, 1, 2])
        XCTAssertEqual(accountNumbers(pinning: [first[0], second[0], first[1]], in: snapshot), [1, 2, 1])
    }

    func testMissingSlotsNeverShowAnAccountNumberAndDoNotCountAsAnAccount() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "xai-oauth", accountID: "grok-a", quotas: [quota(id: "session"), quota(id: "weekly")]),
            report(provider: "openai-codex", accountID: "codex-a"),
            report(provider: "openai-codex", accountID: "codex-b")
        ])
        let grok = try pinKeys(of: snapshot.reports[0])
        let codexA = try pinKeys(of: snapshot.reports[1])[0]
        let codexB = try pinKeys(of: snapshot.reports[2])[0]
        let departed = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "xai-oauth", accountID: "grok-gone"),
            report(provider: "openai-codex", accountID: "codex-gone")
        ])
        let goneGrok = try pinKeys(of: departed.reports[0])[0]
        let goneCodex = try pinKeys(of: departed.reports[1])[0]

        XCTAssertEqual(accountNumbers(pinning: [grok[0], goneGrok], in: snapshot), [nil, nil])
        XCTAssertEqual(accountNumbers(pinning: [goneGrok, grok[0]], in: snapshot), [nil, nil])
        XCTAssertEqual(accountNumbers(pinning: [grok[0], grok[1], goneGrok], in: snapshot), [nil, nil, nil])
        XCTAssertEqual(accountNumbers(pinning: [codexA, codexB, goneCodex], in: snapshot), [1, 2, nil])
        XCTAssertEqual(accountNumbers(pinning: [codexA, goneCodex], in: snapshot), [nil, nil])
    }

    func testWindowTagNamesEachLengthWhenOneAccountPinsTwoOrMoreLengths() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [
                quota(id: "session", windowID: "5h", windowLabel: "5 Hour", durationMilliseconds: 18_000_000),
                quota(id: "weekly", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000),
                quota(id: "weekly-fable", windowID: "7d-fable", windowLabel: "7 Day (Fable)", durationMilliseconds: 604_800_000),
                quota(id: "monthly", windowID: "30d", windowLabel: "30 Day", durationMilliseconds: 2_592_000_000)
            ])
        ])
        let keys = try pinKeys(of: snapshot.reports[0])

        XCTAssertEqual(windowTags(pinning: [keys[0], keys[1]], in: snapshot), ["5h", "7d"])
        XCTAssertEqual(windowTags(pinning: [keys[0], keys[1], keys[2]], in: snapshot), ["5h", "7d", "7d"])
        XCTAssertEqual(windowTags(pinning: [keys[1], keys[3]], in: snapshot), ["7d", "30d"])
    }

    func testWindowTagStaysHiddenWhenOneAccountsPinsShareALength() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [
                quota(id: "weekly", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000),
                quota(id: "weekly-fable", windowID: "7d-fable", windowLabel: "7 Day (Fable)", durationMilliseconds: 604_800_000)
            ])
        ])
        let keys = try pinKeys(of: snapshot.reports[0])

        XCTAssertEqual(windowTags(pinning: keys, in: snapshot), [nil, nil])
        XCTAssertEqual(windowTags(pinning: [keys[0]], in: snapshot), [nil])
    }

    func testWindowTagStaysHiddenWhenEachAccountPinsOneWindowEvenIfTheLengthsDiffer() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [quota(id: "session", windowID: "5h", durationMilliseconds: 18_000_000)]),
            report(accountID: "claude-b", quotas: [quota(id: "weekly", windowID: "7d", durationMilliseconds: 604_800_000)])
        ])
        let keys = try pinKeys(in: snapshot)

        XCTAssertEqual(windowTags(pinning: keys, in: snapshot), [nil, nil])
    }

    func testWindowTagFallsBackToTheLabelInitialWhenTheDurationIsNull() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [
                quota(id: "weekly", windowID: "7d", windowLabel: "7 Day", durationMilliseconds: 604_800_000),
                quota(id: "monthly", windowID: "monthly", windowLabel: "Monthly", durationMilliseconds: nil)
            ])
        ])
        let keys = try pinKeys(of: snapshot.reports[0])

        XCTAssertEqual(windowTags(pinning: [keys[0], keys[1]], in: snapshot), ["7d", "M"])
        XCTAssertEqual(windowTags(pinning: [keys[1], keys[0]], in: snapshot), ["M", "7d"])
    }

    func testWindowsWithoutADurationShareALengthOnlyWhenTheyShareAnIdentity() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [
                quota(id: "monthly", windowID: "monthly", windowLabel: "Monthly", durationMilliseconds: nil),
                quota(id: "quarterly", windowID: "quarterly", windowLabel: "Quarterly", durationMilliseconds: nil),
                quota(id: "monthly-fable", windowID: "monthly", windowLabel: "Monthly (Fable)", durationMilliseconds: nil)
            ])
        ])
        let keys = try pinKeys(of: snapshot.reports[0])

        XCTAssertEqual(windowTags(pinning: [keys[0], keys[1]], in: snapshot), ["M", "Q"])
        XCTAssertEqual(windowTags(pinning: [keys[0], keys[2]], in: snapshot), [nil, nil])
    }

    func testMissingSlotNeverGetsAWindowTagAndAddsNoLength() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [
                quota(id: "session", windowID: "5h", durationMilliseconds: 18_000_000),
                quota(id: "weekly", windowID: "7d", durationMilliseconds: 604_800_000)
            ])
        ])
        let keys = try pinKeys(of: snapshot.reports[0])
        let departed = try pinKeys(in: UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [quota(id: "monthly", windowID: "30d", durationMilliseconds: 2_592_000_000)])
        ]))[0]

        XCTAssertEqual(windowTags(pinning: [keys[0], departed], in: snapshot), [nil, nil])
        XCTAssertEqual(windowTags(pinning: [keys[0], keys[1], departed], in: snapshot), ["5h", "7d", nil])
    }

    func testSlotWithoutAWindowNeverGetsAWindowTagAndAddsNoLength() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [
                quota(id: "session", windowID: "5h", durationMilliseconds: 18_000_000),
                quota(id: "weekly", windowID: "7d", durationMilliseconds: 604_800_000),
                quota(id: "unwindowed", windowID: nil)
            ])
        ])
        let account = snapshot.reports[0]
        func tags(of quotas: [UsageQuota]) -> [String?] {
            let slots = quotas.map { MenuBarSlot.pinned(SelectedQuota(report: account, quota: $0, accountNumber: 1)) }
            return MenuBarBadge.badges(for: MenuBarContent(slots: slots), now: timestamp).map(\.windowTag)
        }

        XCTAssertEqual(tags(of: [account.quotas[0], account.quotas[2]]), [nil, nil])
        XCTAssertEqual(tags(of: account.quotas), ["5h", "7d", nil])
    }

    func testAttentionSlotTagsItsWindowWhenItsAccountSpansTwoLengthsAndAPinnedSlotKeepsThePinRule() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [
                quota(id: "session", windowID: "5h", windowLabel: "5 Hour"),
                quota(
                    id: "weekly",
                    windowID: "7d",
                    windowLabel: "7 Day",
                    durationMilliseconds: 604_800_000,
                    resetsAt: later(hours: 1),
                    status: .exhausted,
                    remainingPercent: 0
                )
            ]),
            report(accountID: "claude-b", quotas: [
                quota(id: "session", windowID: "5h", windowLabel: "5 Hour", resetsAt: later(hours: 2), status: .nearLimit, remainingPercent: 10)
            ]),
            report(accountID: "claude-c", quotas: [
                quota(
                    id: "weekly",
                    windowID: "7d",
                    windowLabel: "7 Day",
                    durationMilliseconds: 604_800_000,
                    resetsAt: later(hours: 3),
                    status: .exhausted,
                    remainingPercent: 0
                ),
                quota(id: "weekly-fable", windowID: "7d-fable", windowLabel: "7 Day (Fable)", durationMilliseconds: 604_800_000)
            ])
        ])
        let content = snapshot.menuBarContent(pins: MenuBarPins())

        XCTAssertEqual(MenuBarBadge.badges(for: content, now: timestamp), [
            MenuBarBadge(letter: "C", accountNumber: 1, gauge: .used(1), isStale: false, windowTag: "7d"),
            MenuBarBadge(letter: "C", accountNumber: 3, gauge: .used(1), isStale: false, windowTag: nil),
            MenuBarBadge(letter: "C", accountNumber: 2, gauge: .used(0.9), isStale: false, windowTag: nil)
        ])
        let weekly = try pinKeys(of: snapshot.reports[0])[1]
        XCTAssertEqual(windowTags(pinning: [weekly], in: snapshot), [nil])
    }

    func testAnAttentionBadgeKeepsItsAccountNumberWhenAnotherAccountOfItsProviderDoesNotFit() {
        let content = hiddenCodexSnapshot().menuBarContent(pins: MenuBarPins())

        XCTAssertEqual(
            described(content.slots),
            ["attention:claude-a", "attention:cursor-a", "attention:claude-b", "attention:codex-a"]
        )
        XCTAssertEqual(content.hiddenAttention.map(\.selection.report.sourceAccount?.accountID), ["codex-c"])
        XCTAssertEqual(content.hiddenAttentionCount, 1)
        XCTAssertEqual(MenuBarBadge.badges(for: content, now: timestamp), [
            MenuBarBadge(letter: "C", accountNumber: 1, gauge: .used(1), isStale: false, windowTag: "7d"),
            MenuBarBadge(letter: "U", accountNumber: nil, gauge: .used(1), isStale: false, windowTag: nil),
            MenuBarBadge(letter: "C", accountNumber: 2, gauge: .used(0.9), isStale: false, windowTag: "5h"),
            MenuBarBadge(letter: "O", accountNumber: 1, gauge: .used(0.75), isStale: false, windowTag: nil)
        ])
    }

    func testAnAttentionBadgeShowsNoAccountNumberWhenNoOtherAccountOfItsProviderNeedsAttention() {
        let content = hiddenCodexSnapshot(codexThreeNeedsAttention: false).menuBarContent(pins: MenuBarPins())

        XCTAssertEqual(
            described(content.slots),
            ["attention:claude-a", "attention:cursor-a", "attention:claude-b", "attention:codex-a"]
        )
        XCTAssertEqual(content.hiddenAttentionCount, 0)
        XCTAssertEqual(MenuBarBadge.badges(for: content, now: timestamp).map(\.accountNumber), [1, nil, 2, nil])
    }

    func testGaugeReadsUsedFractionClampsItAndKeepsUnknownDistinct() {
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

        XCTAssertEqual(BadgeGauge(amount: amount(usedFraction: nil)), .unknown)
        XCTAssertEqual(BadgeGauge(amount: nil), .unknown)
        XCTAssertEqual(BadgeGauge(amount: amount(usedFraction: 0)), .used(0))
        XCTAssertEqual(BadgeGauge(amount: amount(usedFraction: 0.42)), .used(0.42))
        XCTAssertEqual(BadgeGauge(amount: amount(usedFraction: 1.6)), .used(1))
        XCTAssertEqual(BadgeGauge(amount: amount(usedFraction: -0.2)), .used(0))
        XCTAssertEqual(BadgeGauge(amount: amount(usedFraction: nil, remainingFraction: 0.25)), .used(0.75))
    }

    func testMissingSlotKeepsItsProviderLetterWithoutAGaugeOrAccountNumber() {
        let key = QuotaPinKey(
            account: StableAccountIdentity(provider: "mistral", accountID: "acct-m", organizationID: nil, projectID: nil),
            limitID: "session",
            scope: nil,
            window: QuotaWindowIdentity(id: "5h")
        )
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [])

        let badges = MenuBarBadge.badges(for: snapshot.menuBarContent(pins: MenuBarPins().toggling(key)), now: timestamp)

        XCTAssertEqual(badges, [MenuBarBadge(letter: "M", accountNumber: nil, gauge: .missing, isStale: false, windowTag: nil)])
    }

    func testBadgeTurnsStaleWhenProviderDataReachesTheStaleBoundary() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [report(accountID: "acct-a")])
        let key = try pinKeys(in: snapshot)[0]
        let pins = MenuBarPins().toggling(key)
        func isStale(after seconds: TimeInterval) -> Bool {
            let now = timestamp.addingTimeInterval(seconds)
            return MenuBarBadge.badges(for: snapshot.menuBarContent(pins: pins), now: now)[0].isStale
        }

        XCTAssertFalse(isStale(after: 899))
        XCTAssertTrue(isStale(after: 900))
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

    func testStatusOverviewLeadsAnAccountWithNoKnownUsageByTheStableOrderOfItsQuotas() {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "acct-a", quotas: [
                quota(id: "weekly", windowID: "7d", label: "weekly", remainingPercent: nil),
                quota(id: "session", windowID: "5h", label: "session", remainingPercent: nil)
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

    // Account N resets in (accountCount + 1 - N) hours, so the last account ranks first. Each account also has an available 5-hour quota.
    private func attentionSnapshot(accountCount: Int) -> UsageSnapshot {
        UsageSnapshot(generatedAt: timestamp, reportDrafts: (1...accountCount).map { number in
            report(accountID: "acct-\(number)", quotas: [
                quota(id: "session", label: "Claude 5 Hour"),
                quota(
                    id: "weekly",
                    windowID: "7d",
                    windowLabel: "7 Day",
                    durationMilliseconds: 604_800_000,
                    resetsAt: later(hours: Double(accountCount + 1 - number)),
                    label: "Claude 7 Day",
                    status: .exhausted,
                    remainingPercent: 0
                )
            ])
        })
    }

    // Exhausted accounts rank first, then near-limit ones by least remaining, so Codex Account 3 (40% left) ranks fifth and does not fit in
    // four slots. Claude Account 1 has two quotas that need attention. Codex Account 2 is healthy.
    private func hiddenCodexSnapshot(codexThreeNeedsAttention: Bool = true) -> UsageSnapshot {
        UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(accountID: "claude-a", quotas: [
                quota(id: "session", label: "Claude 5 Hour", status: .nearLimit, remainingPercent: 5),
                quota(
                    id: "weekly",
                    windowID: "7d",
                    durationMilliseconds: 604_800_000,
                    resetsAt: later(hours: 3),
                    label: "Claude 7 Day",
                    status: .exhausted,
                    remainingPercent: 0
                )
            ]),
            report(accountID: "claude-b", quotas: [
                quota(id: "session", label: "Claude 5 Hour", status: .nearLimit, remainingPercent: 10),
                quota(id: "weekly", windowID: "7d", durationMilliseconds: 604_800_000, label: "Claude 7 Day")
            ]),
            report(provider: "cursor", accountID: "cursor-a", quotas: [
                quota(
                    id: "monthly",
                    windowID: "30d",
                    durationMilliseconds: 2_592_000_000,
                    resetsAt: later(hours: 5),
                    label: "Cursor Monthly",
                    status: .exhausted,
                    remainingPercent: 0
                )
            ]),
            report(provider: "openai-codex", accountID: "codex-a", quotas: [
                quota(id: "session", label: "Codex 5 Hour", status: .nearLimit, remainingPercent: 25)
            ]),
            report(provider: "openai-codex", accountID: "codex-b", quotas: [
                quota(id: "session", label: "Codex 5 Hour", remainingPercent: 90)
            ]),
            report(provider: "openai-codex", accountID: "codex-c", quotas: [
                quota(
                    id: "session",
                    label: "Codex 5 Hour",
                    status: codexThreeNeedsAttention ? .nearLimit : .available,
                    remainingPercent: codexThreeNeedsAttention ? 40 : 90
                )
            ])
        ])
    }

    private func pinKeys(in snapshot: UsageSnapshot) throws -> [QuotaPinKey] {
        try snapshot.reports.map { try XCTUnwrap($0.quotas.first?.pinKey) }
    }

    private func pinKeys(of report: UsageReport) throws -> [QuotaPinKey] {
        try report.quotas.map { try XCTUnwrap($0.pinKey) }
    }

    private func pinnedBadges(pinning keys: [QuotaPinKey], in snapshot: UsageSnapshot) -> [MenuBarBadge] {
        let pins = keys.reduce(MenuBarPins()) { $0.toggling($1) }
        return MenuBarBadge.badges(for: snapshot.menuBarContent(pins: pins), now: timestamp)
    }

    private func accountNumbers(pinning keys: [QuotaPinKey], in snapshot: UsageSnapshot) -> [Int?] {
        pinnedBadges(pinning: keys, in: snapshot).map(\.accountNumber)
    }

    private func windowTags(pinning keys: [QuotaPinKey], in snapshot: UsageSnapshot) -> [String?] {
        pinnedBadges(pinning: keys, in: snapshot).map(\.windowTag)
    }

    private func described(_ slots: [MenuBarSlot]) -> [String] {
        slots.map { slot in
            switch slot {
            case .pinned(let selection): "pinned:\(selection.report.sourceAccount?.accountID ?? "-")"
            case .attention(let selection): "attention:\(selection.report.sourceAccount?.accountID ?? "-")"
            case .defaulted(let selection): "defaulted:\(selection.report.sourceAccount?.accountID ?? "-")"
            case .missing(let key): "missing:\(key.account.accountID)"
            }
        }
    }

    private func builtQuotas(from drafts: [UsageQuotaDraft]) -> [UsageQuota] {
        UsageSnapshot(generatedAt: timestamp, reportDrafts: [report(accountID: "acct-a", quotas: drafts)]).reports[0].quotas
    }
}

final class MenuBarBadgeRendererTests: XCTestCase {
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

    func testImageIsATemplateWithOneColumnPerBadgeAndRoomForTheAccountNumber() {
        let plain = badge(.used(0.5))
        let numbered = badge(.used(0.5), number: 2)

        let image = MenuBarBadgeRenderer.image(for: [plain, plain, plain])
        let withNumber = MenuBarBadgeRenderer.image(for: [plain, plain, numbered])
        let large = MenuBarBadgeRenderer.image(for: [plain], height: 22)

        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 50, height: 16))
        XCTAssertEqual(withNumber.size.width - image.size.width, 6, accuracy: 1)
        XCTAssertEqual(large.size.height, 22)
        XCTAssertEqual(large.size.width, 19.25, accuracy: 0.001)
    }

    func testGaugeFillsFromTheBottomOverATrackAndKnocksTheLetterOut() throws {
        let empty = try render([badge(.used(0))])
        let half = try render([badge(.used(0.5))])
        let full = try render([badge(.used(1))])

        XCTAssertEqual(empty.alpha(x: 9, row: 16), 0.30, accuracy: 0.03)
        XCTAssertEqual(full.alpha(x: 9, row: 16), 1, accuracy: 0.03)
        XCTAssertEqual(half.alpha(x: 9, row: 26), 1, accuracy: 0.03)
        XCTAssertEqual(half.alpha(x: 9, row: 6), 0.30, accuracy: 0.03)
        XCTAssertEqual(empty.alpha(x: 14, row: 16), 0, accuracy: 0.05)
        XCTAssertEqual(full.alpha(x: 14, row: 16), 0, accuracy: 0.05)
    }

    func testUnknownDrawsAFramedOutlineAndMissingDashesIt() throws {
        let unknown = try render([badge(.unknown)])
        let missing = try render([badge(.missing)])

        XCTAssertEqual(unknown.alpha(x: 9, row: 16), 0, accuracy: 0.02)
        XCTAssertEqual(unknown.alpha(x: 14, row: 16), 0.9, accuracy: 0.05)
        XCTAssertGreaterThan((10...22).map { unknown.alpha(x: 0, row: $0) }.min() ?? 0, 0.85)
        let dashedEdge = (10...22).map { missing.alpha(x: 0, row: $0) }
        XCTAssertLessThan(dashedEdge.min() ?? 1, 0.1)
        XCTAssertGreaterThan(dashedEdge.max() ?? 0, 0.45)
        XCTAssertEqual(missing.alpha(x: 14, row: 16), 0.55, accuracy: 0.05)
    }

    func testStaleBadgeStripesTheFilledPartAndDimsTheTrack() throws {
        let fresh = try render([badge(.used(1))])
        let stale = try render([badge(.used(1), isStale: true)])
        let staleEmpty = try render([badge(.used(0), isStale: true)])

        let bands = [28, 26, 24, 22].map { stale.alpha(x: 9, row: $0) }
        XCTAssertEqual(bands[0], bands[2], accuracy: 0.03)
        XCTAssertEqual(bands[1], bands[3], accuracy: 0.03)
        XCTAssertGreaterThan(abs(bands[0] - bands[1]), 0.2)
        XCTAssertLessThan(bands.max() ?? 1, 0.7)
        XCTAssertEqual(fresh.alpha(x: 9, row: 28), 1, accuracy: 0.03)
        XCTAssertEqual(staleEmpty.alpha(x: 9, row: 16), 0.16, accuracy: 0.03)
    }

    func testStaleUnknownBadgeDimsItsOutlineLetterAndAccountNumber() throws {
        let fresh = try render([badge(.unknown, number: 8)])
        let stale = try render([badge(.unknown, number: 8, isStale: true)])
        let badgeColumns = 0..<28
        let numberColumns = 30..<40

        XCTAssertEqual(fresh.peakAlpha(columns: badgeColumns) - stale.peakAlpha(columns: badgeColumns), 0.405, accuracy: 0.03)
        XCTAssertEqual(fresh.peakAlpha(columns: numberColumns) - stale.peakAlpha(columns: numberColumns), 0.45, accuracy: 0.03)
    }

    func testAccountNumberSitsRightOfTheBadgeOnItsBottomEdge() throws {
        let numbered = try render([badge(.used(0.5), number: 8)])

        let lowerRows = (18...30).flatMap { row in (30..<40).map { numbered.alpha(x: $0, row: row) } }
        let upperRows = (2..<12).flatMap { row in (30..<40).map { numbered.alpha(x: $0, row: row) } }
        XCTAssertGreaterThan(lowerRows.max() ?? 0, 0.8)
        XCTAssertEqual(upperRows.max() ?? 1, 0, accuracy: 0.01)
    }

    func testTagWidensTheBadgeByTheMeasuredTagColumn() {
        let plain = MenuBarBadgeRenderer.image(for: [badge(.used(0.5))])
        let tagged = MenuBarBadgeRenderer.image(for: [badge(.used(0.5), tag: "7d")])
        let longer = MenuBarBadgeRenderer.image(for: [badge(.used(0.5), tag: "30d")])

        XCTAssertEqual(plain.size.width, 14)
        XCTAssertEqual(tagged.size.width - plain.size.width, measuredTagColumn("7d"))
        XCTAssertEqual(longer.size.width - plain.size.width, measuredTagColumn("30d"))
    }

    func testTagAndAccountNumberShareOneColumnAsWideAsTheWiderOfTheTwo() {
        func width(number: Int?, tag: String?) -> CGFloat {
            MenuBarBadgeRenderer.image(for: [badge(.used(0.5), number: number, tag: tag)]).size.width
        }
        let digitColumn = width(number: 8, tag: nil) - 14

        XCTAssertGreaterThan(digitColumn, measuredTagColumn("I"))
        XCTAssertLessThan(digitColumn, measuredTagColumn("30d"))
        XCTAssertEqual(width(number: 8, tag: "I"), 14 + digitColumn)
        XCTAssertEqual(width(number: 8, tag: "30d"), 14 + measuredTagColumn("30d"))
    }

    func testTagInkSitsInTheTopHalfAndAccountNumberInkInTheBottomHalf() throws {
        let tagOnly = try render([badge(.used(0.5), tag: "7d")])
        let numberOnly = try render([badge(.used(0.5), number: 8)])
        let both = try render([badge(.used(0.5), number: 8, tag: "7d")])
        let topHalf = 0..<16
        let bottomHalf = 16..<32

        XCTAssertGreaterThan(tagOnly.peakAlpha(columns: 30..<tagOnly.width, rows: topHalf), 0.5)
        XCTAssertEqual(tagOnly.peakAlpha(columns: 30..<tagOnly.width, rows: bottomHalf), 0, accuracy: 0.01)
        XCTAssertGreaterThan(numberOnly.peakAlpha(columns: 30..<numberOnly.width, rows: bottomHalf), 0.5)
        XCTAssertEqual(numberOnly.peakAlpha(columns: 30..<numberOnly.width, rows: topHalf), 0, accuracy: 0.01)
        XCTAssertGreaterThan(both.peakAlpha(columns: 30..<both.width, rows: topHalf), 0.5)
        XCTAssertGreaterThan(both.peakAlpha(columns: 30..<both.width, rows: bottomHalf), 0.5)
    }

    func testStaleBadgeDimsItsWindowTagLikeItsAccountNumber() throws {
        let fresh = try render([badge(.used(0.5), tag: "7d")])
        let stale = try render([badge(.used(0.5), isStale: true, tag: "7d")])
        let tagColumns = 30..<fresh.width
        let topHalf = 0..<16

        let dimming = stale.peakAlpha(columns: tagColumns, rows: topHalf) / fresh.peakAlpha(columns: tagColumns, rows: topHalf)
        XCTAssertEqual(dimming, 0.55, accuracy: 0.03)
    }

    func testZeroOverflowDrawsTheSameImageAsNoOverflow() throws {
        let badges = [badge(.used(0.5)), badge(.used(0.9), number: 2, tag: "7d")]

        let without = try pixels(of: MenuBarBadgeRenderer.image(for: badges))
        let zero = try pixels(of: MenuBarBadgeRenderer.image(for: badges, overflow: 0))

        XCTAssertGreaterThan(without.peakAlpha(columns: 0..<without.width), 0.5)
        XCTAssertEqual(CGFloat(zero.width) / 2, 14 + 4 + 14 + measuredTagColumn("7d"))
        XCTAssertEqual(zero.width, without.width)
        XCTAssertEqual(zero.visibleBytes, without.visibleBytes)
    }

    func testOverflowDrawsAPlusCountOneSpacingAfterTheLastBadgeOnItsBottomEdge() throws {
        let badges = [badge(.used(0.5))]
        let plain = MenuBarBadgeRenderer.image(for: badges)
        let overflowed = MenuBarBadgeRenderer.image(for: badges, overflow: 2)
        let drawn = try pixels(of: overflowed)
        let spacing = 28..<36
        let count = 36..<drawn.width
        let topHalf = 0..<16
        let bottomHalf = 16..<32

        XCTAssertEqual(overflowed.size.width - plain.size.width, 4 + measuredDigitAdvance("+2"))
        XCTAssertEqual(drawn.peakAlpha(columns: spacing), 0, accuracy: 0.01)
        XCTAssertGreaterThan(drawn.peakAlpha(columns: count, rows: bottomHalf), 0.5)
        XCTAssertEqual(drawn.peakAlpha(columns: count, rows: topHalf), 0, accuracy: 0.01)
    }

    private func badge(_ gauge: BadgeGauge, number: Int? = nil, isStale: Bool = false, tag: String? = nil) -> MenuBarBadge {
        MenuBarBadge(letter: "I", accountNumber: number, gauge: gauge, isStale: isStale, windowTag: tag)
    }

    private struct Pixels {
        let bytes: [UInt8]
        let bytesPerRow: Int
        let width: Int

        func alpha(x: Int, row: Int) -> Double {
            Double(bytes[row * bytesPerRow + x * 4 + 3]) / 255
        }

        func peakAlpha(columns: Range<Int>) -> Double {
            peakAlpha(columns: columns, rows: 0..<bytes.count / bytesPerRow)
        }

        func peakAlpha(columns: Range<Int>, rows: Range<Int>) -> Double {
            rows.flatMap { row in columns.map { alpha(x: $0, row: row) } }.max() ?? 0
        }

        var visibleBytes: [UInt8] {
            (0..<bytes.count / bytesPerRow).flatMap { row in bytes[(row * bytesPerRow)..<(row * bytesPerRow + width * 4)] }
        }
    }

    private func render(_ badges: [MenuBarBadge]) throws -> Pixels {
        try pixels(of: MenuBarBadgeRenderer.image(for: badges))
    }

    private func pixels(of image: NSImage) throws -> Pixels {
        let scale = 2
        let height = Int(image.size.height) * scale
        let bitmap = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(image.size.width) * scale,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        bitmap.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(bitmap.data)
        let buffer = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: bitmap.bytesPerRow * height)
        return Pixels(bytes: Array(buffer), bytesPerRow: bitmap.bytesPerRow, width: bitmap.width)
    }

    private func measuredTagColumn(_ tag: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 7, weight: .bold)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: tag, attributes: [.font: font]) as CFAttributedString)
        return (1 + CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))).rounded()
    }

    private func measuredDigitAdvance(_ text: String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]) as CFAttributedString)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)).rounded()
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

final class QuotaFlowerTests: XCTestCase {
    func testLayoutIsAFlowerOnlyForThreeToEightSlots() {
        let layouts = (0...10).map(SummaryLayout.forSlotCount)

        XCTAssertEqual(layouts, [.list, .list, .list, .flower, .flower, .flower, .flower, .flower, .flower, .list, .list])
    }

    func testFillRadiusSpansTheInnerToTheOuterEdgeAndGrowsWithTheFraction() {
        for count in [3, 8] {
            let petal = PetalGeometry(petalCount: count, index: 0, outerRadius: 75)

            XCTAssertEqual(petal.innerRadius, 18, accuracy: 1e-9)
            XCTAssertEqual(petal.fillRadius(forUsedFraction: 0), 18, accuracy: 1e-9)
            XCTAssertEqual(petal.fillRadius(forUsedFraction: 1), 75)
            XCTAssertEqual(petal.fillRadius(forUsedFraction: -0.5), 18, accuracy: 1e-9)
            XCTAssertEqual(petal.fillRadius(forUsedFraction: 2), 75)
            let radii = (0...10).map { petal.fillRadius(forUsedFraction: Double($0) / 10) }
            for (lower, upper) in zip(radii, radii.dropFirst()) {
                XCTAssertLessThan(lower, upper, "\(count) petals")
            }
        }
    }

    func testFillRadiusCoversTheFractionOfThePetalAreaNotOfItsLength() {
        for count in [3, 8] {
            let petal = PetalGeometry(petalCount: count, index: 0, outerRadius: 75)
            let fractions = [0.25, 0.5, 0.75]
            let radii = fractions.map { petal.fillRadius(forUsedFraction: $0) }

            let sample = sampledArea(of: petal, insideDisks: radii)

            for (fraction, covered) in zip(fractions, sample.inside) {
                XCTAssertEqual(covered / sample.total, fraction, accuracy: 0.01, "\(count) petals at \(fraction)")
            }
            XCTAssertGreaterThan(radii[1], 18 + (75 - 18) / 2 + 5, "\(count) petals reach past the linear midpoint")
        }
    }

    func testAreaWithinRadiusMatchesASampledGrid() {
        for count in [3, 8] {
            let petal = PetalGeometry(petalCount: count, index: 0, outerRadius: 75)
            let radii: [CGFloat] = [30, 50, 70, 75]

            let sample = sampledArea(of: petal, insideDisks: radii)

            for (radius, covered) in zip(radii, sample.inside) {
                XCTAssertEqual(Double(petal.area(withinRadius: radius)), covered, accuracy: 0.01 * sample.total, "\(count) petals within \(radius)")
            }
            XCTAssertEqual(petal.area(withinRadius: 10), 0)
            XCTAssertEqual(petal.area(withinRadius: 18), 0, accuracy: 1e-9)
            XCTAssertEqual(petal.area(withinRadius: 200), petal.area(withinRadius: 75))
        }
    }

    func testPetalsOfOneFlowerNeverShareAPoint() {
        let step: CGFloat = 0.5
        for count in SummaryLayout.petalRange {
            let petals = (0..<count).map { PetalGeometry(petalCount: count, index: $0, outerRadius: 75) }
            let paths = petals.map { $0.path(in: center) }
            var covered = [Int](repeating: 0, count: count)
            var shared = 0
            var y = center.y - 75 + step / 2
            while y < center.y + 75 {
                var x = center.x - 75 + step / 2
                while x < center.x + 75 {
                    let holders = paths.indices.filter { paths[$0].contains(CGPoint(x: x, y: y)) }
                    for holder in holders { covered[holder] += 1 }
                    if holders.count > 1 { shared += 1 }
                    x += step
                }
                y += step
            }

            XCTAssertEqual(shared, 0, "\(count) petals")
            for (petal, points) in zip(petals, covered) {
                let area = Double(petal.area(withinRadius: 75))
                XCTAssertEqual(Double(points) * Double(step * step), area, accuracy: 0.01 * area, "\(count) petals, index \(petal.index)")
            }
        }
    }

    func testPetalsRunClockwiseFromTwelveOClock() {
        let paths = (0..<4).map { PetalGeometry(petalCount: 4, index: $0, outerRadius: 75).path(in: center) }
        // Twelve, three, six and nine o'clock on a y-down plane, 46 pt from the center.
        let compass = [
            CGPoint(x: center.x, y: center.y - 46),
            CGPoint(x: center.x + 46, y: center.y),
            CGPoint(x: center.x, y: center.y + 46),
            CGPoint(x: center.x - 46, y: center.y),
        ]

        for (index, path) in paths.enumerated() {
            XCTAssertEqual(compass.map { path.contains($0) }, (0..<4).map { $0 == index }, "petal \(index)")
        }
    }

    func testPetalCornersAreRoundedAtBothEdges() {
        let path = PetalGeometry(petalCount: 3, index: 0, outerRadius: 75).path(in: center)
        // The petal spans -147 to -33 degrees. The corner probes sit 1.5 degrees inside each side.
        func point(radius: CGFloat, degrees: CGFloat) -> CGPoint {
            CGPoint(x: center.x + radius * cos(degrees * .pi / 180), y: center.y + radius * sin(degrees * .pi / 180))
        }

        XCTAssertFalse(path.contains(point(radius: 73, degrees: -145.5)))
        XCTAssertFalse(path.contains(point(radius: 73, degrees: -34.5)))
        XCTAssertFalse(path.contains(point(radius: 19, degrees: -145.5)))
        XCTAssertFalse(path.contains(point(radius: 19, degrees: -34.5)))
        XCTAssertTrue(path.contains(point(radius: 73, degrees: -90)))
        XCTAssertTrue(path.contains(point(radius: 19, degrees: -90)))
        XCTAssertTrue(path.contains(point(radius: 50, degrees: -145.5)))
        XCTAssertTrue(path.contains(point(radius: 50, degrees: -34.5)))
    }

    func testLabelSitsInsideItsPetalAtTheMiddleOfTheOuterThird() {
        for count in SummaryLayout.petalRange {
            for index in 0..<count {
                let petal = PetalGeometry(petalCount: count, index: index, outerRadius: 75)
                let label = petal.labelCenter(in: center)

                XCTAssertEqual(hypot(label.x - center.x, label.y - center.y), 65.5, accuracy: 1e-6)
                XCTAssertTrue(petal.path(in: center).contains(label), "\(count) petals, index \(index)")
            }
        }
    }

    func testPaletteHoldsEightDistinctColorsAndWrapsPastThem() {
        XCTAssertEqual(Set((0..<8).map(QuotaPalette.color(at:))).count, 8)
        XCTAssertEqual(QuotaPalette.color(at: 8), QuotaPalette.color(at: 0))
        XCTAssertEqual(QuotaPalette.color(at: -1), QuotaPalette.color(at: 7))
    }

    @MainActor
    func testLegendTextReusesTheMenuBarSlotText() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            draft(accountID: "acct-a", quotaLabel: "5 hours", fetchedAt: timestamp),
            draft(accountID: "acct-b", quotaLabel: "7 days", fetchedAt: timestamp),
        ])
        let second = try XCTUnwrap(snapshot.reports[1].quotas.first?.pinKey)
        let gone = QuotaPinKey(
            account: StableAccountIdentity(provider: "openai-codex", accountID: "acct-gone", organizationID: nil, projectID: nil),
            limitID: "quota-1",
            scope: nil,
            window: QuotaWindowIdentity(id: "7d")
        )

        let slots = snapshot.menuBarContent(pins: MenuBarPins().toggling(second).toggling(gone)).slots

        XCTAssertEqual(
            slots.map(UsageStore.accessibilityDescription(of:)),
            ["Codex Account 2, 7 days, 73% left", "Pinned quota unavailable"]
        )
    }

    @MainActor
    func testSlotsShareTheFreshnessOfTheirOldestReport() throws {
        let older = timestamp.addingTimeInterval(-3_600)
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            draft(accountID: "acct-a", quotaLabel: "5 hours", fetchedAt: timestamp),
            draft(accountID: "acct-b", quotaLabel: "7 days", fetchedAt: older),
        ])
        let pins = try snapshot.reports.reduce(MenuBarPins()) { pins, report in
            pins.toggling(try XCTUnwrap(report.quotas.first?.pinKey))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletTests-\(UUID().uuidString)", isDirectory: true)
        let store = UsageStore(persistence: AppPersistence(directoryURL: directory))

        XCTAssertEqual(store.freshness(of: snapshot.menuBarContent(pins: pins).slots).fetchedAt, older)
        XCTAssertNil(store.freshness(of: []).fetchedAt)
    }

    private var center: CGPoint { CGPoint(x: 100, y: 100) }

    private var timestamp: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    private func draft(accountID: String, quotaLabel: String, fetchedAt: Date) -> UsageReportDraft {
        UsageReportDraft(
            provider: "openai-codex",
            sourceAccount: SourceAccountIdentity(accountID: accountID, organizationID: nil, projectID: nil),
            privateDisplayLabel: nil,
            fetchedAt: fetchedAt,
            resetCredits: nil,
            quotas: [
                UsageQuotaDraft(
                    id: "quota-1",
                    label: quotaLabel,
                    scope: nil,
                    window: QuotaWindow(identity: QuotaWindowIdentity(id: "7d"), label: "7d", durationMilliseconds: nil, resetLabel: nil),
                    amount: UsageAmount(used: 27, limit: 100, remaining: 73, usedFraction: 0.27, remainingFraction: 0.73, unit: .percent),
                    status: .available,
                    resetsAt: nil
                )
            ]
        )
    }

    // Counts the grid points the petal covers, in total and inside each disk around the flower's center.
    private func sampledArea(of petal: PetalGeometry, insideDisks radii: [CGFloat]) -> (total: Double, inside: [Double]) {
        let step: CGFloat = 0.25
        let path = petal.path(in: center)
        let box = path.boundingBoxOfPath
        var total = 0
        var inside = [Int](repeating: 0, count: radii.count)
        var y = box.minY + step / 2
        while y < box.maxY {
            var x = box.minX + step / 2
            while x < box.maxX {
                if path.contains(CGPoint(x: x, y: y)) {
                    total += 1
                    let distance = hypot(x - center.x, y - center.y)
                    for (offset, radius) in radii.enumerated() where distance <= radius {
                        inside[offset] += 1
                    }
                }
                x += step
            }
            y += step
        }
        let cell = Double(step * step)
        return (Double(total) * cell, inside.map { Double($0) * cell })
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
