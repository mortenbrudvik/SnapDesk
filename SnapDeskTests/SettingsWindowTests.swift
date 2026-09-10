import AppKit
import XCTest
@testable import SnapDesk

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testWindowSurvivesClosingSoItCanBeShownAgain() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        XCTAssertFalse(
            window.isReleasedWhenClosed,
            "AppDelegate keeps one controller for the app's lifetime and reopens this window"
        )

        controller.showWindow(nil)
        XCTAssertTrue(window.isVisible)

        window.close()
        XCTAssertFalse(window.isVisible)

        controller.showWindow(nil)
        XCTAssertTrue(controller.window === window, "reopening must present the same window")
        XCTAssertTrue(window.isVisible)
    }

    func testWindowHostsTheSettingsFormAtAFixedSize() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        XCTAssertNotNil(window.contentViewController, "the Shortcuts and Launch at login form")
        XCTAssertEqual(window.contentView?.frame.size, NSSize(width: 420, height: 240))
        // The SwiftUI form declares a fixed frame, so a resizable window would only add empty
        // space; closable is the only way out of a window an LSUIElement app cannot re-focus
        // from a Dock icon.
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.styleMask.contains(.closable))
    }
}
