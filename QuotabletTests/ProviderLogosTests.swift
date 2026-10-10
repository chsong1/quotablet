import AppKit
import XCTest

// The tests draw invented shapes only. No test, fixture or asset in this repository holds a real company logo.
private struct SyntheticLogo {
    var canvas = CGSize(width: 512, height: 256)
    var mark = CGRect(x: 128, y: 32, width: 256, height: 128)
    var top: [UInt8] = [200, 30, 90]
    var bottom: [UInt8] = [20, 140, 220]

    func writePNG(to url: URL) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(canvas.width),
            height: Int(canvas.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        paint(in: context)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func writePDF(to url: URL) throws {
        var box = CGRect(origin: .zero, size: canvas)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        paint(in: context)
        context.endPDFPage()
        context.closePDF()
    }

    // Two bands, so a mirrored or flipped draw puts the wrong color where a test samples.
    private func paint(in context: CGContext) {
        context.setFillColor(color(top))
        context.fill(CGRect(x: mark.minX, y: mark.midY, width: mark.width, height: mark.height / 2))
        context.setFillColor(color(bottom))
        context.fill(CGRect(x: mark.minX, y: mark.minY, width: mark.width, height: mark.height / 2))
    }

    private func color(_ rgb: [UInt8]) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb[0]) / 255, green: CGFloat(rgb[1]) / 255, blue: CGFloat(rgb[2]) / 255, alpha: 1)
    }
}

private extension XCTestCase {
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func render(_ image: NSImage, in appearance: NSAppearance.Name = .aqua) throws -> Raster {
        let scale = 2
        let width = Int((image.size.width * CGFloat(scale)).rounded(.up))
        let height = Int(image.size.height) * scale
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
        }
        let data = try XCTUnwrap(context.data)
        let buffer = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: context.bytesPerRow * height)
        return Raster(bytes: Array(buffer), bytesPerRow: context.bytesPerRow, width: width, height: height)
    }
}

final class LogoFileTests: XCTestCase {
    private let everything: Set<String> = [
        "anthropic-on-dark.pdf", "anthropic-on-dark.png", "anthropic-on-light.pdf", "anthropic-on-light.png", "anthropic.pdf", "anthropic.png"
    ]

    func testADarkMenuBarTriesItsOwnVariantsBeforeTheSharedFiles() {
        func name(_ present: Set<String>) -> String? {
            LogoFile.name(provider: "anthropic", appearance: .dark, among: present)
        }

        XCTAssertEqual(name(everything), "anthropic-on-dark.pdf")
        XCTAssertEqual(name(everything.subtracting(["anthropic-on-dark.pdf"])), "anthropic-on-dark.png")
        XCTAssertEqual(name(everything.subtracting(["anthropic-on-dark.pdf", "anthropic-on-dark.png"])), "anthropic.pdf")
        XCTAssertEqual(name(["anthropic-on-light.pdf", "anthropic.png"]), "anthropic.png")
        XCTAssertNil(name(["anthropic-on-light.pdf", "anthropic-on-light.png"]))
    }

    func testALightMenuBarTriesItsOwnVariantsBeforeTheSharedFiles() {
        func name(_ present: Set<String>) -> String? {
            LogoFile.name(provider: "anthropic", appearance: .light, among: present)
        }

        XCTAssertEqual(name(everything), "anthropic-on-light.pdf")
        XCTAssertEqual(name(everything.subtracting(["anthropic-on-light.pdf"])), "anthropic-on-light.png")
        XCTAssertEqual(name(everything.subtracting(["anthropic-on-light.pdf", "anthropic-on-light.png"])), "anthropic.pdf")
        XCTAssertEqual(name(["anthropic-on-dark.pdf", "anthropic.png"]), "anthropic.png")
        XCTAssertNil(name(["anthropic-on-dark.pdf", "anthropic-on-dark.png"]))
    }

    func testOnlyTheProvidersOwnFilesMatch() {
        XCTAssertEqual(LogoFile.name(provider: "cursor", appearance: .dark, among: everything.union(["cursor.png"])), "cursor.png")
        XCTAssertNil(LogoFile.name(provider: "cursor", appearance: .dark, among: everything))
        XCTAssertNil(LogoFile.name(provider: "openai", appearance: .dark, among: ["openai-codex.pdf", "openai-codex-on-dark.pdf"]))
        XCTAssertNil(LogoFile.name(provider: "anthropic", appearance: .dark, among: []))
    }

    func testTheProviderIdIsLowercasedLikeTheRegistryDoes() {
        XCTAssertEqual(LogoFile.name(provider: "Anthropic", appearance: .light, among: ["anthropic.pdf"]), "anthropic.pdf")
    }

    func testAppearancesSplitIntoDarkAndLight() throws {
        XCTAssertEqual(LogoAppearance(try XCTUnwrap(NSAppearance(named: .darkAqua))), .dark)
        XCTAssertEqual(LogoAppearance(try XCTUnwrap(NSAppearance(named: .aqua))), .light)
    }
}

final class AlphaChannelTests: XCTestCase {
    func testVisibleBoundsHoldEveryPixelWithAnyAlphaCountedFromTheTopLeft() throws {
        var values = [UInt8](repeating: 0, count: 10 * 6)
        values[1 * 10 + 2] = 1
        values[4 * 10 + 8] = 255
        let channel = try XCTUnwrap(AlphaChannel(width: 10, height: 6, values: values))

        XCTAssertEqual(channel.visibleBounds, CGRect(x: 2, y: 1, width: 7, height: 4))
    }

    func testAFullyTransparentBitmapHasNoBoundsAndASingleCornerPixelHasOne() throws {
        let empty = try XCTUnwrap(AlphaChannel(width: 4, height: 3, values: [UInt8](repeating: 0, count: 12)))
        var corner = [UInt8](repeating: 0, count: 12)
        corner[11] = 9
        let single = try XCTUnwrap(AlphaChannel(width: 4, height: 3, values: corner))

        XCTAssertNil(empty.visibleBounds)
        XCTAssertEqual(single.visibleBounds, CGRect(x: 3, y: 2, width: 1, height: 1))
    }

    func testABitmapWhoseSizeDisagreesWithItsBytesIsRefused() {
        XCTAssertNil(AlphaChannel(width: 4, height: 3, values: [1, 2, 3]))
        XCTAssertNil(AlphaChannel(width: 0, height: 3, values: []))
    }

    func testRenderingAnImageKeepsItsRowsFromTheTop() throws {
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { _ in
            NSColor.red.setFill()
            NSRect(x: 4, y: 12, width: 8, height: 4).fill()
            return true
        }

        let channel = try XCTUnwrap(AlphaChannel(rendering: image, longerSide: 40))

        XCTAssertEqual(channel.width, 40)
        XCTAssertEqual(channel.height, 20)
        XCTAssertEqual(channel.visibleBounds, CGRect(x: 4, y: 4, width: 8, height: 4))
    }
}

final class ProviderLogoTests: XCTestCase {
    func testAPNGKeepsOnlyItsArtworkAndWhereThatSitsInTheImage() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("anthropic.png")
        try SyntheticLogo().writePNG(to: url)

        let logo = try XCTUnwrap(ProviderLogo(contentsOf: url))

        XCTAssertEqual(logo.image.size, CGSize(width: 512, height: 256))
        XCTAssertEqual(logo.visibleRect, CGRect(x: 128, y: 32, width: 256, height: 128))
        XCTAssertEqual(logo.aspectRatio, 2)
        XCTAssertFalse(logo.image.isTemplate)
    }

    func testAPDFKeepsOnlyItsArtworkAndWhereThatSitsInTheImage() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("anthropic.pdf")
        try SyntheticLogo().writePDF(to: url)

        let logo = try XCTUnwrap(ProviderLogo(contentsOf: url))

        XCTAssertEqual(logo.image.size, CGSize(width: 512, height: 256))
        XCTAssertEqual(logo.visibleRect.minX, 128, accuracy: 0.01)
        XCTAssertEqual(logo.visibleRect.minY, 32, accuracy: 0.01)
        XCTAssertEqual(logo.visibleRect.width, 256, accuracy: 0.01)
        XCTAssertEqual(logo.visibleRect.height, 128, accuracy: 0.01)
    }

    func testAFileWithNoArtworkOrNoImageIsNotALogo() throws {
        let directory = try makeTemporaryDirectory()
        try SyntheticLogo(mark: .zero).writePNG(to: directory.appendingPathComponent("blank.png"))
        try Data("not an image".utf8).write(to: directory.appendingPathComponent("broken.png"))
        try SyntheticLogo().writePNG(to: directory.appendingPathComponent("real.png"))

        XCTAssertNil(ProviderLogo(contentsOf: directory.appendingPathComponent("blank.png")))
        XCTAssertNil(ProviderLogo(contentsOf: directory.appendingPathComponent("broken.png")))
        XCTAssertNil(ProviderLogo(contentsOf: directory.appendingPathComponent("missing.png")))
        XCTAssertNotNil(ProviderLogo(contentsOf: directory.appendingPathComponent("real.png")))
    }

    func testTheArtworkImageIsTheTrimmedMarkAtTheRequestedHeightWithItsColorsUnchanged() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("anthropic.png")
        try SyntheticLogo(top: [200, 30, 90], bottom: [20, 140, 220]).writePNG(to: url)
        let logo = try XCTUnwrap(ProviderLogo(contentsOf: url))

        let artwork = logo.artwork(height: 14)
        let raster = try render(artwork)

        XCTAssertEqual(artwork.size, NSSize(width: 28, height: 14))
        XCTAssertFalse(artwork.isTemplate)
        XCTAssertEqual(raster.pixel(column: 28, row: 6), [200, 30, 90, 255])
        XCTAssertEqual(raster.pixel(column: 28, row: 21), [20, 140, 220, 255])
        XCTAssertEqual(raster.alpha(column: 4, row: 4), 1)
        XCTAssertEqual(raster.alpha(column: 51, row: 23), 1)
    }
}

final class ProviderLogoLibraryTests: XCTestCase {
    func testTheDirectoryIsReadOnceAndAgainOnlyWhenItsModificationDateChanges() throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("Logos", isDirectory: true)
        var library = ProviderLogoLibrary(directoryURL: directory)

        XCTAssertTrue(library.reloadIfChanged())
        XCTAssertFalse(library.reloadIfChanged())
        XCTAssertNil(library.catalog.logo(for: "anthropic", appearance: .dark))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SyntheticLogo().writePNG(to: directory.appendingPathComponent("anthropic.png"))
        let firstStamp = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: firstStamp], ofItemAtPath: directory.path)
        XCTAssertTrue(library.reloadIfChanged())
        XCTAssertNotNil(library.catalog.logo(for: "anthropic", appearance: .dark))

        try SyntheticLogo().writePNG(to: directory.appendingPathComponent("openai-codex.png"))
        try FileManager.default.setAttributes([.modificationDate: firstStamp], ofItemAtPath: directory.path)
        XCTAssertFalse(library.reloadIfChanged())
        XCTAssertNil(library.catalog.logo(for: "openai-codex", appearance: .dark))

        try FileManager.default.setAttributes([.modificationDate: firstStamp.addingTimeInterval(1)], ofItemAtPath: directory.path)
        XCTAssertTrue(library.reloadIfChanged())
        XCTAssertNotNil(library.catalog.logo(for: "openai-codex", appearance: .dark))
    }

    func testOnlyReadablePDFAndPNGFilesBecomeLogos() throws {
        let directory = try makeTemporaryDirectory()
        try SyntheticLogo().writePDF(to: directory.appendingPathComponent("cursor.pdf"))
        try SyntheticLogo().writePNG(to: directory.appendingPathComponent("xai-oauth.png"))
        try Data("not an image".utf8).write(to: directory.appendingPathComponent("anthropic.png"))
        try Data("<svg/>".utf8).write(to: directory.appendingPathComponent("openai-codex.svg"))
        try Data("notes".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        var library = ProviderLogoLibrary(directoryURL: directory)

        XCTAssertTrue(library.reloadIfChanged())

        XCTAssertNotNil(library.catalog.logo(for: "cursor", appearance: .light))
        XCTAssertNotNil(library.catalog.logo(for: "xai-oauth", appearance: .light))
        XCTAssertNil(library.catalog.logo(for: "anthropic", appearance: .light))
        XCTAssertNil(library.catalog.logo(for: "openai-codex", appearance: .light))
    }

    func testEachAppearanceGetsItsOwnFileAndTheSharedFileServesTheRest() throws {
        let directory = try makeTemporaryDirectory()
        try SyntheticLogo().writePNG(to: directory.appendingPathComponent("anthropic-on-dark.png"))
        try SyntheticLogo(canvas: CGSize(width: 512, height: 512), mark: CGRect(x: 128, y: 128, width: 256, height: 256))
            .writePNG(to: directory.appendingPathComponent("anthropic.png"))
        var library = ProviderLogoLibrary(directoryURL: directory)

        XCTAssertTrue(library.reloadIfChanged())

        XCTAssertEqual(library.catalog.logo(for: "anthropic", appearance: .dark)?.aspectRatio, 2)
        XCTAssertEqual(library.catalog.logo(for: "anthropic", appearance: .light)?.aspectRatio, 1)
    }
}

@MainActor
final class UsageStoreLogosTests: XCTestCase {
    func testTheStoreLoadsLogosBesideItsSettingsAndReloadsThemOnThePresentationTick() async throws {
        let directory = try makeTemporaryDirectory()
        let logos = directory.appendingPathComponent("Logos", isDirectory: true)
        try FileManager.default.createDirectory(at: logos, withIntermediateDirectories: true)
        try SyntheticLogo().writePNG(to: logos.appendingPathComponent("anthropic.png"))
        let store = UsageStore(persistence: AppPersistence(directoryURL: directory), presentationInterval: .milliseconds(20)) { _ in
            UsageSnapshot(generatedAt: Date(), reportDrafts: [])
        }

        await store.start()
        XCTAssertNotNil(store.logos.logo(for: "anthropic", appearance: .dark))
        XCTAssertNil(store.logos.logo(for: "openai-codex", appearance: .dark))

        try SyntheticLogo().writePNG(to: logos.appendingPathComponent("openai-codex.png"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: logos.path)
        var attempts = 0
        while store.logos.logo(for: "openai-codex", appearance: .dark) == nil, attempts < 250 {
            try await Task.sleep(for: .milliseconds(20))
            attempts += 1
        }

        XCTAssertNotNil(store.logos.logo(for: "openai-codex", appearance: .dark))
        await store.shutdown()
    }
}

private struct Raster {
    let bytes: [UInt8]
    let bytesPerRow: Int
    let width: Int
    let height: Int

    func pixel(column: Int, row: Int) -> [UInt8] {
        let offset = row * bytesPerRow + column * 4
        return Array(bytes[offset..<offset + 4])
    }

    func alpha(column: Int, row: Int) -> Double {
        Double(pixel(column: column, row: row)[3]) / 255
    }

    func peakAlpha(columns: Range<Int>, rows: Range<Int>? = nil) -> Double {
        (rows ?? 0..<height).flatMap { row in columns.map { alpha(column: $0, row: row) } }.max() ?? 0
    }

    func pixels(columns: Range<Int>) -> [UInt8] {
        (0..<height).flatMap { row in columns.flatMap { pixel(column: $0, row: row) } }
    }

    // Consecutive columns that hold any ink in any row.
    var inkRuns: [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for column in 0...width {
            let hasInk = column < width && peakAlpha(columns: column..<column + 1) > 0
            if hasInk, start == nil { start = column }
            if !hasInk, let first = start {
                runs.append(first..<column)
                start = nil
            }
        }
        return runs
    }
}

final class ProviderMenuBarRendererTests: XCTestCase {
    private let darkLogo = SyntheticLogo(top: [200, 30, 90], bottom: [20, 140, 220])
    private let lightLogo = SyntheticLogo(top: [250, 190, 20], bottom: [30, 160, 90])

    func testALogoReplacesTheBadgeSoTheImageGrowsByTheDifferenceInWidth() throws {
        let providers = [usage("anthropic", 0.5)]

        let bare = ProviderMenuBarRenderer.image(for: providers, logos: .empty)
        let logo = ProviderMenuBarRenderer.image(for: providers, logos: try catalog(["anthropic.png": SyntheticLogo()]))

        XCTAssertEqual(logo.size.width - bare.size.width, 16)
        XCTAssertEqual(logo.size.height, 16)
        XCTAssertFalse(logo.isTemplate)
        XCTAssertFalse(bare.isTemplate)
    }

    func testLogoPixelsKeepTheSourceColorsExactlyInEveryAppearance() throws {
        let image = ProviderMenuBarRenderer.image(for: [usage("anthropic", 0.5)], logos: try catalog(["anthropic.png": darkLogo]))

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let raster = try render(image, in: appearance)

            XCTAssertEqual(raster.pixel(column: 30, row: 3), [200, 30, 90, 255], appearance.rawValue)
            XCTAssertEqual(raster.pixel(column: 30, row: 28), [20, 140, 220, 255], appearance.rawValue)
            XCTAssertEqual(raster.alpha(column: 30, row: 0), 0, appearance.rawValue)
            XCTAssertEqual(raster.alpha(column: 30, row: 31), 0, appearance.rawValue)
        }
    }

    func testTheLogoVariantFollowsTheAppearanceTheImageIsDrawnIn() throws {
        let files = ["anthropic-on-dark.png": darkLogo, "anthropic-on-light.png": lightLogo]
        let image = ProviderMenuBarRenderer.image(for: [usage("anthropic", 0.5)], logos: try catalog(files))

        XCTAssertEqual(try render(image, in: .darkAqua).pixel(column: 30, row: 3), [200, 30, 90, 255])
        XCTAssertEqual(try render(image, in: .aqua).pixel(column: 30, row: 3), [250, 190, 20, 255])
    }

    func testAnAppearanceWithoutAVariantGetsTheBadgeAndTheImageFitsTheWiderLayout() throws {
        let image = ProviderMenuBarRenderer.image(for: [usage("ibm", 0.5)], logos: try catalog(["ibm-on-dark.png": darkLogo]))
        let bare = ProviderMenuBarRenderer.image(for: [usage("ibm", 0.5)], logos: .empty)

        let dark = try render(image, in: .darkAqua)
        let light = try render(image, in: .aqua)

        XCTAssertEqual(image.size.width - bare.size.width, 16)
        XCTAssertEqual(dark.pixel(column: 14, row: 8), [200, 30, 90, 255])
        XCTAssertGreaterThan(light.alpha(column: 9, row: 8), 0.2)
        XCTAssertEqual(light.alpha(column: 30, row: 8), 0)
    }

    func testStaleDataChangesOnlyTheTextAndNeverTheLogoPixels() throws {
        let logos = try catalog(["anthropic.png": darkLogo])
        let fresh = ProviderMenuBarRenderer.image(for: [usage("anthropic", 0.5)], logos: logos)
        let stale = ProviderMenuBarRenderer.image(for: [usage("anthropic", 0.5, isStale: true)], logos: logos)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let freshRaster = try render(fresh, in: appearance)
            let staleRaster = try render(stale, in: appearance)
            let text = 68..<freshRaster.width

            XCTAssertEqual(staleRaster.width, freshRaster.width)
            XCTAssertEqual(staleRaster.pixels(columns: 0..<60), freshRaster.pixels(columns: 0..<60), appearance.rawValue)
            XCTAssertNotEqual(staleRaster.pixels(columns: text), freshRaster.pixels(columns: text), appearance.rawValue)
            XCTAssertLessThan(staleRaster.peakAlpha(columns: text), freshRaster.peakAlpha(columns: text) - 0.2, appearance.rawValue)
        }
    }

    func testTextSitsAtLeastThreePointsFromItsLogoAndProvidersAreAtLeastEightPointsApart() throws {
        let logos = try catalog(["anthropic.png": darkLogo, "openai-codex.png": lightLogo])
        let image = ProviderMenuBarRenderer.image(for: [usage("anthropic", 0.5), usage("openai-codex", 0.94)], logos: logos)

        let runs = try render(image).inkRuns

        let firstLogo = try XCTUnwrap(runs.first)
        let secondLogoIndex = try XCTUnwrap(runs.indices.dropFirst().first { runs[$0].count >= 60 })
        XCTAssertEqual(firstLogo, 0..<60)
        XCTAssertGreaterThanOrEqual(runs[1].lowerBound - firstLogo.upperBound, 6)
        XCTAssertGreaterThanOrEqual(runs[secondLogoIndex].lowerBound - runs[secondLogoIndex - 1].upperBound, 16)
        XCTAssertGreaterThanOrEqual(runs[secondLogoIndex + 1].lowerBound - runs[secondLogoIndex].upperBound, 6)
    }

    func testAnUnknownShareDrawsAnEnDashInsteadOfDigits() throws {
        let logos = try catalog(["anthropic.png": darkLogo])
        let unknown = ProviderMenuBarRenderer.image(for: [usage("anthropic", nil)], logos: logos)
        let known = ProviderMenuBarRenderer.image(for: [usage("anthropic", 0.5)], logos: logos)

        let raster = try render(unknown)

        XCTAssertLessThan(unknown.size.width, known.size.width)
        XCTAssertGreaterThan(raster.peakAlpha(columns: 68..<raster.width), 0.4)
        XCTAssertEqual(raster.inkRuns.count, 2)
    }

    func testTextAndBadgeAreDrawnInTheLabelColorOfTheAppearance() throws {
        let image = ProviderMenuBarRenderer.image(for: [usage("ibm", 1)], logos: .empty)

        let dark = try render(image, in: .darkAqua)
        let light = try render(image, in: .aqua)

        let darkFill = dark.pixel(column: 9, row: 16)
        let lightFill = light.pixel(column: 9, row: 16)
        XCTAssertGreaterThan(dark.alpha(column: 9, row: 16), 0.8)
        XCTAssertEqual(Array(darkFill[0..<3]), [darkFill[3], darkFill[3], darkFill[3]])
        XCTAssertGreaterThan(light.alpha(column: 9, row: 16), 0.8)
        XCTAssertEqual(Array(lightFill[0..<3]), [0, 0, 0])
        let darkText = (0..<dark.height).flatMap { row in (36..<dark.width).map { dark.pixel(column: $0, row: row) } }.max { $0[3] < $1[3] }
        XCTAssertEqual(darkText.map { Array($0[0..<3]) }, darkText.map { [$0[3], $0[3], $0[3]] })
    }

    func testWithoutALogoTheBadgeFillsFromTheBottomOverATrackAndKnocksTheLetterOut() throws {
        let empty = try render(badge(0))
        let half = try render(badge(0.5))
        let full = try render(badge(1))

        let ink = full.alpha(column: 9, row: 16)
        XCTAssertGreaterThan(ink, 0.8)
        XCTAssertEqual(empty.alpha(column: 9, row: 16) / ink, 0.30, accuracy: 0.03)
        XCTAssertEqual(half.alpha(column: 9, row: 26) / ink, 1, accuracy: 0.03)
        XCTAssertEqual(half.alpha(column: 9, row: 6) / ink, 0.30, accuracy: 0.03)
        XCTAssertEqual(empty.alpha(column: 14, row: 16), 0, accuracy: 0.05)
        XCTAssertEqual(full.alpha(column: 14, row: 16), 0, accuracy: 0.05)
    }

    func testAnUnknownShareDrawsAFramedOutlineAroundASolidLetter() throws {
        let known = try render(badge(1))
        let unknown = try render(badge(nil))

        let ink = known.alpha(column: 9, row: 16)
        XCTAssertEqual(unknown.alpha(column: 9, row: 16), 0, accuracy: 0.02)
        XCTAssertEqual(unknown.alpha(column: 14, row: 16) / ink, 0.9, accuracy: 0.05)
        XCTAssertGreaterThan((10...22).map { unknown.alpha(column: 0, row: $0) / ink }.min() ?? 0, 0.85)
    }

    func testAStaleBadgeStripesTheFilledPartAndDimsTheTrack() throws {
        let fresh = try render(badge(1))
        let stale = try render(badge(1, isStale: true))
        let staleEmpty = try render(badge(0, isStale: true))

        let ink = fresh.alpha(column: 9, row: 28)
        let bands = [28, 26, 24, 22].map { stale.alpha(column: 9, row: $0) / ink }
        XCTAssertEqual(bands[0], bands[2], accuracy: 0.03)
        XCTAssertEqual(bands[1], bands[3], accuracy: 0.03)
        XCTAssertGreaterThan(abs(bands[0] - bands[1]), 0.2)
        XCTAssertLessThan(bands.max() ?? 1, 0.7)
        XCTAssertEqual(staleEmpty.alpha(column: 9, row: 16) / ink, 0.16, accuracy: 0.03)
    }

    func testAStaleUnknownBadgeDimsItsOutlineAndLetter() throws {
        let fresh = try render(badge(nil))
        let stale = try render(badge(nil, isStale: true))
        let badgeColumns = 0..<28

        XCTAssertEqual(stale.peakAlpha(columns: badgeColumns) / fresh.peakAlpha(columns: badgeColumns), 0.55, accuracy: 0.03)
    }

    func testTheMenuBarDimsAProviderOnlyWhenEveryMeasuredAccountIsStale() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // The same calls the menu bar label makes: the snapshot's provider usage, drawn by the renderer.
        func raster(secondsOld ages: [TimeInterval]) throws -> Raster {
            let drafts = ages.enumerated().map { index, age in
                UsageReportDraft(
                    provider: "ibm",
                    sourceAccount: SourceAccountIdentity(accountID: "ibm-\(index)", organizationID: nil, projectID: nil),
                    privateDisplayLabel: nil,
                    fetchedAt: now.addingTimeInterval(-age),
                    resetCredits: nil,
                    quotas: [
                        UsageQuotaDraft(
                            id: "weekly",
                            label: "Weekly",
                            scope: nil,
                            window: QuotaWindow(identity: QuotaWindowIdentity(id: "7d"), label: "7 Day", durationMilliseconds: 604_800_000, resetLabel: nil),
                            amount: UsageAmount(used: 50, limit: 100, remaining: 50, usedFraction: 0.5, remainingFraction: 0.5, unit: .percent),
                            status: .available,
                            resetsAt: nil
                        )
                    ]
                )
            }
            let providers = UsageSnapshot(generatedAt: now, reportDrafts: drafts).providerUsage(now: now)
            return try render(ProviderMenuBarRenderer.image(for: providers, logos: .empty))
        }

        let fresh = try raster(secondsOld: [60, 60])
        let someStale = try raster(secondsOld: [3_600, 60])
        let allStale = try raster(secondsOld: [3_600, 3_600])
        let text = 36..<fresh.width

        XCTAssertEqual(someStale.pixels(columns: 0..<someStale.width), fresh.pixels(columns: 0..<fresh.width))
        XCTAssertLessThan(allStale.peakAlpha(columns: text), fresh.peakAlpha(columns: text) - 0.2)
    }

    private func usage(_ provider: String, _ used: Double?, isStale: Bool = false) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            accountCount: 1,
            measured: [],
            usedFraction: used,
            isStale: isStale,
            attention: ProviderAttention(exhaustedAccounts: 0, nearLimitAccounts: 0)
        )
    }

    // The letter I has a stem through the middle of the badge, where the tests look for the knocked-out letter.
    private func badge(_ used: Double?, isStale: Bool = false) -> NSImage {
        ProviderMenuBarRenderer.image(for: [usage("ibm", used, isStale: isStale)], logos: .empty)
    }

    private func catalog(_ files: [String: SyntheticLogo]) throws -> ProviderLogoCatalog {
        let directory = try makeTemporaryDirectory()
        for (name, logo) in files {
            try logo.writePNG(to: directory.appendingPathComponent(name))
        }
        var library = ProviderLogoLibrary(directoryURL: directory)
        _ = library.reloadIfChanged()
        return library.catalog
    }
}
