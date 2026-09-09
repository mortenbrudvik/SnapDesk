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
        arguments: String
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
            arguments: arguments
        )
    }

    func testMoveExistingOnNoneRunning() {
        let doc = makeDocument(moveExistingWindows: true)
        let plans = LaunchPlanner.plan(document: doc, runningBundleIDs: [])

        XCTAssertEqual(plans.count, 3)
        XCTAssertEqual(
            plans[0],
            SlotPlan(
                index: 0,
                action: .launch(
                    bundleIdentifier: safariID,
                    path: safariPath,
                    arguments: ["--new-window"],
                    newInstance: false
                )
            )
        )
        XCTAssertEqual(plans[1], SlotPlan(index: 1, action: .reuse))
        XCTAssertEqual(
            plans[2],
            SlotPlan(
                index: 2,
                action: .launch(
                    bundleIdentifier: previewID,
                    path: previewPath,
                    arguments: [],
                    newInstance: false
                )
            )
        )
    }

    func testMoveExistingOnSafariAlreadyRunning() {
        let doc = makeDocument(moveExistingWindows: true)
        let plans = LaunchPlanner.plan(document: doc, runningBundleIDs: [safariID])

        XCTAssertEqual(plans.count, 3)
        XCTAssertEqual(plans[0], SlotPlan(index: 0, action: .reuse))
        XCTAssertEqual(plans[1], SlotPlan(index: 1, action: .reuse))
        XCTAssertEqual(
            plans[2],
            SlotPlan(
                index: 2,
                action: .launch(
                    bundleIdentifier: previewID,
                    path: previewPath,
                    arguments: [],
                    newInstance: false
                )
            )
        )
    }

    func testMoveExistingOffLaunchesAllAsNewInstance() {
        let doc = makeDocument(moveExistingWindows: false)
        let plans = LaunchPlanner.plan(document: doc, runningBundleIDs: [safariID, previewID])

        XCTAssertEqual(plans.count, 3)
        XCTAssertEqual(
            plans[0],
            SlotPlan(
                index: 0,
                action: .launch(
                    bundleIdentifier: safariID,
                    path: safariPath,
                    arguments: ["--new-window"],
                    newInstance: true
                )
            )
        )
        XCTAssertEqual(
            plans[1],
            SlotPlan(
                index: 1,
                action: .launch(
                    bundleIdentifier: safariID,
                    path: safariPath,
                    arguments: [],
                    newInstance: true
                )
            )
        )
        XCTAssertEqual(
            plans[2],
            SlotPlan(
                index: 2,
                action: .launch(
                    bundleIdentifier: previewID,
                    path: previewPath,
                    arguments: [],
                    newInstance: true
                )
            )
        )
    }

    func testPlaceOrderDescending() {
        XCTAssertEqual(LaunchPlanner.placeOrder(windowCount: 3), [2, 1, 0])
    }

    func testPlaceOrderEmpty() {
        XCTAssertEqual(LaunchPlanner.placeOrder(windowCount: 0), [])
    }
}
