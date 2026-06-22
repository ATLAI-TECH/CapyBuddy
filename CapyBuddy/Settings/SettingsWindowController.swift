import AppKit
import SwiftUI

extension Notification.Name {
    /// Broadcast by AppDelegate when a per-feature "Settings…" item is
    /// clicked while the Settings window is already open. SettingsView
    /// listens for this and switches its sidebar selection.
    static let capyBuddySettingsSelect = Notification.Name("CapyBuddy.Settings.SelectFeature")
}

@MainActor
final class SettingsWindowController: NSWindowController {

    convenience init(initialSelection: String? = nil) {
        let hosting = NSHostingController(rootView: SettingsView(initialSelection: initialSelection))
        let window = NSWindow(contentViewController: hosting)
        window.title = "CapyBuddy Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 480))
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }
}
