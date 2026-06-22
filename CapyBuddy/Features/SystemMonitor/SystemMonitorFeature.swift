import AppKit
import Combine
import SwiftUI

@MainActor
final class SystemMonitorFeature: NSObject, Feature {

    let id = "systemMonitor"
    let displayName = String(localized: "System Monitor")
    let iconSystemName = "cpu"
    let summary = String(localized: "Adds a menu-bar status item showing live CPU, memory, and other system stats.")

    /// Off by default — System Monitor adds its own permanent status item
    /// to the menu bar, which surprises new users. Let them opt in from
    /// Settings instead of finding extra menu-bar real estate consumed.
    let defaultEnabled = false

    var isEnabled: Bool = false
    var showsInMenuBar: Bool = true

    private let sampler = HostStatsSampler()
    private(set) var lastStats: SystemStats?

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var timer: Timer?

    func start() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "CPU --"
        item.button?.font = .menuBarFont(ofSize: 0)

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        self.statusItem = item
        self.menu = menu

        update()
        restartTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        menu = nil
        lastStats = nil
    }

    /// SystemMonitor owns its own NSStatusItem, so it deliberately doesn't
    /// contribute to CapyBuddy's primary dropdown.
    func makeMenuBarItems() -> [NSMenuItem] { [] }

    func makeSettingsView() -> AnyView {
        AnyView(SystemMonitorSettingsView(feature: self))
    }

    /// Re-sample once and update the status item title. Cheap; called on the
    /// timer tick and whenever a setting toggle changes what we display.
    func update() {
        let stats = sampler.sample()
        lastStats = stats
        let title = HostStatsSampler.statusBarString(
            cpu: SystemMonitorPrefs.showCPU ? stats.cpu : nil,
            memory: SystemMonitorPrefs.showMEM ? stats.memory : nil,
            format: SystemMonitorPrefs.displayFormat
        )
        statusItem?.button?.title = title
    }

    func restartTimer() {
        timer?.invalidate()
        let interval = SystemMonitorPrefs.refreshInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }
}

extension SystemMonitorFeature: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let stats = lastStats {
            let cpuRow = NSMenuItem(
                title: String(
                    format: "CPU: %.0f%%   (User %.0f%% / Sys %.0f%%)",
                    stats.cpu.busyPercent,
                    stats.cpu.userPercent,
                    stats.cpu.systemPercent
                ),
                action: nil,
                keyEquivalent: ""
            )
            cpuRow.isEnabled = false
            menu.addItem(cpuRow)

            let memRow = NSMenuItem(
                title: "MEM: \(HostStatsSampler.formatBytes(stats.memory.usedBytes)) / \(HostStatsSampler.formatBytes(stats.memory.totalBytes))",
                action: nil,
                keyEquivalent: ""
            )
            memRow.isEnabled = false
            menu.addItem(memRow)

            let compRow = NSMenuItem(
                title: "Compressed: \(HostStatsSampler.formatBytes(stats.memory.compressedBytes))",
                action: nil,
                keyEquivalent: ""
            )
            compRow.isEnabled = false
            menu.addItem(compRow)

            menu.addItem(.separator())
        }

        let activity = NSMenuItem(
            title: String(localized: "Open Activity Monitor"),
            action: #selector(openActivityMonitor),
            keyEquivalent: ""
        )
        activity.target = self
        menu.addItem(activity)
    }

    @objc private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.open(url)
    }
}

enum SystemMonitorPrefs {
    private static let defaults = UserDefaults.standard
    private static let intervalKey = "systemMonitor.refreshInterval"
    private static let showCPUKey = "systemMonitor.showCPU"
    private static let showMEMKey = "systemMonitor.showMEM"
    static let displayFormatKey = "systemMonitor.displayFormat"

    static var refreshInterval: TimeInterval {
        let stored = defaults.double(forKey: intervalKey)
        return stored > 0 ? stored : 1.0
    }

    static var showCPU: Bool {
        if defaults.object(forKey: showCPUKey) == nil { return true }
        return defaults.bool(forKey: showCPUKey)
    }

    static var showMEM: Bool {
        if defaults.object(forKey: showMEMKey) == nil { return true }
        return defaults.bool(forKey: showMEMKey)
    }

    /// Menu-bar text format. Defaults to `.labeled` to preserve the
    /// historical "CPU 45% · MEM 8GB" rendering for upgrading users.
    static var displayFormat: MenuBarDisplayFormat {
        guard let raw = defaults.string(forKey: displayFormatKey),
              let fmt = MenuBarDisplayFormat(rawValue: raw) else {
            return .labeled
        }
        return fmt
    }
}
