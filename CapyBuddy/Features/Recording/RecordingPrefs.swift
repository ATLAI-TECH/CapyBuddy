import Foundation

/// Persisted recording preferences. Most options live in Settings →
/// Recording so the inline toolbar stays a 3-button (start/pause/stop) UI
/// — per the user, "尽量简单，不要让用户配置复杂的东西，复杂的东西放到它的 settings".
enum RecordingPrefs {
    private static let defaults = UserDefaults.standard

    private static let frameRateKey       = "recording.frameRate"
    private static let codecKey           = "recording.codec"
    private static let qualityKey         = "recording.quality"
    private static let fileFormatKey      = "recording.fileFormat"
    private static let systemAudioKey     = "recording.systemAudio"
    private static let microphoneKey      = "recording.microphone"
    private static let showsCursorKey     = "recording.showsCursor"
    private static let highlightCursorKey = "recording.highlightCursor"
    private static let countdownKey       = "recording.countdownSeconds"
    private static let revealInFinderKey  = "recording.revealInFinder"
    private static let saveDirectoryKey   = "recording.saveDirectory"

    enum Codec: String, CaseIterable, Identifiable {
        case h264, hevc
        var id: String { rawValue }
        var label: String {
            switch self {
            case .h264: return "H.264"
            case .hevc: return "HEVC"
            }
        }
    }

    enum FileFormat: String, CaseIterable, Identifiable {
        case mp4, mov
        var id: String { rawValue }
        var label: String {
            switch self {
            case .mp4: return "MP4"
            case .mov: return "MOV (QuickTime)"
            }
        }
        var fileExtension: String { rawValue }
    }

    enum Quality: String, CaseIterable, Identifiable {
        case low, medium, high
        var id: String { rawValue }
        var label: String {
            switch self {
            case .low:    return "Low"
            case .medium: return "Medium"
            case .high:   return "High"
            }
        }
        /// Bitrate multiplier applied on top of the resolution-derived target.
        var multiplier: Double {
            switch self {
            case .low:    return 0.4
            case .medium: return 0.7
            case .high:   return 1.0
            }
        }
    }

    static var frameRate: Int {
        get { (defaults.object(forKey: frameRateKey) as? Int) ?? 30 }
        set { defaults.set(newValue, forKey: frameRateKey) }
    }

    static var codec: Codec {
        get { Codec(rawValue: defaults.string(forKey: codecKey) ?? "") ?? .h264 }
        set { defaults.set(newValue.rawValue, forKey: codecKey) }
    }

    static var fileFormat: FileFormat {
        get { FileFormat(rawValue: defaults.string(forKey: fileFormatKey) ?? "") ?? .mp4 }
        set { defaults.set(newValue.rawValue, forKey: fileFormatKey) }
    }

    static var quality: Quality {
        get { Quality(rawValue: defaults.string(forKey: qualityKey) ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: qualityKey) }
    }

    static var captureSystemAudio: Bool {
        get {
            if defaults.object(forKey: systemAudioKey) == nil { return true }
            return defaults.bool(forKey: systemAudioKey)
        }
        set { defaults.set(newValue, forKey: systemAudioKey) }
    }

    static var captureMicrophone: Bool {
        get { defaults.bool(forKey: microphoneKey) }
        set { defaults.set(newValue, forKey: microphoneKey) }
    }

    static var showsCursor: Bool {
        get {
            if defaults.object(forKey: showsCursorKey) == nil { return true }
            return defaults.bool(forKey: showsCursorKey)
        }
        set { defaults.set(newValue, forKey: showsCursorKey) }
    }

    static var highlightCursor: Bool {
        get { defaults.bool(forKey: highlightCursorKey) }
        set { defaults.set(newValue, forKey: highlightCursorKey) }
    }

    /// Seconds of "3-2-1" countdown shown before the engine actually
    /// starts. `0` means "begin immediately".
    static var countdownSeconds: Int {
        get {
            if defaults.object(forKey: countdownKey) == nil { return 3 }
            return defaults.integer(forKey: countdownKey)
        }
        set { defaults.set(newValue, forKey: countdownKey) }
    }

    /// When `true`, the manager automatically reveals the finished file in
    /// Finder. Off by default so we don't yank focus away from whatever
    /// the user was doing post-recording.
    static var revealInFinder: Bool {
        get {
            if defaults.object(forKey: revealInFinderKey) == nil { return false }
            return defaults.bool(forKey: revealInFinderKey)
        }
        set { defaults.set(newValue, forKey: revealInFinderKey) }
    }

    static var saveDirectory: URL {
        get {
            if let path = defaults.string(forKey: saveDirectoryKey),
               !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            return movies.appendingPathComponent("CapyBuddy", isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: saveDirectoryKey) }
    }

    /// Builds (and creates if needed) the destination path for a new
    /// recording. Filename: `CapyBuddy YYYY-MM-DD at HH.MM.SS.<ext>`, with a
    /// ` (n)` suffix appended on collision (rare — two recordings in the
    /// same second — but cheap to defend against).
    static func makeOutputURL() throws -> URL {
        let dir = saveDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "CapyBuddy \(formatter.string(from: Date()))"
        let ext = fileFormat.fileExtension
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// Rough free-space estimate for the save directory in bytes. Returns
    /// nil if the volume can't be read.
    static func freeSpaceBytes() -> Int64? {
        let path = saveDirectory.path
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber else {
            return nil
        }
        return free.int64Value
    }
}
