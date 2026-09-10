import XCTest
@testable import SnapDesk

final class WindowMatcherTests: XCTestCase {
    private let safari = "com.apple.Safari"
    private let chrome = "com.google.Chrome"

    private var github: MatchableWindow {
        MatchableWindow(id: "w1", bundleIdentifier: safari, title: "GitHub")
    }

    private var docs: MatchableWindow {
        MatchableWindow(id: "w2", bundleIdentifier: safari, title: "Docs")
    }

    private var among: [MatchableWindow] { [github, docs] }

    func testExactTitleClaimsDocsNotGitHub() {
        let slot = savedWindow(bundleIdentifier: safari, title: "Docs")
        XCTAssertEqual(WindowMatcher.assign(slots: [slot], among: among), [0: docs])
    }

    func testEmptyTitleGetsLeftoverAfterDocsClaimed() {
        let slot = savedWindow(bundleIdentifier: safari, title: "")
        XCTAssertEqual(WindowMatcher.assign(slots: [slot], among: among, claimed: ["w2"]), [0: github])
    }

    func testClaimedIdNeverReturned() {
        let slot = savedWindow(bundleIdentifier: safari, title: "Docs")
        XCTAssertEqual(WindowMatcher.assign(slots: [slot], among: among, claimed: ["w1", "w2"]), [:])
    }

    func testDifferentBundleIDNeverMatches() {
        let slot = savedWindow(bundleIdentifier: chrome, title: "Docs")
        XCTAssertEqual(WindowMatcher.assign(slots: [slot], among: among), [:])
    }

    /// The steal this whole two-pass shape exists to stop: slot 0's window is gone, and taking the
    /// only live window as a leftover would leave the slot actually named "GitHub" empty and land
    /// the GitHub window on slot 0's saved frame. Slot 0 gets nothing instead — it has lost nothing
    /// it could have used, and the survivor goes back where it was.
    func testALeftoverIsNeverTakenFromTheSlotItExactlyMatches() {
        let gone = savedWindow(bundleIdentifier: safari, title: "Docs")
        let owner = savedWindow(bundleIdentifier: safari, title: "GitHub")

        let assignment = WindowMatcher.assign(slots: [gone, owner], among: [github])

        XCTAssertEqual(assignment, [1: github])
    }

    /// Scarce windows go to the slots the user listed first, but only after every exact title has
    /// had its turn: here slot 1 is the one named after the surviving window, so slot 0 takes the
    /// untitled leftover rather than the window slot 1 owns.
    func testLeftoversGoInSlotOrderOnceExactTitlesAreSettled() {
        let stranger = MatchableWindow(id: "w3", bundleIdentifier: safari, title: "Stranger")
        let gone = savedWindow(bundleIdentifier: safari, title: "Gone")
        let owner = savedWindow(bundleIdentifier: safari, title: "GitHub")

        let assignment = WindowMatcher.assign(slots: [gone, owner], among: [github, stranger])

        XCTAssertEqual(assignment, [0: stranger, 1: github])
    }

    /// `exactTitles` is what the launch polls with while it is still waiting for an app's remaining
    /// windows, so it must hand out nothing a title does not name.
    func testExactTitlesHandsOutNoLeftovers() {
        let gone = savedWindow(bundleIdentifier: safari, title: "Gone")
        let owner = savedWindow(bundleIdentifier: safari, title: "GitHub")

        let assignment = WindowMatcher.exactTitles(slots: [gone, owner], among: [github, docs])

        XCTAssertEqual(assignment, [1: github])
    }

    private func savedWindow(bundleIdentifier: String, title: String) -> SavedWindow {
        SavedWindow(
            bundleIdentifier: bundleIdentifier,
            bundlePath: "/Applications/Dummy.app",
            name: "Dummy",
            title: title,
            displayId: "display",
            x: 0,
            y: 0,
            width: 100,
            height: 100,
            minimized: false,
            zoomed: false,
            arguments: ""
        )
    }
}
