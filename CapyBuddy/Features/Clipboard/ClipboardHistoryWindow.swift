import AppKit
import CoreGraphics
import ImageIO
import SwiftUI

@MainActor
final class ClipboardHistoryWindow {

    private let store: ClipboardStore
    private let pasteboard: NSPasteboard
    private var panel: NSPanel?
    /// Vision-result panel re-used across multiple "Extract text" actions
    /// so the user doesn't accumulate stray windows.
    private var extractPanel: ExtractResultPanel?

    init(store: ClipboardStore, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
    }

    func toggle() {
        if let panel, panel.isVisible {
            close()
        } else {
            show()
        }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Hide the system title text so the in-content header (logo + title)
        // can own the visual hierarchy. Traffic lights stay because of the
        // closable styleMask.
        panel.title = String(localized: "Clipboard History")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingController(
            rootView: ClipboardHistoryView(
                store: store,
                onPick: { [weak self] item in self?.pick(item) },
                onClose: { [weak self] in self?.close() },
                onExtractText: { [weak self] item in self?.extractText(from: item) },
                onScanQR: { [weak self] item in self?.scanQR(from: item) }
            )
        )
        panel.contentViewController = hosting
        return panel
    }

    // MARK: - Vision actions on image items

    /// Open the OCR / translate panel for an image clipboard item. Loads
    /// the on-disk PNG (the same path the row's thumbnail uses) and feeds
    /// it to a fresh `ExtractResultViewModel`. Re-uses one panel instance
    /// across calls so successive Extract clicks don't pile up windows.
    func extractText(from item: ClipboardItem) {
        guard case .image(let url) = item.kind,
              let cgImage = Self.loadCGImage(from: url) else { return }
        let viewModel = ExtractResultViewModel(
            runOCR: { try await OCRService.recognizedString(in: cgImage) }
        )
        let panel: ExtractResultPanel
        if let existing = extractPanel {
            panel = existing
            panel.contentViewController = NSHostingController(
                rootView: ExtractResultView(viewModel: viewModel)
            )
        } else {
            panel = ExtractResultPanel(viewModel: viewModel)
            extractPanel = panel
        }
        panel.center()
        panel.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Run barcode detection against an image clipboard item. On success
    /// shows an alert with Copy / Open (if URL); on failure surfaces a
    /// short "no code" alert. Mirrors the screenshot toolbar's flow.
    func scanQR(from item: ClipboardItem) {
        guard case .image(let url) = item.kind,
              let cgImage = Self.loadCGImage(from: url) else { return }
        Task { @MainActor in
            let alert = NSAlert()
            do {
                let hit = try await BarcodeService.firstPayload(in: cgImage)
                alert.messageText = "QR / Barcode detected"
                alert.informativeText = hit.payload
                alert.addButton(withTitle: "Copy")
                let url = BarcodeService.openableURL(from: hit.payload)
                if url != nil { alert.addButton(withTitle: "Open") }
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                let response = alert.runModal()
                switch response {
                case .alertFirstButtonReturn:
                    self.pasteboard.clearContents()
                    self.pasteboard.setString(hit.payload, forType: .string)
                case .alertSecondButtonReturn:
                    if let url { NSWorkspace.shared.open(url) }
                default:
                    break
                }
            } catch {
                alert.alertStyle = .informational
                alert.messageText = "No code found"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                _ = alert.runModal()
            }
        }
    }

    /// PNG-on-disk → CGImage. ImageIO is fewer copies than NSImage when
    /// the only consumer is Vision.
    private static func loadCGImage(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func pick(_ item: ClipboardItem) {
        writeToPasteboard(item)
        close()
    }

    private func writeToPasteboard(_ item: ClipboardItem) {
        pasteboard.clearContents()
        switch item.kind {
        case .text(let s):
            pasteboard.setString(s, forType: .string)
        case .image(let url):
            if let data = try? Data(contentsOf: url) {
                pasteboard.setData(data, forType: .png)
            }
        case .files(let urls):
            pasteboard.writeObjects(urls as [NSURL])
        }
    }
}

// MARK: - Palette
//
// Mirrors PictureConvert's clean white + slate look so the two windows feel
// like they belong to the same family. Kept private to this file.

private enum Palette {
    static let bg          = Color(light: NSColor.white,
                                   dark: NSColor(white: 0.12, alpha: 1))
    static let surface     = Color(light: NSColor(white: 0.97, alpha: 1),
                                   dark: NSColor(white: 0.17, alpha: 1))
    static let surfaceDeep = Color(light: NSColor(white: 0.93, alpha: 1),
                                   dark: NSColor(white: 0.22, alpha: 1))
    static let stroke      = Color(light: NSColor(white: 0.88, alpha: 1),
                                   dark: NSColor(white: 0.30, alpha: 1))
    static let primary     = Color(light: NSColor(red: 0.13, green: 0.13, blue: 0.16, alpha: 1),
                                   dark: NSColor(red: 0.92, green: 0.92, blue: 0.95, alpha: 1))
    static let muted       = Color(light: NSColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1),
                                   dark: NSColor(red: 0.62, green: 0.62, blue: 0.68, alpha: 1))
    static let accent      = Color(light: NSColor(red: 0.30, green: 0.45, blue: 0.95, alpha: 1),
                                   dark: NSColor(red: 0.45, green: 0.58, blue: 1.00, alpha: 1))
    static let warn        = Color(light: NSColor(red: 0.92, green: 0.45, blue: 0.40, alpha: 1),
                                   dark: NSColor(red: 0.98, green: 0.55, blue: 0.50, alpha: 1))
}

// MARK: - Root view

private struct ClipboardHistoryView: View {

    @ObservedObject var store: ClipboardStore
    let onPick: (ClipboardItem) -> Void
    let onClose: () -> Void
    let onExtractText: (ClipboardItem) -> Void
    let onScanQR: (ClipboardItem) -> Void

    @State private var query: String = ""
    @State private var selectedID: UUID?

    private var filtered: [ClipboardItem] { store.search(query) }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            content
            footer
        }
        .frame(minWidth: 520, idealWidth: 520, minHeight: 600, idealHeight: 600)
        .background(Palette.bg.ignoresSafeArea())
        .onAppear { selectedID = filtered.first?.id }
        .onChange(of: query) { _, _ in selectedID = filtered.first?.id }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Clipboard History")
                    .font(.title3.bold())
                    .foregroundStyle(Palette.primary)
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        // Top padding leaves room for the traffic-light buttons sitting in
        // the transparent titlebar area.
        .padding(.top, 28)
        .padding(.bottom, 14)
    }

    private var subtitleText: String {
        let total = store.items.count
        let pinned = store.items.filter(\.pinned).count
        if total == 0 { return "Copy something to get started" }
        if pinned > 0 { return "\(total) item\(total == 1 ? "" : "s") · \(pinned) pinned" }
        return "\(total) item\(total == 1 ? "" : "s")"
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
            TextField("Search clipboard…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Palette.primary)
                .onSubmit(submitSelected)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filtered) { item in
                        ClipboardRow(
                            item: item,
                            selected: selectedID == item.id,
                            onCopy: { onPick(item) },
                            onTogglePin: { store.togglePin(id: item.id) },
                            onDelete: { store.remove(id: item.id) },
                            onExtractText: { onExtractText(item) },
                            onScanQR: { onScanQR(item) }
                        )
                        .onTapGesture(count: 2) { onPick(item) }
                        .onTapGesture { selectedID = item.id }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Palette.muted.opacity(0.55))
            Text(query.isEmpty ? "No clipboard items" : "No matches")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.primary)
            Text(query.isEmpty
                 ? "Copy something to start building history."
                 : "Try a different search term.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
        }
        .padding(.bottom, 40)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: { store.clearUnpinned() }) {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                    Text("Clear Unpinned")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(unpinnableExists ? Palette.warn : Palette.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!unpinnableExists)

            Spacer()

            Text("\(store.items.count) item\(store.items.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Palette.surface
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Palette.stroke)
                        .frame(height: 1)
                }
        )
    }

    private var unpinnableExists: Bool {
        store.items.contains(where: { !$0.pinned })
    }

    private func submitSelected() {
        let target = filtered.first { $0.id == selectedID } ?? filtered.first
        if let target { onPick(target) }
    }
}

// MARK: - Row

private struct ClipboardRow: View {
    let item: ClipboardItem
    let selected: Bool
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    let onExtractText: () -> Void
    let onScanQR: () -> Void

    @State private var hovering = false

    private var isImage: Bool {
        if case .image = item.kind { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leadingGlyph
            VStack(alignment: .leading, spacing: 3) {
                Text(rowText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(rowTextStyle)
                    .lineLimit(2)
                    .truncationMode(.tail)
                metaLine
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(rowStroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy", action: onCopy)
            Button(item.pinned ? "Unpin" : "Pin", action: onTogglePin)
            if isImage {
                Divider()
                Button("Extract Text…", action: onExtractText)
                Button("Scan QR Code", action: onScanQR)
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var rowFill: Color {
        if selected { return Palette.accent.opacity(0.10) }
        if hovering { return Palette.surface }
        return .clear
    }

    private var rowStroke: Color {
        if selected { return Palette.accent.opacity(0.32) }
        if hovering { return Palette.stroke }
        return .clear
    }

    private var rowTextStyle: Color {
        if case .image = item.kind { return Palette.muted }
        return Palette.primary
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        if case .image(let url) = item.kind {
            ImageThumbnail(url: url)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.surface)
                Image(systemName: kindSymbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Palette.muted)
            }
            .frame(width: 38, height: 38)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Palette.stroke, lineWidth: 1)
            )
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.accent)
            }
            Text(item.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Palette.muted)
            Text("·")
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted.opacity(0.5))
            Text(kindLabel)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Palette.muted)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 4) {
            RowActionButton(
                symbol: "doc.on.doc",
                help: "Copy",
                tint: Palette.accent,
                action: onCopy
            )
            RowActionButton(
                symbol: item.pinned ? "pin.slash" : "pin",
                help: item.pinned ? "Unpin" : "Pin",
                tint: Palette.accent,
                action: onTogglePin
            )
            RowActionButton(
                symbol: "trash",
                help: "Delete",
                tint: Palette.warn,
                action: onDelete
            )
        }
        .opacity(hovering || selected ? 1 : 0)
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.12), value: selected)
    }

    private var rowText: String {
        switch item.kind {
        case .image(let url):
            if let dim = imagePixelDimensions(url) {
                return "Image · \(dim.width) × \(dim.height)"
            }
            return "Image"
        case .files(let urls):
            if urls.count == 1 { return urls[0].lastPathComponent }
            return "\(urls.count) files · \(urls.first?.lastPathComponent ?? "")"
        case .text(let s):
            return s
        }
    }

    private var kindSymbol: String {
        switch item.kind {
        case .text:  return "doc.text"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        }
    }

    private var kindLabel: String {
        switch item.kind {
        case .text:  return "Text"
        case .image: return "Image"
        case .files(let urls): return urls.count == 1 ? "File" : "\(urls.count) files"
        }
    }

    private func imagePixelDimensions(_ url: URL) -> (width: Int, height: Int)? {
        guard let rep = NSImage(contentsOf: url)?.representations.first else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }
}

// MARK: - Action button

private struct RowActionButton: View {
    let symbol: String
    let help: String
    let tint: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Color.white : tint)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? tint : tint.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Image thumbnail

/// Square thumbnail for an on-disk PNG. Loaded lazily off the scrolling
/// hot path via @State + onAppear.
private struct ImageThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Palette.stroke, lineWidth: 1)
                    )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Palette.surface)
                    Image(systemName: "photo")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.muted)
                }
                .frame(width: 38, height: 38)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Palette.stroke, lineWidth: 1)
                )
            }
        }
        .onAppear {
            if image == nil { image = NSImage(contentsOf: url) }
        }
    }
}
