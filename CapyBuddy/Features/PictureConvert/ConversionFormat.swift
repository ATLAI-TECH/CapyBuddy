import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One of the image formats CapyBuddy can read (and usually write) via
/// ImageIO. AVIF stands in as the modern lossy/lossless target.
///
/// WebP is read-only on macOS — ImageIO decodes it but most macOS
/// versions can't encode it. It's still listed so users can pick WebP
/// files as a *source* and convert them out; the runtime
/// `writableOnThisSystem` filter at the bottom drops it from the target
/// list whenever the active macOS can't actually write it.
///
/// ICO / BMP / ICNS / JPEG2000 added in v2: ImageIO advertises them in
/// `CGImageDestinationCopyTypeIdentifiers()` on macOS 26, and the same
/// runtime filter transparently drops any the active macOS doesn't support.
enum ConversionFormat: String, CaseIterable, Identifiable, Hashable {
    case png
    case jpeg
    case heic
    case tiff
    case gif
    case avif
    case webp
    case ico
    case bmp
    case icns
    case jpeg2000

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .png:      return "PNG"
        case .jpeg:     return "JPEG"
        case .heic:     return "HEIC"
        case .tiff:     return "TIFF"
        case .gif:      return "GIF"
        case .avif:     return "AVIF"
        case .webp:     return "WebP"
        case .ico:      return "ICO"
        case .bmp:      return "BMP"
        case .icns:     return "ICNS"
        case .jpeg2000: return "JP2"
        }
    }

    /// File extension used when writing. Lower-cased; no leading dot.
    var fileExtension: String {
        switch self {
        case .png:      return "png"
        case .jpeg:     return "jpg"
        case .heic:     return "heic"
        case .tiff:     return "tiff"
        case .gif:      return "gif"
        case .avif:     return "avif"
        case .webp:     return "webp"
        case .ico:      return "ico"
        case .bmp:      return "bmp"
        case .icns:     return "icns"
        case .jpeg2000: return "jp2"
        }
    }

    /// UTI string passed to ImageIO for both reading and writing.
    var utiIdentifier: String {
        switch self {
        case .png:      return "public.png"
        case .jpeg:     return "public.jpeg"
        case .heic:     return "public.heic"
        case .tiff:     return "public.tiff"
        case .gif:      return "com.compuserve.gif"
        case .avif:     return "public.avif"
        case .webp:     return "org.webmproject.webp"
        case .ico:      return "com.microsoft.ico"
        case .bmp:      return "com.microsoft.bmp"
        case .icns:     return "com.apple.icns"
        case .jpeg2000: return "public.jpeg-2000"
        }
    }

    /// Whether quality tuning has any effect for this format. Used by the
    /// UI to gray out the slider for lossless targets.
    var isLossy: Bool {
        switch self {
        case .jpeg, .heic, .avif, .webp, .jpeg2000: return true
        case .png, .tiff, .gif, .ico, .bmp, .icns: return false
        }
    }

    /// Targets that can hold more than one frame/page. Animated sources
    /// (GIF) keep every frame for these — PNG becomes APNG, TIFF goes
    /// multi-page. Every other target takes frame 0 only; handing ImageIO
    /// a multi-frame list with a JPEG/HEIC destination makes Finalize fail.
    var supportsMultipleFrames: Bool {
        switch self {
        case .gif, .tiff, .png: return true
        case .jpeg, .heic, .avif, .webp, .ico, .bmp, .icns, .jpeg2000: return false
        }
    }

    /// Best-effort identification of a file's format from its extension.
    /// Returns `nil` for anything we can't recognize.
    static func inferred(from url: URL) -> ConversionFormat? {
        switch url.pathExtension.lowercased() {
        case "png":               return .png
        case "jpg", "jpeg":       return .jpeg
        case "heic", "heif":      return .heic
        case "tif", "tiff":       return .tiff
        case "gif":               return .gif
        case "avif":              return .avif
        case "webp":              return .webp
        case "ico":               return .ico
        case "bmp":               return .bmp
        case "icns":              return .icns
        case "jp2", "jpf", "jpx": return .jpeg2000
        default:                  return nil
        }
    }

    /// Subset of `allCases` that the running system can actually write.
    /// Computed once at process start by querying ImageIO. The UI binds
    /// to this so we never offer a target that ImageIO would reject.
    static let writableOnThisSystem: [ConversionFormat] = {
        let supported = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return allCases.filter { supported.contains($0.utiIdentifier) }
    }()
}
