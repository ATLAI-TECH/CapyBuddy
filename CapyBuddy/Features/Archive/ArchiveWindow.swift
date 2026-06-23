import AppKit
import SwiftUI

/// Free-floating panel hosting the archive view. Mirrors PictureConvertWindow.
@MainActor
final class ArchiveWindow {

    private let queue: ArchiveQueue
    private var panel: NSPanel?

    init(queue: ArchiveQueue) {
        self.queue = queue
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.title = String(localized: "Compressor")
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isFloatingPanel = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentViewController = NSHostingController(
            rootView: ArchiveRootView(queue: queue)
        )
        return p
    }
}
