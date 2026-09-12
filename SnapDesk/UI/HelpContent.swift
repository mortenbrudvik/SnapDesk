import Foundation
import KeyboardShortcuts

/// The help text, as data rather than as view code.
///
/// Two things here are read from the app rather than written down beside it, because this project
/// has already been through a round of documentation that quietly stopped being true. The shortcut
/// rows ask the shortcut library what is bound right now, so a user who rebinds Capture sees their
/// own keys. And every failure the launch HUD can display has an entry in the troubleshooting
/// topic, which a test enforces against `SlotFailure` — a new failure fails the suite until it is
/// explained here.
@MainActor
enum HelpContent {
    struct Entry: Equatable {
        var term: String
        var detail: String
    }

    struct Topic: Equatable, Identifiable {
        var title: String
        var entries: [Entry]
        var id: String { title }
    }

    static let shortcutsTitle = "Keyboard shortcuts"
    static let troubleshootingTitle = "If a window did not come back"

    /// What a command is bound to, in the form the menu shows it, or "not set" when a user has
    /// cleared it — a command with no keys is a real state, and blank is not a keystroke.
    static func currentShortcut(for name: KeyboardShortcuts.Name) -> String {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return "not set" }
        return String(describing: shortcut)
    }

    static func topics(
        shortcut: @MainActor (KeyboardShortcuts.Name) -> String = currentShortcut
    ) -> [Topic] {
        [
            Topic(title: "Getting started", entries: [
                Entry(
                    term: "1. Allow Accessibility",
                    detail: """
                    SnapDesk moves other apps' windows, which macOS only permits with Accessibility \
                    access. Open System Settings › Privacy & Security › Accessibility, add SnapDesk, \
                    and switch it on. Then choose Relaunch from the menu: macOS only applies the \
                    permission to a freshly started copy of the app.
                    """
                ),
                Entry(
                    term: "2. Arrange your desk",
                    detail: """
                    Put the windows where you want them. SnapDesk records what is on screen right \
                    now — there is no separate canvas to design a layout on.
                    """
                ),
                Entry(
                    term: "3. Capture",
                    detail: """
                    Choose Capture (\(shortcut(.capture))). The editor opens on a new workspace \
                    holding every window SnapDesk could read. Nothing is written to disk yet.
                    """
                ),
                Entry(
                    term: "4. Save",
                    detail: """
                    Name the workspace and choose Save. You get a .snapdesk file you can keep \
                    anywhere — the Desktop, a project folder, a repository.
                    """
                ),
                Entry(
                    term: "5. Restore",
                    detail: """
                    Double-click that file, or pick it from Recents. SnapDesk opens the apps it \
                    needs and puts the windows back on the displays and frames you saved.
                    """
                ),
            ]),

            Topic(title: "What the menu does", entries: [
                Entry(term: "Capture", detail: "Snapshots the windows open right now and opens the editor on them."),
                Entry(term: "Recents", detail: "Workspaces you have saved or opened lately. Choosing one restores it straight away."),
                Entry(term: "Editor", detail: "Opens the editor on the workspace you had last, or an empty one."),
                Entry(term: "Open…", detail: "Choose a .snapdesk file to restore."),
                Entry(
                    term: "SnapDesk needs Accessibility",
                    detail: """
                    Shown only while SnapDesk cannot move windows. Click it to open the right pane \
                    of System Settings. When permission is working the row reads \
                    "SnapDesk can move windows" and does nothing.
                    """
                ),
                Entry(
                    term: "Relaunch",
                    detail: """
                    Quits SnapDesk and starts it again. macOS only applies a new Accessibility \
                    grant to a fresh process, so this is how a grant you have just given takes \
                    effect.
                    """
                ),
            ]),

            Topic(title: shortcutsTitle, entries: [
                Entry(term: "Capture", detail: shortcut(.capture)),
                Entry(term: "Editor", detail: shortcut(.editor)),
                Entry(
                    term: "Workspace shortcuts",
                    detail: """
                    Five more keys you can bind, each to a workspace of your choosing, so a desk \
                    comes back without opening a menu. They start unbound: pick the keys and the \
                    workspace in Settings…. A key whose workspace has since been deleted says so \
                    rather than doing nothing.
                    """
                ),
                Entry(
                    term: "Changing them",
                    detail: """
                    Settings… lets you record a different combination. The shortcuts work while any \
                    app is frontmost. If one does nothing, another app has probably claimed the \
                    same keys — macOS gives them to whoever asked first, without telling anybody.
                    """
                ),
            ]),

            Topic(title: "The editor", entries: [
                Entry(term: "Name", detail: "What the workspace is called in Recents and in the window title."),
                Entry(
                    term: "Window rows",
                    detail: """
                    One row per window. You can edit the title SnapDesk matches on, the display, \
                    the position and size, whether it is minimized, zoomed or fullscreen, the \
                    document it had open, and command-line arguments to pass when the app is \
                    launched.
                    """
                ),
                Entry(
                    term: "Document or URL",
                    detail: """
                    The page or file the window had open. SnapDesk fills this in when the app tells \
                    it — browsers, Terminal and TextEdit do; Safari and Finder do not — and \
                    restoring opens it, which is what brings back a second and third window that \
                    the app would not have reopened on its own. It also means restoring the same \
                    workspace twice opens the same page twice: nothing checks whether the window \
                    is already there. Clear the field to restore the window without it.
                    """
                ),
                Entry(
                    term: "Fullscreen",
                    detail: """
                    Not the same thing as Zoomed. Zoomed fills the screen; fullscreen hides the \
                    menu bar and gives the window a Space of its own. macOS decides which Space \
                    that is, and SnapDesk cannot ask for a particular one. Some windows have no \
                    fullscreen state at all — a fixed-size one refuses it — and those come back \
                    on their saved frame instead.
                    """
                ),
                Entry(term: "Remove", detail: "Drops a window from the workspace. The real window is untouched."),
                Entry(
                    term: "Capture, in the editor",
                    detail: """
                    Re-reads the desk and merges it into the workspace you are editing, keeping the \
                    arguments you set for windows it recognises.
                    """
                ),
                Entry(term: "Launch", detail: "Restores the workspace as it stands, without saving first."),
                Entry(
                    term: "Move existing windows",
                    detail: """
                    On, SnapDesk moves windows an app already has open. Off, it asks the app for a \
                    new instance and leaves your existing windows alone — though many apps ignore \
                    that request and simply activate the copy already running.
                    """
                ),
            ]),

            Topic(title: "Settings", entries: [
                Entry(
                    term: "Launch at login",
                    detail: """
                    Adds SnapDesk to your login items. macOS may ask you to approve it, and you can \
                    remove it again in System Settings without SnapDesk running — which is why this \
                    reads the system's answer rather than remembering its own.
                    """
                ),
                Entry(
                    term: "Restore when SnapDesk starts",
                    detail: """
                    Picks one workspace to come back every time the app starts. Deliberately not \
                    "at login": SnapDesk cannot tell a login launch from any other, so it does what \
                    the label says instead of guessing. A workspace you opened by double-clicking \
                    goes first, and this one follows.
                    """
                ),
            ]),

            Topic(title: "Workspace files", entries: [
                Entry(
                    term: "Plain JSON",
                    detail: """
                    A .snapdesk file is readable text. You can keep it in a project folder or in \
                    version control, and open it in any editor to see exactly what was saved.
                    """
                ),
                Entry(
                    term: "Frames are relative",
                    detail: """
                    Each window is stored against its display's visible area rather than in absolute \
                    screen coordinates, so a workspace captured on a large display still lands \
                    sensibly on a smaller one.
                    """
                ),
                Entry(
                    term: "Moving them",
                    detail: """
                    Renaming or moving a file is fine — Recents follows it. Double-clicking one \
                    restores it whether or not SnapDesk is already running.
                    """
                ),
            ]),

            Topic(title: troubleshootingTitle, entries: [
                Entry(
                    term: "Nothing happens at all",
                    detail: """
                    Almost always Accessibility. The menu's top section says whether SnapDesk can \
                    move windows; if it cannot, grant it and then choose Relaunch. A grant does not \
                    apply to a copy of the app that was already running when you gave it.
                    """
                ),
                Entry(
                    term: SlotFailure.appNotFound.displayText,
                    detail: """
                    The app is not where it was when you captured — moved, renamed or uninstalled. \
                    Open the workspace in the editor and either remove that row or capture again.
                    """
                ),
                Entry(
                    term: SlotFailure.launchFailed.displayText,
                    detail: "macOS refused to open the app. Check that it opens normally from Finder."
                ),
                Entry(
                    term: SlotFailure.documentFailed.displayText,
                    detail: """
                    The app opened, but the page or file the window had is no longer there — a file \
                    that has moved or been renamed, or an address the app would not take. The app \
                    itself is fine; clear the Document field on that row to restore the window \
                    without it.
                    """
                ),
                Entry(
                    term: SlotFailure.launchTimedOut.displayText,
                    detail: """
                    The app took more than ten seconds to open, so SnapDesk stopped waiting rather \
                    than hold up the rest of the restore. Try again once it has started.
                    """
                ),
                Entry(
                    term: SlotFailure.noWindow.displayText,
                    detail: """
                    The app opened but never showed a window this workspace could use. Apps often \
                    open fewer windows from cold than you had when you captured. Opening the app \
                    yourself first and restoring again usually works.
                    """
                ),
                Entry(
                    term: SlotFailure.noNewWindow.displayText,
                    detail: """
                    You asked for fresh windows — "Move existing windows" is off — and the app only \
                    ever uses the copy already running, so there was no new window to place. Your \
                    own windows were deliberately left alone. Turn "Move existing windows" on for \
                    that workspace, or quit the app before restoring.
                    """
                ),
                Entry(
                    term: SlotFailure.noDisplay.displayText,
                    detail: """
                    macOS reported no display to place onto, which normally means the lid is closed \
                    with no external screen connected.
                    """
                ),
                Entry(
                    term: SlotFailure.windowsUnreadable.displayText,
                    detail: """
                    The app never answered when asked what windows it had. It may be busy or \
                    unresponsive. Try again once it settles; if it keeps happening, check that \
                    SnapDesk still has Accessibility access.
                    """
                ),
                Entry(
                    term: SlotFailure.windowGone.displayText,
                    detail: """
                    The window closed, or its title changed, between SnapDesk finding it and \
                    placing it. Browsers retitle windows as pages load, which is the usual cause.
                    """
                ),
                Entry(
                    term: SlotFailure.couldNotPosition.displayText,
                    detail: """
                    The window refused to move or resize. Some windows are a fixed size, and some \
                    apps refuse while a sheet or dialog is open in front of them.
                    """
                ),
                Entry(
                    term: SlotFailure.stateNotRestored.displayText,
                    detail: """
                    The window is on its saved frame, but would not take the zoom or minimize you \
                    saved. Windows with no zoom button report this.
                    """
                ),
                Entry(
                    term: "Placed (other window)",
                    detail: """
                    The slot was given a window it is not named after, because the window it wanted \
                    had not appeared. This usually means a title changed since you captured. Open \
                    the workspace in the editor and capture again to record the new titles.
                    """
                ),
                Entry(
                    term: "The panel stays on screen",
                    detail: """
                    A restore that goes cleanly disappears by itself. One that lost a window, or \
                    settled for a different one, stays up and beeps once, so a problem is never \
                    mistaken for success. Dismiss closes it.
                    """
                ),
            ]),
        ]
    }
}
