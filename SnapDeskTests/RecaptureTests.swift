import XCTest
@testable import SnapDesk

final class RecaptureTests: XCTestCase {
    private let safari = "com.apple.Safari"
    private let chrome = "com.google.Chrome"

    func testSameTitleKeepsArguments() {
        let old = [
            savedWindow(bundleIdentifier: safari, title: "GitHub", arguments: "https://github.com")
        ]
        let new = [
            savedWindow(bundleIdentifier: safari, title: "GitHub", arguments: "")
        ]
        let merged = Recapture.merge(old: old, new: new)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].arguments, "https://github.com")
        XCTAssertEqual(merged[0].title, "GitHub")
    }

    func testTitleChangedKeepsArgsViaBundleIDFallback() {
        let old = [
            savedWindow(bundleIdentifier: safari, title: "GitHub", arguments: "https://github.com")
        ]
        let new = [
            savedWindow(bundleIdentifier: safari, title: "Renamed Tab", arguments: "")
        ]
        let merged = Recapture.merge(old: old, new: new)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].arguments, "https://github.com")
        XCTAssertEqual(merged[0].title, "Renamed Tab")
    }

    func testTwoSlotsGreedyOneToOne() {
        let old = [
            savedWindow(bundleIdentifier: safari, title: "GitHub", arguments: "https://github.com"),
            savedWindow(bundleIdentifier: safari, title: "Docs", arguments: "https://docs.example")
        ]
        let new = [
            savedWindow(bundleIdentifier: safari, title: "GitHub", arguments: ""),
            savedWindow(bundleIdentifier: safari, title: "Docs", arguments: "")
        ]
        let merged = Recapture.merge(old: old, new: new)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].title, "GitHub")
        XCTAssertEqual(merged[0].arguments, "https://github.com")
        XCTAssertEqual(merged[1].title, "Docs")
        XCTAssertEqual(merged[1].arguments, "https://docs.example")
    }

    func testUnmatchedNewWindowKeepsEmptyArguments() {
        let old = [
            savedWindow(bundleIdentifier: safari, title: "GitHub", arguments: "https://github.com")
        ]
        let new = [
            savedWindow(bundleIdentifier: chrome, title: "New Tab", arguments: "")
        ]
        let merged = Recapture.merge(old: old, new: new)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].bundleIdentifier, chrome)
        XCTAssertEqual(merged[0].arguments, "")
    }

    private func savedWindow(
        bundleIdentifier: String,
        title: String,
        arguments: String
    ) -> SavedWindow {
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
            arguments: arguments
        )
    }
}
