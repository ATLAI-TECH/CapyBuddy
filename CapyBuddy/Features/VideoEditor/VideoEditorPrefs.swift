import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Persisted preferences for the Video Editor feature. Mirrors the
/// `RecordingPrefs` shape — the editor window itself stays simple
/// (play / trim / crop / export); everything configurable lives here so
/// Settings → Video Editor is the one place to tweak defaults.
enum VideoEditorPrefs {
    private static let defaults = UserDefaults.standard

    private static let openAfterRecordingKey = "videoEditor.openAfterRecording"
    private static let exportFormatKey        = "videoEditor.exportFormat"
    private static let exportQualityKey       = "videoEditor.exportQuality"
    private static let revealInFinderKey      = "videoEditor.revealInFinder"

    /// Output container + codec. `AVAssetExportSession` only writes the
    /// QuickTime container family (mov / mp4 / m4v); GIF is produced through
    /// a separate `CGImageDestination` path.
    enum ExportFormat: String, CaseIterable, Identifiable {
        case mp4H264   // .mp4, H.264 — the safe default
        case mp4HEVC   // .mp4, HEVC (H.265) — smaller files, newer decoders
        case movH264   // .mov, H.264 — QuickTime-native
        case m4v       // .m4v, H.264 — Apple TV / iTunes flavour
        case gif       // animated GIF

        var id: String { rawValue }

        var label: String {
            switch self {
            case .mp4H264: return "MP4 · H.264"
            case .mp4HEVC: return "MP4 · HEVC (H.265)"
            case .movH264: return "MOV · H.264 (QuickTime)"
            case .m4v:     return "M4V · H.264"
            case .gif:     return "Animated GIF"
            }
        }

        var fileExtension: String {
            switch self {
            case .mp4H264, .mp4HEVC: return "mp4"
            case .movH264:           return "mov"
            case .m4v:               return "m4v"
            case .gif:               return "gif"
            }
        }

        /// `AVFileType` for the export session, or `nil` for GIF (handled
        /// outside `AVAssetExportSession`).
        var avFileType: AVFileType? {
            switch self {
            case .mp4H264, .mp4HEVC: return .mp4
            case .movH264:           return .mov
            case .m4v:               return .m4v
            case .gif:               return nil
            }
        }

        var usesHEVC: Bool { self == .mp4HEVC }
        var isGIF: Bool { self == .gif }

        var contentType: UTType {
            switch self {
            case .gif: return .gif
            default:   return UTType(filenameExtension: fileExtension) ?? .movie
            }
        }
    }

    enum ExportQuality: String, CaseIterable, Identifiable {
        case p720, p1080, source
        var id: String { rawValue }
        var label: String {
            switch self {
            case .p720:   return "720p"
            case .p1080:  return "1080p"
            case .source: return "Source resolution"
            }
        }
        /// `AVAssetExportSession` preset name. All of these are compatible
        /// with an attached `AVVideoComposition` (unlike `Passthrough`).
        /// HEVC ships fewer fixed-size presets, so 720p falls back to the
        /// 1080p HEVC preset.
        func presetName(hevc: Bool) -> String {
            if hevc {
                switch self {
                case .p720, .p1080: return AVAssetExportPresetHEVC1920x1080
                case .source:       return AVAssetExportPresetHEVCHighestQuality
                }
            }
            switch self {
            case .p720:   return AVAssetExportPreset1280x720
            case .p1080:  return AVAssetExportPreset1920x1080
            case .source: return AVAssetExportPresetHighestQuality
            }
        }
    }

    /// When `true`, finishing a screen recording pops the new clip straight
    /// into the editor so the user can trim / crop before sharing. On by
    /// default — the editor is the natural next step after recording.
    static var openAfterRecording: Bool {
        get {
            if defaults.object(forKey: openAfterRecordingKey) == nil { return true }
            return defaults.bool(forKey: openAfterRecordingKey)
        }
        set { defaults.set(newValue, forKey: openAfterRecordingKey) }
    }

    static var exportFormat: ExportFormat {
        get { ExportFormat(rawValue: defaults.string(forKey: exportFormatKey) ?? "") ?? .mp4H264 }
        set { defaults.set(newValue.rawValue, forKey: exportFormatKey) }
    }

    static var exportQuality: ExportQuality {
        get { ExportQuality(rawValue: defaults.string(forKey: exportQualityKey) ?? "") ?? .source }
        set { defaults.set(newValue.rawValue, forKey: exportQualityKey) }
    }

    /// Reveal the exported file in Finder when the export finishes.
    /// Off by default so we don't yank focus away after every export.
    static var revealInFinder: Bool {
        get {
            if defaults.object(forKey: revealInFinderKey) == nil { return false }
            return defaults.bool(forKey: revealInFinderKey)
        }
        set { defaults.set(newValue, forKey: revealInFinderKey) }
    }
}
