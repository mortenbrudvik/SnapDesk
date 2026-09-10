import AppKit
import ApplicationServices
import XCTest
@testable import SnapDesk

/// Thrown in place of an `XCTSkip` when `SNAPDESK_REQUIRE_AX=1`, so the test stops at the point
/// it would have skipped. It sits outside `AXWindowTests` because that class is `@MainActor` and
/// `CustomStringConvertible.description` is not isolated to anything.
private struct AccessibilityRequired: Error, CustomStringConvertible {
    var description: String {
        "SNAPDESK_REQUIRE_AX=1 and the Accessibility layer was not reachable"
    }
}

/// Exercises `AXWindow` against real Accessibility calls, using windows the test host owns.
///
/// Driving our own windows is what makes the file testable at all: no second app to launch, and
/// every expectation checkable against the `NSWindow` on the other side. It is not free of TCC,
/// though — on a machine that has not granted the test host Accessibility, our own windows are
/// not vended over Accessibility and every test here skips (see `accessibilityIsRequired`).
/// What they cannot cover is another app's window: refusing a frame, hanging past the messaging
/// timeout, or honouring `AXEnhancedUserInterface`.
///
/// They do need a window server that answers Accessibility requests, which a GitHub Actions
/// runner does not have: there, enumerating our own windows takes the test host down instead of
/// returning an error. There is no CI in this repository today (no `.github`, no workflow of any
/// kind), so this suite runs only locally; a runner added later will have to pass
/// `-skip-testing:SnapDeskTests/AXWindowTests`. Either way it is a real gap — a change to
/// `AXWindow` has to be tested on a developer machine, because nothing on a runner guards it.
@MainActor
final class AXWindowTests: XCTestCase {
    /// A titled window is 28pt taller than its content rect, so every expectation here is built
    /// from `NSWindow.frame` rather than from the rect the window was asked for.
    private func makeWindow(
        contentRect: NSRect = NSRect(x: 200, y: 200, width: 400, height: 300),
        styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        // A programmatically created NSWindow defaults to `isReleasedWhenClosed`, which under ARC
        // is an over-release: `close()` in the teardown block below drops the last retain while
        // the block still holds the reference, and the block's own release then lands on freed
        // memory. That corrupts the heap silently until something else — an in-flight
        // miniaturize animation, once this file started exercising minimize and zoom — is
        // allocated into it and crashes the whole test host in `-[_NSWindowTransformAnimation
        // dealloc]`. ARC owns these windows; AppKit must not release them a second time.
        window.isReleasedWhenClosed = false
        window.title = "AXWindowTests \(UUID().uuidString)"
        window.orderFrontRegardless()
        addTeardownBlock { @MainActor in
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.close()
        }
        return window
    }

    // MARK: Requiring the Accessibility layer

    /// Whether an unreachable Accessibility layer is a failure rather than a skip. Off unless
    /// `SNAPDESK_REQUIRE_AX` — or `TEST_RUNNER_SNAPDESK_REQUIRE_AX`, which is the spelling that
    /// survives an `xcodebuild` invocation — is set to `1`.
    ///
    /// A skipped test and a passing one are the same exit status: `xcodebuild` prints
    /// "** TEST SUCCEEDED **" either way, and the skip count is a line of scrollback nobody
    /// reads. This project has already had a run report success with "Executed 258 tests, with 23
    /// tests skipped" where all 23 were this file — the Accessibility layer was not exercised at
    /// all and nothing said so. A missing grant is the usual cause, and it can go missing without
    /// anyone touching System Settings: the grant is keyed to the code signature, so an
    /// ad-hoc-signed build loses it on every rebuild.
    ///
    /// The default stays a skip, so an ordinary local run on a machine without the grant is not a
    /// wall of red. A run that has to *prove* `AXWindow` works sets the variable and gets a
    /// failure instead of silence.
    ///
    /// Both spellings are read because the test host is launched by `xcodebuild`, not by the
    /// shell that set the variable — and measured, only the prefixed one arrives. `xcodebuild`
    /// forwards `TEST_RUNNER_`-prefixed variables into the host process with the prefix stripped
    /// and passes nothing else through, so `SNAPDESK_REQUIRE_AX=1 xcodebuild … test` leaves this
    /// `false` and the suite skips exactly as if the flag had not been set. From a shell, set
    /// `TEST_RUNNER_SNAPDESK_REQUIRE_AX=1`; the unprefixed name is what a scheme or test-plan
    /// environment entry would set.
    private static var accessibilityIsRequired: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["SNAPDESK_REQUIRE_AX"] == "1"
            || environment["TEST_RUNNER_SNAPDESK_REQUIRE_AX"] == "1"
    }

    /// The one place that decides what an unreachable Accessibility layer means. Every guard in
    /// this file throws what this returns rather than raising `XCTSkip` itself, so the two
    /// behaviours cannot drift apart per call site.
    private func accessibilityUnavailable(
        _ reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Error {
        // What TCC says is part of the message: "granted but not applying" and "never granted"
        // are different repairs (see `AccessibilityAuth.Remedy`), and the skip is the only place
        // a reader learns which one they are looking at.
        let message = """
            \(reason); TCC reports trusted=\(AccessibilityAuth.isTrusted). Grant Accessibility to \
            the test host — the built SnapDesk.app that hosts these tests, not Xcode and not the \
            terminal — under System Settings › Privacy & Security › Accessibility. The grant is \
            keyed to the code signature, and an ad-hoc signature has no identity beyond its \
            cdhash — which changes on every rebuild — so an ad-hoc-signed build drops the grant \
            every time it is built: remove the stale entry and add the freshly built app again.
            """
        guard Self.accessibilityIsRequired else { return XCTSkip(message) }
        XCTFail(message, file: file, line: line)
        return AccessibilityRequired()
    }

    /// The AX element for one of our own windows, found by the unique title `makeWindow` gave it.
    /// This is the raw lookup on purpose: the role-guard tests need an element that has not
    /// already been through `AXWindow`'s own filtering. Everything else goes through
    /// `axWindow(for:)`.
    private func element(for window: NSWindow) throws -> AXUIElement {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &value
        )
        guard error == .success else {
            throw accessibilityUnavailable("no Accessibility access to our own windows (AXError \(error.rawValue))")
        }
        let windows = try XCTUnwrap(value as? [AXUIElement])
        let match = windows.first { element in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            return title as? String == window.title
        }
        guard let match else {
            throw accessibilityUnavailable("no Accessibility access to our own windows (not vended)")
        }
        return match
    }

    /// Goes through `AXWindow.windows(pid:)` rather than repeating the lookup here, because that
    /// function — and its role-filtering `compactMap` — is what every capture and every
    /// placement runs through, and a test-local copy would leave it uncovered.
    ///
    /// The raw read comes first and is the only thing allowed to skip: once it has vended the
    /// window, the Accessibility layer is demonstrably reachable, and a wrapper that then answers
    /// nothing is broken — a failure, never a skip. Before this, a regression in `windows(pid:)`
    /// skipped every test here and the run still printed TEST SUCCEEDED.
    private func axWindow(for window: NSWindow) throws -> AXWindow {
        _ = try element(for: window)
        let windows: [AXWindow]
        do {
            windows = try AXWindow.windows(pid: getpid())
        } catch {
            XCTFail("the raw read vends our windows but AXWindow.windows(pid:) threw \(error)")
            throw error
        }
        guard let match = windows.first(where: { $0.title == window.title }) else {
            XCTFail("the raw read vends this window but AXWindow.windows(pid:) does not (\(windows.count) found)")
            throw WrapperMissedWindow()
        }
        return match
    }

    private struct WrapperMissedWindow: Error {}

    /// AX writes reach the window server asynchronously — minimizing and zooming both animate —
    /// so state written on one line is not readable on the next.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("timed out waiting for \(description)", file: file, line: line)
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Gives the window server time to act on a button press before anything reads the result.
    /// `waitUntil` cannot stand in wherever the condition is itself an AX write: a write that
    /// lands mid-zoom is a user move as far as the window server is concerned, and cancels the
    /// zoom the test is waiting for.
    private func settle(_ seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
        }
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

    // MARK: Lookup

    func testWindowsForOurProcessVendsOurWindow() throws {
        let window = makeWindow()
        _ = try element(for: window)

        let windows = try AXWindow.windows(pid: getpid())

        XCTAssertTrue(windows.contains { $0.title == window.title })
    }

    /// A pid that no process has answers a failure, and it has to arrive as one: the empty list
    /// it used to become is indistinguishable from an app with no windows, which is how a capture
    /// came to drop an app and still report a healthy count.
    func testAListThatCannotBeReadThrowsRatherThanAnsweringAnEmptyList() {
        // Reserve a pid that is not in use by asking the kernel for one and letting it exit.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertNoThrow(try process.run())
        process.waitUntilExit()

        XCTAssertThrowsError(try AXWindow.windows(pid: process.processIdentifier)) { error in
            XCTAssertNotEqual((error as? AXWindowListError)?.code, .success)
        }
    }

    // MARK: The restore catalog

    /// `AXWindowCatalog` is the restore side of `CaptureFilter`: a window capture would have
    /// refused must not be handed to a slot either. A `.titled`-only window vends none of the
    /// three title-bar buttons while still calling itself `AXStandardWindow`, which is exactly
    /// the shape an Open/Save panel has — and the shape the catalog used to hand out, because it
    /// built its candidate without ever reading the buttons.
    func testTheRestoreCatalogListsARealWindowButNotAChromelessOne() throws {
        let real = makeWindow()
        let chromeless = makeWindow(
            contentRect: NSRect(x: 320, y: 320, width: 400, height: 300),
            styleMask: [.titled]
        )
        _ = try axWindow(for: real)
        let bundleID = try XCTUnwrap(Bundle.main.bundleIdentifier)

        let listed = try AXWindowCatalog().standardWindows(bundleIdentifier: bundleID)

        XCTAssertTrue(listed.contains { $0.title == real.title }, "a real window must be listed")
        XCTAssertFalse(
            listed.contains { $0.title == chromeless.title },
            "a chromeless standard window is an Open/Save panel as far as the filter is concerned"
        )
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

    func testAFailedReadIsNilRatherThanFalse() throws {
        let window = makeWindow()
        let ax = try axWindow(for: window)
        window.close()

        // A closed window answers nothing, which used to arrive at the call site as a confident
        // `false` and was written into the saved workspace as real window state.
        XCTAssertNil(ax.minimizedState)
        XCTAssertNil(ax.zoomedState)
        XCTAssertFalse(ax.isMinimized, "the lossy accessors stay available for throwaway decisions")
        XCTAssertFalse(ax.isZoomed)
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

        XCTAssertEqual(before, ax.identity, "Restore claims windows by this id; a move must not change it")
    }

    func testDifferentWindowsHaveDifferentIdentities() throws {
        let first = try axWindow(for: makeWindow())
        let second = try axWindow(for: makeWindow(contentRect: NSRect(x: 260, y: 260, width: 380, height: 280)))

        XCTAssertNotNil(first.identity)
        XCTAssertNotEqual(first.identity, second.identity)
    }

    // MARK: Minimized

    func testMinimizedRoundTripsOnOurWindow() throws {
        // This test used to skip on every machine: the host is LSUIElement, so the guard against
        // miniaturizing a window with no Dock tile to fall into was never not true, and minimize
        // had zero coverage anywhere. Becoming a regular app for the length of the test removes
        // the hazard itself rather than the test; the policy goes back in teardown.
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        addTeardownBlock { @MainActor in NSApp.setActivationPolicy(policy) }

        let window = makeWindow()
        let ax = try axWindow(for: window)
        XCTAssertEqual(ax.minimizedState, false)

        XCTAssertEqual(ax.setMinimized(true), .success)
        waitUntil("the window to be miniaturized") { window.isMiniaturized }
        XCTAssertEqual(ax.minimizedState, true)

        XCTAssertEqual(ax.setMinimized(false), .success)
        waitUntil("the window to come back") { !window.isMiniaturized }
        XCTAssertEqual(ax.minimizedState, false)
    }

    /// Un-minimizing is a precondition for the frame write that follows it, so it has to happen
    /// when the state is *unknown* and not only when it is a confirmed `true`. The read fails for
    /// exactly the window this matters for: one minimized long enough that its app is swapped out
    /// and misses the messaging timeout on the first message. Branching on `isMinimized` reads
    /// that as "not minimized", skips the un-minimize, and writes a frame into the Dock.
    /// The two halves a placement has to tell apart. A refusal on a window *confirmed* minimized
    /// is fatal — every write after it lands in the Dock and is swallowed while AX reports success
    /// — and a refusal on a state that could not be read is not, because the window may never have
    /// been minimized at all. A lossy wrapper that returned the same `AXError` for both is how a
    /// placement that needed no un-minimize at all came to be reported "could not position"; that
    /// wrapper is gone, and this is the API that replaced it.
    func testUnminimizeSeparatesAConfirmedStateFromAnUnreadableOne() throws {
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        addTeardownBlock { @MainActor in NSApp.setActivationPolicy(policy) }

        let window = makeWindow()
        let ax = try axWindow(for: window)

        XCTAssertEqual(ax.unminimize(), .alreadyUp, "a confirmed-up window must not be written to at all")
        XCTAssertFalse(window.isMiniaturized)

        XCTAssertEqual(ax.setMinimized(true), .success)
        waitUntil("the window to be miniaturized") { window.isMiniaturized }

        XCTAssertEqual(ax.unminimize(), .wasMinimized(write: .success))
        waitUntil("the window to come back") { !window.isMiniaturized }
    }

    func testUnminimizeOnAnUnreadableStateWritesAndSaysTheStateWasUnknown() throws {
        let window = makeWindow()
        let ax = try axWindow(for: window)
        window.close()

        XCTAssertNil(ax.minimizedState)
        // The write still has to be attempted — skipping it on an unreadable state is what let a
        // frame be written to a window that was still in the Dock — but the caller has to be able
        // to see that nothing about this window was ever confirmed, so that a refusal here does not
        // fail a placement whose frame write would have worked.
        guard case .stateUnknown(let write) = ax.unminimize() else {
            return XCTFail("an unreadable state must be written to blind and reported as unknown")
        }
        XCTAssertNotEqual(write, .success, "a closed window refuses the write; that refusal is not a verdict")
    }

    // MARK: Zoom

    func testAWindowFillingTheVisibleFrameReadsAsZoomed() throws {
        let visible = try XCTUnwrap(NSScreen.screens.first?.visibleFrame)
        let window = makeWindow()
        let ax = try axWindow(for: window)
        XCTAssertEqual(ax.zoomedState, false)

        XCTAssertEqual(ax.setCocoaFrame(visible), .success)

        // Zoom state is inferred from the frame because macOS vends no zoom attribute: the old
        // implementation read a nonexistent "AXZoomed" and so answered false for every window
        // on every machine, which is what capture wrote into the saved workspace.
        XCTAssertEqual(ax.zoomedState, true)
    }

    func testZoomingPressesTheZoomButtonAndMovesTheRealWindow() throws {
        let window = makeWindow()
        let ax = try axWindow(for: window)
        let unzoomed = window.frame

        XCTAssertEqual(ax.setZoomed(true), .success)

        waitUntil("AppKit to report the window zoomed") { window.isZoomed }
        XCTAssertNotEqual(window.frame, unzoomed, "the zoom must reach the window, not just the AX layer")
        XCTAssertTrue(ax.isZoomed)

        XCTAssertEqual(ax.setZoomed(false), .success)

        waitUntil("AppKit to report the window un-zoomed") { !window.isZoomed }
        XCTAssertEqual(window.frame, unzoomed, "un-zooming restores the frame the user had before")
    }

    /// Restore writes the saved frame before it restores zoom, and for a slot saved zoomed that
    /// frame *is* the visible frame. The button is a toggle AppKit aims from its own frame test,
    /// so the press it would make here is an *un*-zoom: the window jumps back to its pre-zoom size
    /// — off the frame restore just wrote — while the press reports `.success` and the slot is
    /// reported placed. Requesting a state the frame already confirms must move nothing.
    func testZoomingAWindowThatAlreadyFillsTheScreenLeavesItThere() throws {
        let visible = try XCTUnwrap(NSScreen.screens.first?.visibleFrame)
        let window = makeWindow()
        let ax = try axWindow(for: window)
        let beforePlacement = window.frame

        XCTAssertEqual(ax.setCocoaFrame(visible), .success)
        XCTAssertEqual(ax.zoomedState, true)

        XCTAssertEqual(ax.setZoomed(true), .success)

        settle()
        XCTAssertEqual(window.frame, visible, "the window must stay on the frame the placement wrote")
        XCTAssertNotEqual(window.frame, beforePlacement, "which is where a press would have sent it back to")
        XCTAssertEqual(ax.zoomedState, true)
    }

    /// The press itself is directionless — it is `-[NSWindow zoom:]` — so pressing it twice has to
    /// leave the window where it started. This is the primitive `setZoomed` guards; a caller that
    /// reaches for it is on its own for the direction.
    func testPressingTheZoomButtonTwiceReturnsTheWindowToWhereItWas() throws {
        let window = makeWindow()
        let ax = try axWindow(for: window)
        let before = window.frame

        XCTAssertEqual(ax.pressZoomButton(), .success)
        waitUntil("AppKit to report the window zoomed") { window.isZoomed }

        XCTAssertEqual(ax.pressZoomButton(), .success)
        waitUntil("AppKit to report the window un-zoomed") { !window.isZoomed }
        XCTAssertEqual(window.frame, before)
    }

    /// The other half of the same guard: the button is a toggle, so "un-zoom" on a window that is
    /// not zoomed would zoom it. A frame confirmed not to fill its display is the confirmation
    /// that there is nothing to do, and there the press is the destructive move.
    func testUnZoomingAWindowThatDoesNotFillTheScreenPressesNothing() throws {
        let window = makeWindow()
        let ax = try axWindow(for: window)
        let before = window.frame
        XCTAssertEqual(ax.zoomedState, false)

        XCTAssertEqual(ax.setZoomed(false), .success)

        settle()
        XCTAssertEqual(window.frame, before, "a press here would have zoomed the window instead")
    }

    func testUnZoomingWithAFrameThatCouldNotBeReadIsNotReportedAsSuccess() throws {
        let window = makeWindow()
        let ax = try axWindow(for: window)
        window.close()

        XCTAssertNil(ax.zoomedState)
        XCTAssertNotEqual(
            ax.setZoomed(false),
            .success,
            "an unknown state is not the confirmed 'nothing to do' that skips the press"
        )
    }
}
