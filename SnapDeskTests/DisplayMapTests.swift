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

    func testResolveUnknownIdEmptySavedReturnsMain() {
        XCTAssertEqual(
            DisplayMap.resolve(displayId: "unknown", saved: [], live: live, main: lg),
            lg
        )
    }
}
