import AppKit
import CoreGraphics
import SwiftUI

enum FlowerLayout: Equatable {
    // Rows in place of a flower, when the count is outside the petal range.
    case list
    case flower

    static let petalRange = 3...8

    // The one rule for every flower in the panel: the front page's providers and a provider page's accounts.
    static func forItemCount(_ count: Int) -> FlowerLayout {
        petalRange.contains(count) ? .flower : .list
    }
}

// What one petal draws. The petals follow their items' order, so a petal's position is its item's rank.
struct Petal: Equatable, Sendable {
    // Nil when nothing is measured. The petal then has an outline and no fill.
    let usedFraction: Double?
    let isStale: Bool
    // Inside the petal: a provider's used percent, or an account's number.
    let text: String
    let badge: AttentionBadge?

    init(_ usage: ProviderUsage) {
        usedFraction = usage.usedFraction
        isStale = usage.isStale
        text = UsageFormatting.usedPercent(usage.usedFraction)
        badge = usage.attention.badge
    }

    init(_ account: AccountDetail) {
        usedFraction = account.capacityFraction
        isStale = account.isStale
        text = String(account.number)
        badge = account.urgency.map { AttentionBadge(urgency: $0, count: 1) }
    }
}

extension ProviderUsage {
    var usedText: String {
        usedFraction == nil ? "Unknown" : "\(UsageFormatting.usedPercent(usedFraction)) used"
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

    var axisAngle: CGFloat {
        -.pi / 2 + 2 * .pi * CGFloat(index) / CGFloat(petalCount)
    }

    private var halfSpan: CGFloat {
        (2 * .pi / CGFloat(petalCount) - gapDegrees * .pi / 180) / 2
    }

    func path(in center: CGPoint) -> CGPath {
        let inner = innerRounding
        let outer = outerRounding
        let first = axisAngle - halfSpan
        let last = axisAngle + halfSpan
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

    func axisPoint(atRadius radius: CGFloat, in center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + radius * cos(axisAngle), y: center.y + radius * sin(axisAngle))
    }

    // Just inside the outer arc and a little clockwise of the axis, so a badge there leaves the tip clear for a logo.
    func badgeCenter(in center: CGPoint) -> CGPoint {
        let angle = axisAngle + min(max(halfSpan * 0.5, 0.2), 0.38)
        let radius = outerRadius - 10
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    // Where a box of `size` centers to sit `gap` beyond the petal's tip, so the gap is even whatever the petal's angle.
    func boxCenter(size: CGSize, beyondTipBy gap: CGFloat, in center: CGPoint) -> CGPoint {
        let half = abs(cos(axisAngle)) * size.width / 2 + abs(sin(axisAngle)) * size.height / 2
        return axisPoint(atRadius: outerRadius + gap + half, in: center)
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

// All the petals of one flower, built once so a view outlines each petal a single time.
struct FlowerGeometry {
    let diameter: CGFloat
    let petals: [PetalGeometry]

    init(petalCount: Int, diameter: CGFloat) {
        self.diameter = diameter
        petals = (0..<petalCount).map { PetalGeometry(petalCount: petalCount, index: $0, outerRadius: diameter / 2) }
    }

    var center: CGPoint { CGPoint(x: diameter / 2, y: diameter / 2) }

    // The petal that holds `point`, or nil over a gap, over the hole in the middle, or outside the flower.
    // Hover and click both ask this, because the petals' frames overlap and only their outlines tell them apart.
    func index(containing point: CGPoint) -> Int? {
        petals.firstIndex { $0.path(in: center).contains(point) }
    }
}

enum QuotaPalette {
    // Petals next to each other contrast, so the order is part of the design. No color here is a red, orange, yellow, or green.
    // Those belong to the status badges, so a petal never reads as a status.
    private static let colors: [Color] = [.blue, .brown, .indigo, .teal, .gray, .cyan, slate, .purple]

    // The system colors have no muted blue, and the palette needs a cool color that stays quiet beside cyan.
    private static let slate = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.45, green: 0.55, blue: 0.75, alpha: 1)
            : NSColor(srgbRed: 0.34, green: 0.43, blue: 0.62, alpha: 1)
    })

    static func color(at index: Int) -> Color {
        colors[(index % colors.count + colors.count) % colors.count]
    }
}

extension LogoAppearance {
    init(_ scheme: ColorScheme) {
        self = scheme == .dark ? .dark : .light
    }
}

// The size of a logo's artwork at a given height. One wider than `maxWidth` shrinks with its shape unchanged, so a wide wordmark cannot crowd its neighbors.
enum LogoFit {
    static func size(aspectRatio: CGFloat, height: CGFloat, maxWidth: CGFloat) -> CGSize {
        let width = min(height * aspectRatio, maxWidth)
        return CGSize(width: width, height: width / aspectRatio)
    }
}

// Names the pairs of views that grow or travel between the front page and a provider's page.
enum PanelHero {
    // The provider's logo, from beside its petal to the page's header.
    static func logo(_ provider: String) -> String { "logo.\(provider)" }
    // The provider's petal or row, which the page's tint grows out of.
    static func tint(_ provider: String) -> String { "tint.\(provider)" }
}

extension View {
    // Pairs this view with the view of the same `id` on the other page, so one grows or travels into the other.
    // A nil namespace pairs nothing, which is how Reduce Motion falls back to a cross-fade.
    @ViewBuilder
    func paired(_ id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: id, in: namespace)
        } else {
            self
        }
    }
}

extension QuotaUrgency {
    // Two shapes, so a badge or a glyph never rests on its color alone.
    var symbol: String {
        switch self {
        case .exhausted: "xmark.octagon.fill"
        case .nearLimit: "exclamationmark.triangle.fill"
        }
    }
}

enum PetalLook {
    static let trackOpacity = 0.22
    static let staleOpacity = 0.55
    static let staleSaturation = 0.4
    static let outlineWidth: CGFloat = 1.5
    static let stripeThickness: CGFloat = 1.5
    static let fullFillOverhang: CGFloat = 2
    static let liftScale: CGFloat = 1.035
    static let liftBrightness = 0.12
    // Over a petal's color the ink is near black, which stays legible on every palette color in both appearances.
    static let inkOnColor = Color.black.opacity(0.88)
}

private enum FlowerMetrics {
    static let maxDiameter: CGFloat = 300
    static let logoHeight: CGFloat = 18
    static let logoMaxWidth: CGFloat = 36
    static let logoGap: CGFloat = 7
    // The petal that opens grows past the panel while it fades, and the others shrink away.
    static let openedScale: CGFloat = 2.6
    static let othersScale: CGFloat = 0.9
}

// How large a petal's text is and how far from the center it sits. Fewer petals are wider, so they take larger text set nearer the middle.
struct PetalLabelStyle: Equatable, Sendable {
    let size: CGFloat
    // Of the flower's outer radius.
    let radiusFraction: CGFloat

    // A provider's used percent such as "100%". The sizes suit a flower 300 pt across and scale with the diameter.
    static func percent(petalCount: Int, diameter: CGFloat) -> PetalLabelStyle {
        let size: CGFloat = petalCount <= 4 ? 34 : (petalCount <= 6 ? 28 : 22)
        let fraction: CGFloat = petalCount <= 4 ? 0.64 : (petalCount <= 6 ? 0.70 : 0.76)
        return PetalLabelStyle(size: size * diameter / FlowerMetrics.maxDiameter, radiusFraction: fraction)
    }

    // An account's number, one digit or two.
    static func number(petalCount: Int) -> PetalLabelStyle {
        PetalLabelStyle(size: petalCount <= 5 ? 26 : 21, radiusFraction: petalCount <= 4 ? 0.58 : 0.64)
    }
}

// The provider's logo, drawn as its file provides it and never tinted, or the provider's letter when no file exists.
struct ProviderMark: View {
    let provider: String
    let logos: ProviderLogoCatalog
    let height: CGFloat
    var maxWidth: CGFloat = 36
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let logo = logos.logo(for: provider, appearance: LogoAppearance(colorScheme)) {
                let size = LogoFit.size(aspectRatio: logo.aspectRatio, height: height, maxWidth: maxWidth)
                Image(nsImage: logo.artwork(height: size.height))
                    .renderingMode(.original)
                    .resizable()
                    .frame(width: size.width, height: size.height)
            } else {
                Text(ProviderRegistry.badgeLetter(for: provider))
                    .font(.system(size: height * 0.8, weight: .heavy, design: .rounded))
                    .frame(width: height, height: height)
            }
        }
        .accessibilityHidden(true)
    }

    // What the mark measures, for a caller that positions it before it draws.
    static func size(provider: String, logos: ProviderLogoCatalog, appearance: LogoAppearance, height: CGFloat, maxWidth: CGFloat) -> CGSize {
        guard let logo = logos.logo(for: provider, appearance: appearance) else { return CGSize(width: height, height: height) }
        return LogoFit.size(aspectRatio: logo.aspectRatio, height: height, maxWidth: maxWidth)
    }
}

struct StatusBadge: View {
    let badge: AttentionBadge
    let showsCount: Bool

    var body: some View {
        let isExhausted = badge.urgency == .exhausted
        HStack(spacing: 3) {
            Image(systemName: badge.urgency.symbol)
                .font(.system(size: 10, weight: .bold))
            if showsCount {
                Text("\(badge.count)")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(isExhausted ? Color.white : PetalLook.inkOnColor)
        .padding(.horizontal, showsCount ? 7 : 0)
        .frame(minWidth: 20, minHeight: 20)
        .background(Capsule().fill(isExhausted ? Color(red: 0.80, green: 0.13, blue: 0.12) : Color(nsColor: .systemOrange)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.25))
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
    }
}

// One petal: a pale track, the area-correct fill, stale stripes, and its text. The text turns dark exactly at the fill's edge,
// so a figure the edge cuts through stays legible on both sides.
struct PetalView: View {
    let geometry: PetalGeometry
    let petal: Petal
    let color: Color
    let label: PetalLabelStyle
    let badgeShowsCount: Bool
    var isLifted = false

    var body: some View {
        let middle = CGPoint(x: geometry.outerRadius, y: geometry.outerRadius)
        let reach = fillReach
        ZStack {
            marks(reach: reach)
                .brightness(isLifted ? PetalLook.liftBrightness : 0)
            text(reach: reach, middle: middle)
            if let badge = petal.badge {
                StatusBadge(badge: badge, showsCount: badgeShowsCount)
                    .position(geometry.badgeCenter(in: middle))
            }
        }
        .scaleEffect(isLifted ? PetalLook.liftScale : 1)
        .animation(.easeOut(duration: 0.12), value: isLifted)
        .animation(.easeOut(duration: 0.35), value: petal.usedFraction)
    }

    // Staleness is the report's age, not its amount, so an unknown petal dims too.
    private var dim: Double {
        petal.isStale ? PetalLook.staleOpacity : 1
    }

    // The radius of the disk that holds the used share. Nil when nothing is used or nothing is measured.
    // A disk exactly as wide as the petal would leave a thin seam where both antialiased edges meet, so a full petal overhangs.
    private var fillReach: CGFloat? {
        guard let fraction = petal.usedFraction, fraction > 0 else { return nil }
        return fraction >= 1 ? geometry.outerRadius + PetalLook.fullFillOverhang : geometry.fillRadius(forUsedFraction: fraction)
    }

    @ViewBuilder
    private func marks(reach: CGFloat?) -> some View {
        let shape = PetalShape(geometry: geometry)
        if petal.usedFraction == nil {
            shape.stroke(color, lineWidth: PetalLook.outlineWidth).opacity(dim)
        } else {
            shape.fill(color.opacity(PetalLook.trackOpacity))
            if let reach {
                filled(shape, reach: reach)
            }
        }
    }

    @ViewBuilder
    private func filled(_ shape: PetalShape, reach: CGFloat) -> some View {
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

    // Over the fill the text is dark, and over the empty track it is the primary color. A stale fill is dim and striped,
    // so its figure keeps the primary color throughout. An outline leaves the text on the panel, so it takes the outline's color.
    private func text(reach: CGFloat?, middle: CGPoint) -> some View {
        let point = geometry.axisPoint(atRadius: geometry.outerRadius * label.radiusFraction, in: middle)
        let digits = Text(petal.text)
            .font(.system(size: label.size, weight: .heavy, design: .rounded))
            .monospacedDigit()
        return ZStack {
            digits
                .foregroundStyle(petal.usedFraction == nil ? color.opacity(dim) : Color.primary)
                .position(point)
            if let reach, !petal.isStale {
                digits
                    .foregroundStyle(PetalLook.inkOnColor)
                    .position(point)
                    .mask { FillDisk(radius: reach) }
            }
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

// The stale stripes. Horizontal bands run left to right and stack downward, as on a petal. Vertical bands stand side by side, as on a thin bar.
struct StripeBands: Shape {
    var direction: Axis = .horizontal

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step = 2 * PetalLook.stripeThickness
        switch direction {
        case .horizontal:
            var top = rect.minY
            while top < rect.maxY {
                path.addRect(CGRect(x: rect.minX, y: top, width: rect.width, height: PetalLook.stripeThickness))
                top += step
            }
        case .vertical:
            var left = rect.minX
            while left < rect.maxX {
                path.addRect(CGRect(x: left, y: rect.minY, width: PetalLook.stripeThickness, height: rect.height))
                left += step
            }
        }
        return path
    }
}

// A thin bar filled to a used share. Stripes mark the fill of a stale account, as they mark its petal.
struct ThinBar: View {
    let used: Double?
    let color: Color
    var height: CGFloat = 4
    var isStale = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14))
                if let used, used > 0 {
                    let width = max(height, proxy.size.width * min(max(used, 0), 1))
                    if isStale {
                        Capsule().fill(color)
                            .opacity(0.78)
                            .mask { StripeBands(direction: .vertical) }
                            .frame(width: width)
                    } else {
                        Capsule().fill(color)
                            .frame(width: width)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct ProviderFlower: View {
    let providers: [ProviderUsage]
    let logos: ProviderLogoCatalog
    let route: PanelRoute
    // Pairs the logos and the tint with the provider page's. Nil under Reduce Motion, which cross-fades instead.
    let namespace: Namespace.ID?
    let open: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: Int?

    private var openProvider: String? {
        if case .provider(let id) = route { id } else { nil }
    }

    var body: some View {
        GeometryReader { proxy in
            let flower = FlowerGeometry(petalCount: providers.count, diameter: Self.diameter(in: proxy.size))
            ZStack {
                ZStack {
                    petals(in: flower)
                    tips(in: flower)
                    tints(in: flower)
                }
                .accessibilityHidden(true)
                touch(in: flower)
                accessibility(in: flower)
            }
            .frame(width: flower.diameter, height: flower.diameter)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quotablet.provider-flower")
        .accessibilityHidden(openProvider != nil)
        .onChange(of: openProvider) { _, _ in setHovered(nil) }
        .onDisappear { setHovered(nil) }
    }

    // The only place `hovered` changes, so every push of the pointing hand has its pop.
    private func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        if hovered == nil {
            NSCursor.pointingHand.push()
        } else if index == nil {
            NSCursor.pop()
        }
        hovered = index
    }

    // The flower is 300 pt across, or smaller when notices leave less room. The logos sit beyond its tips, so they count against the room.
    private static func diameter(in size: CGSize) -> CGFloat {
        let reach = FlowerMetrics.logoGap + FlowerMetrics.logoMaxWidth
        return max(0, min(FlowerMetrics.maxDiameter, size.width - 2 * reach, size.height - 2 * reach))
    }

    private func petals(in flower: FlowerGeometry) -> some View {
        ForEach(providers.indices, id: \.self) { index in
            PetalView(
                geometry: flower.petals[index],
                petal: Petal(providers[index]),
                color: QuotaPalette.color(at: index),
                label: .percent(petalCount: providers.count, diameter: flower.diameter),
                badgeShowsCount: true,
                isLifted: hovered == index && openProvider == nil
            )
            .scaleEffect(scale(of: providers[index].provider), anchor: .center)
            .opacity(openProvider == nil ? 1 : 0)
        }
    }

    private func scale(of provider: String) -> CGFloat {
        guard let openProvider, !reduceMotion else { return 1 }
        return provider == openProvider ? FlowerMetrics.openedScale : FlowerMetrics.othersScale
    }

    // Each logo sits beyond its petal's tip. It fades with the flower, and a stand-in at the same place pairs with the page's logo.
    private func tips(in flower: FlowerGeometry) -> some View {
        ForEach(providers.indices, id: \.self) { index in
            let provider = providers[index].provider
            let size = ProviderMark.size(
                provider: provider, logos: logos, appearance: LogoAppearance(colorScheme),
                height: FlowerMetrics.logoHeight, maxWidth: FlowerMetrics.logoMaxWidth
            )
            ProviderMark(provider: provider, logos: logos, height: FlowerMetrics.logoHeight, maxWidth: FlowerMetrics.logoMaxWidth)
                .overlay {
                    if openProvider == nil {
                        Color.clear.paired(PanelHero.logo(provider), in: namespace)
                    }
                }
                .position(flower.petals[index].boxCenter(size: size, beyondTipBy: FlowerMetrics.logoGap, in: flower.center))
                .opacity(openProvider == nil ? 1 : 0)
        }
    }

    // The page's tint grows out of the petal that opens. Its stand-in is the petal's bounding box and exists only while the flower shows.
    @ViewBuilder
    private func tints(in flower: FlowerGeometry) -> some View {
        if openProvider == nil {
            ForEach(providers.indices, id: \.self) { index in
                let box = flower.petals[index].path(in: flower.center).boundingBoxOfPath
                Color.clear
                    .frame(width: box.width, height: box.height)
                    .paired(PanelHero.tint(providers[index].provider), in: namespace)
                    .position(x: box.midX, y: box.midY)
            }
        }
    }

    // One hover and one click for the whole flower, both resolved against the petals' outlines.
    private func touch(in flower: FlowerGeometry) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): setHovered(flower.index(containing: point))
                case .ended: setHovered(nil)
                }
            }
            .gesture(
                SpatialTapGesture().onEnded { tap in
                    if let index = flower.index(containing: tap.location) { open(providers[index].provider) }
                }
            )
            .allowsHitTesting(openProvider == nil)
    }

    // Each petal is a button of its own, sized to the petal and not to the flower, so a screen reader outlines the right shape.
    private func accessibility(in flower: FlowerGeometry) -> some View {
        ForEach(providers.indices, id: \.self) { index in
            let usage = providers[index]
            let box = flower.petals[index].path(in: flower.center).boundingBoxOfPath
            Color.clear
                .frame(width: box.width, height: box.height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(usage.petalAccessibilityLabel)
                .accessibilityHint("Shows accounts")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { open(usage.provider) }
                .accessibilityIdentifier("quotablet.petal.\(usage.provider)")
                .position(x: box.midX, y: box.midY)
                .allowsHitTesting(false)
        }
    }
}

struct ProviderList: View {
    let providers: [ProviderUsage]
    let logos: ProviderLogoCatalog
    let route: PanelRoute
    let namespace: Namespace.ID?
    let open: (String) -> Void

    private var isOpen: Bool { route != .flower }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(providers.indices, id: \.self) { index in
                    ProviderRow(
                        usage: providers[index],
                        color: QuotaPalette.color(at: index),
                        logos: logos,
                        isOpen: isOpen,
                        namespace: namespace,
                        open: { open(providers[index].provider) }
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .opacity(isOpen ? 0 : 1)
        .allowsHitTesting(!isOpen)
        .accessibilityHidden(isOpen)
        .accessibilityIdentifier("quotablet.provider-list")
    }
}

private struct ProviderRow: View {
    let usage: ProviderUsage
    let color: Color
    let logos: ProviderLogoCatalog
    let isOpen: Bool
    let namespace: Namespace.ID?
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 9) {
                HStack(spacing: 10) {
                    ProviderMark(provider: usage.provider, logos: logos, height: 18)
                        .overlay {
                            if !isOpen {
                                Color.clear.paired(PanelHero.logo(usage.provider), in: namespace)
                            }
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ProviderRegistry.displayName(for: usage.provider))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(usage.accountsPhrase)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let badge = usage.attention.badge {
                        StatusBadge(badge: badge, showsCount: true)
                    }
                    Text(usage.usedText)
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                ThinBar(used: usage.usedFraction, color: color, height: 5, isStale: usage.isStale)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(isHovered ? 0.2 : 0.1)))
            .overlay {
                if !isOpen {
                    Color.clear.paired(PanelHero.tint(usage.provider), in: namespace)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(usage.petalAccessibilityLabel)
        .accessibilityHint("Shows accounts")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("quotablet.provider-row.\(usage.provider)")
    }
}
