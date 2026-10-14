import XCTest
@testable import mob_ios

final class SmokeTests: XCTestCase {
    func testAppModuleLoads() {
        XCTAssertNotNil(Bundle(for: SmokeTests.self))
    }
}
