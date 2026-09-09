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

    private func makeHUD(delay: FakeDelay = FakeDelay()) -> (LaunchHUDController, FakeDelay) {
        (LaunchHUDController(delay: delay), delay)
    }

    private func launchingSlots() -> [SlotProgress] {
        [
            SlotProgress(index: 0, name: "Safari", status: .launching),
            SlotProgress(index: 1, name: "Preview", status: .launching),
        ]
    }

    func testUpdateTwoLaunchingSlotsShowsRows() {
        let (hud, delay) = makeHUD()

        hud.update(launchingSlots())

        XCTAssertTrue(hud.isVisible)
        XCTAssertEqual(hud.rows.map(\.name), ["Safari", "Preview"])
        XCTAssertEqual(hud.rows.map(\.status), ["Launching", "Launching"])
        XCTAssertNil(delay.pending)
    }

    func testAllPlacedSchedulesDelayThenHides() {
        let (hud, delay) = makeHUD()
        hud.update(launchingSlots())

        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .placed),
            SlotProgress(index: 1, name: "Preview", status: .placed),
        ])

        XCTAssertTrue(hud.isVisible)
        XCTAssertEqual(delay.duration, .milliseconds(600))
        XCTAssertNotNil(delay.pending)

        delay.fire()

        XCTAssertFalse(hud.isVisible)
        XCTAssertNil(delay.pending)
    }

    func testCancelButtonInvokesOnCancel() {
        let (hud, _) = makeHUD()
        var cancelled = false
        hud.onCancel = { cancelled = true }
        hud.update(launchingSlots())

        hud.cancelButton.performClick(nil)

        XCTAssertTrue(cancelled)
    }

    func testStatusTextForEachSlotStatus() {
        let (hud, _) = makeHUD()

        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .pending),
            SlotProgress(index: 1, name: "Preview", status: .launching),
            SlotProgress(index: 2, name: "Notes", status: .placed),
            SlotProgress(index: 3, name: "Mail", status: .failed("App not found")),
        ])

        XCTAssertEqual(
            hud.rows.map(\.status),
            ["Pending", "Launching", "Placed", "Failed: App not found"]
        )
    }

    func testDismissHidesAndFurtherUpdatesDoNotReshow() {
        let (hud, delay) = makeHUD()
        var dismissed = false
        var cancelled = false
        hud.onDismiss = { dismissed = true }
        hud.onCancel = { cancelled = true }
        hud.update(launchingSlots())

        hud.dismissButton.performClick(nil)

        XCTAssertFalse(hud.isVisible)
        XCTAssertTrue(dismissed)
        XCTAssertFalse(cancelled)

        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .placed),
            SlotProgress(index: 1, name: "Preview", status: .placed),
        ])

        XCTAssertFalse(hud.isVisible)
        XCTAssertNil(delay.pending)
    }

    func testPresentSetsPanelTitle() {
        let (hud, _) = makeHUD()

        hud.present(title: "Coding")

        XCTAssertEqual(hud.panel.title, "Coding")
        XCTAssertTrue(hud.isVisible)
    }

    func testMixedPlacedAndFailedAutoDismisses() {
        let (hud, delay) = makeHUD()
        hud.update(launchingSlots())

        hud.update([
            SlotProgress(index: 0, name: "Safari", status: .failed("Could not position")),
            SlotProgress(index: 1, name: "Preview", status: .placed),
        ])

        XCTAssertEqual(delay.duration, .milliseconds(600))
        delay.fire()
        XCTAssertFalse(hud.isVisible)
    }
}
