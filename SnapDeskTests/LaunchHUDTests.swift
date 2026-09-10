import AppKit
import XCTest
@testable import SnapDesk

@MainActor
final class LaunchHUDTests: XCTestCase {
    @MainActor
    private final class FakeDelay: DelayRunning {
        var duration: Duration?
        var pending: (@MainActor () -> Void)?

        func run(after duration: Duration, _ work: @escaping @MainActor () -> Void) {
            self.duration = duration
            pending = work
        }

        func fire() {
            let work = pending
            pending = nil
            work?()
        }
    }

    @MainActor
    private final class BeepCounter {
        var count = 0
    }

    /// The HUD is a floating panel that joins every Space, so one left visible sits over whatever
    /// the developer is doing for the rest of the run.
    private func makeHUD(delay: FakeDelay = FakeDelay()) -> (LaunchHUDController, FakeDelay, BeepCounter) {
        let beeps = BeepCounter()
        let hud = LaunchHUDController(delay: delay, beep: { beeps.count += 1 })
        addTeardownBlock { @MainActor in hud.panel.orderOut(nil) }
        return (hud, delay, beeps)
    }

    private func launchingSlots() -> [SlotProgress] {
        [
            SlotProgress(index: 0, name: "Safari", status: .launching),
            SlotProgress(index: 1, name: "Preview", status: .launching),
        ]
    }

    private func placedSlots() -> [SlotProgress] {
        [
            SlotProgress(index: 0, name: "Safari", status: .placed(.clean)),
            SlotProgress(index: 1, name: "Preview", status: .placed(.clean)),
        ]
    }

    func testUpdateTwoLaunchingSlotsShowsRows() {
        let (hud, delay, _) = makeHUD()

        hud.update(launchingSlots())

        XCTAssertTrue(hud.isVisible)
        XCTAssertEqual(hud.rows.map(\.name), ["Safari", "Preview"])
        XCTAssertEqual(hud.rows.map(\.text), ["Launching", "Launching"])
        XCTAssertNil(delay.pending)
    }

    func testAllPlacedSchedulesDelayThenHides() {
        let (hud, delay, _) = makeHUD()
        hud.update(launchingSlots())

        hud.update(placedSlots())

        XCTAssertTrue(hud.isVisible)
        XCTAssertEqual(delay.duration, .milliseconds(600))
        XCTAssertNotNil(delay.pending)

        delay.fire()

        XCTAssertFalse(hud.isVisible)
        XCTAssertNil(delay.pending)
    }

    func testCancelButtonInvokesOnCancel() {
        let (hud, _, _) = makeHUD()
        var cancelled = false
        hud.onCancel = { cancelled = true }
        hud.update(launchingSlots())

        XCTAssertTrue(hud.cancelButton.isEnabled)
        hud.cancelButton.performClick(nil)

        XCTAssertTrue(cancelled)
    }

    /// The HUD outlives the restore by the length of its auto-dismiss. A Cancel click landing in
    /// that window has nothing left to cancel, so the button must not still be offering it.
    func testCancelIsRefusedOnceEverySlotIsTerminal() {
        let (hud, _, _) = makeHUD()
        var cancelled = false
        hud.onCancel = { cancelled = true }
        hud.update(launchingSlots())

        hud.update(placedSlots())

        XCTAssertFalse(hud.cancelButton.isEnabled)
        hud.cancelButton.performClick(nil)
        XCTAssertFalse(cancelled)
    }

    func testPresentReArmsCancelAfterAFinishedRestore() {
        let (hud, _, _) = makeHUD()
        hud.update(placedSlots())
        XCTAssertFalse(hud.cancelButton.isEnabled)

        hud.present(title: "Writing")

        XCTAssertTrue(hud.cancelButton.isEnabled)
    }

    func testStatusTextForEachSlotStatus() {
        let (hud, _, _) = makeHUD()

        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .pending),
            SlotProgress(index: 1, name: "Preview", status: .launching),
            SlotProgress(index: 2, name: "Notes", status: .matched),
            SlotProgress(index: 3, name: "Music", status: .placed(.clean)),
            SlotProgress(index: 4, name: "Terminal", status: .cancelled),
            SlotProgress(index: 5, name: "Mail", status: .failed(.appNotFound)),
            SlotProgress(index: 6, name: "Xcode", status: .placed(PlacementNote(isGuess: true, substituteDisplay: nil))),
            SlotProgress(index: 7, name: "Slack", status: .placed(PlacementNote(isGuess: false, substituteDisplay: "LG UltraFine"))),
            SlotProgress(index: 8, name: "Finder", status: .placed(PlacementNote(isGuess: true, substituteDisplay: "LG UltraFine"))),
            SlotProgress(index: 9, name: "Pages", status: .failed(.stateNotRestored)),
            SlotProgress(index: 10, name: "Numbers", status: .failed(.windowGone)),
            SlotProgress(index: 11, name: "Keynote", status: .failed(.windowsUnreadable)),
        ])

        XCTAssertEqual(
            hud.rows.map(\.text),
            [
                "Pending", "Launching", "Ready", "Placed", "Cancelled", "Failed: App not found",
                "Placed (other window)", "Placed on LG UltraFine", "Placed on LG UltraFine (other window)",
                "Failed: Zoom or minimize failed", "Failed: Window disappeared", "Failed: Could not read windows",
            ]
        )
    }

    /// Whether a row is a failure is a fact about the slot's status, and the row carries it as one.
    /// Recovering it from the rendered wording — `status.hasPrefix("Failed")` — makes the colour
    /// hostage to a string that exists to be reworded, which is exactly how the beep came to miss
    /// four of the five failures.
    func testRowsCarryFailureAsAStatusFactNotAsAPrefixOfTheirText() {
        let (hud, _, _) = makeHUD()

        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .placed(.clean)),
            SlotProgress(index: 1, name: "Preview", status: .cancelled),
            SlotProgress(index: 2, name: "Notes", status: .failed(.noWindow)),
        ])

        XCTAssertEqual(hud.rows.map(\.isFailure), [false, false, true])
        // And the flag is what the panel actually paints: only the failed row is red.
        let red = statusLabels(in: hud.panel).filter { $0.textColor == .systemRed }
        XCTAssertEqual(red.map(\.stringValue), ["Failed: No window"])
    }

    /// Every label the panel is currently showing, in the order it stacked them.
    private func statusLabels(in panel: NSPanel) -> [NSTextField] {
        func collect(_ view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField { return [field] }
            return view.subviews.flatMap(collect)
        }
        guard let contentView = panel.contentView else { return [] }
        return collect(contentView)
    }

    func testDismissHidesAndFurtherUpdatesDoNotReshow() {
        let (hud, delay, _) = makeHUD()
        var dismissed = false
        var cancelled = false
        hud.onDismiss = { dismissed = true }
        hud.onCancel = { cancelled = true }
        hud.update(launchingSlots())

        hud.dismissButton.performClick(nil)

        XCTAssertFalse(hud.isVisible)
        XCTAssertTrue(dismissed)
        XCTAssertFalse(cancelled)

        hud.update(placedSlots())

        XCTAssertFalse(hud.isVisible)
        XCTAssertNil(delay.pending)
    }

    func testPresentSetsPanelTitle() {
        let (hud, _, _) = makeHUD()

        hud.present(title: "Coding")

        XCTAssertEqual(hud.panel.title, "Coding")
        XCTAssertTrue(hud.isVisible)
    }

    /// A restore that lost a slot must not vanish after 600ms looking exactly like a clean one.
    func testMixedPlacedAndFailedStaysOnScreen() {
        let (hud, delay, _) = makeHUD()
        hud.update(launchingSlots())

        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .failed(.couldNotPosition)),
            SlotProgress(index: 1, name: "Preview", status: .placed(.clean)),
        ])

        XCTAssertNil(delay.pending)
        XCTAssertTrue(hud.isVisible)
    }

    /// A slot that settled for a window it is not named after, or landed on a substitute screen,
    /// is not a *failure* — so the HUD counted it as a clean run and dismissed itself after 600ms,
    /// which is the one thing that makes the note worth carrying pointless. Worse, the correction
    /// pass runs for four seconds after that and would update a HUD the user can no longer see.
    func testAPlacementThatGuessedOrSubstitutedStaysOnScreen() {
        for note in [
            PlacementNote(isGuess: true, substituteDisplay: nil),
            PlacementNote(isGuess: false, substituteDisplay: "LG UltraFine"),
        ] {
            let (hud, delay, beeps) = makeHUD()
            hud.update(launchingSlots())

            hud.update([
                SlotProgress(index: 0, name: "Safari", status: .placed(note)),
                SlotProgress(index: 1, name: "Preview", status: .placed(.clean)),
            ])

            XCTAssertNil(delay.pending, "\(note) must not auto-dismiss")
            XCTAssertTrue(hud.isVisible)
            XCTAssertEqual(beeps.count, 0, "a guess is not a failure: it must not beep")
        }
    }

    /// And a correction that clears the note lets the HUD go: there is nothing left to explain.
    func testAHUDDismissesOnceACorrectionClearsTheGuess() {
        let (hud, delay, _) = makeHUD()
        hud.update(launchingSlots())
        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .placed(PlacementNote(isGuess: true, substituteDisplay: nil))),
            SlotProgress(index: 1, name: "Preview", status: .placed(.clean)),
        ])
        XCTAssertNil(delay.pending)

        hud.update(placedSlots())

        XCTAssertEqual(delay.duration, .milliseconds(600))
        delay.fire()
        XCTAssertFalse(hud.isVisible)
    }

    func testEverySlotFailedStaysOnScreen() {
        let (hud, delay, _) = makeHUD()
        hud.update(launchingSlots())

        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .failed(.appNotFound)),
            SlotProgress(index: 1, name: "Preview", status: .failed(.launchFailed)),
        ])

        XCTAssertNil(delay.pending)
        XCTAssertTrue(hud.isVisible)
    }

    /// "App not found" and "Launch failed" are the two failures a restore hits most often; both
    /// were silent while the beep was matched against one specific message.
    func testEveryKindOfFailureBeepsOnceWhenItFirstAppears() {
        let (hud, _, beeps) = makeHUD()
        hud.update(launchingSlots())

        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .failed(.appNotFound)),
            SlotProgress(index: 1, name: "Preview", status: .launching),
        ])
        XCTAssertEqual(beeps.count, 1)

        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .failed(.appNotFound)),
            SlotProgress(index: 1, name: "Preview", status: .failed(.noWindow)),
        ])
        XCTAssertEqual(beeps.count, 2)

        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .failed(.appNotFound)),
            SlotProgress(index: 1, name: "Preview", status: .failed(.noWindow)),
        ])
        XCTAssertEqual(beeps.count, 2)
    }

    /// The whole point of Cancel is to make the restore go away. Treating the slots it stopped as
    /// failures beeps at the user for doing what they asked for and then makes them dismiss the
    /// HUD a second time.
    func testCancellingThroughTheHUDIsSilentAndDismissesItself() {
        let (hud, delay, beeps) = makeHUD()
        var cancelled = false
        hud.onCancel = { cancelled = true }
        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .launching),
            SlotProgress(index: 1, name: "Preview", status: .pending),
            SlotProgress(index: 2, name: "Notes", status: .pending),
        ])

        hud.cancelButton.performClick(nil)
        XCTAssertTrue(cancelled)

        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .cancelled),
            SlotProgress(index: 1, name: "Preview", status: .cancelled),
            SlotProgress(index: 2, name: "Notes", status: .cancelled),
        ])

        XCTAssertEqual(beeps.count, 0)
        XCTAssertEqual(delay.duration, .milliseconds(600))

        delay.fire()

        XCTAssertFalse(hud.isVisible)
    }

    /// A single snapshot can turn several slots terminal at once — every slot of an app whose
    /// bundle is missing. One beep per slot stacks into a noise that reads as a crash.
    func testASnapshotThatFailsSeveralSlotsBeepsOnce() {
        let (hud, _, beeps) = makeHUD()
        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .launching),
            SlotProgress(index: 1, name: "Preview", status: .launching),
            SlotProgress(index: 2, name: "Notes", status: .launching),
        ])

        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .failed(.appNotFound)),
            SlotProgress(index: 1, name: "Preview", status: .failed(.appNotFound)),
            SlotProgress(index: 2, name: "Notes", status: .failed(.appNotFound)),
        ])

        XCTAssertEqual(beeps.count, 1)
    }

    /// A HUD the user has already dismissed has nothing left to say about the restore.
    func testADismissedHUDStaysSilent() {
        let (hud, _, beeps) = makeHUD()
        hud.update(launchingSlots())
        hud.dismissButton.performClick(nil)

        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .failed(.appNotFound)),
            SlotProgress(index: 1, name: "Preview", status: .failed(.noWindow)),
        ])

        XCTAssertEqual(beeps.count, 0)
        XCTAssertFalse(hud.isVisible)
    }

    /// A restore can go terminal and then report more work — a queued slot, a retry. The dismiss
    /// scheduled by the earlier snapshot must not fire against the newer one.
    /// `try?` around the sleep swallowed the cancellation and ran the work anyway — instantly,
    /// since a cancelled sleep returns at once. The auto-dismiss would then hide a HUD that by
    /// then belongs to a different restore.
    func testACancelledDelayDoesNotRunItsWork() async {
        let delay = MainActorDelay()
        let ran = Flag()

        delay.run(after: .seconds(60)) { ran.value = true }
        let pending = try? XCTUnwrap(delay.pending)
        pending?.cancel()
        await pending?.value

        XCTAssertFalse(ran.value)
    }

    /// And an uncancelled one still runs, or the auto-dismiss would never fire at all.
    func testADelayThatIsNotCancelledRunsItsWork() async {
        let delay = MainActorDelay()
        let ran = Flag()

        delay.run(after: .milliseconds(1)) { ran.value = true }
        await delay.pending?.value

        XCTAssertTrue(ran.value)
    }

    @MainActor
    private final class Flag {
        var value = false
    }

    func testNewerProgressCancelsAScheduledAutoDismiss() {
        let (hud, delay, _) = makeHUD()
        hud.update(launchingSlots())
        hud.update(placedSlots())
        XCTAssertNotNil(delay.pending)

        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .placed(.clean)),
            SlotProgress(index: 1, name: "Preview", status: .launching),
        ])

        delay.fire()

        XCTAssertTrue(hud.isVisible)
    }
}
