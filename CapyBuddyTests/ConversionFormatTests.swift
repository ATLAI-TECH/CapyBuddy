import XCTest
@testable import CapyBuddy

final class ConversionFormatTests: XCTestCase {

    // MARK: - Display fields

    func testDisplayNamesAreUserFacing() {
        XCTAssertEqual(ConversionFormat.png.displayName, "PNG")
        XCTAssertEqual(ConversionFormat.jpeg.displayName, "JPEG")
        XCTAssertEqual(ConversionFormat.heic.displayName, "HEIC")
        XCTAssertEqual(ConversionFormat.tiff.displayName, "TIFF")
        XCTAssertEqual(ConversionFormat.gif.displayName, "GIF")
        XCTAssertEqual(ConversionFormat.avif.displayName, "AVIF")
        XCTAssertEqual(ConversionFormat.webp.displayName, "WebP")
        XCTAssertEqual(ConversionFormat.ico.displayName, "ICO")
        XCTAssertEqual(ConversionFormat.bmp.displayName, "BMP")
        XCTAssertEqual(ConversionFormat.icns.displayName, "ICNS")
        XCTAssertEqual(ConversionFormat.jpeg2000.displayName, "JP2")
    }

    func testFileExtensionsAreLowercaseNoDot() {
        for format in ConversionFormat.allCases {
            XCTAssertFalse(format.fileExtension.hasPrefix("."),
                           "\(format) extension should not have leading dot")
            XCTAssertEqual(format.fileExtension, format.fileExtension.lowercased())
        }
        // JPEG renders as `.jpg` (the more common spelling), not `.jpeg`.
        XCTAssertEqual(ConversionFormat.jpeg.fileExtension, "jpg")
    }

    func testUTIIdentifiersMatchAppleConventions() {
        XCTAssertEqual(ConversionFormat.png.utiIdentifier, "public.png")
        XCTAssertEqual(ConversionFormat.jpeg.utiIdentifier, "public.jpeg")
        XCTAssertEqual(ConversionFormat.heic.utiIdentifier, "public.heic")
        XCTAssertEqual(ConversionFormat.tiff.utiIdentifier, "public.tiff")
        XCTAssertEqual(ConversionFormat.gif.utiIdentifier, "com.compuserve.gif")
        XCTAssertEqual(ConversionFormat.avif.utiIdentifier, "public.avif")
        XCTAssertEqual(ConversionFormat.webp.utiIdentifier, "org.webmproject.webp")
        XCTAssertEqual(ConversionFormat.ico.utiIdentifier, "com.microsoft.ico")
        XCTAssertEqual(ConversionFormat.bmp.utiIdentifier, "com.microsoft.bmp")
        XCTAssertEqual(ConversionFormat.icns.utiIdentifier, "com.apple.icns")
        XCTAssertEqual(ConversionFormat.jpeg2000.utiIdentifier, "public.jpeg-2000")
    }

    func testIsLossyOnlyForCompressedFormats() {
        XCTAssertTrue(ConversionFormat.jpeg.isLossy)
        XCTAssertTrue(ConversionFormat.heic.isLossy)
        XCTAssertTrue(ConversionFormat.avif.isLossy)
        XCTAssertTrue(ConversionFormat.webp.isLossy)
        XCTAssertTrue(ConversionFormat.jpeg2000.isLossy)
        XCTAssertFalse(ConversionFormat.png.isLossy)
        XCTAssertFalse(ConversionFormat.tiff.isLossy)
        XCTAssertFalse(ConversionFormat.gif.isLossy)
        XCTAssertFalse(ConversionFormat.ico.isLossy)
        XCTAssertFalse(ConversionFormat.bmp.isLossy)
        XCTAssertFalse(ConversionFormat.icns.isLossy)
    }

    func testWritableOnThisSystemCoversAtLeastPNGAndJPEG() {
        let writable = ConversionFormat.writableOnThisSystem
        XCTAssertTrue(writable.contains(.png))
        XCTAssertTrue(writable.contains(.jpeg))
        XCTAssertTrue(writable.contains(.tiff))
    }

    // MARK: - Inference

    func testInferredRecognizesAllSupportedExtensions() {
        let cases: [(String, ConversionFormat)] = [
            ("photo.png", .png),
            ("PHOTO.PNG", .png),
            ("photo.jpg", .jpeg),
            ("photo.jpeg", .jpeg),
            ("photo.JPG", .jpeg),
            ("photo.heic", .heic),
            ("photo.heif", .heic),
            ("photo.tif", .tiff),
            ("photo.tiff", .tiff),
            ("photo.gif", .gif),
            ("photo.avif", .avif),
            ("photo.webp", .webp),
            ("photo.ico", .ico),
            ("photo.bmp", .bmp),
            ("photo.icns", .icns),
            ("photo.jp2", .jpeg2000),
            ("photo.jpf", .jpeg2000),
            ("photo.jpx", .jpeg2000),
        ]
        for (name, expected) in cases {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            XCTAssertEqual(ConversionFormat.inferred(from: url), expected,
                           "\(name) should infer as \(expected)")
        }
    }

    func testInferredReturnsNilForUnsupportedExtensions() {
        XCTAssertNil(ConversionFormat.inferred(from: URL(fileURLWithPath: "/tmp/x.raw")))
        XCTAssertNil(ConversionFormat.inferred(from: URL(fileURLWithPath: "/tmp/x.txt")))
        XCTAssertNil(ConversionFormat.inferred(from: URL(fileURLWithPath: "/tmp/no_extension")))
    }

    func testAllCasesCoversEveryFormat() {
        // Locks the public surface — adding a new case requires a deliberate
        // update here, which forces a corresponding UI/test sweep.
        XCTAssertEqual(ConversionFormat.allCases.count, 11)
    }
}
