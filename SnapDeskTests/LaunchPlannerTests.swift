import XCTest
@testable import SnapDesk

final class LaunchPlannerTests: XCTestCase {
    private let safariID = "com.apple.Safari"
    private let safariPath = "/Applications/Safari.app"
    private let previewID = "com.apple.Preview"
    private let previewPath = "/System/Applications/Preview.app"

    private func makeDocument(moveExistingWindows: Bool) -> WorkspaceDocument {
        WorkspaceDocument(
            version: WorkspaceDocument.currentVersion,
            name: "Test",
            moveExistingWindows: moveExistingWindows,
            displays: [],
            windows: [
                savedWindow(
                    bundleIdentifier: safariID,
                    bundlePath: safariPath,
                    name: "Safari",
                    arguments: "--new-window"
                ),
                savedWindow(
                    bundleIdentifier: safariID,
                    bundlePath: safariPath,
                    name: "Safari",
                    arguments: ""
                ),
                savedWindow(
                    bundleIdentifier: previewID,
                    bundlePath: previewPath,
                    name: "Preview",
                    arguments: ""
                ),
            ]
        )
    }

    private func savedWindow(
        bundleIdentifier: String,
        bundlePath: String,
        name: String,
        arguments: String,
        document: String? = nil
    ) -> SavedWindow {
        SavedWindow(
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundlePath,
            name: name,
            title: "",
            displayId: "display",
            x: 0,
            y: 0,
            width: 100,
            height: 100,
            minimized: false,
            zoomed: false,
            document: document,
            arguments: arguments
        )
    }

    func testMoveExistingOnNoneRunning() {
        let doc = makeDocument(moveExistingWindows: true)
        let plans = LaunchPlanner.plan(document: doc, runningBundleIDs: [])

        XCTAssertEqual(plans.count, 3)
        XCTAssertEqual(
            plans[0],
            .launch(arguments: ["--new-window"], newInstance: false)
        )
        XCTAssertEqual(plans[1], .reuse)
        XCTAssertEqual(
            plans[2],
            .launch(arguments: [], newInstance: false)
        )
    }

    func testMoveExistingOnSafariAlreadyRunning() {
        let doc = makeDocument(moveExistingWindows: true)
        let plans = LaunchPlanner.plan(document: doc, runningBundleIDs: [safariID])

        XCTAssertEqual(plans.count, 3)
        XCTAssertEqual(plans[0], .reuse)
        XCTAssertEqual(plans[1], .reuse)
        XCTAssertEqual(
            plans[2],
            .launch(arguments: [], newInstance: false)
        )
    }

    func testMoveExistingOffLaunchesAllAsNewInstance() {
        let doc = makeDocument(moveExistingWindows: false)
        let plans = LaunchPlanner.plan(document: doc, runningBundleIDs: [safariID, previewID])

        XCTAssertEqual(plans.count, 3)
        XCTAssertEqual(
            plans[0],
            .launch(arguments: ["--new-window"], newInstance: true)
        )
        XCTAssertEqual(
            plans[1],
            .launch(arguments: [], newInstance: true)
        )
        XCTAssertEqual(
            plans[2],
            .launch(arguments: [], newInstance: true)
        )
    }

    func testSingleInstanceForcedOntoReuseWhenMoveExistingOff() {
        let settingsID = "com.apple.systempreferences"
        let settingsPath = "/System/Applications/System Settings.app"
        let doc = WorkspaceDocument(
            version: WorkspaceDocument.currentVersion,
            name: "Settings",
            moveExistingWindows: false,
            displays: [],
            windows: [
                savedWindow(bundleIdentifier: settingsID, bundlePath: settingsPath, name: "Settings", arguments: ""),
                savedWindow(bundleIdentifier: settingsID, bundlePath: settingsPath, name: "Settings", arguments: ""),
                savedWindow(bundleIdentifier: safariID, bundlePath: safariPath, name: "Safari", arguments: ""),
            ]
        )

        let plans = LaunchPlanner.plan(
            document: doc,
            runningBundleIDs: [],
            prohibitsMultipleInstances: { bundleID, _ in bundleID == settingsID }
        )

        XCTAssertEqual(
            plans[0],
            .launch(arguments: [], newInstance: false)
        )
        XCTAssertEqual(plans[1], .reuse)
        XCTAssertEqual(
            plans[2],
            .launch(arguments: [], newInstance: true)
        )
    }

    func testSingleInstanceAlreadyRunningReusesEverySlot() {
        let settingsID = "com.apple.systempreferences"
        let settingsPath = "/System/Applications/System Settings.app"
        let doc = WorkspaceDocument(
            version: WorkspaceDocument.currentVersion,
            name: "Settings",
            moveExistingWindows: false,
            displays: [],
            windows: [
                savedWindow(bundleIdentifier: settingsID, bundlePath: settingsPath, name: "Settings", arguments: ""),
                savedWindow(bundleIdentifier: settingsID, bundlePath: settingsPath, name: "Settings", arguments: ""),
            ]
        )

        let plans = LaunchPlanner.plan(
            document: doc,
            runningBundleIDs: [settingsID],
            prohibitsMultipleInstances: { bundleID, _ in bundleID == settingsID }
        )

        XCTAssertEqual(plans[0], .reuse)
        XCTAssertEqual(plans[1], .reuse)
    }

    func testPlaceOrderDescending() {
        XCTAssertEqual(LaunchPlanner.placeOrder(windowCount: 3), [2, 1, 0])
        // Stated separately because this is the point of the reversal: slot 0 is placed last so it
        // ends up frontmost. Ascending order would still visit every slot and still place every
        // window, so only an assertion about the order catches a flip.
        XCTAssertEqual(LaunchPlanner.placeOrder(windowCount: 3).last, 0)
        XCTAssertEqual(LaunchPlanner.placeOrder(windowCount: 1), [0])
    }

    func testPlaceOrderEmpty() {
        XCTAssertEqual(LaunchPlanner.placeOrder(windowCount: 0), [])
    }

    // MARK: Documents

    /// Every document slot opens, which is the opposite of the group rule for plain launches
    /// where only the first slot opens at all. Each open is what brings that slot's window into
    /// being, so skipping the second one is how three saved windows came back as one.
    func testEveryDocumentSlotOpensEvenWhenTheGroupWouldOtherwiseReuse() {
        let document = WorkspaceDocument(
            version: WorkspaceDocument.currentVersion,
            name: "Docs",
            moveExistingWindows: true,
            displays: [],
            windows: [
                savedWindow(
                    bundleIdentifier: safariID,
                    bundlePath: safariPath,
                    name: "Safari",
                    arguments: "",
                    document: "https://example.com/a"
                ),
                savedWindow(
                    bundleIdentifier: safariID,
                    bundlePath: safariPath,
                    name: "Safari",
                    arguments: "",
                    document: "https://example.com/b"
                ),
            ]
        )

        let actions = LaunchPlanner.plan(document: document, runningBundleIDs: [safariID])

        XCTAssertEqual(
            actions,
            [
                .openDocument(url: URL(string: "https://example.com/a")!, arguments: [], newInstance: false),
                .openDocument(url: URL(string: "https://example.com/b")!, arguments: [], newInstance: false),
            ]
        )
    }

    /// With "move existing windows" off, only the group's first document slot asks for a new
    /// instance. Otherwise three saved pages would open three copies of the browser instead of
    /// three windows in one.
    func testOnlyTheFirstDocumentSlotOfAGroupAsksForANewInstance() {
        let document = WorkspaceDocument(
            version: WorkspaceDocument.currentVersion,
            name: "Docs",
            moveExistingWindows: false,
            displays: [],
            windows: [
                savedWindow(
                    bundleIdentifier: safariID,
                    bundlePath: safariPath,
                    name: "Safari",
                    arguments: "",
                    document: "https://example.com/a"
                ),
                savedWindow(
                    bundleIdentifier: safariID,
                    bundlePath: safariPath,
                    name: "Safari",
                    arguments: "",
                    document: "https://example.com/b"
                ),
            ]
        )

        let actions = LaunchPlanner.plan(document: document, runningBundleIDs: [])

        XCTAssertEqual(
            actions.map { action -> Bool? in
                if case .openDocument(_, _, let newInstance) = action { return newInstance }
                return nil
            },
            [true, false]
        )
    }

    /// A document that is not a location cannot be opened, so the slot falls back to the ordinary
    /// launch rules rather than planning an open that would certainly fail. Capture already
    /// filters these out; a hand-edited file is refused by `validate()`. This is the third line.
    func testASlotWhoseDocumentIsNotUsableFallsBackToAPlainLaunch() {
        let document = WorkspaceDocument(
            version: WorkspaceDocument.currentVersion,
            name: "Docs",
            moveExistingWindows: true,
            displays: [],
            windows: [
                savedWindow(
                    bundleIdentifier: safariID,
                    bundlePath: safariPath,
                    name: "Safari",
                    arguments: "",
                    document: "Untitled 3"
                ),
            ]
        )

        let actions = LaunchPlanner.plan(document: document, runningBundleIDs: [])

        XCTAssertEqual(actions, [.launch(arguments: [], newInstance: false)])
    }
}
