import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct EditorRecentItem: Identifiable, Equatable {
    var id: String
    var url: URL
    var name: String
    var filename: String
    /// Nil for a workspace that has never been restored. Shown so the list says why it is in the
    /// order it is in.
    var lastLaunched: Date?
}

enum EditorSaveChoice {
    case save, discard, cancel
}

/// Every modal the editor puts in front of the user. Injected so the close, discard and save
/// paths can be exercised without an NSAlert run loop.
@MainActor
protocol EditorPrompting: AnyObject {
    func saveChoice(documentName: String) -> EditorSaveChoice
    func saveDestination(suggestedName: String) -> URL?
    /// `title` says what SnapDesk failed to do; `detail` carries the file and the underlying reason.
    func report(title: String, detail: String?)
}

@MainActor
final class AppKitEditorPrompt: EditorPrompting {
    func saveChoice(documentName: String) -> EditorSaveChoice {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to “\(documentName)”?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }

    func saveDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [WorkspaceFileType.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func report(title: String, detail: String?) {
        let alert = NSAlert()
        alert.messageText = title
        if let detail {
            alert.informativeText = detail
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Remembers the workspace name behind each recent file, keyed on the file's modification date,
/// so the sidebar is not re-reading and re-decoding up to twenty documents on the main thread
/// every time the window becomes key. A file whose date cannot be read is read every time: a
/// missing date is not evidence that nothing changed.
@MainActor
final class RecentNameCache {
    private var names: [String: (modified: Date, name: String?)] = [:]

    func name(for url: URL, modified: Date?, load: () -> String?) -> String? {
        let key = url.resolvingSymlinksInPath().path
        guard let modified else {
            names[key] = nil
            return load()
        }
        if let cached = names[key], cached.modified == modified {
            return cached.name
        }
        let name = load()
        names[key] = (modified, name)
        return name
    }
}

@MainActor
final class EditorHost: ObservableObject {
    @Published var session: EditorSession
    @Published var recents: [EditorRecentItem] = []
    /// Whether a folder has been nominated, so the sidebar can offer Choose or Change.
    @Published var hasWorkspaceFolder = false
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
    private let library: WorkspaceLibrary
    private let capture: () -> CaptureOutcome?
    private let launch: (WorkspaceDocument) -> Void
    private let launchFile: (URL) -> Void
    private let prompt: any EditorPrompting
    private let beep: @MainActor () -> Void
    let host: EditorHost
    private var titleCancellable: AnyCancellable?
    private var didCenter = false
    /// How many of this window's modals are on screen; see `presenting(_:)`. A count rather than a
    /// flag so a prompt raised from inside another one cannot clear it for both.
    private var promptDepth = 0
    private let recentNames = RecentNameCache()

    init(
        recents: RecentsStore,
        library: WorkspaceLibrary = WorkspaceLibrary(),
        capture: @escaping () -> CaptureOutcome?,
        launch: @escaping (WorkspaceDocument) -> Void,
        launchFile: @escaping (URL) -> Void = { _ in },
        prompt: any EditorPrompting = AppKitEditorPrompt(),
        beep: @escaping @MainActor () -> Void = { NSSound.beep() }
    ) {
        self.recents = recents
        self.library = library
        self.launchFile = launchFile
        self.capture = capture
        self.launch = launch
        self.prompt = prompt
        self.beep = beep
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

    var session: EditorSession { host.session }

    /// True while one of this window's own modals is up. `AppDelegate` asks before doing the work
    /// a command needs, so a Capture that is going to be refused does not first sweep every app's
    /// windows over Accessibility.
    var isPresentingPrompt: Bool { promptDepth > 0 }

    /// Opens the editor on a fresh capture, or just brings it forward when `captured` is nil.
    /// Returns whether the capture was taken on: false when the editor refused it (a prompt is
    /// up) or the user kept their unsaved work instead.
    @discardableResult
    func open(captured: WorkspaceDocument?) -> Bool {
        guard !isPresentingPrompt else {
            refuseCommandWhilePrompting("open")
            return false
        }
        if let captured {
            guard confirmDiscardIfNeeded() else {
                present()
                return false
            }
            replaceSession(
                EditorSession(document: captured, fileURL: nil, recents: recents)
            )
        }
        present()
        return captured != nil
    }

    /// The Capture command: the document goes into the editor and whatever the capture could not
    /// read is explained on top of it, so a workspace missing an app is never mistaken for a
    /// complete one.
    ///
    /// A capture holding no windows never replaces anything. Whether the desk was empty or
    /// Accessibility read nothing, installing it would throw away whatever the user had open in
    /// the editor — and arrive `isDirty == false`, so it would not even look unsaved.
    func open(capture outcome: CaptureOutcome) {
        guard !outcome.document.windows.isEmpty else {
            guard !isPresentingPrompt else {
                refuseCommandWhilePrompting("capture")
                return
            }
            Log.capture.error("capture read no windows; the editor was left unchanged")
            present()
            report(
                title: "Captured no windows",
                detail: "\(outcome.report.explanation ?? "SnapDesk found no windows to capture.") The workspace was left unchanged."
            )
            return
        }
        guard open(captured: outcome.document) else { return }
        explain(outcome.report)
    }

    func recapture() {
        guard !isPresentingPrompt else {
            refuseCommandWhilePrompting("recapture")
            return
        }
        guard let outcome = capture() else { return }
        // `applyCapture` refuses an empty capture rather than blanking the document: whether the
        // desk was really empty or Accessibility read nothing, wiping every configured slot is not
        // what the user reached for Capture to do. The report says which of the two it was.
        guard host.session.applyCapture(outcome.document) else {
            Log.capture.error("recapture read no windows; the document was left unchanged")
            let reason = outcome.report.explanation
                ?? "SnapDesk found no windows to capture."
            report(
                title: "Captured no windows",
                detail: "\(reason) The workspace was left unchanged."
            )
            return
        }
        explain(outcome.report)
    }

    private func explain(_ report: CaptureReport) {
        guard let explanation = report.explanation else { return }
        Log.capture.error("capture was incomplete: \(explanation, privacy: .public)")
        self.report(title: "Some windows were not captured", detail: explanation)
    }

    func prepareForTermination() -> Bool {
        guard host.session.isDirty else { return true }
        switch presenting({ prompt.saveChoice(documentName: host.session.document.name) }) {
        case .save:
            return performSave()
        case .discard:
            return true
        case .cancel:
            return false
        }
    }

    override func showWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard host.session.isDirty else { return true }
        switch presenting({ prompt.saveChoice(documentName: host.session.document.name) }) {
        case .save:
            return performSave()
        case .discard:
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
                onLaunchWorkspace: { [weak self] url in self?.launchSelectedWorkspace(url) },
                onChooseFolder: { [weak self] in self?.chooseWorkspaceFolder() },
                onClearFolder: { [weak self] in self?.clearWorkspaceFolder() },
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

    private func openPanel() {
        guard confirmDiscardIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [WorkspaceFileType.contentType]
        guard presenting({ panel.runModal() }) == .OK, let url = panel.url else { return }
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
            Log.editor.error("could not open \(url.path, privacy: .public): the file no longer exists")
            report(
                title: "Could not open “\(url.lastPathComponent)”",
                detail: "The file could not be found. It may have been moved, renamed, or deleted."
            )
            refreshRecents()
            return
        }
        do {
            let document = try WorkspaceDocument.load(from: url)
            recents.add(url)
            replaceSession(EditorSession(document: document, fileURL: url, recents: recents))
        } catch let error as WorkspaceDocumentError {
            Log.editor.error(
                "could not read \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            report(
                title: WorkspaceOpener.openFailureTitle(for: url),
                detail: WorkspaceOpener.detail(for: error)
            )
        } catch {
            Log.editor.error(
                "could not read \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            report(
                title: "Could not open “\(url.lastPathComponent)”",
                detail: error.localizedDescription
            )
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
        guard presenting({ alert.runModal() }) == .alertFirstButtonReturn else { return }
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
            Log.editor.error(
                "could not trash \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            report(
                title: "Could not move “\(url.lastPathComponent)” to the Trash",
                detail: error.localizedDescription
            )
        }
    }

    private func launchCurrent() {
        launch(host.session.document)
    }

    @discardableResult
    private func performSave() -> Bool {
        guard let url = host.session.fileURL else { return saveAs() }
        do {
            try host.session.save()
            updateTitle()
            return true
        } catch {
            Log.editor.error(
                "could not save \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            report(
                title: "Could not save “\(url.lastPathComponent)”",
                detail: error.localizedDescription
            )
            return false
        }
    }

    @discardableResult
    private func saveAs() -> Bool {
        guard let url = presenting({ prompt.saveDestination(suggestedName: suggestedFileName()) }) else {
            return false
        }
        do {
            try host.session.save(to: url)
            refreshRecents()
            updateTitle()
            return true
        } catch {
            Log.editor.error(
                "could not save \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            report(
                title: "Could not save “\(url.lastPathComponent)”",
                detail: error.localizedDescription
            )
            return false
        }
    }

    func removeWindow(at index: Int) {
        host.session.removeWindow(at: index)
        if host.selectedWindowIndex == index {
            host.selectedWindowIndex = nil
        } else if let selected = host.selectedWindowIndex, selected > index {
            host.selectedWindowIndex = selected - 1
        }
    }

    private func confirmDiscardIfNeeded() -> Bool {
        guard host.session.isDirty else { return true }
        switch presenting({ prompt.saveChoice(documentName: host.session.document.name) }) {
        case .save:
            return performSave()
        case .discard:
            return true
        case .cancel:
            return false
        }
    }

    private func revertAfterDiscard() {
        guard let url = host.session.fileURL else {
            replaceSession(
                EditorSession(
                    document: EditorSession.untitledDocument,
                    fileURL: nil,
                    recents: recents
                )
            )
            return
        }
        do {
            let document = try WorkspaceDocument.load(from: url)
            replaceSession(EditorSession(document: document, fileURL: url, recents: recents))
        } catch {
            // The file is gone or unreadable. Resetting to Untitled here would look like SnapDesk
            // wiped the workspace on the one action the user expected to be lossless, so keep the
            // session on the file and let them save it back out.
            let reason = error.localizedDescription
            Log.editor.error("discard could not re-read \(url.path, privacy: .public): \(reason, privacy: .public)")
            report(
                title: "Could not reload “\(url.lastPathComponent)”",
                detail: """
                SnapDesk kept the version in the editor because the saved file could not be read. \
                \(error.localizedDescription)
                """
            )
        }
    }

    /// Runs a modal prompt or panel and marks the editor as busy with it for the duration. Global
    /// hot keys keep firing while `runModal` spins the run loop, and their handlers land on the
    /// main actor inside it — so without this a Capture arriving mid-prompt opened a second prompt
    /// on top of the first and replaced the session the first one was about, and the user's
    /// answer was then applied to the wrong document. `open(captured:)` and `recapture()` refuse
    /// while this is set.
    private func presenting<T>(_ body: () -> T) -> T {
        promptDepth += 1
        defer { promptDepth -= 1 }
        return body()
    }

    private func report(title: String, detail: String?) {
        presenting { prompt.report(title: title, detail: detail) }
    }

    /// The beep stays: a command that dies silently is indistinguishable from a broken app.
    func refuseCommandWhilePrompting(_ command: String) {
        Log.editor.notice("\(command, privacy: .public) refused: the editor has a prompt on screen")
        beep()
    }

    /// The sidebar list: the nominated folder merged with recents, ordered by the library. With
    /// no folder chosen this is exactly the recents list, which is what it was before.
    private func refreshRecents() {
        host.hasWorkspaceFolder = library.folder != nil
        host.recents = library.listing(recents: recents.urls).map { row in
            let modified = try? row.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let name = recentNames.name(for: row.url, modified: modified) {
                try? WorkspaceDocument.load(from: row.url).name
            } ?? row.name
            return EditorRecentItem(
                id: row.url.resolvingSymlinksInPath().path,
                url: row.url,
                name: name,
                filename: row.url.lastPathComponent,
                lastLaunched: row.lastLaunched
            )
        }
        syncRecentSelection()
    }

    /// Nominates the folder the sidebar lists alongside recents.
    func chooseWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder your workspaces live in."
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        library.folder = url
        refreshRecents()
    }

    func clearWorkspaceFolder() {
        library.folder = nil
        refreshRecents()
    }

    func launchSelectedWorkspace(_ url: URL) {
        launchFile(url)
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
        let suffix = ".\(WorkspaceFileType.fileExtension)"
        return base.hasSuffix(suffix) ? base : base + suffix
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
}
