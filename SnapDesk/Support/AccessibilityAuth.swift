import ApplicationServices
import AppKit

/// Accessibility permission: checking it, asking for it, and walking the user through the
/// relaunch macOS requires before a new grant takes effect.
@MainActor
enum AccessibilityAuth {
    private static var didShowSystemPrompt = false
    private static var didShowRelaunchAlert = false
    /// An explanation is on screen; see `runAlert`.
    private static var isExplaining = false

    /// What TCC says. Can be true while AX calls still fail; see `isEffectivelyTrusted`.
    static var isTrusted: Bool {
        AXIsProcessTrustedWithOptions([promptOption: false] as CFDictionary)
    }

    /// Whether an actual Accessibility call succeeds. After a grant, or after a rebuild that
    /// changed the code signature, `isTrusted` can say yes while every call answers
    /// `.apiDisabled` until the app relaunches. This is what the Settings pane reports.
    ///
    /// The probe must target *another application's* element. Two ways to get this wrong:
    /// the system-wide element answers `.cannotComplete` when the process is untrusted and
    /// never `.apiDisabled`, so a probe against it reports every process as working; and a
    /// process may always read its own hierarchy, trusted or not, so probing ourselves would
    /// answer yes just as uselessly. Only a cross-application read tells the states apart.
    static var isEffectivelyTrusted: Bool {
        // No other app to ask (no window server, a bare test rig): fall back to what TCC says
        // rather than inventing an answer.
        guard let pid = probeTarget else { return isTrusted }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &value
        )
        // Anything but `.apiDisabled` means the call was allowed through: the app having no
        // focused window, or not answering, is not a permission problem.
        return error != .apiDisabled
    }

    /// A regular app that is not SnapDesk, to aim the trust probe at.
    private static var probeTarget: pid_t? {
        NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isTerminated
        }?.processIdentifier
    }

    /// The value of `kAXTrustedCheckOptionPrompt`. The constant itself is imported as a global
    /// `var`, which Swift 6 strict concurrency rejects as shared mutable state.
    private static let promptOption = "AXTrustedCheckOptionPrompt"

    /// What the user actually has to do. `isTrusted` and `isEffectivelyTrusted` disagree
    /// exactly when TCC holds a grant that a stale code signature keeps from applying, and
    /// those two states need opposite instructions — so the choice is a value rather than a
    /// chain of `if`s buried in the presentation code.
    enum Remedy: Equatable {
        /// Accessibility calls go through; there is nothing to ask for.
        case none
        /// TCC has no grant for this signature: the user has to add and enable SnapDesk.
        case grant
        /// TCC granted it but calls still fail: only a fresh process picks the grant up.
        case relaunch
    }

    static func remedy(isTrusted: Bool, isEffectivelyTrusted: Bool) -> Remedy {
        if isEffectivelyTrusted { return .none }
        return isTrusted ? .relaunch : .grant
    }

    static var currentRemedy: Remedy {
        remedy(isTrusted: isTrusted, isEffectivelyTrusted: isEffectivelyTrusted)
    }

    /// On launch, if Accessibility is not *effectively* working, show the system dialog when
    /// TCC has not granted it and the remove/add/Relaunch alert when it has — never both. A
    /// user who has never granted anything cannot follow a script whose first step is removing
    /// an entry that is not there, and the system dialog already says what they need. Each
    /// dialog appears at most once per launch.
    static func promptAtLaunchIfNeeded() {
        switch currentRemedy {
        case .none:
            break
        case .grant:
            showSystemPromptOnce()
        case .relaunch:
            guard !didShowRelaunchAlert else { return }
            didShowRelaunchAlert = true
            // `runModal` would block the rest of the caller's launch work — the status item and
            // the hot keys — leaving an LSUIElement app showing a dialog with no menu bar icon
            // behind it and no way to quit. Hand it back to the run loop so wiring finishes.
            Task { showRelaunchAlert() }
        }
    }

    /// Guards the command path. This answers something the user just did, so unlike the
    /// launch-time prompt it always logs and always puts the explanation back on screen: a
    /// command that dies with a beep is indistinguishable from a broken app. Only the macOS
    /// TCC dialog stays once per launch, because the system ignores repeat requests anyway.
    static func requestIfNeeded(for command: String = "command") {
        let remedy = currentRemedy
        Log.app.error("\(command, privacy: .public) refused: accessibility remedy is \(String(describing: remedy), privacy: .public)")
        switch remedy {
        case .none:
            break
        case .grant:
            showSystemPromptOnce()
            showGrantAlert()
        case .relaunch:
            didShowRelaunchAlert = true
            showRelaunchAlert()
        }
    }

    private static func showSystemPromptOnce() {
        guard !didShowSystemPrompt else { return }
        didShowSystemPrompt = true
        _ = AXIsProcessTrustedWithOptions([promptOption: true] as CFDictionary)
    }

    /// The never-granted script: no "remove the existing entry" step, because there is nothing
    /// to remove yet, and no Relaunch button, because there is no grant waiting to be applied.
    static func showGrantAlert() {
        let choice = runAlert(
            message: "SnapDesk needs Accessibility",
            informative: """
            macOS only lets SnapDesk move other apps' windows once you allow it.

            1. System Settings → Privacy & Security → Accessibility
            2. Click + and choose /Applications/SnapDesk.app
            3. Turn it on
            4. Quit and reopen SnapDesk

            macOS does not apply this permission until SnapDesk restarts.
            """,
            buttons: ["Open Settings", "Cancel"]
        )
        if choice == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }

    /// Why "remove, then add again": TCC ties the grant to the code signature. An ad-hoc-signed
    /// build (`CODE_SIGN_IDENTITY=-`) has no identity beyond its cdhash, so each rebuild is a new
    /// one and the old row shows as on but does not apply; re-adding re-keys it. A build signed
    /// with a certificate — which is what `project.yml` does for Debug as well as Release — keeps
    /// a stable identity, so those users normally only need steps 3 to 5.
    static func showRelaunchAlert() {
        let choice = runAlert(
            message: "SnapDesk needs Accessibility",
            informative: """
            1. System Settings → Privacy & Security → Accessibility
            2. If SnapDesk is listed, select it and click − to remove it
            3. Click + and choose /Applications/SnapDesk.app
            4. Turn it on
            5. Click Relaunch here

            macOS does not apply this permission until SnapDesk restarts.
            """,
            buttons: ["Relaunch", "Open Settings", "Cancel"]
        )
        switch choice {
        case .alertFirstButtonReturn:
            relaunch()
        case .alertSecondButtonReturn:
            openSystemSettings()
        default:
            break
        }
    }

    /// Every alert goes through here, so none of them can forget to activate first — SnapDesk is
    /// an LSUIElement app, so an unactivated modal can open behind whatever the user is looking
    /// at, and the instructions they need are then invisible — and none of them can stack on
    /// another: global hot keys keep firing while `runModal` spins the run loop, so a held-down
    /// shortcut would otherwise pile up one alert per key repeat. A refused alert reads as a
    /// cancel, which every caller already treats as "do nothing".
    @discardableResult
    private static func runAlert(
        message: String,
        informative: String,
        buttons: [String]
    ) -> NSApplication.ModalResponse {
        guard !isExplaining else { return .cancel }
        isExplaining = true
        defer { isExplaining = false }
        return alertPresenter(message, informative, buttons)
    }

    /// Puts one alert on screen and returns the button. Replaceable so the paths that end in an
    /// explanation — a vetoed relaunch, above all — can be exercised without a modal.
    static var alertPresenter: (_ message: String, _ informative: String, _ buttons: [String]) -> NSApplication.ModalResponse = { message, informative, buttons in
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        for title in buttons {
            alert.addButton(withTitle: title)
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    /// Set between asking to quit and the quit being granted; see `armRelaunchHelperIfPending`.
    private(set) static var relaunchPending = false

    /// How the helper is started. One seam for both paths, so a test can prove that `relaunch()`
    /// starts *nothing* — the whole point of deferring it — rather than only that the path it was
    /// handed went unused.
    static var helperLauncher: @MainActor (String, pid_t) throws -> Void = launchHelper

    /// Starts the shell helper that waits for this process to exit and reopens the bundle.
    static func launchHelper(bundlePath: String, pid: pid_t) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", reopenScript, bundlePath, String(pid)]
        try process.run()
    }

    /// Quits and starts a fresh process, which is what makes a new Accessibility grant apply.
    ///
    /// The helper is *not* started here. It waits for this pid to exit and then reopens the
    /// bundle, so started before the quit was granted it stayed armed for ten seconds after a
    /// vetoed quit — an unsaved editor, Cancel — and a real ⌘Q inside that window brought SnapDesk
    /// straight back. `AppDelegate.applicationShouldTerminate` starts it instead, through
    /// `armRelaunchHelperIfPending`, once the quit is known to be going ahead.
    static func relaunch(terminate: @MainActor () -> Void = { NSApp.terminate(nil) }) {
        relaunchPending = true
        terminate()

        // terminate(nil) returns instead of exiting when the quit is vetoed — an editor with
        // unsaved changes answers `.terminateCancel` — or when the helper could not be started,
        // which `armRelaunchHelperIfPending` has already explained. The first case is the one
        // the user has not heard about: say so, or they are left believing SnapDesk restarted
        // and that the permission is now in effect.
        guard relaunchPending else { return }
        relaunchPending = false
        Log.app.error("relaunch cancelled: termination was vetoed")
        runAlert(
            message: "SnapDesk did not relaunch",
            informative: "Something is keeping SnapDesk open. Save or close the editor window, then quit SnapDesk and open it again.",
            buttons: ["OK"]
        )
    }

    /// Called from `applicationShouldTerminate` once every veto has had its turn. Starts the helper
    /// if a relaunch asked for the quit, and answers whether the quit may go ahead: a helper that
    /// cannot be started is the one failure that has to stop it, because the app would otherwise
    /// vanish and not come back, which reads as a crash. An ordinary quit is untouched.
    static func armRelaunchHelperIfPending() -> Bool {
        guard relaunchPending else { return true }
        relaunchPending = false
        do {
            try helperLauncher(Bundle.main.bundlePath, getpid())
            return true
        } catch {
            Log.app.error("relaunch helper failed to start: \(error.localizedDescription, privacy: .public)")
            runAlert(
                message: "SnapDesk could not relaunch itself",
                informative: "Quit SnapDesk and open it again from Applications.\n\n\(error.localizedDescription)",
                buttons: ["OK"]
            )
            return false
        }
    }

    /// `open` on a bundle that is still running only activates the running instance, so the
    /// helper waits for this process to actually go away before asking LaunchServices for a new
    /// one — and gives up after ten seconds if it never does. It is only ever started once the
    /// quit has been granted (see `armRelaunchHelperIfPending`), so that ceiling is a backstop
    /// and not a window in which a later ⌘Q would relaunch the app. The bundle path ($0) and pid
    /// ($1) are passed as arguments, never spliced into the script, so quotes or spaces in the
    /// path cannot break the command.
    private static let reopenScript = """
    i=0
    while [ "$i" -lt 100 ]; do
        /bin/kill -0 "$1" 2>/dev/null || exec /usr/bin/open "$0"
        sleep 0.1
        i=$((i + 1))
    done
    """

    static func openSystemSettings() {
        // Deep links, tried in order:
        //   1. macOS 13+ System Settings, straight to the Accessibility pane
        //   2. the pre-Ventura System Preferences anchor, which System Settings still maps
        //   3. the Privacy & Security root, if the pane query is rejected
        // Last resort: the app with no pane selected.
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        ]
        for spec in candidates {
            if let url = URL(string: spec), NSWorkspace.shared.open(url) {
                return
            }
        }
        if !NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) {
            Log.app.error("could not open System Settings")
        }
    }
}
