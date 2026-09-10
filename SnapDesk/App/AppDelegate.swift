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

@MainActor
protocol UserAlerting: AnyObject {
    func show(message: String)
}

@MainActor
struct WorkspaceOpener {
    func open(url: URL, launching: any WorkspaceLaunching, alerting: any UserAlerting) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            alerting.show(message: "File not found")
            return
        }
        do {
            _ = try WorkspaceDocument.load(from: url)
            launching.launch(url: url)
        } catch let error as WorkspaceDocumentError {
            alerting.show(message: Self.message(for: error))
        } catch {
            alerting.show(message: "Could not read this workspace.")
        }
    }

    /// Defers to the error's own text so an older-format file is never described as a newer one,
    /// and so a permission failure is not reported as a parse failure.
    static func message(for error: WorkspaceDocumentError) -> String {
        error.message
    }

    /// The message to show *instead of* restoring, or nil when the document can be applied.
    ///
    /// `open(url:...)` gets this for free from `WorkspaceDocument.load`, but the editor restores a
    /// document it holds in memory, with no file in between — so that path has to run the same
    /// check itself or a negative size reaches `AXWindow` unchecked, which is what `validate()`
    /// exists to stop.
    static func rejection(of document: WorkspaceDocument) -> String? {
        do {
            try document.validate()
            return nil
        } catch let error as WorkspaceDocumentError {
            return message(for: error)
        } catch {
            return "This workspace cannot be used."
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
    private let recents = RecentsStore()
    private let captureService = CaptureService()
    private let launchService = LaunchService()
    private var statusItem: StatusItemController?
    private var hotkeys: HotkeyCenter?
    private lazy var launchHUD: LaunchHUDController = {
        let hud = LaunchHUDController()
        hud.onCancel = { [weak self] in
            guard let self else { return }
            self.launchService.cancel()
            self.launchQueue.cancelQueued()
        }
        return hud
    }()

    /// Capture passes a new unsaved document; Editor passes nil.
    var editorOpener: (WorkspaceDocument?) -> Void = { _ in }
    var hudPresenter: @MainActor @Sendable ([SlotProgress]) -> Void = { _ in }
    var settingsOpener: () -> Void = {}
    private var editorWindow: EditorWindowController?
    private var settingsWindow: SettingsWindowController?
    private var launchChain: Task<Void, Never>?
    private var launchQueue = LaunchQueue()

    override init() {
        super.init()
        editorOpener = { [weak self] document in
            self?.openEditor(captured: document)
        }
        settingsOpener = { [weak self] in
            self?.openSettings()
        }
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
            onSettings: { [weak self] in self?.settingsOpener() }
        )
        hotkeys = HotkeyCenter(
            capturing: self,
            onEditor: { [weak self] in self?.editorOpener(nil) }
        )
        hotkeys?.start()
        Log.app.info("launched: trusted=\(AccessibilityAuth.isTrusted) effective=\(AccessibilityAuth.isEffectivelyTrusted)")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            WorkspaceOpener().open(url: url, launching: self, alerting: self)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if editorWindow?.prepareForTermination() == false {
            return .terminateCancel
        }
        return .terminateNow
    }

    func launch(url: URL) {
        guard AccessibilityAuth.isEffectivelyTrusted else {
            refuseUntrusted("restore")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            show(message: "File not found")
            return
        }
        do {
            let document = try WorkspaceDocument.load(from: url)
            recents.add(url)
            startLaunch(document)
        } catch let error as WorkspaceDocumentError {
            show(message: WorkspaceOpener.message(for: error))
        } catch {
            show(message: "Could not read this workspace.")
        }
    }

    /// The editor's in-memory restore. `launch(url:)` needs no check of its own because it goes
    /// through `WorkspaceDocument.load`, which validates; this path has no file in between, so
    /// without this a negative size or a window naming a display the document does not describe
    /// would reach `AXWindow` directly — which is the hazard `validate()` exists for.
    func launch(document: WorkspaceDocument) {
        guard AccessibilityAuth.isEffectivelyTrusted else {
            refuseUntrusted("restore")
            return
        }
        if let rejection = WorkspaceOpener.rejection(of: document) {
            show(message: rejection)
            return
        }
        startLaunch(document)
    }

    func captureToEditor() {
        guard AccessibilityAuth.isEffectivelyTrusted else {
            refuseUntrusted("capture")
            return
        }
        editorOpener(captureService.capture())
    }

    func show(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Chains restores rather than relying on `LaunchService`'s own gate: the HUD reset in
    /// `present(title:)` happens outside that gate, so without the chain a second restore would
    /// wipe the first one's rows while it was still running.
    private func startLaunch(_ document: WorkspaceDocument) {
        let previous = launchChain
        let ticket = launchQueue.ticket
        launchChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            // A Cancel click while this restore was still waiting its turn was aimed at the queue
            // as a whole; starting now would re-open the HUD the user had just stopped.
            guard self.launchQueue.isStillWanted(ticket) else { return }
            self.launchHUD.present(title: document.name)
            let result = await self.launchService.launch(document) { [weak self] progress in
                self?.launchHUD.update(progress)
                self?.hudPresenter(progress)
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
        let placed = slots.filter { $0.status == .placed }.count
        let cancelled = slots.filter { $0.status == .cancelled }.count
        var outcomes: [String] = []
        if !failures.isEmpty {
            outcomes.append("failed [\(failures.joined(separator: "; "))]")
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

    /// Names the command in the log line and in the explanation the user gets. The beep stays:
    /// it is the immediate answer to the keystroke, ahead of the alert that explains why.
    private func refuseUntrusted(_ command: String) {
        NSSound.beep()
        AccessibilityAuth.requestIfNeeded(for: command)
    }

    private func openEditor(captured: WorkspaceDocument?) {
        if editorWindow == nil {
            editorWindow = EditorWindowController(
                recents: recents,
                capture: { [weak self] in
                    guard let self else { return nil }
                    guard AccessibilityAuth.isEffectivelyTrusted else {
                        self.refuseUntrusted("capture")
                        return nil
                    }
                    return self.captureService.capture()
                },
                launch: { [weak self] document in
                    self?.launch(document: document)
                }
            )
        }
        editorWindow?.open(captured: captured)
    }

    private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.showWindow(nil)
    }
}
