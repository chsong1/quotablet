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

enum MenuBarBadgeRenderer {
    static let slotHeight: CGFloat = 16

    private static let badgeSide: CGFloat = 14
    private static let badgeSpacing: CGFloat = 4
    private static let digitGap: CGFloat = 1
    private static let digitFontSize: CGFloat = 8.5
    private static let letterCapRatio: CGFloat = 0.58
    private static let outlineWidth: CGFloat = 1
    private static let dashCount: CGFloat = 12
    private static let trackAlpha: CGFloat = 0.30
    private static let staleTrackAlpha: CGFloat = 0.16
    private static let staleFillAlpha: CGFloat = 0.55
    private static let stripeFactor: CGFloat = 0.45
    private static let unknownAlpha: CGFloat = 0.90
    private static let missingAlpha: CGFloat = 0.55

    private struct Column: Sendable {
        let badge: MenuBarBadge
        let originX: CGFloat
        let width: CGFloat
    }

    static func image(for badges: [MenuBarBadge], height: CGFloat = MenuBarBadgeRenderer.slotHeight) -> NSImage {
        let columns = layout(badges)
        let layoutWidth = columns.last.map { $0.originX + $0.width } ?? 0
        let size = NSSize(width: layoutWidth * height / slotHeight, height: height)
        // AppKit runs the handler on whichever thread draws the image, so it must not inherit the main actor.
        let image = NSImage(size: size, flipped: false) { @Sendable destination in
            guard layoutWidth > 0, let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.translateBy(x: destination.minX, y: destination.minY)
            context.scaleBy(x: destination.width / layoutWidth, y: destination.height / slotHeight)
            draw(columns, in: context)
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func layout(_ badges: [MenuBarBadge]) -> [Column] {
        var columns: [Column] = []
        var originX: CGFloat = 0
        for badge in badges {
            // Whole points keep every badge edge on the pixel grid at 1x.
            let digitWidth = badge.accountNumber.map { (digitGap + digitAdvance(String($0))).rounded() } ?? 0
            let width = badgeSide + digitWidth
            columns.append(Column(badge: badge, originX: originX, width: width))
            originX += width + badgeSpacing
        }
        return columns
    }

    private static func draw(_ columns: [Column], in context: CGContext) {
        context.saveGState()
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)
        // The layer keeps the clear blend from reaching whatever AppKit is drawing into.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for column in columns {
            drawBadge(column, in: context)
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func drawBadge(_ column: Column, in context: CGContext) {
        let badge = column.badge
        let geometry = RoundedSquareGeometry(side: badgeSide)
        let rect = CGRect(x: column.originX, y: (slotHeight - badgeSide) / 2, width: badgeSide, height: badgeSide)
        // Staleness is the report's age, not its amount, so an unknown gauge goes stale too. A missing pin has no report.
        let staleDim: CGFloat = badge.isStale ? staleFillAlpha : 1
        var digitAlpha: CGFloat = 1
        switch badge.gauge {
        case .used(let fraction):
            drawGauge(fraction, isStale: badge.isStale, letter: badge.letter, rect: rect, geometry: geometry, in: context)
            digitAlpha = staleDim
        case .unknown:
            drawOutline(letter: badge.letter, rect: rect, geometry: geometry, alpha: unknownAlpha * staleDim, isDashed: false, in: context)
            digitAlpha = staleDim
        case .missing:
            drawOutline(letter: badge.letter, rect: rect, geometry: geometry, alpha: missingAlpha, isDashed: true, in: context)
        }
        if let number = badge.accountNumber {
            drawDigits(String(number), at: CGPoint(x: rect.maxX + digitGap, y: rect.minY), alpha: digitAlpha, in: context)
        }
    }

    private static func drawGauge(
        _ fraction: Double,
        isStale: Bool,
        letter: String,
        rect: CGRect,
        geometry: RoundedSquareGeometry,
        in context: CGContext
    ) {
        let shape = CGPath(roundedRect: rect, cornerWidth: geometry.cornerRadius, cornerHeight: geometry.cornerRadius, transform: nil)
        let track = isStale ? staleTrackAlpha : trackAlpha
        let fill = isStale ? staleFillAlpha : 1

        context.setFillColor(gray: 0, alpha: track)
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
                    context.setFillColor(gray: 0, alpha: overlayAlpha(reaching: reached, over: track))
                    context.fill(CGRect(x: rect.minX, y: bandMinY, width: rect.width, height: 1))
                    bandMinY += 1
                    isOn.toggle()
                }
            } else {
                context.setFillColor(gray: 0, alpha: overlayAlpha(reaching: fill, over: track))
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
        isDashed: Bool,
        in context: CGContext
    ) {
        let inset = outlineWidth / 2
        let frame = rect.insetBy(dx: inset, dy: inset)
        let radius = geometry.cornerRadius - inset
        context.saveGState()
        context.setAlpha(alpha)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setFillColor(gray: 0, alpha: 1)
        context.setLineWidth(outlineWidth)
        if isDashed {
            let perimeter = 4 * (frame.width - 2 * radius) + 2 * CGFloat.pi * radius
            let period = perimeter / dashCount
            context.setLineDash(phase: 0, lengths: [period * 0.6, period * 0.4])
        }
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

    private static func drawDigits(_ digits: String, at origin: CGPoint, alpha: CGFloat, in context: CGContext) {
        context.saveGState()
        context.setAlpha(alpha)
        context.setFillColor(gray: 0, alpha: 1)
        context.textMatrix = .identity
        context.textPosition = origin
        CTLineDraw(typeset(digits, font: digitFont()), context)
        context.restoreGState()
    }

    // The track is already painted under the fill, so this is the alpha that composites to `reached`.
    private static func overlayAlpha(reaching reached: CGFloat, over base: CGFloat) -> CGFloat {
        guard base < 1 else { return 0 }
        return max(0, (reached - base) / (1 - base))
    }

    private static func digitAdvance(_ digits: String) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(typeset(digits, font: digitFont()), nil, nil, nil))
    }

    private static func typeset(_ text: String, font: NSFont) -> CTLine {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        return CTLineCreateWithAttributedString(attributed as CFAttributedString)
    }

    private static func letterFont(side: CGFloat) -> NSFont {
        let probe = NSFont.systemFont(ofSize: 100, weight: .heavy)
        return NSFont.systemFont(ofSize: side * letterCapRatio * 100 / probe.capHeight, weight: .heavy)
    }

    private static func digitFont() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: digitFontSize, weight: .bold)
    }
}
