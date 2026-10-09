import CoreGraphics
import SwiftUI

enum SummaryLayout: Equatable {
    case list
    case flower

    static let petalRange = 3...8

    static func forSlotCount(_ count: Int) -> SummaryLayout {
        petalRange.contains(count) ? .flower : .list
    }

    // The flower card is 200 pt tall at any count: 10 padding, 14 header, 3 gap, 150 chart, 2 gap, 11 caption, 10 padding.
    var cardSpacing: CGFloat {
        switch self {
        case .list: 7
        case .flower: 3
        }
    }

    var cardVerticalPadding: CGFloat {
        switch self {
        case .list: 12
        case .flower: 10
        }
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
        precondition(SummaryLayout.petalRange.contains(petalCount), "A flower has \(SummaryLayout.petalRange) petals.")
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
    // Petals next to each other in pin order contrast, so the order is part of the design.
    private static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .yellow]

    static func color(at index: Int) -> Color {
        colors[(index % colors.count + colors.count) % colors.count]
    }
}

private extension MenuBarBadge {
    var tag: String {
        letter + (accountNumber.map(String.init) ?? "")
    }
}

private enum FlowerMetrics {
    static let chartDiameter: CGFloat = 150
    static let columnSpacing: CGFloat = 14
    static let rowHeight: CGFloat = 14
    static let rowSpacing: CGFloat = 5
    static let captionSpacing: CGFloat = 2
    // Keeps a few letters of the quota label beside a long value such as "Remaining unknown", which shrinks instead.
    static let labelFloor: CGFloat = 36
}

private enum PetalLook {
    static let trackOpacity = 0.22
    static let staleOpacity = 0.55
    static let staleSaturation = 0.4
    static let outlineWidth: CGFloat = 1.5
    static let missingDash: [CGFloat] = [4, 3]
    static let stripeThickness: CGFloat = 1.5
    static let fullFillOverhang: CGFloat = 2
    static let labelShadowOpacity = 0.4
    static let labelShadowRadius: CGFloat = 1
    static let labelShadowOffset: CGFloat = 0.5
}

struct QuotaFlowerSummary: View {
    let slots: [MenuBarSlot]
    let badges: [MenuBarBadge]
    let freshness: UsageFreshness
    let now: Date
    let onRemove: (QuotaPinKey) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FlowerMetrics.captionSpacing) {
            HStack(alignment: .center, spacing: FlowerMetrics.columnSpacing) {
                FlowerChart(badges: badges)
                legend
            }
            caption
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: FlowerMetrics.rowSpacing) {
            ForEach(Array(zip(slots, badges).enumerated()), id: \.offset) { index, pair in
                FlowerLegendRow(index: index, slot: pair.0, badge: pair.1, onRemove: onRemove)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var caption: some View {
        let needsAttention = freshness.isStale(at: now) || freshness.refreshStatus == .failed
        return Text(freshness.displayLabel(now: now))
            .font(.system(size: 9, weight: needsAttention ? .semibold : .regular))
            .foregroundStyle(needsAttention ? Color.orange : Color.secondary)
            .lineLimit(1)
    }
}

private struct FlowerChart: View {
    let badges: [MenuBarBadge]

    var body: some View {
        let radius = FlowerMetrics.chartDiameter / 2
        let labelSize: CGFloat = badges.count <= 6 ? 12 : 10
        ZStack {
            ForEach(Array(badges.enumerated()), id: \.offset) { index, badge in
                PetalView(
                    geometry: PetalGeometry(petalCount: badges.count, index: index, outerRadius: radius),
                    badge: badge,
                    color: QuotaPalette.color(at: index),
                    labelSize: labelSize
                )
            }
        }
        .frame(width: FlowerMetrics.chartDiameter, height: FlowerMetrics.chartDiameter)
        .animation(.easeOut(duration: 0.35), value: usedFractions)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage chart, \(badges.count) pinned quotas")
    }

    private var usedFractions: [Double?] {
        badges.map { badge -> Double? in
            if case .used(let fraction) = badge.gauge { return fraction }
            return nil
        }
    }
}

private struct PetalView: View {
    let geometry: PetalGeometry
    let badge: MenuBarBadge
    let color: Color
    let labelSize: CGFloat

    var body: some View {
        ZStack {
            marks
            label
        }
    }

    // Staleness is the report's age, not its amount, so an unknown petal dims too. A missing pin has no report.
    private var dim: Double {
        badge.isStale ? PetalLook.staleOpacity : 1
    }

    @ViewBuilder
    private var marks: some View {
        let petal = PetalShape(geometry: geometry)
        switch badge.gauge {
        case .used(let fraction):
            petal.fill(color.opacity(PetalLook.trackOpacity))
            if fraction > 0 {
                filled(petal, fraction: fraction)
            }
        case .unknown:
            petal.stroke(color, lineWidth: PetalLook.outlineWidth).opacity(dim)
        case .missing:
            petal.stroke(Color.secondary, style: StrokeStyle(lineWidth: PetalLook.outlineWidth, dash: PetalLook.missingDash))
        }
    }

    // A disk exactly as wide as the petal would leave a thin seam where both antialiased edges meet.
    @ViewBuilder
    private func filled(_ petal: PetalShape, fraction: Double) -> some View {
        let reach = fraction >= 1
            ? geometry.outerRadius + PetalLook.fullFillOverhang
            : geometry.fillRadius(forUsedFraction: fraction)
        if badge.isStale {
            petal.fill(color)
                .saturation(PetalLook.staleSaturation)
                .opacity(PetalLook.staleOpacity)
                .mask(StripeBands())
                .clipShape(FillDisk(radius: reach))
        } else {
            petal.fill(color)
                .clipShape(FillDisk(radius: reach))
        }
    }

    private var label: some View {
        let middle = CGPoint(x: geometry.outerRadius, y: geometry.outerRadius)
        let ink = labelInk
        return Text(badge.tag)
            .font(.system(size: labelSize, weight: .heavy, design: .rounded))
            .foregroundStyle(ink.color)
            .shadow(color: ink.shadow, radius: PetalLook.labelShadowRadius, y: PetalLook.labelShadowOffset)
            .position(geometry.labelCenter(in: middle))
    }

    // A gauge draws white letters. They sit over the fill only above roughly 75% used, and over the pale track
    // below that, so a faint shadow keeps them readable on both. An outline leaves the letter on the panel, so it
    // takes the outline's color and needs no shadow.
    private var labelInk: (color: Color, shadow: Color) {
        switch badge.gauge {
        case .used: (.white, .black.opacity(PetalLook.labelShadowOpacity))
        case .unknown: (color.opacity(dim), .clear)
        case .missing: (.secondary, .clear)
        }
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

private struct FlowerLegendRow: View {
    let index: Int
    let slot: MenuBarSlot
    let badge: MenuBarBadge
    let onRemove: (QuotaPinKey) -> Void

    var body: some View {
        switch slot {
        case .pinned(let selection), .attention(let selection), .defaulted(let selection):
            details(of: selection)
        case .missing(let key):
            unavailable(key)
        }
    }

    private var marker: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(QuotaPalette.color(at: index))
                .frame(width: 8, height: 8)
            Text(badge.tag)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(minWidth: 18, alignment: .leading)
        }
    }

    private func details(of selection: SelectedQuota) -> some View {
        let description = UsageStore.accessibilityDescription(of: slot)
        return HStack(spacing: 6) {
            marker
            Text(selection.quota.label)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(minWidth: FlowerMetrics.labelFloor, alignment: .leading)
            if badge.isStale {
                Text("Stale")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            Text(UsageFormatting.remainingText(selection.quota.amount))
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .layoutPriority(1)
        }
        .frame(height: FlowerMetrics.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.isStale ? "\(description), stale" : description)
    }

    private func unavailable(_ key: QuotaPinKey) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                marker
                Text("Unavailable")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(UsageStore.accessibilityDescription(of: slot))
            Button("Remove") {
                onRemove(key)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .accessibilityLabel("Remove unavailable pinned quota")
        }
        .frame(height: FlowerMetrics.rowHeight)
        .accessibilityElement(children: .contain)
    }
}
