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

private struct FakeAX: AXCapturing {
    var windowsByPid: [pid_t: [AXWindowSnapshot]]
    func snapshot(pid: pid_t) -> [AXWindowSnapshot] { windowsByPid[pid] ?? [] }
}

private struct FakeOrder: CGWindowOrdering {
    var ids: [UInt32]
    func onScreenWindowIDsFrontToBack() -> [UInt32] { ids }
}

private struct FakeDisplays: DisplayCatalog {
    var live: [LiveDisplay]
    func displays() -> [LiveDisplay] { live }
}
