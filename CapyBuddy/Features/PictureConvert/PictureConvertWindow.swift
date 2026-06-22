import AppKit
import SwiftUI

/// Hosts the Picture Converter SwiftUI view in a free-floating panel.
/// Mirrors the shape of `ClipboardHistoryWindow`: an `NSPanel` that is
/// lazily built, kept alive across show/hide, and torn down in `stop()`.
@MainActor
final class PictureConvertWindow {

    private let queue: ConversionQueue
    private var panel: NSPanel?

    init(queue: ConversionQueue) {
        self.queue = queue
    }

    func toggle() {
        if let panel, panel.isVisible {
            close()
        } else {
            show()
        }
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
        p.title = String(localized: "Picture Converter")
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isFloatingPanel = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentViewController = NSHostingController(
            rootView: PictureConvertRootView(queue: queue)
        )
        return p
    }
}
