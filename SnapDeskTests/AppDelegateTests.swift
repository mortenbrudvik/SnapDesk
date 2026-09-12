import AppKit
import XCTest
@testable import SnapDesk

/// `AppDelegate` with every side effect replaced: the launch chain and queue, the trust gate, the
/// alerts, and the files handed over before launch finishes. `applicationDidFinishLaunching` is
/// never called — under XCTest it returns before doing anything anyway — so nothing here installs
/// a status item, registers a hot key, or prompts for Accessibility.
@MainActor
final class AppDelegateTests: XCTestCase {
    @MainActor
    private final class FakeRestorer: WorkspaceRestoring {
        private(set) var launched: [ValidatedWorkspace] = []
        private(set) var cancelCount = 0
        /// Parks every launch until `releaseAll()`, so a second restore can be queued behind it.
        var parkLaunches = false
        private var parked: [CheckedContinuation<Void, Never>] = []

        func launch(
            _ workspace: ValidatedWorkspace,
            onProgress: @MainActor @escaping ([SlotProgress]) -> Void
        ) async -> [SlotProgress] {
            launched.append(workspace)
            if parkLaunches {
                await withCheckedContinuation { parked.append($0) }
            }
            let result = workspace.document.windows.enumerated().map { index, window in
                SlotProgress(index: index, name: window.name, status: .placed(.clean))
            }
            onProgress(result)
            return result
        }

        func cancel() {
            cancelCount += 1
        }

        func releaseAll() {
            let waiting = parked
            parked = []
            for continuation in waiting {
                continuation.resume()
            }
        }
    }

    @MainActor
    private final class FakeHUD: LaunchHUDPresenting {
        var onCancel: (() -> Void)?
        private(set) var presented: [String] = []
        private(set) var updates: [[SlotProgress]] = []

        func present(title: String) { presented.append(title) }
        func update(_ slots: [SlotProgress]) { updates.append(slots) }
    }

    @MainActor
    private final class Recorder {
        var alerts: [(title: String, detail: String?)] = []
        var refusals: [String] = []
        var trusted = true
        var editorOpens: [CaptureOutcome?] = []
    }

    private struct Fixture {
        let delegate: AppDelegate
        let restorer: FakeRestorer
        let hud: FakeHUD
        let recents: RecentsStore
        let recorder: Recorder
        let shortcuts: WorkspaceShortcuts
        let library: WorkspaceLibrary
    }

    private func makeFixture(trusted: Bool = true, startupWorkspace: URL? = nil) -> Fixture {
        let restorer = FakeRestorer()
        let hud = FakeHUD()
        let recorder = Recorder()
        recorder.trusted = trusted
        let recents = RecentsStore(defaults: scratchDefaults())
        // Its own throwaway suite: under TEST_HOST, `.standard` is the shipping app's own domain.
        let shortcuts = WorkspaceShortcuts(defaults: scratchDefaults())
        let library = WorkspaceLibrary(defaults: scratchDefaults())
        let capture = CaptureOutcome(document: makeDocument(name: "Captured"), report: .clean)
        let delegate = AppDelegate(
            dependencies: AppDelegate.Dependencies(
                recents: recents,
                workspaceShortcuts: shortcuts,
                library: library,
                startupWorkspace: { startupWorkspace },
                capture: { capture },
                restorer: restorer,
                hud: hud,
                accessibilityTrusted: { recorder.trusted },
                refuseUntrusted: { recorder.refusals.append($0) },
                presentAlert: { title, detail in recorder.alerts.append((title, detail)) }
            )
        )
        delegate.editorOpener = { recorder.editorOpens.append($0) }
        return Fixture(
            delegate: delegate,
            restorer: restorer,
            hud: hud,
            recents: recents,
            recorder: recorder,
            shortcuts: shortcuts,
            library: library
        )
    }

    // MARK: Launching from a file

    func testALaunchFromAFileIsValidatedAddedToRecentsAndRestored() async throws {
        let fixture = makeFixture()
        let url = try writeWorkspace(makeDocument(name: "Coding"))

        fixture.delegate.launch(url: url)
        await fixture.delegate.launchChain?.value

        XCTAssertEqual(fixture.restorer.launched.map(\.document.name), ["Coding"])
        XCTAssertEqual(fixture.hud.presented, ["Coding"])
        // The progress the restore reports has to reach the HUD, or every row stays "Pending".
        XCTAssertEqual(
            fixture.hud.updates.last?.map(\.status),
            [.placed(.clean)],
            "the restore's progress must be forwarded to the HUD"
        )
        XCTAssertEqual(fixture.recents.urls.map(\.standardizedFileURL), [url.standardizedFileURL])
        XCTAssertTrue(fixture.recorder.alerts.isEmpty)
    }

    func testAnUntrustedLaunchIsRefusedBeforeTheFileIsTouched() throws {
        let fixture = makeFixture(trusted: false)
        let url = try writeWorkspace(makeDocument(name: "Coding"))

        fixture.delegate.launch(url: url)

        XCTAssertEqual(fixture.recorder.refusals, ["restore"])
        XCTAssertTrue(fixture.restorer.launched.isEmpty)
        XCTAssertTrue(fixture.recents.urls.isEmpty, "a refused launch is not a recent")
        XCTAssertNil(fixture.delegate.launchChain)
    }

    /// The alert names the file and carries the cause: with several files opened at once, an
    /// anonymous "Could not read this workspace" left the user guessing which one was broken.
    func testAMalformedFileIsExplainedByNameAndNotAddedToRecents() throws {
        let fixture = makeFixture()
        let url = try writeData(Data("{".utf8), named: "broken")

        fixture.delegate.launch(url: url)

        XCTAssertEqual(fixture.recorder.alerts.map(\.title), ["Could not open “\(url.lastPathComponent)”"])
        XCTAssertNotNil(fixture.recorder.alerts.first?.detail)
        XCTAssertTrue(fixture.restorer.launched.isEmpty)
        XCTAssertTrue(fixture.recents.urls.isEmpty)
    }

    func testAMissingFileIsExplainedByName() {
        let fixture = makeFixture()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).snapdesk")

        fixture.delegate.launch(url: url)

        XCTAssertEqual(fixture.recorder.alerts.map(\.title), ["Could not open “\(url.lastPathComponent)”"])
        XCTAssertEqual(fixture.recorder.alerts.map(\.detail), [WorkspaceOpener.missingFileDetail])
    }

    /// A workspace with no slots used to flash a HUD with no rows that dismissed itself 600ms
    /// later — indistinguishable from a glitch. It is told apart from a restore instead.
    func testAnEmptyWorkspaceIsExplainedInsteadOfFlashingTheHUD() async throws {
        let fixture = makeFixture()
        let url = try writeWorkspace(makeDocument(name: "Empty", windows: []))

        fixture.delegate.launch(url: url)
        await fixture.delegate.launchChain?.value

        XCTAssertEqual(fixture.recorder.alerts.map(\.title), ["“Empty” has no windows to restore"])
        XCTAssertTrue(fixture.hud.presented.isEmpty)
        XCTAssertTrue(fixture.restorer.launched.isEmpty)
    }

    // MARK: Launching from the editor

    func testAnInMemoryDocumentThatFailsValidationIsRejectedWithAnAlert() async {
        let fixture = makeFixture()
        var document = makeDocument(name: "Editing")
        document.windows[0].width = 0

        fixture.delegate.launch(document: document)
        await fixture.delegate.launchChain?.value

        XCTAssertEqual(fixture.recorder.alerts.map(\.title), ["Cannot restore “Editing”"])
        XCTAssertTrue(fixture.recorder.alerts[0].detail?.contains("Safari") == true, "the alert names the slot")
        XCTAssertTrue(fixture.restorer.launched.isEmpty)
    }

    // MARK: Chaining

    /// Two restores in quick succession run one after the other, and the HUD is presented for the
    /// second only once the first is done — presenting resets its rows, and the first restore is
    /// still writing to them.
    func testChainedRestoresPresentTheHUDInOrder() async {
        let fixture = makeFixture()
        fixture.restorer.parkLaunches = true

        fixture.delegate.launch(document: makeDocument(name: "A"))
        fixture.delegate.launch(document: makeDocument(name: "B"))
        await settle { fixture.restorer.launched.count == 1 }

        XCTAssertEqual(fixture.hud.presented, ["A"])
        XCTAssertEqual(fixture.restorer.launched.map(\.document.name), ["A"])

        fixture.restorer.parkLaunches = false
        fixture.restorer.releaseAll()
        await fixture.delegate.launchChain?.value

        XCTAssertEqual(fixture.hud.presented, ["A", "B"])
        XCTAssertEqual(fixture.restorer.launched.map(\.document.name), ["A", "B"])
    }

    /// A Cancel click reaches the running restore through the service and the queued one through
    /// the queue: it never called the service, so nothing else could stop it, and it would have
    /// re-opened the HUD moments after the user got rid of it.
    func testACancelStopsTheRunningRestoreAndAbandonsTheQueuedOne() async {
        let fixture = makeFixture()
        fixture.restorer.parkLaunches = true

        fixture.delegate.launch(document: makeDocument(name: "A"))
        fixture.delegate.launch(document: makeDocument(name: "B"))
        await settle { fixture.restorer.launched.count == 1 }

        fixture.hud.onCancel?()
        XCTAssertEqual(fixture.restorer.cancelCount, 1)

        fixture.restorer.parkLaunches = false
        fixture.restorer.releaseAll()
        await fixture.delegate.launchChain?.value

        XCTAssertEqual(fixture.hud.presented, ["A"], "the queued restore must not present after the cancel")
        XCTAssertEqual(fixture.restorer.launched.map(\.document.name), ["A"])

        // A restore started after the click is wanted again.
        fixture.delegate.launch(document: makeDocument(name: "C"))
        await fixture.delegate.launchChain?.value
        XCTAssertEqual(fixture.hud.presented, ["A", "C"])
    }

    // MARK: Files opened before launch finishes

    /// AppKit delivers a double-clicked file's open event before `applicationDidFinishLaunching`.
    /// Acting on it there would raise an alert with no status item and no hot keys behind it, in
    /// an app with no Dock icon to quit from — so the file waits until the app is wired.
    func testAFileOpenedBeforeLaunchFinishesIsHeldUntilItDoes() async throws {
        let fixture = makeFixture()
        let url = try writeWorkspace(makeDocument(name: "Coding"))

        fixture.delegate.application(NSApp, open: [url])

        XCTAssertTrue(fixture.restorer.launched.isEmpty)
        XCTAssertTrue(fixture.recorder.alerts.isEmpty)

        fixture.delegate.completeLaunch()
        await fixture.delegate.launchChain?.value

        XCTAssertEqual(fixture.restorer.launched.map(\.document.name), ["Coding"])
    }

    func testAFileOpenedAfterLaunchIsOpenedAtOnce() async throws {
        let fixture = makeFixture()
        fixture.delegate.completeLaunch()
        let url = try writeWorkspace(makeDocument(name: "Coding"))

        fixture.delegate.application(NSApp, open: [url])
        await fixture.delegate.launchChain?.value

        XCTAssertEqual(fixture.restorer.launched.map(\.document.name), ["Coding"])
    }

    // MARK: Capture

    func testCaptureHandsTheOutcomeToTheEditorAndIsRefusedUntrusted() {
        let fixture = makeFixture()

        fixture.delegate.captureToEditor()
        XCTAssertEqual(fixture.recorder.editorOpens.map { $0?.document.name }, ["Captured"])

        fixture.recorder.trusted = false
        fixture.delegate.captureToEditor()
        XCTAssertEqual(fixture.recorder.refusals, ["capture"])
        XCTAssertEqual(fixture.recorder.editorOpens.count, 1)
    }

    // MARK: Helpers

    /// Yields until `condition` holds, or fails after a bounded number of yields.
    private func settle(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }

    // MARK: The library

    /// Restoring records when, so the library can order by what the user actually uses. Where
    /// that date is *not* written — the workspace file — is pinned by WorkspaceLibraryTests.
    func testRestoringAWorkspaceRecordsWhenItWasLaunched() async throws {
        let url = try writeWorkspace(makeDocument(name: "Coding"))
        let fixture = makeFixture()

        fixture.delegate.launch(url: url)
        await fixture.delegate.launchChain?.value

        XCTAssertNotNil(fixture.library.lastLaunched(url))
    }

    /// A workspace that failed to open was never restored, so it gets no date. Otherwise the
    /// library would sort a file the user cannot even open to the top.
    func testAWorkspaceThatFailsToOpenIsNotRecordedAsLaunched() async throws {
        let url = try writeData(Data("not json".utf8), named: "broken")
        let fixture = makeFixture()

        fixture.delegate.launch(url: url)
        await fixture.delegate.launchChain?.value

        XCTAssertNil(fixture.library.lastLaunched(url))
    }

    // MARK: The startup workspace

    /// Drains through the same gate a double-clicked file uses, so a startup restore cannot begin
    /// before the status item and hot keys exist.
    func testAStartupWorkspaceIsRestoredOnceLaunchCompletes() async throws {
        let url = try writeWorkspace(makeDocument(name: "Coding"))
        let fixture = makeFixture(startupWorkspace: url)

        XCTAssertTrue(fixture.restorer.launched.isEmpty, "not before the app is wired")

        fixture.delegate.completeLaunch()
        await fixture.delegate.launchChain?.value

        XCTAssertEqual(fixture.restorer.launched.map(\.document.name), ["Coding"])
    }

    func testNoStartupWorkspaceRestoresNothing() async {
        let fixture = makeFixture()

        fixture.delegate.completeLaunch()
        await fixture.delegate.launchChain?.value

        XCTAssertTrue(fixture.restorer.launched.isEmpty)
        XCTAssertTrue(fixture.recorder.alerts.isEmpty)
    }

    /// A file the user double-clicked is why the app is launching at all, so it goes first — the
    /// startup workspace is the default for when nothing else was asked for.
    func testADoubleClickedFileIsRestoredBeforeTheStartupWorkspace() async throws {
        let startup = try writeWorkspace(makeDocument(name: "Startup"))
        let opened = try writeWorkspace(makeDocument(name: "Opened"))
        let fixture = makeFixture(startupWorkspace: startup)

        fixture.delegate.application(NSApp, open: [opened])
        fixture.delegate.completeLaunch()
        await fixture.delegate.launchChain?.value

        XCTAssertEqual(
            fixture.restorer.launched.map(\.document.name),
            ["Opened", "Startup"],
            "the file the user asked for comes first"
        )
    }

    /// A startup workspace whose file has since been deleted reports it, rather than leaving the
    /// user to wonder why nothing came back.
    func testAStartupWorkspaceWhoseFileIsGoneReportsIt() async throws {
        let url = try writeWorkspace(makeDocument(name: "Coding"))
        let fixture = makeFixture(startupWorkspace: url)
        try FileManager.default.removeItem(at: url)

        fixture.delegate.completeLaunch()
        await fixture.delegate.launchChain?.value

        XCTAssertTrue(fixture.restorer.launched.isEmpty)
        XCTAssertEqual(fixture.recorder.alerts.compactMap(\.detail), [WorkspaceOpener.missingFileDetail])
    }

    // MARK: Workspace hotkeys

    /// A workspace hotkey opens its workspace by exactly the path a double-clicked file takes:
    /// the same validation, the same recents entry, the same alerts.
    func testAWorkspaceHotkeyLaunchesTheWorkspaceBoundToItsSlot() async throws {
        let url = try writeWorkspace(makeDocument(name: "Coding"))
        let fixture = makeFixture()
        fixture.shortcuts.assign(url, to: 2)

        fixture.delegate.launchWorkspace(inSlot: 2)
        await fixture.delegate.launchChain?.value

        XCTAssertEqual(fixture.restorer.launched.map(\.document.name), ["Coding"])
    }

    /// An unassigned slot does nothing and says nothing. A key can be bound before a workspace
    /// is, and beeping at the user for pressing it would be noise, not information.
    func testAnUnassignedWorkspaceHotkeyDoesNothing() async {
        let fixture = makeFixture()

        fixture.delegate.launchWorkspace(inSlot: 0)
        await fixture.delegate.launchChain?.value

        XCTAssertTrue(fixture.restorer.launched.isEmpty)
        XCTAssertTrue(fixture.recorder.alerts.isEmpty, "an unassigned slot is not an error")
    }

    /// A workspace deleted since it was bound reports the same "could not be found" alert a stale
    /// recent does. Silence here would leave the user pressing a key that does nothing.
    func testAWorkspaceHotkeyWhoseFileIsGoneReportsIt() async throws {
        let url = try writeWorkspace(makeDocument(name: "Coding"))
        let fixture = makeFixture()
        fixture.shortcuts.assign(url, to: 1)
        try FileManager.default.removeItem(at: url)

        fixture.delegate.launchWorkspace(inSlot: 1)
        await fixture.delegate.launchChain?.value

        XCTAssertTrue(fixture.restorer.launched.isEmpty)
        XCTAssertEqual(fixture.recorder.alerts.compactMap(\.detail), [WorkspaceOpener.missingFileDetail])
    }

    private func scratchDefaults() -> UserDefaults {
        let name = "com.brudvik.snapdesk.tests.appdelegate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func writeWorkspace(_ document: WorkspaceDocument) throws -> URL {
        try writeData(try document.encoded(), named: document.name.lowercased())
    }

    private func writeData(_ data: Data, named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).snapdesk")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeDocument(name: String, windows: [SavedWindow]? = nil) -> WorkspaceDocument {
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
            windows: windows ?? [
                SavedWindow(
                    bundleIdentifier: "com.apple.Safari",
                    bundlePath: "/Applications/Safari.app",
                    name: "Safari",
                    title: "GitHub",
                    displayId: "display",
                    x: 0,
                    y: 0,
                    width: 800,
                    height: 600,
                    minimized: false,
                    zoomed: false,
                    arguments: ""
                ),
            ]
        )
    }
}
