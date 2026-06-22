// Picture Editor disabled — feature is not mature yet.
#if false
import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Editing state for one image session. Keeps a linear undo stack of
/// `CIImage`s — every committed operation pushes a new entry, and undo /
/// redo just moves an index pointer. CIImages are reference-light (they
/// describe a pipeline, not pixel data), so the stack stays cheap even
/// with dozens of operations queued.
@MainActor
final class PictureEditModel: ObservableObject {

    // MARK: - Source / current
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceFormat: ConversionFormat?

    /// Latest image, or nil when no file is loaded yet.
    @Published private(set) var currentImage: CIImage?

    /// CIContext shared across renders — creating one per call would burn
    /// far more time than the actual filter graph.
    let context: CIContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - History (undo / redo)
    @Published private var history: [CIImage] = []
    @Published private var historyIndex: Int = -1

    var canUndo: Bool { historyIndex > 0 }
    var canRedo: Bool { historyIndex < history.count - 1 }

    // MARK: - Live preview adjustments
    // These are applied on top of `currentImage` for live feedback before
    // the user hits "Apply". On apply, we snapshot the adjusted image into
    // history and reset these to identity.
    @Published var liveBrightness: CGFloat = 0
    @Published var liveContrast: CGFloat = 0
    @Published var liveSaturation: CGFloat = 0

    /// Filter the user is *previewing*. Stays nil until they tap a filter
    /// chip; flipping between chips just swaps this value (so previews are
    /// non-stacking — clicking Sepia after Sepia doesn't double-apply).
    /// Applied = pushed onto history and cleared.
    @Published var previewFilter: PictureEditOps.Filter?

    var hasLiveAdjustments: Bool {
        liveBrightness != 0 || liveContrast != 0 || liveSaturation != 0
    }

    var hasPreviewFilter: Bool { previewFilter != nil }

    /// Image with the active preview filter and any live colour adjustments
    /// composited on top. This is what the canvas renders. The committed
    /// state in `currentImage` stays clean until the user taps Apply.
    var displayImage: CIImage? {
        guard var img = currentImage else { return nil }
        if let filter = previewFilter {
            img = PictureEditOps.apply(filter, to: img)
        }
        if hasLiveAdjustments {
            img = PictureEditOps.adjustColor(img,
                                             brightness: liveBrightness,
                                             contrast: liveContrast,
                                             saturation: liveSaturation)
        }
        return img
    }

    // MARK: - Status
    @Published var isWorking: Bool = false
    @Published var statusMessage: String?

    // MARK: - Loading

    func loadImage(from url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            statusMessage = "Couldn't read this image."
            return
        }
        let ci = CIImage(cgImage: cg)
        sourceURL = url
        sourceFormat = ConversionFormat.inferred(from: url)
        history = [ci]
        historyIndex = 0
        currentImage = ci
        resetLiveAdjustments()
        statusMessage = nil
    }

    func clear() {
        sourceURL = nil
        sourceFormat = nil
        history = []
        historyIndex = -1
        currentImage = nil
        resetLiveAdjustments()
        statusMessage = nil
    }

    private func resetLiveAdjustments() {
        liveBrightness = 0
        liveContrast = 0
        liveSaturation = 0
        previewFilter = nil
    }

    // MARK: - History management

    /// Push a freshly-mutated image. Trims any redo-tail (typical undo
    /// stack semantics: making a new edit after undo discards the redo
    /// history).
    func commit(_ image: CIImage, status: String? = nil) {
        if historyIndex >= 0 && historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(image)
        historyIndex = history.count - 1
        currentImage = image
        resetLiveAdjustments()
        if let status { statusMessage = status }
    }

    func undo() {
        guard canUndo else { return }
        historyIndex -= 1
        currentImage = history[historyIndex]
        resetLiveAdjustments()
    }

    func redo() {
        guard canRedo else { return }
        historyIndex += 1
        currentImage = history[historyIndex]
        resetLiveAdjustments()
    }

    func resetToOriginal() {
        guard !history.isEmpty else { return }
        historyIndex = 0
        currentImage = history[0]
        resetLiveAdjustments()
    }

    // MARK: - Synchronous ops

    func cropCurrent(to rect: CGRect) {
        guard let img = currentImage else { return }
        commit(PictureEditOps.crop(img, to: rect), status: "Cropped")
    }

    func rotate(byDegrees degrees: CGFloat) {
        guard let img = currentImage else { return }
        commit(PictureEditOps.rotate(img, byDegrees: degrees), status: "Rotated \(Int(degrees))°")
    }

    func flipHorizontal() {
        guard let img = currentImage else { return }
        commit(PictureEditOps.flipHorizontal(img), status: "Flipped horizontally")
    }

    func flipVertical() {
        guard let img = currentImage else { return }
        commit(PictureEditOps.flipVertical(img), status: "Flipped vertically")
    }

    func resize(scale: CGFloat) {
        guard let img = currentImage else { return }
        commit(PictureEditOps.resize(img, scale: scale), status: "Resized to \(Int(scale * 100))%")
    }

    /// Toggle a preview filter. Calling with the same filter twice clears
    /// the preview (so the user can A/B compare with the original by
    /// tapping the chip again).
    func togglePreviewFilter(_ filter: PictureEditOps.Filter) {
        if previewFilter == filter {
            previewFilter = nil
        } else {
            previewFilter = filter
        }
    }

    func clearPreviewFilter() {
        previewFilter = nil
    }

    /// Snapshot the previewed filter (and any live colour adjustments) into
    /// history. Single op so undo backs out the entire preview in one go.
    func applyPendingPreview() {
        guard hasPreviewFilter || hasLiveAdjustments,
              let img = currentImage else { return }
        var staged = img
        if let filter = previewFilter {
            staged = PictureEditOps.apply(filter, to: staged)
        }
        if hasLiveAdjustments {
            staged = PictureEditOps.adjustColor(staged,
                                                brightness: liveBrightness,
                                                contrast: liveContrast,
                                                saturation: liveSaturation)
        }
        let label: String = {
            if let f = previewFilter, hasLiveAdjustments { return "Applied \(f.displayName) + adjust" }
            if let f = previewFilter { return "Applied \(f.displayName)" }
            return "Color adjusted"
        }()
        commit(staged, status: label)
    }

    /// Convenience kept for the Adjust panel's existing Apply button.
    func commitLiveAdjustments() {
        applyPendingPreview()
    }

    func addWatermark(text: String,
                      position: PictureEditOps.WatermarkPosition,
                      opacity: CGFloat) {
        guard let img = currentImage, !text.isEmpty else { return }
        let result = PictureEditOps.watermark(img, text: text, position: position, opacity: opacity)
        commit(result, status: "Watermark added")
    }

    // MARK: - Async ops

    func removeBackground() async {
        guard let img = currentImage else { return }
        isWorking = true
        statusMessage = "Removing background…"
        defer { isWorking = false }
        do {
            let result = try await BackgroundRemoval.removeBackground(from: img)
            commit(result, status: "Background removed")
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Export

    /// Render the current image to a CGImage at full pixel resolution.
    /// Used by the export pipeline and any other consumer that needs a
    /// concrete bitmap (e.g. for clipboard copy).
    func renderCurrentCGImage() -> CGImage? {
        guard let img = displayImage ?? currentImage else { return nil }
        return context.createCGImage(img, from: img.extent)
    }

    /// Default filename for the save panel — `<stem>-edited.<ext>`.
    func defaultExportFilename(format: ConversionFormat) -> String {
        let stem = sourceURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return "\(stem)-edited.\(format.fileExtension)"
    }

    /// Write the current image to disk. Re-uses the conversion engine's
    /// quality knob for lossy formats. Returns the URL on success.
    @discardableResult
    func export(to url: URL, format: ConversionFormat, quality: Double) -> URL? {
        guard let cg = renderCurrentCGImage() else {
            statusMessage = "Nothing to export."
            return nil
        }
        let cfType = format.utiIdentifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, cfType, 1, nil) else {
            statusMessage = "Can't write to \(format.displayName) on this Mac."
            return nil
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            statusMessage = "Failed to save."
            return nil
        }
        statusMessage = "Saved \(url.lastPathComponent)"
        return url
    }

    /// Copy the current image to the clipboard as PNG (for pasting into
    /// any app that accepts pasted images).
    func copyToClipboard() {
        guard let cg = renderCurrentCGImage() else { return }
        let nsImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])
        statusMessage = "Copied to clipboard"
    }
}

#endif
