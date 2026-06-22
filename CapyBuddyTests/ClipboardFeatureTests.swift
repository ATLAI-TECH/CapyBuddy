import XCTest
import AppKit
@testable import CapyBuddy

@MainActor
final class ClipboardFeatureTests: XCTestCase {

    func testShortPreviewLeavesShortStringsUntouched() {
        XCTAssertEqual(ClipboardFeature.shortPreview("hello"), "hello")
    }

    func testShortPreviewReplacesNewlinesWithSpaces() {
        XCTAssertEqual(
            ClipboardFeature.shortPreview("line1\nline2"),
            "line1 line2"
        )
    }

    func testShortPreviewTruncatesWithEllipsis() {
        // 800 chars of "x" easily exceeds the default 260-pt menu width,
        // so the result must be truncated and end in "…".
        let long = String(repeating: "x", count: 800)
        let result = ClipboardFeature.shortPreview(long)
        XCTAssertTrue(result.hasSuffix("…"))
        XCTAssertLessThan(result.count, long.count)
    }

    func testShortPreviewKeepsCJKWidthBounded() {
        // Wide CJK characters previously stretched the menu because we
        // truncated by char count. The width-based path keeps the rendered
        // size at or below the budget for both scripts.
        let cjk = String(repeating: "字", count: 200)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        let preview = ClipboardFeature.shortPreview(cjk, maxWidth: 260)
        let width = (preview as NSString).size(withAttributes: attrs).width
        XCTAssertLessThanOrEqual(width, 260)
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    func testCopyTextItemWritesToPasteboard() {
        let feature = ClipboardFeature()
        let item = ClipboardItem(kind: .text("hi from test"))
        feature.copyToPasteboard(item)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hi from test")
    }

    func testMakeMenuBarItemsHasHeaderAndFooterWhenEmpty() {
        let feature = ClipboardFeature(store: ClipboardStore(storageURL: nil))
        let items = feature.makeMenuBarItems()
        // header + sep + empty placeholder + sep + footer = 5
        XCTAssertEqual(items.count, 5)
        XCTAssertNotNil(items[0].view, "header is a SwiftUI hosting view")
        XCTAssertTrue(items[1].isSeparatorItem)
        XCTAssertNotNil(items[2].view, "empty placeholder is a SwiftUI hosting view")
        XCTAssertTrue(items[3].isSeparatorItem)
        XCTAssertNotNil(items[4].view, "footer is a SwiftUI hosting view")
    }

    func testMakeMenuBarItemsRendersOneRowPerRecent() {
        let feature = ClipboardFeature(store: ClipboardStore(storageURL: nil))
        feature.store.append(ClipboardItem(kind: .text("alpha")))
        feature.store.append(ClipboardItem(kind: .text("beta")))

        let items = feature.makeMenuBarItems()
        // header + sep + 2 rows + sep + footer = 6
        XCTAssertEqual(items.count, 6)
        XCTAssertNotNil(items[0].view)
        XCTAssertTrue(items[1].isSeparatorItem)
        XCTAssertNotNil(items[2].view)
        XCTAssertNotNil(items[3].view)
        XCTAssertTrue(items[4].isSeparatorItem)
        XCTAssertNotNil(items[5].view)
    }
}
