// Picture Editor disabled — feature is not mature yet.
#if false
import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Palette (kept private to this feature, mirroring PictureConvert)

private enum EditorPalette {
    static let bg          = Color.white
    static let surface     = Color(white: 0.97)
    static let surfaceDeep = Color(white: 0.93)
    static let stroke      = Color(white: 0.88)
    static let primary     = Color(red: 0.13, green: 0.13, blue: 0.16)
    static let muted       = Color(red: 0.55, green: 0.55, blue: 0.60)
    static let accent      = Color(red: 0.30, green: 0.45, blue: 0.95)
    static let success     = Color(red: 0.18, green: 0.65, blue: 0.40)
}

// MARK: - Root

struct PictureEditRootView: View {

    @StateObject var model: PictureEditModel
    @State private var cropMode: Bool = false
    @State private var cropRectImageSpace: CGRect? = nil
    @State private var currentZoom: CGFloat = 1.0
    @State private var zoomCommand: ZoomableImageView.ZoomCommand? = nil

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                canvas
                    .frame(minWidth: 360, minHeight: 360)
                    .layoutPriority(1)
                sidebar
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            }
            Divider()
            statusBar
        }
        .background(EditorPalette.bg.ignoresSafeArea())
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: openFile) {
                Label("Open", systemImage: "folder")
            }

            Divider().frame(height: 18)

            Button(action: { model.undo() }) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .keyboardShortcut("z", modifiers: .command)

            Button(action: { model.redo() }) {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Button(action: { model.resetToOriginal() }) {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .disabled(model.currentImage == nil)

            Divider().frame(height: 18)

            // Zoom group — fit / actual / in / out
            Button { zoomCommand = .fit } label: {
                Label("Fit", systemImage: "rectangle.compress.vertical")
            }
            .disabled(model.currentImage == nil)
            .help("Fit to window (⌘0)")
            .keyboardShortcut("0", modifiers: .command)

            Button { zoomCommand = .actualSize } label: {
                Label("100%", systemImage: "1.square")
            }
            .disabled(model.currentImage == nil)
            .help("Actual size (⌘1)")
            .keyboardShortcut("1", modifiers: .command)

            Button { zoomCommand = .zoomOut } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(model.currentImage == nil)
            .help("Zoom out (⌘-)")
            .keyboardShortcut("-", modifiers: .command)

            Button { zoomCommand = .zoomIn } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(model.currentImage == nil)
            .help("Zoom in (⌘+)")
            .keyboardShortcut("=", modifiers: .command)

            Text(zoomLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(EditorPalette.muted)
                .frame(width: 56, alignment: .leading)

            Spacer()

            Button(action: { model.copyToClipboard() }) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(model.currentImage == nil)
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button(action: exportFile) {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            .disabled(model.currentImage == nil)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(EditorPalette.surface)
    }

    private var zoomLabel: String {
        guard model.currentImage != nil else { return "" }
        return "\(Int((currentZoom * 100).rounded()))%"
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack {
            if let img = model.currentImage {
                Text("\(Int(img.extent.width)) × \(Int(img.extent.height)) px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(EditorPalette.muted)
            }
            Spacer()
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(EditorPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(EditorPalette.surface)
    }

    // MARK: Canvas

    @ViewBuilder
    private var canvas: some View {
        ZStack {
            EditorPalette.surfaceDeep.ignoresSafeArea()

            if let img = model.displayImage ?? model.currentImage {
                ZoomableImageView(
                    image: img,
                    context: model.context,
                    currentZoom: $currentZoom,
                    zoomCommand: $zoomCommand
                )
                if cropMode {
                    cropOverlay
                }
            } else {
                emptyCanvas
            }

            if model.isWorking {
                ZStack {
                    Color.black.opacity(0.18)
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.large)
                        Text(model.statusMessage ?? "Working…")
                            .foregroundStyle(.white)
                            .font(.callout)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .allowsHitTesting(true)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    /// Crop overlay sits on top of the zoomable canvas. It works in canvas
    /// coordinates (0…1 normalized) so it doesn't have to know about the
    /// scrollview's magnification — we convert to image-space at apply
    /// time using the current image extent.
    private var cropOverlay: some View {
        GeometryReader { geo in
            CropDragOverlay(
                geometry: geo,
                imageSize: model.currentImage?.extent.size ?? .zero,
                cropRectImageSpace: $cropRectImageSpace
            )
        }
    }

    private var emptyCanvas: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(EditorPalette.muted)
            Text("Drop an image here")
                .font(.title3.bold())
                .foregroundStyle(EditorPalette.primary)
            Text("PNG, JPEG, HEIC, TIFF, GIF, AVIF, BMP, ICNS, ICO, JP2 - anything macOS can read.")
                .font(.callout)
                .foregroundStyle(EditorPalette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Choose File…", action: openFile)
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Apply / cancel banner — shows whenever any preview is live
                if model.hasPreviewFilter || model.hasLiveAdjustments {
                    pendingPreviewBanner
                }
                cropSection
                transformSection
                resizeSection
                filtersSection
                adjustSection
                watermarkSection
                magicSection
            }
            .padding(14)
        }
        .frame(maxHeight: .infinity)
        .background(EditorPalette.surface)
    }

    private var pendingPreviewBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill").foregroundStyle(EditorPalette.accent)
            Text("Previewing").font(.caption.bold())
            Spacer()
            Button("Cancel") {
                model.previewFilter = nil
                model.liveBrightness = 0
                model.liveContrast = 0
                model.liveSaturation = 0
            }
            .controlSize(.small)
            Button("Apply") {
                model.applyPendingPreview()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(EditorPalette.accent.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(EditorPalette.accent.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: Sidebar sections

    private var cropSection: some View {
        SidebarSection(title: "Crop", systemImage: "crop") {
            Toggle("Crop mode", isOn: $cropMode)
                .toggleStyle(.switch)
                .onChange(of: cropMode) { _, new in
                    if !new { cropRectImageSpace = nil }
                }
            HStack {
                Button("Apply Crop") {
                    if let rect = cropRectImageSpace {
                        model.cropCurrent(to: rect)
                    }
                    cropMode = false
                    cropRectImageSpace = nil
                }
                .disabled(cropRectImageSpace == nil)
                Spacer()
                Button("Cancel") {
                    cropMode = false
                    cropRectImageSpace = nil
                }
                .disabled(!cropMode)
            }
        }
    }

    private var transformSection: some View {
        SidebarSection(title: "Transform", systemImage: "rotate.left") {
            HStack(spacing: 8) {
                Button {
                    model.rotate(byDegrees: -90)
                } label: { Label("Left 90°", systemImage: "rotate.left") }
                Button {
                    model.rotate(byDegrees: 90)
                } label: { Label("Right 90°", systemImage: "rotate.right") }
            }
            HStack(spacing: 8) {
                Button {
                    model.flipHorizontal()
                } label: { Label("Flip H", systemImage: "arrow.left.and.right") }
                Button {
                    model.flipVertical()
                } label: { Label("Flip V", systemImage: "arrow.up.and.down") }
            }
        }
    }

    private var resizeSection: some View {
        SidebarSection(title: "Resize", systemImage: "arrow.up.left.and.down.right.magnifyingglass") {
            ResizePanel(model: model)
        }
    }

    private var filtersSection: some View {
        SidebarSection(title: "Filters", systemImage: "wand.and.stars") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tap a filter to preview, then Apply.")
                    .font(.caption)
                    .foregroundStyle(EditorPalette.muted)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(PictureEditOps.Filter.allCases) { filter in
                        FilterChip(
                            filter: filter,
                            isActive: model.previewFilter == filter,
                            action: { model.togglePreviewFilter(filter) }
                        )
                    }
                }
            }
        }
    }

    private var adjustSection: some View {
        SidebarSection(title: "Adjust", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 4) {
                AdjustSlider(label: "Brightness", value: $model.liveBrightness, range: -0.5...0.5)
                AdjustSlider(label: "Contrast",   value: $model.liveContrast,   range: -0.5...0.5)
                AdjustSlider(label: "Saturation", value: $model.liveSaturation, range: -1.0...1.0)
                Text("Use the banner above to Apply or Cancel.")
                    .font(.caption2)
                    .foregroundStyle(EditorPalette.muted)
            }
        }
    }

    private var watermarkSection: some View {
        SidebarSection(title: "Watermark", systemImage: "textformat") {
            WatermarkPanel(model: model)
        }
    }

    private var magicSection: some View {
        SidebarSection(title: "Magic", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Vision-powered tools.")
                    .font(.caption)
                    .foregroundStyle(EditorPalette.muted)
                Button {
                    Task { await model.removeBackground() }
                } label: {
                    Label("Remove Background", systemImage: "person.crop.rectangle.badge.xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking || model.currentImage == nil)
            }
        }
    }

    // MARK: Actions

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ConversionFormat.allCases.compactMap {
            UTType($0.utiIdentifier)
        }
        if panel.runModal() == .OK, let url = panel.url {
            model.loadImage(from: url)
            cropMode = false
            cropRectImageSpace = nil
        }
    }

    private func exportFile() {
        guard model.currentImage != nil else { return }
        let exportFormat = model.sourceFormat ?? .png
        let panel = NSSavePanel()
        panel.allowedContentTypes = ConversionFormat.writableOnThisSystem.compactMap {
            UTType($0.utiIdentifier)
        }
        panel.nameFieldStringValue = model.defaultExportFilename(format: exportFormat)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let chosenFormat = ConversionFormat.inferred(from: url) ?? exportFormat
        model.export(to: url, format: chosenFormat, quality: 0.9)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL? = {
                if let u = item as? URL { return u }
                if let d = item as? Data { return URL(dataRepresentation: d, relativeTo: nil) }
                return nil
            }()
            guard let url else { return }
            DispatchQueue.main.async {
                model.loadImage(from: url)
                cropMode = false
                cropRectImageSpace = nil
            }
        }
        return true
    }
}

// MARK: - Crop overlay (canvas-aligned drag rectangle)

/// Draws a draggable crop rectangle directly over the zoomable canvas. The
/// rectangle is stored in *image-space* coordinates so it survives the
/// underlying NSScrollView's magnification — when the user pans/zooms, the
/// overlay redraws but the crop rect stays anchored to the same pixels.
private struct CropDragOverlay: View {
    let geometry: GeometryProxy
    let imageSize: CGSize
    @Binding var cropRectImageSpace: CGRect?

    @State private var dragStart: CGPoint?
    @State private var dragRectInLocal: CGRect?

    var body: some View {
        ZStack {
            // The fit-to-window scaling is handled by ZoomableImageView, but
            // the crop overlay is *always* drawn in fit-to-window space —
            // i.e. assume the underlying image is fully visible. This is
            // a deliberate simplification: the crop rect is most useful at
            // overview zoom level. Users can fine-tune by re-cropping.
            let visibleImageRect = computeFitRect(canvas: geometry.size, imageSize: imageSize)

            Color.black.opacity(0.35)
                .reverseMask {
                    if let rect = highlightRect(visibleImageRect: visibleImageRect) {
                        Rectangle().frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    }
                }

            if let rect = highlightRect(visibleImageRect: visibleImageRect) {
                Rectangle()
                    .strokeBorder(EditorPalette.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let visibleImageRect = computeFitRect(canvas: geometry.size, imageSize: imageSize)
                    if dragStart == nil { dragStart = value.startLocation }
                    let s = dragStart ?? value.startLocation
                    let r = CGRect(
                        x: min(s.x, value.location.x),
                        y: min(s.y, value.location.y),
                        width: abs(value.location.x - s.x),
                        height: abs(value.location.y - s.y)
                    ).intersection(visibleImageRect)
                    dragRectInLocal = r
                    cropRectImageSpace = imageSpaceRect(for: r, visibleImageRect: visibleImageRect)
                }
                .onEnded { _ in dragStart = nil }
        )
    }

    private func highlightRect(visibleImageRect: CGRect) -> CGRect? {
        if let live = dragRectInLocal, live.width > 1, live.height > 1 { return live }
        guard let imgRect = cropRectImageSpace else { return nil }
        return localRect(forImageSpace: imgRect, visibleImageRect: visibleImageRect)
    }

    private func computeFitRect(canvas: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0 && imageSize.height > 0 else {
            return CGRect(origin: .zero, size: canvas)
        }
        let scale = min(canvas.width / imageSize.width, canvas.height / imageSize.height, 1.0)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
    }

    private func imageSpaceRect(for localRect: CGRect, visibleImageRect: CGRect) -> CGRect? {
        guard visibleImageRect.width > 0, imageSize.width > 0 else { return nil }
        let scale = imageSize.width / visibleImageRect.width
        let xImg = (localRect.minX - visibleImageRect.minX) * scale
        // Convert SwiftUI top-down → CIImage bottom-up.
        let yCanvasBottom = visibleImageRect.maxY - localRect.maxY
        let yImg = yCanvasBottom * scale
        return CGRect(x: xImg, y: yImg, width: localRect.width * scale, height: localRect.height * scale)
    }

    private func localRect(forImageSpace imgRect: CGRect, visibleImageRect: CGRect) -> CGRect {
        guard imageSize.width > 0 else { return .zero }
        let scale = visibleImageRect.width / imageSize.width
        let x = visibleImageRect.minX + imgRect.minX * scale
        let yBottom = imgRect.minY * scale
        let y = visibleImageRect.maxY - yBottom - imgRect.height * scale
        return CGRect(x: x, y: y, width: imgRect.width * scale, height: imgRect.height * scale)
    }
}

extension View {
    /// `mask(_:)` inverted — paint the masked region opaque, the rest
    /// transparent. Used by `CropDragOverlay` to punch a hole through the
    /// dim layer at the crop rect.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(mask().blendMode(.destinationOut))
        }
    }
}

// MARK: - Sidebar plumbing

private struct SidebarSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.bold())
                .foregroundStyle(EditorPalette.muted)
            content()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(EditorPalette.stroke, lineWidth: 1)
        )
    }
}

private struct AdjustSlider: View {
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%+.2f", value))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(EditorPalette.muted)
            }
            Slider(value: $value, in: range)
        }
    }
}

private struct FilterChip: View {
    let filter: PictureEditOps.Filter
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(filter.displayName)
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 26)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? EditorPalette.accent : Color.white)
                )
                .foregroundStyle(isActive ? Color.white : EditorPalette.primary)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isActive ? EditorPalette.accent : EditorPalette.stroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Resize panel with both percentage shortcuts and a free numeric input.
/// "Resize" used to feel like it dropped resolution because the previews
/// were at fit-to-window — the new zoomable canvas makes the actual pixel
/// dimensions discoverable, and the status bar shows them at all times.
private struct ResizePanel: View {
    @ObservedObject var model: PictureEditModel
    @State private var customWidth: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scale to a percentage of the original.")
                .font(.caption)
                .foregroundStyle(EditorPalette.muted)
            HStack {
                ForEach([0.25, 0.5, 0.75, 1.5, 2.0], id: \.self) { scale in
                    Button("\(Int(scale * 100))%") {
                        model.resize(scale: scale)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Divider().padding(.vertical, 2)

            HStack {
                Text("Width:").font(.caption)
                TextField("px", text: $customWidth)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 80)
                Button("Apply") {
                    if let target = Double(customWidth),
                       target > 0,
                       let img = model.currentImage,
                       img.extent.width > 0 {
                        let scale = target / Double(img.extent.width)
                        model.resize(scale: CGFloat(scale))
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

private struct WatermarkPanel: View {
    @ObservedObject var model: PictureEditModel

    @State private var text: String = ""
    @State private var position: PictureEditOps.WatermarkPosition = .bottomRight
    @State private var opacity: CGFloat = 0.8

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Watermark text", text: $text)
                .textFieldStyle(.roundedBorder)
            Picker("Position", selection: $position) {
                ForEach(PictureEditOps.WatermarkPosition.allCases) { pos in
                    Text(pos.displayName).tag(pos)
                }
            }
            .pickerStyle(.menu)
            HStack {
                Text("Opacity").font(.caption)
                Slider(value: $opacity, in: 0.2...1.0)
                Text(String(format: "%.0f%%", opacity * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(EditorPalette.muted)
                    .frame(width: 36, alignment: .trailing)
            }
            Button {
                model.addWatermark(text: text, position: position, opacity: opacity)
            } label: {
                Label("Add Watermark", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(text.isEmpty || model.currentImage == nil)
        }
    }
}

#endif
