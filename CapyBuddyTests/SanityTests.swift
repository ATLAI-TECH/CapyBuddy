import XCTest
@testable import CapyBuddy

final class SanityTests: XCTestCase {

    func testArithmeticSanity() {
        XCTAssertEqual(1 + 1, 2)
    }

    @MainActor
    func testFeatureRegistryIsAccessible() {
        let registry = FeatureRegistry.shared
        XCTAssertNotNil(registry)
    }
}
