import XCTest
@testable import SnapDesk

final class BundleTests: XCTestCase {
    func testBundleIdentifierIsSnapDesk() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.brudvik.snapdesk")
    }
}
