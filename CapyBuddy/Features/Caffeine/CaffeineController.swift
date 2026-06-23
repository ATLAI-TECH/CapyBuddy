import Foundation
import Combine

@MainActor
final class CaffeineController: ObservableObject {

    enum State: Equatable {
        case inactive
        case activeIndefinite
        case activeUntil(Date)
    }

    @Published private(set) var state: State = .inactive
    @Published var preventDisplaySleep: Bool

    private let holder: PowerAssertionHolder
    private let clock: () -> Date
    private var timer: Timer?
    private var displaySleepObservation: AnyCancellable?

    init(
        holder: PowerAssertionHolder,
        preventDisplaySleep: Bool = false,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.holder = holder
        self.preventDisplaySleep = preventDisplaySleep
        self.clock = clock

        // If the user flips the "prevent display sleep" toggle while the
        // assertion is already held, the assertion TYPE doesn't change
        // automatically — IOKit only reads it at acquire time. Release and
        // re-acquire so the new mode takes effect immediately.
        displaySleepObservation = $preventDisplaySleep
            .dropFirst()
            .sink { [weak self] new in
                guard let self, self.holder.isHeld else { return }
                self.holder.release()
                try? self.holder.acquire(preventDisplaySleep: new)
            }
    }

    var isActive: Bool { state != .inactive }

    var remainingTime: TimeInterval? {
        guard case .activeUntil(let until) = state else { return nil }
        return max(0, until.timeIntervalSince(clock()))
    }

    /// `duration == nil` keeps the Mac awake until the user toggles Caffeine
    /// off. A finite duration arms a one-shot timer that calls `expire()`.
    func activate(duration: TimeInterval?) {
        if holder.isHeld { holder.release() }
        do {
            try holder.acquire(preventDisplaySleep: preventDisplaySleep)
        } catch {
            state = .inactive
            return
        }

        timer?.invalidate()
        if let duration {
            state = .activeUntil(clock().addingTimeInterval(duration))
            timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.expire() }
            }
        } else {
            state = .activeIndefinite
            timer = nil
        }
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
        if holder.isHeld { holder.release() }
        state = .inactive
    }

    /// Called by the duration timer when it elapses. Exposed at `internal`
    /// scope so unit tests can simulate expiry without sleeping.
    func expire() {
        deactivate()
    }
}
