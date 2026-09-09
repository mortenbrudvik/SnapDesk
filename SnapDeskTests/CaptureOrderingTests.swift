import XCTest
@testable import SnapDesk

final class CaptureOrderingTests: XCTestCase {
    func testOnScreenFrontToBackThenMinimized() {
        let candidates = [
            OrderedWindow(cgWindowID: 1, isMinimized: false, label: "A"),
            OrderedWindow(cgWindowID: 2, isMinimized: false, label: "B"),
            OrderedWindow(cgWindowID: 3, isMinimized: false, label: "C"),
            OrderedWindow(cgWindowID: 4, isMinimized: true, label: "Z"),
        ]
        let sorted = CaptureOrdering.sort(
            candidates: candidates,
            onScreenFrontToBack: [3, 1, 2]
        )
        XCTAssertEqual(sorted.map(\.label), ["C", "A", "B", "Z"])
    }
}
