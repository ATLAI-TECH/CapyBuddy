import AppKit

/// A directory the app may write into right now. When the grant came from a
/// resolved security-scoped bookmark, this token keeps the scope open —
/// retain it until the write finishes; the scope closes on deinit.
final class WritableDirectory {
    let url: URL
    private let isSecurityScoped: Bool

    init(url: URL, isSecurityScoped: Bool) {
        self.url = url
        self.isSecurityScoped = isSecurityScoped
    }

    deinit {
        if isSecurityScoped {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

/// Sandbox-aware picker for "where do converted/compressed files land".
///
/// `com.apple.security.files.user-selected.read-write` only covers the items
/// the user actually dropped or picked — NOT siblings in the same folder.
/// Writing `photo-converted.png` next to `photo.png` therefore fails for a
/// plain file drop. This resolver keeps the write-next-to-source behaviour
/// whenever the sandbox really allows it (folder drops, container paths) and
/// otherwise asks the user to pick an output folder once, persisting the
/// grant as a security-scoped bookmark for future launches.
@MainActor
final class OutputDirectoryResolver {

    private let bookmarkDefaultsKey: String
    private let panelMessage: String

    /// Folder picked earlier in this session, so a multi-file batch only
    /// prompts once.
    private var sessionDirectory: WritableDirectory?
    private var promptDeclined = false

    init(bookmarkDefaultsKey: String, panelMessage: String) {
        self.bookmarkDefaultsKey = bookmarkDefaultsKey
        self.panelMessage = panelMessage
    }

    /// Directory for outputs derived from `input`, or nil if no writable
    /// location is available (the user cancelled the folder prompt).
    func directory(for input: URL) -> WritableDirectory? {
        let sourceDir = input.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: sourceDir.path) {
            return WritableDirectory(url: sourceDir, isSecurityScoped: false)
        }
        if let cached = sessionDirectory { return cached }
        if let bookmarked = resolveBookmark() {
            sessionDirectory = bookmarked
            return bookmarked
        }
        if promptDeclined { return nil }
        if let picked = promptForDirectory(startingAt: sourceDir) {
            sessionDirectory = picked
            return picked
        }
        promptDeclined = true
        return nil
    }

    /// Lets the UI re-offer the folder prompt after the user cancelled it
    /// once (cancelling shouldn't permanently break the feature).
    func resetDeclined() {
        promptDeclined = false
    }

    // MARK: - Bookmark plumbing

    private func resolveBookmark() -> WritableDirectory? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkDefaultsKey) else {
            return nil
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            UserDefaults.standard.removeObject(forKey: bookmarkDefaultsKey)
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            url.stopAccessingSecurityScopedResource()
            UserDefaults.standard.removeObject(forKey: bookmarkDefaultsKey)
            return nil
        }
        if stale {
            saveBookmark(for: url)
        }
        return WritableDirectory(url: url, isSecurityScoped: true)
    }

    private func promptForDirectory(startingAt suggestion: URL) -> WritableDirectory? {
        let panel = NSOpenPanel()
        panel.message = panelMessage
        panel.prompt = String(localized: "Use This Folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = suggestion
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        saveBookmark(for: url)
        // Panel grants are live for the rest of this session without an
        // explicit start/stop; the bookmark covers future launches.
        return WritableDirectory(url: url, isSecurityScoped: false)
    }

    private func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: bookmarkDefaultsKey)
    }
}

extension URL {
    /// Run `body` with a security-scope opened for this URL when one is
    /// needed (bookmark-resolved inputs); no-op for URLs that already carry
    /// a live grant (open-panel picks, drag-ins).
    func accessingSecurityScopedResource<T>(_ body: () throws -> T) rethrows -> T {
        let didStart = startAccessingSecurityScopedResource()
        defer {
            if didStart { stopAccessingSecurityScopedResource() }
        }
        return try body()
    }
}
