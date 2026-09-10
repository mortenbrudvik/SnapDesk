import CoreGraphics
import XCTest
@testable import SnapDesk

private extension CGRect {
    var codable: CodableRect { CodableRect(self) }
}

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
    /// Close to the built-in display in size but not identical, so the closest-size rule has a
    /// single right answer rather than a tie that `min` breaks by list order.
    private let similarUnnamed = LiveDisplay(
        id: "CCC",
        name: "",
        frame: CGRect(x: -1600, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: -1600, y: 38, width: 1600, height: 1000),
        scale: 2
    )

    /// The closest-size candidate is listed last, so a result that merely picked the first entry
    /// cannot pass as the right one.
    private var live: [LiveDisplay] { [similarUnnamed, lg, builtIn] }

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
        XCTAssertEqual(DisplayMap.matchWithRule(saved: saved, among: live)?.rule, .closestSize)
    }

    func testEachRuleReportsItself() {
        let byID = SavedDisplay(id: "BBB", name: "Renamed", frame: lg.frame.codable, visibleFrame: lg.visibleFrame.codable, scale: 2)
        let byName = SavedDisplay(id: "MISSING", name: "LG UltraFine", frame: lg.frame.codable, visibleFrame: lg.visibleFrame.codable, scale: 2)
        XCTAssertEqual(DisplayMap.matchWithRule(saved: byID, among: live)?.rule, .sameID)
        XCTAssertEqual(DisplayMap.matchWithRule(saved: byName, among: live)?.rule, .sameName)
        XCTAssertNil(DisplayMap.matchWithRule(saved: byName, among: []))
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
            DisplayMap.resolve(displayId: "GONE", saved: [saved], live: live, primary: builtIn),
            lg
        )
    }

    func testResolveUnknownIdEmptySavedReturnsMain() {
        XCTAssertEqual(
            DisplayMap.resolve(displayId: "unknown", saved: [], live: live, primary: lg),
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
            DisplayMap.resolve(displayId: "AAA", saved: [saved], live: [], primary: builtIn),
            builtIn
        )
    }

    // MARK: Identity of a display with no UUID

    /// The stand-in identity is what keeps two UUID-less displays apart, both when matching a
    /// saved workspace and as the `Identifiable` id of `SavedDisplay`.
    /// `OnceGate` is what keeps `LiveDisplay`'s missing-UUID line to one per identity: that value
    /// is rebuilt from `NSScreen` on every read — per slot, per correction poll, and inside every
    /// zoom read-back — so an unconditional line appeared dozens of times per placed window and
    /// buried the ones that mattered. This covers the gate; the call site is not covered, because
    /// it needs a UUID-less screen.
    @MainActor
    func testOnceGateAnswersOncePerSubject() {
        let gate = OnceGate()

        XCTAssertTrue(gate.shouldLog("display-number:1"))
        XCTAssertFalse(gate.shouldLog("display-number:1"))
        XCTAssertTrue(gate.shouldLog("display-number:2"), "a different display still gets its line")
        XCTAssertFalse(gate.shouldLog("display-number:2"))
    }

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
