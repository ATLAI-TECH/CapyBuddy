import Foundation

/// Owns the list of jobs the archive window is showing. Mirrors
/// `ConversionQueue`: each submit spawns a detached Task that walks the
/// job through `.queued → .running → .finished/.failed`.
@MainActor
final class ArchiveQueue: ObservableObject {

    @Published private(set) var jobs: [ArchiveJob] = []

    /// Finds a sandbox-writable home for outputs. The sandbox only grants
    /// access to the dropped/picked items themselves — not to creating
    /// siblings next to them — so writing to the source folder fails for
    /// plain file drops and we fall back to a user-picked folder.
    private let outputResolver = OutputDirectoryResolver(
        bookmarkDefaultsKey: "archive.outputDirectoryBookmark",
        panelMessage: String(localized: "Choose where archives and extracted files are saved.")
    )

    /// `customOutputURL` overrides the default sibling-of-source path —
    /// used by the Save As… flow, where the user picked a custom name and
    /// folder via NSSavePanel.
    func submitCompress(
        inputs: [URL],
        format: ArchiveFormat,
        customOutputURL: URL? = nil
    ) {
        let job = ArchiveJob(operation: .compress(format: format, inputs: inputs))
        jobs.append(job)
        outputResolver.resetDeclined()
        runCompress(job: job, inputs: inputs, format: format, customOutputURL: customOutputURL)
    }

    func submitDecompress(input: URL, format: ArchiveFormat) {
        let job = ArchiveJob(operation: .decompress(format: format, input: input))
        jobs.append(job)
        outputResolver.resetDeclined()
        runDecompress(job: job, input: input, format: format)
    }

    func clearCompleted() {
        jobs.removeAll { $0.isTerminal }
    }

    // MARK: - Compress

    private func runCompress(
        job: ArchiveJob,
        inputs: [URL],
        format: ArchiveFormat,
        customOutputURL: URL?
    ) {
        // Output goes next to the first input unless the user picked their
        // own destination via Save As… (an NSSavePanel URL carries its own
        // scoped grant). The sandbox does NOT let us create siblings next to
        // a dropped file, so the resolver falls back to a user-picked output
        // folder when the source directory isn't writable.
        let outURL: URL
        var destination: WritableDirectory?
        if let custom = customOutputURL {
            outURL = ArchiveEngine.uniqued(custom)
        } else {
            destination = outputResolver.directory(for: inputs[0])
            guard let destination else {
                job.state = .failed(
                    message: String(localized: "Choose an output folder to save the archive.")
                )
                return
            }
            outURL = ArchiveEngine.defaultCompressOutputURL(
                inputs: inputs, format: format, in: destination.url
            )
        }
        job.state = .running

        Task.detached(priority: .userInitiated) {
            let result: Result<(URL, Int64, Int64), Error>
            do {
                try Self.accessingInputs(inputs) {
                    try ArchiveEngine.compress(
                        inputs: inputs, format: format, outputURL: outURL
                    )
                }
                let inBytes = Self.totalSize(of: inputs)
                let outBytes = Self.fileSize(at: outURL)
                result = .success((outURL, inBytes, outBytes))
            } catch {
                result = .failure(error)
            }
            // Keep the security-scoped output grant open until the write
            // above has finished.
            withExtendedLifetime(destination) {}
            await MainActor.run {
                Self.apply(result: result, to: job)
            }
        }
    }

    // MARK: - Decompress

    private func runDecompress(job: ArchiveJob, input: URL, format: ArchiveFormat) {
        guard let destination = outputResolver.directory(for: input) else {
            job.state = .failed(
                message: String(localized: "Choose an output folder to extract into.")
            )
            return
        }
        let outDir = ArchiveEngine.defaultDecompressOutputURL(
            input: input, in: destination.url
        )
        job.state = .running

        Task.detached(priority: .userInitiated) {
            let result: Result<(URL, Int64, Int64), Error>
            do {
                try Self.accessingInputs([input]) {
                    try ArchiveEngine.decompress(
                        input: input, format: format, outputDirectory: outDir
                    )
                }
                let inBytes = Self.fileSize(at: input)
                let outBytes = Self.totalSize(of: [outDir])
                result = .success((outDir, inBytes, outBytes))
            } catch {
                result = .failure(error)
            }
            // Keep the security-scoped output grant open until the write
            // above has finished.
            withExtendedLifetime(destination) {}
            await MainActor.run {
                Self.apply(result: result, to: job)
            }
        }
    }

    /// Open a security scope on every input that needs one for the duration
    /// of `body` (bookmark-resolved URLs); a no-op for URLs whose grant is
    /// already live (drag-ins, open-panel picks).
    nonisolated private static func accessingInputs<T>(
        _ inputs: [URL], _ body: () throws -> T
    ) rethrows -> T {
        let started = inputs.filter { $0.startAccessingSecurityScopedResource() }
        defer { started.forEach { $0.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    // MARK: - Helpers

    @MainActor
    private static func apply(result: Result<(URL, Int64, Int64), Error>, to job: ArchiveJob) {
        switch result {
        case .success(let (out, inBytes, outBytes)):
            job.state = .finished(outputURL: out, inputBytes: inBytes, outputBytes: outBytes)
        case .failure(let err):
            job.state = .failed(message: errorMessage(err))
        }
    }

    nonisolated private static func fileSize(at url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(v?.fileSize ?? 0)
    }

    /// Recursive directory size — used so decompression rows can show the
    /// extracted payload's real footprint, not just the archive size.
    nonisolated private static func totalSize(of urls: [URL]) -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                    for case let item as URL in enumerator {
                        let v = try? item.resourceValues(forKeys: [.fileSizeKey])
                        total += Int64(v?.fileSize ?? 0)
                    }
                }
            } else {
                total += fileSize(at: url)
            }
        }
        return total
    }

    static func errorMessage(_ error: Error) -> String {
        switch error {
        case ArchiveError.toolMissing(let name):
            return "Couldn't find \(name)."
        case ArchiveError.toolFailed(_, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "Archive tool failed." }
            return trimmed
        case ArchiveError.unsupportedOperation(let msg):
            return msg
        case ArchiveError.outputExists(let url):
            return "A file already exists at \(url.lastPathComponent)."
        default:
            return error.localizedDescription
        }
    }

    /// "saved 72%" / "+12%" / "no change". Mirrors ConversionQueue.savingsLabel
    /// so the row UI feels consistent.
    static func savingsLabel(inputBytes: Int64, outputBytes: Int64) -> String {
        guard inputBytes > 0 else { return "" }
        let delta = inputBytes - outputBytes
        let pct = Double(delta) / Double(inputBytes) * 100
        if abs(pct) < 0.5 { return "no change" }
        if pct > 0 { return String(format: "saved %.0f%%", pct) }
        return String(format: "+%.0f%%", -pct)
    }
}
