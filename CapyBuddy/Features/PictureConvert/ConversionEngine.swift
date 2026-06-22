import Foundation
import ImageIO
import CoreGraphics

enum ConversionError: Error, Equatable {
    case unreadableSource
    case unsupportedTarget
    case writeFailed
}

/// Stateless ImageIO-based converter. Image conversion on a modern Mac is
/// fast enough (tens of ms for a 4K photo) that there is no value in
/// streaming progress; the queue runs each job on a background actor and
/// reports completion as a single transition.
enum ConversionEngine {

    /// Read every image frame in `inputURL` and re-encode them as
    /// `targetFormat` at `outputURL`. Multi-frame inputs (animated GIF) are
    /// preserved frame-by-frame when the target supports them.
    ///
    /// - Parameter quality: 0...1, used for lossy formats (JPEG/HEIC/WebP)
    ///   and ignored otherwise.
    static func convertImage(
        inputURL: URL,
        outputURL: URL,
        targetFormat: ConversionFormat,
        quality: Double = 0.9
    ) throws {
        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.unreadableSource
        }

        // Single-frame targets get exactly frame 0 — an animated GIF's
        // full frame list with a JPEG/HEIC destination fails Finalize.
        let sourceFrames = CGImageSourceGetCount(source)
        let frameCount = targetFormat.supportsMultipleFrames ? sourceFrames : 1
        let cfType = targetFormat.utiIdentifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(
            outputURL as CFURL, cfType, frameCount, nil
        ) else {
            throw ConversionError.unsupportedTarget
        }

        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        for i in 0..<frameCount {
            CGImageDestinationAddImageFromSource(dest, source, i, opts as CFDictionary)
        }

        if !CGImageDestinationFinalize(dest) {
            throw ConversionError.writeFailed
        }
    }

    // MARK: - Output naming

    /// Build a sibling filename for the converted file. If the target
    /// extension matches the input's (user picked the same format), append
    /// `-converted` so the original isn't clobbered. If the resulting path
    /// already exists, deduplicate with a `(1)`, `(2)`, … suffix.
    /// `avoiding` holds output paths already promised to in-flight jobs —
    /// the on-disk existence check alone can't see a sibling job that
    /// picked the same name but hasn't written its file yet.
    static func defaultOutputURL(
        for inputURL: URL,
        targetFormat: ConversionFormat,
        in directory: URL,
        avoiding reserved: Set<String> = []
    ) -> URL {
        let stem = inputURL.deletingPathExtension().lastPathComponent
        let ext = targetFormat.fileExtension
        let suffix = (inputURL.pathExtension.lowercased() == ext) ? "-converted" : ""
        let candidate = directory.appendingPathComponent("\(stem)\(suffix).\(ext)")
        return uniqued(candidate, avoiding: reserved)
    }

    /// If `url` already exists on disk (or is reserved by another job),
    /// return `<stem> (1).<ext>`, `<stem> (2).<ext>`, … until a free path
    /// is found.
    static func uniqued(_ url: URL, avoiding reserved: Set<String> = []) -> URL {
        let fm = FileManager.default
        let taken = { (path: String) in
            fm.fileExists(atPath: path) || reserved.contains(path)
        }
        if !taken(url.path) { return url }
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 1
        while true {
            let candidate = dir.appendingPathComponent("\(stem) (\(i)).\(ext)")
            if !taken(candidate.path) { return candidate }
            i += 1
        }
    }
}
