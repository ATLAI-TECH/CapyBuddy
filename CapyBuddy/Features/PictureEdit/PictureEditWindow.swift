// Picture Editor disabled — feature is not mature yet.
#if false
import AppKit
import SwiftUI

/// Hosts the Picture Editor SwiftUI surface in a free-floating panel.
/// Mirrors `PictureConvertWindow` so the two editors feel like siblings.
@MainActor
final class PictureEditWindow {

    private let model: PictureEditModel
    private var panel: NSPanel?

    init(model: PictureEditModel) {
        self.model = model
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
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.title = String(localized: "Picture Editor")
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .visible
        p.isFloatingPanel = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        let m = model
        p.contentViewController = NSHostingController(
            rootView: PictureEditRootView(model: m)
        )
        return p
    }
}

#endif
