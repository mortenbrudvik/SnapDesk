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
