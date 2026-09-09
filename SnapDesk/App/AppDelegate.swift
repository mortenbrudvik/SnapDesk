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

    static func message(for error: WorkspaceDocumentError) -> String {
        switch error {
        case .unsupportedVersion:
            return "This workspace was saved with a newer SnapDesk"
        case .corrupt:
            return "Could not read this workspace."
        }
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
            self?.launchService.cancel()
        }
        return hud
    }()

    /// Capture passes a new unsaved document; Editor passes nil.
    var editorOpener: (WorkspaceDocument?) -> Void = { _ in }
    var hudPresenter: @MainActor @Sendable ([SlotProgress]) -> Void = { _ in }
    var settingsOpener: () -> Void = {}

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

    func launch(url: URL) {
        guard AccessibilityAuth.isEffectivelyTrusted else {
            refuseUntrusted()
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

    func launch(document: WorkspaceDocument) {
        guard AccessibilityAuth.isEffectivelyTrusted else {
            refuseUntrusted()
            return
        }
        startLaunch(document)
    }

    func captureToEditor() {
        guard AccessibilityAuth.isEffectivelyTrusted else {
            refuseUntrusted()
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

    private func startLaunch(_ document: WorkspaceDocument) {
        launchHUD.present(title: document.name)
        Task { [weak self] in
            guard let self else { return }
            _ = await self.launchService.launch(document) { [weak self] progress in
                self?.launchHUD.update(progress)
                self?.hudPresenter(progress)
            }
        }
    }

    private func refuseUntrusted() {
        NSSound.beep()
        AccessibilityAuth.requestIfNeeded()
    }
}
