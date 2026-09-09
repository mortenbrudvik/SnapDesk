import XCTest
@testable import SnapDesk

@MainActor
final class EditorWindowTests: XCTestCase {
    func testMenuCaptureReplacesVisibleSavedSessionWithUntitled() throws {
        let recents = RecentsStore(defaults: scratchDefaults())
        let controller = EditorWindowController(
            recents: recents,
            capture: { nil },
            launch: { _ in }
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coding-\(UUID().uuidString).snapdesk")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
            )
        )
        try controller.session.save(to: url)
        XCTAssertFalse(controller.session.isDirty)
        XCTAssertEqual(controller.session.fileURL, url)

        controller.open(
            captured: makeDocument(
                name: "Untitled",
                windows: [savedWindow(bundleIdentifier: "com.apple.Preview", title: "Photo")]
            )
        )

        XCTAssertNil(controller.session.fileURL)
        XCTAssertEqual(controller.session.document.name, "Untitled")
        XCTAssertEqual(controller.session.document.windows.map(\.title), ["Photo"])
        XCTAssertTrue(controller.session.isDirty)
    }

    func testEditorRecaptureMergesIntoCurrentSavedSession() throws {
        var recaptured = makeDocument(
            name: "Untitled",
            windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
        )
        recaptured.windows[0].x = 40
        let recents = RecentsStore(defaults: scratchDefaults())
        let controller = EditorWindowController(
            recents: recents,
            capture: { recaptured },
            launch: { _ in }
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coding-\(UUID().uuidString).snapdesk")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        var saved = savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")
        saved.arguments = "https://github.com"
        controller.open(captured: makeDocument(name: "Coding", windows: [saved]))
        try controller.session.save(to: url)

        controller.recapture()

        XCTAssertEqual(controller.session.fileURL, url)
        XCTAssertEqual(controller.session.document.name, "Coding")
        XCTAssertEqual(controller.session.document.windows[0].arguments, "https://github.com")
        XCTAssertEqual(controller.session.document.windows[0].x, 40)
        XCTAssertTrue(controller.session.isDirty)
    }

    func testPrepareForTerminationAllowsWhenClean() {
        let controller = EditorWindowController(
            recents: RecentsStore(defaults: scratchDefaults()),
            capture: { nil },
            launch: { _ in }
        )
        XCTAssertFalse(controller.session.isDirty)
        XCTAssertTrue(controller.prepareForTermination())
    }

    private func scratchDefaults() -> UserDefaults {
        let name = "com.brudvik.snapdesk.tests.editorwindow.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeDocument(
        name: String,
        windows: [SavedWindow]
    ) -> WorkspaceDocument {
        WorkspaceDocument(
            version: WorkspaceDocument.currentVersion,
            name: name,
            moveExistingWindows: true,
            displays: [
                SavedDisplay(
                    id: "display",
                    name: "Built-in",
                    frame: CodableRect(x: 0, y: 0, width: 1512, height: 982),
                    visibleFrame: CodableRect(x: 0, y: 38, width: 1512, height: 916),
                    scale: 2
                ),
            ],
            windows: windows
        )
    }

    private func savedWindow(bundleIdentifier: String, title: String) -> SavedWindow {
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
            arguments: ""
        )
    }
}
