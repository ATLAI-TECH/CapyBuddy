import XCTest
@testable import CapyBuddy

final class ClipboardItemTests: XCTestCase {

    func testTextPreviewTrimsWhitespace() {
        let item = ClipboardItem(kind: .text("   hello world  \n"))
        XCTAssertEqual(item.preview, "hello world")
    }

    func testTextPreviewKeepsAllWhitespaceWhenContentIsBlank() {
        let item = ClipboardItem(kind: .text("    "))
        XCTAssertEqual(item.preview, "    ")
    }

    func testImagePreviewMentionsFilename() {
        let url = URL(fileURLWithPath: "/tmp/foo/bar.png")
        let item = ClipboardItem(kind: .image(url))
        XCTAssertEqual(item.preview, "[Image] bar.png")
    }

    func testFilesPreviewSingularVsPlural() {
        let one = ClipboardItem(kind: .files([URL(fileURLWithPath: "/a/b.txt")]))
        XCTAssertEqual(one.preview, "[File] b.txt")

        let many = ClipboardItem(kind: .files([
            URL(fileURLWithPath: "/a/b.txt"),
            URL(fileURLWithPath: "/a/c.txt"),
        ]))
        XCTAssertEqual(many.preview, "[2 files] b.txt")
    }

    func testSameContentIgnoresIDAndTimestamp() {
        let a = ClipboardItem(id: UUID(), kind: .text("hi"), timestamp: Date(timeIntervalSince1970: 1))
        let b = ClipboardItem(id: UUID(), kind: .text("hi"), timestamp: Date(timeIntervalSince1970: 999))
        XCTAssertTrue(ClipboardItem.sameContent(a, b))
    }

    func testSameContentDistinguishesDifferentText() {
        let a = ClipboardItem(kind: .text("hi"))
        let b = ClipboardItem(kind: .text("bye"))
        XCTAssertFalse(ClipboardItem.sameContent(a, b))
    }

    func testCodableRoundTrip() throws {
        let original = ClipboardItem(
            kind: .text("hello"),
            sourceBundleID: "com.apple.Safari",
            pinned: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.kind, original.kind)
        XCTAssertEqual(decoded.preview, original.preview)
        XCTAssertEqual(decoded.sourceBundleID, original.sourceBundleID)
        XCTAssertEqual(decoded.pinned, original.pinned)
    }
}
