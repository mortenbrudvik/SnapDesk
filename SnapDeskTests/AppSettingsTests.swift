import XCTest
import ServiceManagement
@testable import SnapDesk

@MainActor
final class AppSettingsTests: XCTestCase {
    private final class FakeLoginItems: LoginItemService {
        var status: SMAppService.Status = .notRegistered
        var statusAfterRegister: SMAppService.Status = .enabled
        var registerError: Error?
        var unregisterError: Error?
        var registerCalls = 0
        var unregisterCalls = 0

        func register() throws {
            registerCalls += 1
            if let registerError { throw registerError }
            status = statusAfterRegister
        }

        func unregister() throws {
            unregisterCalls += 1
            if let unregisterError { throw unregisterError }
            status = .notRegistered
        }
    }

    private struct Failure: Error {}

    func testFailedRegistrationRollsTheToggleBackOnceWithoutRecursing() {
        let fake = FakeLoginItems()
        fake.registerError = Failure()
        fake.unregisterError = Failure()
        let settings = AppSettings(loginItems: fake)

        settings.launchAtLogin = true

        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertEqual(fake.unregisterCalls, 0, "rollback must not fire the observer again")
        XCTAssertNotNil(settings.loginItemMessage)
    }

    func testRegistrationThatNeedsApprovalKeepsTheToggleOnAndExplains() {
        let fake = FakeLoginItems()
        fake.statusAfterRegister = .requiresApproval
        let settings = AppSettings(loginItems: fake)

        settings.launchAtLogin = true

        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(settings.loginItemStatus, .requiresApproval)
        XCTAssertTrue(settings.loginItemMessage?.contains("Login Items") == true, "\(String(describing: settings.loginItemMessage))")
        XCTAssertTrue(settings.loginItemMessage?.contains("SnapDesk") == true, "\(String(describing: settings.loginItemMessage))")
    }

    func testSuccessfulRegistrationClearsAnyMessage() {
        let fake = FakeLoginItems()
        let settings = AppSettings(loginItems: fake)

        settings.launchAtLogin = true

        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertNil(settings.loginItemMessage)
        XCTAssertEqual(fake.registerCalls, 1)
    }

    /// `SMAppService` is the source of truth and the user can change it in System Settings while
    /// the pane is open — approve the item, or remove it. Both values were computed once in `init`,
    /// so the pane kept telling the user to approve an item they had approved, forever.
    func testRefreshReReadsTheLoginItemStatusWithoutWritingIt() {
        let fake = FakeLoginItems()
        fake.statusAfterRegister = .requiresApproval
        let settings = AppSettings(loginItems: fake)
        settings.launchAtLogin = true
        XCTAssertNotNil(settings.loginItemMessage)

        fake.status = .enabled
        settings.refresh()

        XCTAssertNil(settings.loginItemMessage, "the approval message goes away once the user has approved")
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(fake.registerCalls, 1, "a refresh reads; it must never register again")

        fake.status = .notRegistered
        settings.refresh()

        XCTAssertFalse(settings.launchAtLogin, "the toggle follows an item removed in System Settings")
        XCTAssertEqual(fake.unregisterCalls, 0, "and mirroring that is not an unregister")
    }

    func testTurningOffUnregisters() {
        let fake = FakeLoginItems()
        fake.status = .enabled
        let settings = AppSettings(loginItems: fake)
        XCTAssertTrue(settings.launchAtLogin, "initial state mirrors the service")

        settings.launchAtLogin = false

        XCTAssertEqual(fake.unregisterCalls, 1)
        XCTAssertFalse(settings.launchAtLogin)
    }

    // MARK: Workspace shortcuts

    private func scratchDefaults() -> UserDefaults {
        let name = "com.brudvik.snapdesk.tests.shortcuts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    /// A real file on disk, because a bookmark cannot be made for one that does not exist.
    private func writeWorkspaceFile(named name: String = "Coding") throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snapdesk-shortcuts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("\(name).snapdesk")
        try Data("{}".utf8).write(to: url)
        return url
    }

    func testASlotStartsEmptyAndAnAssignmentSurvivesAReload() throws {
        let defaults = scratchDefaults()
        let url = try writeWorkspaceFile()
        let shortcuts = WorkspaceShortcuts(defaults: defaults)

        XCTAssertNil(shortcuts.workspace(for: 0))

        shortcuts.assign(url, to: 0)
        XCTAssertEqual(shortcuts.workspace(for: 0)?.resolvingSymlinksInPath(), url.resolvingSymlinksInPath())

        let reloaded = WorkspaceShortcuts(defaults: defaults)
        XCTAssertEqual(reloaded.workspace(for: 0)?.resolvingSymlinksInPath(), url.resolvingSymlinksInPath())
    }

    func testClearingASlotRemovesTheBinding() throws {
        let defaults = scratchDefaults()
        let url = try writeWorkspaceFile()
        let shortcuts = WorkspaceShortcuts(defaults: defaults)
        shortcuts.assign(url, to: 2)
        XCTAssertNotNil(shortcuts.workspace(for: 2))

        shortcuts.assign(nil, to: 2)

        XCTAssertNil(shortcuts.workspace(for: 2))
        XCTAssertNil(WorkspaceShortcuts(defaults: defaults).workspace(for: 2), "and it stays cleared")
    }

    /// Assigning one slot must not disturb another: they are five independent bindings stored
    /// side by side.
    func testSlotsAreIndependentOfEachOther() throws {
        let defaults = scratchDefaults()
        let first = try writeWorkspaceFile(named: "First")
        let last = try writeWorkspaceFile(named: "Last")
        let shortcuts = WorkspaceShortcuts(defaults: defaults)

        shortcuts.assign(first, to: 0)
        shortcuts.assign(last, to: WorkspaceShortcuts.slotCount - 1)

        XCTAssertEqual(shortcuts.workspace(for: 0)?.lastPathComponent, "First.snapdesk")
        XCTAssertEqual(shortcuts.workspace(for: WorkspaceShortcuts.slotCount - 1)?.lastPathComponent, "Last.snapdesk")
        for slot in 1..<(WorkspaceShortcuts.slotCount - 1) {
            XCTAssertNil(shortcuts.workspace(for: slot))
        }
    }

    /// The bookmark is what makes this worth more than storing a path: a workspace the user
    /// renames keeps its hotkey. Without it the slot would point at a file that is gone and the
    /// key would start reporting "could not be found".
    func testAnAssignedWorkspaceIsStillFoundAfterItIsRenamed() throws {
        let defaults = scratchDefaults()
        let url = try writeWorkspaceFile(named: "Before")
        let shortcuts = WorkspaceShortcuts(defaults: defaults)
        shortcuts.assign(url, to: 1)

        let renamed = url.deletingLastPathComponent().appendingPathComponent("After.snapdesk")
        try FileManager.default.moveItem(at: url, to: renamed)

        let reloaded = WorkspaceShortcuts(defaults: defaults)
        XCTAssertEqual(reloaded.workspace(for: 1)?.lastPathComponent, "After.snapdesk")
    }

    /// A slot index from outside the fixed range is ignored rather than trapping: the value can
    /// reach here from a stored preference an older or newer build wrote.
    func testAnOutOfRangeSlotIsIgnored() throws {
        let defaults = scratchDefaults()
        let url = try writeWorkspaceFile()
        let shortcuts = WorkspaceShortcuts(defaults: defaults)

        shortcuts.assign(url, to: WorkspaceShortcuts.slotCount)
        shortcuts.assign(url, to: -1)

        XCTAssertNil(shortcuts.workspace(for: WorkspaceShortcuts.slotCount))
        XCTAssertNil(shortcuts.workspace(for: -1))
        for slot in 0..<WorkspaceShortcuts.slotCount {
            XCTAssertNil(shortcuts.workspace(for: slot), "nothing may have been written into a real slot")
        }
    }

    // MARK: The Trash

    /// Measured on this machine: a minimal bookmark follows a file into the Trash and resolves
    /// there, stale. Left alone, the key would restore a workspace the user deleted and the slot
    /// would be rewritten to point into the Trash. The slot has to answer as if the file were
    /// gone — its old path, which no longer exists, so the launch path reports it. Puts one file
    /// in the real Trash for the length of the test and removes it again.
    func testAWorkspaceMovedToTheTrashIsReportedMissingRatherThanFound() throws {
        let defaults = scratchDefaults()
        let url = try writeWorkspaceFile(named: "Trashed-\(UUID().uuidString)")
        let shortcuts = WorkspaceShortcuts(defaults: defaults)
        shortcuts.assign(url, to: 0)
        try trash(url)

        let answer = try XCTUnwrap(shortcuts.workspace(for: 0))

        XCTAssertEqual(answer.path, url.path, "the slot falls back to where the file was")
        XCTAssertFalse(FileManager.default.fileExists(atPath: answer.path))
        let persisted = try XCTUnwrap(defaults.array(forKey: "workspaceShortcutPaths") as? [String])
        XCTAssertFalse(persisted[0].contains("/.Trash/"), "the binding must not be rewritten into the Trash")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: WorkspaceShortcuts(defaults: defaults).workspace(for: 0)?.path ?? "/nonexistent"
            ),
            "a reload must not resurrect it either"
        )
    }

    func testAStartupWorkspaceMovedToTheTrashIsNotFound() throws {
        let defaults = scratchDefaults()
        let url = try writeWorkspaceFile(named: "Trashed-\(UUID().uuidString)")
        let settings = AppSettings(loginItems: FakeLoginItems(), defaults: defaults)
        settings.startupWorkspace = url
        try trash(url)

        let answer = try XCTUnwrap(settings.startupWorkspace)

        XCTAssertEqual(answer.path, url.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: answer.path))
        XCTAssertFalse((defaults.string(forKey: "startupWorkspacePath") ?? "").contains("/.Trash/"))
    }

    /// Moves the file to the Trash and removes it from there when the test ends.
    private func trash(_ url: URL) throws {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        let item = trashed as URL?
        addTeardownBlock {
            if let item { try? FileManager.default.removeItem(at: item) }
        }
    }

    // MARK: Persisted form

    /// The rewrite `WorkspaceBookmark.resolve` asks for has to reach defaults, or the same stale
    /// bookmark is resolved on every launch and the fallback path names a file that is gone.
    func testARenamedWorkspaceHasItsNewPathPersistedInItsSlot() throws {
        let defaults = scratchDefaults()
        let url = try writeWorkspaceFile(named: "Before")
        WorkspaceShortcuts(defaults: defaults).assign(url, to: 1)
        let renamed = url.deletingLastPathComponent().appendingPathComponent("After.snapdesk")
        try FileManager.default.moveItem(at: url, to: renamed)

        let reloaded = WorkspaceShortcuts(defaults: defaults)
        XCTAssertEqual(reloaded.workspace(for: 1)?.lastPathComponent, "After.snapdesk")

        let paths = try XCTUnwrap(defaults.array(forKey: "workspaceShortcutPaths") as? [String])
        XCTAssertEqual(
            URL(fileURLWithPath: paths[1]).lastPathComponent,
            "After.snapdesk",
            "the fallback path follows the file"
        )
    }

    /// A short array from an older build, or a hand-edited one, still means five slots.
    func testAShortSlotArrayFromAnOlderBuildStillLoadsFiveSlots() throws {
        let defaults = scratchDefaults()
        let first = try writeWorkspaceFile(named: "First")
        let last = try writeWorkspaceFile(named: "Last")
        let bookmark = try first.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set([bookmark], forKey: "workspaceShortcutBookmarks")
        defaults.set([first.path], forKey: "workspaceShortcutPaths")

        let shortcuts = WorkspaceShortcuts(defaults: defaults)
        XCTAssertEqual(shortcuts.workspace(for: 0)?.lastPathComponent, "First.snapdesk")
        for slot in 1..<WorkspaceShortcuts.slotCount {
            XCTAssertNil(shortcuts.workspace(for: slot))
        }

        shortcuts.assign(last, to: WorkspaceShortcuts.slotCount - 1)
        XCTAssertEqual(
            (defaults.array(forKey: "workspaceShortcutPaths") as? [String])?.count,
            WorkspaceShortcuts.slotCount
        )
        XCTAssertEqual(
            (defaults.array(forKey: "workspaceShortcutBookmarks") as? [Data])?.count,
            WorkspaceShortcuts.slotCount
        )
    }

    // MARK: The startup workspace

    func testTheStartupWorkspaceSurvivesAReloadAndClearsToNil() throws {
        let defaults = scratchDefaults()
        let url = try writeWorkspaceFile()
        let settings = AppSettings(loginItems: FakeLoginItems(), defaults: defaults)
        XCTAssertNil(settings.startupWorkspace)

        settings.startupWorkspace = url
        XCTAssertEqual(
            AppSettings(loginItems: FakeLoginItems(), defaults: defaults).startupWorkspace?
                .resolvingSymlinksInPath().path,
            url.resolvingSymlinksInPath().path
        )

        settings.startupWorkspace = nil
        XCTAssertNil(AppSettings(loginItems: FakeLoginItems(), defaults: defaults).startupWorkspace)
    }

    func testARenamedStartupWorkspaceHasItsNewPathPersisted() throws {
        let defaults = scratchDefaults()
        let url = try writeWorkspaceFile(named: "Before")
        AppSettings(loginItems: FakeLoginItems(), defaults: defaults).startupWorkspace = url
        let renamed = url.deletingLastPathComponent().appendingPathComponent("After.snapdesk")
        try FileManager.default.moveItem(at: url, to: renamed)

        let reloaded = AppSettings(loginItems: FakeLoginItems(), defaults: defaults)
        XCTAssertEqual(reloaded.startupWorkspace?.lastPathComponent, "After.snapdesk")
        XCTAssertEqual(
            URL(fileURLWithPath: defaults.string(forKey: "startupWorkspacePath") ?? "").lastPathComponent,
            "After.snapdesk"
        )
    }

    // MARK: Forgetting a trashed workspace

    /// Trashing a workspace in the editor clears it here too, but only when it is that file.
    func testForgettingTheStartupWorkspaceClearsItOnlyForTheSameFile() throws {
        let defaults = scratchDefaults()
        let chosen = try writeWorkspaceFile(named: "Chosen")
        let other = try writeWorkspaceFile(named: "Other")
        let settings = AppSettings(loginItems: FakeLoginItems(), defaults: defaults)
        settings.startupWorkspace = chosen

        settings.forgetStartupWorkspace(other)
        XCTAssertEqual(settings.startupWorkspace?.lastPathComponent, "Chosen.snapdesk")

        settings.forgetStartupWorkspace(chosen)
        XCTAssertNil(settings.startupWorkspace)
        XCTAssertNil(AppSettings(loginItems: FakeLoginItems(), defaults: defaults).startupWorkspace)
    }

    /// A slot bound to a file the editor then trashes is cleared, and the other slots are not.
    func testForgettingAWorkspaceClearsEverySlotBoundToIt() throws {
        let defaults = scratchDefaults()
        let gone = try writeWorkspaceFile(named: "Gone")
        let kept = try writeWorkspaceFile(named: "Kept")
        let shortcuts = WorkspaceShortcuts(defaults: defaults)
        shortcuts.assign(gone, to: 0)
        shortcuts.assign(kept, to: 1)
        shortcuts.assign(gone, to: 4)

        shortcuts.forget(gone)

        XCTAssertNil(shortcuts.workspace(for: 0))
        XCTAssertEqual(shortcuts.workspace(for: 1)?.lastPathComponent, "Kept.snapdesk")
        XCTAssertNil(shortcuts.workspace(for: 4))
        XCTAssertNil(WorkspaceShortcuts(defaults: defaults).workspace(for: 0), "and it stays cleared")
    }
}
