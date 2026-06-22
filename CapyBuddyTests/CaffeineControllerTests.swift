import XCTest
@testable import CapyBuddy

@MainActor
final class CaffeineControllerTests: XCTestCase {

    /// Mutable clock so tests can advance "time" deterministically without
    /// waiting on real wall-clock seconds.
    private final class MutableClock {
        var now: Date
        init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self.now = start }
        func read() -> Date { now }
        func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private func makeController(
        preventDisplaySleep: Bool = false
    ) -> (CaffeineController, MockPowerAssertionHolder, MutableClock) {
        let holder = MockPowerAssertionHolder()
        let clock = MutableClock()
        let controller = CaffeineController(
            holder: holder,
            preventDisplaySleep: preventDisplaySleep,
            clock: clock.read
        )
        return (controller, holder, clock)
    }

    func testInitialStateIsInactive() {
        let (controller, holder, _) = makeController()
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertFalse(holder.isHeld)
        XCTAssertNil(controller.remainingTime)
    }

    func testActivateIndefiniteAcquiresAssertion() {
        let (controller, holder, _) = makeController()
        controller.activate(duration: nil)

        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.state, .activeIndefinite)
        XCTAssertTrue(holder.isHeld)
        XCTAssertEqual(holder.acquireCount, 1)
        XCTAssertNil(controller.remainingTime)
    }

    func testActivateWithDurationSetsActiveUntil() {
        let (controller, holder, clock) = makeController()
        controller.activate(duration: 60)

        XCTAssertTrue(controller.isActive)
        if case .activeUntil(let until) = controller.state {
            XCTAssertEqual(until, clock.now.addingTimeInterval(60))
        } else {
            XCTFail("Expected .activeUntil, got \(controller.state)")
        }
        XCTAssertTrue(holder.isHeld)
        XCTAssertEqual(controller.remainingTime ?? -1, 60, accuracy: 0.001)
    }

    func testRemainingTimeShrinksAsClockAdvances() {
        let (controller, _, clock) = makeController()
        controller.activate(duration: 60)
        clock.advance(by: 25)
        XCTAssertEqual(controller.remainingTime ?? -1, 35, accuracy: 0.001)
    }

    func testRemainingTimeClampsToZeroPastDeadline() {
        let (controller, _, clock) = makeController()
        controller.activate(duration: 60)
        clock.advance(by: 120)
        XCTAssertEqual(controller.remainingTime, 0)
    }

    func testDeactivateReleasesAssertion() {
        let (controller, holder, _) = makeController()
        controller.activate(duration: nil)
        controller.deactivate()

        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertFalse(holder.isHeld)
        XCTAssertEqual(holder.acquireCount, 1)
        XCTAssertEqual(holder.releaseCount, 1)
    }

    func testExpireBehavesLikeDeactivate() {
        let (controller, holder, _) = makeController()
        controller.activate(duration: 60)
        controller.expire()

        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(holder.isHeld)
        XCTAssertEqual(holder.releaseCount, 1)
    }

    func testReactivatingDoesNotLeakAssertion() {
        let (controller, holder, _) = makeController()
        controller.activate(duration: nil)
        controller.activate(duration: 30)
        controller.activate(duration: nil)

        XCTAssertTrue(controller.isActive)
        XCTAssertTrue(holder.isHeld)
        XCTAssertEqual(holder.acquireCount, 3)
        XCTAssertEqual(holder.releaseCount, 2)
        XCTAssertEqual(holder.heldCount, 1, "Net hold count should always be 0 or 1")
    }

    func testDeactivateWhileInactiveIsNoop() {
        let (controller, holder, _) = makeController()
        controller.deactivate()
        XCTAssertEqual(holder.releaseCount, 0)
        XCTAssertEqual(controller.state, .inactive)
    }

    func testPreventDisplaySleepFlagPropagatesToHolder() {
        let (controller, holder, _) = makeController(preventDisplaySleep: true)
        controller.activate(duration: nil)
        XCTAssertEqual(holder.lastPreventDisplaySleep, true)

        controller.deactivate()
        controller.preventDisplaySleep = false
        controller.activate(duration: nil)
        XCTAssertEqual(holder.lastPreventDisplaySleep, false)
    }

    func testAcquireFailureKeepsStateInactive() {
        let (controller, holder, _) = makeController()
        holder.nextAcquireError = .acquireFailed(-1)

        controller.activate(duration: 60)

        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertFalse(holder.isHeld)
    }
}
