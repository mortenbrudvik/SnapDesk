import AppKit
import ServiceManagement
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

    /// Centring on every open threw away the position the user had dragged the window to.
    func testShowingTheWindowAgainKeepsWhereTheUserPutIt() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.showWindow(nil)
        let moved = NSRect(x: 60, y: 60, width: window.frame.width, height: window.frame.height)
        window.setFrame(moved, display: false)

        window.close()
        controller.showWindow(nil)

        XCTAssertEqual(window.frame.origin, moved.origin)
    }

    /// The pane shows what `SMAppService` says, and that can change while the window is closed.
    func testShowingTheWindowReReadsTheLoginItemStatus() throws {
        final class FakeLoginItems: LoginItemService {
            var status: SMAppService.Status = .notRegistered
            func register() throws { status = .enabled }
            func unregister() throws { status = .notRegistered }
        }
        let fake = FakeLoginItems()
        let settings = AppSettings(loginItems: fake)
        let controller = SettingsWindowController(settings: settings)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        XCTAssertFalse(settings.launchAtLogin)

        fake.status = .enabled
        controller.showWindow(nil)

        XCTAssertTrue(settings.launchAtLogin)
    }

    func testWindowHostsTheSettingsFormAtAFixedSize() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        XCTAssertNotNil(window.contentViewController, "the Shortcuts, Workspace shortcuts and General form")
        // Grew with the five workspace shortcut rows and the startup workspace picker. The window
        // and the SwiftUI frame have to agree or the form is clipped, which is what this pins.
        XCTAssertEqual(window.contentView?.frame.size, NSSize(width: 460, height: 480))
        // The SwiftUI form declares a fixed frame, so a resizable window would only add empty
        // space; closable is the only way out of a window an LSUIElement app cannot re-focus
        // from a Dock icon.
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.styleMask.contains(.closable))
    }
}
