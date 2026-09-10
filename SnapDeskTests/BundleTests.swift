import AppKit
import XCTest
@testable import SnapDesk

final class BundleTests: XCTestCase {
    func testBundleIdentifierIsSnapDesk() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.brudvik.snapdesk")
    }

    /// SnapDesk is `LSUIElement`, so it has no Dock icon and the app icon is never the big thing
    /// on screen — which is exactly why nothing would notice it going missing. It is what the user
    /// looks for in the System Settings › Privacy & Security › Accessibility list, in Login Items,
    /// and in Finder, and a build with no catalog shows a blank page there instead.
    @MainActor
    func testTheAppCarriesItsIcon() throws {
        let icon = try XCTUnwrap(
            NSImage(named: "AppIcon"),
            "the AppIcon asset is missing from the built bundle"
        )
        XCTAssertGreaterThan(icon.size.width, 0)

        // The sizes the Accessibility list and Finder actually ask for. A catalog holding only the
        // large art still looks wrong where this app is seen most.
        let widths = Set(icon.representations.map(\.pixelsWide))
        for expected in [16, 32, 128, 512, 1024] {
            XCTAssertTrue(widths.contains(expected), "no \(expected)px representation; have \(widths.sorted())")
        }
    }

    /// `actool` writes this key when it compiles the catalog, and the Finder and Settings read it
    /// to find the icon. A catalog that is present but not named by the build setting compiles
    /// fine and leaves this empty.
    func testTheBundleNamesItsIconAsset() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String, "AppIcon")
    }
}
