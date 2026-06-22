import XCTest
import AppKit
@testable import CapyBuddy

@MainActor
final class ClipboardMonitorTests: XCTestCase {

    /// Hand-rollable stand-in for `NSPasteboard` — tests can poke `changeCount`
    /// and the typed payloads without touching the real pasteboard.
    final class FakePasteboard: PasteboardReading {
        var changeCount: Int = 0
        var types: [NSPasteboard.PasteboardType]? = nil
        var stringPayload: String? = nil
        var dataPayload: [NSPasteboard.PasteboardType: Data] = [:]

        func string(forType type: NSPasteboard.PasteboardType) -> String? {
            type == .string ? stringPayload : nil
        }

        func data(forType type: NSPasteboard.PasteboardType) -> Data? {
            dataPayload[type]
        }

        /// Convenience: simulate a fresh paste.
        func setText(_ s: String) {
            changeCount += 1
            stringPayload = s
            types = [.string]
        }

        func setConcealed() {
            changeCount += 1
            types = [ClipboardMonitor.concealedType]
            stringPayload = "secret"
        }
    }

    func testPollWithNoChangeIsNoop() {
        let store = ClipboardStore(storageURL: nil)
        let pb = FakePasteboard()
        let monitor = ClipboardMonitor(
            store: store,
            pasteboard: pb,
            captureImages: { false },
            frontmostBundleID: { nil }
        )

        monitor.poll()
        monitor.poll()
        XCTAssertTrue(store.items.isEmpty)
    }

    func testPollAfterTextChangeAppendsItem() {
        let store = ClipboardStore(storageURL: nil)
        let pb = FakePasteboard()
        let monitor = ClipboardMonitor(
            store: store,
            pasteboard: pb,
            captureImages: { false },
            frontmostBundleID: { "com.apple.Safari" }
        )

        pb.setText("hello")
        monitor.poll()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].preview, "hello")
        XCTAssertEqual(store.items[0].sourceBundleID, "com.apple.Safari")
    }

    func testConcealedTypeIsSkipped() {
        let store = ClipboardStore(storageURL: nil)
        let pb = FakePasteboard()
        let monitor = ClipboardMonitor(
            store: store,
            pasteboard: pb,
            captureImages: { false },
            frontmostBundleID: { nil }
        )

        pb.setConcealed()
        monitor.poll()

        XCTAssertTrue(store.items.isEmpty)
    }

    func testConsecutiveSameTextDeduplicates() {
        let store = ClipboardStore(storageURL: nil)
        let pb = FakePasteboard()
        let monitor = ClipboardMonitor(
            store: store,
            pasteboard: pb,
            captureImages: { false },
            frontmostBundleID: { nil }
        )

        pb.setText("dup")
        monitor.poll()
        pb.setText("dup")           // changeCount bumped, but content identical
        monitor.poll()

        XCTAssertEqual(store.items.count, 1)
    }

    func testReadCurrentReturnsNilForEmptyPasteboard() {
        let store = ClipboardStore(storageURL: nil)
        let pb = FakePasteboard()
        let monitor = ClipboardMonitor(
            store: store,
            pasteboard: pb,
            captureImages: { false },
            frontmostBundleID: { nil }
        )

        XCTAssertNil(monitor.readCurrent())
    }

    func testReadCurrentDoesNotCaptureImageWhenDisabled() {
        let store = ClipboardStore(storageURL: nil)
        let pb = FakePasteboard()
        pb.changeCount += 1
        pb.types = [.png]
        pb.dataPayload[.png] = Data([0x89, 0x50, 0x4E, 0x47])  // PNG magic, body invalid but irrelevant

        let monitor = ClipboardMonitor(
            store: store,
            pasteboard: pb,
            imageDirectory: nil,
            captureImages: { false },
            frontmostBundleID: { nil }
        )

        monitor.poll()
        XCTAssertTrue(store.items.isEmpty)
    }
}
