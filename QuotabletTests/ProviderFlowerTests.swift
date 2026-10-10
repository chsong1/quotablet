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

    func testPetalsFollowTheMenuBarOrderAndCarryEachProvidersUsedPercentAndBadge() {
        let petals = providers().map(Petal.init)

        XCTAssertEqual(petals.map(\.text), ["79%", "94%", "1%", "100%"])
        XCTAssertEqual(percents(petals), [79, 94, 1, 100])
        XCTAssertEqual(petals.map(\.isStale), [false, false, false, false])
        XCTAssertEqual(petals.map(\.badge), [AttentionBadge(urgency: .exhausted, count: 5), nil, nil, AttentionBadge(urgency: .exhausted, count: 1)])
    }

    func testAProviderWithNoMeasuredAccountGetsAnOutlinePetalWithADashAndNoBadge() {
        let petals = providers(unmeasuredClaudeAccounts: 5).map(Petal.init)

        XCTAssertEqual(petals.map(\.text), ["–", "94%", "1%", "100%"])
        XCTAssertEqual(percents(petals), [nil, 94, 1, 100])
        XCTAssertNil(petals[0].badge)
    }

    func testPetalsTurnStaleWhenEveryMeasuredAccountOfTheirProviderReachesTheStaleBoundary() {
        XCTAssertEqual(providers(afterSeconds: 899).map(Petal.init).map(\.isStale), [false, false, false, false])
        XCTAssertEqual(providers(afterSeconds: 900).map(Petal.init).map(\.isStale), [true, true, true, true])
    }

    func testAnAccountPetalCarriesItsNumberItsCapacityFillAndItsOwnBadge() throws {
        let detail = try XCTUnwrap(RealisticFixture.snapshot().providerDetail(of: "anthropic", now: RealisticFixture.fetchedAt))

        let petals = detail.accounts.map(Petal.init)

        XCTAssertEqual(petals.map(\.text), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(percents(petals), [100, 90, 80, 70, 55])
        XCTAssertEqual(petals.map(\.badge), [AttentionBadge?](repeating: AttentionBadge(urgency: .exhausted, count: 1), count: 5))
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
                attention: ProviderAttention(exhaustedAccounts: exhausted, nearLimitAccounts: nearLimit)
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

    func testALogoKeepsItsHeightAndShrinksOnlyWhenItIsWiderThanTheLimit() {
        XCTAssertEqual(LogoFit.size(aspectRatio: 1, height: 18, maxWidth: 36), CGSize(width: 18, height: 18))
        XCTAssertEqual(LogoFit.size(aspectRatio: 0.5, height: 18, maxWidth: 36), CGSize(width: 9, height: 18))
        XCTAssertEqual(LogoFit.size(aspectRatio: 2, height: 18, maxWidth: 36), CGSize(width: 36, height: 18))
        XCTAssertEqual(LogoFit.size(aspectRatio: 4, height: 18, maxWidth: 36), CGSize(width: 36, height: 9))
    }

    func testPetalDigitsNeverGrowAsPetalsMultiplyAndScaleInStepWithTheFlower() throws {
        let sizes = FlowerLayout.petalRange.map { PetalLabelStyle.percent(petalCount: $0, diameter: 300).size }
        for (wider, narrower) in zip(sizes, sizes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(wider, narrower)
        }
        XCTAssertGreaterThan(try XCTUnwrap(sizes.first), try XCTUnwrap(sizes.last))
        for count in FlowerLayout.petalRange {
            XCTAssertEqual(PetalLabelStyle.percent(petalCount: count, diameter: 150).size * 2, PetalLabelStyle.percent(petalCount: count, diameter: 300).size, accuracy: 1e-9)
        }
        let numbers = FlowerLayout.petalRange.map { PetalLabelStyle.number(petalCount: $0).size }
        for (wider, narrower) in zip(numbers, numbers.dropFirst()) {
            XCTAssertGreaterThanOrEqual(wider, narrower)
        }
    }

    private func providers(unmeasuredClaudeAccounts: Int = 0, afterSeconds: TimeInterval = 0) -> [ProviderUsage] {
        RealisticFixture.snapshot(unmeasuredClaudeAccounts: unmeasuredClaudeAccounts)
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

final class FlowerGeometryTests: XCTestCase {
    func testAPointResolvesToThePetalThatHoldsItAndToNilOverGapsTheHoleAndOutside() {
        let flower = FlowerGeometry(petalCount: 4, diameter: 150)
        let middle = flower.center
        // Twelve, three, six and nine o'clock, 46 pt from the center.
        let compass = [
            CGPoint(x: middle.x, y: middle.y - 46),
            CGPoint(x: middle.x + 46, y: middle.y),
            CGPoint(x: middle.x, y: middle.y + 46),
            CGPoint(x: middle.x - 46, y: middle.y),
        ]
        // The 6 degree gap between the first two petals runs along the up-right diagonal.
        let gap = CGPoint(x: middle.x + 46 * cos(-.pi / 4), y: middle.y + 46 * sin(-.pi / 4))

        XCTAssertEqual(compass.map { flower.index(containing: $0) }, [0, 1, 2, 3])
        XCTAssertNil(flower.index(containing: gap))
        XCTAssertNil(flower.index(containing: middle))
        XCTAssertNil(flower.index(containing: CGPoint(x: 200, y: 75)))
    }

    func testEveryPetalOfEveryFlowerSizeIsFoundAtItsOwnAxis() {
        for count in FlowerLayout.petalRange {
            let flower = FlowerGeometry(petalCount: count, diameter: 300)

            let found = flower.petals.map { flower.index(containing: $0.axisPoint(atRadius: 100, in: flower.center)) }

            XCTAssertEqual(found, Array(0..<count), "\(count) petals")
        }
    }
}

final class PetalGeometryTests: XCTestCase {
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
        for count in FlowerLayout.petalRange {
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

    func testAxisPointsLieOnTheirPetalAndItsBadgeSitsInsideNearTheTip() {
        for count in FlowerLayout.petalRange {
            for index in 0..<count {
                let petal = PetalGeometry(petalCount: count, index: index, outerRadius: 75)
                let path = petal.path(in: center)
                let onAxis = petal.axisPoint(atRadius: 65.5, in: center)
                let badge = petal.badgeCenter(in: center)
                let badgeDistance = hypot(badge.x - center.x, badge.y - center.y)

                XCTAssertEqual(hypot(onAxis.x - center.x, onAxis.y - center.y), 65.5, accuracy: 1e-6)
                XCTAssertTrue(path.contains(onAxis), "\(count) petals, index \(index)")
                XCTAssertGreaterThan(badgeDistance, 75 * 0.8)
                XCTAssertLessThan(badgeDistance, 75)
                XCTAssertTrue(path.contains(badge), "badge of \(count) petals, index \(index)")
            }
        }
    }

    func testABoxBeyondTheTipKeepsTheSameGapWhateverThePetalsAngle() {
        let size = CGSize(width: 36, height: 18)
        let petals = (0..<4).map { PetalGeometry(petalCount: 4, index: $0, outerRadius: 75) }

        let centers = petals.map { $0.boxCenter(size: size, beyondTipBy: 7, in: center) }

        // Twelve and six o'clock clear half the box's height, and three and nine o'clock half its width.
        XCTAssertEqual(centers[0].x, 100, accuracy: 1e-9)
        XCTAssertEqual(centers[0].y, 100 - (75 + 7 + 9), accuracy: 1e-9)
        XCTAssertEqual(centers[1].x, 100 + (75 + 7 + 18), accuracy: 1e-9)
        XCTAssertEqual(centers[1].y, 100, accuracy: 1e-9)
        XCTAssertEqual(centers[2].x, 100, accuracy: 1e-9)
        XCTAssertEqual(centers[2].y, 100 + (75 + 7 + 9), accuracy: 1e-9)
        XCTAssertEqual(centers[3].x, 100 - (75 + 7 + 18), accuracy: 1e-9)
        XCTAssertEqual(centers[3].y, 100, accuracy: 1e-9)
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
