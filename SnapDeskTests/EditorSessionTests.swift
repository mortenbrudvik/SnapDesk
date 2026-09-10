import XCTest
@testable import SnapDesk

@MainActor
final class EditorSessionTests: XCTestCase {
    func testRemoveWindowAtZeroDropsTheSlotAndSetsDirty() {
        let first = savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub", arguments: "")
        let second = savedWindow(bundleIdentifier: "com.apple.Preview", title: "Photo", arguments: "")
        let session = EditorSession(
            document: makeDocument(windows: [first, second]),
            fileURL: URL(fileURLWithPath: "/tmp/coding.snapdesk")
        )
        XCTAssertFalse(session.isDirty)

        session.removeWindow(at: 0)

        XCTAssertEqual(session.document.windows.count, 1)
        XCTAssertEqual(session.document.windows[0].bundleIdentifier, "com.apple.Preview")
        XCTAssertTrue(session.isDirty)
    }

    func testRemoveWindowPreservesRemainingRowIdentity() {
        let first = savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub", arguments: "")
        let second = savedWindow(bundleIdentifier: "com.apple.Preview", title: "Photo", arguments: "")
        let session = EditorSession(
            document: makeDocument(windows: [first, second]),
            fileURL: nil
        )
        XCTAssertEqual(session.rowIDs.count, 2)
        let secondID = session.rowIDs[1]

        session.removeWindow(at: 0)

        XCTAssertEqual(session.rowIDs, [secondID])
        XCTAssertEqual(session.document.windows.count, 1)
    }

    func testApplyCaptureRebuildsRowIdentitiesToMatchWindows() {
        let session = EditorSession(
            document: makeDocument(windows: [
                savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub", arguments: ""),
            ]),
            fileURL: nil
        )
        let oldIDs = session.rowIDs

        session.applyCapture(
            makeDocument(windows: [
                savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub", arguments: ""),
                savedWindow(bundleIdentifier: "com.apple.Preview", title: "Photo", arguments: ""),
            ])
        )

        XCTAssertEqual(session.rowIDs.count, 2)
        XCTAssertNotEqual(session.rowIDs, oldIDs)
        XCTAssertEqual(Set(oldIDs).intersection(session.rowIDs), [])
    }

    func testApplyCapturePreservesArgumentsOnMatchAndPreservesNameAndMoveExisting() {
        let old = savedWindow(
            bundleIdentifier: "com.apple.Safari",
            title: "GitHub",
            arguments: "https://github.com"
        )
        let session = EditorSession(
            document: makeDocument(
                name: "Coding",
                moveExistingWindows: false,
                displays: [savedDisplay(id: "old", name: "Old")],
                windows: [old]
            ),
            fileURL: nil
        )

        var capturedWindow = savedWindow(
            bundleIdentifier: "com.apple.Safari",
            title: "GitHub",
            arguments: ""
        )
        capturedWindow.x = 40
        capturedWindow.y = 50
        capturedWindow.width = 800
        capturedWindow.height = 600
        let captured = makeDocument(
            name: "Untitled",
            moveExistingWindows: true,
            displays: [savedDisplay(id: "new", name: "New")],
            windows: [capturedWindow]
        )

        session.applyCapture(captured)

        XCTAssertEqual(session.document.name, "Coding")
        XCTAssertFalse(session.document.moveExistingWindows)
        XCTAssertEqual(session.document.displays, captured.displays)
        XCTAssertEqual(session.document.windows.count, 1)
        XCTAssertEqual(session.document.windows[0].arguments, "https://github.com")
        XCTAssertEqual(session.document.windows[0].title, "GitHub")
        XCTAssertEqual(session.document.windows[0].x, 40)
        XCTAssertEqual(session.document.windows[0].width, 800)
        XCTAssertTrue(session.isDirty)
    }

    func testApplyCaptureWithNoWindowsIsRefusedAndLeavesTheDocumentIntact() {
        let existing = savedWindow(
            bundleIdentifier: "com.apple.Safari",
            title: "GitHub",
            arguments: "https://github.com"
        )
        let session = EditorSession(
            document: makeDocument(name: "Coding", windows: [existing]),
            fileURL: URL(fileURLWithPath: "/tmp/coding.snapdesk")
        )
        let rowIDs = session.rowIDs
        XCTAssertFalse(session.isDirty)

        let applied = session.applyCapture(
            makeDocument(
                name: "Untitled",
                displays: [savedDisplay(id: "new", name: "New")],
                windows: []
            )
        )

        XCTAssertFalse(applied)
        XCTAssertEqual(session.document.windows, [existing])
        XCTAssertEqual(session.rowIDs, rowIDs)
        XCTAssertEqual(session.document.displays.map(\.id), ["display"])
        XCTAssertFalse(session.isDirty, "a capture that read nothing must not dirty a saved workspace")
    }

    func testRemoveWindowIgnoresAnIndexOutsideTheSlots() {
        let session = EditorSession(
            document: makeDocument(windows: [
                savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub", arguments: ""),
                savedWindow(bundleIdentifier: "com.apple.Preview", title: "Photo", arguments: ""),
            ]),
            fileURL: URL(fileURLWithPath: "/tmp/coding.snapdesk")
        )

        session.removeWindow(at: 2)
        session.removeWindow(at: -1)

        XCTAssertEqual(session.document.windows.count, 2)
        XCTAssertEqual(session.rowIDs.count, 2)
        XCTAssertFalse(session.isDirty)
    }

    func testSaveWritesToTheExistingFileURLAndClearsDirty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-session-\(UUID().uuidString).snapdesk")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession(document: makeDocument(name: "Coding"), fileURL: url)
        session.document.name = "Coding Edited"
        XCTAssertTrue(session.isDirty)

        try session.save()

        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(try WorkspaceDocument.load(from: url).name, "Coding Edited")
    }

    func testSaveToAddsTheURLToRecents() throws {
        let suiteName = "com.brudvik.snapdesk.tests.editorsession.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let recents = RecentsStore(defaults: defaults)
        let session = EditorSession(document: makeDocument(name: "Coding"), fileURL: nil, recents: recents)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-session-\(UUID().uuidString).snapdesk")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        try session.save(to: url)

        XCTAssertEqual(
            recents.urls.map { $0.resolvingSymlinksInPath().path },
            [url.resolvingSymlinksInPath().path]
        )
    }

    func testSaveToWritesJSONThatLoadRoundTrips() throws {
        let session = EditorSession(
            document: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub", arguments: "")]
            ),
            fileURL: nil
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-session-\(UUID().uuidString).snapdesk")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        try session.save(to: url)

        let loaded = try WorkspaceDocument.load(from: url)
        XCTAssertEqual(loaded, session.document)
        XCTAssertEqual(session.fileURL, url)
        XCTAssertFalse(session.isDirty)
    }

    /// The session must not report a save it did not make: the document is refused, so the file is
    /// left alone and the work stays unsaved rather than being marked clean.
    func testSavingADocumentTheLoaderWouldRejectFailsAndKeepsTheSessionDirty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-session-\(UUID().uuidString).snapdesk")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession(document: makeDocument(name: "Coding"), fileURL: url)
        session.document.windows[0].height = -600

        XCTAssertThrowsError(try session.save()) { error in
            guard case .corrupt(.invalid)? = error as? WorkspaceDocumentError else {
                return XCTFail("expected .corrupt(.invalid), got \(error)")
            }
        }
        XCTAssertTrue(session.isDirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSaveWithoutURLThrowsNoFileURL() {
        let session = EditorSession(document: makeDocument(), fileURL: nil)

        XCTAssertThrowsError(try session.save()) { error in
            XCTAssertEqual(error as? EditorSessionError, .noFileURL)
        }
    }

    func testCapturedUntitledWithWindowsIsDirtyAndEmptyUntitledIsClean() {
        let captured = EditorSession(
            document: makeDocument(
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub", arguments: "")]
            ),
            fileURL: nil
        )
        XCTAssertTrue(captured.isDirty, "a captured untitled document must prompt on close")

        let empty = EditorSession(document: EditorSession.untitledDocument, fileURL: nil)
        XCTAssertFalse(empty.isDirty)
        XCTAssertTrue(empty.document.windows.isEmpty)
    }

    private func makeDocument(
        name: String = "Untitled",
        moveExistingWindows: Bool = true,
        displays: [SavedDisplay]? = nil,
        windows: [SavedWindow]? = nil
    ) -> WorkspaceDocument {
        WorkspaceDocument(
            version: WorkspaceDocument.currentVersion,
            name: name,
            moveExistingWindows: moveExistingWindows,
            displays: displays ?? [savedDisplay(id: "display", name: "Built-in")],
            windows: windows ?? [
                savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub", arguments: "")
            ]
        )
    }

    private func savedDisplay(id: String, name: String) -> SavedDisplay {
        SavedDisplay(
            id: id,
            name: name,
            frame: CodableRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CodableRect(x: 0, y: 38, width: 1512, height: 916),
            scale: 2
        )
    }

    private func savedWindow(
        bundleIdentifier: String,
        title: String,
        arguments: String
    ) -> SavedWindow {
        SavedWindow(
            bundleIdentifier: bundleIdentifier,
            bundlePath: "/Applications/Dummy.app",
            name: "Dummy",
            title: title,
            displayId: "display",
            x: 0,
            y: 0,
            width: 100,
            height: 100,
            minimized: false,
            zoomed: false,
            arguments: arguments
        )
    }
}
