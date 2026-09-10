import XCTest
@testable import SnapDesk

final class FramePlacementTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 38, width: 1512, height: 916)

    func testRelativeSubtractsVisibleOrigin() {
        let cocoa = CGRect(x: 100, y: 138, width: 800, height: 600)
        XCTAssertEqual(
            FramePlacement.relative(cocoa: cocoa, visibleFrame: visible),
            CGRect(x: 100, y: 100, width: 800, height: 600)
        )
    }

    func testCocoaAddsVisibleOrigin() {
        let relative = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(
            FramePlacement.cocoa(relative: relative, visibleFrame: visible),
            CGRect(x: 100, y: 138, width: 800, height: 600)
        )
    }

    func testRestoreUsesPointsWhenSizeMatches() {
        let relative = CGRect(x: 10, y: 20, width: 400, height: 300)
        let live = CGRect(x: 1920, y: 38, width: 1512, height: 916)
        XCTAssertEqual(
            FramePlacement.restore(relative: relative, savedVisible: visible, liveVisible: live),
            CGRect(x: 1930, y: 58, width: 400, height: 300)
        )
    }

    func testRestoreScalesWhenSizeDiffers() {
        let relative = CGRect(x: 0, y: 0, width: 756, height: 458)
        let live = CGRect(x: 0, y: 0, width: 3024, height: 1832)
        let restored = FramePlacement.restore(relative: relative, savedVisible: visible, liveVisible: live)
        XCTAssertEqual(restored.origin.x, 0, accuracy: 0.5)
        XCTAssertEqual(restored.size.width, 1512, accuracy: 0.5)
        XCTAssertEqual(restored.size.height, 916, accuracy: 0.5)
    }

    func testClampPullsAFullyOffscreenWindowToTheTopRightCorner() {
        let off = CGRect(x: 5000, y: 5000, width: 400, height: 300)
        XCTAssertEqual(
            FramePlacement.clamp(off, to: visible),
            CGRect(x: 1112, y: 654, width: 400, height: 300)
        )
    }

    func testClampPullsAWindowPastTheBottomLeftBackInside() {
        let off = CGRect(x: -700, y: -500, width: 800, height: 600)
        XCTAssertEqual(
            FramePlacement.clamp(off, to: visible),
            CGRect(x: 0, y: 38, width: 800, height: 600)
        )
    }

    /// The clamp keeps the whole window inside `visible`, which is what leaves the title bar
    /// grabbable — a taller-than-a-title-bar window is not parked with only its top strip on.
    func testClampLeavesTheWholeWindowInsideNotJustItsTitleBar() {
        let tall = CGRect(x: 0, y: 700, width: 800, height: 900)
        let clamped = FramePlacement.clamp(tall, to: visible)
        XCTAssertEqual(clamped, CGRect(x: 0, y: 54, width: 800, height: 900))
        XCTAssertTrue(visible.contains(clamped))
    }

    func testClampLeavesAWindowAlreadyInsideUntouched() {
        let inside = CGRect(x: 100, y: 138, width: 400, height: 300)
        XCTAssertEqual(FramePlacement.clamp(inside, to: visible), inside)
    }

    func testClampShrinksLargerThanVisible() {
        let huge = CGRect(x: -100, y: -100, width: 4000, height: 3000)
        let clamped = FramePlacement.clamp(huge, to: visible)
        XCTAssertEqual(clamped, visible)
    }
}
