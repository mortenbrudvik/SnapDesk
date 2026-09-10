import AppKit
import KeyboardShortcuts

/// Registers the Capture and Editor global hotkeys once. The library uses Carbon
/// `RegisterEventHotKey`, so they fire while any app is frontmost.
@MainActor
final class HotkeyCenter {
    private weak var capturing: (any WorkspaceCapturing)?
    private let onEditor: () -> Void
    private var started = false

    init(capturing: any WorkspaceCapturing, onEditor: @escaping () -> Void) {
        self.capturing = capturing
        self.onEditor = onEditor
    }

    /// Safe to call more than once: the library keeps handlers globally, so registering twice
    /// would capture or open the editor twice per key press.
    func start() {
        guard !started else { return }
        started = true
        KeyboardShortcuts.onKeyUp(for: .capture) { [weak capturing] in
            Task { @MainActor in
                capturing?.captureToEditor()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .editor) { [onEditor] in
            Task { @MainActor in
                onEditor()
            }
        }
        logBindings()
    }

    /// Logs what each command is *configured* to use. Deliberately not phrased as confirmation:
    /// the library swallows Carbon registration failures (it prints to stdout, which an
    /// LSUIElement app discards, and still reports the shortcut as set), so a combination
    /// another app already owns logs exactly the same line and then never fires. Distinguishing
    /// the two would need the Carbon status the library never surfaces; until then the only
    /// real check is pressing the key. An unbound command, at least, can never fire, so that
    /// one is a warning.
    private func logBindings() {
        for name in [KeyboardShortcuts.Name.capture, .editor] {
            guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else {
                Log.hotkeys.warning("\(name.rawValue, privacy: .public): unbound, so it will never fire")
                continue
            }
            Log.hotkeys.info("\(name.rawValue, privacy: .public): configured as \(String(describing: shortcut), privacy: .public) (configured, not confirmed registered)")
        }
    }
}
