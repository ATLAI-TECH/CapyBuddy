import AppKit
import SwiftUI

@MainActor
final class SpaceShortcutFeature: Feature {
    // Stable across the SpaceBuddy → SpaceShortcut rename so the persisted enabled flag survives.
    let id = "spacebuddy"
    let displayName = String(localized: "Space Shortcut")
    let iconSystemName = "space"
    let summary = String(localized: "Hold Space and tap a key to instantly launch or focus your most-used apps.")
    let requiresAccessibility = true

    var isEnabled: Bool = false
    var showsInMenuBar: Bool = true

    let bindingStore = BindingStore()
    let state = SpaceShortcutState()
    /// Long-press-Space backend. Always-on CGEventTap. Created only once
    /// Accessibility is granted (creating the tap is itself what triggers the
    /// system prompt).
    private let eventTap = EventTapManager()
    private let hud = ChordHUDController()
    /// Watches for the app regaining focus so a tap that was dormant
    /// (Accessibility not yet granted) comes alive the moment the user grants
    /// it in System Settings and switches back — no relaunch.
    private var activationObserver: NSObjectProtocol?

    /// True iff the keyboard event tap is currently installed.
    var isTapActive: Bool { eventTap.isActive }

    func start() {
        eventTap.chordHandler = { [weak self] keyCode in
            self?.launchBinding(forKeyCode: keyCode) ?? false
        }
        eventTap.chordModeDidChange = { [weak self] active in
            self?.setChordHUDVisible(active)
        }

        startTapIfPermitted()

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.isTapActive,
                      PermissionChecker.isAccessibilityGranted(prompt: false) else { return }
                _ = self.restartTap()
            }
        }
    }

    func stop() {
        if let observer = activationObserver {
            NotificationCenter.default.removeObserver(observer)
            activationObserver = nil
        }
        tearDown()
    }

    @discardableResult
    func restartTap() -> Bool {
        tearDown()
        startTapIfPermitted()
        return isTapActive
    }

    func makeSettingsView() -> AnyView {
        AnyView(SpaceShortcutSettingsView(
            store: bindingStore,
            isTapActive: { [weak self] in self?.isTapActive ?? false },
            restartTap: { [weak self] in self?.restartTap() ?? false }
        ))
    }

    // MARK: - Tap lifecycle

    private func startTapIfPermitted() {
        // IMPORTANT: creating the CGEventTap (inside `eventTap.start()`) is
        // itself what makes macOS pop the Accessibility prompt when we're not
        // yet trusted — there's no separate "ask" call to suppress. So to keep
        // launch prompt-free we must NOT create the tap until Accessibility is
        // already granted. Until then the feature stays dormant; the
        // onboarding / Settings permission card guides the user, and
        // `restartTap()` (Settings "Re-check" or the next launch) brings the
        // tap up the moment it's granted.
        guard PermissionChecker.isAccessibilityGranted(prompt: false) else {
            NSLog("[CapyBuddy] SpaceShortcut: dormant - Accessibility not granted yet (no prompt at launch).")
            return
        }
        if !eventTap.start() {
            NSLog("[CapyBuddy] SpaceShortcut: failed to start event tap (Accessibility permission required).")
        } else {
            NSLog("[CapyBuddy] SpaceShortcut: long-press mode, holdThreshold=%.2fs", eventTap.holdThreshold)
        }
    }

    private func tearDown() {
        eventTap.stop()
        setChordHUDVisible(false)
    }

    private func launchBinding(forKeyCode keyCode: UInt16) -> Bool {
        guard let binding = bindingStore.binding(for: keyCode) else {
            NSLog("[CapyBuddy] SpaceShortcut: chord keyCode=%d has no binding", Int(keyCode))
            return false
        }
        NSLog("[CapyBuddy] SpaceShortcut: launching %@ for keyCode=%d", binding.displayName, Int(keyCode))
        AppLauncher.launchOrActivate(binding)
        SpaceShortcutStats.shared.recordLaunch(binding)
        return true
    }

    private func setChordHUDVisible(_ visible: Bool) {
        state.chordModeActive = visible
        hud.setVisible(visible)
    }
}
