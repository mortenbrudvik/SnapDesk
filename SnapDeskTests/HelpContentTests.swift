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

    /// A help page that lists what a window row can do, and silently omits one of its controls,
    /// is worse than no list: the reader takes the list for the whole set. This is the test that
    /// makes adding a control to the row a failing build until the help catches up.
    func testTheEditorTopicMentionsEveryControlOnAWindowRow() throws {
        let editor = try XCTUnwrap(HelpContent.topics().first { $0.title == "The editor" })
        let text = editor.entries.map(\.detail).joined(separator: " ").lowercased()

        for control in ["title", "display", "minimized", "zoomed", "fullscreen", "document", "arguments"] {
            XCTAssertTrue(text.contains(control), "the editor topic never mentions \(control)")
        }
    }

    /// The named entry of the named topic, so a test asserts on the sentence that explains a
    /// thing rather than on a word that could appear anywhere in the help.
    private func entry(_ term: String, in topicTitle: String) throws -> HelpContent.Entry {
        let topic = try XCTUnwrap(
            HelpContent.topics().first { $0.title == topicTitle },
            "no topic titled \(topicTitle)"
        )
        return try XCTUnwrap(
            topic.entries.first { $0.term == term },
            "no entry \(term) under \(topicTitle)"
        )
    }

    /// Restoring the same workspace twice opens the same page twice, because nothing checks
    /// whether the window is already there. That is a real limitation the user meets on their
    /// second restore, and help that omits it lets them think they are looking at a bug.
    func testTheHelpIsHonestAboutRestoringTheSameDocumentTwice() throws {
        let document = try entry("Document or URL", in: "The editor")
        XCTAssertTrue(
            document.detail.contains("opens the same page twice"),
            "the Document entry never warns that a second restore repeats a document"
        )
    }

    /// Measured: a running browser puts a document into a tab, not a window, unless it is a
    /// Chromium-based one asked for a window. The entry has to say so, or the user reads "No
    /// window" on a Safari slot as a bug.
    func testTheDocumentEntrySaysWhatABrowserDoesWithAPage() throws {
        let document = try entry("Document or URL", in: "The editor")
        XCTAssertTrue(document.detail.contains("Safari opens a tab"))
        XCTAssertTrue(document.detail.contains("Chromium-based browsers"))
    }

    /// Text the field will not store is marked as such under it, and the help says so — the
    /// field otherwise shows one thing while the file holds another.
    func testTheDocumentEntrySaysUnstorableTextIsMarked() throws {
        let document = try entry("Document or URL", in: "The editor")
        XCTAssertTrue(document.detail.contains("marked"))
    }

    /// The five workspace shortcuts ship unbound, so nothing in the app reveals them until the
    /// user goes looking. A shortcuts page that omits them leaves the feature undiscoverable.
    func testTheShortcutsTopicExplainsTheWorkspaceSlots() throws {
        let slots = try entry("Workspace shortcuts", in: HelpContent.shortcutsTitle)
        XCTAssertTrue(slots.detail.contains("Settings"), "it has to say where the keys and workspaces are chosen")
    }

    /// "When SnapDesk starts" is not "at login", and the help has to say which it is or the user
    /// will reasonably expect the other.
    func testTheHelpExplainsWhenAStartupWorkspaceIsRestored() throws {
        let startup = try entry("Restore when SnapDesk starts", in: "Settings")
        XCTAssertTrue(startup.detail.contains("at login"), "the distinction from login is the point of the entry")
    }

    /// The sidebar lists a folder only once the user nominates one, so nothing in the app
    /// reveals the feature until they find the button. The help has to name the button.
    func testTheHelpExplainsTheWorkspaceFolder() throws {
        let list = try entry("The Workspaces list", in: "The editor")
        XCTAssertTrue(list.detail.contains("Choose Folder"), "the entry has to name the button that nominates a folder")
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

    /// A refused fullscreen folds into the same HUD row as a refused zoom or minimize, so the row
    /// and its help entry have to name all three states or the user checks the wrong toggles.
    func testTheStateFailureRowAndItsHelpNameFullscreen() throws {
        XCTAssertTrue(SlotFailure.stateNotRestored.displayText.lowercased().contains("fullscreen"))
        let troubleshooting = try XCTUnwrap(
            HelpContent.topics().first { $0.title == HelpContent.troubleshootingTitle }
        )
        let entry = try XCTUnwrap(
            troubleshooting.entries.first { $0.term == SlotFailure.stateNotRestored.displayText }
        )
        XCTAssertTrue(entry.detail.lowercased().contains("fullscreen"))
    }
}
