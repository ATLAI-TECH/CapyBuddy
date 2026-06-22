import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Palette
//
// Clean white + slate palette with dark-mode counterparts. Kept private to
// this feature so we don't leak design tokens into the rest of the app —
// other features use the system materials.

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
    static let accent      = Color(light: NSColor(red: 0.30, green: 0.45, blue: 0.95, alpha: 1),   // soft blue
                                   dark: NSColor(red: 0.45, green: 0.58, blue: 1.00, alpha: 1))
    static let success     = Color(light: NSColor(red: 0.18, green: 0.65, blue: 0.40, alpha: 1),
                                   dark: NSColor(red: 0.30, green: 0.78, blue: 0.50, alpha: 1))
    static let warn        = Color(light: NSColor(red: 0.92, green: 0.45, blue: 0.40, alpha: 1),
                                   dark: NSColor(red: 0.98, green: 0.55, blue: 0.50, alpha: 1))
}

// MARK: - Root

struct PictureConvertRootView: View {

    @StateObject var queue: ConversionQueue
    @State private var sourceFormat: ConversionFormat
    @State private var targetFormat: ConversionFormat
    @State private var staged: [URL] = []
    @State private var isHovering: Bool = false
    @State private var rejectedDrop: Bool = false

    private let availableTargets: [ConversionFormat]

    init(queue: ConversionQueue) {
        _queue = StateObject(wrappedValue: queue)
        let writable = ConversionFormat.writableOnThisSystem
        self.availableTargets = writable
        // Sensible defaults: PNG → JPEG falls within every macOS version's
        // writable set, so we don't have to guess.
        _sourceFormat = State(initialValue: .png)
        _targetFormat = State(
            initialValue: writable.first(where: { $0 == .jpeg }) ?? writable.first ?? .png
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            formatBar
            DropZone(
                acceptedFormat: sourceFormat,
                staged: staged,
                isHovering: $isHovering,
                rejected: $rejectedDrop,
                onAddURLs: handleAddURLs,
                onRemove: { url in staged.removeAll { $0 == url } }
            )
            .frame(height: 200)

            convertButton

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
                Text("Picture Converter")
                    .font(.title3.bold())
                    .foregroundStyle(Palette.primary)
                Text("Pick a format, drop your files, hit convert.")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
        }
    }

    private var formatBar: some View {
        HStack(spacing: 10) {
            Text("From")
                .font(.caption.bold())
                .foregroundStyle(Palette.muted)
            Picker("", selection: $sourceFormat) {
                ForEach(ConversionFormat.allCases) { fmt in
                    Text(fmt.displayName).tag(fmt)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 100)

            Image(systemName: "arrow.right")
                .font(.caption.bold())
                .foregroundStyle(Palette.muted)

            Text("To")
                .font(.caption.bold())
                .foregroundStyle(Palette.muted)
            Picker("", selection: $targetFormat) {
                ForEach(availableTargets) { fmt in
                    Text(fmt.displayName).tag(fmt)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 100)
            .tint(Palette.accent)

            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: 1)
        )
    }

    private var convertButton: some View {
        Button(action: runConversion) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                Text(staged.isEmpty
                     ? "Add files to convert"
                     : "Convert \(staged.count) file\(staged.count == 1 ? "" : "s") → \(targetFormat.displayName)")
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
                Text("Converted files will appear here.")
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

    /// Files come in from a drop or an open-panel pick. Auto-detect the
    /// source format from the first recognizable file and switch the
    /// `From` picker to match, then stage every file of that format.
    private func handleAddURLs(_ urls: [URL]) {
        guard let detected = urls.lazy.compactMap({ ConversionFormat.inferred(from: $0) }).first else {
            // Nothing in the drop is a recognized image — flash the warn state.
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { rejectedDrop = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation { rejectedDrop = false }
            }
            return
        }
        if sourceFormat != detected {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                sourceFormat = detected
            }
        }
        for url in urls where ConversionFormat.inferred(from: url) == detected && !staged.contains(url) {
            staged.append(url)
        }
    }

    private func runConversion() {
        let urls = staged
        staged.removeAll()
        queue.submit(urls: urls, targetFormat: targetFormat)
    }
}

// MARK: - Drop zone

private struct DropZone: View {
    let acceptedFormat: ConversionFormat
    let staged: [URL]
    @Binding var isHovering: Bool
    @Binding var rejected: Bool
    let onAddURLs: ([URL]) -> Void
    let onRemove: (URL) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isHovering ? Palette.surface : Palette.bg)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .foregroundStyle(
                    rejected
                    ? Palette.warn
                    : (isHovering ? Palette.accent : Palette.stroke)
                )

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
            isTargeted: Binding(
                get: { isHovering },
                set: { isHovering = $0 }
            )
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
            Image(systemName: rejected
                  ? "exclamationmark.triangle.fill"
                  : "tray.and.arrow.down.fill")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(rejected ? Palette.warn
                                 : (isHovering ? Palette.accent : Palette.muted))
                .scaleEffect(isHovering ? 1.08 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovering)
            Text(rejected
                 ? "Hmm, that's not a \(acceptedFormat.displayName) file."
                 : "Drop \(acceptedFormat.displayName) files here")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(rejected ? Palette.warn : Palette.primary)
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
                        StagedThumbnail(url: url) { onRemove(url) }
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
            }
            .foregroundStyle(Palette.muted)
        }
        .padding(.vertical, 8)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ConversionFormat.allCases.compactMap {
            UTType($0.utiIdentifier)
        }
        if panel.runModal() == .OK {
            onAddURLs(panel.urls)
        }
    }

    /// Collect file URLs from drag providers. NSItemProvider returns the
    /// `public.file-url` payload as raw `Data` (an opaque URL bookmark) on
    /// some macOS versions and as a real `URL` on others — handle both.
    private static func collectURLs(from providers: [NSItemProvider]) async -> [URL] {
        await withTaskGroup(of: URL?.self) { group in
            for provider in providers {
                group.addTask {
                    await loadURL(from: provider)
                }
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

// MARK: - Staged thumbnails

/// Square preview tile for a single dropped file. NSImage decodes any
/// format ImageIO understands (incl. AVIF/HEIC/WebP source files), and
/// the load happens off the main thread so dropping a stack of large
/// photos doesn't stutter the UI.
private struct StagedThumbnail: View {
    let url: URL
    let onRemove: () -> Void

    @State private var image: NSImage?
    @State private var hovering: Bool = false

    private let side: CGFloat = 110

    var body: some View {
        ZStack(alignment: .topTrailing) {
            preview
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Palette.stroke, lineWidth: 1)
                )

            removeButton
                .padding(5)
                .opacity(hovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: hovering)
        }
        .overlay(alignment: .bottom) {
            Text(url.lastPathComponent)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: side - 12, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.black.opacity(0.55))
                )
                .padding(.bottom, 6)
        }
        .onHover { hovering = $0 }
        .onAppear(perform: loadImage)
        .help(url.lastPathComponent)
    }

    @ViewBuilder
    private var preview: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
        } else {
            Palette.surface
                .overlay(
                    Image(systemName: "photo")
                        .foregroundStyle(Palette.muted)
                )
        }
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.black.opacity(0.7)))
        }
        .buttonStyle(.plain)
        .help("Remove")
    }

    private func loadImage() {
        guard image == nil else { return }
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOf: url)
            await MainActor.run { self.image = img }
        }
    }
}

/// Trailing tile in the staged strip — same footprint as a thumbnail so
/// the row stays visually aligned. Tap opens the open-panel.
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
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    .foregroundStyle(Palette.stroke)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Job row

private struct JobRow: View {
    @ObservedObject var job: ConversionJob

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
            Image(systemName: "clock.fill")
                .foregroundStyle(Palette.muted)
        case .running:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.success)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warn)
        }
    }

    @ViewBuilder
    private var detailLine: some View {
        switch job.state {
        case .queued:
            Text("Queued · → \(job.targetFormat.displayName)")
        case .running:
            Text("Converting → \(job.targetFormat.displayName)…")
        case .finished(_, let inBytes, let outBytes):
            Text("\(formatBytes(inBytes)) → \(formatBytes(outBytes))   ·   \(ConversionQueue.savingsLabel(inputBytes: inBytes, outputBytes: outBytes))")
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

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview {
    PictureConvertRootView(queue: ConversionQueue())
}
