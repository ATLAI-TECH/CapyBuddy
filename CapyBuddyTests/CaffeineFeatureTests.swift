import XCTest
import AppKit
@testable import CapyBuddy

@MainActor
final class CaffeineFeatureTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // CaffeinePrefs reads/writes UserDefaults.standard; clear so a prior
        // test run that flipped a toggle doesn't leak state into this run.
        CaffeinePrefs.activateOnLaunch = false
        CaffeinePrefs.preventDisplaySleep = false
        CaffeinePrefs.defaultDuration = 0
    }

    func testDurationOrNilTreatsZeroAsIndefinite() {
        XCTAssertNil(CaffeineFeature.durationOrNil(0))
        XCTAssertEqual(CaffeineFeature.durationOrNil(60), 60)
        XCTAssertEqual(CaffeineFeature.durationOrNil(900), 900)
    }

    func testDurationOrNilTreatsNegativeAsIndefinite() {
        XCTAssertNil(CaffeineFeature.durationOrNil(-1))
    }

    func testFormatRemainingUnderAnHourUsesMinutesSeconds() {
        XCTAssertEqual(CaffeineFeature.formatRemaining(0), "0:00")
        XCTAssertEqual(CaffeineFeature.formatRemaining(59), "0:59")
        XCTAssertEqual(CaffeineFeature.formatRemaining(60), "1:00")
        XCTAssertEqual(CaffeineFeature.formatRemaining(125), "2:05")
        XCTAssertEqual(CaffeineFeature.formatRemaining(59 * 60 + 30), "59:30")
    }

    func testFormatRemainingAboveAnHourUsesHourFormat() {
        XCTAssertEqual(CaffeineFeature.formatRemaining(3600), "1:00:00")
        XCTAssertEqual(CaffeineFeature.formatRemaining(3661), "1:01:01")
        XCTAssertEqual(CaffeineFeature.formatRemaining(2 * 3600 + 5 * 60 + 9), "2:05:09")
    }

    func testFormatRemainingClampsNegativeToZero() {
        XCTAssertEqual(CaffeineFeature.formatRemaining(-5), "0:00")
    }

    func testIconChangesWithActiveState() {
        let feature = CaffeineFeature(holderFactory: { MockPowerAssertionHolder() })
        feature.start()
        XCTAssertEqual(feature.iconSystemName, "cup.and.saucer")

        feature.controller?.activate(duration: nil)
        XCTAssertEqual(feature.iconSystemName, "cup.and.saucer.fill")

        feature.controller?.deactivate()
        XCTAssertEqual(feature.iconSystemName, "cup.and.saucer")

        feature.stop()
    }

    func testMakeMenuBarItemsBeforeStartIsEmpty() {
        let feature = CaffeineFeature(holderFactory: { MockPowerAssertionHolder() })
        XCTAssertEqual(feature.makeMenuBarItems().count, 0)
    }

    func testMakeMenuBarItemsWhenInactiveReturnsFlatDurationList() {
        let feature = CaffeineFeature(holderFactory: { MockPowerAssertionHolder() })
        feature.start()
        defer { feature.stop() }

        let items = feature.makeMenuBarItems()
        // Items are inserted directly into the Caffeine feature's submenu by
        // MenuBarManager — no extra "Keep Awake" wrapper level.
        XCTAssertEqual(items.map(\.title), [
            "15 minutes", "30 minutes", "1 hour", "2 hours", "Indefinitely",
        ])
    }

    func testMakeMenuBarItemsWhenActiveShowsOnlyStatusAndTurnOff() {
        let feature = CaffeineFeature(holderFactory: { MockPowerAssertionHolder() })
        feature.start()
        defer { feature.stop() }

        feature.controller?.activate(duration: 600)

        let items = feature.makeMenuBarItems()
        // Active state hides the duration list entirely — the user has
        // already picked one. Submenu is just: Remaining + sep + Turn Off.
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items[0].title.hasPrefix("Remaining: "))
        XCTAssertFalse(items[0].isEnabled)
        XCTAssertTrue(items[1].isSeparatorItem)
        XCTAssertEqual(items[2].title, "Turn Off")
    }

    func testMakeMenuBarItemsWhenActiveIndefinitelyShowsOnState() {
        let feature = CaffeineFeature(holderFactory: { MockPowerAssertionHolder() })
        feature.start()
        defer { feature.stop() }

        feature.controller?.activate(duration: nil)

        let items = feature.makeMenuBarItems()
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].title, "On — Indefinitely")
    }

    func testTurnOffMenuItemDeactivates() {
        let feature = CaffeineFeature(holderFactory: { MockPowerAssertionHolder() })
        feature.start()
        defer { feature.stop() }

        feature.controller?.activate(duration: nil)
        XCTAssertTrue(feature.controller?.isActive ?? false)

        let turnOff = feature.makeMenuBarItems().last!
        XCTAssertEqual(turnOff.title, "Turn Off")
        XCTAssertEqual(turnOff.action, #selector(CaffeineFeature.toggleAction))
        feature.toggleAction()
        XCTAssertFalse(feature.controller?.isActive ?? true)
    }

    func testMenuTitleSurfacesCountdownWhenActive() {
        let feature = CaffeineFeature(holderFactory: { MockPowerAssertionHolder() })
        feature.start()
        defer { feature.stop() }

        XCTAssertEqual(feature.menuTitle, "Keep Awake")

        feature.controller?.activate(duration: 600)
        XCTAssertTrue(feature.menuTitle.hasPrefix("Keep Awake — "))
        XCTAssertTrue(feature.menuTitle.contains(":"))

        feature.controller?.deactivate()
        XCTAssertEqual(feature.menuTitle, "Keep Awake")

        feature.controller?.activate(duration: nil)
        XCTAssertEqual(feature.menuTitle, "Keep Awake — On")
    }

    func testToggleActionFlipsControllerState() {
        let feature = CaffeineFeature(holderFactory: { MockPowerAssertionHolder() })
        feature.start()
        defer { feature.stop() }

        XCTAssertFalse(feature.controller?.isActive ?? true)
        feature.toggleAction()
        XCTAssertTrue(feature.controller?.isActive ?? false)
        feature.toggleAction()
        XCTAssertFalse(feature.controller?.isActive ?? true)
    }

    func testActivateForDurationUsesRepresentedObjectSeconds() {
        let feature = CaffeineFeature(holderFactory: { MockPowerAssertionHolder() })
        feature.start()
        defer { feature.stop() }

        let item = NSMenuItem(title: "10 min", action: nil, keyEquivalent: "")
        item.representedObject = NSNumber(value: 600.0)
        feature.activateForDuration(item)

        XCTAssertTrue(feature.controller?.isActive ?? false)
        XCTAssertEqual(feature.controller?.remainingTime ?? -1, 600, accuracy: 1.0)
    }

    func testActivateForDurationWithNilRepresentedActivatesIndefinitely() {
        let feature = CaffeineFeature(holderFactory: { MockPowerAssertionHolder() })
        feature.start()
        defer { feature.stop() }

        let item = NSMenuItem(title: "Indefinitely", action: nil, keyEquivalent: "")
        item.representedObject = nil
        feature.activateForDuration(item)

        XCTAssertEqual(feature.controller?.state, .activeIndefinite)
    }

    func testStopReleasesController() {
        let feature = CaffeineFeature(holderFactory: { MockPowerAssertionHolder() })
        feature.start()
        XCTAssertNotNil(feature.controller)
        feature.controller?.activate(duration: nil)
        feature.stop()
        XCTAssertNil(feature.controller)
    }
}
