import KeyboardShortcuts

enum HotkeyName {
    static let captureDefault = KeyboardShortcuts.Shortcut(.c, modifiers: [.control, .option, .command])
    static let editorDefault = KeyboardShortcuts.Shortcut(.e, modifiers: [.control, .option, .command])
}

extension KeyboardShortcuts.Name {
    static let capture = Self("capture", default: HotkeyName.captureDefault)
    static let editor = Self("editor", default: HotkeyName.editorDefault)

    /// Five fixed slots a workspace can be bound to, in slot order.
    ///
    /// Fixed rather than one name per workspace, because a `Name` is a *persisted* identity: the
    /// library stores a binding under its raw value and nothing ever removes one. Minting a name
    /// per file would leave a dead binding in defaults every time a workspace was deleted.
    ///
    /// No default shortcut on any of them. Which keys these use is the user's to choose, and
    /// picking five combinations on their behalf would collide with something.
    static let workspaceSlots: [Self] = [
        Self("workspace1"),
        Self("workspace2"),
        Self("workspace3"),
        Self("workspace4"),
        Self("workspace5"),
    ]
}
