import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct EditorRecentItem: Identifiable, Equatable {
    var id: String
    var url: URL
    var name: String
    var filename: String
}

@MainActor
final class EditorHost: ObservableObject {
    @Published var session: EditorSession
    @Published var recents: [EditorRecentItem] = []
    @Published var selectedRecentID: String?
    @Published var selectedWindowIndex: Int?

    private var sessionCancellable: AnyCancellable?

    init(session: EditorSession) {
        self.session = session
        bindSession()
    }

    func replaceSession(_ session: EditorSession) {
        self.session = session
        selectedWindowIndex = nil
        bindSession()
    }

    private func bindSession() {
        sessionCancellable = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private let recents: RecentsStore
    private let capture: () -> WorkspaceDocument?
    private let launch: (WorkspaceDocument) -> Void
    private let host: EditorHost
    private var titleCancellable: AnyCancellable?
    private var didCenter = false

    init(
        recents: RecentsStore,
        capture: @escaping () -> WorkspaceDocument?,
        launch: @escaping (WorkspaceDocument) -> Void
    ) {
        self.recents = recents
        self.capture = capture
        self.launch = launch
        let session = EditorSession(
            document: EditorSession.untitledDocument,
            fileURL: nil,
            recents: recents
        )
        self.host = EditorHost(session: session)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Untitled"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 420)

        super.init(window: window)

        window.delegate = self
        installView()
        refreshRecents()
        observeTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func open(captured: WorkspaceDocument?) {
        if let captured {
            if window?.isVisible == true {
                host.session.applyCapture(captured)
            } else {
                guard confirmDiscardIfNeeded() else {
                    present()
                    return
                }
                replaceSession(
                    EditorSession(document: captured, fileURL: nil, recents: recents)
                )
            }
        }
        present()
    }

    override func showWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard host.session.isDirty else { return true }
        switch saveDontCancel() {
        case .save:
            return performSave()
        case .dont:
            revertAfterDiscard()
            return true
        case .cancel:
            return false
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshRecents()
    }

    private func present() {
        refreshRecents()
        updateTitle()
        if !didCenter {
            window?.center()
            didCenter = true
        }
        showWindow(nil)
    }

    private func installView() {
        window?.contentView = NSHostingView(
            rootView: EditorView(
                host: host,
                onCapture: { [weak self] in self?.recapture() },
                onOpen: { [weak self] in self?.openPanel() },
                onSelectRecent: { [weak self] url in self?.selectRecent(url) },
                onRemoveRecent: { [weak self] in self?.removeSelectedRecent() },
                onReveal: { [weak self] in self?.revealInFinder() },
                onTrash: { [weak self] in self?.moveToTrash() },
                onLaunch: { [weak self] in self?.launchCurrent() },
                onLaunchAndEdit: { [weak self] in self?.launchAndEdit() },
                onSave: { [weak self] in _ = self?.performSave() },
                onSaveAs: { [weak self] in _ = self?.saveAs() },
                onRemoveWindow: { [weak self] index in self?.removeWindow(at: index) }
            )
        )
    }

    private func replaceSession(_ session: EditorSession) {
        host.replaceSession(session)
        observeTitle()
        refreshRecents()
        updateTitle()
    }

    private func observeTitle() {
        titleCancellable = host.session.$document
            .map(\.name)
            .removeDuplicates()
            .sink { [weak self] name in
                self?.window?.title = Self.windowTitle(name)
            }
    }

    private func recapture() {
        guard let captured = capture() else { return }
        host.session.applyCapture(captured)
    }

    private func openPanel() {
        guard confirmDiscardIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType("com.brudvik.snapdesk") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(url)
    }

    private func selectRecent(_ url: URL) {
        if sameFile(url, host.session.fileURL) { return }
        guard confirmDiscardIfNeeded() else {
            syncRecentSelection()
            return
        }
        openFile(url)
    }

    private func openFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            presentMessage("File not found")
            refreshRecents()
            return
        }
        do {
            let document = try WorkspaceDocument.load(from: url)
            recents.add(url)
            replaceSession(EditorSession(document: document, fileURL: url, recents: recents))
        } catch let error as WorkspaceDocumentError {
            presentMessage(WorkspaceOpener.message(for: error))
        } catch {
            presentMessage("Could not read this workspace.")
        }
    }

    private func removeSelectedRecent() {
        guard let url = targetURL() else { return }
        recents.remove(url)
        refreshRecents()
    }

    private func revealInFinder() {
        guard let url = targetURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func moveToTrash() {
        guard let url = targetURL() else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.informativeText = "This file will also be removed from Recents."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            recents.remove(url)
            if sameFile(url, host.session.fileURL) {
                replaceSession(
                    EditorSession(
                        document: EditorSession.untitledDocument,
                        fileURL: nil,
                        recents: recents
                    )
                )
            } else {
                refreshRecents()
            }
        } catch {
            presentMessage(error.localizedDescription)
        }
    }

    private func launchCurrent() {
        launch(host.session.document)
    }

    private func launchAndEdit() {
        launch(host.session.document)
    }

    @discardableResult
    private func performSave() -> Bool {
        if host.session.fileURL != nil {
            do {
                try host.session.save()
                updateTitle()
                return true
            } catch {
                presentMessage(error.localizedDescription)
                return false
            }
        }
        return saveAs()
    }

    @discardableResult
    private func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType("com.brudvik.snapdesk") ?? .json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFileName()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try host.session.save(to: url)
            refreshRecents()
            updateTitle()
            return true
        } catch {
            presentMessage(error.localizedDescription)
            return false
        }
    }

    private func removeWindow(at index: Int) {
        host.session.removeWindow(at: index)
        if host.selectedWindowIndex == index {
            host.selectedWindowIndex = nil
        } else if let selected = host.selectedWindowIndex, selected > index {
            host.selectedWindowIndex = selected - 1
        }
    }

    private func confirmDiscardIfNeeded() -> Bool {
        guard host.session.isDirty else { return true }
        switch saveDontCancel() {
        case .save:
            return performSave()
        case .dont:
            return true
        case .cancel:
            return false
        }
    }

    private enum CloseChoice {
        case save, dont, cancel
    }

    private func saveDontCancel() -> CloseChoice {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to “\(host.session.document.name)”?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .dont
        default:
            return .cancel
        }
    }

    private func revertAfterDiscard() {
        if let url = host.session.fileURL, let document = try? WorkspaceDocument.load(from: url) {
            replaceSession(EditorSession(document: document, fileURL: url, recents: recents))
        } else {
            replaceSession(
                EditorSession(
                    document: EditorSession.untitledDocument,
                    fileURL: nil,
                    recents: recents
                )
            )
        }
    }

    private func refreshRecents() {
        host.recents = recents.urls.map { url in
            let name: String
            if FileManager.default.fileExists(atPath: url.path),
               let document = try? WorkspaceDocument.load(from: url)
            {
                name = document.name
            } else {
                name = url.deletingPathExtension().lastPathComponent
            }
            return EditorRecentItem(
                id: url.resolvingSymlinksInPath().path,
                url: url,
                name: name,
                filename: url.lastPathComponent
            )
        }
        syncRecentSelection()
    }

    private func syncRecentSelection() {
        if let url = host.session.fileURL {
            host.selectedRecentID = url.resolvingSymlinksInPath().path
        } else {
            host.selectedRecentID = nil
        }
    }

    private func updateTitle() {
        window?.title = Self.windowTitle(host.session.document.name)
    }

    private static func windowTitle(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    private func suggestedFileName() -> String {
        let base = Self.windowTitle(host.session.document.name)
        return base.hasSuffix(".snapdesk") ? base : "\(base).snapdesk"
    }

    private func targetURL() -> URL? {
        if let id = host.selectedRecentID,
           let item = host.recents.first(where: { $0.id == id })
        {
            return item.url
        }
        return host.session.fileURL
    }

    private func sameFile(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        return a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    private func presentMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
