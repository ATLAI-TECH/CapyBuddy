import Foundation
import IOKit.pwr_mgt

/// Abstraction over `IOPMAssertion*` so `CaffeineController` can be unit-tested
/// without holding a real system power assertion.
protocol PowerAssertionHolder: AnyObject {
    var isHeld: Bool { get }
    func acquire(preventDisplaySleep: Bool) throws
    func release()
}

enum PowerAssertionError: Error, Equatable {
    case acquireFailed(IOReturn)
}

final class IOKitPowerAssertionHolder: PowerAssertionHolder {

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var held: Bool = false

    var isHeld: Bool { held }

    func acquire(preventDisplaySleep: Bool) throws {
        guard !held else { return }
        let type: CFString = preventDisplaySleep
            ? kIOPMAssertionTypeNoDisplaySleep as CFString
            : kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        let result = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "CapyBuddy Caffeine" as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            throw PowerAssertionError.acquireFailed(result)
        }
        held = true
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(assertionID)
        held = false
    }

    deinit {
        if held {
            IOPMAssertionRelease(assertionID)
        }
    }
}
