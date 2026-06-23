import Foundation

/// Owns the list of jobs the converter window is showing. Submitting a
/// URL appends a job and kicks off conversion on a detached task; the job
/// transitions through `.queued` → `.running` → `.finished` / `.failed`
/// and the row in the UI re-renders from its own `@Published state`.
@MainActor
final class ConversionQueue: ObservableObject {

    @Published private(set) var jobs: [ConversionJob] = []

    /// Where converted files land. Default is the source file's own
    /// directory (set per-job at submit time). The window can override
    /// this if we ever add an output-folder picker.
    var outputDirectoryOverride: URL?

    /// Finds a sandbox-writable home for outputs. The sandbox only grants
    /// access to the dropped/picked files themselves — not to creating
    /// siblings next to them — so writing to the source folder fails for
    /// plain file drops and we fall back to a user-picked folder.
    private let outputResolver = OutputDirectoryResolver(
        bookmarkDefaultsKey: "pictureConvert.outputDirectoryBookmark",
        panelMessage: String(localized: "Choose where converted images are saved.")
    )

    /// Output paths promised to in-flight jobs. Two same-named inputs
    /// submitted together would otherwise both pass the on-disk uniqueness
    /// check and race to write the same file.
    private var reservedOutputPaths: Set<String> = []

    func submit(urls: [URL], targetFormat: ConversionFormat) {
        outputResolver.resetDeclined()
        for url in urls {
            let job = ConversionJob(inputURL: url, targetFormat: targetFormat)
            jobs.append(job)
            run(job: job)
        }
    }

    func clearCompleted() {
        jobs.removeAll { $0.isTerminal }
    }

    /// Used by tests to wait for the in-flight job to settle. Real UI
    /// doesn't call this — it observes `job.state` instead.
    func waitForAllJobs() async {
        while jobs.contains(where: { !$0.isTerminal }) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Internals

    private func run(job: ConversionJob) {
        let input = job.inputURL
        let format = job.targetFormat

        let destination: WritableDirectory?
        if let override = outputDirectoryOverride {
            destination = WritableDirectory(url: override, isSecurityScoped: false)
        } else {
            destination = outputResolver.directory(for: input)
        }
        guard let destination else {
            job.state = .failed(
                message: String(localized: "Choose an output folder to save converted files.")
            )
            return
        }
        let outURL = ConversionEngine.defaultOutputURL(
            for: input, targetFormat: format, in: destination.url,
            avoiding: reservedOutputPaths
        )
        reservedOutputPaths.insert(outURL.path)

        job.state = .running

        Task.detached(priority: .userInitiated) {
            let result: Result<(URL, Int64, Int64), Error>
            do {
                try input.accessingSecurityScopedResource {
                    try ConversionEngine.convertImage(
                        inputURL: input,
                        outputURL: outURL,
                        targetFormat: format
                    )
                }
                let inSize = Self.fileSize(at: input)
                let outSize = Self.fileSize(at: outURL)
                result = .success((outURL, inSize, outSize))
            } catch {
                result = .failure(error)
            }
            // Keep the security-scoped output grant open until the write
            // above has finished.
            withExtendedLifetime(destination) {}

            await MainActor.run {
                switch result {
                case .success(let (out, inBytes, outBytes)):
                    job.state = .finished(
                        outputURL: out,
                        inputBytes: inBytes,
                        outputBytes: outBytes
                    )
                case .failure(let err):
                    job.state = .failed(message: Self.errorMessage(err))
                }
            }
        }
    }

    nonisolated private static func fileSize(at url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(v?.fileSize ?? 0)
    }

    /// Friendly message for `ConversionError`; falls back to the system
    /// description for anything else.
    static func errorMessage(_ error: Error) -> String {
        switch error {
        case ConversionError.unreadableSource:
            return "Couldn't read this file."
        case ConversionError.unsupportedTarget:
            return "Can't write to this format on your system."
        case ConversionError.writeFailed:
            return "Failed to save the converted file."
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Formatting helpers (also exercised by tests)

    /// "Saved 72%" / "+12%" / "no change". Positive numbers mean the
    /// output is smaller than the input.
    static func savingsLabel(inputBytes: Int64, outputBytes: Int64) -> String {
        guard inputBytes > 0 else { return "" }
        let delta = inputBytes - outputBytes
        let pct = Double(delta) / Double(inputBytes) * 100
        if abs(pct) < 0.5 { return "no change" }
        if pct > 0 { return String(format: "saved %.0f%%", pct) }
        return String(format: "+%.0f%%", -pct)
    }
}
