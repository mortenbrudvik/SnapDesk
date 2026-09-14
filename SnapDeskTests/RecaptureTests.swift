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

    func testEmptyCaptureMergesToNothingSoCallersMustRefuseIt() {
        let old = [
            savedWindow(bundleIdentifier: safari, title: "GitHub", arguments: "https://github.com")
        ]

        XCTAssertTrue(Recapture.merge(old: old, new: []).isEmpty)
    }

    /// A document the user typed by hand — Safari vends none, so the help tells them to — has to
    /// survive a recapture the way arguments do, or the next Capture in the editor throws it away.
    func testARecaptureKeepsTheOldDocumentWhenTheNewCaptureHasNone() {
        let old = [
            savedWindow(bundleIdentifier: safari, title: "GitHub", arguments: "", document: "https://github.com")
        ]
        let new = [
            savedWindow(bundleIdentifier: safari, title: "GitHub", arguments: "")
        ]
        let merged = Recapture.merge(old: old, new: new)
        XCTAssertEqual(merged.map(\.document), ["https://github.com"])
    }

    /// But a document the app vends now is the current one, and wins.
    func testARecaptureTakesTheDocumentTheAppVendsNow() {
        let old = [
            savedWindow(bundleIdentifier: chrome, title: "Docs", arguments: "", document: "https://example.com/old")
        ]
        let new = [
            savedWindow(bundleIdentifier: chrome, title: "Docs", arguments: "", document: "https://example.com/new")
        ]
        let merged = Recapture.merge(old: old, new: new)
        XCTAssertEqual(merged.map(\.document), ["https://example.com/new"])
    }

    private func savedWindow(
        bundleIdentifier: String,
        title: String,
        arguments: String,
        document: String? = nil
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
            document: document,
            arguments: arguments
        )
    }
}
