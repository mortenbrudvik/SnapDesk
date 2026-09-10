import SwiftUI
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

    func testRecaptureThatReadsNoWindowsKeepsTheDocumentAndTellsTheUser() throws {
        let empty = makeDocument(name: "Untitled", windows: [])
        let prompt = FakePrompt()
        let controller = EditorWindowController(
            recents: RecentsStore(defaults: scratchDefaults()),
            capture: { empty },
            launch: { _ in },
            prompt: prompt
        )
        let url = temporaryWorkspaceURL()

        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
            )
        )
        try controller.session.save(to: url)

        controller.recapture()

        XCTAssertEqual(controller.session.document.windows.map(\.title), ["GitHub"])
        XCTAssertEqual(controller.session.fileURL, url)
        XCTAssertFalse(controller.session.isDirty, "a capture that read nothing must not dirty the workspace")
        XCTAssertEqual(prompt.reports.map(\.title), ["Captured no windows"])
    }

    func testDiscardingChangesReloadsTheSavedFile() throws {
        let prompt = FakePrompt()
        let controller = makeController(prompt: prompt)
        let url = temporaryWorkspaceURL()
        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
            )
        )
        try controller.session.save(to: url)
        controller.session.document.name = "Coding Edited"
        prompt.choice = .discard

        XCTAssertTrue(controller.windowShouldClose(try XCTUnwrap(controller.window)))

        XCTAssertEqual(controller.session.document.name, "Coding")
        XCTAssertEqual(controller.session.fileURL, url)
        XCTAssertFalse(controller.session.isDirty)
        XCTAssertTrue(prompt.reports.isEmpty)
    }

    func testDiscardingChangesKeepsTheSessionWhenTheFileCannotBeRead() throws {
        let prompt = FakePrompt()
        let controller = makeController(prompt: prompt)
        let url = temporaryWorkspaceURL()
        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
            )
        )
        try controller.session.save(to: url)
        controller.session.document.name = "Coding Edited"
        try FileManager.default.removeItem(at: url)
        prompt.choice = .discard

        XCTAssertTrue(controller.windowShouldClose(try XCTUnwrap(controller.window)))

        XCTAssertEqual(controller.session.fileURL, url, "the editor must not forget the file it was editing")
        XCTAssertEqual(controller.session.document.name, "Coding Edited")
        XCTAssertEqual(controller.session.document.windows.map(\.title), ["GitHub"])
        XCTAssertEqual(prompt.reports.map(\.title), ["Could not reload “\(url.lastPathComponent)”"])
    }

    func testWindowShouldCloseCancelKeepsTheUnsavedEdits() throws {
        let prompt = FakePrompt()
        let controller = makeController(prompt: prompt)
        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
            )
        )
        prompt.choice = .cancel

        XCTAssertFalse(controller.windowShouldClose(try XCTUnwrap(controller.window)))

        XCTAssertTrue(controller.session.isDirty)
        XCTAssertEqual(controller.session.document.name, "Coding")
    }

    func testWindowShouldCloseSaveWritesTheEditsToTheFile() throws {
        let prompt = FakePrompt()
        let controller = makeController(prompt: prompt)
        let url = temporaryWorkspaceURL()
        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
            )
        )
        try controller.session.save(to: url)
        controller.session.document.name = "Coding Edited"
        prompt.choice = .save

        XCTAssertTrue(controller.windowShouldClose(try XCTUnwrap(controller.window)))

        XCTAssertFalse(controller.session.isDirty)
        XCTAssertEqual(try WorkspaceDocument.load(from: url).name, "Coding Edited")
    }

    /// A size the document cannot hold must stop the save rather than be written out and rejected
    /// on the next open, and the user has to be told which slot is wrong while the editor is still
    /// open to fix it.
    func testSavingASlotWithANonPositiveSizeIsRefusedAndExplained() throws {
        let prompt = FakePrompt()
        let controller = makeController(prompt: prompt)
        let url = temporaryWorkspaceURL()
        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
            )
        )
        try controller.session.save(to: url)
        controller.session.document.windows[0].width = 0
        prompt.choice = .save

        XCTAssertFalse(controller.windowShouldClose(try XCTUnwrap(controller.window)))

        XCTAssertTrue(controller.session.isDirty)
        XCTAssertEqual(prompt.reports.map(\.title), ["Could not save “\(url.lastPathComponent)”"])
        let detail = try XCTUnwrap(prompt.reports.first?.detail)
        XCTAssertTrue(detail.contains("Dummy"), "the alert must name the offending slot: \(detail)")
        XCTAssertEqual(try WorkspaceDocument.load(from: url).windows[0].width, 100, "the saved file must be untouched")
    }

    /// The row's W and H fields commit through this binding. They used to take a 0 or a negative
    /// side straight into the document, which then could not be saved or relaunched.
    func testTheWindowSizeFieldClampsANonPositiveSideBeforeItReachesTheDocument() {
        let controller = makeController(prompt: FakePrompt())
        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
            )
        )
        let session = controller.session
        let width = WindowSizeField.binding(
            Binding(
                get: { session.document.windows[0].width },
                set: { session.document.windows[0].width = $0 }
            )
        )

        width.wrappedValue = 0
        XCTAssertEqual(session.document.windows[0].width, WindowSizeField.minimum)

        width.wrappedValue = -400
        XCTAssertEqual(session.document.windows[0].width, WindowSizeField.minimum)

        width.wrappedValue = 640
        XCTAssertEqual(session.document.windows[0].width, 640, "a legal size must pass through untouched")
        XCTAssertEqual(WindowSizeField.clamped(.nan), WindowSizeField.minimum)
    }

    func testSavingAnUntitledWorkspaceOnCloseWritesToTheChosenDestination() throws {
        let prompt = FakePrompt()
        let controller = makeController(prompt: prompt)
        let url = temporaryWorkspaceURL()
        prompt.destination = url
        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
            )
        )
        XCTAssertNil(controller.session.fileURL)
        prompt.choice = .save

        XCTAssertTrue(controller.windowShouldClose(try XCTUnwrap(controller.window)))

        XCTAssertEqual(controller.session.fileURL, url)
        XCTAssertFalse(controller.session.isDirty)
        XCTAssertEqual(try WorkspaceDocument.load(from: url).name, "Coding")
    }

    func testCancellingTheSaveDestinationKeepsTheWindowOpen() throws {
        let prompt = FakePrompt()
        let controller = makeController(prompt: prompt)
        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
            )
        )
        prompt.choice = .save
        prompt.destination = nil

        XCTAssertFalse(controller.windowShouldClose(try XCTUnwrap(controller.window)))

        XCTAssertTrue(controller.session.isDirty)
        XCTAssertNil(controller.session.fileURL)
    }

    func testPrepareForTerminationCancelBlocksQuitAndDiscardAllowsIt() {
        let prompt = FakePrompt()
        let controller = makeController(prompt: prompt)
        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
            )
        )
        XCTAssertTrue(controller.session.isDirty)

        prompt.choice = .cancel
        XCTAssertFalse(controller.prepareForTermination())

        prompt.choice = .discard
        XCTAssertTrue(controller.prepareForTermination())
    }

    func testCapturingOverUnsavedWorkIsAbandonedWhenTheUserCancels() {
        let prompt = FakePrompt()
        let controller = makeController(prompt: prompt)
        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
            )
        )
        prompt.choice = .cancel

        controller.open(
            captured: makeDocument(
                name: "Untitled",
                windows: [savedWindow(bundleIdentifier: "com.apple.Preview", title: "Photo")]
            )
        )

        XCTAssertEqual(controller.session.document.name, "Coding")
        XCTAssertEqual(controller.session.document.windows.map(\.title), ["GitHub"])
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

    func testRemovingARowAboveTheSelectionShiftsTheSelectionUp() {
        let controller = makeController(prompt: FakePrompt())
        controller.open(captured: makeDocument(name: "Coding", windows: threeWindows()))
        controller.host.selectedWindowIndex = 2

        controller.removeWindow(at: 0)

        XCTAssertEqual(controller.host.selectedWindowIndex, 1)
        XCTAssertEqual(controller.session.document.windows.map(\.title), ["Photo", "Notes"])
    }

    func testRemovingTheSelectedRowClearsTheSelection() {
        let controller = makeController(prompt: FakePrompt())
        controller.open(captured: makeDocument(name: "Coding", windows: threeWindows()))
        controller.host.selectedWindowIndex = 1

        controller.removeWindow(at: 1)

        XCTAssertNil(controller.host.selectedWindowIndex)
        XCTAssertEqual(controller.session.document.windows.map(\.title), ["GitHub", "Notes"])
    }

    func testRemovingARowBelowTheSelectionLeavesTheSelectionAlone() {
        let controller = makeController(prompt: FakePrompt())
        controller.open(captured: makeDocument(name: "Coding", windows: threeWindows()))
        controller.host.selectedWindowIndex = 0

        controller.removeWindow(at: 2)

        XCTAssertEqual(controller.host.selectedWindowIndex, 0)
        XCTAssertEqual(controller.session.document.windows.map(\.title), ["GitHub", "Photo"])
    }

    @MainActor
    private final class FakePrompt: EditorPrompting {
        struct Report: Equatable {
            var title: String
            var detail: String?
        }

        var choice: EditorSaveChoice = .cancel
        var destination: URL?
        private(set) var reports: [Report] = []

        func saveChoice(documentName: String) -> EditorSaveChoice { choice }

        func saveDestination(suggestedName: String) -> URL? { destination }

        func report(title: String, detail: String?) {
            reports.append(Report(title: title, detail: detail))
        }
    }

    private func makeController(prompt: FakePrompt) -> EditorWindowController {
        EditorWindowController(
            recents: RecentsStore(defaults: scratchDefaults()),
            capture: { nil },
            launch: { _ in },
            prompt: prompt
        )
    }

    private func temporaryWorkspaceURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coding-\(UUID().uuidString).snapdesk")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func threeWindows() -> [SavedWindow] {
        [
            savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub"),
            savedWindow(bundleIdentifier: "com.apple.Preview", title: "Photo"),
            savedWindow(bundleIdentifier: "com.apple.Notes", title: "Notes"),
        ]
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

@MainActor
final class WorkspacePreviewGeometryTests: XCTestCase {
    private let bounds = CGRect(x: -1512, y: 0, width: 3024, height: 982)
    private let origin = CGPoint(x: 10, y: 20)

    func testPreviewRectPlacesTheTopOfTheDesktopAtTheTopOfThePreview() {
        let topLeft = CGRect(x: -1512, y: 482, width: 500, height: 500)

        let rect = WorkspacePreview.previewRect(cocoa: topLeft, bounds: bounds, scale: 0.5, origin: origin)

        XCTAssertEqual(rect.minX, 10, accuracy: 0.0001)
        XCTAssertEqual(rect.minY, 20, accuracy: 0.0001, "cocoa's top edge must map to the preview's top edge")
        XCTAssertEqual(rect.width, 250, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 250, accuracy: 0.0001)
    }

    func testPreviewRectFlipsALowWindowToTheBottomOfThePreview() {
        let bottomRight = CGRect(x: 1012, y: 0, width: 500, height: 482)

        let rect = WorkspacePreview.previewRect(cocoa: bottomRight, bounds: bounds, scale: 0.5, origin: origin)

        XCTAssertEqual(rect.minX, 10 + 1262, accuracy: 0.0001)
        XCTAssertEqual(rect.minY, 20 + 250, accuracy: 0.0001)
        XCTAssertEqual(rect.maxY, 20 + bounds.height * 0.5, accuracy: 0.0001)
    }

    func testWindowCocoaFrameOffsetsByTheMatchingDisplayVisibleFrame() {
        let frame = WorkspacePreview.windowCocoaFrame(
            savedWindow(displayId: "main"),
            displays: [display(id: "left", visibleX: -1512, visibleY: 0), display(id: "main", visibleX: 0, visibleY: 38)]
        )

        XCTAssertEqual(frame, CGRect(x: 10, y: 58, width: 300, height: 200))
    }

    func testWindowCocoaFrameFallsBackToTheFirstDisplayForAnUnknownDisplayID() {
        let frame = WorkspacePreview.windowCocoaFrame(
            savedWindow(displayId: "unplugged"),
            displays: [display(id: "left", visibleX: -1512, visibleY: 0), display(id: "main", visibleX: 0, visibleY: 38)]
        )

        XCTAssertEqual(frame, CGRect(x: -1502, y: 20, width: 300, height: 200))
    }

    func testWindowCocoaFrameKeepsRelativeCoordinatesWithNoDisplays() {
        let frame = WorkspacePreview.windowCocoaFrame(savedWindow(displayId: "main"), displays: [])

        XCTAssertEqual(frame, CGRect(x: 10, y: 20, width: 300, height: 200))
    }

    func testUnionFramesIsNullWithoutDisplaysAndSpansThemOtherwise() {
        XCTAssertTrue(WorkspacePreview.unionFrames([]).isNull)

        let union = WorkspacePreview.unionFrames([
            CGRect(x: 0, y: 0, width: 1512, height: 982),
            CGRect(x: -1512, y: 0, width: 1512, height: 982),
        ])

        XCTAssertEqual(union, CGRect(x: -1512, y: 0, width: 3024, height: 982))
    }

    private func display(id: String, visibleX: Double, visibleY: Double) -> SavedDisplay {
        SavedDisplay(
            id: id,
            name: id,
            frame: CodableRect(x: visibleX, y: 0, width: 1512, height: 982),
            visibleFrame: CodableRect(x: visibleX, y: visibleY, width: 1512, height: 916),
            scale: 2
        )
    }

    private func savedWindow(displayId: String) -> SavedWindow {
        SavedWindow(
            bundleIdentifier: "com.apple.Safari",
            bundlePath: "/Applications/Dummy.app",
            name: "Dummy",
            title: "GitHub",
            displayId: displayId,
            x: 10,
            y: 20,
            width: 300,
            height: 200,
            minimized: false,
            zoomed: false,
            arguments: ""
        )
    }
}

