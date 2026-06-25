import AppKit
import SwiftUI

/// Lightweight video editor for Pro: play a clip, trim it, optionally crop
/// to a common aspect ratio, change speed or mute, then export. Designed as
/// the natural follow-up to a screen recording — when a recording finishes
/// it can pop straight into here (see `VideoEditorPrefs.openAfterRecording`).
@MainActor
final class VideoEditorFeature: NSObject, Feature {

    let id = "videoEditor"
    let displayName = String(localized: "Video Editor")
    let iconSystemName = "film"
    let summary = String(localized: "Play, trim, crop, mute or re-speed a video clip and export it - handy right after a screen recording.")

    var isEnabled: Bool = false
    var showsInMenuBar: Bool = true
    /// Off by default: it's a heavier, opt-in tool that also writes files.
    var defaultEnabled: Bool { false }

    /// The dropdown submenu already has "Open Video…"; the top-level Enabled
    /// toggle is driven from Settings → General (mirrors Screen Recording).
    var hasEnabledToggleInMenu: Bool { false }

    let window = VideoEditorWindow()

    /// Weakly tracked so the Recording feature's "open editor after a
    /// recording" hook can reach the live instance without a hard
    /// dependency. Nil whenever the feature is disabled (`stop()` clears it).
    private(set) static weak var active: VideoEditorFeature?

    func start() {
        VideoEditorFeature.active = self
    }

    func stop() {
        if VideoEditorFeature.active === self { VideoEditorFeature.active = nil }
        window.tearDown()
    }

    func makeMenuBarItems() -> [NSMenuItem] {
        let open = NSMenuItem(title: String(localized: "Open Video…"),
                              action: #selector(openVideo), keyEquivalent: "")
        open.target = self
        open.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        return [open]
    }

    func makeSettingsView() -> AnyView {
        AnyView(VideoEditorSettingsView())
    }

    @objc private func openVideo() {
        guard let url = VideoEditorOpenPanel.chooseURL() else { return }
        window.show(with: url)
    }

    /// Entry point used by `RecordingManager` once a recording is saved.
    /// No-op when the feature is disabled (no live instance).
    static func openAfterRecording(url: URL) {
        guard VideoEditorPrefs.openAfterRecording else { return }
        active?.window.show(with: url)
    }
}

// MARK: - Editor window

/// Owns the editor's `NSWindow` + view model. Mirrors the lazy-build,
/// kept-alive-across-show/hide shape of `QRCodeWindow`.
@MainActor
final class VideoEditorWindow: NSObject, NSWindowDelegate {

    let model = VideoEditorModel()
    private var window: NSWindow?

    func show(with url: URL?) {
        let win = window ?? makeWindow()
        window = win
        if let url { model.load(url: url) }
        if !win.isVisible { win.center() }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func tearDown() {
        model.cleanup()
        window?.orderOut(nil)
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = String(localized: "Video Editor")
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentViewController = NSHostingController(rootView: VideoEditorView(model: model))
        win.setContentSize(NSSize(width: 880, height: 600))
        win.contentMinSize = NSSize(width: 640, height: 460)
        win.center()
        return win
    }

    // Pause playback when the window is dismissed — but keep the loaded clip
    // around so re-opening the window resumes where the user left off.
    func windowWillClose(_ notification: Notification) {
        model.player.pause()
    }
}
