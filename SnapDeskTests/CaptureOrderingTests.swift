import XCTest
@testable import SnapDesk

final class CaptureOrderingTests: XCTestCase {
    func testOnScreenFrontToBackThenMinimized() {
        let labels = ["A", "B", "C", "Z"]
        let candidates = [
            OrderedWindow(cgWindowID: 1, isMinimized: false),
            OrderedWindow(cgWindowID: 2, isMinimized: false),
            OrderedWindow(cgWindowID: 3, isMinimized: false),
            OrderedWindow(cgWindowID: 4, isMinimized: true),
        ]
        let ordering = CaptureOrdering.sortedIndices(
            of: candidates,
            onScreenFrontToBack: [3, 1, 2]
        )
        XCTAssertEqual(ordering, [2, 0, 1, 3])
        XCTAssertEqual(ordering.map { labels[$0] }, ["C", "A", "B", "Z"])
    }

    /// Everything the window server does not list as on-screen keeps its source order at the back:
    /// a window with no CoreGraphics id, a window on another Space, and a minimized one.
    func testWindowsMissingFromTheOnScreenListTrailInSourceOrder() {
        let candidates = [
            OrderedWindow(cgWindowID: nil, isMinimized: false),
            OrderedWindow(cgWindowID: 99, isMinimized: false),
            OrderedWindow(cgWindowID: 7, isMinimized: true),
            OrderedWindow(cgWindowID: 5, isMinimized: false),
        ]
        XCTAssertEqual(
            CaptureOrdering.sortedIndices(of: candidates, onScreenFrontToBack: [5, 7]),
            [3, 0, 1, 2]
        )
    }

    /// Two windows can share a CoreGraphics id (the same id listed twice), and the on-screen list
    /// can mention an id twice. The first mention is the front-most, and candidates that tie on
    /// rank keep their source order.
    func testDuplicateIDsKeepTheFrontmostRankAndTieBreakOnSourceOrder() {
        let labels = ["A", "B", "C"]
        let candidates = [
            OrderedWindow(cgWindowID: 7, isMinimized: false),
            OrderedWindow(cgWindowID: 5, isMinimized: false),
            OrderedWindow(cgWindowID: 7, isMinimized: false),
        ]
        let ordering = CaptureOrdering.sortedIndices(
            of: candidates,
            onScreenFrontToBack: [7, 5, 7]
        )
        XCTAssertEqual(ordering, [0, 2, 1])
        XCTAssertEqual(ordering.map { labels[$0] }, ["A", "C", "B"])
    }

    func testEmptyCandidatesProduceNoIndices() {
        XCTAssertEqual(CaptureOrdering.sortedIndices(of: [], onScreenFrontToBack: [1, 2]), [])
    }
}
