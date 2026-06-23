import Foundation
import Carbon.HIToolbox
import CoreGraphics
import Combine

/// `HotkeyConfig` persistence for the Clipboard feature, kept separate from
/// `HotkeyConfigStore` (which is Screenshot-specific) so each feature can
/// own its own user-defaults key without cross-talk.
@MainActor
final class ClipboardHotkeyStore: ObservableObject {

    static let shared = ClipboardHotkeyStore()
    private let key = "CapyBuddy.Clipboard.hotkey"

    @Published private(set) var current: HotkeyConfig

    static let defaultConfig: HotkeyConfig = HotkeyConfig(
        keyCode: UInt16(kVK_ANSI_V),
        flags: [.maskCommand, .maskShift]
    )

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(HotkeyConfig.self, from: data) {
            self.current = decoded
        } else {
            self.current = Self.defaultConfig
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
