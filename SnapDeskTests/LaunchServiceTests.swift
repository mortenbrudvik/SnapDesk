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
            [URL(fileURLWithPath: safariPath), URL(fileURLWithPath: previewPath)]
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

    func testLaunchTimeoutFailsSlotAndContinues() async {
        let launcher = FakeLauncher()
        let previewURL = URL(fileURLWithPath: previewPath)
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            previewID: previewURL,
        ]
        launcher.hangURLs = [previewURL]
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
            placer: placer,
            launchTimeout: .milliseconds(50)
        )

        let result = await service.launch(makeDocument(moveExistingWindows: false)) { _ in }

        XCTAssertEqual(
            result,
            [
                SlotProgress(index: 0, name: "Safari", status: .placed),
                SlotProgress(index: 1, name: "Preview", status: .failed("Launch failed")),
            ]
        )
        XCTAssertEqual(launcher.opens.map(\.url), [URL(fileURLWithPath: safariPath)])
        XCTAssertEqual(placer.placements.map(\.window.id), [safariWindow.id])
        XCTAssertEqual(apps.activated, [safariID])
    }

    func testColdStartTwoSafariSlotsLaunchesOnceThenPlacesBoth() async {
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let apps = FakeApps()
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow, safariWindow2],
        ])
        windows.requireOpenBeforeWindows = true
        windows.launcher = launcher
        let placer = FakePlacer()
        let service = makeService(
            launcher: launcher,
            apps: apps,
            windows: windows,
            placer: placer
        )

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: true,
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
                        bundleIdentifier: safariID,
                        bundlePath: safariPath,
                        name: "Safari",
                        title: "Apple",
                        x: 100,
                        y: 50,
                        width: 400,
                        height: 300
                    ),
                ]
            )
        ) { _ in }

        XCTAssertEqual(
            result,
            [
                SlotProgress(index: 0, name: "Safari", status: .placed),
                SlotProgress(index: 1, name: "Safari", status: .placed),
            ]
        )
        XCTAssertEqual(launcher.opens.count, 1)
        XCTAssertEqual(launcher.opens[0].url, URL(fileURLWithPath: safariPath))
        XCTAssertFalse(launcher.opens[0].configuration.createsNewApplicationInstance)
        XCTAssertEqual(Set(placer.placements.map(\.window.id)), [safariWindow.id, safariWindow2.id])
    }

    func testOverlappingLaunchesRunSequentially() async {
        let launcher = FakeLauncher()
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            previewID: URL(fileURLWithPath: previewPath),
        ]
        launcher.yieldBeforeOpen = true
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow],
            previewID: [previewWindow],
        ])
        let service = makeService(launcher: launcher, windows: windows)
        let safariDoc = makeDocument(
            moveExistingWindows: false,
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
            ]
        )
        let previewDoc = makeDocument(
            moveExistingWindows: false,
            windows: [
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

        let first = Task { @MainActor in
            await service.launch(safariDoc) { _ in }
        }
        let second = Task { @MainActor in
            await service.launch(previewDoc) { _ in }
        }
        _ = await first.value
        _ = await second.value

        XCTAssertEqual(launcher.maxInFlightOpens, 1)
        XCTAssertEqual(launcher.opens.count, 2)
    }

    func testSingleInstanceAppReusesWhenMoveExistingOff() async {
        let settingsID = "com.apple.systempreferences"
        let settingsPath = "/System/Applications/System Settings.app"
        let settingsWindow = MatchableWindow(id: "settings-1", bundleIdentifier: settingsID, title: "Settings")
        let settingsWindow2 = MatchableWindow(id: "settings-2", bundleIdentifier: settingsID, title: "Wi-Fi")
        let launcher = FakeLauncher()
        launcher.urls = [settingsID: URL(fileURLWithPath: settingsPath)]
        let windows = FakeWindows(windowsByBundle: [
            settingsID: [settingsWindow, settingsWindow2],
        ])
        windows.requireOpenBeforeWindows = true
        windows.launcher = launcher
        let placer = FakePlacer()
        let service = makeService(
            launcher: launcher,
            windows: windows,
            placer: placer,
            prohibitsMultipleInstances: { bundleID, _ in bundleID == settingsID }
        )

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: false,
                windows: [
                    savedWindow(
                        bundleIdentifier: settingsID,
                        bundlePath: settingsPath,
                        name: "System Settings",
                        title: "Settings",
                        x: 0,
                        y: 0,
                        width: 800,
                        height: 600
                    ),
                    savedWindow(
                        bundleIdentifier: settingsID,
                        bundlePath: settingsPath,
                        name: "System Settings",
                        title: "Wi-Fi",
                        x: 20,
                        y: 20,
                        width: 800,
                        height: 600
                    ),
                ]
            )
        ) { _ in }

        XCTAssertEqual(
            result,
            [
                SlotProgress(index: 0, name: "System Settings", status: .placed),
                SlotProgress(index: 1, name: "System Settings", status: .placed),
            ]
        )
        XCTAssertEqual(launcher.opens.count, 1)
        XCTAssertFalse(launcher.opens[0].configuration.createsNewApplicationInstance)
    }

    func testReadsLSMultipleInstancesProhibitedFromInfoPlist() throws {
        let single = try makeTempAppBundle(prohibited: true)
        let multi = try makeTempAppBundle(prohibited: false)
        XCTAssertTrue(InfoPlistInstancePolicy.prohibitsMultipleInstances(bundleIdentifier: "", path: single.path))
        XCTAssertFalse(InfoPlistInstancePolicy.prohibitsMultipleInstances(bundleIdentifier: "", path: multi.path))
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

    private var safariWindow2: MatchableWindow {
        MatchableWindow(id: "safari-2", bundleIdentifier: safariID, title: "Apple")
    }

    private var previewWindow: MatchableWindow {
        MatchableWindow(id: "preview-1", bundleIdentifier: previewID, title: "Notes")
    }

    private func makeService(
        launcher: FakeLauncher,
        apps: FakeApps = FakeApps(),
        windows: FakeWindows,
        placer: FakePlacer = FakePlacer(),
        launchTimeout: Duration = .seconds(10),
        prohibitsMultipleInstances: @escaping (String, String) -> Bool = { _, _ in false }
    ) -> LaunchService {
        LaunchService(
            launcher: launcher,
            apps: apps,
            windows: windows,
            placer: placer,
            displays: FakeLaunchDisplays(live: [display]),
            clock: FakeClock(),
            launchTimeout: launchTimeout,
            prohibitsMultipleInstances: prohibitsMultipleInstances
        )
    }

    private func makeDocument(
        moveExistingWindows: Bool,
        windows: [SavedWindow]? = nil
    ) -> WorkspaceDocument {
        WorkspaceDocument(
            version: WorkspaceDocument.currentVersion,
            name: "Coding",
            moveExistingWindows: moveExistingWindows,
            displays: [savedDisplay()],
            windows: windows ?? [
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

    private func makeTempAppBundle(prohibited: Bool) throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapDesk-instance-\(UUID().uuidString).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "test.snapdesk.\(prohibited ? "single" : "multi")",
            "CFBundleName": "Fake",
            "LSMultipleInstancesProhibited": prohibited,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: app) }
        return app
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
    var hangURLs: Set<URL> = []
    var opens: [(url: URL, configuration: LaunchConfiguration)] = []
    var openError: (any Error)?
    var yieldBeforeOpen = false
    var inFlightOpens = 0
    var maxInFlightOpens = 0

    func urlForApplication(bundleIdentifier: String) -> URL? {
        urls[bundleIdentifier]
    }

    func applicationExists(at path: String) -> Bool {
        existingPaths.contains(path)
    }

    func openApplication(at url: URL, configuration: LaunchConfiguration) async throws {
        inFlightOpens += 1
        maxInFlightOpens = max(maxInFlightOpens, inFlightOpens)
        defer { inFlightOpens -= 1 }
        if yieldBeforeOpen {
            await Task.yield()
        }
        if hangURLs.contains(url) {
            try await Task.sleep(for: .seconds(60))
        }
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
    var requireOpenBeforeWindows = false
    weak var launcher: FakeLauncher?

    init(windowsByBundle: [String: [MatchableWindow]] = [:]) {
        self.windowsByBundle = windowsByBundle
    }

    func standardWindows(bundleIdentifier: String) -> [MatchableWindow] {
        guard windowsAreAvailable(for: bundleIdentifier) else { return [] }
        return windowsByBundle[bundleIdentifier] ?? []
    }

    func waitForWindow(
        bundleIdentifier: String,
        excluding: Set<String>,
        timeout: Duration
    ) async -> MatchableWindow? {
        _ = timeout
        return standardWindows(bundleIdentifier: bundleIdentifier).first { !excluding.contains($0.id) }
    }

    private func windowsAreAvailable(for bundleIdentifier: String) -> Bool {
        guard requireOpenBeforeWindows else { return true }
        guard let launcher, let url = launcher.urls[bundleIdentifier] else { return false }
        return launcher.opens.contains { $0.url == url }
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
