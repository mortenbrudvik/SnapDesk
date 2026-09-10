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
                SlotProgress(index: 0, name: "Safari", status: .failed(.appNotFound)),
                SlotProgress(index: 1, name: "Preview", status: .placed),
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

        XCTAssertEqual(result, [SlotProgress(index: 0, name: "Safari", status: .placed)])
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
                SlotProgress(index: 1, name: "Preview", status: .placed),
            ]
        )
        XCTAssertEqual(placer.placements.map(\.window.id), [previewWindow.id, safariWindow.id])
        XCTAssertEqual(apps.activated, [previewID])
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
        XCTAssertTrue(first.allSatisfy { $0.status == .placed })

        service.cancel()

        let second = await service.launch(makeDocument(moveExistingWindows: false)) { _ in }

        XCTAssertEqual(
            second,
            [
                SlotProgress(index: 0, name: "Safari", status: .placed),
                SlotProgress(index: 1, name: "Preview", status: .placed),
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
        while openGate.arrivals == 0 {
            await Task.yield()
        }
        let queued = Task { @MainActor in await service.launch(document) { _ in } }
        // Lets the queued restore reach the gate, which is what makes it something a cancel can
        // still be aimed at.
        await Task.yield()

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
                SlotProgress(index: 0, name: "Safari", status: .placed),
                SlotProgress(index: 1, name: "Preview", status: .failed(.launchTimedOut)),
            ]
        )
        XCTAssertEqual(launcher.opens.map(\.url), [URL(fileURLWithPath: safariPath)])
        XCTAssertEqual(placer.placements.map(\.window.id), [safariWindow.id])
        XCTAssertEqual(apps.activated, [safariID])
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
                SlotProgress(index: 0, name: "Safari", status: .placed),
                SlotProgress(index: 1, name: "Safari", status: .placed),
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

        XCTAssertEqual(
            result.map(\.status),
            [.placed, .failed(.noWindow), .failed(.noWindow)]
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

        XCTAssertEqual(result.map(\.status), [.failed(.noWindow), .placed, .placed])
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
            snapshot.contains { $0.status == .placed }
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

        XCTAssertEqual(result.map(\.status), [.placed])
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

        XCTAssertEqual(result.map(\.status), [.placed])
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

        XCTAssertEqual(
            result.map(\.status),
            [.failed(.couldNotPosition), .failed(.couldNotPosition)]
        )
        XCTAssertTrue(placer.placements.isEmpty)
    }

    /// A slot whose app never vends anything must not wait forever, and must not wait longer than
    /// the configured timeout says.
    func testTheWaitForAWindowIsBoundedByTheWindowTimeout() async {
        let launcher = FakeLauncher()
        launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
        let windows = FakeWindows(windowsByBundle: [:])
        let clock = ScriptedClock()
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
        // 250ms of 100ms polls. The wait is counted in polls rather than measured against a wall
        // clock so that it is the same length whichever `Clock` is driving it.
        XCTAssertEqual(clock.sleeps, 3)
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

        XCTAssertEqual(result.map(\.status), [.placed, .placed])
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

        XCTAssertEqual(result.map(\.status), [.placed, .placed, .placed])
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
            if sleepsWhenPlaced == nil, progress.allSatisfy({ $0.status == .placed }) {
                sleepsWhenPlaced = clock.sleeps
            }
        }

        XCTAssertEqual(result.map(\.status), [.placed, .placed])
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

        XCTAssertEqual(result.map(\.status), [.placed, .placed])
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

        XCTAssertEqual(result.map(\.status), [.placed, .placed, .failed(.noWindow)])
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

        await gate.acquire()
        XCTAssertTrue(gate.isHeld)

        let waiter = Task { @MainActor in
            await gate.acquire()
            waiterRan.value = true
        }
        await Task.yield()
        XCTAssertFalse(waiterRan.value)

        gate.release()

        XCTAssertFalse(waiterRan.value)
        XCTAssertTrue(gate.isHeld)

        await waiter.value
        XCTAssertTrue(waiterRan.value)
        gate.release()
        XCTAssertFalse(gate.isHeld)
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

        let placed = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: false,
            zoomed: false,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertTrue(placed)
        XCTAssertEqual(window.frameWrites, [frame])
        XCTAssertEqual(window.minimizedAtFrameWrite, [false])
        XCTAssertEqual(clock.sleeps, 3)
    }

    func testAWindowThatNeverLeavesTheDockIsReportedRatherThanWrittenTo() async {
        let window = FakeAXWindow(isMinimized: true)
        let clock = ScriptedClock()

        let placed = await WindowPlacement.apply(
            to: window,
            cocoaFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            minimized: false,
            zoomed: false,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertFalse(placed)
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

        let placed = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: false,
            zoomed: false,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(window.unminimizeWrites, 1, "an unreadable state must be written to, not assumed")
        XCTAssertTrue(placed)
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

        let placed = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: false,
            zoomed: false,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(window.unminimizeWrites, 1, "an unreadable state must still be written to")
        XCTAssertTrue(placed)
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

        let placed = await WindowPlacement.apply(
            to: window,
            cocoaFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            minimized: false,
            zoomed: false,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertEqual(window.unminimizeWrites, 1, "the blind write must still be sent")
        XCTAssertFalse(placed, "a window that says it is still minimized must not be reported placed")
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

        let placed = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: false,
            zoomed: false,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertTrue(placed)
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

        let placed = await WindowPlacement.apply(
            to: window,
            cocoaFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            minimized: false,
            zoomed: false,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertFalse(placed)
        XCTAssertTrue(window.frameWrites.isEmpty)
        XCTAssertEqual(clock.sleeps, 0, "a refused write left nothing in flight to wait for")
    }

    /// A slot saved minimized on a window that is *already* minimized is already restored. Forcing
    /// it out of the Dock only to put it back is a visible flash, costs the deminiaturize wait, and
    /// the frame write in between would be swallowed by the Dock regardless.
    func testASlotSavedMinimizedLeavesAnAlreadyMinimizedWindowAlone() async {
        let window = FakeAXWindow(isMinimized: true)
        let clock = ScriptedClock()

        let placed = await WindowPlacement.apply(
            to: window,
            cocoaFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            minimized: true,
            zoomed: false,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertTrue(placed)
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
            if poll == 2 { window.minimizedState = false }
        }
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        let placed = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: true,
            zoomed: false,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertTrue(placed)
        XCTAssertEqual(window.frameWrites, [frame])
        XCTAssertEqual(window.minimizedState, true, "the saved minimize is re-applied after the frame")
    }

    /// The skip is still a skip where it is safe to be one: a window confirmed to be up takes no
    /// un-minimize write and no wait, so the common case pays nothing for the honesty above.
    func testAWindowConfirmedToBeUpIsNotWrittenToOrWaitedFor() async {
        let window = FakeAXWindow(isMinimized: false)
        let clock = ScriptedClock()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        let placed = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: false,
            zoomed: false,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertTrue(placed)
        XCTAssertEqual(window.unminimizeWrites, 0)
        XCTAssertEqual(clock.sleeps, 0)
        XCTAssertEqual(window.frameWrites, [frame])
    }

    /// `isZoomed` is inferred from the frame, so a non-resizable window parked at the visible frame
    /// reads as zoomed and has no zoom button to press. Aborting there loses a move that the frame
    /// write alone would have made.
    func testARefusedUnZoomStillLetsTheWindowBeMoved() async {
        let window = FakeAXWindow(isZoomed: true)
        window.unzoomResult = .attributeUnsupported
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        let placed = await WindowPlacement.apply(
            to: window,
            cocoaFrame: frame,
            minimized: false,
            zoomed: false,
            bundleIdentifier: safariID,
            clock: ScriptedClock()
        )

        XCTAssertTrue(placed)
        XCTAssertEqual(window.frameWrites, [frame])
    }

    /// The saved state is what the user asked for, so a refusal there is still a failed placement.
    func testARefusedSavedZoomStillFailsThePlacement() async {
        let window = FakeAXWindow()
        window.zoomResult = .attributeUnsupported

        let placed = await WindowPlacement.apply(
            to: window,
            cocoaFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            minimized: false,
            zoomed: true,
            bundleIdentifier: safariID,
            clock: ScriptedClock()
        )

        XCTAssertFalse(placed)
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

        let placed = await WindowPlacement.apply(
            to: window,
            cocoaFrame: window.zoomTarget,
            minimized: false,
            zoomed: true,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertTrue(placed)
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

        let placed = await WindowPlacement.apply(
            to: window,
            cocoaFrame: saved,
            minimized: false,
            zoomed: true,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertTrue(placed)
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

        let placed = await WindowPlacement.apply(
            to: window,
            cocoaFrame: standard,
            minimized: false,
            zoomed: true,
            bundleIdentifier: safariID,
            clock: clock
        )

        XCTAssertFalse(placed, "an unverifiable zoom is reported, not assumed")
        XCTAssertEqual(window.frame, standard, "the correcting press put it back on its saved frame")
        XCTAssertEqual(window.zoomPresses, 2, "bounded: it does not press forever")
        // 2 attempts x 500ms of 50ms polls. Deliberately far short of the deminiaturize bound: a
        // zoom animates in a quarter second and is not a precondition for anything after it.
        XCTAssertEqual(clock.sleeps, 20)
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
                displays: [savedDisplay(display)],
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

    private var notesWindow: MatchableWindow {
        MatchableWindow(id: "notes-1", bundleIdentifier: notesID, title: "Inbox")
    }

    private func makeService(
        launcher: FakeLauncher,
        apps: FakeApps = FakeApps(),
        windows: FakeWindows,
        placer: FakePlacer = FakePlacer(),
        displays: [LiveDisplay]? = nil,
        clock: any Clock = FakeClock(),
        launchTimeout: Duration = .seconds(10),
        windowTimeout: Duration = .seconds(8),
        prohibitsMultipleInstances: @escaping (String, String) -> Bool = { _, _ in false }
    ) -> LaunchService {
        LaunchService(
            launcher: launcher,
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

    private func makeDocument(
        moveExistingWindows: Bool,
        displays: [SavedDisplay]? = nil,
        windows: [SavedWindow]? = nil
    ) -> WorkspaceDocument {
        WorkspaceDocument(
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
        height: Double = 900
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
            height: height
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
        zoomed: Bool = false
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
    var hangURLs: Set<URL> = []
    var opens: [(url: URL, configuration: LaunchConfiguration)] = []
    var openError: (any Error)?
    var openGate: OpenGate?
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
        if let openGate {
            await openGate.park()
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

    func standardWindows(bundleIdentifier: String) -> [MatchableWindow] {
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
    }

    var placements: [Placement] = []
    var refuseIDs: Set<String>

    init(refuseIDs: Set<String> = []) {
        self.refuseIDs = refuseIDs
    }

    func place(_ window: MatchableWindow, cocoaFrame: CGRect, minimized: Bool, zoomed: Bool) async -> Bool {
        placements.append(
            Placement(window: window, cocoaFrame: cocoaFrame, minimized: minimized, zoomed: zoomed)
        )
        return !refuseIDs.contains(window.id)
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

    init(isMinimized: Bool = false, isZoomed: Bool = false) {
        self.minimizedState = isMinimized
        self.frame = isZoomed ? zoomTarget : userFrame
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

    func setMinimized(_ minimized: Bool) -> AXError {
        guard minimized else {
            unminimizeWrites += 1
            return unminimizeResult
        }
        minimizedState = true
        return .success
    }

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

    func setCocoaFrame(_ frame: CGRect) -> AXError {
        frameWrites.append(frame)
        minimizedAtFrameWrite.append(isMinimized)
        self.frame = frame
        return .success
    }
}

/// Stands in for the time a bounded wait spends polling: `onSleep` is where the test moves the
/// world on, so a wait that never re-reads its state can be told apart from one that does.
@MainActor
private final class ScriptedClock: Clock {
    private(set) var sleeps = 0
    var onSleep: @MainActor (Int) -> Void = { _ in }

    func sleep(_ duration: Duration) async {
        _ = duration
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

@MainActor
private struct FakeClock: Clock {
    func sleep(_ duration: Duration) async {
        _ = duration
    }
}
