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

        let doc = service.capture(name: "Coding")

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

        let doc = service.capture()

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

        let doc = service.capture()

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

        let doc = service.capture()

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

        let doc = service.capture()

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

        let doc = service.capture()

        XCTAssertEqual(doc.windows.count, 1)
        XCTAssertEqual(doc.windows[0].displayId, mirror.id)
    }

    /// Zoom is the one window attribute capture infers rather than reads, and it has to be
    /// inferred against the display list this capture records. Reading `NSScreen` inside the
    /// per-window read instead answers from a second snapshot of the screens — one that can
    /// disagree with the displays saved beside the window, and that no test can drive.
    func testTheDisplayListCaptureRecordsIsWhatTheWindowReadIsGiven() {
        let ax = FakeAX(windowsByPid: [
            safari.pid: [
                snapshot(
                    cgWindowID: 10,
                    title: "GitHub",
                    cocoaFrame: CGRect(x: 200, y: 238, width: 400, height: 300)
                ),
            ],
        ])
        let service = CaptureService(
            apps: FakeApps(running: [safari]),
            ax: ax,
            order: FakeOrder(ids: [10]),
            displays: FakeDisplays(live: [display])
        )

        _ = service.capture()

        XCTAssertEqual(ax.displaysPerCall, [[display]])
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

        let service = CaptureService(
            apps: FakeApps(running: [safari]),
            ax: FakeAX(windowsByPid: [safari.pid: [zeroWidth, zeroHeight, negative, usable]]),
            order: FakeOrder(ids: [30, 31, 32, 33]),
            displays: FakeDisplays(live: [display])
        )

        let doc = service.capture(name: "Degenerate")

        XCTAssertNoThrow(try doc.validate(), "a captured document must always be one the user can save")
        for window in doc.windows {
            XCTAssertGreaterThan(window.width, 0, "\(window.title) was recorded with a size that is not positive")
            XCTAssertGreaterThan(window.height, 0, "\(window.title) was recorded with a size that is not positive")
        }
        XCTAssertEqual(doc.windows.map(\.title), ["Negative", "Usable"], "only the degenerate sizes are dropped")
        // The negative rect is recorded as the rectangle it describes, not as negative numbers.
        let repaired = try XCTUnwrap(doc.windows.first { $0.title == "Negative" })
        XCTAssertEqual(repaired.width, 400)
        XCTAssertEqual(repaired.height, 300)
    }

    private func snapshot(
        cgWindowID: UInt32?,
        title: String,
        role: String = "AXWindow",
        subrole: String? = nil,
        cocoaFrame: CGRect,
        minimized: Bool = false,
        zoomed: Bool = false
    ) -> AXWindowSnapshot {
        AXWindowSnapshot(
            cgWindowID: cgWindowID,
            title: title,
            role: role,
            subrole: subrole,
            cocoaFrame: cocoaFrame,
            minimized: minimized,
            zoomed: zoomed
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

/// A class, not a struct, so a test can read back what the capture handed it.
@MainActor
private final class FakeAX: AXCapturing {
    private let windowsByPid: [pid_t: [AXWindowSnapshot]]
    private(set) var displaysPerCall: [[LiveDisplay]] = []

    init(windowsByPid: [pid_t: [AXWindowSnapshot]]) {
        self.windowsByPid = windowsByPid
    }

    func snapshot(pid: pid_t, displays: [LiveDisplay]) -> [AXWindowSnapshot] {
        displaysPerCall.append(displays)
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
