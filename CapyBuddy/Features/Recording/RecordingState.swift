import Foundation
import Observation

/// Source-of-truth state model for an in-progress recording. Owned by
/// `RecordingManager`; observed by the toolbar panel to drive the
/// start/pause/resume/stop button state and the elapsed-time label.
@Observable
@MainActor
final class RecordingState {
    enum Phase: Equatable {
        case idle
        case counting     // 3-2-1 countdown before .preparing
        case preparing
        case recording
        case paused
        case stopping
    }

    var phase: Phase = .idle
    /// Target the manager is currently driving. Used by the overlay
    /// controller to know which screen / region to draw the frame
    /// around. nil while idle.
    var activeTarget: RecordingTarget?
    var outputURL: URL?
    /// Absolute wall-clock time the recording started. `nil` while idle.
    /// Resetting on resume would make the elapsed counter jump backwards;
    /// instead we track paused-out time separately and compute
    /// `elapsedSeconds` as `now - startedAt - pausedDuration`.
    var startedAt: Date?
    /// Total seconds the recording has spent in `.paused`. Frozen on resume
    /// so subsequent ticks subtract a fixed amount.
    var pausedDuration: TimeInterval = 0
    /// When the current pause began. nil while not paused.
    var pauseStartedAt: Date?
    /// Seconds left on the pre-record countdown. Driven by RecordingManager.
    var countdownRemaining: Int = 0

    /// Bumped twice a second by `RecordingManager`'s ticker. Reading
    /// `elapsedSeconds` indirectly observes this via the @Observable
    /// dependency tracker, so a mutation here forces SwiftUI views that
    /// display elapsed time to redraw.
    var tickCounter: Int = 0

    var elapsedSeconds: TimeInterval {
        _ = tickCounter // observed dependency
        guard let startedAt else { return 0 }
        let extraPaused: TimeInterval
        if let pauseStartedAt {
            extraPaused = Date().timeIntervalSince(pauseStartedAt)
        } else {
            extraPaused = 0
        }
        return Date().timeIntervalSince(startedAt) - pausedDuration - extraPaused
    }

    func reset() {
        phase = .idle
        activeTarget = nil
        outputURL = nil
        startedAt = nil
        pausedDuration = 0
        pauseStartedAt = nil
        countdownRemaining = 0
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
