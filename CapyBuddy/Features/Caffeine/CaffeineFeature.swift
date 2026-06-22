import AppKit
import Combine
import SwiftUI

@MainActor
final class CaffeineFeature: NSObject, Feature {

    let id = "caffeine"
    let displayName = String(localized: "Keep Awake")
    let summary = String(localized: "Prevents your Mac from sleeping or dimming the display for a chosen duration.")

    var iconSystemName: String {
        controller?.isActive == true ? "cup.and.saucer.fill" : "cup.and.saucer"
    }

    /// Surface the live countdown directly on the top-level menu row so
    /// the user sees "how much time is left" at a glance, without
    /// drilling into the submenu.
    var menuTitle: String {
        guard let controller, controller.isActive else { return displayName }
        if let remaining = controller.remainingTime {
            return "\(displayName) — \(Self.formatRemaining(remaining))"
        }
        return "\(displayName) — On"
    }

    /// Caffeine's submenu IS the on/off mechanism — pick a duration to
    /// activate, click Off (or wait) to deactivate. A separate "Enabled"
    /// toggle alongside those choices was redundant and confusing.
    var hasEnabledToggleInMenu: Bool { false }

    var isEnabled: Bool = false
    var showsInMenuBar: Bool = true

    private(set) var controller: CaffeineController?
    private var stateObservation: AnyCancellable?
    private let holderFactory: @MainActor () -> PowerAssertionHolder

    /// Held weakly so that when `MenuBarManager` ticks us each second, we
    /// can update the live "Remaining: m:ss" row in place. NSMenu doesn't
    /// re-poll item titles during a tracking session, so without this
    /// in-place mutation the countdown visibly freezes while the menu
    /// stays open.
    private weak var remainingMenuItem: NSMenuItem?

    init(holderFactory: @escaping @MainActor () -> PowerAssertionHolder = { IOKitPowerAssertionHolder() }) {
        self.holderFactory = holderFactory
        super.init()
    }

    func start() {
        guard controller == nil else { return }
        // Always block display sleep when we hold a power assertion. A
        // "Keep Awake" tool that lets the screen turn off is the most
        // common bug report we get; making this configurable created more
        // confusion than flexibility, especially because UserDefaults
        // could pin a stale `false` from prior versions and there was no
        // obvious way for the user to fix it.
        let controller = CaffeineController(
            holder: holderFactory(),
            preventDisplaySleep: true
        )
        self.controller = controller

        if CaffeinePrefs.activateOnLaunch {
            controller.activate(duration: Self.durationOrNil(CaffeinePrefs.defaultDuration))
        }
    }

    func stop() {
        controller?.deactivate()
        controller = nil
        stateObservation?.cancel()
        stateObservation = nil
    }

    func makeMenuBarItems() -> [NSMenuItem] {
        guard let controller else { return [] }

        // Inserted into the Caffeine feature's submenu by `MenuBarManager`.
        // Two distinct shapes:
        //   • inactive — list duration choices so the user can pick one
        //   • active   — show countdown / status + Turn Off only; the
        //     active title on the top-level row already shows the time, so
        //     re-listing every duration just clutters the menu (and the
        //     user said as much: "应该是显示倒计时就可以").
        if controller.isActive {
            return activeStateItems(controller: controller)
        } else {
            return durationItems()
        }
    }

    private func durationItems() -> [NSMenuItem] {
        let options: [(String, TimeInterval?, String)] = [
            ("15 minutes",   15 * 60,         "15.circle"),
            ("30 minutes",   30 * 60,         "30.circle"),
            ("1 hour",       60 * 60,         "1.circle"),
            ("2 hours",      2 * 60 * 60,     "2.circle"),
            ("Indefinitely", nil,             "infinity.circle"),
        ]
        return options.map { title, secs, symbol in
            let item = NSMenuItem(
                title: title,
                action: #selector(activateForDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = secs.map { NSNumber(value: $0) }
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return item
        }
    }

    private func activeStateItems(controller: CaffeineController) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let statusTitle: String
        if let remaining = controller.remainingTime {
            statusTitle = "Remaining: \(Self.formatRemaining(remaining))"
        } else {
            statusTitle = "On — Indefinitely"
        }
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        items.append(status)
        remainingMenuItem = status

        items.append(.separator())

        let off = NSMenuItem(
            title: "Turn Off",
            action: #selector(toggleAction),
            keyEquivalent: ""
        )
        off.target = self
        off.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
        items.append(off)

        return items
    }

    func makeSettingsView() -> AnyView {
        AnyView(CaffeineSettingsView(feature: self))
    }

    func refreshMenuBarItems() {
        guard let controller, controller.isActive,
              let item = remainingMenuItem else { return }
        if let remaining = controller.remainingTime {
            item.title = "Remaining: \(Self.formatRemaining(remaining))"
        } else {
            item.title = "On — Indefinitely"
        }
    }

    // MARK: - Actions
    //
    // Marked `@objc` (for `NSMenuItem.action`) and `internal` (for tests).

    @objc func toggleAction() {
        guard let controller else { return }
        if controller.isActive {
            controller.deactivate()
        } else {
            controller.activate(duration: Self.durationOrNil(CaffeinePrefs.defaultDuration))
        }
    }

    @objc func activateForDuration(_ sender: NSMenuItem) {
        guard let controller else { return }
        let secs = (sender.representedObject as? NSNumber)?.doubleValue
        controller.activate(duration: secs)
    }

    // MARK: - Helpers

    /// `0` in user-defaults means "indefinite"; map it to `nil`.
    static func durationOrNil(_ stored: TimeInterval) -> TimeInterval? {
        stored > 0 ? stored : nil
    }

    static func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

enum CaffeinePrefs {
    private static let defaults = UserDefaults.standard
    private static let durationKey = "caffeine.defaultDuration"
    private static let displaySleepKey = "caffeine.preventDisplaySleep"
    private static let activateOnLaunchKey = "caffeine.activateOnLaunch"

    /// Stored in seconds. `0` ⇒ indefinite.
    static var defaultDuration: TimeInterval {
        get { defaults.double(forKey: durationKey) }
        set { defaults.set(newValue, forKey: durationKey) }
    }
    /// Defaults `true`: a "Keep Awake" tool that lets the display sleep
    /// surprises every user who's ever tried it. The IOKit assertion type
    /// `PreventUserIdleSystemSleep` only blocks system sleep, not display
    /// sleep — so without this on, the screen still goes dark on the
    /// system's normal display timeout. Use an explicit absent-key check
    /// since `defaults.bool(forKey:)` returns `false` when missing.
    static var preventDisplaySleep: Bool {
        get {
            if defaults.object(forKey: displaySleepKey) == nil { return true }
            return defaults.bool(forKey: displaySleepKey)
        }
        set { defaults.set(newValue, forKey: displaySleepKey) }
    }
    static var activateOnLaunch: Bool {
        get { defaults.bool(forKey: activateOnLaunchKey) }
        set { defaults.set(newValue, forKey: activateOnLaunchKey) }
    }
}
