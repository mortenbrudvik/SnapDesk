import XCTest
@testable import SnapDesk

final class ScreenGeometryTests: XCTestCase {
    private let primary = LiveDisplay(
        id: "PRIMARY",
        name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 80, width: 1920, height: 975),
        scale: 2
    )
    private let right = LiveDisplay(
        id: "RIGHT",
        name: "LG UltraFine",
        frame: CGRect(x: 1920, y: -300, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1920, y: -300, width: 2560, height: 1415),
        scale: 2
    )
    private let left = LiveDisplay(
        id: "LEFT",
        name: "Studio Display",
        frame: CGRect(x: -1440, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: -1440, y: 0, width: 1440, height: 875),
        scale: 2
    )
    private var displays: [LiveDisplay] { [primary, right, left] }

    // MARK: Cocoa ↔ Accessibility

    func testCocoaToAXFlipsAboutThePrimaryTopEdge() {
        let cocoa = CGRect(x: 100, y: 50, width: 640, height: 480)
        let ax = ScreenGeometry.axRect(fromCocoa: cocoa, primaryMaxY: 1080)
        XCTAssertEqual(ax, CGRect(x: 100, y: 550, width: 640, height: 480))
    }

    func testAXToCocoaRoundTripsOnEveryDisplay() {
        for rect in [
            CGRect(x: 100, y: 50, width: 640, height: 480),
            CGRect(x: 2500, y: -200, width: 800, height: 600),
            CGRect(x: -1000, y: 300, width: 400, height: 300),
        ] {
            let ax = ScreenGeometry.axRect(fromCocoa: rect, primaryMaxY: 1080)
            XCTAssertEqual(ScreenGeometry.cocoaRect(fromAX: ax, primaryMaxY: 1080), rect)
        }
    }

    // MARK: Display lookup

    func testPointOnTheTopEdgeOfADisplayResolvesToIt() {
        XCTAssertEqual(ScreenGeometry.display(containing: CGPoint(x: 960, y: 1080), in: displays), primary)
    }

    func testPointOnASharedEdgeGoesToTheDisplayThatContainsItExactly() {
        XCTAssertEqual(ScreenGeometry.display(containing: CGPoint(x: 1920, y: 500), in: displays), right)
        XCTAssertEqual(ScreenGeometry.display(containing: CGPoint(x: 0, y: 500), in: displays), primary)
    }

    func testPointOffEveryDisplayResolvesToNothing() {
        XCTAssertNil(ScreenGeometry.display(containing: CGPoint(x: 960, y: 5000), in: displays))
        XCTAssertNil(ScreenGeometry.display(containing: CGPoint.zero, in: []))
    }

    func testRectResolvesByItsCenter() {
        let straddling = CGRect(x: 1500, y: 100, width: 1000, height: 500)
        XCTAssertEqual(ScreenGeometry.display(containing: straddling, in: displays), right)
    }

    /// The centre rule is not an "over half the area" rule. This window has five times as much of
    /// itself on each neighbour as on the narrow display holding its midpoint, and still belongs
    /// to the narrow one.
    func testRectBelongsToTheDisplayUnderItsCentreNotTheOneHoldingMostOfItsArea() {
        let wideLeft = LiveDisplay(
            id: "WIDE-LEFT",
            name: "Wide Left",
            frame: CGRect(x: -1000, y: 0, width: 1000, height: 1080),
            visibleFrame: CGRect(x: -1000, y: 0, width: 1000, height: 1080),
            scale: 1
        )
        let narrowMiddle = LiveDisplay(
            id: "NARROW",
            name: "Narrow",
            frame: CGRect(x: 0, y: 0, width: 100, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 1080),
            scale: 1
        )
        let wideRight = LiveDisplay(
            id: "WIDE-RIGHT",
            name: "Wide Right",
            frame: CGRect(x: 100, y: 0, width: 1000, height: 1080),
            visibleFrame: CGRect(x: 100, y: 0, width: 1000, height: 1080),
            scale: 1
        )
        let straddlingAll = CGRect(x: -500, y: 100, width: 1100, height: 500)

        XCTAssertEqual(
            ScreenGeometry.display(containing: straddlingAll, in: [wideLeft, narrowMiddle, wideRight]),
            narrowMiddle
        )
    }

    func testRectWithOffScreenCenterUsesLargestIntersection() {
        let hangingOffPrimary = CGRect(x: 100, y: 1000, width: 400, height: 200)
        XCTAssertNil(ScreenGeometry.display(containing: CGPoint(x: 300, y: 1100), in: displays))
        XCTAssertEqual(ScreenGeometry.display(containing: hangingOffPrimary, in: displays), primary)

        let hangingOffRight = CGRect(x: 2500, y: 1100, width: 400, height: 200)
        XCTAssertNil(ScreenGeometry.display(containing: CGPoint(x: 2700, y: 1200), in: displays))
        XCTAssertEqual(ScreenGeometry.display(containing: hangingOffRight, in: displays), right)
    }

    func testRectOffEveryDisplayResolvesToNothing() {
        let off = CGRect(x: 960, y: 5000, width: 100, height: 100)
        XCTAssertNil(ScreenGeometry.display(containing: off, in: displays))
        XCTAssertNil(ScreenGeometry.display(containing: off, in: []))
    }

    /// Mirrored displays report identical geometry, so the lookup cannot tell them apart by
    /// geometry; it must hand back the element it matched rather than a look-alike, or the caller
    /// stamps every window on the second screen with the first screen's identity.
    func testLookupReturnsTheMatchedDisplayNotAGeometricTwin() {
        let mirror = LiveDisplay(
            id: "MIRROR",
            name: "Mirrored",
            frame: primary.frame,
            visibleFrame: primary.visibleFrame,
            scale: primary.scale
        )
        let centre = CGPoint(x: primary.frame.midX, y: primary.frame.midY)

        XCTAssertEqual(ScreenGeometry.display(containing: centre, in: [mirror, primary])?.id, "MIRROR")
        XCTAssertEqual(ScreenGeometry.display(containing: centre, in: [primary, mirror])?.id, "PRIMARY")
    }
}
