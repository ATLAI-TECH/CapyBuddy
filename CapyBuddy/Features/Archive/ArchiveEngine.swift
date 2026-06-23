import Foundation

enum ArchiveError: Error, Equatable {
    case toolMissing(String)
    case toolFailed(exitCode: Int32, stderr: String)
    case unsupportedOperation(String)
    case outputExists(URL)
}

/// Stateless wrapper around the system archive CLIs. Every job spawns a
/// `Process`, waits for it to exit, and reports success/failure as a single
/// transition — same shape as `ConversionEngine`. Sandbox-safe: the user
/// must have granted access to both the source and the destination (which
/// is true by construction since they came from a drag-in URL or its
/// containing directory).
enum ArchiveEngine {

    // MARK: - Public entry points

    /// Compress one or more inputs into a single archive at `outputURL`.
    /// For multi-file zip/tar/tar.gz/7z the archive contains each item at
    /// the top level. For `gz` exactly one input is required (gz is a
    /// stream compressor, not a container).
    static func compress(
        inputs: [URL],
        format: ArchiveFormat,
        outputURL: URL
    ) throws {
        guard !inputs.isEmpty else {
            throw ArchiveError.unsupportedOperation("Nothing to compress.")
        }

        try ensureNotExists(outputURL)

        switch format {
        case .zip:
            try compressZip(inputs: inputs, output: outputURL)
        case .tar:
            try compressTar(inputs: inputs, output: outputURL, gzip: false)
        case .tarGz:
            try compressTar(inputs: inputs, output: outputURL, gzip: true)
        case .gz:
            guard inputs.count == 1, !isDirectory(inputs[0]) else {
                throw ArchiveError.unsupportedOperation(
                    "gz only handles a single file. Pick tar.gz for folders or multiple files."
                )
            }
            try compressGz(input: inputs[0], output: outputURL)
        }
    }

    /// Extract `inputURL` into `outputDirectory`. The directory is created
    /// if missing. The format is inferred from the file extension; the
    /// caller can pass `format` explicitly for the magic-byte-detection
    /// path if we ever add it.
    static func decompress(
        input inputURL: URL,
        format: ArchiveFormat,
        outputDirectory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )

        switch format {
        case .zip:
            try decompressZip(input: inputURL, outputDir: outputDirectory)
        case .tar, .tarGz:
            try decompressTar(input: inputURL, outputDir: outputDirectory)
        case .gz:
            try decompressGz(input: inputURL, outputDir: outputDirectory)
        }
    }

    // MARK: - Compress implementations

    /// Use `ditto` because it produces the same `.zip` Finder makes (resource
    /// forks sequestered into `__MACOSX`, parent directory preserved). For
    /// multi-input we stage a temp folder so the archive holds each item at
    /// its own top-level entry — ditto only takes one source argument.
    private static func compressZip(inputs: [URL], output: URL) throws {
        if inputs.count == 1 {
            try run("/usr/bin/ditto", [
                "-c", "-k",
                "--sequesterRsrc",
                "--keepParent",
                inputs[0].path,
                output.path,
            ])
        } else {
            try withMultiInputStaging(inputs) { stagingDir in
                try run("/usr/bin/ditto", [
                    "-c", "-k",
                    "--sequesterRsrc",
                    stagingDir.path,
                    output.path,
                ])
            }
        }
    }

    private static func compressTar(inputs: [URL], output: URL, gzip: Bool) throws {
        // `tar -C parent name1 name2 …` writes each entry relative to its
        // parent, which is what users expect (no leading absolute path
        // inside the archive). When inputs come from different parents we
        // stage them into one folder first.
        let flags = gzip ? "-czf" : "-cf"

        if let commonParent = sharedParent(of: inputs) {
            var args = [flags, output.path, "-C", commonParent.path]
            for url in inputs { args.append(url.lastPathComponent) }
            try run("/usr/bin/tar", args)
        } else {
            try withMultiInputStaging(inputs) { stagingDir in
                let parent = stagingDir.deletingLastPathComponent()
                let name = stagingDir.lastPathComponent
                try run("/usr/bin/tar", [flags, output.path, "-C", parent.path, name])
            }
        }
    }

    private static func compressGz(input: URL, output: URL) throws {
        // gzip writes to stdout with -c so we can pick our own destination
        // name. (`gzip foo.txt` would overwrite the source's location.)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", input.path]

        let outHandle = try openForWriting(output)
        process.standardOutput = outHandle
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()
        try? outHandle.close()

        if process.terminationStatus != 0 {
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            throw ArchiveError.toolFailed(exitCode: process.terminationStatus, stderr: err)
        }
    }

    // MARK: - Decompress implementations

    private static func decompressZip(input: URL, outputDir: URL) throws {
        // `ditto -x -k` is the inverse of the compress path above. Handles
        // every zip ditto can produce, including ones with __MACOSX.
        try run("/usr/bin/ditto", [
            "-x", "-k",
            input.path,
            outputDir.path,
        ])
    }

    private static func decompressTar(input: URL, outputDir: URL) throws {
        // tar autodetects gzip/bzip2/xz from the magic header — no need to
        // branch on `.tar` vs `.tar.gz` here.
        try run("/usr/bin/tar", [
            "-xf", input.path,
            "-C", outputDir.path,
        ])
    }

    private static func decompressGz(input: URL, outputDir: URL) throws {
        // Strip the trailing `.gz` for the output file. If the input was
        // `foo.txt.gz` we write `foo.txt`. Files with no inner extension
        // (`foo.gz`) get an empty extension, which the dedup helper fixes.
        let baseName = input.deletingPathExtension().lastPathComponent
        let target = ArchiveEngine.uniqued(outputDir.appendingPathComponent(baseName))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", input.path]

        let outHandle = try openForWriting(target)
        process.standardOutput = outHandle
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()
        try? outHandle.close()

        if process.terminationStatus != 0 {
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            throw ArchiveError.toolFailed(exitCode: process.terminationStatus, stderr: err)
        }
    }

    // MARK: - Output naming

    /// Pick a sibling output filename for `compress`. Uses a timestamped
    /// "Compressed YYYY-MM-DD at HH.MM.SS.ext" name (matching the screenshot
    /// feature's save-default pattern), since picking a stem from one input
    /// is misleading when the archive contains several files. Users who want
    /// a meaningful name use the Save As… button.
    static func defaultCompressOutputURL(
        inputs: [URL],
        format: ArchiveFormat,
        in directory: URL
    ) -> URL {
        let candidate = directory.appendingPathComponent(
            "\(defaultCompressStem()).\(format.fileExtension)"
        )
        return uniqued(candidate)
    }

    /// Filename stem (no extension) for a fresh archive. Public so the UI
    /// can pre-fill an `NSSavePanel` with the same name.
    static func defaultCompressStem(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Compressed \(f.string(from: date))"
    }

    /// Pick a sibling output directory for `decompress`. Same stem as the
    /// archive (minus `.zip` / `.tar.gz` / etc), deduped if needed.
    static func defaultDecompressOutputURL(
        input: URL,
        in directory: URL
    ) -> URL {
        let stem = input.lastPathComponent.removingArchiveSuffix()
        return uniqued(directory.appendingPathComponent(stem))
    }

    static func uniqued(_ url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = ext.isEmpty
            ? url.lastPathComponent
            : url.deletingPathExtension().lastPathComponent
        var i = 1
        while true {
            let name = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    // MARK: - Process plumbing

    private static func run(_ executablePath: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        do {
            try process.run()
        } catch {
            throw ArchiveError.toolMissing(executablePath)
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            throw ArchiveError.toolFailed(exitCode: process.terminationStatus, stderr: err)
        }
    }

    /// Open `url` for writing as a `FileHandle`, creating it fresh. Caller
    /// owns the handle and must close it after the process exits.
    private static func openForWriting(_ url: URL) throws -> FileHandle {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        return try FileHandle(forWritingTo: url)
    }

    private static func ensureNotExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw ArchiveError.outputExists(url)
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Return the common parent directory if every input lives directly
    /// inside the same folder. Used by `compressTar` to pick a `-C` so
    /// archive entries are stored relative to that folder.
    private static func sharedParent(of inputs: [URL]) -> URL? {
        guard let first = inputs.first else { return nil }
        let parent = first.deletingLastPathComponent()
        for url in inputs.dropFirst() where url.deletingLastPathComponent() != parent {
            return nil
        }
        return parent
    }

    /// Copy every input into a fresh temp folder and hand the folder to
    /// `body`. Used when archive tooling expects a single source argument
    /// (ditto) or when the user dragged in files from disparate locations.
    private static func withMultiInputStaging(
        _ inputs: [URL],
        _ body: (URL) throws -> Void
    ) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(
            "capybuddy-archive-\(UUID().uuidString)"
        )
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        for url in inputs {
            // Same-named inputs from different folders would collide in the
            // flat staging dir — dedupe with the usual " (1)" suffix.
            let dest = uniqued(staging.appendingPathComponent(url.lastPathComponent))
            try fm.copyItem(at: url, to: dest)
        }
        try body(staging)
    }

}

private extension String {
    /// Strip a single trailing archive extension (`.zip`, `.tar.gz`, `.tgz`,
    /// `.tar`, `.gz`) so we can derive a clean stem for output paths.
    func removingArchiveSuffix() -> String {
        let lower = self.lowercased()
        for suffix in [".tar.gz", ".tgz", ".tar", ".zip", ".gz"] {
            if lower.hasSuffix(suffix) {
                return String(self.dropLast(suffix.count))
            }
        }
        return self
    }
}
