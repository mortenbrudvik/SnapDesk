import KeyboardShortcuts
import XCTest
@testable import SnapDesk

final class HotkeyNameTests: XCTestCase {
    func testCaptureNameAndDefaultShortcut() {
        XCTAssertEqual(KeyboardShortcuts.Name.capture.rawValue, "capture")
        XCTAssertEqual(
            HotkeyName.captureDefault,
            KeyboardShortcuts.Shortcut(.c, modifiers: [.control, .option, .command])
        )
        KeyboardShortcuts.reset(.capture)
        XCTAssertEqual(
            KeyboardShortcuts.getShortcut(for: .capture),
            KeyboardShortcuts.Shortcut(.c, modifiers: [.control, .option, .command])
        )
    }

    func testEditorNameAndDefaultShortcut() {
        XCTAssertEqual(KeyboardShortcuts.Name.editor.rawValue, "editor")
        XCTAssertEqual(
            HotkeyName.editorDefault,
            KeyboardShortcuts.Shortcut(.e, modifiers: [.control, .option, .command])
        )
        KeyboardShortcuts.reset(.editor)
        XCTAssertEqual(
            KeyboardShortcuts.getShortcut(for: .editor),
            KeyboardShortcuts.Shortcut(.e, modifiers: [.control, .option, .command])
        )
    }
}
