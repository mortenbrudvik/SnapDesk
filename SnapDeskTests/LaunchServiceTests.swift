import ApplicationServices
import XCTest
@testable import SnapDesk

@MainActor
final class LaunchServiceTests: XCTestCase {
    private let safariID = "com.apple.Safari"
    private let safariPath = "/Applications/Safari.app"
    private let previewID = "com.apple.Preview"
    private let previewPath = "/System/Applications/Preview.app"
    private let notesID = "com.apple.Notes"
    private let notesPath = "/System/Applications/Notes.app"

    private let display = LiveDisplay(
        id: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
        name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 38, width: 1512, height: 916),
        scale: 2
    )

    /// Exactly twice the built-in display, so a slot saved here has a frame that is halved when it
    /// has to be restored onto the built-in one.
    private let secondaryDisplay = LiveDisplay(
        id: "A1B2C3D4-EXTERNAL",
        name: "LG UltraFine",
        frame: CGRect(x: 1512, y: 0, width: 3024, height: 1890),
        visibleFrame: CGRect(x: 1512, y: 0, width: 3024, height: 1832),
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
                SlotProgress(index: 0, name: "Safari", status: .placed(.clean)),
                SlotProgress(index: 1, name: "Preview", status: .placed(.clean)),
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
                SlotProgress(index: 0, name: "Safari", status: .failed(.appNotFound)),
                SlotProgress(index: 1, name: "Preview", status: .placed(.clean)),
            ]
        )
        XCTAssertEqual(launcher.opens.map(\.url), [URL(fileURLWithPath: previewPath)])
        XCTAssertEqual(placer.placements.map(\.window.id), [previewWindow.id])
        XCTAssertEqual(apps.activated, [previewID])
    }

    func testFallsBackToTheSavedBundlePathWhenTheBundleIDIsUnknown() async {
        let launcher = FakeLauncher()
        launcher.urls = [:]
        launcher.existingPaths = [safariPath]
        let windows = FakeWindows(windowsByBundle: [safariID: [safariWindow]])
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, windows: windows, placer: placer)

        let result = await service.launch(
            makeDocument(moveExistingWindows: false, windows: [safariSlot(title: "GitHub")])
        ) { _ in }

        XCTAssertEqual(result, [SlotProgress(index: 0, name: "Safari", status: .placed(.clean))])
        XCTAssertEqual(launcher.opens.map(\.url), [URL(fileURLWithPath: safariPath)])
        XCTAssertEqual(placer.placements.map(\.window.id), [safariWindow.id])
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
                SlotProgress(index: 0, name: "Safari", status: .failed(.couldNotPosition)),
                SlotProgress(index: 1, name: "Preview", status: .placed(.clean)),
            ]
        )
        XCTAssertEqual(placer.placements.map(\.window.id), [previewWindow.id, safariWindow.id])
        XCTAssertEqual(apps.activated, [previewID])
    }

    /// The frame was written and the window sits on it; only the saved zoom or minimize did not
    /// take. "Could not position" for that sends the user looking at a window that is exactly
    /// where they saved it, so the slot gets a failure that says what is actually missing.
    func testASavedStateThatDidNotTakeIsReportedAsSuchNotAsCouldNotPosition() async {
        let launcher = FakeLauncher()
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            previewID: URL(fileURLWithPath: previewPath),
        ]
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow],
            previewID: [previewWindow],
        ])
        let placer = FakePlacer()
        placer.outcomes = [safariWindow.id: .stateNotRestored]
        let service = makeService(launcher: launcher, windows: windows, placer: placer)

        let result = await service.launch(makeDocument(moveExistingWindows: false)) { _ in }

        XCTAssertEqual(result.map(\.status), [.failed(.stateNotRestored), .placed(.clean)])
    }

    /// The window a slot claimed can be gone by the time the placement pass reaches it — closed,
    /// or retitled under the title-based fallback identity. That is a different problem from a
    /// refused write, and the HUD has to be able to say so.
    func testAWindowThatVanishedBeforePlacementIsReportedAsGone() async {
        let launcher = FakeLauncher()
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            previewID: URL(fileURLWithPath: previewPath),
        ]
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow],
            previewID: [previewWindow],
        ])
        let placer = FakePlacer()
        placer.outcomes = [safariWindow.id: .windowGone]
        let service = makeService(launcher: launcher, windows: windows, placer: placer)

        let result = await service.launch(makeDocument(moveExistingWindows: false)) { _ in }

        XCTAssertEqual(result.map(\.status), [.failed(.windowGone), .placed(.clean)])
    }

    /// Cancelling is something the user did, so the slots it stops report `.cancelled` rather than
    /// a failure: a failure beeps, pins the HUD open and is logged as a fault.
    func testCancelDuringALaunchMarksEverySlotThatIsNotDoneYet() async {
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

        let result = await service.launch(makeDocument(moveExistingWindows: false)) { progress in
            if progress[0].status == .launching {
                service.cancel()
            }
        }

        XCTAssertEqual(
            result,
            [
                SlotProgress(index: 0, name: "Safari", status: .cancelled),
                SlotProgress(index: 1, name: "Preview", status: .cancelled),
            ]
        )
        XCTAssertEqual(launcher.opens.map(\.url), [URL(fileURLWithPath: safariPath)])
    }

    /// A Cancel click that lands while the HUD is auto-dismissing a finished restore has no launch
    /// to cancel. It must not be held against the next one.
    func testCancelWithNothingInFlightDoesNotPoisonTheNextLaunch() async {
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

        let first = await service.launch(makeDocument(moveExistingWindows: false)) { _ in }
        XCTAssertTrue(first.allSatisfy { $0.status == .placed(.clean) })

        service.cancel()

        let second = await service.launch(makeDocument(moveExistingWindows: false)) { _ in }

        XCTAssertEqual(
            second,
            [
                SlotProgress(index: 0, name: "Safari", status: .placed(.clean)),
                SlotProgress(index: 1, name: "Preview", status: .placed(.clean)),
            ]
        )
    }

    /// A Cancel click while a second restore is queued behind the running one has to reach the
    /// queued one too. It is part of what the user just stopped, nothing else will ever cancel it,
    /// and letting it start seconds later re-opens the HUD they were getting rid of.
    func testCancelReachesARestoreThatIsStillWaitingItsTurn() async {
        let launcher = FakeLauncher()
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            previewID: URL(fileURLWithPath: previewPath),
        ]
        let openGate = OpenGate()
        launcher.openGate = openGate
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow],
            previewID: [previewWindow],
        ])
        let service = makeService(launcher: launcher, windows: windows)
        let document = makeDocument(moveExistingWindows: false)

        let running = Task { @MainActor in await service.launch(document) { _ in } }
        await yieldUntil("the first restore reaches the launcher") { openGate.arrivals > 0 }
        let queued = Task { @MainActor in await service.launch(document) { _ in } }
        // Lets the queued restore reach the gate, which is what makes it something a cancel can
        // still be aimed at.
        await yieldUntil("the second restore reaches the gate") { service.queuedRestores > 0 }

        service.cancel()
        // Nothing releases a second parking, and the running restore has one more slot to open.
        launcher.openGate = nil
        openGate.releaseAll()

        _ = await running.value
        let queuedResult = await queued.value

        XCTAssertEqual(queuedResult.map(\.status), [.cancelled, .cancelled])
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
                SlotProgress(index: 0, name: "Safari", status: .placed(.clean)),
                SlotProgress(index: 1, name: "Preview", status: .failed(.launchTimedOut)),
            ]
        )
        XCTAssertEqual(launcher.opens.map(\.url), [URL(fileURLWithPath: safariPath)])
        XCTAssertEqual(placer.placements.map(\.window.id), [safariWindow.id])
        XCTAssertEqual(apps.activated, [safariID])
    }

    /// `NSWorkspace.openApplication` does not observe cancellation: its completion handler arrives
    /// when LaunchServices is done, however long that takes. Racing it inside a structured task
    /// group therefore bounded the *error* and not the wait — the group had to await the launch
    /// before it could rethrow the timeout — so a bundle that took 90s to open held the whole
    /// restore, and the HUD's Cancel button, for those 90s. The fake above honours cancellation,
    /// which is exactly why `testLaunchTimeoutFailsSlotAndContinues` could not see this.
    func testALaunchThatIgnoresCancellationStillTimesOutOnSchedule() async {
        let launcher = FakeLauncher()
        let safariURL = URL(fileURLWithPath: safariPath)
        launcher.urls = [
            safariID: safariURL,
            previewID: URL(fileURLWithPath: previewPath),
        ]
        launcher.neverReturnURLs = [safariURL]
        addTeardownBlock { @MainActor in launcher.releaseParked() }
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow],
            previewID: [previewWindow],
        ])
        let service = makeService(launcher: launcher, windows: windows, launchTimeout: .milliseconds(50))
        let outcome = Outcome()

        let run = Task { @MainActor in
            outcome.result = await service.launch(makeDocument(moveExistingWindows: false)) { _ in }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while outcome.result == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        guard let result = outcome.result else {
            run.cancel()
            return XCTFail("the restore must not wait for a launch that never returns")
        }
        XCTAssertEqual(result.map(\.status), [.failed(.launchTimedOut), .placed(.clean)])
        XCTAssertEqual(launcher.opens.map(\.url), [URL(fileURLWithPath: previewPath)])
    }

    @MainActor
    private final class Outcome {
        var result: [SlotProgress]?
    }

    /// A rejected open — Gatekeeper, a damaged bundle — is a different failure from a hang, and the
    /// HUD has to be able to tell the user which one happened.
    func testRejectedOpenIsReportedAsLaunchFailedNotTimedOut() async {
        struct Rejected: Error {}
        let launcher = FakeLauncher()
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            previewID: URL(fileURLWithPath: previewPath),
        ]
        launcher.openError = Rejected()
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow],
            previewID: [previewWindow],
        ])
        let service = makeService(launcher: launcher, windows: windows)

        let result = await service.launch(makeDocument(moveExistingWindows: false)) { _ in }

        XCTAssertEqual(
            result.map(\.status),
            [.failed(.launchFailed), .failed(.launchFailed)]
        )
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
                    safariSlot(title: "GitHub", x: 0, y: 0, width: 800, height: 900),
                    safariSlot(title: "Apple", x: 100, y: 50, width: 400, height: 300),
                ]
            )
        ) { _ in }

        XCTAssertEqual(
            result,
            [
                SlotProgress(index: 0, name: "Safari", status: .placed(.clean)),
                SlotProgress(index: 1, name: "Safari", status: .placed(.clean)),
            ]
        )
        XCTAssertEqual(launcher.opens.count, 1)
        XCTAssertEqual(launcher.opens[0].url, URL(fileURLWithPath: safariPath))
        XCTAssertFalse(launcher.opens[0].configuration.createsNewApplicationInstance)
        // Ordered, and paired with the frame each window received: a set of window ids cannot tell
        // correct title matching apart from the two slots' windows being swapped.
        XCTAssertEqual(placer.placements.map(\.window.id), [safariWindow2.id, safariWindow.id])
        XCTAssertEqual(
            placer.placements.map(\.cocoaFrame),
            [
                CGRect(x: 100, y: 88, width: 400, height: 300),
                CGRect(x: 0, y: 38, width: 800, height: 900),
            ]
        )
    }

    /// Turning "move existing windows" off means the user's live windows are left alone and every
    /// slot gets a fresh instance. The catalog lists every process running under a bundle id, so
    /// without a pid filter the restore claimed the user's own "GitHub" window by exact title —
    /// and moved it — before the new instance had vended anything; the pre-existing windows also
    /// counted as vended, so nothing waited for the new instance at all.
    func testANewInstanceRestoreLeavesThePreExistingInstancesWindowsAlone() async {
        let existing = MatchableWindow(id: "safari-old", pid: 100, bundleIdentifier: safariID, title: "GitHub")
        let fresh = MatchableWindow(id: "safari-new", pid: 200, bundleIdentifier: safariID, title: "GitHub")
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let apps = FakeApps()
        apps.running = [safariID]
        apps.pids = [safariID: [100]]
        let windows = FakeWindows(windowsByBundle: [safariID: [existing]])
        let clock = ScriptedClock()
        windows.vend(fresh, afterPolls: 2, on: clock)
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, apps: apps, windows: windows, placer: placer, clock: clock)

        let result = await service.launch(
            makeDocument(moveExistingWindows: false, windows: [safariSlot(title: "GitHub")])
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.placed(.clean)])
        XCTAssertEqual(placer.placements.map(\.window.id), [fresh.id], "the user's own window must not be moved")
        XCTAssertEqual(launcher.opens.count, 1)
        XCTAssertTrue(launcher.opens[0].configuration.createsNewApplicationInstance)
        XCTAssertEqual(apps.activatedPIDs, [200], "the instance holding the restored window comes forward, not the old one")
    }

    /// Plenty of apps ignore `createsNewApplicationInstance` and simply activate the copy that is
    /// already running. Every window then belongs to the pre-existing pid, the filter removes them
    /// all — correctly, the user asked for their own windows to be left alone — and the slot has
    /// nothing to take. Reporting "No window" for an app with six windows on screen sends the user
    /// looking for a bug; this is a different thing and says so.
    func testAnAppThatRefusesToOpenANewInstanceIsReportedAsSuchNotAsNoWindow() async {
        let existing = MatchableWindow(id: "safari-old", pid: 100, bundleIdentifier: safariID, title: "GitHub")
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let apps = FakeApps()
        apps.running = [safariID]
        apps.pids = [safariID: [100]]
        let windows = FakeWindows(windowsByBundle: [safariID: [existing]])
        let clock = ScriptedClock()
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, apps: apps, windows: windows, placer: placer, clock: clock)

        let result = await service.launch(
            makeDocument(moveExistingWindows: false, windows: [safariSlot(title: "GitHub")])
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.failed(.noNewWindow)])
        XCTAssertTrue(placer.placements.isEmpty, "the window the user already had must not be moved")
    }

    /// The window list being unreadable at placement time is not the window having disappeared:
    /// one is an app that stopped answering, the other a window that closed. Both arrived as the
    /// same `nil`, and so as the same "Window disappeared".
    func testAWindowListThatCannotBeReadAtPlacementTimeIsNotReportedAsAClosedWindow() async {
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let windows = FakeWindows(windowsByBundle: [safariID: [safariWindow]])
        let placer = FakePlacer()
        placer.outcomes = [safariWindow.id: .windowsUnreadable]
        let service = makeService(launcher: launcher, windows: windows, placer: placer)

        let result = await service.launch(
            makeDocument(moveExistingWindows: false, windows: [safariSlot(title: "GitHub")])
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.failed(.windowsUnreadable)])
    }

    /// A Cancel while a slot is mid-launch used to wait out that open — up to the launch timeout,
    /// per slot — because nothing woke the wait. The HUD's Cancel button is the one control that
    /// has to answer immediately.
    func testCancelDuringASlowLaunchIsActedOnAtOnce() async {
        let launcher = FakeLauncher()
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            previewID: URL(fileURLWithPath: previewPath),
        ]
        let openGate = OpenGate()
        launcher.openGate = openGate
        addTeardownBlock { @MainActor in openGate.releaseAll() }
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow],
            previewID: [previewWindow],
        ])
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, windows: windows, placer: placer)

        let outcome = Outcome()
        let run = Task { @MainActor in
            outcome.result = await service.launch(makeDocument(moveExistingWindows: false)) { _ in }
        }
        await yieldUntil("the first launch to be in flight") { openGate.arrivals > 0 }

        service.cancel()
        // Deliberately not `await run.value`: if the cancel does not wake the open, that awaits a
        // continuation nobody will ever resume and the whole suite wedges with no output. This
        // fails instead.
        await yieldUntil("the restore to come back without waiting for the open") { outcome.result != nil }
        run.cancel()

        XCTAssertEqual(outcome.result?.map(\.status), [.cancelled, .cancelled])
        XCTAssertTrue(placer.placements.isEmpty)
        // Nothing released the gate: the restore came back without sitting through the open.
        XCTAssertEqual(openGate.arrivals, 1)
    }

    /// Two new-instance slots of one app. The pids to exclude are read *once*, before the first
    /// launch — re-reading before the second would exclude the instance the first slot just
    /// created, and strand its window. Nothing else in the suite can tell those two apart.
    func testASecondNewInstanceOfTheSameAppIsNotMistakenForThePreExistingOne() async {
        let existing = MatchableWindow(id: "safari-old", pid: 100, bundleIdentifier: safariID, title: "Old")
        let firstNew = MatchableWindow(id: "safari-new-1", pid: 200, bundleIdentifier: safariID, title: "GitHub")
        let secondNew = MatchableWindow(id: "safari-new-2", pid: 300, bundleIdentifier: safariID, title: "Apple")
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let apps = FakeApps()
        apps.running = [safariID]
        apps.pids = [safariID: [100]]
        let windows = FakeWindows(windowsByBundle: [safariID: [existing]])
        let clock = ScriptedClock()
        // Each launch brings up an instance, and the pid list grows the way the real one would.
        launcher.onOpen = { _ in
            if windows.windowsByBundle[self.safariID]?.count == 1 {
                windows.windowsByBundle[self.safariID]?.append(firstNew)
                apps.pids[self.safariID] = [100, 200]
            } else {
                windows.windowsByBundle[self.safariID]?.append(secondNew)
                apps.pids[self.safariID] = [100, 200, 300]
            }
        }
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, apps: apps, windows: windows, placer: placer, clock: clock)

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: false,
                windows: [
                    safariSlot(title: "GitHub", x: 0, y: 0, width: 800, height: 900),
                    safariSlot(title: "Apple", x: 100, y: 50, width: 400, height: 300),
                ]
            )
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.placed(.clean), .placed(.clean)])
        XCTAssertEqual(launcher.opens.count, 2)
        XCTAssertEqual(
            placer.placements.map(\.window.id),
            [secondNew.id, firstNew.id],
            "both new instances' windows are claimable; only the pre-existing one is off limits"
        )
        XCTAssertFalse(placer.placements.contains { $0.window.id == existing.id })
    }

    /// The reuse path, end to end: a running app is not launched again, it is un-hidden (a ⌘H'd
    /// app's windows would otherwise be placed and stay invisible), and its existing windows —
    /// which the new-instance path filters out — are exactly the ones a reuse claims.
    func testAReusedRunningAppIsUnhiddenNotRelaunchedAndItsOwnWindowsAreClaimed() async {
        let github = MatchableWindow(id: "safari-1", pid: 100, bundleIdentifier: safariID, title: "GitHub")
        let apple = MatchableWindow(id: "safari-2", pid: 100, bundleIdentifier: safariID, title: "Apple")
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let apps = FakeApps()
        apps.running = [safariID]
        apps.pids = [safariID: [100]]
        let windows = FakeWindows(windowsByBundle: [safariID: [github, apple]])
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, apps: apps, windows: windows, placer: placer)

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: true,
                windows: [
                    safariSlot(title: "GitHub", x: 0, y: 0, width: 800, height: 900),
                    safariSlot(title: "Apple", x: 100, y: 50, width: 400, height: 300),
                ]
            )
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.placed(.clean), .placed(.clean)])
        XCTAssertTrue(launcher.opens.isEmpty, "a running app is reused, never launched again")
        XCTAssertEqual(apps.unhidden, [safariID, safariID])
        XCTAssertEqual(placer.placements.map(\.window.id), [apple.id, github.id])
        XCTAssertEqual(apps.activatedPIDs, [100])
    }

    /// Three saved Safari windows, one live window. The low-index slots are the ones the user
    /// listed first and the one `activateFrontmost` expects to have won, so slot 0 gets the window
    /// even though placement walks the slots back-to-front.
    func testScarceWindowsGoToTheLowestIndexedSlots() async {
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let apps = FakeApps()
        let windows = FakeWindows(windowsByBundle: [safariID: [safariWindow]])
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
                    safariSlot(title: "One", x: 0, y: 0, width: 800, height: 900),
                    safariSlot(title: "Two", x: 100, y: 50, width: 400, height: 300),
                    safariSlot(title: "Three", x: 200, y: 60, width: 300, height: 200),
                ]
            )
        ) { _ in }

        // Slot 0 took the one window as a leftover, so its "Placed" carries the guess note.
        XCTAssertEqual(
            result.map(\.status),
            [.placed(PlacementNote(isGuess: true, substituteDisplay: nil)), .failed(.noWindow), .failed(.noWindow)]
        )
        XCTAssertEqual(placer.placements.map(\.window.id), [safariWindow.id])
        XCTAssertEqual(placer.placements.map(\.cocoaFrame), [CGRect(x: 0, y: 38, width: 800, height: 900)])
        XCTAssertEqual(apps.activated, [safariID])
    }

    /// The workspace saved three Safari windows and the user has since closed the first one's.
    /// Both survivors must go back to *their* saved rect: handing windows out greedily in slot
    /// order gives slot 0 the window slot 1 is named after, and every survivor lands on the wrong
    /// frame while the slot whose window is genuinely gone looks like the one that worked.
    func testEachSurvivingWindowGoesBackToItsOwnSavedFrame() async {
        let mail = MatchableWindow(id: "safari-mail", bundleIdentifier: safariID, title: "Mail")
        let news = MatchableWindow(id: "safari-news", bundleIdentifier: safariID, title: "News")
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let windows = FakeWindows(windowsByBundle: [safariID: [mail, news]])
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, windows: windows, placer: placer)

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: true,
                windows: [
                    safariSlot(title: "Docs", x: 0, y: 0, width: 800, height: 900),
                    safariSlot(title: "Mail", x: 100, y: 50, width: 400, height: 300),
                    safariSlot(title: "News", x: 200, y: 60, width: 300, height: 200),
                ]
            )
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.failed(.noWindow), .placed(.clean), .placed(.clean)])
        // Placement walks the slots back-to-front, so News is written before Mail.
        XCTAssertEqual(placer.placements.map(\.window.id), [news.id, mail.id])
        XCTAssertEqual(
            placer.placements.map(\.cocoaFrame),
            [
                CGRect(x: 200, y: 98, width: 300, height: 200),
                CGRect(x: 100, y: 88, width: 400, height: 300),
            ]
        )
    }

    /// A slot that has been given its window says so straight away. Everything matched otherwise
    /// sits at "Launching" until the slowest app has run out the whole window timeout.
    func testASlotReportsItsClaimBeforeThePlacementPassRuns() async {
        let launcher = FakeLauncher()
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            previewID: URL(fileURLWithPath: previewPath),
        ]
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow],
            previewID: [previewWindow],
        ])
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, windows: windows, placer: placer)

        var snapshots: [[SlotProgress]] = []
        _ = await service.launch(makeDocument(moveExistingWindows: false)) { snapshots.append($0) }

        let firstPlacement = snapshots.firstIndex { snapshot in
            snapshot.contains { $0.status == .placed(.clean) }
        }
        let bothMatched = snapshots.firstIndex { snapshot in
            snapshot.allSatisfy { $0.status == .matched }
        }
        XCTAssertNotNil(bothMatched)
        XCTAssertNotNil(firstPlacement)
        if let bothMatched, let firstPlacement {
            XCTAssertLessThan(bothMatched, firstPlacement)
        }
    }

    func testMinimizedAndZoomedStatesReachThePlacer() async {
        let launcher = FakeLauncher()
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            previewID: URL(fileURLWithPath: previewPath),
        ]
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow],
            previewID: [previewWindow],
        ])
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, windows: windows, placer: placer)

        _ = await service.launch(
            makeDocument(
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
                        height: 900,
                        minimized: true
                    ),
                    savedWindow(
                        bundleIdentifier: previewID,
                        bundlePath: previewPath,
                        name: "Preview",
                        title: "Notes",
                        x: 100,
                        y: 50,
                        width: 400,
                        height: 300,
                        zoomed: true
                    ),
                ]
            )
        ) { _ in }

        XCTAssertEqual(placer.placements.map(\.window.id), [previewWindow.id, safariWindow.id])
        XCTAssertEqual(placer.placements.map(\.minimized), [false, true])
        XCTAssertEqual(placer.placements.map(\.zoomed), [true, false])
    }

    /// The saved display is gone, so the slot lands on the only live one — at half the size,
    /// because that display's visible frame is half as wide and half as tall.
    func testSlotSavedOnAMissingDisplayIsScaledOntoTheLiveOne() async {
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let windows = FakeWindows(windowsByBundle: [safariID: [safariWindow]])
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, windows: windows, placer: placer)

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: false,
                displays: [savedDisplay(display), savedDisplay(secondaryDisplay)],
                windows: [
                    safariSlot(
                        title: "GitHub",
                        displayId: secondaryDisplay.id,
                        x: 100,
                        y: 100,
                        width: 400,
                        height: 300
                    ),
                ]
            )
        ) { _ in }

        XCTAssertEqual(
            result.map(\.status),
            [.placed(PlacementNote(isGuess: false, substituteDisplay: display.name))],
            "a window aimed at a substitute screen is placed, and says which screen it went to"
        )
        XCTAssertEqual(placer.placements.map(\.cocoaFrame), [CGRect(x: 50, y: 88, width: 200, height: 150)])
    }

    /// Same display, half the resolution it was captured at — the frame is scaled rather than
    /// restored verbatim and then clamped.
    func testSameDisplayAtALowerResolutionScalesTheFrame() async {
        let shrunk = LiveDisplay(
            id: display.id,
            name: display.name,
            frame: CGRect(x: 0, y: 0, width: 756, height: 491),
            visibleFrame: CGRect(x: 0, y: 19, width: 756, height: 458),
            scale: 2
        )
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let windows = FakeWindows(windowsByBundle: [safariID: [safariWindow]])
        let placer = FakePlacer()
        let service = makeService(
            launcher: launcher,
            windows: windows,
            placer: placer,
            displays: [shrunk]
        )

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: false,
                windows: [safariSlot(title: "GitHub", x: 100, y: 50, width: 400, height: 300)]
            )
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.placed(.clean)])
        XCTAssertEqual(placer.placements.map(\.cocoaFrame), [CGRect(x: 50, y: 44, width: 200, height: 150)])
    }

    func testNoLiveDisplaysFailsEverySlotWithoutPlacingAnything() async {
        let launcher = FakeLauncher()
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            previewID: URL(fileURLWithPath: previewPath),
        ]
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow],
            previewID: [previewWindow],
        ])
        let placer = FakePlacer()
        let service = makeService(
            launcher: launcher,
            windows: windows,
            placer: placer,
            displays: []
        )

        let result = await service.launch(makeDocument(moveExistingWindows: false)) { _ in }

        // Not "could not position", which describes a window that refused a write: with nothing
        // attached there is no frame to compute in the first place.
        XCTAssertEqual(result.map(\.status), [.failed(.noDisplay), .failed(.noDisplay)])
        XCTAssertTrue(placer.placements.isEmpty)
    }

    /// A slot whose app never vends anything must not wait forever, and must not wait longer than
    /// the configured timeout says.
    func testTheWaitForAWindowIsBoundedByTheWindowTimeout() async {
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let windows = FakeWindows(windowsByBundle: [:])
        // A frozen clock, so only the poll *count* can end this wait: under a clock whose `now`
        // advances, the wall-clock deadline would expire at the same moment and the assertion
        // below would hold even with the count removed.
        let clock = CountingClock()
        let service = makeService(
            launcher: launcher,
            windows: windows,
            clock: clock,
            windowTimeout: .milliseconds(250)
        )

        let result = await service.launch(
            makeDocument(moveExistingWindows: false, windows: [safariSlot(title: "GitHub")])
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.failed(.noWindow)])
        // 250ms of 100ms polls.
        XCTAssertEqual(clock.sleeps, 3)
    }

    /// The window wait was bounded by a poll count, and each poll reads Accessibility synchronously
    /// on the main thread — up to `AXWindow.messagingTimeout` per read against a hung app. Eighty
    /// polls at half a second each is forty seconds with the main actor blocked, not the eight the
    /// timeout promises, so the wait has to answer to the clock as well as to the count.
    func testTheWindowWaitIsBoundedByWallClockTimeWhenEachPollIsSlow() async {
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let windows = FakeWindows(windowsByBundle: [:])
        let clock = ScriptedClock()
        windows.onRead = { clock.advance(by: .milliseconds(500)) }
        let service = makeService(launcher: launcher, windows: windows, clock: clock)

        let result = await service.launch(
            makeDocument(moveExistingWindows: false, windows: [safariSlot(title: "GitHub")])
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.failed(.noWindow)])
        XCTAssertGreaterThanOrEqual(clock.elapsed, .seconds(8), "the budget is still spent in full")
        XCTAssertLessThan(
            clock.elapsed,
            .seconds(8) + .milliseconds(600),
            "and overrun by at most one slow poll, not by the whole poll count: \(clock.sleeps) sleeps"
        )
    }

    /// Nothing cancels the task a restore runs in today, but a restore inside a cancelled task
    /// would otherwise degrade badly rather than stop: `Task.sleep` throws at once when its task
    /// is cancelled, so every timed wait becomes a zero-delay loop that burns the poll budget
    /// instantly and reports `.noWindow` for slots that merely had not vended yet.
    func testACancelledTaskEndsTheRestoreAsCancelled() async {
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let windows = FakeWindows(windowsByBundle: [:])
        let clock = ScriptedClock()
        let service = makeService(launcher: launcher, windows: windows, clock: clock)
        let document = makeDocument(moveExistingWindows: false, windows: [safariSlot(title: "GitHub")])

        let run = Task { @MainActor in await service.launch(document) { _ in } }
        clock.onSleep = { count in
            if count == 2 { run.cancel() }
        }
        let result = await run.value

        XCTAssertEqual(result.map(\.status), [.cancelled])
        XCTAssertEqual(clock.sleeps, 2, "cut short at the poll the cancellation landed in")
    }

    /// The scenario a cold launch is made of: an app hands its windows over one at a time, in an
    /// order of its own that has nothing to do with the order the workspace saved them in. Safari
    /// has "Mail" up at once and only gets round to "Docs" later, so slot 0 has nothing it can use
    /// on the first look. Giving up there strands it — and strands the Docs window, which arrives
    /// to find nobody waiting for it — while the beep and the pinned HUD report a failure that the
    /// restore caused itself.
    func testASlotWaitsForItsOwnWindowWhenTheAppVendsItLate() async {
        let mail = MatchableWindow(id: "safari-mail", bundleIdentifier: safariID, title: "Mail")
        let docs = MatchableWindow(id: "safari-docs", bundleIdentifier: safariID, title: "Docs")
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let windows = FakeWindows(windowsByBundle: [safariID: [mail]])
        let clock = ScriptedClock()
        windows.vend(docs, afterPolls: 3, on: clock)
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, windows: windows, placer: placer, clock: clock)

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: true,
                windows: [
                    safariSlot(title: "Docs", x: 0, y: 0, width: 800, height: 900),
                    safariSlot(title: "Mail", x: 100, y: 50, width: 400, height: 300),
                ]
            )
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.placed(.clean), .placed(.clean)])
        // Paired ids and frames, not a set: swapping the two windows would leave both slots placed
        // and every count unchanged. Placement walks the slots back-to-front, so Mail is written
        // first.
        XCTAssertEqual(placer.placements.map(\.window.id), [mail.id, docs.id])
        XCTAssertEqual(
            placer.placements.map(\.cocoaFrame),
            [
                CGRect(x: 100, y: 88, width: 400, height: 300),
                CGRect(x: 0, y: 38, width: 800, height: 900),
            ]
        )
        // The restore went on as soon as the late window arrived rather than sitting out the rest
        // of the timeout.
        XCTAssertEqual(clock.sleeps, 3)
    }

    /// Same late vend, three slots, and the app hands its windows over back-to-front. Every slot
    /// has to end up on its own saved frame; a slot that settles for whatever is up when it looks
    /// takes the window a later slot is named after and both land in the wrong place.
    func testEverySlotStillGetsItsOwnWindowWhenTheyVendInReverseOrder() async {
        let news = MatchableWindow(id: "safari-news", bundleIdentifier: safariID, title: "News")
        let mail = MatchableWindow(id: "safari-mail", bundleIdentifier: safariID, title: "Mail")
        let docs = MatchableWindow(id: "safari-docs", bundleIdentifier: safariID, title: "Docs")
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let windows = FakeWindows(windowsByBundle: [safariID: [news]])
        let clock = ScriptedClock()
        windows.vend(mail, afterPolls: 1, on: clock)
        windows.vend(docs, afterPolls: 4, on: clock)
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, windows: windows, placer: placer, clock: clock)

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: true,
                windows: [
                    safariSlot(title: "Docs", x: 0, y: 0, width: 800, height: 900),
                    safariSlot(title: "Mail", x: 100, y: 50, width: 400, height: 300),
                    safariSlot(title: "News", x: 200, y: 60, width: 300, height: 200),
                ]
            )
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.placed(.clean), .placed(.clean), .placed(.clean)])
        XCTAssertEqual(placer.placements.map(\.window.id), [news.id, mail.id, docs.id])
        XCTAssertEqual(
            placer.placements.map(\.cocoaFrame),
            [
                CGRect(x: 200, y: 98, width: 300, height: 200),
                CGRect(x: 100, y: 88, width: 400, height: 300),
                CGRect(x: 0, y: 38, width: 800, height: 900),
            ]
        )
    }

    /// The other half of the wait: it must not hold the restore up when nothing more is coming.
    /// Safari has as many windows up as the workspace saved, they have simply been renamed since —
    /// a browser retitles a window every time the page does — so the leftovers go out at once
    /// rather than after the timeout.
    func testTitlesThatChangedSinceTheCaptureDoNotWaitOutTheTimeout() async {
        let first = MatchableWindow(id: "safari-1", bundleIdentifier: safariID, title: "Renamed one")
        let second = MatchableWindow(id: "safari-2", bundleIdentifier: safariID, title: "Renamed two")
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let windows = FakeWindows(windowsByBundle: [safariID: [first, second]])
        let clock = ScriptedClock()
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, windows: windows, placer: placer, clock: clock)
        var sleepsWhenPlaced: Int?

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: true,
                windows: [
                    safariSlot(title: "Docs", x: 0, y: 0, width: 800, height: 900),
                    safariSlot(title: "Mail", x: 100, y: 50, width: 400, height: 300),
                ]
            )
        ) { progress in
            if sleepsWhenPlaced == nil, progress.allSatisfy(\.status.isPlaced) {
                sleepsWhenPlaced = clock.sleeps
            }
        }

        // Both slots settled for a window they are not named after, and nothing corrected that:
        // the HUD has to say so, or a layout with two swapped windows reads as a clean restore.
        let guess = PlacementNote(isGuess: true, substituteDisplay: nil)
        XCTAssertEqual(result.map(\.status), [.placed(guess), .placed(guess)])
        // The layout the user is waiting for goes up without a single sleep. Both slots settled for
        // a window they are not named after, so the correction pass below does run afterwards — but
        // it runs after placement and after `activateFrontmost`, so it costs the restore nothing
        // visible. Asserting on the *placement* rather than on the final sleep count is what keeps
        // that distinction honest.
        XCTAssertEqual(sleepsWhenPlaced, 0)
        // Leftovers in slot order: slot 0 is the one `activateFrontmost` expects to have won.
        XCTAssertEqual(placer.placements.map(\.window.id), [second.id, first.id])
    }

    /// REPRODUCTION of the start-page failure, on the measured timeline rather than a described
    /// one. Safari is saved with two slots, "Docs" and "Mail". At t=0 it vends "Mail" plus a start
    /// page — two windows, which is exactly the count the workspace expects — so the app looks
    /// finished on the very first poll and slot 0 settles for the start page. The real "Docs"
    /// window arrives in the window-restoration second wave, measured at 2.5-3.7s (poll 25 here),
    /// with nobody left waiting for it.
    ///
    /// Vend gaps were measured bimodal with an empty middle: same-batch <=19ms, restoration wave
    /// at 2565-3706ms. That is why no quiet period both settles fast and covers this case.
    func testStartPageIsTakenWhileTheRealWindowIsStillComing() async {
        let startPage = MatchableWindow(id: "safari-start", bundleIdentifier: safariID, title: "Startside")
        let mail = MatchableWindow(id: "safari-mail", bundleIdentifier: safariID, title: "Mail")
        let docs = MatchableWindow(id: "safari-docs", bundleIdentifier: safariID, title: "Docs")

        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let windows = FakeWindows(windowsByBundle: [safariID: [mail, startPage]])
        let clock = ScriptedClock()
        windows.vend(docs, afterPolls: 25, on: clock)
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, windows: windows, placer: placer, clock: clock)

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: true,
                windows: [
                    safariSlot(title: "Docs", x: 0, y: 0, width: 800, height: 900),
                    safariSlot(title: "Mail", x: 100, y: 50, width: 400, height: 300),
                ]
            )
        ) { _ in }

        XCTAssertEqual(
            result.map(\.status),
            [.placed(.clean), .placed(.clean)],
            "the correction replaced the guess, so slot 0 is no longer reported as holding another window"
        )
        let placedIDs = placer.placements.map(\.window.id)
        XCTAssertTrue(
            placedIDs.contains(docs.id),
            """
            slot "Docs" must end up holding the real Docs window, not the start page it settled \
            for. Placed: \(placedIDs)
            """
        )

        // The guessed window keeps the frame it was given: nothing here knows where it belongs
        // instead, and the correction lands on the same frame afterwards, so the right window ends
        // up on top and the guess is fully behind it.
        let docsSlotFrame = placer.placements.first { $0.window.id == startPage.id }?.cocoaFrame
        let corrected = placer.placements.last { $0.window.id == docs.id }
        XCTAssertEqual(corrected?.cocoaFrame, docsSlotFrame, "the real window must take the slot's frame")
        XCTAssertGreaterThan(
            placedIDs.lastIndex(of: docs.id) ?? -1,
            placedIDs.firstIndex(of: startPage.id) ?? .max,
            "the correction must be placed after the guess so it ends up in front of it"
        )
    }

    /// Whether an app can still turn up a window is a fact about *that app*. Safari has vended both
    /// windows the workspace saved — under new titles — so its slots can settle at once, even though
    /// Notes in the same workspace never vends and holds the restore open for the full timeout.
    /// Deciding it across the whole restore instead left Safari's slots sitting at "Matching" for
    /// eight seconds because of an unrelated app, which is the stall `.matched` exists to prevent.
    func testAFinishedAppsSlotsSettleWhileAnotherAppIsStillBeingWaitedFor() async {
        let first = MatchableWindow(id: "safari-1", bundleIdentifier: safariID, title: "Renamed one")
        let second = MatchableWindow(id: "safari-2", bundleIdentifier: safariID, title: "Renamed two")
        let launcher = FakeLauncher()
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            notesID: URL(fileURLWithPath: notesPath),
        ]
        // Notes is listed but never vends a window, so it polls out the whole timeout.
        let windows = FakeWindows(windowsByBundle: [safariID: [first, second]])
        let clock = ScriptedClock()
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, windows: windows, placer: placer, clock: clock)

        var safariSettledAfter: Int?
        let result = await service.launch(
            makeDocument(
                moveExistingWindows: true,
                windows: [
                    safariSlot(title: "Docs", x: 0, y: 0, width: 800, height: 900),
                    safariSlot(title: "Mail", x: 100, y: 50, width: 400, height: 300),
                    savedWindow(
                        bundleIdentifier: notesID,
                        bundlePath: notesPath,
                        name: "Notes",
                        title: "Inbox",
                        x: 0, y: 0, width: 300, height: 300
                    ),
                ]
            )
        ) { progress in
            if safariSettledAfter == nil, progress[0].status == .matched, progress[1].status == .matched {
                safariSettledAfter = clock.sleeps
            }
        }

        let guess = PlacementNote(isGuess: true, substituteDisplay: nil)
        XCTAssertEqual(result.map(\.status), [.placed(guess), .placed(guess), .failed(.noWindow)])
        XCTAssertEqual(
            safariSettledAfter,
            0,
            "Safari had vended everything the workspace expected of it, so its slots must not wait on Notes"
        )
    }

    /// The moment a Cancel is most likely to be clicked: a slot is parked waiting on an app that
    /// has not vended a window yet. Letting the wait run its course reports the slot the user was
    /// waiting on as a failure — which beeps, pins the HUD open and logs a fault — for a restore
    /// they deliberately stopped, and does it eight seconds after they asked.
    func testCancelWhileASlotIsParkedInTheWindowWaitEndsItAsCancelled() async {
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let windows = FakeWindows(windowsByBundle: [:])
        let clock = ScriptedClock()
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, windows: windows, placer: placer, clock: clock)
        clock.onSleep = { count in
            if count == 2 { service.cancel() }
        }

        let result = await service.launch(
            makeDocument(moveExistingWindows: false, windows: [safariSlot(title: "GitHub")])
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.cancelled])
        // Cut short at the poll the click landed in, not run out to the 8s timeout's 80 polls.
        XCTAssertEqual(clock.sleeps, 2)
        XCTAssertTrue(placer.placements.isEmpty)
    }

    /// The moment a Cancel actually lands during a real restore: placement, where the real placer
    /// blocks up to two seconds per window waiting for a deminiaturize. The slot being placed and
    /// everything after it end `.cancelled`, and nothing is brought forward afterwards — the user
    /// stopped the restore, and activating an app they did not ask for is the restore carrying on.
    func testCancelDuringAPlacementEndsTheRestoreWithoutActivatingAnything() async {
        let launcher = FakeLauncher()
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            previewID: URL(fileURLWithPath: previewPath),
            notesID: URL(fileURLWithPath: notesPath),
        ]
        let apps = FakeApps()
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow],
            previewID: [previewWindow],
            notesID: [notesWindow],
        ])
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, apps: apps, windows: windows, placer: placer)
        // Placement walks back to front: Notes is placed, and the Cancel lands during it — a
        // placement that *succeeds*, which is the common case and the one that used to fall
        // through to `activateFrontmost` anyway.
        placer.onPlace = { window in
            if window.id == self.notesWindow.id { service.cancel() }
        }

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: false,
                windows: [
                    safariSlot(title: "GitHub"),
                    savedWindow(bundleIdentifier: previewID, bundlePath: previewPath, name: "Preview", title: "Notes", x: 100, y: 50, width: 400, height: 300),
                    savedWindow(bundleIdentifier: notesID, bundlePath: notesPath, name: "Notes", title: "Inbox", x: 200, y: 60, width: 300, height: 200),
                ]
            )
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.cancelled, .cancelled, .placed(.clean)])
        XCTAssertEqual(placer.placements.map(\.window.id), [notesWindow.id], "the restore stops where the click landed")
        XCTAssertTrue(apps.activated.isEmpty, "a cancelled restore must not bring an app forward")
    }

    /// A correction whose placement is refused — the window closed again between the read and the
    /// write — must not consume the slot's chance: the window can vend once more inside the
    /// correction window, and the slot is still holding a guess until it does.
    func testARefusedCorrectionLeavesTheSlotOpenToALaterWindow() async {
        let startPage = MatchableWindow(id: "safari-start", bundleIdentifier: safariID, title: "Startside")
        let mail = MatchableWindow(id: "safari-mail", bundleIdentifier: safariID, title: "Mail")
        let docsFirst = MatchableWindow(id: "safari-docs-1", bundleIdentifier: safariID, title: "Docs")
        let docsAgain = MatchableWindow(id: "safari-docs-2", bundleIdentifier: safariID, title: "Docs")
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let windows = FakeWindows(windowsByBundle: [safariID: [mail, startPage]])
        let clock = ScriptedClock()
        windows.vend(docsFirst, afterPolls: 3, on: clock)
        windows.vend(docsAgain, afterPolls: 6, on: clock)
        let placer = FakePlacer()
        placer.outcomes = [docsFirst.id: .windowGone]
        let service = makeService(launcher: launcher, windows: windows, placer: placer, clock: clock)

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: true,
                windows: [
                    safariSlot(title: "Docs", x: 0, y: 0, width: 800, height: 900),
                    safariSlot(title: "Mail", x: 100, y: 50, width: 400, height: 300),
                ]
            )
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.placed(.clean), .placed(.clean)], "the second Docs window corrected the guess")
        XCTAssertEqual(placer.placements.map(\.window.id), [mail.id, startPage.id, docsFirst.id, docsAgain.id])
    }

    /// The correction window is 4s of 100ms polls, and a window arriving after it is left alone.
    func testTheCorrectionWindowIsBoundedAndALateWindowIsNotSwappedIn() async {
        let first = MatchableWindow(id: "safari-1", bundleIdentifier: safariID, title: "Renamed one")
        let second = MatchableWindow(id: "safari-2", bundleIdentifier: safariID, title: "Renamed two")
        let docs = MatchableWindow(id: "safari-docs", bundleIdentifier: safariID, title: "Docs")
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let windows = FakeWindows(windowsByBundle: [safariID: [first, second]])
        let clock = ScriptedClock()
        windows.vend(docs, afterPolls: 41, on: clock)
        let placer = FakePlacer()
        let service = makeService(launcher: launcher, windows: windows, placer: placer, clock: clock)

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: true,
                windows: [
                    safariSlot(title: "Docs", x: 0, y: 0, width: 800, height: 900),
                    safariSlot(title: "Mail", x: 100, y: 50, width: 400, height: 300),
                ]
            )
        ) { _ in }

        let guess = PlacementNote(isGuess: true, substituteDisplay: nil)
        XCTAssertEqual(result.map(\.status), [.placed(guess), .placed(guess)])
        XCTAssertEqual(clock.sleeps, 40, "4s of 100ms polls, then the guess stands")
        XCTAssertFalse(placer.placements.contains { $0.window.id == docs.id })
    }

    /// An app whose window list could not be read on any poll — it never answered within the AX
    /// timeout, or Accessibility refused — has not vended nothing; nobody could look. "No window"
    /// sends the user waiting for an app that will never be readable, so it gets its own failure.
    func testWindowsThatCannotBeReadOnAnyPollFailAsUnreadableNotAsNoWindow() async {
        let launcher = FakeLauncher()
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            previewID: URL(fileURLWithPath: previewPath),
        ]
        let windows = FakeWindows(windowsByBundle: [previewID: [previewWindow]])
        windows.failingBundles = [safariID]
        let clock = ScriptedClock()
        let service = makeService(launcher: launcher, windows: windows, clock: clock)

        let result = await service.launch(makeDocument(moveExistingWindows: false)) { _ in }

        XCTAssertEqual(result.map(\.status), [.failed(.windowsUnreadable), .placed(.clean)])
    }

    func testOverlappingLaunchesRunSequentially() async {
        let launcher = FakeLauncher()
        launcher.urls = [
            safariID: URL(fileURLWithPath: safariPath),
            previewID: URL(fileURLWithPath: previewPath),
            notesID: URL(fileURLWithPath: notesPath),
        ]
        launcher.yieldBeforeOpen = true
        let windows = FakeWindows(windowsByBundle: [
            safariID: [safariWindow],
            previewID: [previewWindow],
            notesID: [notesWindow],
        ])
        let service = makeService(launcher: launcher, windows: windows)
        let documents = [
            makeDocument(moveExistingWindows: false, windows: [safariSlot(title: "GitHub")]),
            makeDocument(
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
            ),
            makeDocument(
                moveExistingWindows: false,
                windows: [
                    savedWindow(
                        bundleIdentifier: notesID,
                        bundlePath: notesPath,
                        name: "Notes",
                        title: "Inbox",
                        x: 200,
                        y: 60,
                        width: 300,
                        height: 200
                    ),
                ]
            ),
        ]

        let running = documents.map { document in
            Task { @MainActor in
                await service.launch(document) { _ in }
            }
        }
        for task in running {
            _ = await task.value
        }

        XCTAssertEqual(launcher.maxInFlightOpens, 1)
        XCTAssertEqual(launcher.opens.count, 3)
    }

    /// Releasing the gate must hand ownership straight to the waiter. Clearing the flag first and
    /// letting the waiter re-take it leaves a window — between the resume and the waiter actually
    /// running — in which a caller arriving fresh sees an idle gate and starts alongside it.
    func testGateStaysHeldWhileHandingOffToAWaiter() async {
        let gate = LaunchGate()
        let waiterRan = Flag()

        let ticket = await gate.acquire()
        XCTAssertTrue(gate.isHeld)

        let waiter = Task { @MainActor in
            let own = await gate.acquire()
            waiterRan.value = true
            gate.release(own)
        }
        await Task.yield()
        XCTAssertFalse(waiterRan.value)

        gate.release(ticket)

        XCTAssertFalse(waiterRan.value)
        XCTAssertTrue(gate.isHeld)

        await waiter.value
        XCTAssertTrue(waiterRan.value)
        XCTAssertFalse(gate.isHeld)
    }

    /// Only the holder can release. A stale ticket — a release that arrives twice, or from a run
    /// that is no longer the holder — must not hand the gate to a waiter while the real holder is
    /// still restoring, which would run two restores at once.
    func testAStaleTicketCannotReleaseTheGate() async {
        let gate = LaunchGate()
        let waiterRan = Flag()

        let first = await gate.acquire()
        gate.release(first)
        let second = await gate.acquire()
        let waiter = Task { @MainActor in
            let own = await gate.acquire()
            waiterRan.value = true
            gate.release(own)
        }
        await Task.yield()
        XCTAssertEqual(gate.waiterCount, 1)

        gate.release(first)
        await Task.yield()

        XCTAssertFalse(waiterRan.value, "a stale ticket must not wake the waiter")
        XCTAssertTrue(gate.isHeld)

        gate.release(second)
        await waiter.value
        XCTAssertTrue(waiterRan.value)
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
                SlotProgress(index: 0, name: "System Settings", status: .placed(.clean)),
                SlotProgress(index: 1, name: "System Settings", status: .placed(.clean)),
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

    /// `setMinimized(false)` returning `.success` only means the window server took the write; the
    /// window is still in the Dock while it animates back, and a frame written to it there is
    /// swallowed — silently, since that write answers `.success` too.
    func testTheFrameIsWrittenOnlyAfterTheWindowIsActuallyOutOfTheDock() async {
        let window = FakeAXWindow(isMinimized: true)
        let clock = ScriptedClock()
        clock.onSleep = { poll in
            if poll == 3 { window.isMinimized = false }
        }
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: false,
            zoomed: false,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(window.frameWrites, [frame])
        XCTAssertEqual(window.minimizedAtFrameWrite, [false])
        XCTAssertEqual(clock.sleeps, 3)
    }

    func testAWindowThatNeverLeavesTheDockIsReportedRatherThanWrittenTo() async {
        let window = FakeAXWindow(isMinimized: true)
        let clock = ScriptedClock()

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            minimized: false,
            zoomed: false,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .refused)
        XCTAssertTrue(window.frameWrites.isEmpty)
        // Bounded: 2s of 50ms polls. One wedged app cannot stall the rest of the restore.
        XCTAssertEqual(clock.sleeps, 40)
    }

    /// The read that says whether a window is minimized is the one that fails for the window that
    /// has been minimized longest: the app is swapped out, so its first AX message can miss the
    /// messaging timeout. Branching on the lossy `isMinimized` took that for "not minimized",
    /// skipped the un-minimize, and wrote a frame into the Dock — which swallows it and answers
    /// `.success`, so the slot was reported "Placed" without moving.
    func testAWindowWhoseMinimizedStateCannotBeReadIsUnMinimizedRatherThanAssumedToBeUp() async {
        let window = FakeAXWindow()
        window.minimizedState = nil
        let clock = ScriptedClock()
        clock.onSleep = { poll in
            if poll == 3 { window.minimizedState = false }
        }
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: false,
            zoomed: false,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(window.unminimizeWrites, 1, "an unreadable state must be written to, not assumed")
        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(window.frameWrites, [frame])
        XCTAssertEqual(clock.sleeps, 3, "the frame waits for the state to become readable and false")
    }

    /// The other half, and a deliberate reversal of what this asserted a round ago. An unreadable
    /// minimized state is not evidence that the window is in the Dock — it is what a live window
    /// answers when its app misses the AX messaging timeout — so treating the unverifiable outcome
    /// as fatal refused to place perfectly ordinary windows behind a slow AX server. The blind
    /// un-minimize is still sent (that part of the round-1 fix is pinned below), and the wait is
    /// still made, but the frame write is now the judge: it is the only step here that can actually
    /// report on the window.
    func testAWindowWhoseMinimizedStateStaysUnreadableIsStillPlaced() async {
        let window = FakeAXWindow()
        window.minimizedState = nil
        let clock = ScriptedClock()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: false,
            zoomed: false,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(window.unminimizeWrites, 1, "an unreadable state must still be written to")
        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(window.frameWrites, [frame])
        // Bounded: it waits the full 2s for the state to become readable before giving up on the
        // question and writing anyway. One unreadable window cannot stall the rest of the restore.
        XCTAssertEqual(clock.sleeps, 40)
    }

    /// The discriminating timeline between the two unreadable cases: the first read misses the AX
    /// messaging timeout, so the un-minimize is sent blind, and then the swapped-out app pages in
    /// and answers that the window is *still* in the Dock. That is an answer, and it is the same
    /// precondition failure as a window known to be minimized — the frame write would report
    /// success and move nothing. Reporting "Placed" here is the round-1 defect by another route.
    func testAWindowThatAnswersItIsStillInTheDockIsReportedRatherThanWrittenTo() async {
        let window = FakeAXWindow()
        window.minimizedState = nil
        let clock = ScriptedClock()
        // The app pages in on the first poll and says it never left the Dock.
        clock.onSleep = { _ in window.minimizedState = true }

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            minimized: false,
            zoomed: false,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(window.unminimizeWrites, 1, "the blind write must still be sent")
        XCTAssertEqual(outcome, .refused, "a window that says it is still minimized must not be reported placed")
        XCTAssertEqual(window.frameWrites, [], "nothing may be written to a window still in the Dock")
    }

    /// The un-minimize write itself being refused on a state that could not be read is the same
    /// non-verdict: nothing here says the window is in the Dock, so the frame write still gets its
    /// turn. Under the old lossy `AXError` this hit the un-minimize guard and reported
    /// "Could not position" for a window that was never minimized.
    func testARefusedUnMinimizeOnAnUnreadableStateStillPlacesTheWindow() async {
        let window = FakeAXWindow()
        window.minimizedState = nil
        window.unminimizeResult = .cannotComplete
        let clock = ScriptedClock()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: false,
            zoomed: false,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(window.frameWrites, [frame])
        XCTAssertEqual(clock.sleeps, 0, "a refused write left nothing in flight to wait for")
    }

    /// The refusal that *is* a verdict: the state was read, it said minimized, and the un-minimize
    /// was refused. Every write after this one lands in the Dock and answers `.success`, so the
    /// placement has to stop rather than report a window placed that the user never sees move.
    func testARefusedUnMinimizeOnAConfirmedMinimizedWindowFailsThePlacement() async {
        let window = FakeAXWindow(isMinimized: true)
        window.unminimizeResult = .cannotComplete
        let clock = ScriptedClock()

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            minimized: false,
            zoomed: false,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .refused)
        XCTAssertTrue(window.frameWrites.isEmpty)
        XCTAssertEqual(clock.sleeps, 0, "a refused write left nothing in flight to wait for")
    }

    /// A slot saved minimized on a window that is *already* minimized is already restored. Forcing
    /// it out of the Dock only to put it back is a visible flash, costs the deminiaturize wait, and
    /// the frame write in between would be swallowed by the Dock regardless.
    func testASlotSavedMinimizedLeavesAnAlreadyMinimizedWindowAlone() async {
        let window = FakeAXWindow(isMinimized: true)
        let clock = ScriptedClock()

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            minimized: true,
            zoomed: false,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(window.unminimizeWrites, 0)
        XCTAssertTrue(window.frameWrites.isEmpty)
        XCTAssertEqual(clock.sleeps, 0)
        XCTAssertEqual(window.minimizedState, true)
    }

    /// The short-circuit above is on a *confirmed* minimized only: an unreadable state is not
    /// evidence the window is already where the slot wants it, so it takes the full sequence.
    func testASlotSavedMinimizedStillPlacesAWindowWhoseStateCannotBeRead() async {
        let window = FakeAXWindow()
        window.minimizedState = nil
        let clock = ScriptedClock()
        clock.onSleep = { poll in
            // Readable, and up, at poll 2 — then back into the Dock once the placement asks.
            if poll == 2 { window.minimizedState = false }
            if poll == 4 { window.minimizedState = true }
        }
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: true,
            zoomed: false,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(window.frameWrites, [frame])
        XCTAssertEqual(window.minimizeWrites, 1, "the saved minimize is re-applied after the frame")
        XCTAssertEqual(window.minimizedState, true)
    }

    /// The skip is still a skip where it is safe to be one: a window confirmed to be up takes no
    /// un-minimize write and no wait, so the common case pays nothing for the honesty above.
    func testAWindowConfirmedToBeUpIsNotWrittenToOrWaitedFor() async {
        let window = FakeAXWindow(isMinimized: false)
        let clock = ScriptedClock()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: false,
            zoomed: false,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(window.unminimizeWrites, 0)
        XCTAssertEqual(clock.sleeps, 0)
        XCTAssertEqual(window.frameWrites, [frame])
    }

    /// The re-minimize at the end of a placement was written and never read back, so a window that
    /// cannot be miniaturized — a panel, a window without the button — reported the slot placed
    /// while sitting on screen. Every other state change here is polled until it flips; this one
    /// is too, and a state that never flips is `stateNotRestored`: the frame *was* applied.
    func testASavedMinimizeThatNeverTakesIsReportedRatherThanAssumed() async {
        let window = FakeAXWindow(isMinimized: false)
        let clock = ScriptedClock()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: true,
            zoomed: false,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .stateNotRestored)
        XCTAssertEqual(window.frameWrites, [frame], "the frame is still applied")
        XCTAssertEqual(window.minimizeWrites, 1)
        XCTAssertEqual(clock.sleeps, 40, "bounded: 2s of 50ms polls, like every other state wait")
    }

    /// The ordinary case: the write is accepted and the window goes into the Dock a moment later,
    /// which is what the wait is for — an AX write is asynchronous, so `.success` is not the state.
    func testASavedMinimizeThatTakesAfterAMomentIsAPlacement() async {
        let window = FakeAXWindow(isMinimized: false)
        let clock = ScriptedClock()
        clock.onSleep = { poll in
            if poll == 2 { window.minimizedState = true }
        }
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: true,
            zoomed: false,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(window.frameWrites, [frame])
        XCTAssertEqual(window.minimizedState, true)
        XCTAssertEqual(clock.sleeps, 2)
    }

    /// A window whose state could never be read is placed on the strength of the frame write alone
    /// — so when *that* is refused, there is nothing left that could have worked, and the slot has
    /// to be reported rather than assumed placed.
    func testAWindowWhoseFrameWriteIsRefusedIsNotReportedAsPlaced() async {
        let window = FakeAXWindow()
        window.minimizedState = nil
        window.frameResult = .cannotComplete
        let clock = ScriptedClock()

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            minimized: false,
            zoomed: false,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .refused)
    }

    /// `isZoomed` is inferred from the frame, so a non-resizable window parked at the visible frame
    /// reads as zoomed and has no zoom button to press. Aborting there loses a move that the frame
    /// write alone would have made.
    func testARefusedUnZoomStillLetsTheWindowBeMoved() async {
        let window = FakeAXWindow(isZoomed: true)
        window.unzoomResult = .attributeUnsupported
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: false,
            zoomed: false,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: ScriptedClock()
        )

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(window.frameWrites, [frame])
    }

    /// The saved state is what the user asked for, so a refusal there is still a failed placement.
    func testARefusedSavedZoomStillFailsThePlacement() async {
        let window = FakeAXWindow()
        window.zoomResult = .attributeUnsupported

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            minimized: false,
            zoomed: true,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: ScriptedClock()
        )

        XCTAssertEqual(outcome, .stateNotRestored, "the window is on its frame; only the saved zoom is missing")
    }

    /// The zoom press is a *toggle*: `-[NSWindow zoom:]` picks its own direction from the window's
    /// frame, so the argument does not aim it. A slot saved zoomed has the visible frame as its
    /// saved frame, and the placement writes that frame first — which means by the time the zoom
    /// step runs, the window is already zoomed and pressing sends it straight back off the frame
    /// that was just written, answering `.success` for having done it. The old code trusted that
    /// `.success` and reported "Placed" for a window sitting at its pre-zoom size.
    func testASlotSavedZoomedWhoseFrameIsAlreadyTheZoomTargetIsNotPressedOffIt() async {
        let window = FakeAXWindow()
        let clock = ScriptedClock()

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: window.zoomTarget,
            minimized: false,
            zoomed: true,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(window.frame, window.zoomTarget, "the window must end on the frame that was saved")
        XCTAssertEqual(window.zoomPresses, 0, "the state already answered the request")
        XCTAssertEqual(clock.sleeps, 0)
    }

    /// The companion: a window whose saved frame is *not* the zoom target does need the press, and
    /// gets exactly one. Reading `isZoomed` before pressing must not turn into never pressing.
    func testASlotSavedZoomedAwayFromTheZoomTargetStillGetsItsPress() async {
        let window = FakeAXWindow()
        let saved = CGRect(x: 40, y: 60, width: 500, height: 400)
        let clock = ScriptedClock()

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: saved,
            minimized: false,
            zoomed: true,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(window.frameWrites, [saved])
        XCTAssertEqual(window.zoomPresses, 1)
        XCTAssertTrue(window.isZoomed)
    }

    /// An app that overrides `windowWillUseStandardFrame:` zooms to a standard frame that is not
    /// the display's visible frame, so the frame-derived `isZoomed` never agrees that the press
    /// worked. The second attempt is what makes that recoverable — the first press read the window
    /// as already zoomed and un-zoomed it, the second puts it back — and the placement then reports
    /// the slot as not fully restored rather than claiming a zoom it cannot see.
    func testAZoomThatNeverReadsBackIsCorrectedOnceAndThenReportedHonestly() async {
        let window = FakeAXWindow()
        let standard = CGRect(x: 0, y: 0, width: 1_000, height: 875)
        window.standardFrame = standard
        let clock = ScriptedClock()

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: standard,
            minimized: false,
            zoomed: true,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .stateNotRestored, "an unverifiable zoom is reported, not assumed")
        XCTAssertEqual(window.frame, standard, "the correcting press put it back on its saved frame")
        XCTAssertEqual(window.zoomPresses, 2, "bounded: it does not press forever")
        // 2 attempts x 500ms of 50ms polls. Deliberately far short of the deminiaturize bound: a
        // zoom animates in a quarter second and is not a precondition for anything after it.
        XCTAssertEqual(clock.sleeps, 20)
    }

    // MARK: Fullscreen

    /// Entering fullscreen is the last thing the placement does, and the order is not cosmetic:
    /// the transition replaces the window's frame outright, so a frame written afterwards is
    /// thrown away by the window server.
    func testASlotSavedFullscreenEntersFullscreenAfterTheFrameIsWritten() async {
        let window = FakeAXWindow()
        let clock = ScriptedClock()
        clock.onSleep = { poll in if poll == 2 { window.fullscreenState = true } }
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: false,
            zoomed: false,
            fullscreen: true,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(window.frameWrites, [frame])
        XCTAssertEqual(window.fullscreenWrites, 1)
        XCTAssertEqual(
            window.fullscreenAtFrameWrite,
            [false],
            "the frame has to be written while the window is still out of fullscreen"
        )
    }

    /// Leaving fullscreen is the opposite half, and it is a *precondition* rather than a finishing
    /// touch: a fullscreen window swallows a frame write and answers `.success` for it, exactly as
    /// a minimized one does. So it happens before the frame, not after.
    func testASlotSavedNotFullscreenLeavesFullscreenBeforeTheFrameIsWritten() async {
        let window = FakeAXWindow(isFullscreen: true)
        let clock = ScriptedClock()
        clock.onSleep = { poll in if poll == 2 { window.fullscreenState = false } }
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: false,
            zoomed: false,
            fullscreen: false,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(window.frameWrites, [frame])
        XCTAssertEqual(window.fullscreenWrites, 1)
        XCTAssertEqual(
            window.fullscreenAtFrameWrite,
            [false],
            "the window has to be out of fullscreen before its frame is written"
        )
    }

    /// A window that will not come out of fullscreen is the same failure as one that will not come
    /// out of the Dock: nothing written after it lands, so the frame write is not even attempted
    /// and the slot is reported rather than claimed.
    func testAWindowThatWillNotLeaveFullscreenIsReportedRatherThanWrittenTo() async {
        let window = FakeAXWindow(isFullscreen: true)
        let clock = ScriptedClock()

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            minimized: false,
            zoomed: false,
            fullscreen: false,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .refused)
        XCTAssertTrue(window.frameWrites.isEmpty, "a fullscreen window swallows the frame write")
        XCTAssertEqual(clock.sleeps, 40, "bounded: one wedged window cannot stall the restore")
    }

    /// A window that refuses to *enter* fullscreen is a different matter: it is already on its
    /// saved frame, so this is the partial success a refused zoom reports, not a failure.
    /// Measured refusing: Activity Monitor and System Settings.
    func testAFullscreenThatNeverTakesIsReportedAsStateNotRestored() async {
        let window = FakeAXWindow()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let clock = ScriptedClock()

        let outcome = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: false,
            zoomed: false,
            fullscreen: true,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(outcome, .stateNotRestored)
        XCTAssertEqual(window.frame, frame, "the frame was applied even though the fullscreen was not")
        // 2s of 50ms polls — the deminiaturize bound rather than the zoom one, because a measured
        // fullscreen transition takes over a second where a zoom animates in a quarter of one.
        XCTAssertEqual(clock.sleeps, 40, "bounded, like every other state wait here")
    }

    /// A workspace written before the field existed says nothing about fullscreen, and nil is not
    /// false: such a slot must neither push a window into fullscreen nor drag one out. This is
    /// exactly the behaviour every build before this one had.
    func testANilFullscreenLeavesTheWindowAlone() async {
        let window = FakeAXWindow(isFullscreen: true)
        let clock = ScriptedClock()

        _ = await WindowPlacement.apply(
            to: window,
            cocoaFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            minimized: false,
            zoomed: false,
            fullscreen: nil,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(window.fullscreenState, true)
        XCTAssertEqual(window.fullscreenWrites, 0)
        XCTAssertEqual(clock.sleeps, 0)
    }

    // MARK: Documents

    /// The point of the whole feature. Arguments reach a *new* instance only, so a running app
    /// ignores them; opening a document works either way, which is what lets a cold start
    /// reproduce every window instead of the one the app felt like restoring.
    func testASlotWithADocumentOpensItRatherThanRelyingOnTheAppsOwnSession() async {
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let opener = FakeDocumentOpener()
        let windows = FakeWindows(windowsByBundle: [safariID: [safariWindow]])
        let service = makeService(launcher: launcher, opener: opener, windows: windows)

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: true,
                windows: [safariSlot(title: "GitHub", document: "https://example.com/docs")]
            )
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.placed(.clean)])
        XCTAssertEqual(opener.opened.map(\.document.absoluteString), ["https://example.com/docs"])
        XCTAssertEqual(opener.opened.map(\.app), [URL(fileURLWithPath: safariPath)])
        XCTAssertTrue(
            launcher.opens.isEmpty,
            "opening a document launches the app on its own; a second open is wasted work"
        )
    }

    /// Two slots of one app with two documents open two documents — exactly the case a cold start
    /// could not reproduce before, because the app decides for itself what to restore.
    ///
    /// Under `moveExistingWindows` neither asks for a new instance, so the two documents land as
    /// two windows of one app rather than as two copies of the app.
    func testEverySlotWithADocumentGetsItsOwnOpen() async {
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let opener = FakeDocumentOpener()
        let windows = FakeWindows(windowsByBundle: [safariID: [safariWindow, safariWindow2]])
        let service = makeService(launcher: launcher, opener: opener, windows: windows)

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: true,
                windows: [
                    safariSlot(title: "GitHub", document: "https://example.com/a"),
                    safariSlot(title: "Apple", document: "https://example.com/b"),
                ]
            )
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.placed(.clean), .placed(.clean)])
        XCTAssertEqual(
            opener.opened.map(\.document.absoluteString),
            ["https://example.com/a", "https://example.com/b"]
        )
        XCTAssertTrue(
            opener.opened.allSatisfy { !$0.configuration.createsNewApplicationInstance },
            "two documents belong in one app, not in two copies of it"
        )
    }

    /// A slot with no document behaves exactly as it did before any of this existed.
    func testASlotWithNoDocumentStillLaunchesTheAppNormally() async {
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let opener = FakeDocumentOpener()
        let windows = FakeWindows(windowsByBundle: [safariID: [safariWindow]])
        let service = makeService(launcher: launcher, opener: opener, windows: windows)

        let result = await service.launch(
            makeDocument(moveExistingWindows: false, windows: [safariSlot(title: "GitHub")])
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.placed(.clean)])
        XCTAssertTrue(opener.opened.isEmpty, "no document, no document open")
        XCTAssertEqual(launcher.opens.map(\.url), [URL(fileURLWithPath: safariPath)])
    }

    /// A refused open is a failure the user can act on — a moved file, a URL the app will not
    /// take — and not a silent fallthrough into the window wait, which would spend the whole
    /// eight-second budget and then report the vaguer "No window".
    func testADocumentThatCannotBeOpenedFailsTheSlot() async {
        struct Refused: Error {}
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let opener = FakeDocumentOpener()
        opener.openError = Refused()
        let windows = FakeWindows(windowsByBundle: [safariID: [safariWindow]])
        let service = makeService(launcher: launcher, opener: opener, windows: windows)

        let result = await service.launch(
            makeDocument(
                moveExistingWindows: true,
                windows: [safariSlot(title: "GitHub", document: "/Users/me/gone.txt")]
            )
        ) { _ in }

        XCTAssertEqual(result.map(\.status), [.failed(.documentFailed)])
    }

    func testEmptyDocumentReturnsEmptyWithoutLaunching() async {
        let launcher = FakeLauncher()
        let windows = FakeWindows()
        let service = makeService(launcher: launcher, windows: windows)
        var snapshots: [[SlotProgress]] = []

        let result = await service.launch(
            try! WorkspaceDocument(
                version: WorkspaceDocument.currentVersion,
                name: "Empty",
                moveExistingWindows: false,
                displays: [savedDisplay(display)],
                windows: []
            ).validated()
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

    private var notesWindow: MatchableWindow {
        MatchableWindow(id: "notes-1", bundleIdentifier: notesID, title: "Inbox")
    }

    /// Yields until the condition holds, and *fails* rather than spinning forever if it never
    /// does — an unbounded `while !condition { await Task.yield() }` turns a broken assumption
    /// into a hung suite with no output.
    private func yieldUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<10_000 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)", file: file, line: line)
    }

    private func makeService(
        launcher: FakeLauncher,
        apps: FakeApps = FakeApps(),
        opener: FakeDocumentOpener = FakeDocumentOpener(),
        windows: FakeWindows,
        placer: FakePlacer = FakePlacer(),
        displays: [LiveDisplay]? = nil,
        clock: any RestoreClock = FakeClock(),
        launchTimeout: Duration = .seconds(10),
        windowTimeout: Duration = .seconds(8),
        prohibitsMultipleInstances: @escaping (String, String) -> Bool = { _, _ in false }
    ) -> LaunchService {
        LaunchService(
            launcher: launcher,
            documentOpener: opener,
            apps: apps,
            windows: windows,
            placer: placer,
            displays: FakeLaunchDisplays(live: displays ?? [display]),
            clock: clock,
            launchTimeout: launchTimeout,
            windowTimeout: windowTimeout,
            prohibitsMultipleInstances: prohibitsMultipleInstances
        )
    }

    /// Every document a test restores is validated the way the app validates it — `LaunchService`
    /// only accepts the proof — so the fixtures here are exactly what a real restore would take.
    private func makeDocument(
        moveExistingWindows: Bool,
        displays: [SavedDisplay]? = nil,
        windows: [SavedWindow]? = nil
    ) -> ValidatedWorkspace {
        try! WorkspaceDocument(
            version: WorkspaceDocument.currentVersion,
            name: "Coding",
            moveExistingWindows: moveExistingWindows,
            displays: displays ?? [savedDisplay(display)],
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
        ).validated()
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

    private func savedDisplay(_ live: LiveDisplay) -> SavedDisplay {
        SavedDisplay(
            id: live.id,
            name: live.name,
            frame: CodableRect(live.frame),
            visibleFrame: CodableRect(live.visibleFrame),
            scale: Double(live.scale)
        )
    }

    private func safariSlot(
        title: String,
        displayId: String? = nil,
        x: Double = 0,
        y: Double = 0,
        width: Double = 800,
        height: Double = 900,
        document: String? = nil
    ) -> SavedWindow {
        savedWindow(
            bundleIdentifier: safariID,
            bundlePath: safariPath,
            name: "Safari",
            title: title,
            displayId: displayId,
            x: x,
            y: y,
            width: width,
            height: height,
            document: document
        )
    }

    private func savedWindow(
        bundleIdentifier: String,
        bundlePath: String,
        name: String,
        title: String,
        displayId: String? = nil,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        minimized: Bool = false,
        zoomed: Bool = false,
        document: String? = nil
    ) -> SavedWindow {
        SavedWindow(
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundlePath,
            name: name,
            title: title,
            displayId: displayId ?? display.id,
            x: x,
            y: y,
            width: width,
            height: height,
            minimized: minimized,
            zoomed: zoomed,
            document: document,
            arguments: ""
        )
    }
}

@MainActor
private final class Flag {
    var value = false
}

@MainActor
private final class FakeLauncher: ApplicationLaunching {
    var urls: [String: URL] = [:]
    var existingPaths: Set<String> = []
    /// Hang, but honour cancellation — the way a cooperative async call would.
    var hangURLs: Set<URL> = []
    /// Never come back at all, cancelled or not — the way `NSWorkspace.openApplication` behaves.
    var neverReturnURLs: Set<URL> = []
    var opens: [(url: URL, configuration: LaunchConfiguration)] = []
    var openError: (any Error)?
    var openGate: OpenGate?
    /// Runs when an open is accepted — where a test brings the launched instance into being.
    var onOpen: @MainActor (URL) -> Void = { _ in }
    var yieldBeforeOpen = false
    var inFlightOpens = 0
    var maxInFlightOpens = 0
    private var parked: [CheckedContinuation<Void, Never>] = []

    /// Lets go of every open parked by `neverReturnURLs`.
    func releaseParked() {
        let waiting = parked
        parked = []
        for continuation in waiting {
            continuation.resume()
        }
    }

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
        if let openGate {
            await openGate.park()
        }
        if hangURLs.contains(url) {
            try await Task.sleep(for: .seconds(60))
        }
        if neverReturnURLs.contains(url) {
            // Parked, and released in the test's teardown: a continuation nobody resumes leaks the
            // task and everything it captured for the life of the process.
            await withCheckedContinuation { parked.append($0) }
        }
        if let openError { throw openError }
        opens.append((url, configuration))
        onOpen(url)
    }
}

@MainActor
private final class FakeApps: RunningApplicationQuerying {
    var running: Set<String> = []
    /// The processes behind each running bundle id; empty for a bundle that is listed as running
    /// but whose pids a test does not care about.
    var pids: [String: Set<pid_t>] = [:]
    var unhidden: [String] = []
    var activated: [String] = []
    var activatedPIDs: [pid_t?] = []

    func runningBundleIDs() -> Set<String> { running }

    func runningPIDs(bundleIdentifier: String) -> Set<pid_t> {
        pids[bundleIdentifier] ?? []
    }

    func unhide(bundleIdentifier: String) {
        unhidden.append(bundleIdentifier)
    }

    func activate(bundleIdentifier: String, pid: pid_t?) {
        activated.append(bundleIdentifier)
        activatedPIDs.append(pid)
    }
}

extension MatchableWindow {
    /// Most tests do not care which process a window belongs to; pid 1 stands in.
    init(id: String, bundleIdentifier: String, title: String) {
        self.init(id: id, pid: 1, bundleIdentifier: bundleIdentifier, title: title)
    }
}

@MainActor
/// Records what was opened where. Deliberately separate from `FakeLauncher`: the point of the
/// whole feature is that these are two different calls with two different guarantees, and a test
/// that could not tell them apart would not be testing the difference.
private final class FakeDocumentOpener: DocumentOpening {
    var opened: [(document: URL, app: URL, configuration: LaunchConfiguration)] = []
    var openError: (any Error)?
    /// Runs when an open is accepted — where a test brings the resulting window into being.
    var onOpen: @MainActor (URL) -> Void = { _ in }

    func open(_ url: URL, withApplicationAt app: URL, configuration: LaunchConfiguration) async throws {
        if let openError { throw openError }
        opened.append((document: url, app: app, configuration: configuration))
        onOpen(url)
    }
}

private final class FakeWindows: WindowCatalog {
    var windowsByBundle: [String: [MatchableWindow]]
    var requireOpenBeforeWindows = false
    weak var launcher: FakeLauncher?
    /// Runs on every read, so a test can charge the clock for it.
    var onRead: @MainActor () -> Void = {}
    /// Bundles whose window list cannot be read at all — the app that never answers within the
    /// AX timeout, or a lost trust grant.
    var failingBundles: Set<String> = []

    init(windowsByBundle: [String: [MatchableWindow]] = [:]) {
        self.windowsByBundle = windowsByBundle
    }

    /// Makes a window appear the way a real one does — some way into the restore rather than at
    /// t=0. `clock` drives the poll count, so this is the fake's stand-in for "Safari got round to
    /// opening this tab 300ms after it launched".
    func vend(_ window: MatchableWindow, afterPolls polls: Int, on clock: ScriptedClock) {
        let existing = clock.onSleep
        clock.onSleep = { [weak self] count in
            existing(count)
            guard count == polls, let self else { return }
            self.windowsByBundle[window.bundleIdentifier, default: []].append(window)
        }
    }

    func standardWindows(bundleIdentifier: String) throws -> [MatchableWindow] {
        onRead()
        if failingBundles.contains(bundleIdentifier) {
            throw AXWindowListError(code: .cannotComplete)
        }
        guard windowsAreAvailable(for: bundleIdentifier) else { return [] }
        return windowsByBundle[bundleIdentifier] ?? []
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
        var fullscreen: Bool?
    }

    var placements: [Placement] = []
    var refuseIDs: Set<String>
    /// Per window id; anything not listed (and not refused) is placed cleanly.
    var outcomes: [String: PlacementOutcome] = [:]
    /// Runs before each placement is recorded — where a test lands a Cancel click mid-placement.
    var onPlace: @MainActor (MatchableWindow) -> Void = { _ in }

    init(refuseIDs: Set<String> = []) {
        self.refuseIDs = refuseIDs
    }

    func place(
        _ window: MatchableWindow,
        cocoaFrame: CGRect,
        minimized: Bool,
        zoomed: Bool,
        fullscreen: Bool?
    ) async -> PlacementOutcome {
        onPlace(window)
        placements.append(
            Placement(
                window: window,
                cocoaFrame: cocoaFrame,
                minimized: minimized,
                zoomed: zoomed,
                fullscreen: fullscreen
            )
        )
        if refuseIDs.contains(window.id) { return .refused }
        return outcomes[window.id] ?? .placed
    }
}

/// A window whose AX writes behave the way the real ones do: accepting a write says nothing about
/// when — or whether — the state actually changes. The test drives the change through the clock.
@MainActor
private final class FakeAXWindow: PlaceableWindow {
    /// Nil stands for the read that *failed*, which is the state the placer must not mistake for
    /// "not minimized": it is what a long-minimized window answers on its first AX message.
    var minimizedState: Bool?
    var unminimizeResult: AXError = .success
    var unzoomResult: AXError = .success
    var zoomResult: AXError = .success

    /// The zoom model is window-server-accurate rather than `AXWindow`-accurate, on purpose: the
    /// thing under test here is the *placement's* sequencing, so the fake has to be able to punish
    /// a press that was not needed. Real zoom state is not an attribute — it is inferred from the
    /// frame, and the press is a toggle AppKit aims from that same comparison.
    var frame: CGRect = .zero
    /// Stands in for the visible frame / standard frame: where a zoom takes the window.
    var zoomTarget = CGRect(x: 0, y: 0, width: 1_440, height: 875)
    /// Where a zoom would restore to.
    var userFrame = CGRect(x: 120, y: 90, width: 640, height: 480)
    /// Where a press actually lands, and the frame AppKit aims the toggle from. For an ordinary
    /// resizable window that is the zoom target, which is why this defaults to it; an app that
    /// overrides `windowWillUseStandardFrame:` (Safari, Finder) has one that is not, and the two
    /// tests diverging is what the placement's read-back has to survive.
    var standardFrame: CGRect?
    /// How many times the zoom button was actually pressed, so a press that was skipped can be told
    /// apart from one that was made and happened to land on the right frame.
    private(set) var zoomPresses = 0

    /// AppKit's own test is frame-derived, so the fake's is too.
    var isZoomed: Bool { frame == zoomTarget }

    private(set) var frameWrites: [CGRect] = []
    /// How many times the un-minimize was actually written, so a skipped write can be told apart
    /// from one that was attempted and refused.
    private(set) var unminimizeWrites = 0
    /// Whether the window was still in the Dock as each frame write landed. A real one swallows
    /// the write while it is, and answers `.success` regardless.
    private(set) var minimizedAtFrameWrite: [Bool] = []

    /// The lossy view, kept only so a test can flip the state in one word. Production code reads
    /// `minimizedState`.
    var isMinimized: Bool {
        get { minimizedState ?? false }
        set { minimizedState = newValue }
    }

    init(isMinimized: Bool = false, isZoomed: Bool = false, isFullscreen: Bool? = false) {
        self.minimizedState = isMinimized
        self.frame = isZoomed ? zoomTarget : userFrame
        self.fullscreenState = isFullscreen
    }

    /// Mirrors `AXWindow.unminimize`: the write is skipped on a confirmed false and on nothing
    /// else, and which of the two refusals happened is kept rather than flattened to an `AXError`.
    func unminimize() -> AXWindow.UnminimizeOutcome {
        switch minimizedState {
        case .some(false): return .alreadyUp
        case .some(true): return .wasMinimized(write: setMinimized(false))
        case nil: return .stateUnknown(write: setMinimized(false))
        }
    }

    /// Accepts the write and does *not* flip the state: an AX write is asynchronous, so a caller
    /// that needs the outcome has to read it back. Tests drive the flip through the clock, and a
    /// state that never flips is what a window that cannot be miniaturized does — while still
    /// answering `.success`.
    func setMinimized(_ minimized: Bool) -> AXError {
        guard minimized else {
            unminimizeWrites += 1
            return unminimizeResult
        }
        minimizeWrites += 1
        return .success
    }

    private(set) var minimizeWrites = 0

    /// A pure toggle: the argument does not aim it. `-[NSWindow zoom:]` picks its own direction
    /// from the window's frame, so a press on a window already at the zoom target sends it back to
    /// the user frame however the caller asked — and reports `.success` for it.
    func setZoomed(_ zoomed: Bool) -> AXError {
        let refusal = zoomed ? zoomResult : unzoomResult
        guard refusal == .success else { return refusal }
        zoomPresses += 1
        let standard = standardFrame ?? zoomTarget
        frame = frame == standard ? userFrame : standard
        return .success
    }

    /// A real attribute, unlike zoom, so the fake stores it rather than deriving it from the
    /// frame. Nil is the read that failed.
    var fullscreenState: Bool?
    /// What the fullscreen write answers, and separately, whether it ever takes: Activity Monitor
    /// and System Settings accept the write and stay where they are.
    var fullscreenResult: AXError = .success
    private(set) var fullscreenWrites = 0
    /// Whether the window was fullscreen as each frame write landed. It matters in both
    /// directions: a fullscreen window swallows the write, and entering fullscreen afterwards
    /// throws the frame away.
    private(set) var fullscreenAtFrameWrite: [Bool] = []

    /// Accepts the write without flipping the state, for the same reason `setMinimized` does —
    /// and measured on a real window, which is stronger than the analogy: the attribute flips when
    /// the transition starts, and a write that lands before it finishes is accepted and then does
    /// nothing at all.
    func setFullScreen(_ fullscreen: Bool) -> AXError {
        fullscreenWrites += 1
        return fullscreenResult
    }

    /// What the frame write answers. The whole `stateUnknown` design rests on the frame write
    /// being the one step that can still report on a window nothing else could read, so a refusal
    /// there has to be exercised.
    var frameResult: AXError = .success

    func setCocoaFrame(_ frame: CGRect) -> AXError {
        frameWrites.append(frame)
        minimizedAtFrameWrite.append(isMinimized)
        fullscreenAtFrameWrite.append(fullscreenState ?? false)
        guard frameResult == .success else { return frameResult }
        self.frame = frame
        return .success
    }
}

/// Stands in for the time a bounded wait spends polling: `onSleep` is where the test moves the
/// world on, so a wait that never re-reads its state can be told apart from one that does. Time
/// is virtual: each sleep advances `now` by what was asked for, and `advance(by:)` stands in for
/// time that passes *between* sleeps — a slow Accessibility read, above all.
/// Counts sleeps against a clock that never moves, so a poll-count bound can be tested without a
/// wall-clock deadline expiring underneath it.
@MainActor
private final class CountingClock: RestoreClock {
    private(set) var sleeps = 0
    let now = ContinuousClock.now

    func sleep(_ duration: Duration) async {
        _ = duration
        sleeps += 1
    }
}

@MainActor
private final class ScriptedClock: RestoreClock {
    private(set) var sleeps = 0
    private(set) var now: ContinuousClock.Instant = .now
    private let start: ContinuousClock.Instant
    var onSleep: @MainActor (Int) -> Void = { _ in }

    init() {
        start = now
    }

    var elapsed: Duration { now - start }

    func advance(by duration: Duration) {
        now += duration
    }

    func sleep(_ duration: Duration) async {
        now += duration
        sleeps += 1
        onSleep(sleeps)
    }
}

/// Parks a launch inside `openApplication` so a test can hold one restore in flight while a second
/// queues behind it.
@MainActor
private final class OpenGate {
    private(set) var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func park() async {
        arrivals += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseAll() {
        let parked = waiters
        waiters = []
        for waiter in parked {
            waiter.resume()
        }
    }
}

@MainActor
private struct FakeLaunchDisplays: DisplayCatalog {
    var live: [LiveDisplay]
    func displays() -> [LiveDisplay] { live }
}

/// Sleeps instantly and never advances — `now` is frozen at construction — so a wait driven by
/// this clock is bounded by its poll *count* alone. That is what lets a test tell the two bounds
/// apart: under `ScriptedClock` both expire together and either one passing looks the same.
@MainActor
private struct FakeClock: RestoreClock {
    let now = ContinuousClock.now

    func sleep(_ duration: Duration) async {
        _ = duration
    }
}
