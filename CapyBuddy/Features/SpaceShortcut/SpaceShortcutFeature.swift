import AppKit
import Carbon.HIToolbox
import Combine
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
    /// Long-press-Space backend. Always-on CGEventTap; only used in
    /// `.longPressSpace` mode.
    private let eventTap = EventTapManager()
    /// Carbon `RegisterEventHotKey` registration used in `.controlSpace` /
    /// `.optionSpace` modes. Recreated whenever the mode changes.
    private var leaderHotkey: HotkeyTap?
    /// Transient event tap activated only while the leader HUD is open.
    private let leaderCapture = LeaderChordCapture()
    private let hud = ChordHUDController()
    private var triggerModeCancellable: AnyCancellable?

    /// True iff a leader chord is currently being captured. Used by the
    /// settings view to distinguish "listener running" from "ready to listen".
    var isTapActive: Bool {
        switch bindingStore.triggerMode {
        case .longPressSpace:
            return eventTap.isActive
        case .controlSpace, .optionSpace:
            return leaderHotkey?.isActive ?? false
        }
    }

    func start() {
        eventTap.chordHandler = { [weak self] keyCode in
            self?.launchBinding(forKeyCode: keyCode) ?? false
        }
        eventTap.chordModeDidChange = { [weak self] active in
            self?.setChordHUDVisible(active)
        }

        leaderCapture.handler = { [weak self] keyCode in
            self?.launchBinding(forKeyCode: keyCode) ?? false
        }
        leaderCapture.onEnd = { [weak self] in
            self?.setChordHUDVisible(false)
        }

        applyTriggerMode(bindingStore.triggerMode)
        triggerModeCancellable = bindingStore.$triggerMode.sink { [weak self] mode in
            self?.applyTriggerMode(mode)
        }
    }

    func stop() {
        triggerModeCancellable?.cancel()
        triggerModeCancellable = nil
        tearDownAllBackends()
    }

    @discardableResult
    func restartTap() -> Bool {
        let mode = bindingStore.triggerMode
        tearDownAllBackends()
        applyTriggerMode(mode)
        return isTapActive
    }

    func makeSettingsView() -> AnyView {
        AnyView(SpaceShortcutSettingsView(
            store: bindingStore,
            isTapActive: { [weak self] in self?.isTapActive ?? false },
            restartTap: { [weak self] in self?.restartTap() ?? false }
        ))
    }

    // MARK: - Mode wiring

    private func applyTriggerMode(_ mode: SpaceShortcutTriggerMode) {
        tearDownAllBackends()

        switch mode {
        case .longPressSpace:
            if !PermissionChecker.isAccessibilityGranted(prompt: false) {
                _ = PermissionChecker.isAccessibilityGranted(prompt: true)
            }
            if !eventTap.start() {
                NSLog("[CapyBuddy] SpaceShortcut: failed to start event tap (Accessibility permission required).")
            } else {
                NSLog("[CapyBuddy] SpaceShortcut: long-press mode, holdThreshold=%.2fs", eventTap.holdThreshold)
            }

        case .controlSpace, .optionSpace:
            let flags: CGEventFlags = (mode == .controlSpace) ? .maskControl : .maskAlternate
            let config = HotkeyConfig(keyCode: UInt16(kVK_Space), flags: flags)
            let tap = HotkeyTap(config: config)
            tap.onTrigger = { [weak self] in self?.activateLeader() }
            if !tap.start() {
                NSLog("[CapyBuddy] SpaceShortcut: failed to register leader hotkey %@", config.displayString)
            } else {
                NSLog("[CapyBuddy] SpaceShortcut: leader hotkey %@ registered", config.displayString)
            }
            leaderHotkey = tap
        }
    }

    private func tearDownAllBackends() {
        eventTap.stop()
        leaderHotkey?.stop()
        leaderHotkey = nil
        leaderCapture.end()
        setChordHUDVisible(false)
    }

    private func activateLeader() {
        // Tapping the leader combo while a chord is already armed cancels it.
        if leaderCapture.isActive {
            leaderCapture.end()
            return
        }
        // Accessibility is required for the chord-key capture step. Defer the
        // prompt to first use so users who never trigger the chord don't see it.
        if !PermissionChecker.isAccessibilityGranted(prompt: false) {
            _ = PermissionChecker.isAccessibilityGranted(prompt: true)
            return
        }
        setChordHUDVisible(true)
        if !leaderCapture.begin() {
            NSLog("[CapyBuddy] SpaceShortcut: leader capture failed to start (Accessibility?)")
            setChordHUDVisible(false)
        }
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
