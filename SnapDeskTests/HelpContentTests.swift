import KeyboardShortcuts
import XCTest
@testable import SnapDesk

/// The help text is data rather than view code so it can be checked against the app it describes.
/// This repository has already been through one round of documentation that quietly stopped being
/// true; help shown to a user is the worst place for that to happen.
@MainActor
final class HelpContentTests: XCTestCase {
    func testEveryTopicHasATitleAndContent() {
        let topics = HelpContent.topics()
        XCTAssertFalse(topics.isEmpty)

        for topic in topics {
            XCTAssertFalse(topic.title.isEmpty, "a topic shipped without a title")
            XCTAssertFalse(topic.entries.isEmpty, "\(topic.title) has no entries")
            for entry in topic.entries {
                XCTAssertFalse(entry.detail.isEmpty, "\(topic.title) → \(entry.term) has no detail")
            }
        }
    }

    /// The shortcut is shown, not described from memory. A user who rebinds Capture must see their
    /// own combination here, not the default it no longer is.
    func testShortcutRowsShowWhateverIsActuallyBound() throws {
        let topics = HelpContent.topics { name in
            name == .capture ? "⇧⌘9" : "⌥F13"
        }
        let shortcuts = try XCTUnwrap(topics.first { $0.title == HelpContent.shortcutsTitle })

        // The row itself, not merely the text somewhere on the page: the same keys are mentioned
        // in Getting started, so searching the whole document would pass against a row that had
        // been hardcoded back to the default.
        XCTAssertEqual(shortcuts.entries.first { $0.term == "Capture" }?.detail, "⇧⌘9")
        XCTAssertEqual(shortcuts.entries.first { $0.term == "Editor" }?.detail, "⌥F13")

        // And the walkthrough quotes the live value too, so a rebound key is right in both places.
        let gettingStarted = try XCTUnwrap(topics.first { $0.title == "Getting started" })
        XCTAssertTrue(
            gettingStarted.entries.contains { $0.detail.contains("⇧⌘9") },
            "the Capture step does not quote the bound shortcut"
        )
    }

    /// And the default really is the library's answer, not a constant that happens to match today.
    /// Writes to the shared domain, so it snapshots and restores it the way `HotkeyNameTests` does.
    func testTheDefaultLookupComesFromTheShortcutLibrary() throws {
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let saved = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        addTeardownBlock {
            let current = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
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

        let custom = KeyboardShortcuts.Shortcut(.f13, modifiers: [.shift, .command])
        KeyboardShortcuts.setShortcut(custom, for: .capture)

        let shown = HelpContent.currentShortcut(for: .capture)

        XCTAssertEqual(shown, String(describing: custom))
        XCTAssertNotEqual(shown, String(describing: HotkeyName.captureDefault))
    }

    /// An unbound command is a real state — the library lets a user clear one — and "nothing" is
    /// not a keystroke anybody can press.
    func testAnUnboundCommandSaysSoRatherThanShowingNothing() throws {
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let saved = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        addTeardownBlock {
            let current = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
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

        KeyboardShortcuts.setShortcut(nil, for: .editor)

        XCTAssertEqual(HelpContent.currentShortcut(for: .editor), "not set")
    }

    /// The HUD is transient and its failures are terse. Every one it can show has to be explained
    /// somewhere the user can read at leisure — and adding a new failure should fail this test
    /// until it is.
    func testTroubleshootingExplainsEveryFailureTheHUDCanShow() {
        let troubleshooting = HelpContent.topics().first { $0.title == HelpContent.troubleshootingTitle }
        let terms = Set(troubleshooting?.entries.map(\.term) ?? [])

        for failure in SlotFailure.allCases {
            XCTAssertTrue(
                terms.contains(failure.displayText),
                "the HUD can say \"\(failure.displayText)\" and the help does not explain it"
            )
        }
    }
}
