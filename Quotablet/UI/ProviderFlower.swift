import CoreGraphics
import SwiftUI

enum FlowerLayout: Equatable {
    case legendOnly
    case flowerAndLegend

    static let petalRange = 3...8

    static func forProviderCount(_ count: Int) -> FlowerLayout {
        petalRange.contains(count) ? .flowerAndLegend : .legendOnly
    }
}

// What one petal draws. The petals follow the providers' order, so a petal's position is its provider's rank.
struct Petal: Equatable, Sendable {
    let letter: String
    // Nil when no account of the provider is measured. The petal then has an outline and no fill.
    let usedFraction: Double?
    let isStale: Bool

    init(_ usage: ProviderUsage) {
        letter = ProviderRegistry.badgeLetter(for: usage.provider)
        usedFraction = usage.usedFraction
        isStale = usage.isStale
    }
}

extension ProviderUsage {
    var usedText: String {
        usedFraction == nil ? "Unknown" : "\(UsageFormatting.usedPercent(usedFraction)) used"
    }

    var legendAccessibilityLabel: String {
        isStale ? "\(spokenSummary), stale" : spokenSummary
    }
}

// One petal of a flower in a y-down plane such as a SwiftUI canvas. Index 0 is centered at 12 o'clock and
// the indexes run clockwise on screen.
struct PetalGeometry: Equatable, Sendable {
    private static let innerRadiusRatio: CGFloat = 0.24
    private static let outerCornerRatio: CGFloat = 0.16
    private static let innerCornerRatio: CGFloat = 0.06
    private static let integrationSteps = 128
    private static let bisectionSteps = 48

    let petalCount: Int
    let index: Int
    let outerRadius: CGFloat

    init(petalCount: Int, index: Int, outerRadius: CGFloat) {
        precondition(FlowerLayout.petalRange.contains(petalCount), "A flower has \(FlowerLayout.petalRange) petals.")
        precondition((0..<petalCount).contains(index), "A petal index must name one of the flower's petals.")
        self.petalCount = petalCount
        self.index = index
        self.outerRadius = outerRadius
    }

    var innerRadius: CGFloat { outerRadius * Self.innerRadiusRatio }
    var gapDegrees: CGFloat { 6 }

    // A rounded corner is a circle tangent to the petal's radial side and to the inner or outer arc.
    private struct Rounding {
        let centerRadius: CGFloat
        let radius: CGFloat
        // Angle between the radial side and the circle's center, seen from the flower's center.
        let offsetAngle: CGFloat
        // Distance from the flower's center to the point where the circle leaves the radial side.
        let edgeRadius: CGFloat

        init(centerRadius: CGFloat, radius: CGFloat) {
            self.centerRadius = centerRadius
            self.radius = radius
            offsetAngle = asin(radius / centerRadius)
            edgeRadius = (centerRadius * centerRadius - radius * radius).squareRoot()
        }

        // How far the rounding pulls the petal's side in from its radial line, as an angle, at `rho` from the center.
        // Only meaningful between `edgeRadius` and the arc the circle touches.
        func inset(atRadius rho: CGFloat) -> CGFloat {
            let cosine = (rho * rho + centerRadius * centerRadius - radius * radius) / (2 * rho * centerRadius)
            return offsetAngle - acos(min(max(cosine, -1), 1))
        }
    }

    private var innerRounding: Rounding {
        let radius = outerRadius * Self.innerCornerRatio
        return Rounding(centerRadius: innerRadius + radius, radius: radius)
    }

    private var outerRounding: Rounding {
        let radius = outerRadius * Self.outerCornerRatio
        return Rounding(centerRadius: outerRadius - radius, radius: radius)
    }

    private var centerAngle: CGFloat {
        -.pi / 2 + 2 * .pi * CGFloat(index) / CGFloat(petalCount)
    }

    private var halfSpan: CGFloat {
        (2 * .pi / CGFloat(petalCount) - gapDegrees * .pi / 180) / 2
    }

    func path(in center: CGPoint) -> CGPath {
        let inner = innerRounding
        let outer = outerRounding
        let first = centerAngle - halfSpan
        let last = centerAngle + halfSpan
        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }

        // Every arc but the inner one runs toward larger angles, which is clockwise on screen.
        let path = CGMutablePath()
        path.move(to: point(inner.edgeRadius, first))
        path.addLine(to: point(outer.edgeRadius, first))
        path.addArc(
            center: point(outer.centerRadius, first + outer.offsetAngle), radius: outer.radius,
            startAngle: first - .pi / 2, endAngle: first + outer.offsetAngle, clockwise: false
        )
        path.addArc(
            center: center, radius: outerRadius,
            startAngle: first + outer.offsetAngle, endAngle: last - outer.offsetAngle, clockwise: false
        )
        path.addArc(
            center: point(outer.centerRadius, last - outer.offsetAngle), radius: outer.radius,
            startAngle: last - outer.offsetAngle, endAngle: last + .pi / 2, clockwise: false
        )
        path.addLine(to: point(inner.edgeRadius, last))
        path.addArc(
            center: point(inner.centerRadius, last - inner.offsetAngle), radius: inner.radius,
            startAngle: last + .pi / 2, endAngle: last - inner.offsetAngle + .pi, clockwise: false
        )
        path.addArc(
            center: center, radius: innerRadius,
            startAngle: last - inner.offsetAngle, endAngle: first + inner.offsetAngle, clockwise: true
        )
        path.addArc(
            center: point(inner.centerRadius, first + inner.offsetAngle), radius: inner.radius,
            startAngle: first + inner.offsetAngle + .pi, endAngle: first + 3 * .pi / 2, clockwise: false
        )
        path.closeSubpath()
        return path
    }

    // The middle of the petal's outer third, where its label sits.
    func labelCenter(in center: CGPoint) -> CGPoint {
        let radius = innerRadius + (outerRadius - innerRadius) * 5 / 6
        return CGPoint(x: center.x + radius * cos(centerAngle), y: center.y + radius * sin(centerAngle))
    }

    // Integrates the petal's angular width over the rings inside `radius`. The rounded corners have no simple
    // area once a disk cuts through them, so this stays numeric.
    func area(withinRadius radius: CGFloat) -> CGFloat {
        let limit = min(radius, outerRadius)
        guard limit > innerRadius else { return 0 }
        let inner = innerRounding
        let outer = outerRounding
        let span = 2 * halfSpan
        let ringWidth = (limit - innerRadius) / CGFloat(Self.integrationSteps)
        var area: CGFloat = 0
        for ring in 0..<Self.integrationSteps {
            let rho = innerRadius + (CGFloat(ring) + 0.5) * ringWidth
            let pulledIn: CGFloat
            if rho < inner.edgeRadius {
                pulledIn = inner.inset(atRadius: rho)
            } else if rho > outer.edgeRadius {
                pulledIn = outer.inset(atRadius: rho)
            } else {
                pulledIn = 0
            }
            area += (span - 2 * pulledIn) * rho * ringWidth
        }
        return area
    }

    // Petals widen outward, so a radius that is linear in the fraction would understate small values and
    // overstate large ones. This is the radius whose disk covers that fraction of the petal's area.
    func fillRadius(forUsedFraction fraction: Double) -> CGFloat {
        guard fraction > 0 else { return innerRadius }
        guard fraction < 1 else { return outerRadius }
        let target = CGFloat(fraction) * area(withinRadius: outerRadius)
        var low = innerRadius
        var high = outerRadius
        for _ in 0..<Self.bisectionSteps {
            let middle = (low + high) / 2
            if area(withinRadius: middle) < target {
                low = middle
            } else {
                high = middle
            }
        }
        return (low + high) / 2
    }
}

enum QuotaPalette {
    // Petals next to each other contrast, so the order is part of the design.
    private static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .yellow]

    static func color(at index: Int) -> Color {
        colors[(index % colors.count + colors.count) % colors.count]
    }
}

extension LogoAppearance {
    init(_ scheme: ColorScheme) {
        self = scheme == .dark ? .dark : .light
    }
}

// A logo in a legend row is 14 pt tall. One wider than 2:1 shrinks with its shape unchanged, so a wide wordmark cannot push the percent off the card.
enum LegendLogo {
    static let height: CGFloat = 14
    static let maxWidth: CGFloat = 28

    static func size(aspectRatio: CGFloat) -> CGSize {
        let width = min(height * aspectRatio, maxWidth)
        return CGSize(width: width, height: width / aspectRatio)
    }
}

private enum FlowerMetrics {
    static let chartDiameter: CGFloat = 150
    static let columnSpacing: CGFloat = 14
    static let rowSpacing: CGFloat = 8
    static let markSpacing: CGFloat = 6
    static let dotDiameter: CGFloat = 8
}

private enum PetalLook {
    static let trackOpacity = 0.22
    static let staleOpacity = 0.55
    static let staleSaturation = 0.4
    static let outlineWidth: CGFloat = 1.5
    static let stripeThickness: CGFloat = 1.5
    static let fullFillOverhang: CGFloat = 2
    static let labelShadowOpacity = 0.4
    static let labelShadowRadius: CGFloat = 1
    static let labelShadowOffset: CGFloat = 0.5
}

struct ProviderFlowerCard: View {
    let providers: [ProviderUsage]
    let logos: ProviderLogoCatalog
    // The logo variant follows the panel's appearance, as the menu bar's follows its own.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let appearance = LogoAppearance(colorScheme)
        let marks = providers.map { logos.logo(for: $0.provider, appearance: appearance) }
        // Every row reserves the widest logo's width, so the names line up even when a provider has no logo file.
        let logoColumnWidth = marks.compactMap { $0.map { LegendLogo.size(aspectRatio: $0.aspectRatio).width } }.max() ?? 0
        HStack(alignment: .center, spacing: FlowerMetrics.columnSpacing) {
            if FlowerLayout.forProviderCount(providers.count) == .flowerAndLegend {
                FlowerChart(petals: providers.map(Petal.init), summary: providers.spokenSummary)
            }
            VStack(alignment: .leading, spacing: FlowerMetrics.rowSpacing) {
                ForEach(Array(providers.enumerated()), id: \.offset) { index, usage in
                    LegendRow(usage: usage, color: QuotaPalette.color(at: index), logo: marks[index], logoColumnWidth: logoColumnWidth)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("quotablet.provider-flower")
    }
}

private struct FlowerChart: View {
    let petals: [Petal]
    let summary: String

    var body: some View {
        let radius = FlowerMetrics.chartDiameter / 2
        let labelSize: CGFloat = petals.count <= 6 ? 12 : 10
        ZStack {
            ForEach(Array(petals.enumerated()), id: \.offset) { index, petal in
                PetalView(
                    geometry: PetalGeometry(petalCount: petals.count, index: index, outerRadius: radius),
                    petal: petal,
                    color: QuotaPalette.color(at: index),
                    labelSize: labelSize
                )
            }
        }
        .frame(width: FlowerMetrics.chartDiameter, height: FlowerMetrics.chartDiameter)
        .animation(.easeOut(duration: 0.35), value: petals.map(\.usedFraction))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }
}

private struct PetalView: View {
    let geometry: PetalGeometry
    let petal: Petal
    let color: Color
    let labelSize: CGFloat

    var body: some View {
        ZStack {
            marks
            label
        }
    }

    // Staleness is the report's age, not its amount, so an unknown petal dims too.
    private var dim: Double {
        petal.isStale ? PetalLook.staleOpacity : 1
    }

    @ViewBuilder
    private var marks: some View {
        let shape = PetalShape(geometry: geometry)
        if let fraction = petal.usedFraction {
            shape.fill(color.opacity(PetalLook.trackOpacity))
            if fraction > 0 {
                filled(shape, fraction: fraction)
            }
        } else {
            shape.stroke(color, lineWidth: PetalLook.outlineWidth).opacity(dim)
        }
    }

    // A disk exactly as wide as the petal would leave a thin seam where both antialiased edges meet.
    @ViewBuilder
    private func filled(_ shape: PetalShape, fraction: Double) -> some View {
        let reach = fraction >= 1
            ? geometry.outerRadius + PetalLook.fullFillOverhang
            : geometry.fillRadius(forUsedFraction: fraction)
        if petal.isStale {
            shape.fill(color)
                .saturation(PetalLook.staleSaturation)
                .opacity(PetalLook.staleOpacity)
                .mask { StripeBands() }
                .clipShape(FillDisk(radius: reach))
        } else {
            shape.fill(color)
                .clipShape(FillDisk(radius: reach))
        }
    }

    private var label: some View {
        let middle = CGPoint(x: geometry.outerRadius, y: geometry.outerRadius)
        let ink = labelInk
        return Text(petal.letter)
            .font(.system(size: labelSize, weight: .heavy, design: .rounded))
            .foregroundStyle(ink.color)
            .shadow(color: ink.shadow, radius: PetalLook.labelShadowRadius, y: PetalLook.labelShadowOffset)
            .position(geometry.labelCenter(in: middle))
    }

    // A measured petal draws a white letter. It sits over the fill only above roughly 75% used, and over the pale track
    // below that, so a faint shadow keeps it readable on both. An outline leaves the letter on the panel, so it takes the
    // outline's color and needs no shadow.
    private var labelInk: (color: Color, shadow: Color) {
        petal.usedFraction == nil
            ? (color.opacity(dim), .clear)
            : (.white, .black.opacity(PetalLook.labelShadowOpacity))
    }
}

private struct PetalShape: Shape {
    let geometry: PetalGeometry

    func path(in rect: CGRect) -> Path {
        Path(geometry.path(in: CGPoint(x: rect.midX, y: rect.midY)))
    }
}

// Clips a petal to the disk that holds its used share. Animating the radius grows the fill without
// solving for the radius again on every frame.
private struct FillDisk: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: CGRect(x: rect.midX - radius, y: rect.midY - radius, width: 2 * radius, height: 2 * radius))
    }
}

private struct StripeBands: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var top = rect.minY
        while top < rect.maxY {
            path.addRect(CGRect(x: rect.minX, y: top, width: rect.width, height: PetalLook.stripeThickness))
            top += 2 * PetalLook.stripeThickness
        }
        return path
    }
}

private struct LegendRow: View {
    let usage: ProviderUsage
    let color: Color
    let logo: ProviderLogo?
    let logoColumnWidth: CGFloat

    var body: some View {
        HStack(spacing: FlowerMetrics.markSpacing) {
            Circle()
                .fill(color)
                .frame(width: FlowerMetrics.dotDiameter, height: FlowerMetrics.dotDiameter)
            if logoColumnWidth > 0 {
                logoColumn
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(ProviderRegistry.displayName(for: usage.provider))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(usage.accountsPhrase)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(usage.usedText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                if usage.isStale {
                    StaleMark()
                }
            }
            .layoutPriority(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(usage.legendAccessibilityLabel)
    }

    private var logoColumn: some View {
        ZStack {
            if let logo {
                Image(nsImage: logo.artwork(height: LegendLogo.size(aspectRatio: logo.aspectRatio).height))
                    .renderingMode(.original)
            }
        }
        .frame(width: logoColumnWidth, height: LegendLogo.height)
    }
}
