import AppKit
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
        XCTAssertEqual(different.menuBarSlots(pins: pins), [.missing(savedKey)])
        guard case .pinned(let selection) = returned.menuBarSlots(pins: pins).first else {
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
            described(snapshot.menuBarSlots(pins: pins)),
            ["pinned:acct-c", "missing:acct-gone", "pinned:acct-a"]
        )
    }

    func testWithoutPinsTheDefaultQuotaIsSelectedAndAnEmptySnapshotSelectsNothing() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [
            report(provider: "openai-codex", accountID: "acct-codex"),
            report(provider: "anthropic", accountID: "acct-claude")
        ])
        let empty = UsageSnapshot(generatedAt: timestamp, reportDrafts: [])
        let strayKey = try pinKeys(in: snapshot)[0]

        XCTAssertEqual(described(snapshot.menuBarSlots(pins: MenuBarPins())), ["defaulted:acct-claude"])
        XCTAssertEqual(empty.menuBarSlots(pins: MenuBarPins()), [])
        XCTAssertEqual(empty.menuBarSlots(pins: MenuBarPins().toggling(strayKey)), [.missing(strayKey)])
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

        let badges = MenuBarBadge.badges(for: snapshot.menuBarSlots(pins: MenuBarPins().toggling(key)), now: timestamp)

        XCTAssertEqual(badges, [MenuBarBadge(letter: "M", accountNumber: nil, gauge: .missing, isStale: false)])
    }

    func testBadgeTurnsStaleWhenProviderDataReachesTheStaleBoundary() throws {
        let snapshot = UsageSnapshot(generatedAt: timestamp, reportDrafts: [report(accountID: "acct-a")])
        let key = try pinKeys(in: snapshot)[0]
        let pins = MenuBarPins().toggling(key)
        func isStale(after seconds: TimeInterval) -> Bool {
            let now = timestamp.addingTimeInterval(seconds)
            return MenuBarBadge.badges(for: snapshot.menuBarSlots(pins: pins), now: now)[0].isStale
        }

        XCTAssertFalse(isStale(after: 899))
        XCTAssertTrue(isStale(after: 900))
    }

    func testProviderRegistryResolvesKnownIdsAndFallsBackToTheRawIdAndItsFirstLetter() {
        XCTAssertEqual(ProviderRegistry.displayName(for: "Anthropic"), "Claude")
        XCTAssertEqual(ProviderRegistry.badgeLetter(for: "openai-codex"), "O")
        XCTAssertEqual(ProviderRegistry.displayName(for: "mistral"), "mistral")
        XCTAssertEqual(ProviderRegistry.badgeLetter(for: "mistral"), "M")
    }

    private var timestamp: Date { Date(timeIntervalSince1970: 1_800_000_000) }

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

    private func pinKeys(in snapshot: UsageSnapshot) throws -> [QuotaPinKey] {
        try snapshot.reports.map { try XCTUnwrap($0.quotas.first?.pinKey) }
    }

    private func pinKeys(of report: UsageReport) throws -> [QuotaPinKey] {
        try report.quotas.map { try XCTUnwrap($0.pinKey) }
    }

    private func accountNumbers(pinning keys: [QuotaPinKey], in snapshot: UsageSnapshot) -> [Int?] {
        let pins = keys.reduce(MenuBarPins()) { $0.toggling($1) }
        return MenuBarBadge.badges(for: snapshot.menuBarSlots(pins: pins), now: timestamp).map(\.accountNumber)
    }

    private func described(_ slots: [MenuBarSlot]) -> [String] {
        slots.map { slot in
            switch slot {
            case .pinned(let selection): "pinned:\(selection.report.sourceAccount?.accountID ?? "-")"
            case .defaulted(let selection): "defaulted:\(selection.report.sourceAccount?.accountID ?? "-")"
            case .missing(let key): "missing:\(key.account.accountID)"
            }
        }
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

    private func badge(_ gauge: BadgeGauge, number: Int? = nil, isStale: Bool = false) -> MenuBarBadge {
        MenuBarBadge(letter: "I", accountNumber: number, gauge: gauge, isStale: isStale)
    }

    private struct Pixels {
        let bytes: [UInt8]
        let bytesPerRow: Int

        func alpha(x: Int, row: Int) -> Double {
            Double(bytes[row * bytesPerRow + x * 4 + 3]) / 255
        }

        func peakAlpha(columns: Range<Int>) -> Double {
            (0..<bytes.count / bytesPerRow).flatMap { row in columns.map { alpha(x: $0, row: row) } }.max() ?? 0
        }
    }

    private func render(_ badges: [MenuBarBadge]) throws -> Pixels {
        let scale = 2
        let image = MenuBarBadgeRenderer.image(for: badges)
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
        return Pixels(bytes: Array(buffer), bytesPerRow: bitmap.bytesPerRow)
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

        let slots = snapshot.menuBarSlots(pins: MenuBarPins().toggling(second).toggling(gone))

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

        XCTAssertEqual(store.freshness(of: snapshot.menuBarSlots(pins: pins)).fetchedAt, older)
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
