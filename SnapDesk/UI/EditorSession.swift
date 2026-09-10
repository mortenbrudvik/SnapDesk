import Combine
import Foundation

enum EditorSessionError: Error, Equatable {
    case noFileURL
}

@MainActor
final class EditorSession: ObservableObject {
    @Published var document: WorkspaceDocument {
        didSet {
            if document != oldValue {
                isDirty = true
            }
            // The editor's bindings write into `document` directly, so a slot count can change
            // without going through the methods below. `rowIDs` is zipped with the windows to key
            // the SwiftUI rows, and a shorter one silently drops the last rows from the list.
            if document.windows.count != rowIDs.count {
                realignRowIDs()
            }
        }
    }
    @Published var fileURL: URL?
    @Published var isDirty: Bool

    /// Editor-only identities for window rows. Not part of the `.snapdesk` schema.
    private(set) var rowIDs: [UUID]

    private let recents: RecentsStore?

    init(document: WorkspaceDocument, fileURL: URL?, recents: RecentsStore? = nil) {
        self.document = document
        self.fileURL = fileURL
        self.recents = recents
        self.isDirty = fileURL == nil && !document.windows.isEmpty
        self.rowIDs = document.windows.map { _ in UUID() }
    }

    func removeWindow(at index: Int) {
        guard document.windows.indices.contains(index) else { return }
        // The identity goes first, so the counts match by the time `document`'s observer runs and
        // it has nothing to realign — realigning would drop the *last* row rather than this one.
        rowIDs.remove(at: index)
        document.windows.remove(at: index)
    }

    /// Keeps the rows that are still there and mints identities for the rest. Appending a slot
    /// must not renumber the ones above it, or every row loses its place mid-edit.
    private func realignRowIDs() {
        let count = document.windows.count
        if rowIDs.count > count {
            rowIDs = Array(rowIDs.prefix(count))
        } else {
            rowIDs += (rowIDs.count..<count).map { _ in UUID() }
        }
    }

    /// Returns `false` — leaving the session untouched — when the capture holds no windows.
    /// `Recapture.merge` maps over the new windows, so an empty capture would otherwise replace
    /// every configured slot with nothing and mark that loss dirty.
    @discardableResult
    func applyCapture(_ captured: WorkspaceDocument) -> Bool {
        guard !captured.windows.isEmpty else { return false }
        document.displays = captured.displays
        document.windows = Recapture.merge(old: document.windows, new: captured.windows)
        rowIDs = document.windows.map { _ in UUID() }
        isDirty = true
        return true
    }

    func save() throws {
        guard let fileURL else { throw EditorSessionError.noFileURL }
        try document.save(to: fileURL)
        isDirty = false
    }

    func save(to url: URL) throws {
        try document.save(to: url)
        fileURL = url
        recents?.add(url)
        isDirty = false
    }

    static var untitledDocument: WorkspaceDocument {
        WorkspaceDocument(
            version: WorkspaceDocument.currentVersion,
            name: "Untitled",
            moveExistingWindows: true,
            displays: [],
            windows: []
        )
    }
}
