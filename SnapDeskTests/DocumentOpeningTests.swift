import XCTest
@testable import SnapDesk

final class DocumentOpeningTests: XCTestCase {
    /// Measured on this machine: Brave's Info.plist carries `CrProductDirName` and Safari's does
    /// not. Chromium's build writes it into every browser built on it, so it is the marker for
    /// "hand `--new-window` to a new instance and the running one opens a window".
    func testAnAppWithACrProductDirNameIsAChromiumBrowser() {
        XCTAssertTrue(
            ChromiumHandoff.isChromiumApp(infoPlist: [
                "CFBundleIdentifier": "com.brave.Browser",
                "CrProductDirName": "BraveSoftware/Brave-Browser",
            ])
        )
    }

    func testAnAppWithoutItIsNot() {
        XCTAssertFalse(ChromiumHandoff.isChromiumApp(infoPlist: ["CFBundleIdentifier": "com.apple.Safari"]))
        XCTAssertFalse(ChromiumHandoff.isChromiumApp(infoPlist: [:]))
    }

    /// `--new-window` has to come first so the document is what it applies to; the slot's own
    /// arguments follow, and a file is passed as the URL Chromium understands.
    func testTheHandoffArgumentsPutNewWindowBeforeTheDocument() {
        XCTAssertEqual(
            ChromiumHandoff.arguments(opening: URL(string: "https://example.com/docs")!, then: ["--profile-directory=Work"]),
            ["--new-window", "https://example.com/docs", "--profile-directory=Work"]
        )
        XCTAssertEqual(
            ChromiumHandoff.arguments(opening: URL(fileURLWithPath: "/Users/me/a b.html"), then: []),
            ["--new-window", "file:///Users/me/a%20b.html"]
        )
    }
}
