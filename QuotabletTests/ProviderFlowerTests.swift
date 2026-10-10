import CoreGraphics
import SwiftUI
import XCTest

final class ProviderFlowerTests: XCTestCase {
    func testAFlowerNeedsThreeToEightProvidersAndOtherCountsGetTheLegendAlone() {
        let layouts = (0...10).map(FlowerLayout.forProviderCount)

        XCTAssertEqual(layouts, [
            .legendOnly, .legendOnly, .legendOnly,
            .flowerAndLegend, .flowerAndLegend, .flowerAndLegend, .flowerAndLegend, .flowerAndLegend, .flowerAndLegend,
            .legendOnly, .legendOnly
        ])
    }

    func testPetalsFollowTheMenuBarOrderAndCarryEachProvidersLetterAndFillAsWholePercents() {
        let petals = providers().map(Petal.init)

        XCTAssertEqual(petals.map(\.letter), ["C", "O", "G", "U"])
        XCTAssertEqual(percents(petals), [79, 94, 1, 100])
        XCTAssertEqual(petals.map(\.isStale), [false, false, false, false])
    }

    func testAProviderWithNoMeasuredAccountGetsAPetalWithoutAFill() {
        let petals = providers(unmeasuredClaudeAccounts: 5).map(Petal.init)

        XCTAssertEqual(petals.map(\.letter), ["C", "O", "G", "U"])
        XCTAssertEqual(percents(petals), [nil, 94, 1, 100])
    }

    func testPetalsTurnStaleWhenTheirProvidersDataReachesTheStaleBoundary() {
        XCTAssertEqual(providers(afterSeconds: 899).map(Petal.init).map(\.isStale), [false, false, false, false])
        XCTAssertEqual(providers(afterSeconds: 900).map(Petal.init).map(\.isStale), [true, true, true, true])
    }

    func testTheLegendSaysHowManyAccountsEachFigureCovers() {
        XCTAssertEqual(providers().map(\.accountsPhrase), ["5 accounts", "3 accounts", "1 account", "1 account"])
        XCTAssertEqual(providers(unmeasuredClaudeAccounts: 1).map(\.accountsPhrase), ["4 of 5 accounts", "3 accounts", "1 account", "1 account"])
        XCTAssertEqual(providers(unmeasuredClaudeAccounts: 5).first?.accountsPhrase, "5 accounts")
    }

    func testTheLegendReadsTheUsedShareOrUnknown() {
        XCTAssertEqual(providers().map(\.usedText), ["79% used", "94% used", "1% used", "100% used"])
        XCTAssertEqual(providers(unmeasuredClaudeAccounts: 1).first?.usedText, "74% used")
        XCTAssertEqual(providers(unmeasuredClaudeAccounts: 5).first?.usedText, "Unknown")
    }

    func testEachLegendRowSpeaksItsProvidersSummaryAndEndsWithStaleWhenItIs() {
        XCTAssertEqual(providers().map(\.legendAccessibilityLabel), [
            "Claude 79% used across 5 accounts",
            "Codex 94% used across 3 accounts",
            "Grok 1% used, 1 account",
            "Cursor 100% used, 1 account"
        ])
        XCTAssertEqual(providers(afterSeconds: 900).map(\.legendAccessibilityLabel), [
            "Claude 79% used across 5 accounts, stale",
            "Codex 94% used across 3 accounts, stale",
            "Grok 1% used, 1 account, stale",
            "Cursor 100% used, 1 account, stale"
        ])
        XCTAssertEqual(providers(unmeasuredClaudeAccounts: 5).first?.legendAccessibilityLabel, "Claude usage unknown across 5 accounts")
    }

    func testTheChartSpeaksEveryProvidersSummaryInOneSentence() {
        XCTAssertEqual(
            providers().spokenSummary,
            "Claude 79% used across 5 accounts; Codex 94% used across 3 accounts; Grok 1% used, 1 account; Cursor 100% used, 1 account"
        )
    }

    func testALegendLogoIsFourteenPointsTallAndShrinksOnlyWhenItIsWiderThanTwoToOne() {
        XCTAssertEqual(LegendLogo.size(aspectRatio: 1), CGSize(width: 14, height: 14))
        XCTAssertEqual(LegendLogo.size(aspectRatio: 0.5), CGSize(width: 7, height: 14))
        XCTAssertEqual(LegendLogo.size(aspectRatio: 2), CGSize(width: 28, height: 14))
        XCTAssertEqual(LegendLogo.size(aspectRatio: 4), CGSize(width: 28, height: 7))
    }

    func testThePaletteHoldsEightDistinctColorsAndWrapsPastThem() {
        XCTAssertEqual(Set((0..<8).map(QuotaPalette.color(at:))).count, 8)
        XCTAssertEqual(QuotaPalette.color(at: 8), QuotaPalette.color(at: 0))
        XCTAssertEqual(QuotaPalette.color(at: -1), QuotaPalette.color(at: 7))
    }

    private func providers(unmeasuredClaudeAccounts: Int = 0, afterSeconds: TimeInterval = 0) -> [ProviderUsage] {
        RealisticFixture.snapshot(unmeasuredClaudeAccounts: unmeasuredClaudeAccounts)
            .providerUsage(now: RealisticFixture.fetchedAt.addingTimeInterval(afterSeconds))
    }

    private func percents(_ petals: [Petal]) -> [Double?] {
        petals.map { petal in petal.usedFraction.map { ($0 * 100).rounded() } }
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

    func testLabelSitsInsideItsPetalAtTheMiddleOfTheOuterThird() {
        for count in FlowerLayout.petalRange {
            for index in 0..<count {
                let petal = PetalGeometry(petalCount: count, index: index, outerRadius: 75)
                let label = petal.labelCenter(in: center)

                XCTAssertEqual(hypot(label.x - center.x, label.y - center.y), 65.5, accuracy: 1e-6)
                XCTAssertTrue(petal.path(in: center).contains(label), "\(count) petals, index \(index)")
            }
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
