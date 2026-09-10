import AppKit
import XCTest
@testable import SnapDesk

/// The About panel itself is AppKit's, and drawing it is not something a test can judge. What is
/// worth pinning is the text SnapDesk hands it: the acknowledgement is a licence obligation, and
/// an obligation that quietly disappears is the kind of thing nobody notices until it matters.
@MainActor
final class AboutPanelTests: XCTestCase {
    func testTheCreditsSayWhatTheAppDoes() throws {
        let credits = try XCTUnwrap(AboutPanel.options[.credits] as? NSAttributedString).string

        XCTAssertTrue(credits.contains("windows"), credits)
        XCTAssertFalse(credits.isEmpty)
    }

    /// KeyboardShortcuts ships under the MIT licence, which requires its copyright notice to travel
    /// with any copy of the software. This is where it travels.
    func testTheCreditsCarryTheThirdPartyAcknowledgement() throws {
        let credits = try XCTUnwrap(AboutPanel.options[.credits] as? NSAttributedString).string

        XCTAssertTrue(credits.contains("KeyboardShortcuts"), credits)
        XCTAssertTrue(credits.contains("Sindre Sorhus"), credits)
        XCTAssertTrue(credits.contains("MIT"), credits)
    }

    /// Name, version and copyright are deliberately *not* passed: AppKit reads them from the
    /// bundle, so they cannot drift from what the app actually is. Passing them would be a second
    /// copy to keep in step with `project.yml`.
    func testVersionAndNameAreLeftToTheBundle() {
        XCTAssertNil(AboutPanel.options[.applicationName])
        XCTAssertNil(AboutPanel.options[.applicationVersion])
        XCTAssertNil(AboutPanel.options[.version])

        // And the bundle really does carry them, which is what makes leaving them out safe.
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "SnapDesk")
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString"))
        let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
        XCTAssertTrue(copyright?.contains("Morten Brudvik") == true, copyright ?? "nil")
    }
}
