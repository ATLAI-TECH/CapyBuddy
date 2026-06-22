import AppKit
import SwiftUI

/// A small floating capsule that appears at the top-center of the active screen
/// while chord mode is active. Modelled after SpaceLauncher's blue indicator —
/// gives users a clear "you're in chord mode now" cue so the 200ms hold doesn't
/// feel like nothing's happening.
@MainActor
final class ChordHUDController {

    private var panel: NSPanel?

    func setVisible(_ visible: Bool) {
        if visible {
            ensurePanel().orderFront(nil)
        } else {
            panel?.orderOut(nil)
        }
    }

    deinit {
        // The panel is retained by AppKit's window list — if we get deallocated
        // while it's still on screen (e.g. feature stop() never ran), it would
        // leak visibly. Tear it down explicitly. AppKit teardown must hit the
        // main thread; deinit may not be main-isolated.
        if let panel = panel {
            DispatchQueue.main.async {
                panel.orderOut(nil)
                panel.close()
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let existing = panel {
            position(existing)
            return existing
        }
        let hosting = NSHostingController(rootView: ChordHUDView())
        hosting.view.layer?.backgroundColor = .clear
        let p = NSPanel(contentViewController: hosting)
        p.styleMask = [.borderless, .nonactivatingPanel]
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.setContentSize(NSSize(width: 140, height: 40))
        position(p)
        panel = p
        return p
    }

    private func position(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let size = window.frame.size
        let x = f.midX - size.width / 2
        let y = f.maxY - size.height - 16
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct ChordHUDView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "space")
                .font(.system(size: 16, weight: .semibold))
            Text("Chord")
                .font(.system(.callout, design: .rounded).weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.accentColor)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        )
        .padding(4)
    }
}
