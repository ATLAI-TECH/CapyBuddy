import AppKit
import Combine
import SwiftUI

@MainActor
final class ClipboardFeature: NSObject, Feature {

    let id = "clipboard"
    let displayName = String(localized: "Clipboard")
    let iconSystemName = "doc.on.clipboard"
    let summary = String(localized: "Keeps a history of recent clipboard items so you can paste anything you copied earlier.")

    var isEnabled: Bool = false
    var showsInMenuBar: Bool = true

    let store: ClipboardStore
    private(set) var monitor: ClipboardMonitor?
    private(set) var window: ClipboardHistoryWindow?
    private var hotkeyTap: HotkeyTap?
    private var hotkeyObservation: AnyCancellable?

    override init() {
        self.store = ClipboardStore()
        super.init()
    }

    /// Test seam: inject a pre-populated (or empty) store so tests don't have
    /// to share the on-disk history file.
    init(store: ClipboardStore) {
        self.store = store
        super.init()
    }

    func start() {
        guard monitor == nil else { return }

        let monitor = ClipboardMonitor(
            store: store,
            captureImages: { ClipboardPrefs.captureImages }
        )
        monitor.start()
        self.monitor = monitor

        self.window = ClipboardHistoryWindow(store: store)

        let tap = HotkeyTap(config: ClipboardHotkeyStore.shared.current)
        tap.onTrigger = { [weak self] in self?.window?.toggle() }
        if !tap.start() {
            NSLog("[CapyBuddy] Clipboard: hotkey registration failed (combo may be in use by the system or another app).")
        }
        self.hotkeyTap = tap

        hotkeyObservation = ClipboardHotkeyStore.shared.$current.sink { [weak self] new in
            self?.hotkeyTap?.config = new
        }
    }

    func stop() {
        monitor?.stop()
        monitor = nil
        hotkeyTap?.stop()
        hotkeyTap = nil
        window?.close()
        window = nil
        hotkeyObservation?.cancel()
        hotkeyObservation = nil
    }

    func makeMenuBarItems() -> [NSMenuItem] {
        // Inserted into the Clipboard feature's submenu by `MenuBarManager`
        // (between Enabled toggle and Settings…). Returns the inner rows
        // directly — header, recent items, footer — without an extra
        // wrapping submenu level, since the feature row is already the
        // parent.
        let recent = Array(store.items.prefix(10))
        let hotkey = ClipboardHotkeyStore.shared.current.displayString
        var items: [NSMenuItem] = []

        let header = NSMenuItem()
        header.view = Self.hosting(
            ClipboardSubmenuHeader(hotkey: hotkey, count: recent.count),
            width: ClipboardSubmenu.width,
            height: 56
        )
        header.isEnabled = false
        items.append(header)
        items.append(.separator())

        if recent.isEmpty {
            let empty = NSMenuItem()
            empty.view = Self.hosting(
                ClipboardSubmenuEmpty(),
                width: ClipboardSubmenu.width,
                height: 64
            )
            empty.isEnabled = false
            items.append(empty)
        } else {
            for item in recent {
                let row = NSMenuItem()
                let view = ClipboardSubmenuRow(item: item) { [weak self] in
                    guard let self else { return }
                    self.copyToPasteboard(item)
                    NSApp.mainMenu?.cancelTracking()
                }
                row.view = Self.hosting(
                    view,
                    width: ClipboardSubmenu.width,
                    height: 38
                )
                items.append(row)
            }
        }

        items.append(.separator())

        let footer = NSMenuItem()
        footer.view = Self.hosting(
            ClipboardSubmenuFooter(hotkey: hotkey) { [weak self] in
                self?.window?.show()
                NSApp.mainMenu?.cancelTracking()
            },
            width: ClipboardSubmenu.width,
            height: 38
        )
        items.append(footer)

        return items
    }

    private static func hosting<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSView {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return host
    }

    func makeSettingsView() -> AnyView {
        AnyView(ClipboardSettingsView(feature: self))
    }

    // MARK: - Actions

    @objc func showWindowAction() {
        window?.show()
    }

    func copyToPasteboard(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text(let s):
            pb.setString(s, forType: .string)
        case .image(let url):
            if let data = try? Data(contentsOf: url) {
                pb.setData(data, forType: .png)
            }
        case .files(let urls):
            pb.writeObjects(urls as [NSURL])
        }
    }

    /// Truncate a preview line by RENDERED width (not character count) so the
    /// menu has a consistent maximum width regardless of script. Counting
    /// characters made CJK previews ~2× wider than ASCII at the same length,
    /// which let one wide clipboard entry stretch the whole menu.
    static func shortPreview(_ text: String, maxWidth: CGFloat = 260) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        let fullWidth = (single as NSString).size(withAttributes: attrs).width
        if fullWidth <= maxWidth { return single }

        let ellipsis = "…"
        let ellipsisWidth = (ellipsis as NSString).size(withAttributes: attrs).width
        let budget = maxWidth - ellipsisWidth

        var result = ""
        var used: CGFloat = 0
        for ch in single {
            let chW = (String(ch) as NSString).size(withAttributes: attrs).width
            if used + chW > budget { break }
            result.append(ch)
            used += chW
        }
        return result + ellipsis
    }
}

enum ClipboardPrefs {
    private static let defaults = UserDefaults.standard
    private static let captureImagesKey = "clipboard.captureImages"
    private static let maxItemsKey = "clipboard.maxItems"

    /// Defaults `true`. Use `register` to set initial values; absent key reads as `false`,
    /// which we don't want for image capture. So we wrap with an explicit fallback.
    static var captureImages: Bool {
        get {
            if defaults.object(forKey: captureImagesKey) == nil { return true }
            return defaults.bool(forKey: captureImagesKey)
        }
        set { defaults.set(newValue, forKey: captureImagesKey) }
    }

    static var maxItems: Int {
        get {
            let stored = defaults.integer(forKey: maxItemsKey)
            return stored > 0 ? stored : 100
        }
        set { defaults.set(newValue, forKey: maxItemsKey) }
    }
}

// MARK: - Submenu views
//
// Custom NSHostingView-backed rows used inside the clipboard submenu.
// The look mirrors the PictureConvert palette (soft accent on muted
// surfaces) but skips solid fills so the views still blend with the
// translucent menu material.

private enum ClipboardSubmenu {
    static let width: CGFloat = 340
    static let accent = Color(light: NSColor(red: 0.30, green: 0.45, blue: 0.95, alpha: 1),
                              dark: NSColor(red: 0.45, green: 0.58, blue: 1.00, alpha: 1))
}

private struct ClipboardSubmenuHeader: View {
    let hotkey: String
    let count: Int

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Clipboard History")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(count == 0
                     ? "No items yet  ·  \(hotkey)"
                     : "Recent \(count)  ·  \(hotkey)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ClipboardSubmenuEmpty: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "tray")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            Text("Copy something to start building history.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ClipboardSubmenuRow: View {
    let item: ClipboardItem
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 8) {
                leadingGlyph
                Text(rowText)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                copyPill
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering
                          ? ClipboardSubmenu.accent.opacity(0.14)
                          : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
        .help(item.preview)
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        if case .image(let url) = item.kind, let thumb = NSImage(contentsOf: url) {
            Image(nsImage: thumb)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
        } else {
            Image(systemName: kindSymbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
    }

    private var copyPill: some View {
        Text("Copy")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(hovering ? Color.white : ClipboardSubmenu.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(hovering
                          ? ClipboardSubmenu.accent
                          : ClipboardSubmenu.accent.opacity(0.12))
            )
    }

    private var rowText: String {
        if case .image = item.kind { return "Image" }
        return item.preview.replacingOccurrences(of: "\n", with: " ")
    }

    private var kindSymbol: String {
        switch item.kind {
        case .text:  return "doc.text"
        case .image: return "photo"
        case .files: return "doc"
        }
    }
}

private struct ClipboardSubmenuFooter: View {
    let hotkey: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 12))
                    .foregroundStyle(ClipboardSubmenu.accent)
                    .frame(width: 22, height: 22)
                Text("Show All…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 6)
                Text(hotkey)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering
                          ? ClipboardSubmenu.accent.opacity(0.14)
                          : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
    }
}
