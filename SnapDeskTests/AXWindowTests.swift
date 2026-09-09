import AppKit
import ApplicationServices
import XCTest
@testable import SnapDesk

/// Exercises `AXWindow` against real Accessibility calls, using windows the test host owns.
///
/// A process may read and write its own Accessibility hierarchy without being trusted, so these
/// run on a machine that has never granted SnapDesk anything — which is what makes the file
/// testable at all. What they cannot cover is another app's window: refusing a frame, hanging
/// past the messaging timeout, or honouring `AXEnhancedUserInterface`.
///
/// They do need a window server that answers Accessibility requests, which a GitHub Actions
/// runner does not have: there, enumerating our own windows takes the test host down instead of
/// returning an error. CI therefore passes `-skip-testing:SnapDeskTests/AXWindowTests`, and
/// this suite only runs locally. That is a real gap — a change to `AXWindow` has to be tested
/// on a developer machine, because nothing on the runner guards it.
@MainActor
final class AXWindowTests: XCTestCase {
    /// A titled window is 28pt taller than its content rect, so every expectation here is built
    /// from `NSWindow.frame` rather than from the rect the window was asked for.
    private func makeWindow(
        contentRect: NSRect = NSRect(x: 200, y: 200, width: 400, height: 300)
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AXWindowTests \(UUID().uuidString)"
        window.orderFrontRegardless()
        addTeardownBlock { @MainActor in
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.close()
        }
        return window
    }

    /// The AX element for one of our own windows, found by the unique title `makeWindow` gave it.
    private func element(for window: NSWindow) throws -> AXUIElement {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &value
        )
        try XCTSkipUnless(error == .success, "no Accessibility access to our own windows (AXError \(error.rawValue))")
        let windows = try XCTUnwrap(value as? [AXUIElement])
        let match = windows.first { element in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            return title as? String == window.title
        }
        guard let match else {
            throw XCTSkip("no Accessibility access to our own windows (not vended)")
        }
        return match
    }

    private func axWindow(for window: NSWindow) throws -> AXWindow {
        let element = try element(for: window)
        return try XCTUnwrap(AXWindow(windowElement: element))
    }

    // MARK: The role guard

    func testAnElementThatIsNotAWindowIsRejected() {
        // The application element has role AXApplication. Wrapping it would let a command write
        // a position onto the app itself.
        XCTAssertNil(AXWindow(windowElement: AXUIElementCreateApplication(getpid())))
    }

    func testTheSystemWideElementIsRejected() {
        XCTAssertNil(AXWindow(windowElement: AXUIElementCreateSystemWide()))
    }

    func testARealWindowIsAccepted() throws {
        let window = makeWindow()
        let element = try element(for: window)
        XCTAssertNotNil(AXWindow(windowElement: element))
    }

    // MARK: Reading

    func testCocoaFrameMatchesTheWindowsOwnFrame() throws {
        let window = makeWindow()
        let ax = try axWindow(for: window)
        XCTAssertEqual(ax.cocoaFrame, window.frame)
    }

    func testTitleAndPidComeBack() throws {
        let window = makeWindow()
        let ax = try axWindow(for: window)
        XCTAssertEqual(ax.title, window.title)
        XCTAssertEqual(ax.pid, getpid())
    }

    // MARK: Writing

    func testSettingTheFrameMovesAndResizesTheRealWindow() throws {
        let window = makeWindow()
        let ax = try axWindow(for: window)
        let target = CGRect(x: 150, y: 120, width: 333, height: 222)

        XCTAssertEqual(ax.setCocoaFrame(target), .success)

        XCTAssertEqual(window.frame, target, "the write must reach the window, not just the AX layer")
    }

    func testTheFrameReadsBackAsItWasWritten() throws {
        let window = makeWindow()
        let ax = try axWindow(for: window)
        let target = CGRect(x: 175, y: 145, width: 321, height: 210)

        XCTAssertEqual(ax.setCocoaFrame(target), .success)

        // A round trip through AX space and back: any error in the y flip shows up here as a
        // frame mirrored about the primary display's top edge.
        XCTAssertEqual(ax.cocoaFrame, target)
    }

    func testMovingUpwardsIsNotMirrored() throws {
        // The flip is its own inverse, so a bug in it survives a single round trip at one
        // height but not at two different ones: y and primaryMaxY - y - height differ here.
        let window = makeWindow()
        let ax = try axWindow(for: window)

        XCTAssertEqual(ax.setCocoaFrame(CGRect(x: 120, y: 100, width: 300, height: 200)), .success)
        let low = try XCTUnwrap(ax.cocoaFrame)
        XCTAssertEqual(ax.setCocoaFrame(CGRect(x: 120, y: 400, width: 300, height: 200)), .success)
        let high = try XCTUnwrap(ax.cocoaFrame)

        XCTAssertEqual(high.minY - low.minY, 300, "moving 300pt up in Cocoa space must move the window 300pt up")
        XCTAssertGreaterThan(high.minY, low.minY)
    }

    func testAWriteToAClosedWindowReportsAnErrorRatherThanSuccess() throws {
        let window = makeWindow()
        let ax = try axWindow(for: window)
        window.close()

        // The point is that failures come back as AXError instead of being swallowed.
        XCTAssertNotEqual(ax.setCocoaFrame(CGRect(x: 10, y: 10, width: 100, height: 100)), .success)
    }

    // MARK: Identity

    func testIdentityUsesTheWindowIdAndOurPid() throws {
        let window = makeWindow()
        let ax = try axWindow(for: window)
        let identity = try XCTUnwrap(ax.identity)

        guard case .cgWindow(let id, let pid) = identity else {
            return XCTFail("expected a window id, got \(identity); the _AXUIElementGetWindow SPI is gone")
        }
        XCTAssertEqual(pid, getpid())
        XCTAssertEqual(CGWindowID(window.windowNumber), id, "the SPI must agree with AppKit's own window number")
    }

    func testIdentityIsStableAcrossReadsAndAcrossMoves() throws {
        let window = makeWindow()
        let ax = try axWindow(for: window)
        let before = ax.identity

        XCTAssertEqual(ax.setCocoaFrame(CGRect(x: 130, y: 130, width: 280, height: 190)), .success)

        XCTAssertEqual(before, ax.identity, "restore memory is keyed on this; a move must not change it")
    }

    func testDifferentWindowsHaveDifferentIdentities() throws {
        let first = try axWindow(for: makeWindow())
        let second = try axWindow(for: makeWindow(contentRect: NSRect(x: 260, y: 260, width: 380, height: 280)))

        XCTAssertNotNil(first.identity)
        XCTAssertNotEqual(first.identity, second.identity)
    }

    // MARK: Minimized

    func testMinimizedRoundTripsOnOurWindow() throws {
        let window = makeWindow()
        let ax = try axWindow(for: window)
        XCTAssertFalse(ax.isMinimized)
        XCTAssertEqual(ax.setMinimized(true), .success)
        for _ in 0..<20 where !ax.isMinimized {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(ax.isMinimized)
        XCTAssertEqual(ax.setMinimized(false), .success)
        for _ in 0..<20 where ax.isMinimized {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(ax.isMinimized)
    }
}
