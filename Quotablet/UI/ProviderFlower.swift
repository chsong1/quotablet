import AppKit
import CoreGraphics
import SwiftUI

enum FlowerLayout: Equatable {
    // Rows in place of a flower, when the count is outside the petal range.
    case list
    case flower

    static let petalRange = 3...8

    // The rule for a provider page's flower of accounts. The front page lays its providers out with `EmblemGrid`.
    static func forItemCount(_ count: Int) -> FlowerLayout {
        petalRange.contains(count) ? .flower : .list
    }
}

// What one petal draws. The petals follow their accounts' order, so a petal's position is its account's number.
struct Petal: Equatable, Sendable {
    // Nil when nothing is measured. The petal then has a dashed outline and no fill.
    let usedFraction: Double?
    let isStale: Bool
    // The account's number, which a petal on the provider's page carries.
    let text: String
    let urgency: QuotaUrgency?

    init(_ account: AccountDetail) {
        usedFraction = account.capacityFraction
        isStale = account.isStale
        text = String(account.number)
        urgency = account.urgency
    }

    private init(usedFraction: Double?, isStale: Bool, text: String, urgency: QuotaUrgency?) {
        self.usedFraction = usedFraction
        self.isStale = isStale
        self.text = text
        self.urgency = urgency
    }

    // The petals of a provider's emblem: one for each account. A provider that OMP names only through problem accounts has no report,
    // so its emblem is one unmeasured ring.
    static func emblem(of detail: ProviderDetail) -> [Petal] {
        guard !detail.accounts.isEmpty else { return [Petal(usedFraction: nil, isStale: false, text: "", urgency: nil)] }
        return detail.accounts.map(Petal.init)
    }
}

extension ProviderUsage {
    // The pill's text: the used share, a dash for a provider with no report, or "Unknown" for one whose reports hold no figure.
    var usedText: String {
        if usedFraction != nil { return "\(UsageFormatting.usedPercent(usedFraction)) used" }
        return accountCount == 0 ? "—" : "Unknown"
    }
}

// One petal of a flower in a y-down plane such as a SwiftUI canvas. Index 0 is centered at 12 o'clock and the indexes run clockwise on screen.
// A petal is pointed at both ends and widest a little past its middle. A flower of one petal is a band around the hole, set near the rim
// so a lone account does not outweigh a flower of several.
struct PetalGeometry: Equatable, Sendable {
    private static let innerRadiusRatio: CGFloat = 0.28
    private static let ringInnerRadiusRatio: CGFloat = 0.6
    // The widest a petal grows on each side of its axis, as a share of its length. Without the cap two or three petals would swell into disks.
    private static let halfWidthRatio: CGFloat = 0.42
    // Under one, the sides swell outward, so a petal reads as full rather than as a thin leaf.
    private static let bulge: CGFloat = 0.75
    // Over one, the widest point moves out past the middle.
    private static let flare: CGFloat = 1.25
    private static let gapDegrees: CGFloat = 6
    private static let outlineSteps = 72
    private static let integrationSteps = 128
    private static let bisectionSteps = 48

    let petalCount: Int
    let index: Int
    let outerRadius: CGFloat

    init(petalCount: Int, index: Int, outerRadius: CGFloat) {
        precondition(petalCount >= 1, "A flower has at least one petal.")
        precondition((0..<petalCount).contains(index), "A petal index must name one of the flower's petals.")
        self.petalCount = petalCount
        self.index = index
        self.outerRadius = outerRadius
    }

    // Petals start at the edge of the hole that holds the logo. A ring starts farther out, past a gap of the provider's glow.
    var innerRadius: CGFloat { outerRadius * (isRing ? Self.ringInnerRadiusRatio : Self.innerRadiusRatio) }

    // The hole in the middle of a flower, which holds the provider's logo whatever the petal count.
    static func holeRadius(outerRadius: CGFloat) -> CGFloat {
        outerRadius * innerRadiusRatio
    }

    var isRing: Bool { petalCount == 1 }

    var axisAngle: CGFloat {
        -.pi / 2 + 2 * .pi * CGFloat(index) / CGFloat(petalCount)
    }

    // Half the angle a petal may take, which leaves half the gap on each side.
    private var maxHalfSpan: CGFloat {
        .pi / CGFloat(petalCount) - Self.gapDegrees * .pi / 360
    }

    // How far the petal reaches on each side of its axis at `rho` from the center, as an angle. Pi all round for a ring, and zero outside the petal.
    func halfAngle(atRadius rho: CGFloat) -> CGFloat {
        guard rho > innerRadius, rho < outerRadius else { return 0 }
        if isRing { return .pi }
        let length = outerRadius - innerRadius
        let along = (rho - innerRadius) / length
        let halfWidth = Self.halfWidthRatio * length * pow(sin(.pi * pow(along, Self.flare)), Self.bulge)
        return min(asin(min(halfWidth / rho, 1)), maxHalfSpan)
    }

    func path(in center: CGPoint) -> CGPath {
        let path = CGMutablePath()
        if isRing {
            // The two circles run in opposite directions, so the hole stays empty under the nonzero rule.
            path.addArc(center: center, radius: outerRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            path.closeSubpath()
            path.move(to: CGPoint(x: center.x + innerRadius, y: center.y))
            path.addArc(center: center, radius: innerRadius, startAngle: 0, endAngle: -2 * .pi, clockwise: true)
            path.closeSubpath()
            return path
        }
        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        let radii = (0...Self.outlineSteps).map { innerRadius + (outerRadius - innerRadius) * CGFloat($0) / CGFloat(Self.outlineSteps) }
        // Out along the clockwise side to the tip, then back along the other side. Both sides meet the axis at the base and at the tip.
        let out = radii.map { point($0, axisAngle + halfAngle(atRadius: $0)) }
        let back = radii.reversed().dropFirst().dropLast().map { point($0, axisAngle - halfAngle(atRadius: $0)) }
        path.addLines(between: out + back)
        path.closeSubpath()
        return path
    }

    func axisPoint(atRadius radius: CGFloat, in center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + radius * cos(axisAngle), y: center.y + radius * sin(axisAngle))
    }

    // Where a tip badge sits: on the petal's tip, or at the top of a ring.
    func tipCenter(in center: CGPoint) -> CGPoint {
        axisPoint(atRadius: outerRadius, in: center)
    }

    // Integrates the petal's angular width over the rings inside `radius`. The outline has no simple area once a disk cuts through it,
    // so this stays numeric.
    func area(withinRadius radius: CGFloat) -> CGFloat {
        let limit = min(radius, outerRadius)
        guard limit > innerRadius else { return 0 }
        let ringWidth = (limit - innerRadius) / CGFloat(Self.integrationSteps)
        var area: CGFloat = 0
        for ring in 0..<Self.integrationSteps {
            let rho = innerRadius + (CGFloat(ring) + 0.5) * ringWidth
            area += 2 * halfAngle(atRadius: rho) * rho * ringWidth
        }
        return area
    }

    // Petals change width along their length, so a radius that is linear in the fraction would misstate the share. This is the radius
    // whose disk covers that fraction of the petal's area.
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
}

enum QuotaPalette {
    // Emblems next to each other contrast, so the order is part of the design. No color here is a red, orange, yellow, or green.
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
    // The provider's logo, from the middle of its emblem to the page's header.
    static func logo(_ provider: String) -> String { "logo.\(provider)" }
    // The provider's emblem or row, which the page's tint grows out of.
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

    // A tip badge is too small for the outlined symbols, so it takes a bare glyph.
    var tipSymbol: String {
        switch self {
        case .exhausted: "xmark"
        case .nearLimit: "exclamationmark"
        }
    }

    var badgeFill: Color {
        switch self {
        case .exhausted: Color(red: 0.80, green: 0.13, blue: 0.12)
        case .nearLimit: Color(nsColor: .systemOrange)
        }
    }

    var badgeInk: Color {
        switch self {
        case .exhausted: .white
        case .nearLimit: PetalLook.inkOnColor
        }
    }
}

enum PetalLook {
    static let trackOpacity = 0.16
    static let trackStrokeOpacity = 0.45
    // The fill fades toward the tip, so a petal reads as lit from the middle of the flower.
    static let tipOpacity = 0.72
    static let staleOpacity = 0.55
    static let staleSaturation = 0.4
    static let outlineWidth: CGFloat = 1.5
    static let stripeThickness: CGFloat = 1.5
    static let fullFillOverhang: CGFloat = 2
    static let liftScale: CGFloat = 1.035
    static let liftBrightness = 0.08
    // Over a petal's color the ink is near black, which stays legible on every palette color in both appearances.
    static let inkOnColor = Color.black.opacity(0.88)
}

private enum EmblemMetrics {
    static let maxDiameter: CGFloat = 180
    static let inset: CGFloat = 18
    static let spacing: CGFloat = 14
    static let captionGap: CGFloat = 4
    static let captionHeight: CGFloat = 22
    // A tip badge is centered on its petal's tip, so half of it stands past the emblem.
    static let tipRoom: CGFloat = 9
    // How far the glow behind the logo reaches, in radii of the hole.
    static let haloReach: CGFloat = 2.6
    // The emblem that opens grows past the panel while it fades, and the others shrink away.
    static let openedScale: CGFloat = 2.6
    static let othersScale: CGFloat = 0.9
    // The petals unfold from this scale when the panel opens, one after another.
    static let bloomStart: CGFloat = 0.35
    static let bloomStagger = 0.045
}

// How many emblems a row of the front page holds. Nil when there are too many providers for emblems to stay legible, so the front page lists them.
enum EmblemGrid {
    static func columns(forProviderCount count: Int) -> Int? {
        switch count {
        case 1: 1
        case 2...4: 2
        case 5...9: 3
        default: nil
        }
    }
}

// How large an account's number is and how far from the center it sits. Fewer petals are wider, so they take larger digits.
struct PetalLabelStyle: Equatable, Sendable {
    let size: CGFloat
    // Of the flower's outer radius. A petal is widest a little past its middle, which is where the digits sit.
    let radiusFraction: CGFloat

    // An account's number, one digit or two.
    static func number(petalCount: Int) -> PetalLabelStyle {
        PetalLabelStyle(size: petalCount <= 5 ? 24 : 19, radiusFraction: 0.68)
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
        HStack(spacing: 3) {
            Image(systemName: badge.urgency.symbol)
                .font(.system(size: 10, weight: .bold))
            if showsCount {
                Text("\(badge.count)")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(badge.urgency.badgeInk)
        .padding(.horizontal, showsCount ? 7 : 0)
        .frame(minWidth: 20, minHeight: 20)
        .background(Capsule().fill(badge.urgency.badgeFill))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.25))
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
    }
}

// Counts the accounts that need the user to sign in again. A neutral dark capsule with a red symbol, so it never reads as a quota status.
struct SignInBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(red: 1.0, green: 0.36, blue: 0.32))
            Text("\(count)")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, 7)
        .frame(minWidth: 20, minHeight: 20)
        .background(Capsule().fill(Color(white: 0.13)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.25))
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
        .accessibilityIdentifier("quotablet.sign-in-badge")
    }
}

// Marks the tip of a petal whose account needs attention: a small disc in the status color with its own glyph, so it never rests on color alone.
struct TipBadge: View {
    let urgency: QuotaUrgency

    var body: some View {
        Image(systemName: urgency.tipSymbol)
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(urgency.badgeInk)
            .frame(width: 16, height: 16)
            .background(Circle().fill(urgency.badgeFill))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.25))
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
            .accessibilityHidden(true)
    }
}

// One petal: a pale track with a fine outline, the area-correct fill shading outward from the center, stale stripes, and a tip badge when
// its account needs attention. With a label, the account's number turns dark exactly at the fill's edge, so a number the edge cuts through
// stays legible on both sides.
struct PetalView: View {
    let geometry: PetalGeometry
    let petal: Petal
    let color: Color
    // Nil on the front page, where the petals are too small for digits.
    var label: PetalLabelStyle?

    var body: some View {
        let middle = CGPoint(x: geometry.outerRadius, y: geometry.outerRadius)
        let reach = fillReach
        ZStack {
            marks(reach: reach)
            if let label {
                text(label, reach: reach, middle: middle)
            }
            if let urgency = petal.urgency {
                TipBadge(urgency: urgency)
                    .position(geometry.tipCenter(in: middle))
            }
        }
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

    // Full color at the base, fading toward the tip. The shape fills the whole flower's frame, so the gradient centers on the flower.
    private var shading: RadialGradient {
        RadialGradient(
            colors: [color, color.opacity(PetalLook.tipOpacity)],
            center: .center,
            startRadius: geometry.innerRadius,
            endRadius: geometry.outerRadius
        )
    }

    @ViewBuilder
    private func marks(reach: CGFloat?) -> some View {
        let shape = PetalShape(geometry: geometry)
        if petal.usedFraction == nil {
            shape.stroke(color, style: StrokeStyle(lineWidth: PetalLook.outlineWidth, dash: [3, 3])).opacity(dim)
        } else {
            shape.fill(color.opacity(PetalLook.trackOpacity))
            shape.stroke(color.opacity(PetalLook.trackStrokeOpacity), lineWidth: 1)
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
            shape.fill(shading)
                .clipShape(FillDisk(radius: reach))
        }
    }

    // Over the fill the text is dark, and over the empty track it is the primary color. A stale fill is dim and striped,
    // so its figure keeps the primary color throughout. An outline leaves the text on the panel, so it takes the outline's color.
    private func text(_ label: PetalLabelStyle, reach: CGFloat?, middle: CGPoint) -> some View {
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

// The front page: one emblem for each provider, in rows of `columns` with the last row centered. Click an emblem to open its provider's page.
struct ProviderEmblems: View {
    let details: [ProviderDetail]
    let columns: Int
    let logos: ProviderLogoCatalog
    let route: PanelRoute
    // Pairs the logos and the tint with the provider page's. Nil under Reduce Motion, which cross-fades instead.
    let namespace: Namespace.ID?
    let open: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?
    // False while the panel is closed, so the petals unfold each time it opens.
    @State private var hasBloomed = false

    private var openProvider: String? {
        if case .provider(let id) = route { id } else { nil }
    }

    private var rows: [Range<Int>] {
        stride(from: 0, to: details.count, by: columns).map { $0..<min($0 + columns, details.count) }
    }

    var body: some View {
        GeometryReader { proxy in
            let diameter = Self.diameter(in: proxy.size, columns: columns, rows: rows.count)
            VStack(spacing: EmblemMetrics.spacing) {
                ForEach(rows, id: \.lowerBound) { row in
                    HStack(spacing: EmblemMetrics.spacing) {
                        ForEach(row, id: \.self) { index in
                            cell(at: index, diameter: diameter)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quotablet.provider-emblems")
        .accessibilityHidden(openProvider != nil)
        .onAppear { hasBloomed = true }
        .onDisappear {
            hasBloomed = false
            setHovered(nil)
        }
        .onChange(of: openProvider) { _, _ in setHovered(nil) }
    }

    // As large as a cell allows, up to `maxDiameter`. A cell also holds the tip badges' overhang and the caption.
    private static func diameter(in size: CGSize, columns: Int, rows: Int) -> CGFloat {
        let across = (size.width - 2 * EmblemMetrics.inset - CGFloat(columns - 1) * EmblemMetrics.spacing) / CGFloat(columns)
        let down = (size.height - 2 * EmblemMetrics.inset - CGFloat(rows - 1) * EmblemMetrics.spacing) / CGFloat(rows)
            - EmblemMetrics.captionGap - EmblemMetrics.captionHeight
        return max(0, min(EmblemMetrics.maxDiameter, across - 2 * EmblemMetrics.tipRoom, down - 2 * EmblemMetrics.tipRoom))
    }

    // The only place `hovered` changes, so every push of the pointing hand has its pop.
    private func setHovered(_ provider: String?) {
        guard provider != hovered else { return }
        if hovered == nil {
            NSCursor.pointingHand.push()
        } else if provider == nil {
            NSCursor.pop()
        }
        hovered = provider
    }

    private func scale(of provider: String) -> CGFloat {
        guard let openProvider, !reduceMotion else { return 1 }
        return provider == openProvider ? EmblemMetrics.openedScale : EmblemMetrics.othersScale
    }

    private func cell(at index: Int, diameter: CGFloat) -> some View {
        let detail = details[index]
        let provider = detail.usage.provider
        let isLifted = hovered == provider && openProvider == nil
        return Button {
            open(provider)
        } label: {
            VStack(spacing: EmblemMetrics.captionGap) {
                ProviderEmblem(
                    provider: provider,
                    petals: Petal.emblem(of: detail),
                    color: QuotaPalette.color(at: index),
                    logos: logos,
                    diameter: diameter,
                    hasBloomed: hasBloomed || reduceMotion,
                    pairsWithPage: openProvider == nil,
                    namespace: namespace
                )
                .brightness(isLifted ? PetalLook.liftBrightness : 0)
                .padding(EmblemMetrics.tipRoom)
                EmblemCaption(detail: detail)
                    .frame(height: EmblemMetrics.captionHeight)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(scale(of: provider) * (isLifted ? PetalLook.liftScale : 1))
        .animation(.easeOut(duration: 0.12), value: isLifted)
        .opacity(openProvider == nil ? 1 : 0)
        .allowsHitTesting(openProvider == nil)
        .onHover { inside in
            if inside {
                setHovered(provider)
            } else if hovered == provider {
                setHovered(nil)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.emblemAccessibilityLabel)
        .accessibilityHint("Shows accounts")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("quotablet.emblem.\(provider)")
    }
}

// One provider: a petal for each account around the provider's logo, over a soft glow of the provider's color.
private struct ProviderEmblem: View {
    let provider: String
    let petals: [Petal]
    let color: Color
    let logos: ProviderLogoCatalog
    let diameter: CGFloat
    let hasBloomed: Bool
    // While the front page shows, stand-ins here pair with the page's logo and tint, so the page grows out of this emblem and shrinks back into it.
    let pairsWithPage: Bool
    let namespace: Namespace.ID?

    var body: some View {
        let flower = FlowerGeometry(petalCount: petals.count, diameter: diameter)
        let hole = PetalGeometry.holeRadius(outerRadius: diameter / 2)
        let glow = hole * EmblemMetrics.haloReach
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [color.opacity(0.32), color.opacity(0)], center: .center, startRadius: 0, endRadius: glow))
                .frame(width: 2 * glow, height: 2 * glow)
            ForEach(petals.indices, id: \.self) { index in
                PetalView(geometry: flower.petals[index], petal: petals[index], color: color)
                    .scaleEffect(hasBloomed ? 1 : EmblemMetrics.bloomStart)
                    .opacity(hasBloomed ? 1 : 0)
                    .animation(.spring(duration: 0.55, bounce: 0.3).delay(Double(index) * EmblemMetrics.bloomStagger), value: hasBloomed)
            }
            Circle()
                .fill(.background)
                .overlay(Circle().strokeBorder(color.opacity(0.6), lineWidth: 1.25))
                .frame(width: 2 * hole - 4, height: 2 * hole - 4)
            ProviderMark(provider: provider, logos: logos, height: hole * 0.9, maxWidth: hole * 1.4)
                .overlay {
                    if pairsWithPage {
                        Color.clear.paired(PanelHero.logo(provider), in: namespace)
                    }
                }
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            if pairsWithPage {
                Color.clear.paired(PanelHero.tint(provider), in: namespace)
            }
        }
    }
}

// The provider's name and its busiest account's used share, with a count of the accounts that need sign-in.
private struct EmblemCaption: View {
    let detail: ProviderDetail

    var body: some View {
        HStack(spacing: 6) {
            Text(ProviderRegistry.displayName(for: detail.usage.provider))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Text(UsageFormatting.usedPercent(detail.peakFraction))
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            if detail.usage.problemCount > 0 {
                SignInBadge(count: detail.usage.problemCount)
            }
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
                        Text(usage.accountsLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if let badge = usage.attention.badge {
                        StatusBadge(badge: badge, showsCount: true)
                    }
                    if usage.problemCount > 0 {
                        SignInBadge(count: usage.problemCount)
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
