import XCTest
@testable import SnapDesk

@MainActor
final class CaptureServiceTests: XCTestCase {
    private let display = LiveDisplay(
        id: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
        name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 38, width: 1512, height: 916),
        scale: 2
    )

    private let safari = RunningAppInfo(
        pid: 1,
        bundleIdentifier: "com.apple.Safari",
        bundlePath: "/System/Cryptexes/App/System/Applications/Safari.app",
        name: "Safari",
        activationPolicyIsRegular: true,
        isSnapDesk: false
    )

    private let snapDesk = RunningAppInfo(
        pid: 2,
        bundleIdentifier: "com.brudvik.snapdesk",
        bundlePath: "/Applications/SnapDesk.app",
        name: "SnapDesk",
        activationPolicyIsRegular: true,
        isSnapDesk: true
    )

    func testCaptureFiltersOrdersAndMapsDocument() {
        let front = snapshot(
            cgWindowID: 10,
            title: "GitHub",
            cocoaFrame: CGRect(x: 200, y: 238, width: 400, height: 300)
        )
        let back = snapshot(
            cgWindowID: 11,
            title: "Apple",
            cocoaFrame: CGRect(x: 100, y: 138, width: 800, height: 600)
        )
        let floating = snapshot(
            cgWindowID: 12,
            title: "Palette",
            subrole: "AXFloatingWindow",
            cocoaFrame: CGRect(x: 50, y: 50, width: 200, height: 200)
        )
        let tiny = snapshot(
            cgWindowID: 13,
            title: "Tiny",
            cocoaFrame: CGRect(x: 0, y: 0, width: 4, height: 4)
        )
        let minimized = snapshot(
            cgWindowID: 14,
            title: "Downloads",
            cocoaFrame: CGRect(x: 10, y: 48, width: 500, height: 400),
            minimized: true
        )
        let snapDeskWindow = snapshot(
            cgWindowID: 20,
            title: "SnapDesk",
            cocoaFrame: CGRect(x: 20, y: 58, width: 640, height: 480)
        )

        let service = CaptureService(
            apps: FakeApps(running: [safari, snapDesk]),
            ax: FakeAX(windowsByPid: [
                safari.pid: [minimized, back, floating, tiny, front],
                snapDesk.pid: [snapDeskWindow],
            ]),
            order: FakeOrder(ids: [10, 11]),
            displays: FakeDisplays(live: [display])
        )

        let doc = service.capture(name: "Coding").document

        XCTAssertEqual(doc.version, WorkspaceDocument.currentVersion)
        XCTAssertEqual(doc.name, "Coding")
        XCTAssertTrue(doc.moveExistingWindows)
        XCTAssertEqual(doc.displays, [savedDisplay(display)])
        XCTAssertEqual(doc.windows.count, 3)

        XCTAssertEqual(doc.windows.map(\.title), ["GitHub", "Apple", "Downloads"])
        XCTAssertFalse(doc.windows.contains { $0.bundleIdentifier == snapDesk.bundleIdentifier })
        XCTAssertFalse(doc.windows.contains { $0.title == "Palette" || $0.title == "Tiny" })

        let frontSaved = doc.windows[0]
        XCTAssertEqual(frontSaved.bundleIdentifier, safari.bundleIdentifier)
        XCTAssertEqual(frontSaved.bundlePath, safari.bundlePath)
        XCTAssertEqual(frontSaved.name, safari.name)
        XCTAssertEqual(frontSaved.displayId, display.id)
        XCTAssertEqual(frontSaved.x, 200)
        XCTAssertEqual(frontSaved.y, 200)
        XCTAssertEqual(frontSaved.width, 400)
        XCTAssertEqual(frontSaved.height, 300)
        XCTAssertFalse(frontSaved.minimized)
        XCTAssertFalse(frontSaved.zoomed)
        XCTAssertEqual(frontSaved.arguments, "")

        let backSaved = doc.windows[1]
        XCTAssertEqual(backSaved.title, "Apple")
        XCTAssertEqual(backSaved.x, 100)
        XCTAssertEqual(backSaved.y, 100)
        XCTAssertEqual(backSaved.width, 800)
        XCTAssertEqual(backSaved.height, 600)
        XCTAssertEqual(backSaved.arguments, "")

        let minimizedSaved = doc.windows[2]
        XCTAssertEqual(minimizedSaved.title, "Downloads")
        XCTAssertTrue(minimizedSaved.minimized)
        XCTAssertEqual(minimizedSaved.x, 10)
        XCTAssertEqual(minimizedSaved.y, 10)
        XCTAssertEqual(minimizedSaved.arguments, "")
    }

    func testOffScreenCenterAssignsLargestIntersectionNotMain() {
        let left = LiveDisplay(
            id: "LEFT",
            name: "Left",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            scale: 1
        )
        let right = LiveDisplay(
            id: "RIGHT",
            name: "Right",
            frame: CGRect(x: 800, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 800, y: 0, width: 800, height: 600),
            scale: 1
        )
        let hangingOffRight = snapshot(
            cgWindowID: 10,
            title: "Hang",
            cocoaFrame: CGRect(x: 1000, y: 500, width: 400, height: 200)
        )
        let service = CaptureService(
            apps: FakeApps(running: [safari]),
            ax: FakeAX(windowsByPid: [safari.pid: [hangingOffRight]]),
            order: FakeOrder(ids: [10]),
            displays: FakeDisplays(live: [left, right])
        )

        let doc = service.capture().document

        XCTAssertEqual(doc.windows.count, 1)
        XCTAssertEqual(doc.windows[0].displayId, right.id)
        XCTAssertNotEqual(doc.windows[0].displayId, left.id)
    }

    func testEmptyEligibleSetStillCapturesDisplays() {
        let service = CaptureService(
            apps: FakeApps(running: [snapDesk]),
            ax: FakeAX(windowsByPid: [
                snapDesk.pid: [
                    snapshot(
                        cgWindowID: 20,
                        title: "SnapDesk",
                        cocoaFrame: CGRect(x: 20, y: 58, width: 640, height: 480)
                    ),
                ],
            ]),
            order: FakeOrder(ids: [20]),
            displays: FakeDisplays(live: [display])
        )

        let doc = service.capture().document

        XCTAssertEqual(doc.name, "Untitled")
        XCTAssertEqual(doc.windows, [])
        XCTAssertEqual(doc.displays, [savedDisplay(display)])
    }

    /// Capture keeps a window parked off every screen, recording it against the primary display
    /// so restore has somewhere to put it back — `ScreenGeometry` alone would answer "no display".
    func testWindowOffEveryDisplayIsRecordedAgainstThePrimaryDisplay() {
        let secondary = LiveDisplay(
            id: "SECONDARY",
            name: "Secondary",
            frame: CGRect(x: 1512, y: 0, width: 1000, height: 600),
            visibleFrame: CGRect(x: 1512, y: 0, width: 1000, height: 600),
            scale: 1
        )
        let stranded = snapshot(
            cgWindowID: 10,
            title: "Stranded",
            cocoaFrame: CGRect(x: 400, y: 9000, width: 400, height: 300)
        )
        let service = CaptureService(
            apps: FakeApps(running: [safari]),
            ax: FakeAX(windowsByPid: [safari.pid: [stranded]]),
            order: FakeOrder(ids: [10]),
            displays: FakeDisplays(live: [display, secondary])
        )

        let doc = service.capture().document

        XCTAssertEqual(doc.windows.count, 1)
        XCTAssertEqual(doc.windows[0].displayId, display.id)
        XCTAssertEqual(doc.windows[0].x, 400)
        XCTAssertEqual(doc.windows[0].y, 8962)
    }

    /// With no display attached there is no visible frame to make the saved x/y relative to, so a
    /// window is dropped rather than written in absolute coordinates under an empty `displayId` —
    /// which would mean the same four fields carried two different meanings.
    func testWithNoDisplayAttachedWindowsAreSkippedRatherThanRecordedInAbsoluteCoordinates() {
        let window = snapshot(
            cgWindowID: 10,
            title: "GitHub",
            cocoaFrame: CGRect(x: 200, y: 238, width: 400, height: 300)
        )
        let service = CaptureService(
            apps: FakeApps(running: [safari]),
            ax: FakeAX(windowsByPid: [safari.pid: [window]]),
            order: FakeOrder(ids: [10]),
            displays: FakeDisplays(live: [])
        )

        let doc = service.capture().document

        XCTAssertEqual(doc.displays, [])
        XCTAssertEqual(doc.windows, [])
    }

    /// Two screens can report the same frame (mirroring), and the saved window must name the one
    /// the lookup actually chose rather than whichever look-alike came first.
    func testMirroredDisplaysKeepTheirOwnIdentities() {
        let mirror = LiveDisplay(
            id: "MIRROR",
            name: "Mirror",
            frame: display.frame,
            visibleFrame: display.visibleFrame,
            scale: display.scale
        )
        let window = snapshot(
            cgWindowID: 10,
            title: "GitHub",
            cocoaFrame: CGRect(x: 200, y: 238, width: 400, height: 300)
        )
        let service = CaptureService(
            apps: FakeApps(running: [safari]),
            ax: FakeAX(windowsByPid: [safari.pid: [window]]),
            order: FakeOrder(ids: [10]),
            displays: FakeDisplays(live: [mirror, display])
        )

        let doc = service.capture().document

        XCTAssertEqual(doc.windows.count, 1)
        XCTAssertEqual(doc.windows[0].displayId, mirror.id)
    }

    /// Zoom is the one window attribute capture infers rather than reads, and it is inferred
    /// against the display list this capture records — from the very frame saved beside it — so
    /// the two cannot disagree. A second `NSScreen` snapshot taken inside the per-window read
    /// could, and no test could drive it.
    func testZoomIsInferredAgainstTheDisplaysTheCaptureRecords() {
        let filling = snapshot(cgWindowID: 10, title: "Filling", cocoaFrame: display.visibleFrame)
        let service = CaptureService(
            apps: FakeApps(running: [safari]),
            ax: FakeAX(windowsByPid: [safari.pid: [filling]]),
            order: FakeOrder(ids: [10]),
            displays: FakeDisplays(live: [display])
        )

        let doc = service.capture().document

        XCTAssertEqual(doc.windows.map(\.zoomed), [true])
        XCTAssertEqual(doc.windows.map(\.minimized), [false])
    }

    /// The contrast with the test above is the point. Zoom is *inferred* from the frame, because
    /// macOS vends no attribute for it; fullscreen is a real attribute and is read. So a window
    /// can be fullscreen while its recorded frame is nothing like the visible frame, and this is
    /// the case that would be wrong if fullscreen were inferred the way zoom has to be.
    func testFullscreenIsReadRatherThanInferredFromTheFrame() {
        let full = snapshot(
            cgWindowID: 10,
            title: "Docs",
            cocoaFrame: CGRect(x: 40, y: 40, width: 400, height: 300),
            fullscreen: true
        )
        let service = CaptureService(
            apps: FakeApps(running: [safari]),
            ax: FakeAX(windowsByPid: [safari.pid: [full]]),
            order: FakeOrder(ids: [10]),
            displays: FakeDisplays(live: [display])
        )

        let doc = service.capture().document

        XCTAssertEqual(doc.windows.map(\.fullscreen), [true])
        XCTAssertEqual(doc.windows.map(\.zoomed), [false], "a small frame is not zoomed, fullscreen or not")
    }

    /// A read that failed stays nil rather than collapsing to false — the rule every persisted
    /// state here follows. Saved as `false`, a window whose fullscreen state was never actually
    /// read would be dragged out of fullscreen by every later restore.
    ///
    /// Unlike the frame and the minimized state, an unreadable fullscreen does not disqualify the
    /// window: nil is a value this field is allowed to hold, meaning "not recorded".
    func testAFullscreenStateThatCouldNotBeReadIsSavedAsNilRatherThanFalse() {
        let unknown = snapshot(
            cgWindowID: 10,
            title: "Docs",
            cocoaFrame: CGRect(x: 40, y: 40, width: 400, height: 300),
            fullscreen: nil
        )
        let service = CaptureService(
            apps: FakeApps(running: [safari]),
            ax: FakeAX(windowsByPid: [safari.pid: [unknown]]),
            order: FakeOrder(ids: [10]),
            displays: FakeDisplays(live: [display])
        )

        let doc = service.capture().document

        XCTAssertEqual(doc.windows.count, 1, "an unreadable fullscreen does not disqualify the window")
        XCTAssertNil(doc.windows[0].fullscreen)
    }

    /// A usable document is kept; one that is not a location is dropped rather than saved. The
    /// attribute is not a URL field — some apps put a window title in it — and a value that
    /// reaches the file would be handed to LaunchServices on every later restore.
    func testAUsableDocumentIsRecordedAndAnUnusableOneIsDropped() {
        let frame = CGRect(x: 100, y: 138, width: 800, height: 600)
        let withURL = snapshot(cgWindowID: 10, title: "Docs", cocoaFrame: frame, document: "https://example.com/a")
        let withJunk = snapshot(cgWindowID: 11, title: "Junk", cocoaFrame: frame, document: "Untitled 3")
        let service = CaptureService(
            apps: FakeApps(running: [safari]),
            ax: FakeAX(windowsByPid: [safari.pid: [withURL, withJunk]]),
            order: FakeOrder(ids: [10, 11]),
            displays: FakeDisplays(live: [display])
        )

        let doc = service.capture().document

        XCTAssertEqual(doc.windows.map(\.title), ["Docs", "Junk"], "the junk document must not cost the window")
        XCTAssertEqual(doc.windows.map(\.document), ["https://example.com/a", nil])
    }

    // MARK: What could not be read

    /// The failure this whole report exists for: an app that is busy when the hotkey fires does
    /// not answer within the AX timeout, and used to simply vanish from the workspace — the
    /// document looked complete, and every later restore lacked the app.
    func testAnAppWhoseWindowListCannotBeReadIsReportedRatherThanSilentlyDropped() {
        let xcode = RunningAppInfo(
            pid: 3,
            bundleIdentifier: "com.apple.dt.Xcode",
            bundlePath: "/Applications/Xcode.app",
            name: "Xcode",
            activationPolicyIsRegular: true,
            isSnapDesk: false
        )
        let ax = FakeAX(windowsByPid: [
            safari.pid: [snapshot(cgWindowID: 10, title: "GitHub", cocoaFrame: CGRect(x: 200, y: 238, width: 400, height: 300))],
        ])
        ax.failingPids = [xcode.pid]
        let service = CaptureService(
            apps: FakeApps(running: [safari, xcode]),
            ax: ax,
            order: FakeOrder(ids: [10]),
            displays: FakeDisplays(live: [display])
        )

        let outcome = service.capture()

        XCTAssertEqual(outcome.document.windows.map(\.title), ["GitHub"])
        XCTAssertEqual(outcome.report.unreadableApps, ["Xcode"])
        XCTAssertFalse(outcome.report.isClean)
        let explanation = try? XCTUnwrap(outcome.report.explanation)
        XCTAssertTrue(explanation?.contains("Xcode") == true, "the explanation must name the app: \(explanation ?? "nil")")
    }

    /// A failed read of the frame or the minimized state disqualifies the window — a wrong value
    /// would go to disk — but the user has to hear that a window is missing.
    func testAWindowWhoseFrameOrMinimizedStateCannotBeReadIsSkippedAndCounted() {
        let readable = snapshot(cgWindowID: 10, title: "GitHub", cocoaFrame: CGRect(x: 200, y: 238, width: 400, height: 300))
        let unreadableState = snapshot(cgWindowID: 11, title: "Apple", cocoaFrame: CGRect(x: 100, y: 138, width: 800, height: 600), minimized: nil)
        let unreadableFrame = snapshot(cgWindowID: 12, title: "Docs", cocoaFrame: nil)
        let service = CaptureService(
            apps: FakeApps(running: [safari]),
            ax: FakeAX(windowsByPid: [safari.pid: [readable, unreadableState, unreadableFrame]]),
            order: FakeOrder(ids: [10, 11, 12]),
            displays: FakeDisplays(live: [display])
        )

        let outcome = service.capture()

        XCTAssertEqual(outcome.document.windows.map(\.title), ["GitHub"])
        XCTAssertEqual(outcome.report.skippedWindows, ["Safari": 2])
        XCTAssertTrue(outcome.report.explanation?.contains("2 windows of Safari") == true, outcome.report.explanation ?? "nil")
    }

    /// Restore matches windows by bundle identifier, so a slot saved with an empty one can never be
    /// filled: it burns the whole window timeout and fails. Better not to write it at all.
    func testAnAppWithoutABundleIdentifierIsSkippedAndReported() {
        let unidentified = RunningAppInfo(
            pid: 4,
            bundleIdentifier: "",
            bundlePath: "/Users/me/Build/Scratch.app",
            name: "Scratch",
            activationPolicyIsRegular: true,
            isSnapDesk: false
        )
        let service = CaptureService(
            apps: FakeApps(running: [unidentified]),
            ax: FakeAX(windowsByPid: [
                unidentified.pid: [snapshot(cgWindowID: 40, title: "Scratch", cocoaFrame: CGRect(x: 200, y: 238, width: 400, height: 300))],
            ]),
            order: FakeOrder(ids: [40]),
            displays: FakeDisplays(live: [display])
        )

        let outcome = service.capture()

        XCTAssertEqual(outcome.document.windows, [])
        XCTAssertEqual(outcome.report.unidentifiedApps, ["Scratch"])
        XCTAssertTrue(outcome.report.explanation?.contains("Scratch") == true)
    }

    func testACaptureThatReadEverythingReportsNothing() {
        let service = CaptureService(
            apps: FakeApps(running: [safari]),
            ax: FakeAX(windowsByPid: [
                safari.pid: [snapshot(cgWindowID: 10, title: "GitHub", cocoaFrame: CGRect(x: 200, y: 238, width: 400, height: 300))],
            ]),
            order: FakeOrder(ids: [10]),
            displays: FakeDisplays(live: [display])
        )

        let outcome = service.capture()

        XCTAssertEqual(outcome.report, .clean)
        XCTAssertTrue(outcome.report.isClean)
        XCTAssertNil(outcome.report.explanation)
    }

    /// The inference behind `SavedWindow.zoomed`, on its own: a window filling the visible frame
    /// of the display it sits on is as close to zoomed as macOS lets anything ask.
    func testZoomIsInferredFromTheFrameAgainstTheDisplaysItIsHanded() {
        let elsewhere = LiveDisplay(
            id: "ELSEWHERE",
            name: "Elsewhere",
            frame: CGRect(x: 4000, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 4000, y: 0, width: 1000, height: 800),
            scale: 1
        )
        let filling = display.visibleFrame

        XCTAssertTrue(AXWindow.isZoomed(frame: filling, on: [display]))
        XCTAssertTrue(
            AXWindow.isZoomed(frame: filling.insetBy(dx: 1, dy: 1), on: [display]),
            "a zoom lands up to a point short of the visible frame"
        )
        XCTAssertFalse(AXWindow.isZoomed(frame: filling.insetBy(dx: 3, dy: 3), on: [display]))

        // The same frame, against screens it is nowhere near: the answer comes from the list it
        // is handed and from nothing else.
        XCTAssertFalse(AXWindow.isZoomed(frame: filling, on: [elsewhere]))
        XCTAssertFalse(AXWindow.isZoomed(frame: filling, on: []))
    }

    /// Saving now validates, so a capture that recorded a window with a non-positive size would
    /// hand the user a document they cannot save. It cannot: the eligibility filter's 8pt floor
    /// runs before anything is recorded, and `CGRect.width`/`.height` standardize, so a negative
    /// AX size is measured as its magnitude rather than slipping through as a negative number.
    /// This pins the seam between the two — capture's output is always something `validate()`
    /// accepts — rather than either half on its own.
    func testCaptureNeverRecordsAWindowValidationWouldReject() throws {
        let zeroWidth = snapshot(
            cgWindowID: 30,
            title: "Zero width",
            cocoaFrame: CGRect(x: 100, y: 138, width: 0, height: 400)
        )
        let zeroHeight = snapshot(
            cgWindowID: 31,
            title: "Zero height",
            cocoaFrame: CGRect(x: 100, y: 138, width: 400, height: 0)
        )
        let negative = snapshot(
            cgWindowID: 32,
            title: "Negative",
            cocoaFrame: CGRect(x: 500, y: 438, width: -400, height: -300)
        )
        let usable = snapshot(
            cgWindowID: 33,
            title: "Usable",
            cocoaFrame: CGRect(x: 100, y: 138, width: 800, height: 600)
        )
        // Not a location, and `validate()` refuses one. The window is still perfectly good, so the
        // document has to be dropped without the window going with it.
        let junkDocument = snapshot(
            cgWindowID: 34,
            title: "Junk document",
            cocoaFrame: CGRect(x: 100, y: 138, width: 800, height: 600),
            document: "Untitled 3"
        )

        let service = CaptureService(
            apps: FakeApps(running: [safari]),
            ax: FakeAX(windowsByPid: [safari.pid: [zeroWidth, zeroHeight, negative, usable, junkDocument]]),
            order: FakeOrder(ids: [30, 31, 32, 33, 34]),
            displays: FakeDisplays(live: [display])
        )

        let doc = service.capture(name: "Degenerate").document

        XCTAssertNoThrow(try doc.validate(), "a captured document must always be one the user can save")
        for window in doc.windows {
            XCTAssertGreaterThan(window.width, 0, "\(window.title) was recorded with a size that is not positive")
            XCTAssertGreaterThan(window.height, 0, "\(window.title) was recorded with a size that is not positive")
        }
        XCTAssertEqual(
            doc.windows.map(\.title),
            ["Negative", "Usable", "Junk document"],
            "only the degenerate sizes are dropped"
        )
        XCTAssertNil(
            doc.windows.first { $0.title == "Junk document" }?.document,
            "the unusable document is dropped, but not the window"
        )
        // The negative rect is recorded as the rectangle it describes, not as negative numbers.
        let repaired = try XCTUnwrap(doc.windows.first { $0.title == "Negative" })
        XCTAssertEqual(repaired.width, 400)
        XCTAssertEqual(repaired.height, 300)
    }

    private func snapshot(
        cgWindowID: UInt32?,
        title: String,
        subrole: String? = nil,
        cocoaFrame: CGRect?,
        minimized: Bool? = false,
        fullscreen: Bool? = false,
        document: String? = nil
    ) -> AXWindowSnapshot {
        AXWindowSnapshot(
            cgWindowID: cgWindowID,
            title: title,
            subrole: subrole,
            cocoaFrame: cocoaFrame,
            minimized: minimized,
            fullscreen: fullscreen,
            document: document,
            hasTitleBarButtons: true
        )
    }

    private func savedDisplay(_ live: LiveDisplay) -> SavedDisplay {
        SavedDisplay(
            id: live.id,
            name: live.name,
            frame: CodableRect(live.frame),
            visibleFrame: CodableRect(live.visibleFrame),
            scale: Double(live.scale)
        )
    }
}

private struct FakeApps: RunningAppSourcing {
    var running: [RunningAppInfo]
    func apps() -> [RunningAppInfo] { running }
}

@MainActor
private final class FakeAX: AXCapturing {
    private let windowsByPid: [pid_t: [AXWindowSnapshot]]
    /// Apps whose window list cannot be read at all — the beachballing app, in the real thing.
    var failingPids: Set<pid_t> = []

    init(windowsByPid: [pid_t: [AXWindowSnapshot]]) {
        self.windowsByPid = windowsByPid
    }

    func windows(pid: pid_t) throws -> [AXWindowSnapshot] {
        if failingPids.contains(pid) {
            throw AXWindowListError(code: .cannotComplete)
        }
        return windowsByPid[pid] ?? []
    }
}

private struct FakeOrder: CGWindowOrdering {
    var ids: [UInt32]
    func onScreenWindowIDsFrontToBack() -> [UInt32] { ids }
}

private struct FakeDisplays: DisplayCatalog {
    var live: [LiveDisplay]
    func displays() -> [LiveDisplay] { live }
}
