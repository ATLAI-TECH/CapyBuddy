import Foundation

/// One compress or decompress unit of work. Owns its own `@Published state`
/// so each row in the UI re-renders independently — same shape as
/// `ConversionJob`.
@MainActor
final class ArchiveJob: ObservableObject, Identifiable {

    enum Operation: Equatable {
        case compress(format: ArchiveFormat, inputs: [URL])
        case decompress(format: ArchiveFormat, input: URL)
    }

    enum State: Equatable {
        case queued
        /// Archive ops are bounded by I/O; we don't drive a determinate bar
        /// (would need to inspect the tool's stderr) — show indeterminate.
        case running
        case finished(outputURL: URL, inputBytes: Int64, outputBytes: Int64)
        case failed(message: String)
    }

    let id = UUID()
    let operation: Operation

    @Published var state: State = .queued

    init(operation: Operation) {
        self.operation = operation
    }

    /// Short label for the row title — uses the primary input's filename
    /// for both directions.
    var displayName: String {
        switch operation {
        case .compress(_, let inputs):
            if inputs.count == 1 { return inputs[0].lastPathComponent }
            return "\(inputs[0].lastPathComponent) +\(inputs.count - 1)"
        case .decompress(_, let input):
            return input.lastPathComponent
        }
    }

    var isCompress: Bool {
        if case .compress = operation { return true }
        return false
    }

    var format: ArchiveFormat {
        switch operation {
        case .compress(let f, _): return f
        case .decompress(let f, _): return f
        }
    }

    var isTerminal: Bool {
        switch state {
        case .finished, .failed: return true
        case .queued, .running: return false
        }
    }
}
