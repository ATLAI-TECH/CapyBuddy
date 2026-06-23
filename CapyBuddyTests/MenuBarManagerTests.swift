import XCTest
import AppKit
import SwiftUI
@testable import CapyBuddy

@MainActor
final class MenuBarManagerTests: XCTestCase {

    func testFeatureProtocolDefaultMakeMenuBarItemsIsEmpty() {
        let feature = DefaultMenuItemsFeature()
        XCTAssertEqual(feature.makeMenuBarItems().count, 0)
    }

    func testBuildItemsWithNoFeaturesIncludesOnlySettingsAndQuit() {
        let items = MenuBarManager.buildItems(features: [], target: NSObject())
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "Settings…")
        XCTAssertEqual(items[1].title, "Quit CapyBuddy")
    }

    func testBuildItemsHidesDisabledFeatures() {
        let enabled = FakeFeature(id: "a", enabled: true, items: [])
        let disabled = FakeFeature(id: "b", enabled: false, items: [])

        let items = MenuBarManager.buildItems(features: [enabled, disabled], target: NSObject())

        // Disabled features no longer appear at all — Settings → General is
        // the single source of truth for menu visibility.
        // 1 feature row + 1 separator + Settings + Quit = 4
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[0].title, "Fake")
        XCTAssertTrue(items[1].isSeparatorItem)
        XCTAssertEqual(items[2].title, "Settings…")
        XCTAssertEqual(items[3].title, "Quit CapyBuddy")
    }

    func testTopLevelFeatureRowHasNoStateCheckmark() {
        let f = FakeFeature(id: "a", enabled: true, items: [])
        let items = MenuBarManager.buildItems(features: [f], target: NSObject())
        // The icon carries any "active" signal; no leading checkmark on
        // the top-level row.
        XCTAssertEqual(items[0].state, .off)
    }

    func testFeatureRowAlwaysShowsToggleAndSettingsEvenWhenNoExtras() {
        let f = FakeFeature(id: "a", enabled: true, items: [])
        let items = MenuBarManager.buildItems(features: [f], target: NSObject())
        let submenuItems = items[0].submenu?.items ?? []

        // Just: Enabled toggle, separator, Settings…
        XCTAssertEqual(submenuItems.count, 3)
        XCTAssertEqual(submenuItems[0].title, "Enabled")
        XCTAssertTrue(submenuItems[1].isSeparatorItem)
        XCTAssertEqual(submenuItems[2].title, "Settings…")
    }

    func testFeatureRowEmbedsExtrasFromMakeMenuBarItemsWhenEnabled() {
        let extras = [NSMenuItem(title: "Extra", action: nil, keyEquivalent: "")]
        let f = FakeFeature(id: "a", enabled: true, items: extras)
        let items = MenuBarManager.buildItems(features: [f], target: NSObject())
        let submenuItems = items[0].submenu?.items ?? []

        // Enabled, separator, Extra, separator, Settings…
        XCTAssertEqual(submenuItems.count, 5)
        XCTAssertEqual(submenuItems[0].title, "Enabled")
        XCTAssertTrue(submenuItems[1].isSeparatorItem)
        XCTAssertEqual(submenuItems[2].title, "Extra")
        XCTAssertTrue(submenuItems[3].isSeparatorItem)
        XCTAssertEqual(submenuItems[4].title, "Settings…")
    }

    func testDisabledFeaturesDoNotProduceSubmenuAtAll() {
        let extras = [NSMenuItem(title: "Extra", action: nil, keyEquivalent: "")]
        let f = FakeFeature(id: "a", enabled: false, items: extras)
        let items = MenuBarManager.buildItems(features: [f], target: NSObject())
        // Disabled feature is filtered out → only Settings + Quit footer.
        XCTAssertEqual(items.map(\.title), ["Settings…", "Quit CapyBuddy"])
    }

    func testEnabledButHiddenFromMenuFeatureDoesNotAppear() {
        // Enabled (running) but the user has switched off "show in menu" —
        // dropdown should still hide it. The feature's hotkeys/monitors
        // keep working; just no row.
        let f = FakeFeature(id: "a", enabled: true, items: [], showsInMenu: false)
        let items = MenuBarManager.buildItems(features: [f], target: NSObject())
        XCTAssertEqual(items.map(\.title), ["Settings…", "Quit CapyBuddy"])
    }

    func testFeatureRowsCarryIcon() {
        let f = FakeFeature(id: "a", enabled: true, items: [])
        let items = MenuBarManager.buildItems(features: [f], target: NSObject())
        XCTAssertNotNil(items[0].image, "feature row should show its SF Symbol icon")
    }

    func testFeatureWithoutEnabledToggleSkipsToggleRow() {
        let extras = [
            NSMenuItem(title: "15 minutes", action: nil, keyEquivalent: ""),
            NSMenuItem(title: "30 minutes", action: nil, keyEquivalent: ""),
        ]
        let f = ToggleOptOutFeature(items: extras)
        let items = MenuBarManager.buildItems(features: [f], target: NSObject())
        let submenuItems = items[0].submenu?.items ?? []

        // No "Enabled" row — extras come first, then separator, then Settings.
        XCTAssertEqual(submenuItems.map(\.title), [
            "15 minutes", "30 minutes", "", "Settings…",
        ])
        XCTAssertTrue(submenuItems[2].isSeparatorItem)
    }

    func testFeatureWithoutEnabledToggleAndNoExtrasShowsOnlySettings() {
        let f = ToggleOptOutFeature(items: [])
        let items = MenuBarManager.buildItems(features: [f], target: NSObject())
        let submenuItems = items[0].submenu?.items ?? []
        // No toggle, no extras, no leading separator — just Settings…
        XCTAssertEqual(submenuItems.map(\.title), ["Settings…"])
    }

}

@MainActor
private final class ToggleOptOutFeature: Feature {
    let id = "opt-out"
    let displayName = "OptOut"
    let iconSystemName = "circle"
    var isEnabled = true
    var showsInMenuBar = true
    private let items: [NSMenuItem]

    init(items: [NSMenuItem]) {
        self.items = items
    }

    func start() {}
    func stop() {}
    func makeSettingsView() -> AnyView { AnyView(EmptyView()) }
    func makeMenuBarItems() -> [NSMenuItem] { items }

    var hasEnabledToggleInMenu: Bool { false }
}

@MainActor
private final class DefaultMenuItemsFeature: Feature {
    let id = "default"
    let displayName = "Default"
    let iconSystemName = "circle"
    var isEnabled = true
    var showsInMenuBar = true
    func start() {}
    func stop() {}
    func makeSettingsView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor
private final class FakeFeature: Feature {
    let id: String
    let displayName = "Fake"
    let iconSystemName = "circle"
    var isEnabled: Bool
    var showsInMenuBar: Bool
    private let items: [NSMenuItem]

    init(id: String, enabled: Bool, items: [NSMenuItem], showsInMenu: Bool = true) {
        self.id = id
        self.isEnabled = enabled
        self.showsInMenuBar = showsInMenu
        self.items = items
    }

    func start() {}
    func stop() {}
    func makeSettingsView() -> AnyView { AnyView(EmptyView()) }
    func makeMenuBarItems() -> [NSMenuItem] { items }
}
