import KeyboardShortcuts

enum HotkeyName {
    static let captureDefault = KeyboardShortcuts.Shortcut(.c, modifiers: [.control, .option, .command])
    static let editorDefault = KeyboardShortcuts.Shortcut(.e, modifiers: [.control, .option, .command])
}

extension KeyboardShortcuts.Name {
    static let capture = Self("capture", default: HotkeyName.captureDefault)
    static let editor = Self("editor", default: HotkeyName.editorDefault)
}
