// Draws Quotablet's app icon and writes it, at every size macOS asks for, into Quotablet/Resources/Assets.xcassets.
// Change the drawing here and run the script from the repository root rather than editing the PNGs:
//
//     swift Tools/RenderAppIcon.swift
//
// The icon is the panel's emblem for Quotablet itself: six cyan petals filled to different shares around a dark disc that holds
// the letter Q, as a provider with no logo file shows its letter. It fills Apple's macOS icon grid, an 824-point continuous
// rounded square centered in a 1024-point canvas, so macOS 26 shows it as it is instead of boxing it in a gray squircle.

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// The outline of `PetalGeometry` in Quotablet/UI/ProviderFlower.swift, for a flower of several petals, in a y-down plane.
struct PetalOutline {
    let petalCount: Int
    let index: Int
    let outerRadius: CGFloat

    var innerRadius: CGFloat { outerRadius * 0.28 }
    var axisAngle: CGFloat { -.pi / 2 + 2 * .pi * CGFloat(index) / CGFloat(petalCount) }
    private var maxHalfSpan: CGFloat { .pi / CGFloat(petalCount) - 6 * .pi / 360 }

    func halfAngle(atRadius rho: CGFloat) -> CGFloat {
        guard rho > innerRadius, rho < outerRadius else { return 0 }
        let length = outerRadius - innerRadius
        let along = (rho - innerRadius) / length
        let halfWidth = 0.42 * length * pow(sin(.pi * pow(along, 1.25)), 0.75)
        return min(asin(min(halfWidth / rho, 1)), maxHalfSpan)
    }

    func path(in center: CGPoint) -> CGPath {
        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        let radii = (0...72).map { innerRadius + (outerRadius - innerRadius) * CGFloat($0) / 72 }
        let out = radii.map { point($0, axisAngle + halfAngle(atRadius: $0)) }
        let back = radii.reversed().dropFirst().dropLast().map { point($0, axisAngle - halfAngle(atRadius: $0)) }
        let path = CGMutablePath()
        path.addLines(between: out + back)
        path.closeSubpath()
        return path
    }

    func area(withinRadius radius: CGFloat) -> CGFloat {
        let limit = min(radius, outerRadius)
        guard limit > innerRadius else { return 0 }
        let ringWidth = (limit - innerRadius) / 128
        return (0..<128).reduce(0) { area, ring in
            let rho = innerRadius + (CGFloat(ring) + 0.5) * ringWidth
            return area + 2 * halfAngle(atRadius: rho) * rho * ringWidth
        }
    }

    // The radius whose disk covers `fraction` of the petal's area, as the panel fills a petal.
    func fillRadius(forUsedFraction fraction: Double) -> CGFloat {
        let target = CGFloat(fraction) * area(withinRadius: outerRadius)
        var low = innerRadius
        var high = outerRadius
        for _ in 0..<48 {
            let middle = (low + high) / 2
            if area(withinRadius: middle) < target { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }
}

enum IconLook {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let canvas: CGFloat = 1024
    static let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let cornerRadius: CGFloat = 185.4
    static let center = CGPoint(x: 512, y: 512)
    static let outerRadius: CGFloat = 300
    // One point of the panel's 180-point emblem, in canvas units, so strokes keep the emblem's weight.
    static let point = 2 * outerRadius / 180
    // Clockwise from 12 o'clock. Uneven shares, so the petals read as accounts at different points of their limits.
    static let usedFractions = [0.9, 0.55, 0.78, 0.4, 0.68, 0.84]

    static let top = color(0.15, 0.21, 0.42)
    static let bottom = color(0.04, 0.06, 0.17)
    static let petal = color(0.39, 0.82, 1.0)
    static let disc = color(0.05, 0.08, 0.19)
    static let letter = color(1, 1, 1)

    static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: sRGB, components: [red, green, blue, alpha])!
    }

    static func gradient(_ colors: [CGColor]) -> CGGradient {
        CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil)!
    }
}

// Draws in canvas units on a y-down plane. `scale` is pixels per canvas unit, which shadows need because the CTM does not reach them.
func drawIcon(in context: CGContext, scale: CGFloat) {
    let squircle = RoundedRectangle(cornerRadius: IconLook.cornerRadius, style: .continuous).path(in: IconLook.body).cgPath
    let center = IconLook.center

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale, color: IconLook.color(0, 0, 0, 0.3))
    context.addPath(squircle)
    context.setFillColor(IconLook.bottom)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(squircle)
    context.clip()
    context.drawLinearGradient(
        IconLook.gradient([IconLook.top, IconLook.bottom]),
        start: CGPoint(x: center.x, y: IconLook.body.minY),
        end: CGPoint(x: center.x, y: IconLook.body.maxY),
        options: []
    )

    // The glow behind the disc reaches 2.6 radii of the hole, as on an emblem.
    let hole = IconLook.outerRadius * 0.28
    context.drawRadialGradient(
        IconLook.gradient([IconLook.petal.copy(alpha: 0.32)!, IconLook.petal.copy(alpha: 0)!]),
        startCenter: center, startRadius: 0, endCenter: center, endRadius: hole * 2.6, options: []
    )

    // A pale track with a fine outline, and the used share shading from the full color at the base to a lighter tone at the tip.
    let shading = IconLook.gradient([IconLook.petal, IconLook.petal.copy(alpha: 0.72)!])
    for (index, fraction) in IconLook.usedFractions.enumerated() {
        let petal = PetalOutline(petalCount: IconLook.usedFractions.count, index: index, outerRadius: IconLook.outerRadius)
        let outline = petal.path(in: center)
        context.addPath(outline)
        context.setFillColor(IconLook.petal.copy(alpha: 0.2)!)
        context.fillPath()
        context.addPath(outline)
        context.setStrokeColor(IconLook.petal.copy(alpha: 0.5)!)
        context.setLineWidth(IconLook.point)
        context.strokePath()

        let reach = petal.fillRadius(forUsedFraction: fraction)
        context.saveGState()
        context.addPath(outline)
        context.clip()
        context.addEllipse(in: CGRect(x: center.x - reach, y: center.y - reach, width: 2 * reach, height: 2 * reach))
        context.clip()
        context.drawRadialGradient(
            shading, startCenter: center, startRadius: petal.innerRadius, endCenter: center, endRadius: IconLook.outerRadius,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    let discRadius = hole - 2 * IconLook.point
    let disc = CGRect(x: center.x - discRadius, y: center.y - discRadius, width: 2 * discRadius, height: 2 * discRadius)
    let ringWidth = 1.25 * IconLook.point
    context.setFillColor(IconLook.disc)
    context.fillEllipse(in: disc)
    context.setStrokeColor(IconLook.petal.copy(alpha: 0.6)!)
    context.setLineWidth(ringWidth)
    context.strokeEllipse(in: disc.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))

    // The panel's letter badge font, larger than on an emblem so the letter survives the small sizes. The cap height is centered,
    // so the bowl sits in the middle of the disc and the tail hangs below it.
    let heavy = NSFont.systemFont(ofSize: hole, weight: .heavy)
    let font = heavy.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: hole) } ?? heavy
    let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: "Q",
        attributes: [.font: font, .foregroundColor: NSColor(cgColor: IconLook.letter)!]
    ))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.scaleBy(x: 1, y: -1)
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: -bounds.midX, y: -font.capHeight / 2)
    CTLineDraw(line, context)
    context.restoreGState()

    context.restoreGState()
}

func renderIcon(pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: IconLook.sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(pixels) / IconLook.canvas
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)
    drawIcon(in: context, scale: scale)
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}

// Xcode's own layout for a Contents.json: sorted keys, two-space indents, and a closing newline.
func writeContents(_ object: [String: Any], to url: URL) throws {
    var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    data.append(0x0A)
    try data.write(to: url, options: .atomic)
}

// The ten images a macOS app icon set holds: each point size at 1x and 2x.
let slots = [16, 32, 128, 256, 512].flatMap { points in
    [1, 2].map { scale in
        (points: points, scale: scale, file: "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")
    }
}

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = repository.appending(path: "Quotablet/Resources/Assets.xcassets")
let iconSet = catalog.appending(path: "AppIcon.appiconset")
let info: [String: Any] = ["author": "xcode", "version": 1]

try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
for slot in slots {
    try writePNG(renderIcon(pixels: slot.points * slot.scale), to: iconSet.appending(path: slot.file))
}
try writeContents(
    [
        "images": slots.map { ["filename": $0.file, "idiom": "mac", "scale": "\($0.scale)x", "size": "\($0.points)x\($0.points)"] },
        "info": info,
    ],
    to: iconSet.appending(path: "Contents.json")
)
try writeContents(["info": info], to: catalog.appending(path: "Contents.json"))
print("Wrote \(slots.count) icon images to \(iconSet.path)")
