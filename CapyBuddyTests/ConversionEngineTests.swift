import XCTest
import ImageIO
import CoreGraphics
import AppKit
@testable import CapyBuddy

final class ConversionEngineTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CapyBuddyTests-PictureConvert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Real ImageIO conversions

    func testPNGSourceConvertsToJPEG() throws {
        let input = try writeSampleImage(format: .png, name: "fixture.png", size: 64)
        let output = tempDir.appendingPathComponent("out.jpg")

        try ConversionEngine.convertImage(
            inputURL: input,
            outputURL: output,
            targetFormat: .jpeg
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        try assertImageType(at: output, equals: "public.jpeg")
    }

    func testPNGSourceConvertsToAVIFWhenSupported() throws {
        try XCTSkipUnless(
            ConversionFormat.writableOnThisSystem.contains(.avif),
            "AVIF write not supported on this macOS build"
        )
        let input = try writeSampleImage(format: .png, name: "fixture.png", size: 64)
        let output = tempDir.appendingPathComponent("out.avif")

        try ConversionEngine.convertImage(
            inputURL: input,
            outputURL: output,
            targetFormat: .avif
        )

        try assertImageType(at: output, equals: "public.avif")
    }

    func testJPEGSourceConvertsToPNG() throws {
        let input = try writeSampleImage(format: .jpeg, name: "fixture.jpg", size: 64)
        let output = tempDir.appendingPathComponent("out.png")

        try ConversionEngine.convertImage(
            inputURL: input,
            outputURL: output,
            targetFormat: .png
        )

        try assertImageType(at: output, equals: "public.png")
    }

    func testRoundTripPreservesPixelDimensions() throws {
        let input = try writeSampleImage(format: .png, name: "fixture.png", size: 100)
        let output = tempDir.appendingPathComponent("out.heic")

        try ConversionEngine.convertImage(
            inputURL: input,
            outputURL: output,
            targetFormat: .heic
        )

        let dim = try imagePixelDimensions(at: output)
        XCTAssertEqual(dim.width, 100)
        XCTAssertEqual(dim.height, 100)
    }

    func testUnreadableSourceThrows() {
        let bogus = tempDir.appendingPathComponent("does-not-exist.png")
        let output = tempDir.appendingPathComponent("out.jpg")

        XCTAssertThrowsError(
            try ConversionEngine.convertImage(
                inputURL: bogus,
                outputURL: output,
                targetFormat: .jpeg
            )
        ) { error in
            XCTAssertEqual(error as? ConversionError, .unreadableSource)
        }
    }

    // MARK: - defaultOutputURL

    func testDefaultOutputURLUsesTargetExtension() {
        let input = URL(fileURLWithPath: "/tmp/photo.png")
        let dir = URL(fileURLWithPath: "/tmp")
        let out = ConversionEngine.defaultOutputURL(
            for: input, targetFormat: .heic, in: dir
        )
        XCTAssertEqual(out.lastPathComponent, "photo.heic")
    }

    func testDefaultOutputURLAddsConvertedSuffixWhenSameExtension() {
        let input = URL(fileURLWithPath: "/tmp/photo.png")
        let dir = URL(fileURLWithPath: "/tmp")
        let out = ConversionEngine.defaultOutputURL(
            for: input, targetFormat: .png, in: dir
        )
        XCTAssertEqual(out.lastPathComponent, "photo-converted.png")
    }

    func testDefaultOutputURLAvoidsClobberingExistingFiles() throws {
        let input = tempDir.appendingPathComponent("photo.png")
        let occupied = tempDir.appendingPathComponent("photo.jpg")
        try Data([0xFF]).write(to: occupied)

        let out = ConversionEngine.defaultOutputURL(
            for: input, targetFormat: .jpeg, in: tempDir
        )
        XCTAssertEqual(out.lastPathComponent, "photo (1).jpg")
    }

    func testUniquedAcceptsFreshPaths() {
        let fresh = tempDir.appendingPathComponent("never-existed.heic")
        XCTAssertEqual(ConversionEngine.uniqued(fresh), fresh)
    }

    func testUniquedIncrementsThroughExistingPaths() throws {
        let base = tempDir.appendingPathComponent("note.gif")
        let one  = tempDir.appendingPathComponent("note (1).gif")
        try Data([0]).write(to: base)
        try Data([0]).write(to: one)

        let next = ConversionEngine.uniqued(base)
        XCTAssertEqual(next.lastPathComponent, "note (2).gif")
    }

    // MARK: - Helpers

    /// Render a 1×1-style solid colored image into the given format using
    /// ImageIO, so the fixture is a real on-disk file we can decode again.
    private func writeSampleImage(
        format: ConversionFormat,
        name: String,
        size: Int
    ) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!

        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.systemBlue.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = bitmap.cgImage else {
            throw NSError(domain: "test", code: -1)
        }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.utiIdentifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "test", code: -2)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "test", code: -3)
        }
        return url
    }

    private func assertImageType(
        at url: URL,
        equals expectedUTI: String,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            XCTFail("CGImageSource failed for \(url.lastPathComponent)", file: file, line: line)
            return
        }
        let actual = CGImageSourceGetType(source) as String?
        XCTAssertEqual(actual, expectedUTI, file: file, line: line)
    }

    private func imagePixelDimensions(at url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw NSError(domain: "test", code: -1)
        }
        return (w, h)
    }
}
