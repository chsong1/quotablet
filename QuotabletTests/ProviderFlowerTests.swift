import AppKit
import CoreGraphics
import SwiftUI
import XCTest

final class ProviderFlowerTests: XCTestCase {
    func testAFlowerNeedsThreeToEightItemsAndOtherCountsFallBackToRows() {
        XCTAssertEqual((0...10).map(FlowerLayout.forItemCount), [
            .list, .list, .list,
            .flower, .flower, .flower, .flower, .flower, .flower,
            .list, .list
        ])
    }

    func testAProviderPageDrawsAFlowerOfItsAccountsOnlyFromThreeToEightAccounts() throws {
        func layout(accountCount: Int) throws -> FlowerLayout {
            let drafts = (0..<accountCount).map { index in
                UsageReportDraft(
                    provider: "anthropic",
                    sourceAccount: SourceAccountIdentity(accountID: "claude-\(index)", organizationID: nil, projectID: nil),
                    privateDisplayLabel: nil,
                    fetchedAt: RealisticFixture.fetchedAt,
                    resetCredits: nil,
                    quotas: []
                )
            }
            let snapshot = UsageSnapshot(generatedAt: RealisticFixture.fetchedAt, reportDrafts: drafts)
            let detail = try XCTUnwrap(snapshot.providerDetail(of: "anthropic", now: RealisticFixture.fetchedAt))
            return FlowerLayout.forItemCount(detail.accounts.count)
        }

        XCTAssertEqual(try [2, 3, 8, 9].map(layout(accountCount:)), [.list, .flower, .flower, .list])
    }

    func testEmblemsFollowTheMenuBarOrderWithOnePetalPerAccountAndShowTheBusiestAccount() {
        let details = RealisticFixture.snapshot().providerDetails(now: RealisticFixture.fetchedAt)

        XCTAssertEqual(details.map(\.usage.provider), providers().map(\.provider))
        XCTAssertEqual(details.map { Petal.emblem(of: $0).count }, [5, 3, 1, 1])
        XCTAssertEqual(details.map { $0.peakFraction.map { ($0 * 100).rounded() } }, [100, 97, 1, 100])
    }

    func testAnEmblemsPeakSkipsUnmeasuredAccountsAndIsUnknownWhenNoneIsMeasured() throws {
        func claude(unmeasured: Int) throws -> ProviderDetail {
            try XCTUnwrap(RealisticFixture.snapshot(unmeasuredClaudeAccounts: unmeasured).providerDetails(now: RealisticFixture.fetchedAt).first)
        }

        XCTAssertEqual(try XCTUnwrap(try claude(unmeasured: 1).peakFraction), 0.9, accuracy: 1e-9)
        let unmeasured = try claude(unmeasured: 5)
        XCTAssertEqual(percents(Petal.emblem(of: unmeasured)), [nil, nil, nil, nil, nil])
        XCTAssertNil(unmeasured.peakFraction)
        XCTAssertEqual(UsageFormatting.usedPercent(unmeasured.peakFraction), "–")
    }

    func testPetalsTurnStaleWhenTheirAccountReachesTheStaleBoundary() throws {
        func stale(afterSeconds: TimeInterval) throws -> [Bool] {
            let now = RealisticFixture.fetchedAt.addingTimeInterval(afterSeconds)
            return Petal.emblem(of: try XCTUnwrap(RealisticFixture.snapshot().providerDetail(of: "anthropic", now: now))).map(\.isStale)
        }

        XCTAssertEqual(try stale(afterSeconds: 899), [false, false, false, false, false])
        XCTAssertEqual(try stale(afterSeconds: 900), [true, true, true, true, true])
    }

    func testAnEmblemSpeaksItsSummaryThenItsBusiestAccountWhenSeveralAccountsShareTheFigure() {
        XCTAssertEqual(RealisticFixture.snapshot().providerDetails(now: RealisticFixture.fetchedAt).map(\.emblemAccessibilityLabel), [
            "Claude 79% used across 5 accounts, 5 exhausted, busiest account 100% used",
            "Codex 94% used across 3 accounts, busiest account 97% used",
            "Grok 1% used, 1 account",
            "Cursor 100% used, 1 account, 1 exhausted"
        ])
    }

    func testAnAccountPetalCarriesItsNumberItsCapacityFillAndItsOwnUrgency() throws {
        let detail = try XCTUnwrap(RealisticFixture.snapshot().providerDetail(of: "anthropic", now: RealisticFixture.fetchedAt))

        let petals = detail.accounts.map(Petal.init)

        XCTAssertEqual(petals.map(\.text), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(percents(petals), [100, 90, 80, 70, 55])
        XCTAssertEqual(petals.map(\.urgency), [QuotaUrgency?](repeating: .exhausted, count: 5))
    }

    func testAListRowAndAPetalSayHowManyAccountsEachFigureCovers() {
        XCTAssertEqual(providers().map(\.accountsPhrase), ["5 accounts", "3 accounts", "1 account", "1 account"])
        XCTAssertEqual(providers(unmeasuredClaudeAccounts: 1).map(\.accountsPhrase), ["4 of 5 accounts", "3 accounts", "1 account", "1 account"])
        XCTAssertEqual(providers(unmeasuredClaudeAccounts: 5).first?.accountsPhrase, "5 accounts")
    }

    func testThePillReadsTheUsedShareOrUnknown() {
        XCTAssertEqual(providers().map(\.usedText), ["79% used", "94% used", "1% used", "100% used"])
        XCTAssertEqual(providers(unmeasuredClaudeAccounts: 1).first?.usedText, "74% used")
        XCTAssertEqual(providers(unmeasuredClaudeAccounts: 5).first?.usedText, "Unknown")
    }

    func testEachPetalSpeaksItsProvidersSummaryThenWhatNeedsAttentionThenStale() {
        XCTAssertEqual(providers().map(\.petalAccessibilityLabel), [
            "Claude 79% used across 5 accounts, 5 exhausted",
            "Codex 94% used across 3 accounts",
            "Grok 1% used, 1 account",
            "Cursor 100% used, 1 account, 1 exhausted"
        ])
        XCTAssertEqual(providers(afterSeconds: 900).map(\.petalAccessibilityLabel), [
            "Claude 79% used across 5 accounts, 5 exhausted, stale",
            "Codex 94% used across 3 accounts, stale",
            "Grok 1% used, 1 account, stale",
            "Cursor 100% used, 1 account, 1 exhausted, stale"
        ])
        XCTAssertEqual(providers(unmeasuredClaudeAccounts: 1).first?.petalAccessibilityLabel, "Claude 74% used across 4 of 5 accounts, 4 exhausted")
        XCTAssertEqual(providers(unmeasuredClaudeAccounts: 5).first?.petalAccessibilityLabel, "Claude usage unknown across 5 accounts")
    }

    func testAPetalSpeaksBothAttentionCountsWhenSomeAccountsRanOutAndSomeAreClose() {
        func label(exhausted: Int, nearLimit: Int) -> String {
            ProviderUsage(
                provider: "anthropic",
                accountCount: 5,
                measured: [],
                usedFraction: 0.68,
                isStale: false,
                attention: ProviderAttention(exhaustedAccounts: exhausted, nearLimitAccounts: nearLimit),
                disconnectedCount: 0,
                noUsageDataCount: 0
            ).petalAccessibilityLabel
        }

        XCTAssertEqual(label(exhausted: 0, nearLimit: 1), "Claude 68% used across 5 accounts, 1 near limit")
        XCTAssertEqual(label(exhausted: 1, nearLimit: 2), "Claude 68% used across 5 accounts, 1 exhausted, 2 near limit")
        XCTAssertEqual(label(exhausted: 0, nearLimit: 0), "Claude 68% used across 5 accounts")
    }

    func testTheMenuBarItemSpeaksEveryProvidersSummaryInOneSentence() {
        XCTAssertEqual(
            providers().spokenSummary,
            "Claude 79% used across 5 accounts; Codex 94% used across 3 accounts; Grok 1% used, 1 account; Cursor 100% used, 1 account"
        )
    }

    func testAProviderWithOnlyProblemAccountsGetsOneUnmeasuredRingAndASignInCount() throws {
        let snapshot = UsageSnapshot(
            generatedAt: RealisticFixture.fetchedAt,
            reportDrafts: [],
            accountProblems: Array(repeating: RealisticFixture.problem(), count: 5)
        )

        let detail = try XCTUnwrap(snapshot.providerDetails(now: RealisticFixture.fetchedAt).first)
        let petals = Petal.emblem(of: detail)

        XCTAssertEqual(petals.count, 1)
        XCTAssertNil(petals[0].usedFraction)
        XCTAssertNil(petals[0].urgency)
        XCTAssertEqual(detail.usage.problemCount, 5)
        XCTAssertEqual(detail.usage.usedText, "—")
        XCTAssertEqual(detail.emblemAccessibilityLabel, "Claude, 5 accounts need sign-in")
    }

    func testAProviderCountsEachOfItsAccountsThatNeedSignIn() {
        let problems = [
            RealisticFixture.problem(.disconnected),
            RealisticFixture.problem(.disconnected),
            RealisticFixture.problem(.noUsageData),
            RealisticFixture.problem(.noUsageData, provider: "cursor")
        ]

        XCTAssertEqual(providers(accountProblems: problems).map(\.problemCount), [3, 0, 0, 1])
    }

    func testTheSpokenSummaryAppendsEachProblemCountAfterTheFigureAndTheAccounts() {
        func summary(accounts: Int, used: Double?, disconnected: Int = 0, noUsageData: Int = 0) -> String {
            ProviderUsage(
                provider: "anthropic",
                accountCount: accounts,
                measured: [],
                usedFraction: used,
                isStale: false,
                attention: ProviderAttention(exhaustedAccounts: 0, nearLimitAccounts: 0),
                disconnectedCount: disconnected,
                noUsageDataCount: noUsageData
            ).spokenSummary
        }

        XCTAssertEqual(summary(accounts: 4, used: 0.77), "Claude 77% used across 4 accounts")
        XCTAssertEqual(summary(accounts: 4, used: 0.77, disconnected: 1), "Claude 77% used across 4 accounts, 1 account needs sign-in")
        XCTAssertEqual(summary(accounts: 4, used: 0.77, disconnected: 5), "Claude 77% used across 4 accounts, 5 accounts need sign-in")
        XCTAssertEqual(summary(accounts: 2, used: nil), "Claude usage unknown across 2 accounts")
        XCTAssertEqual(summary(accounts: 2, used: nil, disconnected: 1), "Claude usage unknown across 2 accounts, 1 account needs sign-in")
        XCTAssertEqual(summary(accounts: 2, used: nil, disconnected: 5), "Claude usage unknown across 2 accounts, 5 accounts need sign-in")
        XCTAssertEqual(summary(accounts: 0, used: nil, disconnected: 1), "Claude, 1 account needs sign-in")
        XCTAssertEqual(summary(accounts: 0, used: nil, disconnected: 5), "Claude, 5 accounts need sign-in")
        XCTAssertEqual(
            summary(accounts: 1, used: 0.01, disconnected: 1, noUsageData: 2),
            "Claude 1% used, 1 account, 1 account needs sign-in, 2 accounts without usage data"
        )
    }

    func testThePetalTheMenuBarItemAndTheProviderPageShareOneProblemWording() throws {
        let problems = Array(repeating: RealisticFixture.problem(), count: 5)
        let usage = providers(accountProblems: problems)
        let detail = try XCTUnwrap(RealisticFixture.snapshot(accountProblems: problems).providerDetail(of: "anthropic", now: RealisticFixture.fetchedAt))

        XCTAssertEqual(usage.first?.petalAccessibilityLabel, "Claude 79% used across 5 accounts, 5 accounts need sign-in, 5 exhausted")
        XCTAssertEqual(
            usage.spokenSummary,
            "Claude 79% used across 5 accounts, 5 accounts need sign-in; Codex 94% used across 3 accounts; Grok 1% used, 1 account; Cursor 100% used, 1 account"
        )
        XCTAssertEqual(detail.usage.spokenSummary, "Claude 79% used across 5 accounts, 5 accounts need sign-in")
    }

    func testAListRowSaysItsAccountsThenItsProblemsOrOnlyTheProblemsWhenNoAccountHasAReport() throws {
        let withReports = providers(unmeasuredClaudeAccounts: 1, accountProblems: [RealisticFixture.problem()])
        let onlyProblems = try XCTUnwrap(
            UsageSnapshot(
                generatedAt: RealisticFixture.fetchedAt,
                reportDrafts: [],
                accountProblems: [RealisticFixture.problem(), RealisticFixture.problem(), RealisticFixture.problem(.noUsageData)]
            ).providerUsage(now: RealisticFixture.fetchedAt).first
        )

        XCTAssertEqual(withReports.map(\.accountsLine), ["4 of 5 accounts, 1 account needs sign-in", "3 accounts", "1 account", "1 account"])
        XCTAssertEqual(onlyProblems.accountsLine, "2 accounts need sign-in, 1 account without usage data")
    }

    func testALogoKeepsItsHeightAndShrinksOnlyWhenItIsWiderThanTheLimit() {
        XCTAssertEqual(LogoFit.size(aspectRatio: 1, height: 18, maxWidth: 36), CGSize(width: 18, height: 18))
        XCTAssertEqual(LogoFit.size(aspectRatio: 0.5, height: 18, maxWidth: 36), CGSize(width: 9, height: 18))
        XCTAssertEqual(LogoFit.size(aspectRatio: 2, height: 18, maxWidth: 36), CGSize(width: 36, height: 18))
        XCTAssertEqual(LogoFit.size(aspectRatio: 4, height: 18, maxWidth: 36), CGSize(width: 36, height: 9))
    }

    func testAccountDigitsNeverGrowAsPetalsMultiply() {
        let numbers = FlowerLayout.petalRange.map { PetalLabelStyle.number(petalCount: $0).size }
        for (wider, narrower) in zip(numbers, numbers.dropFirst()) {
            XCTAssertGreaterThanOrEqual(wider, narrower)
        }
    }

    private func providers(
        unmeasuredClaudeAccounts: Int = 0,
        afterSeconds: TimeInterval = 0,
        accountProblems: [AccountProblem] = []
    ) -> [ProviderUsage] {
        RealisticFixture.snapshot(unmeasuredClaudeAccounts: unmeasuredClaudeAccounts, accountProblems: accountProblems)
            .providerUsage(now: RealisticFixture.fetchedAt.addingTimeInterval(afterSeconds))
    }

    private func percents(_ petals: [Petal]) -> [Double?] {
        petals.map { petal in petal.usedFraction.map { ($0 * 100).rounded() } }
    }
}

final class QuotaPaletteTests: XCTestCase {
    func testThePaletteHoldsEightDistinctColorsAndWrapsPastThem() {
        XCTAssertEqual(Set((0..<8).map(QuotaPalette.color(at:))).count, 8)
        XCTAssertEqual(QuotaPalette.color(at: 8), QuotaPalette.color(at: 0))
        XCTAssertEqual(QuotaPalette.color(at: -1), QuotaPalette.color(at: 7))
    }

    @MainActor
    func testNoPaletteColorIsAVividRedOrangeYellowOrGreen() throws {
        // Status badges and inks use these hues. A muted color such as gray or brown has a hue on paper and means no status.
        func readsAsStatus(_ color: ColorProbe.RGB) -> Bool {
            guard let hue = color.hue else { return false }
            return color.saturation >= 0.5 && (hue >= 345 || hue < 170)
        }

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for index in 0..<8 {
                let color = try ColorProbe.resolve(NSColor(QuotaPalette.color(at: index)), in: name)
                XCTAssertFalse(readsAsStatus(color), "palette color \(index) in \(name.rawValue), hue \(color.hue ?? -1), saturation \(color.saturation)")
            }
            // The check flags the colors the palette used to hold, so it cannot pass for want of a working hue test.
            for old in [Color.orange, .green, .pink, .yellow] {
                XCTAssertTrue(readsAsStatus(try ColorProbe.resolve(NSColor(old), in: name)), "\(old) in \(name.rawValue)")
            }
        }
    }

    // Three to one is the limit WCAG sets for large text, which a petal's digits are.
    @MainActor
    func testThePetalInkReadsAtThreeToOneOnEveryPaletteColorInBothAppearances() throws {
        let ink = try XCTUnwrap(NSColor(PetalLook.inkOnColor).usingColorSpace(.sRGB))
        let alpha = Double(ink.alphaComponent)

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for index in 0..<8 {
                let fill = try ColorProbe.resolve(NSColor(QuotaPalette.color(at: index)), in: name)
                let over = ColorProbe.RGB(
                    red: Double(ink.redComponent) * alpha + fill.red * (1 - alpha),
                    green: Double(ink.greenComponent) * alpha + fill.green * (1 - alpha),
                    blue: Double(ink.blueComponent) * alpha + fill.blue * (1 - alpha)
                )
                XCTAssertGreaterThanOrEqual(ColorProbe.contrast(over, fill), 3, "palette color \(index) in \(name.rawValue)")
            }
        }
    }
}

final class EmblemGridTests: XCTestCase {
    func testEmblemsFillRowsOfOneTwoOrThreeAndTooManyProvidersFallBackToRows() {
        XCTAssertEqual((0...10).map(EmblemGrid.columns(forProviderCount:)), [nil, 1, 2, 2, 2, 3, 3, 3, 3, 3, nil])
    }
}

final class FlowerGeometryTests: XCTestCase {
    func testEveryPetalOfEveryFlowerSizeHoldsItsOwnAxisAndNoOtherPetalDoes() {
        for count in 1...8 {
            let flower = FlowerGeometry(petalCount: count, diameter: 300)
            let paths = flower.petals.map { $0.path(in: flower.center) }

            for petal in flower.petals {
                let onAxis = petal.axisPoint(atRadius: 100, in: flower.center)
                XCTAssertEqual(paths.indices.filter { paths[$0].contains(onAxis) }, [petal.index], "\(count) petals")
            }
        }
    }
}

final class PetalGeometryTests: XCTestCase {
    func testFillRadiusSpansTheInnerToTheOuterEdgeAndGrowsWithTheFraction() {
        for count in [1, 2, 3, 8] {
            let petal = PetalGeometry(petalCount: count, index: 0, outerRadius: 75)
            // Petals start at the logo's hole, and a ring farther out, near the rim.
            let inner: CGFloat = count == 1 ? 45 : 21

            XCTAssertEqual(petal.innerRadius, inner, accuracy: 1e-9)
            XCTAssertEqual(petal.fillRadius(forUsedFraction: 0), inner, accuracy: 1e-9)
            XCTAssertEqual(petal.fillRadius(forUsedFraction: 1), 75)
            XCTAssertEqual(petal.fillRadius(forUsedFraction: -0.5), inner, accuracy: 1e-9)
            XCTAssertEqual(petal.fillRadius(forUsedFraction: 2), 75)
            let radii = (0...10).map { petal.fillRadius(forUsedFraction: Double($0) / 10) }
            for (lower, upper) in zip(radii, radii.dropFirst()) {
                XCTAssertLessThan(lower, upper, "\(count) petals")
            }
        }
    }

    func testFillRadiusCoversTheFractionOfThePetalAreaNotOfItsLength() {
        for count in [1, 3, 8] {
            let petal = PetalGeometry(petalCount: count, index: 0, outerRadius: 75)
            let fractions = [0.25, 0.5, 0.75]
            let radii = fractions.map { petal.fillRadius(forUsedFraction: $0) }

            let sample = sampledArea(of: petal, insideDisks: radii)

            for (fraction, covered) in zip(fractions, sample.inside) {
                XCTAssertEqual(covered / sample.total, fraction, accuracy: 0.01, "\(count) petals at \(fraction)")
            }
        }
    }

    func testAreaWithinRadiusMatchesASampledGrid() {
        for count in [1, 3, 8] {
            let petal = PetalGeometry(petalCount: count, index: 0, outerRadius: 75)
            let radii: [CGFloat] = [30, 50, 70, 75]

            let sample = sampledArea(of: petal, insideDisks: radii)

            for (radius, covered) in zip(radii, sample.inside) {
                XCTAssertEqual(Double(petal.area(withinRadius: radius)), covered, accuracy: 0.01 * sample.total, "\(count) petals within \(radius)")
            }
            XCTAssertEqual(petal.area(withinRadius: 10), 0)
            XCTAssertEqual(petal.area(withinRadius: 21), 0, accuracy: 1e-9)
            XCTAssertEqual(petal.area(withinRadius: 200), petal.area(withinRadius: 75))
        }
    }

    func testPetalsOfOneFlowerNeverShareAPoint() {
        let step: CGFloat = 0.5
        for count in 1...8 {
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

    func testAPetalIsPointedAtBothEndsAndFullPastItsMiddle() {
        let path = PetalGeometry(petalCount: 3, index: 0, outerRadius: 75).path(in: center)
        // The petal's axis points to 12 o'clock.
        func point(radius: CGFloat, degrees: CGFloat) -> CGPoint {
            CGPoint(x: center.x + radius * cos(degrees * .pi / 180), y: center.y + radius * sin(degrees * .pi / 180))
        }

        XCTAssertTrue(path.contains(point(radius: 73, degrees: -90)))
        XCTAssertTrue(path.contains(point(radius: 23, degrees: -90)))
        XCTAssertFalse(path.contains(point(radius: 73, degrees: -96)))
        XCTAssertFalse(path.contains(point(radius: 73, degrees: -84)))
        XCTAssertFalse(path.contains(point(radius: 23, degrees: -100)))
        XCTAssertFalse(path.contains(point(radius: 23, degrees: -80)))
        XCTAssertTrue(path.contains(point(radius: 52, degrees: -110)))
        XCTAssertTrue(path.contains(point(radius: 52, degrees: -70)))
    }

    func testAOnePetalFlowerIsABandNearTheRimAroundAnEmptyMiddle() {
        let path = PetalGeometry(petalCount: 1, index: 0, outerRadius: 75).path(in: center)

        for degrees in stride(from: CGFloat(0), to: 360, by: 30) {
            let angle = degrees * .pi / 180
            func point(_ radius: CGFloat) -> CGPoint { CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)) }
            XCTAssertTrue(path.contains(point(60)), "\(degrees) degrees")
            XCTAssertFalse(path.contains(point(30)), "\(degrees) degrees")
            XCTAssertFalse(path.contains(point(80)), "\(degrees) degrees")
        }
    }

    private var center: CGPoint { CGPoint(x: 100, y: 100) }

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
