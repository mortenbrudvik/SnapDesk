import XCTest
@testable import SnapDesk

@MainActor
final class LaunchServiceTests: XCTestCase {
    private let safariID = "com.apple.Safari"
    private let safariPath = "/Applications/Safari.app"
    private let previewID = "com.apple.Preview"
    private let previewPath = "/System/Applications/Preview.app"

    private let display = LiveDisplay(
        id: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
        name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 38, width: 1512, height: 916),
        scale: 2
    )

    func testHappyPathLaunchesNewInstancesAndPlacesBoth() async {
        let launcher = FakeLauncher()
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            previewID: URL(fileURLWithPath: previewPath),
        ]
        let apps = FakeApps()
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow],
            previewID: [previewWindow],
        ])
        let placer = FakePlacer()
        let service = makeService(
            launcher: launcher,
            apps: apps,
            windows: windows,
            placer: placer
        )

        var snapshots: [[SlotProgress]] = []
        let result = await service.launch(makeDocument(moveExistingWindows: false)) {
            snapshots.append($0)
        }

        XCTAssertEqual(
            result,
            [
                SlotProgress(index: 0, name: "Safari", status: .placed),
                SlotProgress(index: 1, name: "Preview", status: .placed),
            ]
        )
        XCTAssertEqual(snapshots.last, result)
        XCTAssertEqual(launcher.opens.count, 2)
        XCTAssertEqual(
            launcher.opens.map(\.url),
            [URL(fileURLWithPath: previewPath), URL(fileURLWithPath: safariPath)]
        )
        XCTAssertTrue(launcher.opens.allSatisfy { $0.configuration.createsNewApplicationInstance })
        XCTAssertTrue(launcher.opens.allSatisfy { !$0.configuration.activates })
        XCTAssertEqual(placer.placements.map(\.window.id), [previewWindow.id, safariWindow.id])
        XCTAssertEqual(placer.placements[0].cocoaFrame, CGRect(x: 100, y: 88, width: 400, height: 300))
        XCTAssertEqual(placer.placements[1].cocoaFrame, CGRect(x: 0, y: 38, width: 800, height: 900))
        XCTAssertEqual(apps.activated, [safariID])
    }

    func testMissingAppFailsFirstSlotAndContinues() async {
        let launcher = FakeLauncher()
        launcher.urls = [previewID: URL(fileURLWithPath: previewPath)]
        let apps = FakeApps()
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow],
            previewID: [previewWindow],
        ])
        let placer = FakePlacer()
        let service = makeService(
            launcher: launcher,
            apps: apps,
            windows: windows,
            placer: placer
        )

        let result = await service.launch(makeDocument(moveExistingWindows: false)) { _ in }

        XCTAssertEqual(
            result,
            [
                SlotProgress(index: 0, name: "Safari", status: .failed("App not found")),
                SlotProgress(index: 1, name: "Preview", status: .placed),
            ]
        )
        XCTAssertEqual(launcher.opens.map(\.url), [URL(fileURLWithPath: previewPath)])
        XCTAssertEqual(placer.placements.map(\.window.id), [previewWindow.id])
        XCTAssertEqual(apps.activated, [previewID])
    }

    func testAXRefuseFailsSlotAndContinues() async {
        let launcher = FakeLauncher()
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            previewID: URL(fileURLWithPath: previewPath),
        ]
        let apps = FakeApps()
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow],
            previewID: [previewWindow],
        ])
        let placer = FakePlacer(refuseIDs: [safariWindow.id])
        let service = makeService(
            launcher: launcher,
            apps: apps,
            windows: windows,
            placer: placer
        )

        let result = await service.launch(makeDocument(moveExistingWindows: false)) { _ in }

        XCTAssertEqual(
            result,
            [
                SlotProgress(index: 0, name: "Safari", status: .failed("Could not position")),
                SlotProgress(index: 1, name: "Preview", status: .placed),
            ]
        )
        XCTAssertEqual(placer.placements.map(\.window.id), [previewWindow.id, safariWindow.id])
        XCTAssertEqual(apps.activated, [previewID])
    }

    func testCancelBeforeStartFailsPendingSlots() async {
        let launcher = FakeLauncher()
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            previewID: URL(fileURLWithPath: previewPath),
        ]
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow],
            previewID: [previewWindow],
        ])
        let service = makeService(launcher: launcher, windows: windows)

        service.cancel()
        let result = await service.launch(makeDocument(moveExistingWindows: false)) { _ in }

        XCTAssertEqual(
            result,
            [
                SlotProgress(index: 0, name: "Safari", status: .failed("Cancelled")),
                SlotProgress(index: 1, name: "Preview", status: .failed("Cancelled")),
            ]
        )
        XCTAssertTrue(launcher.opens.isEmpty)
    }

    func testEmptyDocumentReturnsEmptyWithoutLaunching() async {
        let launcher = FakeLauncher()
        let windows = FakeWindows()
        let service = makeService(launcher: launcher, windows: windows)
        var snapshots: [[SlotProgress]] = []

        let result = await service.launch(
            WorkspaceDocument(
                version: WorkspaceDocument.currentVersion,
                name: "Empty",
                moveExistingWindows: false,
                displays: [savedDisplay()],
                windows: []
            )
        ) {
            snapshots.append($0)
        }

        XCTAssertEqual(result, [])
        XCTAssertEqual(snapshots, [[]])
        XCTAssertTrue(launcher.opens.isEmpty)
    }

    private var safariWindow: MatchableWindow {
        MatchableWindow(id: "safari-1", bundleIdentifier: safariID, title: "GitHub")
    }

    private var previewWindow: MatchableWindow {
        MatchableWindow(id: "preview-1", bundleIdentifier: previewID, title: "Notes")
    }

    private func makeService(
        launcher: FakeLauncher,
        apps: FakeApps = FakeApps(),
        windows: FakeWindows,
        placer: FakePlacer = FakePlacer()
    ) -> LaunchService {
        LaunchService(
            launcher: launcher,
            apps: apps,
            windows: windows,
            placer: placer,
            displays: FakeLaunchDisplays(live: [display]),
            clock: FakeClock()
        )
    }

    private func makeDocument(moveExistingWindows: Bool) -> WorkspaceDocument {
        WorkspaceDocument(
            version: WorkspaceDocument.currentVersion,
            name: "Coding",
            moveExistingWindows: moveExistingWindows,
            displays: [savedDisplay()],
            windows: [
                savedWindow(
                    bundleIdentifier: safariID,
                    bundlePath: safariPath,
                    name: "Safari",
                    title: "GitHub",
                    x: 0,
                    y: 0,
                    width: 800,
                    height: 900
                ),
                savedWindow(
                    bundleIdentifier: previewID,
                    bundlePath: previewPath,
                    name: "Preview",
                    title: "Notes",
                    x: 100,
                    y: 50,
                    width: 400,
                    height: 300
                ),
            ]
        )
    }

    private func savedDisplay() -> SavedDisplay {
        SavedDisplay(
            id: display.id,
            name: display.name,
            frame: CodableRect(display.frame),
            visibleFrame: CodableRect(display.visibleFrame),
            scale: Double(display.scale)
        )
    }

    private func savedWindow(
        bundleIdentifier: String,
        bundlePath: String,
        name: String,
        title: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> SavedWindow {
        SavedWindow(
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundlePath,
            name: name,
            title: title,
            displayId: display.id,
            x: x,
            y: y,
            width: width,
            height: height,
            minimized: false,
            zoomed: false,
            arguments: ""
        )
    }
}

@MainActor
private final class FakeLauncher: ApplicationLaunching {
    var urls: [String: URL] = [:]
    var existingPaths: Set<String> = []
    var opens: [(url: URL, configuration: LaunchConfiguration)] = []
    var openError: (any Error)?

    func urlForApplication(bundleIdentifier: String) -> URL? {
        urls[bundleIdentifier]
    }

    func applicationExists(at path: String) -> Bool {
        existingPaths.contains(path)
    }

    func openApplication(at url: URL, configuration: LaunchConfiguration) async throws {
        if let openError { throw openError }
        opens.append((url, configuration))
    }
}

@MainActor
private final class FakeApps: RunningApplicationQuerying {
    var running: Set<String> = []
    var unhidden: [String] = []
    var activated: [String] = []

    func runningBundleIDs() -> Set<String> { running }

    func unhide(bundleIdentifier: String) {
        unhidden.append(bundleIdentifier)
    }

    func activate(bundleIdentifier: String) {
        activated.append(bundleIdentifier)
    }
}

@MainActor
private final class FakeWindows: WindowCatalog {
    var windowsByBundle: [String: [MatchableWindow]]

    init(windowsByBundle: [String: [MatchableWindow]] = [:]) {
        self.windowsByBundle = windowsByBundle
    }

    func standardWindows(bundleIdentifier: String) -> [MatchableWindow] {
        windowsByBundle[bundleIdentifier] ?? []
    }

    func waitForWindow(
        bundleIdentifier: String,
        excluding: Set<String>,
        timeout: Duration
    ) async -> MatchableWindow? {
        _ = timeout
        return (windowsByBundle[bundleIdentifier] ?? []).first { !excluding.contains($0.id) }
    }
}

@MainActor
private final class FakePlacer: WindowPlacing {
    struct Placement {
        var window: MatchableWindow
        var cocoaFrame: CGRect
        var minimized: Bool
        var zoomed: Bool
    }

    var placements: [Placement] = []
    var refuseIDs: Set<String>

    init(refuseIDs: Set<String> = []) {
        self.refuseIDs = refuseIDs
    }

    func place(_ window: MatchableWindow, cocoaFrame: CGRect, minimized: Bool, zoomed: Bool) -> Bool {
        placements.append(
            Placement(window: window, cocoaFrame: cocoaFrame, minimized: minimized, zoomed: zoomed)
        )
        return !refuseIDs.contains(window.id)
    }
}

@MainActor
private struct FakeLaunchDisplays: DisplayCatalog {
    var live: [LiveDisplay]
    func displays() -> [LiveDisplay] { live }
}

@MainActor
private struct FakeClock: Clock {
    func sleep(_ duration: Duration) async {
        _ = duration
    }
}
