import Foundation
import Combine

@MainActor
final class BindingStore: ObservableObject {

    private struct Entry: Codable {
        var keyCode: UInt16
        var binding: AppBinding
    }

    @Published private(set) var bindings: [UInt16: AppBinding] = [:]

    // Stable across the SpaceBuddy → SpaceShortcut rename so existing users keep their bindings.
    private let storageKey = "CapyBuddy.SpaceBuddy.bindings.v1"

    init() {
        load()
    }

    struct Row: Identifiable, Hashable {
        let keyCode: UInt16
        let binding: AppBinding
        var id: UInt16 { keyCode }
    }

    var sortedBindings: [Row] {
        bindings
            .map { Row(keyCode: $0.key, binding: $0.value) }
            .sorted { $0.binding.displayName.lowercased() < $1.binding.displayName.lowercased() }
    }

    func binding(for keyCode: UInt16) -> AppBinding? {
        bindings[keyCode]
    }

    func setBinding(_ binding: AppBinding, forKeyCode keyCode: UInt16) {
        bindings[keyCode] = binding
        save()
    }

    func removeBinding(forKeyCode keyCode: UInt16) {
        bindings.removeValue(forKey: keyCode)
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        guard let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        bindings = Dictionary(uniqueKeysWithValues: decoded.map { ($0.keyCode, $0.binding) })
    }

    private func save() {
        let entries = bindings.map { Entry(keyCode: $0.key, binding: $0.value) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
