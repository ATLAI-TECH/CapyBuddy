import Foundation

/// Archive formats the Archive feature can read and write. All four shell
/// out to stock macOS binaries (`/usr/bin/ditto`, `/usr/bin/tar`,
/// `/usr/bin/gzip`) — no third-party tooling, sandbox-safe.
enum ArchiveFormat: String, CaseIterable, Identifiable {
    case zip
    case tar
    case tarGz
    case gz

    var id: String { rawValue }

    /// Primary file extension used when WRITING this format. For tar.gz we
    /// keep the compound extension so the resulting file plays nicely with
    /// double-click extractors and `file` heuristics.
    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .tar: return "tar"
        case .tarGz: return "tar.gz"
        case .gz: return "gz"
        }
    }

    /// Short human label for menus.
    var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .tar: return "TAR"
        case .tarGz: return "TAR.GZ"
        case .gz: return "GZ"
        }
    }

    /// `gz` is a stream compressor — it only handles a single file, never a
    /// directory. The UI uses this to fall back to `tar.gz` when the user
    /// drops a folder and picks gz.
    var supportsDirectories: Bool {
        switch self {
        case .gz: return false
        default: return true
        }
    }

    // MARK: - Detection

    /// Best-guess archive format for a URL, based on file extension. Returns
    /// `nil` for non-archives — the caller treats `nil` as "this looks like a
    /// payload to compress, not an archive to extract."
    static func detect(from url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        // tar.gz / tgz must be checked BEFORE plain .gz, since the suffix
        // `.gz` also matches at the end of `.tar.gz`. Order matters.
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGz }
        if name.hasSuffix(".tar") { return .tar }
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".gz") { return .gz }
        return nil
    }
}
