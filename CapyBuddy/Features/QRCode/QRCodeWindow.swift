import AppKit
import SwiftUI

/// Free-floating panel hosting the QR generator. Mirrors the lifecycle
/// shape of `PictureConvertWindow` — lazy build, kept alive across show/
/// hide, torn down in `stop()`.
@MainActor
final class QRCodeWindow {

    private var panel: NSPanel?

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
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 740),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.title = String(localized: "QR Code")
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isFloatingPanel = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: QRCodeRootView())
        // Let the SwiftUI ideal size drive the panel — sizingOptions makes
        // the host re-request `intrinsicContentSize` from SwiftUI's frame
        // hints, so the panel opens at idealWidth/idealHeight instead of
        // collapsing to the bare minimum.
        host.sizingOptions = [.preferredContentSize]
        p.contentViewController = host
        return p
    }
}
