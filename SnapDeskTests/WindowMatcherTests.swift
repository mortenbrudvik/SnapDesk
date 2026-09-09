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
        let match = WindowMatcher.match(slot: slot, among: among, claimed: [])
        XCTAssertEqual(match, docs)
    }

    func testEmptyTitleGetsLeftoverAfterDocsClaimed() {
        let slot = savedWindow(bundleIdentifier: safari, title: "")
        let match = WindowMatcher.match(slot: slot, among: among, claimed: ["w2"])
        XCTAssertEqual(match, github)
    }

    func testClaimedIdNeverReturned() {
        let slot = savedWindow(bundleIdentifier: safari, title: "Docs")
        let match = WindowMatcher.match(slot: slot, among: among, claimed: ["w1", "w2"])
        XCTAssertNil(match)
    }

    func testDifferentBundleIDNeverMatches() {
        let slot = savedWindow(bundleIdentifier: chrome, title: "Docs")
        let match = WindowMatcher.match(slot: slot, among: among, claimed: [])
        XCTAssertNil(match)
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
