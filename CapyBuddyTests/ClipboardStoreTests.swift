import XCTest
@testable import CapyBuddy

@MainActor
final class ClipboardStoreTests: XCTestCase {

    private func makeStore(maxItems: Int = 100) -> ClipboardStore {
        // `nil` storage URL disables disk persistence — tests run in memory.
        ClipboardStore(maxItems: maxItems, storageURL: nil)
    }

    private func text(_ s: String, at: TimeInterval = Date().timeIntervalSince1970) -> ClipboardItem {
        ClipboardItem(kind: .text(s), timestamp: Date(timeIntervalSince1970: at))
    }

    func testAppendInsertsAtHead() {
        let store = makeStore()
        store.append(text("a"))
        store.append(text("b"))
        store.append(text("c"))

        XCTAssertEqual(store.items.count, 3)
        XCTAssertEqual(store.items[0].preview, "c")
        XCTAssertEqual(store.items[1].preview, "b")
        XCTAssertEqual(store.items[2].preview, "a")
    }

    func testAppendDedupesConsecutiveIdenticalText() {
        let store = makeStore()
        store.append(text("hello"))
        store.append(text("hello"))
        store.append(text("hello"))

        XCTAssertEqual(store.items.count, 1)
    }

    func testAppendBumpsExistingContentToTopInsteadOfDuplicating() {
        let store = makeStore()
        store.append(text("a"))
        store.append(text("b"))
        store.append(text("a"))   // re-copy of an older entry → bumped, not duplicated

        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items[0].preview, "a")
        XCTAssertEqual(store.items[1].preview, "b")
    }

    func testAppendBumpPreservesPinnedFlag() {
        let store = makeStore()
        store.append(text("a"))
        store.append(text("b"))
        store.togglePin(id: store.items.last!.id)   // pin "a"
        store.append(text("a"))                     // re-copy of pinned entry

        XCTAssertEqual(store.items.count, 2)
        let bumped = store.items.first(where: { $0.preview == "a" })!
        XCTAssertTrue(bumped.pinned)
    }

    func testTrimDropsOldestUnpinnedPastLimit() {
        let store = makeStore(maxItems: 3)
        for ch in ["a", "b", "c", "d", "e"] { store.append(text(ch)) }

        XCTAssertEqual(store.items.count, 3)
        XCTAssertEqual(store.items.map(\.preview), ["e", "d", "c"])
    }

    func testTrimKeepsAllPinnedItemsBeyondLimit() {
        let store = makeStore(maxItems: 2)
        store.append(text("a"))
        store.append(text("b"))
        store.togglePin(id: store.items.last!.id)   // pin "a"

        store.append(text("c"))
        store.append(text("d"))
        store.append(text("e"))

        let pinned = store.items.filter(\.pinned).map(\.preview)
        XCTAssertEqual(pinned, ["a"])

        let unpinned = store.items.filter { !$0.pinned }.map(\.preview)
        XCTAssertEqual(unpinned.count, 2)
        XCTAssertEqual(unpinned, ["e", "d"])
    }

    func testTogglePinFloatsItemToTop() {
        let store = makeStore()
        store.append(text("a"))
        store.append(text("b"))
        store.append(text("c"))

        let aID = store.items.first(where: { $0.preview == "a" })!.id
        store.togglePin(id: aID)

        XCTAssertEqual(store.items[0].preview, "a")
        XCTAssertTrue(store.items[0].pinned)
    }

    func testRemoveByID() {
        let store = makeStore()
        store.append(text("a"))
        store.append(text("b"))

        let bID = store.items.first(where: { $0.preview == "b" })!.id
        store.remove(id: bID)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].preview, "a")
    }

    func testClearUnpinnedKeepsPinned() {
        let store = makeStore()
        store.append(text("a"))
        store.append(text("b"))
        store.append(text("c"))
        store.togglePin(id: store.items.last!.id)   // pin "a"

        store.clearUnpinned()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].preview, "a")
        XCTAssertTrue(store.items[0].pinned)
    }

    func testSearchFiltersByPreview() {
        let store = makeStore()
        store.append(text("hello world"))
        store.append(text("goodbye world"))
        store.append(text("foo bar"))

        XCTAssertEqual(store.search("world").count, 2)
        XCTAssertEqual(store.search("foo").count, 1)
        XCTAssertEqual(store.search("missing").count, 0)
        XCTAssertEqual(store.search("").count, 3)
    }

    func testPersistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapyBuddyTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = ClipboardStore(maxItems: 10, storageURL: url)
        first.append(text("alpha"))
        first.append(text("beta"))

        let second = ClipboardStore(maxItems: 10, storageURL: url)
        XCTAssertEqual(second.items.count, 2)
        XCTAssertEqual(second.items.map(\.preview), ["beta", "alpha"])
    }
}
