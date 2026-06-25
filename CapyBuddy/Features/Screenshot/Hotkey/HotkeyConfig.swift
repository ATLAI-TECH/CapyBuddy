import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// A keyCode + modifier-flags combination, registered with Carbon's
/// `RegisterEventHotKey`. Persisted in UserDefaults so the user's chosen
/// shortcut survives app restarts.
struct HotkeyConfig: Codable, Equatable {

    /// Carbon virtual key code (e.g. kVK_ANSI_A = 0).
    let keyCode: UInt16

    /// Subset of CGEventFlags raw value — only the bits in `interestingMask`.
    let modifiersRaw: UInt64

    /// Carbon hotkeys only honor these four modifier bits. The `fn` bit is
    /// intentionally excluded — Carbon's `RegisterEventHotKey` doesn't
    /// recognize it, so storing it would just create dead shortcuts.
    static let interestingMask: UInt64 =
        UInt64(CGEventFlags.maskShift.rawValue) |
        UInt64(CGEventFlags.maskControl.rawValue) |
        UInt64(CGEventFlags.maskAlternate.rawValue) |
        UInt64(CGEventFlags.maskCommand.rawValue)

    init(keyCode: UInt16, flags: CGEventFlags) {
        self.keyCode = keyCode
        self.modifiersRaw = flags.rawValue & Self.interestingMask
    }

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiersRaw) }

    func matches(keyCode incoming: UInt16, flags incomingFlags: CGEventFlags) -> Bool {
        guard self.keyCode == incoming else { return false }
        return (incomingFlags.rawValue & Self.interestingMask) == self.modifiersRaw
    }

    var displayString: String {
        let f = flags
        var symbols: [String] = []
        if f.contains(.maskControl)   { symbols.append("⌃") }
        if f.contains(.maskAlternate) { symbols.append("⌥") }
        if f.contains(.maskShift)     { symbols.append("⇧") }
        if f.contains(.maskCommand)   { symbols.append("⌘") }
        let keyName = KeyCombo.keyName(forKeyCode: keyCode)
        return symbols.joined() + keyName
    }

    // MARK: - Presets

    struct Preset: Identifiable, Hashable {
        let label: String
        let detail: String
        let config: HotkeyConfig
        var id: String { label }
        static func == (lhs: Preset, rhs: Preset) -> Bool { lhs.label == rhs.label }
        func hash(into hasher: inout Hasher) { hasher.combine(label) }
    }

    static let presets: [Preset] = [
        Preset(
            label: "⌃1",
            detail: "Default - single-modifier, no macOS system conflict.",
            config: HotkeyConfig(keyCode: UInt16(kVK_ANSI_1), flags: [.maskControl])
        ),
        Preset(
            label: "⇧⌘A",
            detail: "CleanShot X / Skitch style.",
            config: HotkeyConfig(keyCode: UInt16(kVK_ANSI_A), flags: [.maskShift, .maskCommand])
        ),
        Preset(
            label: "⌃⌥A",
            detail: "Shottr style.",
            config: HotkeyConfig(keyCode: UInt16(kVK_ANSI_A), flags: [.maskControl, .maskAlternate])
        ),
    ]

    static let `default`: HotkeyConfig = presets[0].config
}

@MainActor
final class HotkeyConfigStore: ObservableObject {
    static let shared = HotkeyConfigStore()
    private let key = "CapyBuddy.Screenshot.hotkey"

    @Published private(set) var current: HotkeyConfig

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(HotkeyConfig.self, from: data),
           decoded.modifiersRaw != 0 {
            // Reject legacy fn-only bindings (modifiersRaw becomes 0 after
            // masking) so the user gets a working default instead of a
            // silently dead hotkey.
            self.current = decoded
        } else {
            self.current = .default
        }
    }

    func update(_ config: HotkeyConfig) {
        guard config != current else { return }
        current = config
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
