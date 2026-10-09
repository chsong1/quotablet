import AppKit

// Quotablet ships no logos. Their owners do not license the marks with this project, so the app draws files the user installs.

enum LogoAppearance: Sendable {
    case dark
    case light

    init(_ appearance: NSAppearance) {
        self = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

enum LogoFile {
    // The first file that exists wins: one made for the menu bar's appearance, then the one that suits both.
    static func name(provider: String, appearance: LogoAppearance, among present: Set<String>) -> String? {
        let id = provider.lowercased()
        let variant = appearance == .dark ? "-on-dark" : "-on-light"
        return ["\(id)\(variant).pdf", "\(id)\(variant).png", "\(id).pdf", "\(id).png"].first(where: present.contains)
    }
}

// The alpha byte of every pixel of a rendered logo, with row 0 at the top.
struct AlphaChannel: Equatable, Sendable {
    let width: Int
    let height: Int
    let values: [UInt8]

    init?(width: Int, height: Int, values: [UInt8]) {
        guard width > 0, height > 0, values.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.values = values
    }

    // Draws the image into a bitmap whose longer side is `longerSide` pixels.
    init?(rendering image: NSImage, longerSide: Int) {
        let longest = max(image.size.width, image.size.height)
        guard image.size.width.isFinite, image.size.height.isFinite, longest > 0 else { return nil }
        let scale = CGFloat(longerSide) / longest
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let data = context.data
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(bounds)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        self.init(width: width, height: height, values: (0..<width * height).map { pixels[$0 * 4 + 3] })
    }

    // The smallest rectangle, counted in pixels from the top left, that holds every pixel with any alpha. Nil when none has.
    var visibleBounds: CGRect? {
        var minColumn = width
        var maxColumn = -1
        var minRow = height
        var maxRow = -1
        for row in 0..<height {
            for column in 0..<width where values[row * width + column] > 0 {
                minColumn = min(minColumn, column)
                maxColumn = max(maxColumn, column)
                minRow = min(minRow, row)
                maxRow = row
            }
        }
        guard maxColumn >= 0 else { return nil }
        return CGRect(x: minColumn, y: minRow, width: maxColumn - minColumn + 1, height: maxRow - minRow + 1)
    }
}

// A logo file and the part of it that holds artwork. Official files can carry wide transparent margins,
// and drawing only the artwork keeps every logo the same height.
struct ProviderLogo: Sendable {
    private static let measuredLongerSide = 512

    // Loaded once and never mutated. The box exists because the macOS 15 SDK that CI builds with does not mark NSImage Sendable.
    private final class ImageBox: @unchecked Sendable {
        let image: NSImage

        init(_ image: NSImage) {
            self.image = image
        }
    }

    private let box: ImageBox
    var image: NSImage { box.image }
    // In the image's own points, origin at the bottom left, which is the space `NSImage.draw(in:from:)` reads.
    let visibleRect: CGRect

    var aspectRatio: CGFloat { visibleRect.width / visibleRect.height }

    init?(contentsOf url: URL) {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        image.isTemplate = false
        guard
            let channel = AlphaChannel(rendering: image, longerSide: Self.measuredLongerSide),
            let pixels = channel.visibleBounds
        else { return nil }
        let scaleX = image.size.width / CGFloat(channel.width)
        let scaleY = image.size.height / CGFloat(channel.height)
        box = ImageBox(image)
        visibleRect = CGRect(
            x: pixels.minX * scaleX,
            y: (CGFloat(channel.height) - pixels.maxY) * scaleY,
            width: pixels.width * scaleX,
            height: pixels.height * scaleY
        )
    }
}

// Every readable logo file of one directory, loaded once.
struct ProviderLogoCatalog: Sendable {
    static let empty = ProviderLogoCatalog(logos: [:])

    private let logos: [String: ProviderLogo]
    private let names: Set<String>

    private init(logos: [String: ProviderLogo]) {
        self.logos = logos
        names = Set(logos.keys)
    }

    init(loadingFrom directory: URL) {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var logos: [String: ProviderLogo] = [:]
        for name in entries where name.hasSuffix(".pdf") || name.hasSuffix(".png") {
            logos[name] = ProviderLogo(contentsOf: directory.appendingPathComponent(name))
        }
        self.init(logos: logos)
    }

    func logo(for provider: String, appearance: LogoAppearance) -> ProviderLogo? {
        LogoFile.name(provider: provider, appearance: appearance, among: names).flatMap { logos[$0] }
    }
}

// Reads the directory again only when its modification date has changed since the last read.
// There is no file watcher, so the caller decides how often to ask. The app never writes to the directory.
struct ProviderLogoLibrary {
    private struct Stamp: Equatable {
        let modified: Date?
    }

    let directoryURL: URL
    private(set) var catalog = ProviderLogoCatalog.empty
    private var lastRead: Stamp?

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    // Says whether the catalog was replaced.
    mutating func reloadIfChanged() -> Bool {
        let stamp = Stamp(modified: modificationDate)
        guard stamp != lastRead else { return false }
        lastRead = stamp
        catalog = ProviderLogoCatalog(loadingFrom: directoryURL)
        return true
    }

    private var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: directoryURL.path))?[.modificationDate] as? Date
    }
}
