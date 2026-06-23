import Foundation
import Combine

/// Counts how many times each Space-chord binding has launched its app.
/// Keyed by the binding's bundle path so renaming the display name doesn't
/// reset the counter, and so two different bindings to the same app share a
/// count (which is what users intuitively expect).
@MainActor
final class SpaceShortcutStats: ObservableObject {

    static let shared = SpaceShortcutStats()

    @Published private(set) var counts: [String: Int] = [:]

    private let storageKey = "CapyBuddy.SpaceShortcut.launchCounts.v1"

    init() {
        if let dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Int] {
            counts = dict
        }
    }

    func recordLaunch(_ binding: AppBinding) {
        counts[binding.bundlePath, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: storageKey)
    }

    func count(for binding: AppBinding) -> Int {
        counts[binding.bundlePath] ?? 0
    }

    var totalLaunches: Int {
        counts.values.reduce(0, +)
    }

    func reset() {
        counts = [:]
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
