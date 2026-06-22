import Foundation
import Combine

@MainActor
final class ClipboardStore: ObservableObject {

    @Published private(set) var items: [ClipboardItem] = []

    /// Cap on unpinned history entries. Lowering it from Settings takes
    /// effect immediately — without the didSet, the store kept the old
    /// surplus (and its on-disk images) until the next copy happened to
    /// trigger a trim.
    var maxItems: Int {
        didSet {
            guard maxItems != oldValue else { return }
            trim()
            save()
        }
    }
    private let storageURL: URL?

    init(maxItems: Int = 100, storageURL: URL? = ClipboardStore.defaultStorageURL()) {
        self.maxItems = maxItems
        self.storageURL = storageURL
        load()
    }

    /// Insert at the head. If the topmost unpinned item already has the same
    /// content (consecutive duplicate), skip — this keeps "pasteboard ping-pong"
    /// from polluting history when an app re-writes the same value.
    func append(_ item: ClipboardItem) {
        if let topUnpinned = items.first(where: { !$0.pinned }),
           ClipboardItem.sameContent(topUnpinned, item) {
            return
        }
        // Re-copy of something already in history — most commonly the user
        // picking an entry from the history window, which writes it back to
        // the pasteboard and gets re-observed by the monitor. Bump the
        // existing row to the top instead of inserting a duplicate.
        if let idx = items.firstIndex(where: { ClipboardItem.sameContent($0, item) }) {
            let old = items.remove(at: idx)
            items.insert(
                ClipboardItem(kind: old.kind, sourceBundleID: item.sourceBundleID, pinned: old.pinned),
                at: 0
            )
            save()
            return
        }
        items.insert(item, at: 0)
        trim()
        save()
    }

    func remove(id: UUID) {
        if let removed = items.first(where: { $0.id == id }) {
            Self.deleteImageFile(for: removed)
        }
        items.removeAll { $0.id == id }
        save()
    }

    func togglePin(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].pinned.toggle()
        // Pinned items float to the top so they're easy to grab.
        items.sort { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            return lhs.timestamp > rhs.timestamp
        }
        save()
    }

    /// Clear unpinned history; pinned items survive.
    func clearUnpinned() {
        for item in items where !item.pinned {
            Self.deleteImageFile(for: item)
        }
        items.removeAll { !$0.pinned }
        save()
    }

    func search(_ query: String) -> [ClipboardItem] {
        guard !query.isEmpty else { return items }
        let lower = query.lowercased()
        return items.filter { $0.preview.lowercased().contains(lower) }
    }

    /// Drop oldest unpinned entries past `maxItems`. Pinned items don't count
    /// toward the cap.
    private func trim() {
        let pinned = items.filter(\.pinned)
        let unpinned = items.filter { !$0.pinned }
        guard unpinned.count > maxItems else { return }
        let kept = unpinned.prefix(maxItems)
        // Anything in `unpinned` past the cap is being dropped; reclaim
        // its on-disk image (if any) so the App Support folder doesn't
        // grow unbounded.
        for evicted in unpinned.dropFirst(maxItems) {
            Self.deleteImageFile(for: evicted)
        }
        items = pinned + kept
        items.sort { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            return lhs.timestamp > rhs.timestamp
        }
    }

    private static func deleteImageFile(for item: ClipboardItem) {
        if case .image(let url) = item.kind {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let url = storageURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else {
            return
        }
        items = decoded
    }

    private func save() {
        guard let url = storageURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[CapyBuddy] Clipboard save failed: \(error)")
        }
    }

    nonisolated static func defaultStorageURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return support
            .appendingPathComponent("CapyBuddy", isDirectory: true)
            .appendingPathComponent("clipboard-history.json")
    }
}
