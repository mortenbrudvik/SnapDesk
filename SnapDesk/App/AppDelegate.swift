import AppKit

@MainActor
protocol WorkspaceLaunching: AnyObject {
    func launch(url: URL)
    func launch(document: WorkspaceDocument)
}

@MainActor
protocol WorkspaceCapturing: AnyObject {
    func captureToEditor()
}

/// One alert: `title` says what SnapDesk could not do, `detail` names the file and the reason
/// when there is one. A message without either sent the user guessing which of the three files
/// they had just double-clicked was the broken one.
@MainActor
protocol UserAlerting: AnyObject {
    func show(title: String, detail: String?)
}

/// The restore engine as `AppDelegate` drives it. `LaunchService` is the real one; the seam is what
/// lets the launch chain, the queue and the HUD wiring be exercised against a restore that can be
/// held open and released from a test.
@MainActor
protocol WorkspaceRestoring: AnyObject {
    func launch(
        _ workspace: ValidatedWorkspace,
        onProgress: @MainActor @escaping ([SlotProgress]) -> Void
    ) async -> [SlotProgress]
    func cancel()
}

extension LaunchService: WorkspaceRestoring {}

@MainActor
protocol LaunchHUDPresenting: AnyObject {
    var onCancel: (() -> Void)? { get set }
    func present(title: String)
    func update(_ slots: [SlotProgress])
}

extension LaunchHUDController: LaunchHUDPresenting {}

@MainActor
struct WorkspaceOpener {
    func open(url: URL, launching: any WorkspaceLaunching, alerting: any UserAlerting) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            alerting.show(title: Self.openFailureTitle(for: url), detail: Self.missingFileDetail)
            return
        }
        do {
            _ = try WorkspaceDocument.load(from: url)
            launching.launch(url: url)
        } catch let error as WorkspaceDocumentError {
            alerting.show(title: Self.openFailureTitle(for: url), detail: Self.detail(for: error))
        } catch {
            alerting.show(title: Self.openFailureTitle(for: url), detail: error.localizedDescription)
        }
    }

    static func openFailureTitle(for url: URL) -> String {
        "Could not open “\(url.lastPathComponent)”"
    }

    static let missingFileDetail = "The file could not be found. It may have been moved, renamed, or deleted."

    /// Defers to the error's own text so an older-format file is never described as a newer one,
    /// and so a permission failure is not reported as a parse failure.
    static func message(for error: WorkspaceDocumentError) -> String {
        error.message
    }

    /// The message, and under it whatever the error knows about the cause — what the file system
    /// said, or which key the decoder tripped on — because "Could not read this workspace" alone
    /// is the same alert for a permission error, a hand-edited typo and a truncated file.
    static func detail(for error: WorkspaceDocumentError) -> String {
        guard let cause = error.detail else { return error.message }
        return "\(error.message)\n\n\(cause)"
    }

    /// Why a document cannot be restored, in the words the alert shows.
    struct Rejection: Error, Equatable {
        let message: String
    }

    /// The check the editor's in-memory restore needs. `open(url:...)` gets it for free from
    /// `WorkspaceDocument.load`, but a document held in the editor has no file in between — so
    /// without this a negative size would reach `AXWindow` unchecked, which is what `validate()`
    /// exists to stop. `LaunchService` accepts only the `ValidatedWorkspace` this produces.
    static func validated(_ document: WorkspaceDocument) -> Result<ValidatedWorkspace, Rejection> {
        do {
            return .success(try document.validated())
        } catch let error as WorkspaceDocumentError {
            return .failure(Rejection(message: message(for: error)))
        } catch {
            return .failure(Rejection(message: "This workspace cannot be used."))
        }
    }
}

/// Numbers restores so a Cancel click can reach the ones queued behind the running one. A queued
/// restore has not called `LaunchService.launch` yet — it is parked on the previous restore's task
/// — so the service's own cancel cannot see it, and without this it starts anyway moments after
/// the user stopped the restore it was waiting for.
struct LaunchQueue {
    private var generation = 0

    /// The ticket a restore starting now should carry.
    var ticket: Int { generation }

    /// Abandons every restore queued at this moment, and only those: a restore the user starts
    /// after the click takes a fresh ticket.
    mutating func cancelQueued() {
        generation += 1
    }

    func isStillWanted(_ ticket: Int) -> Bool {
        ticket == generation
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WorkspaceLaunching, WorkspaceCapturing, UserAlerting {
    /// Everything the delegate talks to that a test cannot let it talk to for real: the shipping
    /// defaults, Accessibility, a restore that moves windows, and modal alerts.
    @MainActor
    struct Dependencies {
        var recents: RecentsStore
        var workspaceShortcuts: WorkspaceShortcuts
        /// When each workspace was last restored. Kept out of the document on purpose; see
        /// `WorkspaceLibrary`.
        var library: WorkspaceLibrary
        /// The workspace to restore when SnapDesk starts, if the user has chosen one.
        ///
        /// Deliberately "when SnapDesk starts" rather than "at login": the app cannot reliably
        /// tell a login launch from any other, and a setting that means exactly what it says is
        /// better than one that guesses and is wrong some of the time.
        var startupWorkspace: @MainActor () -> URL?
        var capture: @MainActor () -> CaptureOutcome
        var restorer: any WorkspaceRestoring
        var hud: any LaunchHUDPresenting
        var accessibilityTrusted: @MainActor () -> Bool
        /// Answers a command refused for want of Accessibility. Names the command, so the log
        /// line and the explanation the user gets both say what was refused.
        var refuseUntrusted: @MainActor (String) -> Void
        var presentAlert: @MainActor (_ title: String, _ detail: String?) -> Void

        static var production: Dependencies {
            let captureService = CaptureService()
            return Dependencies(
                recents: RecentsStore(),
                workspaceShortcuts: WorkspaceShortcuts(),
                library: WorkspaceLibrary(),
                startupWorkspace: { AppSettings.shared.startupWorkspace },
                capture: { captureService.capture() },
                restorer: LaunchService(),
                hud: LaunchHUDController(),
                accessibilityTrusted: { AccessibilityAuth.isEffectivelyTrusted },
                refuseUntrusted: { command in
                    // The beep stays: it is the immediate answer to the keystroke, ahead of the
                    // alert that explains why.
                    NSSound.beep()
                    AccessibilityAuth.requestIfNeeded(for: command)
                },
                presentAlert: { title, detail in
                    let alert = NSAlert()
                    alert.messageText = title
                    if let detail {
                        alert.informativeText = detail
                    }
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            )
        }
    }

    private let dependencies: Dependencies
    private var recents: RecentsStore { dependencies.recents }
    private var statusItem: StatusItemController?
    private var hotkeys: HotkeyCenter?

    /// Capture passes what it captured; Editor passes nil.
    var editorOpener: (CaptureOutcome?) -> Void = { _ in }
    var settingsOpener: () -> Void = {}
    var helpOpener: () -> Void = {}
    private var editorWindow: EditorWindowController?
    private var settingsWindow: SettingsWindowController?
    private var helpWindow: HelpWindowController?
    /// The task the most recently started restore runs in; awaiting it awaits every restore
    /// chained before it too.
    private(set) var launchChain: Task<Void, Never>?
    private var launchQueue = LaunchQueue()

    /// Files handed over before launch has finished. AppKit delivers the open-documents event for
    /// a double-clicked file *inside* `finishLaunching`, before `applicationDidFinishLaunching`,
    /// so an alert raised straight from it — an ungranted first run, say — would sit on screen with
    /// no status item and no hot keys behind it, in an app that has no Dock icon to quit from.
    private var pendingOpens: [URL] = []
    private var isLaunchComplete = false

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        super.init()
        dependencies.hud.onCancel = { [weak self] in
            guard let self else { return }
            self.dependencies.restorer.cancel()
            self.launchQueue.cancelQueued()
        }
        editorOpener = { [weak self] outcome in
            self?.openEditor(captured: outcome)
        }
        settingsOpener = { [weak self] in
            self?.openSettings()
        }
        helpOpener = { [weak self] in
            self?.openHelp()
        }
    }

    override convenience init() {
        self.init(dependencies: .production)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        AXWindow.installMessagingTimeout()
        AccessibilityAuth.promptAtLaunchIfNeeded()
        statusItem = StatusItemController(
            recents: recents,
            launching: self,
            capturing: self,
            alerting: self,
            onEditor: { [weak self] in self?.editorOpener(nil) },
            onSettings: { [weak self] in self?.settingsOpener() },
            onHelp: { [weak self] in self?.helpOpener() }
        )
        hotkeys = HotkeyCenter(
            capturing: self,
            onEditor: { [weak self] in self?.editorOpener(nil) },
            onWorkspace: { [weak self] slot in self?.launchWorkspace(inSlot: slot) }
        )
        hotkeys?.start()
        Log.app.info("launched: trusted=\(AccessibilityAuth.isTrusted) effective=\(AccessibilityAuth.isEffectivelyTrusted)")
        completeLaunch()
    }

    /// Marks the app as wired and opens whatever arrived before it was. Called from
    /// `applicationDidFinishLaunching`, which under XCTest returns before doing anything.
    func completeLaunch() {
        isLaunchComplete = true
        let urls = pendingOpens
        pendingOpens = []
        for url in urls {
            open(url)
        }
        // After the buffer, never before it: a file the user double-clicked is why the app is
        // launching at all, so it goes first and the startup workspace queues behind it. Both go
        // through `open`, so a startup workspace that has been deleted says so.
        if let startup = dependencies.startupWorkspace() {
            open(startup)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard isLaunchComplete else {
            pendingOpens.append(contentsOf: urls)
            return
        }
        for url in urls {
            open(url)
        }
    }

    private func open(_ url: URL) {
        WorkspaceOpener().open(url: url, launching: self, alerting: self)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if editorWindow?.prepareForTermination() == false {
            return .terminateCancel
        }
        // Last, once every veto has had its turn: the relaunch helper must only exist for a quit
        // that is actually going ahead.
        guard AccessibilityAuth.armRelaunchHelperIfPending() else {
            return .terminateCancel
        }
        return .terminateNow
    }

    /// Opens the workspace bound to a hotkey slot.
    ///
    /// Goes through `launch(url:)` rather than repeating any of it, so a workspace opened by a
    /// key gets the same trust check, the same validation, the same recents entry and the same
    /// "could not be found" alert as one opened from Finder.
    func launchWorkspace(inSlot slot: Int) {
        guard let url = dependencies.workspaceShortcuts.workspace(for: slot) else {
            // Not an error: a key can be bound before a workspace is assigned to it.
            Log.hotkeys.notice("workspace slot \(slot) has no workspace assigned")
            return
        }
        launch(url: url)
    }

    func launch(url: URL) {
        guard dependencies.accessibilityTrusted() else {
            dependencies.refuseUntrusted("restore")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            show(title: WorkspaceOpener.openFailureTitle(for: url), detail: WorkspaceOpener.missingFileDetail)
            return
        }
        do {
            let workspace = try WorkspaceDocument.load(from: url).validated()
            recents.add(url)
            // After the load, so a workspace that could not be opened is not recorded as having
            // been restored — the library would otherwise sort a broken file to the top.
            dependencies.library.recordLaunch(of: url)
            startLaunch(workspace)
        } catch let error as WorkspaceDocumentError {
            show(title: WorkspaceOpener.openFailureTitle(for: url), detail: WorkspaceOpener.detail(for: error))
        } catch {
            show(title: WorkspaceOpener.openFailureTitle(for: url), detail: error.localizedDescription)
        }
    }

    /// The editor's in-memory restore. `launch(url:)` needs no check of its own because it goes
    /// through `WorkspaceDocument.load`, which validates; this path has no file in between, so
    /// without this a negative size or a window naming a display the document does not describe
    /// would reach `AXWindow` directly — which is the hazard `validate()` exists for.
    func launch(document: WorkspaceDocument) {
        guard dependencies.accessibilityTrusted() else {
            dependencies.refuseUntrusted("restore")
            return
        }
        switch WorkspaceOpener.validated(document) {
        case .failure(let rejection):
            show(title: "Cannot restore “\(document.name)”", detail: rejection.message)
        case .success(let workspace):
            startLaunch(workspace)
        }
    }

    func captureToEditor() {
        // Asked before the capture, not after: a capture is a synchronous Accessibility sweep of
        // every running app on the main thread, and the editor is going to refuse this anyway
        // while one of its own modals is up — inside whose run loop the hotkey fired.
        if let editorWindow, editorWindow.isPresentingPrompt {
            editorWindow.refuseCommandWhilePrompting("capture")
            return
        }
        guard dependencies.accessibilityTrusted() else {
            dependencies.refuseUntrusted("capture")
            return
        }
        editorOpener(dependencies.capture())
    }

    func show(title: String, detail: String?) {
        dependencies.presentAlert(title, detail)
    }

    /// Chains restores rather than relying on `LaunchService`'s own gate: the HUD reset in
    /// `present(title:)` happens outside that gate, so without the chain a second restore would
    /// wipe the first one's rows while it was still running.
    private func startLaunch(_ workspace: ValidatedWorkspace) {
        let document = workspace.document
        // A workspace with no slots has nothing to restore, and a HUD that opens with no rows
        // and dismisses itself 600ms later reads as a glitch. Say so instead.
        guard !document.windows.isEmpty else {
            show(
                title: "“\(document.name)” has no windows to restore",
                detail: "Capture a workspace first, or add windows to this one in the editor."
            )
            return
        }
        let previous = launchChain
        let ticket = launchQueue.ticket
        launchChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            // A Cancel click while this restore was still waiting its turn was aimed at the queue
            // as a whole; starting now would re-open the HUD the user had just stopped.
            guard self.launchQueue.isStillWanted(ticket) else { return }
            self.dependencies.hud.present(title: document.name)
            let result = await self.dependencies.restorer.launch(workspace) { [weak self] progress in
                self?.dependencies.hud.update(progress)
            }
            Log.launch.info("\(Self.summary(of: result, workspace: document.name), privacy: .public)")
        }
    }

    /// One log line describing how a restore ended. The HUD is transient and the per-slot failures
    /// are only reported to it, so without this a restore that half-failed leaves nothing behind
    /// to diagnose.
    static func summary(of slots: [SlotProgress], workspace: String) -> String {
        let failures = slots.compactMap { slot in
            slot.status.failure.map { "\(slot.name): \($0.displayText)" }
        }
        let placed = slots.filter(\.status.isPlaced).count
        let cancelled = slots.filter { $0.status == .cancelled }.count
        var outcomes: [String] = []
        if !failures.isEmpty {
            outcomes.append("failed [\(failures.joined(separator: "; "))]")
        }
        // A slot can be placed and still not be what the user saved: the HUD says so while it is
        // up, and this is what is left afterwards — which is when someone comes back to ask why
        // the layout looks wrong.
        let guessed = slots.filter { slot in
            if case .placed(let note) = slot.status { return note.isGuess }
            return false
        }
        if !guessed.isEmpty {
            outcomes.append("\(guessed.count) on another window [\(guessed.map(\.name).joined(separator: "; "))]")
        }
        let substituted = slots.compactMap { slot -> String? in
            guard case .placed(let note) = slot.status, let display = note.substituteDisplay else { return nil }
            return "\(slot.name): \(display)"
        }
        if !substituted.isEmpty {
            outcomes.append("\(substituted.count) on another display [\(substituted.joined(separator: "; "))]")
        }
        // Counted separately and never named a failure: the user stopped these on purpose, and a
        // log that calls a deliberate cancel a failure sends the next reader hunting for a bug.
        if cancelled > 0 {
            outcomes.append("cancelled \(cancelled) slot(s)")
        }
        guard !outcomes.isEmpty else {
            return "restored \"\(workspace)\": \(placed) slot(s) placed"
        }
        return """
            restored "\(workspace)": \(placed) of \(slots.count) slot(s) placed, \
            \(outcomes.joined(separator: ", "))
            """
    }

    private func openEditor(captured: CaptureOutcome?) {
        if editorWindow == nil {
            editorWindow = EditorWindowController(
                recents: recents,
                library: dependencies.library,
                capture: { [weak self] in
                    guard let self else { return nil }
                    guard self.dependencies.accessibilityTrusted() else {
                        self.dependencies.refuseUntrusted("capture")
                        return nil
                    }
                    return self.dependencies.capture()
                },
                launch: { [weak self] document in
                    self?.launch(document: document)
                },
                launchFile: { [weak self] url in
                    self?.launch(url: url)
                }
            )
        }
        if let captured {
            editorWindow?.open(capture: captured)
        } else {
            editorWindow?.open(captured: nil)
        }
    }

    private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(shortcuts: dependencies.workspaceShortcuts)
        }
        settingsWindow?.showWindow(nil)
    }

    private func openHelp() {
        if helpWindow == nil {
            helpWindow = HelpWindowController()
        }
        helpWindow?.showWindow(nil)
    }
}
