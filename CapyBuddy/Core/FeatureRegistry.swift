import AppKit
import Combine

@MainActor
final class FeatureRegistry: ObservableObject {
    static let shared = FeatureRegistry()

    @Published private(set) var features: [any Feature] = []

    private let enabledKey = "CapyBuddy.enabledFeatures"
    private let menuVisibleKey = "CapyBuddy.menuVisibleFeatures"

    /// IDs of features whose `start()` we've called and not yet `stop()`ed.
    /// Tracking this lets `reconcile` be idempotent so we never double-start
    /// an already-running event tap when a feature's `isEnabled` changes.
    private var started: Set<String> = []

    private init() {}

    func register(_ feature: any Feature) {
        guard !features.contains(where: { $0.id == feature.id }) else { return }
        feature.isEnabled = persistedBool(forKey: enabledKey, id: feature.id, default: feature.defaultEnabled)
        feature.showsInMenuBar = persistedBool(forKey: menuVisibleKey, id: feature.id, default: true)
        features.append(feature)
        reconcile(feature)
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let feature = features.first(where: { $0.id == id }) else { return }
        guard feature.isEnabled != enabled else { return }
        feature.isEnabled = enabled
        reconcile(feature)
        persistBool(enabled, forKey: enabledKey, id: id)
        objectWillChange.send()
    }

    /// Drive `feature`'s actual running state to match what it *should* be:
    /// running iff it is enabled. Idempotent via `started`.
    private func reconcile(_ feature: any Feature) {
        let shouldRun = feature.isEnabled
        let isRunning = started.contains(feature.id)
        if shouldRun && !isRunning {
            feature.start()
            started.insert(feature.id)
        } else if !shouldRun && isRunning {
            feature.stop()
            started.remove(feature.id)
        }
    }

    /// Toggle whether the feature appears in CapyBuddy's dropdown. Doesn't
    /// touch `isEnabled` — a hidden feature keeps running (hotkeys, etc.)
    /// just without taking up a row in the menu.
    func setMenuVisible(_ visible: Bool, for id: String) {
        guard let feature = features.first(where: { $0.id == id }) else { return }
        guard feature.showsInMenuBar != visible else { return }
        feature.showsInMenuBar = visible
        persistBool(visible, forKey: menuVisibleKey, id: id)
        objectWillChange.send()
    }

    func feature(id: String) -> (any Feature)? {
        features.first(where: { $0.id == id })
    }

    func stopAll() {
        for feature in features where started.contains(feature.id) {
            feature.stop()
        }
        started.removeAll()
    }

    // MARK: - Persistence

    private func persistedBool(forKey key: String, id: String, default defaultValue: Bool) -> Bool {
        let map = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        return map[id] ?? defaultValue
    }

    private func persistBool(_ value: Bool, forKey key: String, id: String) {
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        map[id] = value
        UserDefaults.standard.set(map, forKey: key)
    }
}
