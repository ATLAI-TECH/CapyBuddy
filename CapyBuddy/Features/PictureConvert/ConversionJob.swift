import Foundation

/// Per-file unit of work for the converter window. Owns its own state so
/// the SwiftUI list can observe each row independently — the queue's
/// `@Published jobs` only changes when items are added or removed.
@MainActor
final class ConversionJob: ObservableObject, Identifiable {

    enum State: Equatable {
        case queued
        /// Image conversion is too fast to drive a real progress bar, so
        /// the UI shows an indeterminate animation while in this state.
        case running
        case finished(outputURL: URL, inputBytes: Int64, outputBytes: Int64)
        case failed(message: String)
    }

    let id = UUID()
    let inputURL: URL
    let targetFormat: ConversionFormat

    @Published var state: State = .queued

    init(inputURL: URL, targetFormat: ConversionFormat) {
        self.inputURL = inputURL
        self.targetFormat = targetFormat
    }

    var displayName: String { inputURL.lastPathComponent }

    var isTerminal: Bool {
        switch state {
        case .finished, .failed: return true
        case .queued, .running:  return false
        }
    }
}
