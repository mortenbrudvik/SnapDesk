import XCTest
@testable import SnapDesk

/// The permission policy behind the status-item row and the command path: which of the two
/// mutually exclusive scripts — grant it, or relaunch to apply a grant — a given trust state
/// calls for. As much of `AccessibilityAuth` as can be checked without a modal on screen.
@MainActor
final class AccessibilityAuthTests: XCTestCase {
    func testAWorkingCallNeedsNothingWhateverTCCSays() {
        XCTAssertEqual(AccessibilityAuth.remedy(isTrusted: true, isEffectivelyTrusted: true), AccessibilityAuth.Remedy.none)
        XCTAssertEqual(AccessibilityAuth.remedy(isTrusted: false, isEffectivelyTrusted: true), AccessibilityAuth.Remedy.none)
    }

    func testNeverGrantedAsksForTheGrantAndNotForARelaunch() {
        XCTAssertEqual(AccessibilityAuth.remedy(isTrusted: false, isEffectivelyTrusted: false), AccessibilityAuth.Remedy.grant)
    }

    func testGrantedButStillFailingAsksForARelaunch() {
        XCTAssertEqual(AccessibilityAuth.remedy(isTrusted: true, isEffectivelyTrusted: false), AccessibilityAuth.Remedy.relaunch)
    }

    // MARK: The relaunch helper

    /// The seams are `@Sendable`, so what they record cannot be the test case itself.
    @MainActor
    private final class Recorder {
        var alerts: [String] = []
        var spawns: [(path: String, pid: pid_t)] = []
    }

    private var savedPresenter: ((String, String, [String]) -> NSApplication.ModalResponse)?
    private var savedLauncher: (@MainActor (String, pid_t) throws -> Void)?
    private let recorder = Recorder()
    private var alerts: [String] { recorder.alerts }
    private var spawns: [(path: String, pid: pid_t)] { recorder.spawns }

    /// Both seams are swapped for every test in this file, and put back afterwards — including
    /// `relaunchPending`, which is static and would otherwise leak into the next test.
    override func setUp() async throws {
        try await super.setUp()
        savedPresenter = AccessibilityAuth.alertPresenter
        savedLauncher = AccessibilityAuth.helperLauncher
        recorder.alerts = []
        recorder.spawns = []
        let recorder = recorder
        AccessibilityAuth.alertPresenter = { message, _, _ in
            recorder.alerts.append(message)
            return .cancel
        }
        AccessibilityAuth.helperLauncher = { path, pid in
            recorder.spawns.append((path, pid))
        }
    }

    override func tearDown() async throws {
        if let savedPresenter { AccessibilityAuth.alertPresenter = savedPresenter }
        if let savedLauncher { AccessibilityAuth.helperLauncher = savedLauncher }
        _ = AccessibilityAuth.armRelaunchHelperIfPending()
        try await super.tearDown()
    }

    /// The helper polls for this pid to exit and then reopens the bundle. Spawned *before* the quit
    /// was asked for, it stayed armed for ten seconds after a vetoed quit — an unsaved editor, Cancel
    /// — so a real ⌘Q inside that window brought SnapDesk straight back.
    func testAVetoedQuitLeavesNoRelaunchHelperArmed() {
        AccessibilityAuth.relaunch(terminate: { /* vetoed: AppKit returns without quitting */ })

        XCTAssertTrue(spawns.isEmpty, "nothing may be armed while the app is still running")
        XCTAssertFalse(AccessibilityAuth.relaunchPending)
        XCTAssertEqual(alerts, ["SnapDesk did not relaunch"], "and the user is told it did not happen")

        XCTAssertTrue(AccessibilityAuth.armRelaunchHelperIfPending(), "a later, unrelated quit proceeds")
        XCTAssertTrue(spawns.isEmpty, "and arms nothing")
    }

    /// When the quit goes ahead, AppKit asks the delegate first — and that is where the helper is
    /// started, once, with the bundle path and this pid.
    func testAQuitThatProceedsArmsTheHelperExactlyOnce() {
        AccessibilityAuth.relaunch(terminate: {
            XCTAssertTrue(AccessibilityAuth.armRelaunchHelperIfPending())
            // A second veto pass — AppKit can ask more than once — must not arm a second helper.
            XCTAssertTrue(AccessibilityAuth.armRelaunchHelperIfPending())
        })

        XCTAssertEqual(spawns.count, 1)
        XCTAssertEqual(spawns.first?.path, Bundle.main.bundlePath)
        XCTAssertEqual(spawns.first?.pid, getpid())
        XCTAssertFalse(AccessibilityAuth.relaunchPending)
        XCTAssertEqual(alerts, [], "the quit went ahead: there is nothing to explain")
    }

    /// A helper that cannot be started is the one failure that has to stop the quit: the app would
    /// otherwise vanish and not come back, which reads as a crash.
    func testAHelperThatFailsToStartVetoesTheQuitAndExplains() {
        struct Refused: Error {}
        AccessibilityAuth.helperLauncher = { _, _ in throw Refused() }
        defer { AccessibilityAuth.helperLauncher = { _, _ in } }
        var quitProceeded: Bool?

        AccessibilityAuth.relaunch(terminate: {
            quitProceeded = AccessibilityAuth.armRelaunchHelperIfPending()
        })

        XCTAssertEqual(quitProceeded, false, "the app must not vanish without coming back")
        XCTAssertEqual(alerts, ["SnapDesk could not relaunch itself"])
        XCTAssertFalse(AccessibilityAuth.relaunchPending)
    }
}
