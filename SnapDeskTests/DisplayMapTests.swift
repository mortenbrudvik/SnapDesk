import CoreGraphics
import XCTest
@testable import SnapDesk

final class DisplayMapTests: XCTestCase {
    private let builtIn = LiveDisplay(
        id: "AAA",
        name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 38, width: 1512, height: 982),
        scale: 2
    )
    private let lg = LiveDisplay(
        id: "BBB",
        name: "LG UltraFine",
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        scale: 2
    )
    private let similarUnnamed = LiveDisplay(
        id: "CCC",
        name: "",
        frame: CGRect(x: -1512, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: -1512, y: 38, width: 1512, height: 982),
        scale: 2
    )

    private var live: [LiveDisplay] { [builtIn, lg, similarUnnamed] }

    func testUUIDMatchWinsEvenIfNamesDiffer() {
        let saved = SavedDisplay(
            id: "AAA",
            name: "Something Else",
            frame: CodableRect(x: 0, y: 0, width: 1, height: 1),
            visibleFrame: CodableRect(x: 0, y: 0, width: 1, height: 1),
            scale: 1
        )
        XCTAssertEqual(DisplayMap.match(saved: saved, among: live), builtIn)
    }

    func testNameMatchWhenUUIDMissingFromLive() {
        let saved = SavedDisplay(
            id: "MISSING",
            name: "LG UltraFine",
            frame: CodableRect(x: 0, y: 0, width: 1, height: 1),
            visibleFrame: CodableRect(x: 0, y: 0, width: 1, height: 1),
            scale: 1
        )
        XCTAssertEqual(DisplayMap.match(saved: saved, among: live), lg)
    }

    func testClosestSizeWhenUUIDAndNameMiss() {
        let saved = SavedDisplay(
            id: "MISSING",
            name: "No Such Display",
            frame: CodableRect(x: 0, y: 0, width: 1500, height: 900),
            visibleFrame: CodableRect(x: 0, y: 0, width: 1500, height: 900),
            scale: 1
        )
        XCTAssertEqual(DisplayMap.match(saved: saved, among: live), builtIn)
    }

    /// A display that could not be identified at capture must not match another unidentified one:
    /// an empty id or name is an absence, not a value two displays can share.
    func testEmptyIdAndNameDoNotMatchAnUnidentifiedDisplay() {
        let saved = SavedDisplay(
            id: "",
            name: "",
            frame: CodableRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CodableRect(x: 0, y: 0, width: 2560, height: 1440),
            scale: 1
        )
        XCTAssertEqual(DisplayMap.match(saved: saved, among: live), lg)
    }

    func testResolveSubstitutesTheClosestDisplayWhenTheSavedOneIsGone() {
        let saved = SavedDisplay(
            id: "GONE",
            name: "Unplugged",
            frame: CodableRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CodableRect(x: 0, y: 0, width: 2560, height: 1440),
            scale: 1
        )
        XCTAssertEqual(
            DisplayMap.resolve(displayId: "GONE", saved: [saved], live: live, main: builtIn),
            lg
        )
    }

    func testResolveUnknownIdEmptySavedReturnsMain() {
        XCTAssertEqual(
            DisplayMap.resolve(displayId: "unknown", saved: [], live: live, main: lg),
            lg
        )
    }

    func testResolveWithNoDisplayAttachedReturnsMain() {
        let saved = SavedDisplay(
            id: "AAA",
            name: "Built-in Retina Display",
            frame: CodableRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CodableRect(x: 0, y: 38, width: 1512, height: 982),
            scale: 2
        )
        XCTAssertEqual(
            DisplayMap.resolve(displayId: "AAA", saved: [saved], live: [], main: builtIn),
            builtIn
        )
    }

    // MARK: Identity of a display with no UUID

    /// The stand-in identity is what keeps two UUID-less displays apart, both when matching a
    /// saved workspace and as the `Identifiable` id of `SavedDisplay`.
    func testFallbackIdentitiesDifferPerDisplayAndAreNeverEmpty() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let otherFrame = CGRect(x: 1512, y: 0, width: 2560, height: 1440)

        XCTAssertNotEqual(
            LiveDisplay.fallbackIdentity(number: 1, frame: frame),
            LiveDisplay.fallbackIdentity(number: 2, frame: frame)
        )
        XCTAssertNotEqual(
            LiveDisplay.fallbackIdentity(number: nil, frame: frame),
            LiveDisplay.fallbackIdentity(number: nil, frame: otherFrame)
        )
        XCTAssertFalse(LiveDisplay.fallbackIdentity(number: nil, frame: frame).isEmpty)
        XCTAssertFalse(LiveDisplay.fallbackIdentity(number: 1, frame: frame).isEmpty)
    }
}
