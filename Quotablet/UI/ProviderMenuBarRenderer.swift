import AppKit
import CoreText

struct RoundedSquareGeometry: Equatable, Sendable {
    static let cornerRatio: CGFloat = 0.27

    let side: CGFloat

    var cornerRadius: CGFloat { side * Self.cornerRatio }

    var area: CGFloat {
        side * side - (4 - CGFloat.pi) * cornerRadius * cornerRadius
    }

    func area(below height: CGFloat) -> CGFloat {
        guard side > 0 else { return 0 }
        let clamped = min(max(height, 0), side)
        if clamped <= cornerRadius { return cornerStripArea(height: clamped) }
        if clamped >= side - cornerRadius { return area - cornerStripArea(height: side - clamped) }
        return cornerStripArea(height: cornerRadius) + side * (clamped - cornerRadius)
    }

    // The rounded corners make the bottom rows narrower than the middle ones, so the height
    // that covers a fraction of the area is not that fraction of the height.
    func fillHeight(forUsedFraction fraction: Double) -> CGFloat {
        if fraction.isNaN || fraction <= 0 { return 0 }
        if fraction >= 1 { return side }
        let target = CGFloat(fraction) * area
        var low: CGFloat = 0
        var high = side
        for _ in 0..<48 {
            let middle = (low + high) / 2
            if area(below: middle) < target {
                low = middle
            } else {
                high = middle
            }
        }
        return (low + high) / 2
    }

    private func cornerStripArea(height: CGFloat) -> CGFloat {
        let radius = cornerRadius
        let offset = height - radius
        let halfChord = max(radius * radius - offset * offset, 0).squareRoot()
        let angle = CGFloat(asin(Double(min(max(offset / radius, -1), 1))))
        let arc = (offset * halfChord + radius * radius * angle) / 2 + CGFloat.pi * radius * radius / 4
        return (side - 2 * radius) * height + 2 * arc
    }
}

// The menu bar image: for each provider, its logo and the used share of the provider's combined limit.
// A provider with no logo file gets a lettered badge that fills as the share grows.
//
// A logo is drawn exactly as its file provides it, trimmed to its artwork and scaled to one height. It is never
// tinted, dimmed, masked or outlined, because the brands forbid altering their marks. Only the text beside it
// says that a provider's data is stale.
enum ProviderMenuBarRenderer {
    private static let height: CGFloat = 16
    private static let logoHeight: CGFloat = 15
    private static let logoTextGap: CGFloat = 4
    private static let providerGap: CGFloat = 10

    private static let badgeSide: CGFloat = 14
    private static let badgeMinY: CGFloat = (height - badgeSide) / 2
    private static let textSize: CGFloat = 12
    private static let letterCapRatio: CGFloat = 0.58
    private static let outlineWidth: CGFloat = 1
    private static let trackAlpha: CGFloat = 0.30
    private static let staleTrackAlpha: CGFloat = 0.16
    private static let staleFillAlpha: CGFloat = 0.55
    private static let stripeFactor: CGFloat = 0.45
    private static let unknownAlpha: CGFloat = 0.90

    private struct Item: Sendable {
        let provider: String
        let letter: String
        let usedFraction: Double?
        let isStale: Bool
        let text: String
        let textAdvance: CGFloat
    }

    private struct Placement: Sendable {
        let item: Item
        let logo: ProviderLogo?
        let originX: CGFloat
        let markWidth: CGFloat
        let textX: CGFloat
    }

    private struct Arrangement: Sendable {
        let placements: [Placement]
        let width: CGFloat
    }

    static func image(for providers: [ProviderUsage], logos: ProviderLogoCatalog) -> NSImage {
        let items = providers.map(item(for:))
        let onDark = arrange(items, appearance: .dark, logos: logos)
        let onLight = arrange(items, appearance: .light, logos: logos)
        // The two differ only when a provider's dark and light files have different shapes. The image fits the wider one.
        let width = max(onDark.width, onLight.width)
        // AppKit runs the handler on whichever thread draws the image, so it must not inherit the main actor.
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { @Sendable destination in
            guard width > 0, let context = NSGraphicsContext.current?.cgContext else { return false }
            // The handler runs again whenever the menu bar changes appearance, so the variant is chosen here and not when the image is built.
            let appearance = NSAppearance.currentDrawing()
            context.saveGState()
            context.translateBy(x: destination.minX, y: destination.minY)
            context.scaleBy(x: destination.width / width, y: destination.height / height)
            draw(LogoAppearance(appearance) == .dark ? onDark : onLight, appearance: appearance, in: context)
            context.restoreGState()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func item(for usage: ProviderUsage) -> Item {
        let text = UsageFormatting.usedPercent(usage.usedFraction)
        return Item(
            provider: usage.provider,
            letter: ProviderRegistry.badgeLetter(for: usage.provider),
            usedFraction: usage.usedFraction,
            isStale: usage.isStale,
            text: text,
            textAdvance: advance(of: text, font: textFont())
        )
    }

    private static func arrange(_ items: [Item], appearance: LogoAppearance, logos: ProviderLogoCatalog) -> Arrangement {
        var placements: [Placement] = []
        var originX: CGFloat = 0
        for item in items {
            let logo = logos.logo(for: item.provider, appearance: appearance)
            let markWidth = logo.map { logoHeight * $0.aspectRatio } ?? badgeSide
            // Whole points keep the text on the pixel grid at 1x.
            let textX = (originX + markWidth + logoTextGap).rounded(.up)
            placements.append(Placement(item: item, logo: logo, originX: originX, markWidth: markWidth, textX: textX))
            originX = (textX + item.textAdvance).rounded(.up) + providerGap
        }
        return Arrangement(placements: placements, width: placements.isEmpty ? 0 : originX - providerGap)
    }

    private static func draw(_ arrangement: Arrangement, appearance: NSAppearance, in context: CGContext) {
        var ink = CGColor(gray: 0, alpha: 1)
        var quietInk = ink
        appearance.performAsCurrentDrawingAppearance {
            ink = NSColor.labelColor.cgColor
            quietInk = NSColor.secondaryLabelColor.cgColor
        }
        let font = textFont()
        // A whole-point baseline keeps the flat strokes of digits crisp at 1x.
        let baseline = ((height - font.capHeight) / 2).rounded()
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)
        for placement in arrangement.placements {
            if let logo = placement.logo {
                let box = CGRect(x: placement.originX, y: (height - logoHeight) / 2, width: placement.markWidth, height: logoHeight)
                logo.draw(in: box)
            } else {
                drawBadge(placement.item, at: placement.originX, ink: ink, in: context)
            }
            let textInk = placement.item.isStale ? quietInk : ink
            drawText(placement.item.text, font: font, at: CGPoint(x: placement.textX, y: baseline), color: textInk, in: context)
        }
    }

    private static func drawBadge(_ item: Item, at originX: CGFloat, ink: CGColor, in context: CGContext) {
        let rect = CGRect(x: originX, y: badgeMinY, width: badgeSide, height: badgeSide)
        let geometry = RoundedSquareGeometry(side: badgeSide)
        // The layer keeps the letter's clear blend from reaching whatever AppKit is drawing into.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        if let fraction = item.usedFraction {
            drawGauge(fraction, isStale: item.isStale, letter: item.letter, rect: rect, geometry: geometry, ink: ink, in: context)
        } else {
            // Staleness is the report's age, not its amount, so an unknown share goes stale too.
            let alpha = unknownAlpha * (item.isStale ? staleFillAlpha : 1)
            drawOutline(letter: item.letter, rect: rect, geometry: geometry, alpha: alpha, ink: ink, in: context)
        }
        context.endTransparencyLayer()
    }

    private static func drawGauge(
        _ fraction: Double,
        isStale: Bool,
        letter: String,
        rect: CGRect,
        geometry: RoundedSquareGeometry,
        ink: CGColor,
        in context: CGContext
    ) {
        let shape = CGPath(roundedRect: rect, cornerWidth: geometry.cornerRadius, cornerHeight: geometry.cornerRadius, transform: nil)
        let track = ink.alpha * (isStale ? staleTrackAlpha : trackAlpha)
        let fill = ink.alpha * (isStale ? staleFillAlpha : 1)

        context.setFillColor(ink.copy(alpha: track) ?? ink)
        context.addPath(shape)
        context.fillPath()

        let fillHeight = geometry.fillHeight(forUsedFraction: fraction)
        if fillHeight > 0 {
            context.saveGState()
            context.addPath(shape)
            context.clip()
            context.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: fillHeight))
            if isStale {
                var bandMinY = rect.minY
                var isOn = true
                while bandMinY < rect.minY + fillHeight {
                    let reached = isOn ? fill : fill * stripeFactor
                    context.setFillColor(ink.copy(alpha: overlayAlpha(reaching: reached, over: track)) ?? ink)
                    context.fill(CGRect(x: rect.minX, y: bandMinY, width: rect.width, height: 1))
                    bandMinY += 1
                    isOn.toggle()
                }
            } else {
                context.setFillColor(ink.copy(alpha: overlayAlpha(reaching: fill, over: track)) ?? ink)
                context.fill(rect)
            }
            context.restoreGState()
        }

        context.saveGState()
        context.setBlendMode(.clear)
        drawLetter(letter, in: rect, context: context)
        context.restoreGState()
    }

    private static func drawOutline(
        letter: String,
        rect: CGRect,
        geometry: RoundedSquareGeometry,
        alpha: CGFloat,
        ink: CGColor,
        in context: CGContext
    ) {
        let inset = outlineWidth / 2
        let frame = rect.insetBy(dx: inset, dy: inset)
        let radius = geometry.cornerRadius - inset
        context.saveGState()
        context.setAlpha(alpha)
        context.setStrokeColor(ink)
        context.setFillColor(ink)
        context.setLineWidth(outlineWidth)
        context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()
        drawLetter(letter, in: rect, context: context)
        context.restoreGState()
    }

    private static func drawLetter(_ letter: String, in rect: CGRect, context: CGContext) {
        let line = typeset(letter, font: letterFont(side: rect.width))
        context.textMatrix = .identity
        context.textPosition = .zero
        let ink = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(x: rect.midX - ink.midX, y: rect.midY - ink.midY)
        CTLineDraw(line, context)
    }

    private static func drawText(_ text: String, font: NSFont, at origin: CGPoint, color: CGColor, in context: CGContext) {
        context.saveGState()
        context.setFillColor(color)
        context.textMatrix = .identity
        context.textPosition = origin
        CTLineDraw(typeset(text, font: font), context)
        context.restoreGState()
    }

    // The track is already painted under the fill, so this is the alpha that composites to `reached`.
    private static func overlayAlpha(reaching reached: CGFloat, over base: CGFloat) -> CGFloat {
        guard base < 1 else { return 0 }
        return max(0, (reached - base) / (1 - base))
    }

    private static func advance(of text: String, font: NSFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(typeset(text, font: font), nil, nil, nil))
    }

    // CoreText draws black unless told to read the context's fill color.
    private static func typeset(_ text: String, font: NSFont) -> CTLine {
        let fromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, fromContext: true])
        return CTLineCreateWithAttributedString(attributed as CFAttributedString)
    }

    private static func letterFont(side: CGFloat) -> NSFont {
        let probe = NSFont.systemFont(ofSize: 100, weight: .heavy)
        return NSFont.systemFont(ofSize: side * letterCapRatio * 100 / probe.capHeight, weight: .heavy)
    }

    private static func textFont() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: textSize, weight: .medium)
    }
}
