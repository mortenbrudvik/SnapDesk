import SwiftUI
import XCTest
@testable import SnapDesk

@MainActor
final class EditorWindowTests: XCTestCase {
    func testMenuCaptureReplacesVisibleSavedSessionWithUntitled() throws {
        let controller = makeController(prompt: FakePrompt())
        let url = temporaryWorkspaceURL()

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
        let controller = makeController(
            prompt: FakePrompt(),
            capture: { CaptureOutcome(document: recaptured, report: .clean) }
        )
        let url = temporaryWorkspaceURL()

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
        let controller = makeController(
            prompt: prompt,
            capture: { CaptureOutcome(document: empty, report: .clean) }
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
        XCTAssertEqual(
            prompt.reports.first?.detail,
            "SnapDesk found no windows to capture. The workspace was left unchanged.",
            "a clean empty capture is an empty desk, not a permission problem"
        )
    }

    /// An empty capture that *did* lose apps is a different message: the user has to know that the
    /// capture failed, not that their desk is empty.
    func testAnEmptyRecaptureThatLostAnAppSaysSo() throws {
        let empty = makeDocument(name: "Untitled", windows: [])
        var report = CaptureReport()
        report.unreadableApps = ["Xcode"]
        let prompt = FakePrompt()
        let controller = makeController(
            prompt: prompt,
            capture: { CaptureOutcome(document: empty, report: report) }
        )
        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
            )
        )

        controller.recapture()

        XCTAssertEqual(controller.session.document.windows.map(\.title), ["GitHub"])
        XCTAssertEqual(prompt.reports.map(\.title), ["Captured no windows"])
        let detail = try XCTUnwrap(prompt.reports.first?.detail)
        XCTAssertTrue(detail.contains("Xcode did not answer"), detail)
        XCTAssertTrue(detail.hasSuffix("The workspace was left unchanged."), detail)
    }

    /// A recapture that read most of the desk still applies, and then says which app it lost —
    /// otherwise the workspace looks complete and the missing app is discovered at the next restore.
    func testARecaptureThatLostAnAppAppliesAndExplains() throws {
        var report = CaptureReport()
        report.unreadableApps = ["Xcode"]
        let recaptured = makeDocument(
            name: "Untitled",
            windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
        )
        let prompt = FakePrompt()
        let controller = makeController(
            prompt: prompt,
            capture: { CaptureOutcome(document: recaptured, report: report) }
        )
        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Preview", title: "Photo")]
            )
        )

        controller.recapture()

        XCTAssertEqual(controller.session.document.windows.map(\.title), ["GitHub"])
        XCTAssertEqual(prompt.reports.map(\.title), ["Some windows were not captured"])
        let detail = try XCTUnwrap(prompt.reports.first?.detail)
        XCTAssertTrue(detail.contains("Xcode"), detail)
    }

    /// The Capture command on a desk that yields no windows: the report is clean, so there was
    /// nothing to explain — and the empty document replaced the user's unsaved work, arriving
    /// `isDirty == false` so it did not even look unsaved. `recapture()` refused this from the
    /// start; the menu and hotkey path did not.
    func testACaptureWithNoWindowsIsRefusedRatherThanReplacingTheDocument() throws {
        let prompt = FakePrompt()
        let controller = makeController(prompt: prompt)
        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
            )
        )
        XCTAssertTrue(controller.session.isDirty)

        controller.open(capture: CaptureOutcome(document: makeDocument(name: "Untitled", windows: []), report: .clean))

        XCTAssertEqual(controller.session.document.name, "Coding", "the unsaved work must survive")
        XCTAssertEqual(controller.session.document.windows.map(\.title), ["GitHub"])
        XCTAssertTrue(controller.session.isDirty)
        XCTAssertEqual(prompt.reports.map(\.title), ["Captured no windows"])
        XCTAssertEqual(prompt.saveChoiceCalls, 0, "nothing is being discarded, so there is nothing to confirm")
    }

    /// A recapture arriving while a prompt is up must not even ask for the capture: it is a
    /// synchronous Accessibility sweep of every running app, thrown away.
    func testARecaptureRefusedWhileAPromptIsUpNeverAsksForTheCapture() throws {
        let prompt = FakePrompt()
        let captures = Counter()
        let empty = makeDocument(name: "Untitled", windows: [])
        let controller = makeController(
            prompt: prompt,
            capture: {
                captures.value += 1
                return CaptureOutcome(document: empty, report: .clean)
            }
        )
        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
            )
        )
        prompt.choice = .cancel
        prompt.whileFirstSaveChoiceIsUp = { [weak controller] in controller?.recapture() }

        _ = controller.windowShouldClose(try XCTUnwrap(controller.window))

        XCTAssertEqual(captures.value, 0, "the sweep must not run for a command that is refused")
        XCTAssertEqual(prompt.saveChoiceCalls, 1)
    }

    /// The Capture command from the menu or hotkey: the document goes into the editor, and the
    /// report is shown on top of it.
    func testOpeningACaptureThatLostAnAppExplainsIt() throws {
        var report = CaptureReport()
        report.skippedWindows = ["Safari": 1]
        let prompt = FakePrompt()
        let controller = makeController(prompt: prompt)

        controller.open(
            capture: CaptureOutcome(
                document: makeDocument(
                    name: "Untitled",
                    windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
                ),
                report: report
            )
        )

        XCTAssertEqual(controller.session.document.windows.map(\.title), ["GitHub"])
        XCTAssertEqual(prompt.reports.map(\.title), ["Some windows were not captured"])
        XCTAssertTrue(try XCTUnwrap(prompt.reports.first?.detail).contains("1 window of Safari"))
    }

    /// A capture the user declined — keeping their unsaved work — is not applied, so there is
    /// nothing to explain either.
    func testOpeningACaptureThatTheUserDeclinesShowsNoReport() {
        var report = CaptureReport()
        report.unreadableApps = ["Xcode"]
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
            capture: CaptureOutcome(
                document: makeDocument(
                    name: "Untitled",
                    windows: [savedWindow(bundleIdentifier: "com.apple.Preview", title: "Photo")]
                ),
                report: report
            )
        )

        XCTAssertEqual(controller.session.document.name, "Coding")
        XCTAssertTrue(prompt.reports.isEmpty)
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

    /// A global hotkey keeps firing while an `NSAlert` spins the run loop, and the Capture handler
    /// lands on the main actor inside it. Without a guard the capture opened a *second* save prompt
    /// on top of the close prompt and swapped the session out from under it, so the answer to the
    /// first prompt was applied to the wrong document: Discard threw the fresh capture away.
    func testACaptureArrivingWhileTheClosePromptIsUpIsRefusedAndTheAnswerAppliesToTheOriginalSession() throws {
        let prompt = FakePrompt()
        let beeps = Counter()
        let controller = makeController(prompt: prompt, beep: { beeps.value += 1 })
        let url = temporaryWorkspaceURL()
        controller.open(
            captured: makeDocument(
                name: "Coding",
                windows: [savedWindow(bundleIdentifier: "com.apple.Safari", title: "GitHub")]
            )
        )
        try controller.session.save(to: url)
        controller.session.document.name = "Coding Edited"
        let captured = makeDocument(
            name: "Untitled",
            windows: [savedWindow(bundleIdentifier: "com.apple.Preview", title: "Photo")]
        )
        prompt.choice = .discard
        prompt.whileFirstSaveChoiceIsUp = { [weak controller] in
            controller?.open(captured: captured)
        }

        XCTAssertTrue(controller.windowShouldClose(try XCTUnwrap(controller.window)))

        XCTAssertEqual(prompt.saveChoiceCalls, 1, "the capture must not open a second prompt on top of the first")
        XCTAssertEqual(controller.session.fileURL, url, "the answer applies to the document the prompt was about")
        XCTAssertEqual(controller.session.document.name, "Coding", "Discard reverts the original, not the capture")
        XCTAssertEqual(beeps.value, 1, "a refused command answers the keystroke rather than dying silently")
    }

    @MainActor
    private final class Counter {
        var value = 0
    }

    /// The sidebar names each recent by the `name` inside the file, which meant decoding up to
    /// twenty documents on the main thread every time the window became key. A file that has not
    /// changed since is not read again.
    func testTheRecentNameCacheReloadsOnlyWhenTheFileChanged() {
        let cache = RecentNameCache()
        let url = URL(fileURLWithPath: "/tmp/coding.snapdesk")
        let loads = Counter()
        let first = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(cache.name(for: url, modified: first, load: { loads.value += 1; return "Coding" }), "Coding")
        XCTAssertEqual(cache.name(for: url, modified: first, load: { loads.value += 1; return "Coding" }), "Coding")
        XCTAssertEqual(loads.value, 1, "an unchanged file is answered from the cache")

        let later = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(cache.name(for: url, modified: later, load: { loads.value += 1; return "Renamed" }), "Renamed")
        XCTAssertEqual(loads.value, 2)

        XCTAssertNil(cache.name(for: url, modified: nil, load: { loads.value += 1; return nil }))
        XCTAssertEqual(loads.value, 3, "a file whose date is unknown is always read")

        // And the unknown date evicted what was cached: the name may have changed while nobody
        // could tell, so the next read with a date must not answer from a stale entry.
        XCTAssertEqual(cache.name(for: url, modified: later, load: { loads.value += 1; return "Again" }), "Again")
        XCTAssertEqual(loads.value, 4)
    }

    func testPrepareForTerminationAllowsWhenClean() {
        let controller = makeController(prompt: FakePrompt())
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
        private(set) var saveChoiceCalls = 0
        /// Runs inside the first `saveChoice`, standing in for whatever the run loop delivers while
        /// a real `NSAlert` is modal — a global hotkey handler, above all.
        var whileFirstSaveChoiceIsUp: (() -> Void)?

        func saveChoice(documentName: String) -> EditorSaveChoice {
            saveChoiceCalls += 1
            if saveChoiceCalls == 1 {
                whileFirstSaveChoiceIsUp?()
            }
            return choice
        }

        func saveDestination(suggestedName: String) -> URL? { destination }

        func report(title: String, detail: String?) {
            reports.append(Report(title: title, detail: detail))
        }
    }

    /// Every controller in this file comes from here, so none can be built with the real
    /// `AppKitEditorPrompt` by accident: a regression in the dirty-state logic would then put a
    /// real `NSAlert` up and hang the run instead of failing it. It also closes the window the
    /// controller shows — `open` activates the app, and twenty tests each leaving a window on
    /// screen steals focus for the length of the suite.
    private func makeController(
        prompt: FakePrompt,
        capture: @escaping () -> CaptureOutcome? = { nil },
        beep: @escaping @MainActor () -> Void = {}
    ) -> EditorWindowController {
        let controller = EditorWindowController(
            recents: RecentsStore(defaults: scratchDefaults()),
            capture: capture,
            launch: { _ in },
            prompt: prompt,
            beep: beep
        )
        addTeardownBlock { @MainActor in controller.close() }
        return controller
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

