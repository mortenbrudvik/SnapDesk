import AppKit
import KeyboardShortcuts
import XCTest
@testable import SnapDesk

/// `TEST_HOST` is SnapDesk itself, so `KeyboardShortcuts` reads and writes the shipping app's
/// `UserDefaults`: `reset(_:)` or `setShortcut(_:for:)` from a test edits the shortcuts of whoever
/// runs the suite. Each test therefore runs inside a snapshot of the app's persistent domain that
/// `tearDown` writes back; XCTest runs `tearDown` after a test that fails or throws too, so the
/// restore does not depend on a test reaching its last line.
///
/// The snapshot covers the whole domain rather than the `KeyboardShortcuts_*` keys because the
/// library's key format is private: guessing it wrong would silently protect nothing. Taking it
/// from the persistent domain rather than `object(forKey:)` also keeps registration-domain values
/// out, which must never be written to disk.
final class HotkeyNameTests: XCTestCase {
    /// `nil` until a snapshot exists, so a failed `setUp` leaves `tearDown` nothing to restore
    /// instead of having it wipe a domain it never read.
    private var appDomain: String?
    private var savedDefaults: [String: Any] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        savedDefaults = Self.snapshot(of: domain)
        appDomain = domain
    }

    override func tearDown() {
        if let appDomain {
            Self.restore(savedDefaults, of: appDomain)
        }
        appDomain = nil
        savedDefaults = [:]
        super.tearDown()
    }

    private static func snapshot(of domain: String) -> [String: Any] {
        UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
    }

    /// Only writes keys that actually differ, so an untouched domain is left byte-identical rather
    /// than rewritten wholesale.
    private static func restore(_ saved: [String: Any], of domain: String) {
        let current = snapshot(of: domain)
        for key in Set(saved.keys).union(current.keys) {
            let original = saved[key].flatMap { $0 as? NSObject }
            guard original != current[key].flatMap({ $0 as? NSObject }) else { continue }
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    func testNamesKeepTheRawValuesUserCustomisationsAreStoredUnder() {
        XCTAssertEqual(KeyboardShortcuts.Name.capture.rawValue, "capture")
        XCTAssertEqual(KeyboardShortcuts.Name.editor.rawValue, "editor")
    }

    func testEachNameIsRegisteredWithItsDeclaredDefault() {
        XCTAssertEqual(KeyboardShortcuts.Name.capture.defaultShortcut, HotkeyName.captureDefault)
        XCTAssertEqual(KeyboardShortcuts.Name.editor.defaultShortcut, HotkeyName.editorDefault)
    }

    /// Two constants agreeing says nothing about which keys fire: the shortcut reaches
    /// `HotkeyCenter` and Carbon only after a JSON round trip through `UserDefaults`, and
    /// `project.yml` pins KeyboardShortcuts only to `from: "2.0.0"`, so that encoding can change
    /// under the app on any dependency update.
    func testTheLibraryResolvesEachNameToItsDeclaredDefault() {
        KeyboardShortcuts.reset(.capture, .editor)

        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .capture), HotkeyName.captureDefault)
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .editor), HotkeyName.editorDefault)
    }

    /// Declaring a default must not pin the binding: a customised shortcut is what the app has to
    /// resolve to, and the default has to stay intact underneath it for Reset to mean anything.
    func testACustomisedShortcutWinsOverTheDeclaredDefault() {
        // Reset first: whoever runs the suite may already have customised either command, and the
        // assertions below have to describe the library, not this machine.
        KeyboardShortcuts.reset(.capture, .editor)
        let custom = KeyboardShortcuts.Shortcut(.f13, modifiers: [.shift, .command])
        KeyboardShortcuts.setShortcut(custom, for: .capture)

        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .capture), custom)
        XCTAssertEqual(KeyboardShortcuts.Name.capture.defaultShortcut, HotkeyName.captureDefault)
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .editor), HotkeyName.editorDefault)
    }

    /// The tests above are only safe to run on a developer's own machine because the restore is
    /// correct, and nothing else in the suite would notice if it stopped being. Exercised
    /// directly rather than through `tearDown` so it does not depend on XCTest's ordering.
    func testRestoringASnapshotClearsNewKeysAndPutsOverwrittenOnesBack() throws {
        let domain = try XCTUnwrap(appDomain)
        let addedDuringTest = "HotkeyNameTests_absentBeforeSnapshot"
        let editedDuringTest = "HotkeyNameTests_presentBeforeSnapshot"
        UserDefaults.standard.set("original", forKey: editedDuringTest)

        let saved = Self.snapshot(of: domain)
        UserDefaults.standard.set("scribbled", forKey: addedDuringTest)
        UserDefaults.standard.set("overwritten", forKey: editedDuringTest)
        Self.restore(saved, of: domain)

        XCTAssertNil(UserDefaults.standard.object(forKey: addedDuringTest))
        XCTAssertEqual(UserDefaults.standard.string(forKey: editedDuringTest), "original")
    }

    func testDefaultsAreDistinctSoOneCommandCannotShadowTheOther() {
        XCTAssertNotEqual(HotkeyName.captureDefault, HotkeyName.editorDefault)
    }

    /// ⌃⌥⌘ on both: a plain ⌘-key default would collide with whatever app is frontmost, and
    /// Carbon hands the combination to whoever registered it first.
    func testDefaultsUseTheFullControlOptionCommandModifierSet() {
        for shortcut in [HotkeyName.captureDefault, HotkeyName.editorDefault] {
            XCTAssertEqual(shortcut.modifiers, [.control, .option, .command], "\(shortcut)")
        }
    }

    func testDefaultKeysAreCForCaptureAndEForEditor() {
        XCTAssertEqual(HotkeyName.captureDefault.key, KeyboardShortcuts.Key.c)
        XCTAssertEqual(HotkeyName.editorDefault.key, KeyboardShortcuts.Key.e)
    }
}
