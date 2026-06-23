import AppKit
import Foundation

/// Minimal subset of `NSPasteboard` we read. Pulling it into a protocol lets
/// tests drive the monitor without touching the system pasteboard.
@MainActor
protocol PasteboardReading: AnyObject {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType]? { get }
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
}

extension NSPasteboard: PasteboardReading {}

@MainActor
final class ClipboardMonitor {

    /// Pasteboard type marker used by 1Password / Bitwarden / Apple Keychain
    /// to opt out of clipboard managers. We respect it.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let pasteboard: PasteboardReading
    private let store: ClipboardStore
    private let imageDirectory: URL?
    private let interval: TimeInterval
    private let captureImages: () -> Bool
    private let frontmostBundleID: () -> String?
    private var lastChangeCount: Int
    private var timer: Timer?

    init(
        store: ClipboardStore,
        pasteboard: PasteboardReading = NSPasteboard.general,
        interval: TimeInterval = 0.5,
        imageDirectory: URL? = ClipboardMonitor.defaultImageDirectory(),
        captureImages: @escaping () -> Bool = { true },
        frontmostBundleID: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.interval = interval
        self.imageDirectory = imageDirectory
        self.captureImages = captureImages
        self.frontmostBundleID = frontmostBundleID
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Single-shot pasteboard check. Exposed `internal` so tests can drive it
    /// deterministically rather than waiting on the timer.
    func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        guard let item = readCurrent() else { return }
        store.append(item)
    }

    func readCurrent() -> ClipboardItem? {
        if pasteboard.types?.contains(Self.concealedType) == true {
            return nil
        }
        let bundleID = frontmostBundleID()

        if let str = pasteboard.string(forType: .string), !str.isEmpty {
            return ClipboardItem(kind: .text(str), sourceBundleID: bundleID)
        }
        if captureImages(), let url = readImage() {
            return ClipboardItem(kind: .image(url), sourceBundleID: bundleID)
        }
        return nil
    }

    private func readImage() -> URL? {
        guard let directory = imageDirectory else { return nil }

        // Prefer PNG when the source put it on the pasteboard directly —
        // saves a re-encode round-trip.
        if let pngData = pasteboard.data(forType: .png) {
            return writePNG(pngData, to: directory)
        }

        // Many apps (Preview, Safari/Chrome "Copy Image", screenshot
        // tools) advertise TIFF only. Re-encode to PNG so the on-disk
        // representation is consistent and re-pastes work as PNG.
        if let tiffData = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiffData),
           let pngData = rep.representation(using: .png, properties: [:]) {
            return writePNG(pngData, to: directory)
        }

        return nil
    }

    private func writePNG(_ data: Data, to directory: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent("\(UUID().uuidString).png")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    nonisolated static func defaultImageDirectory() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return support
            .appendingPathComponent("CapyBuddy", isDirectory: true)
            .appendingPathComponent("clipboard-images", isDirectory: true)
    }
}
