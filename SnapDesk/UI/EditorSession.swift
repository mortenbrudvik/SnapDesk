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

    private let recents: RecentsStore?

    init(document: WorkspaceDocument, fileURL: URL?, recents: RecentsStore? = nil) {
        self.document = document
        self.fileURL = fileURL
        self.recents = recents
        self.isDirty = false
    }

    func removeWindow(at index: Int) {
        guard document.windows.indices.contains(index) else { return }
        document.windows.remove(at: index)
    }

    func applyCapture(_ captured: WorkspaceDocument) {
        document.displays = captured.displays
        document.windows = Recapture.merge(old: document.windows, new: captured.windows)
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
