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
        document.windows.remove(at: index)
        rowIDs.remove(at: index)
    }

    func applyCapture(_ captured: WorkspaceDocument) {
        document.displays = captured.displays
        document.windows = Recapture.merge(old: document.windows, new: captured.windows)
        rowIDs = document.windows.map { _ in UUID() }
        isDirty = true
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
