import Foundation
@testable import CapyBuddy

final class MockPowerAssertionHolder: PowerAssertionHolder {

    private(set) var heldCount = 0
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    private(set) var lastPreventDisplaySleep: Bool?
    var nextAcquireError: PowerAssertionError?

    var isHeld: Bool { heldCount > 0 }

    func acquire(preventDisplaySleep: Bool) throws {
        if let err = nextAcquireError {
            nextAcquireError = nil
            throw err
        }
        acquireCount += 1
        heldCount += 1
        lastPreventDisplaySleep = preventDisplaySleep
    }

    func release() {
        guard heldCount > 0 else { return }
        heldCount -= 1
        releaseCount += 1
    }
}
