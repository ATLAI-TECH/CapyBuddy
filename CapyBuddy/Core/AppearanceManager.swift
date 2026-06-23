import AppKit
import SwiftUI

/// User-selectable appearance override (Settings → General → Appearance).
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .light:  return String(localized: "Light")
        case .dark:   return String(localized: "Dark")
        }
    }

    /// nil means "follow the system" — assigning nil to `NSApp.appearance`
    /// restores per-window inheritance from the system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

/// Owns the persisted theme choice and pushes it onto `NSApp.appearance`,
/// which cascades to every window, panel, and menu the app creates.
@MainActor
final class AppearanceManager: ObservableObject {

    static let shared = AppearanceManager()
    private static let defaultsKey = "app.appearanceTheme"

    @Published var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Self.defaultsKey)
            apply()
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
        theme = AppTheme(rawValue: raw) ?? .system
    }

    /// Called once at launch (and again on every change via `didSet`).
    func apply() {
        NSApp.appearance = theme.nsAppearance
    }
}
