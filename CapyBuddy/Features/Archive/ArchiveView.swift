import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Palette
//
// Same clean white + slate palette as the Picture Converter — kept private
// to this feature so the design tokens don't bleed into other surfaces.

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
    static let success     = Color(light: NSColor(red: 0.18, green: 0.65, blue: 0.40, alpha: 1),
                                   dark: NSColor(red: 0.30, green: 0.78, blue: 0.50, alpha: 1))
    static let warn        = Color(light: NSColor(red: 0.92, green: 0.45, blue: 0.40, alpha: 1),
                                   dark: NSColor(red: 0.98, green: 0.55, blue: 0.50, alpha: 1))
}

// MARK: - Detected intent
//
// After the user drops files we classify what they probably want:
// - one file that LOOKS like an archive  → decompress (with a "compress instead" escape hatch)
// - everything else                       → compress, user picks format

private enum DropIntent: Equatable {
    case empty
    case canDecompress(format: ArchiveFormat)   // single archive file
    case mustCompress                            // folder, multiple items, or non-archive file
}

// MARK: - Root

struct ArchiveRootView: View {

    @StateObject var queue: ArchiveQueue
    @State private var staged: [URL] = []
    @State private var compressFormat: ArchiveFormat = .zip
    @State private var isHovering: Bool = false
    @State private var overrideDecompress: Bool = false  // user clicked "compress instead"

    init(queue: ArchiveQueue) {
        _queue = StateObject(wrappedValue: queue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            DropZone(
                staged: staged,
                isHovering: $isHovering,
                onAddURLs: handleAddURLs,
                onClear: { staged.removeAll(); overrideDecompress = false }
            )
            .frame(height: 200)

            controlBar

            actionButton

            jobList
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 620)
        .background(Palette.bg.ignoresSafeArea())
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Compressor")
                    .font(.title3.bold())
                    .foregroundStyle(Palette.primary)
                Text("Drop files to compress, or an archive to extract.")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
        }
    }

    private var detectedIntent: DropIntent {
        if staged.isEmpty { return .empty }
        if !overrideDecompress,
           staged.count == 1,
           !isDirectory(staged[0]),
           let format = ArchiveFormat.detect(from: staged[0]) {
            return .canDecompress(format: format)
        }
        return .mustCompress
    }

    @ViewBuilder
    private var controlBar: some View {
        switch detectedIntent {
        case .empty:
            EmptyView()
        case .canDecompress(let format):
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(Palette.accent)
                Text("Detected \(format.displayName) archive - will extract to the same folder.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.primary)
                Spacer()
                Button("Compress instead") {
                    overrideDecompress = true
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(Palette.accent)
            }
            .padding(14)
            .background(roundedSurface)
        case .mustCompress:
            HStack(spacing: 10) {
                Text("Compress as")
                    .font(.caption.bold())
                    .foregroundStyle(Palette.muted)
                Picker("", selection: $compressFormat) {
                    ForEach(availableCompressFormats) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 140)
                .tint(Palette.accent)
                Spacer()
                Text("\(staged.count) item\(staged.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
            .padding(14)
            .background(roundedSurface)
        }
    }

    /// `.gz` only handles a single file; hide it when the staged set has a
    /// directory or multiple items so the user can't pick an impossible
    /// combination and confuse themselves.
    private var availableCompressFormats: [ArchiveFormat] {
        let gzOK = staged.count == 1 && !isDirectory(staged[0])
        return ArchiveFormat.allCases.filter { gzOK || $0 != .gz }
    }

    private var roundedSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.surface)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button(action: runAction) {
                    HStack(spacing: 6) {
                        Image(systemName: actionIcon)
                        Text(actionLabel)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(staged.isEmpty ? Palette.surfaceDeep : Palette.accent)
                    )
                    .foregroundStyle(staged.isEmpty ? Palette.muted : Color.white)
                }
                .buttonStyle(.plain)
                .disabled(staged.isEmpty)

                if case .mustCompress = detectedIntent {
                    Button(action: runSaveAs) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.pencil")
                            Text("Save As…")
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Palette.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Palette.stroke, lineWidth: 1)
                        )
                        .foregroundStyle(Palette.primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Surface the planned output filename so the user can see what
            // they'll get before hitting Compress — and know that Save As…
            // is the escape hatch when the default doesn't fit.
            if case .mustCompress = detectedIntent {
                HStack(spacing: 4) {
                    Image(systemName: "doc")
                        .font(.system(size: 10))
                    Text("Will save as \(defaultOutputFilename)")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// What `runAction` would write to disk in compress mode — shown as a
    /// hint under the button and used to pre-fill the Save As… panel.
    private var defaultOutputFilename: String {
        "\(ArchiveEngine.defaultCompressStem()).\(compressFormat.fileExtension)"
    }

    private var actionIcon: String {
        switch detectedIntent {
        case .empty, .mustCompress: return "archivebox.fill"
        case .canDecompress: return "shippingbox.and.arrow.backward.fill"
        }
    }

    private var actionLabel: String {
        switch detectedIntent {
        case .empty:
            return "Add files to compress or extract"
        case .canDecompress(let format):
            return "Extract \(format.displayName) archive"
        case .mustCompress:
            return "Compress to \(compressFormat.displayName)"
        }
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent")
                    .font(.caption.bold())
                    .foregroundStyle(Palette.muted)
                Spacer()
                if queue.jobs.contains(where: { $0.isTerminal }) {
                    Button("Clear finished", action: queue.clearCompleted)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(Palette.accent)
                }
            }
            if queue.jobs.isEmpty {
                Text("Finished jobs will appear here.")
                    .font(.caption)
                    .foregroundStyle(Palette.muted.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(queue.jobs.reversed()) { job in
                            JobRow(job: job)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Actions

    private func handleAddURLs(_ urls: [URL]) {
        for url in urls where !staged.contains(url) {
            staged.append(url)
        }
        // Dropping new files invalidates a pending "compress instead"
        // override — re-detect from scratch.
        overrideDecompress = false
    }

    private func runAction() {
        switch detectedIntent {
        case .empty:
            return
        case .canDecompress(let format):
            queue.submitDecompress(input: staged[0], format: format)
        case .mustCompress:
            queue.submitCompress(inputs: staged, format: compressFormat)
        }
        staged.removeAll()
        overrideDecompress = false
    }

    /// Open NSSavePanel pre-filled with the timestamped default name in the
    /// source's folder, so the user only changes what they care about
    /// (often: the name; occasionally: the location).
    private func runSaveAs() {
        guard !staged.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Save Archive"
        panel.nameFieldStringValue = defaultOutputFilename
        panel.directoryURL = staged[0].deletingLastPathComponent()
        // We let the user keep the extension we want — NSSavePanel will
        // append `.zip` etc. if they delete it. Don't constrain
        // allowedContentTypes since we publish formats (tar.gz) that don't
        // have a clean UTType match.
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            queue.submitCompress(
                inputs: staged,
                format: compressFormat,
                customOutputURL: url
            )
            staged.removeAll()
            overrideDecompress = false
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - Drop zone

private struct DropZone: View {
    let staged: [URL]
    @Binding var isHovering: Bool
    let onAddURLs: ([URL]) -> Void
    let onClear: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isHovering ? Palette.surface : Palette.bg)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .foregroundStyle(isHovering ? Palette.accent : Palette.stroke)

            if staged.isEmpty {
                emptyState
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onTapGesture(perform: openPanel)
            } else {
                stagedView
            }
        }
        .onDrop(
            of: [UTType.fileURL],
            isTargeted: Binding(get: { isHovering }, set: { isHovering = $0 })
        ) { providers in
            Task {
                let urls = await Self.collectURLs(from: providers)
                if !urls.isEmpty { await MainActor.run { onAddURLs(urls) } }
            }
            return true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(isHovering ? Palette.accent : Palette.muted)
                .scaleEffect(isHovering ? 1.08 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovering)
            Text("Drop files or an archive here")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.primary)
            Text("or click to choose")
                .font(.caption)
                .foregroundStyle(Palette.muted)
        }
    }

    private var stagedView: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(staged, id: \.self) { url in
                        StagedTile(url: url)
                    }
                    AddMoreTile(action: openPanel)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.caption2)
                Text("\(staged.count) staged · drop more here")
                    .font(.caption)
                Spacer()
                Button("Clear", action: onClear)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(Palette.accent)
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 8)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            onAddURLs(panel.urls)
        }
    }

    private static func collectURLs(from providers: [NSItemProvider]) async -> [URL] {
        await withTaskGroup(of: URL?.self) { group in
            for provider in providers {
                group.addTask { await loadURL(from: provider) }
            }
            var out: [URL] = []
            for await maybe in group {
                if let url = maybe { out.append(url) }
            }
            return out
        }
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    cont.resume(returning: url)
                } else if let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    cont.resume(returning: url)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Staged tile

/// Square tile that previews one staged URL. Uses an icon (folder, archive,
/// generic file) since we can't render thumbnails for arbitrary file types
/// the same way the Picture Converter can for images.
private struct StagedTile: View {
    let url: URL
    private let side: CGFloat = 110

    private var iconSystemName: String {
        if isDirectory(url) { return "folder.fill" }
        if ArchiveFormat.detect(from: url) != nil { return "shippingbox.fill" }
        return "doc.fill"
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: iconSystemName)
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(Palette.accent)
                .frame(width: side, height: side - 28)
            Text(url.lastPathComponent)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Palette.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: side - 8)
        }
        .frame(width: side, height: side)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: 1)
        )
        .help(url.path)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

private struct AddMoreTile: View {
    let action: () -> Void
    private let side: CGFloat = 110

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                Text("Add")
                    .font(.system(size: 10, design: .rounded))
            }
            .foregroundStyle(Palette.muted)
            .frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Palette.stroke)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Job row

private struct JobRow: View {
    @ObservedObject var job: ArchiveJob

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            statusGlyph
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detailLine
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch job.state {
        case .queued:
            Image(systemName: "clock.fill").foregroundStyle(Palette.muted)
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warn)
        }
    }

    private var verb: String { job.isCompress ? "Compressing" : "Extracting" }

    @ViewBuilder
    private var detailLine: some View {
        switch job.state {
        case .queued:
            Text("Queued · \(job.format.displayName)")
        case .running:
            Text("\(verb) → \(job.format.displayName)…")
        case .finished(_, let inBytes, let outBytes):
            if job.isCompress {
                Text("\(byteString(inBytes)) → \(byteString(outBytes))   ·   \(ArchiveQueue.savingsLabel(inputBytes: inBytes, outputBytes: outBytes))")
            } else {
                Text("Extracted \(byteString(outBytes))")
            }
        case .failed(let msg):
            Text(msg)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch job.state {
        case .running:
            ProgressView()
                .progressViewStyle(.linear)
                .frame(width: 80)
                .tint(Palette.accent)
        case .finished(let url, _, _):
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        default:
            EmptyView()
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview {
    ArchiveRootView(queue: ArchiveQueue())
}
