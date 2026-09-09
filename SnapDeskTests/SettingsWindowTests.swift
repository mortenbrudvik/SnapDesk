import XCTest
@testable import SnapDesk

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testWindowTitleIsSnapDeskSettings() {
        let controller = SettingsWindowController()
        XCTAssertEqual(controller.window?.title, "SnapDesk Settings")
    }
}
