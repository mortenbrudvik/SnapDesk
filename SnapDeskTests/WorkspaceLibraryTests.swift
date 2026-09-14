import XCTest
@testable import SnapDesk

@MainActor
final class WorkspaceLibraryTests: XCTestCase {
    private func scratchDefaults() -> UserDefaults {
        let name = "com.brudvik.snapdesk.tests.library.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func scratchFolder() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snapdesk-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @discardableResult
    private func write(_ name: String, in folder: URL, extension ext: String = "snapdesk") throws -> URL {
        let url = folder.appendingPathComponent("\(name).\(ext)")
        try Data("{}".utf8).write(to: url)
        return url
    }

    // MARK: Last launched

    /// The date is the point of the whole type, and where it lives is the design decision:
    /// PowerToys writes `lastLaunchedTime` into the workspace itself. Restoring a workspace must
    /// not modify the user's document — it would dirty version control, break a read-only file,
    /// and change a file they did not edit — so it lives in preferences instead.
    func testRecordingALaunchStoresADateThatSurvivesAReload() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        let url = try write("Coding", in: folder)
        let library = WorkspaceLibrary(defaults: defaults)

        XCTAssertNil(library.lastLaunched(url))

        let when = Date(timeIntervalSince1970: 1_700_000_000)
        library.recordLaunch(of: url, at: when)
        XCTAssertEqual(library.lastLaunched(url), when)

        XCTAssertEqual(WorkspaceLibrary(defaults: defaults).lastLaunched(url), when)
    }

    /// Recording again replaces the date rather than adding a second entry for the same file.
    func testRecordingTheSameWorkspaceTwiceKeepsOneEntryWithTheLaterDate() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        let url = try write("Coding", in: folder)
        let library = WorkspaceLibrary(defaults: defaults)

        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = first.addingTimeInterval(3_600)
        library.recordLaunch(of: url, at: first)
        library.recordLaunch(of: url, at: second)

        XCTAssertEqual(library.lastLaunched(url), second)
        XCTAssertEqual(WorkspaceLibrary(defaults: defaults).entryCount, 1)
    }

    /// The bookmark is why this is not just a dictionary keyed by path: a workspace the user
    /// renames keeps the history that belongs to it.
    func testADateFollowsAWorkspaceThatIsRenamed() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        let url = try write("Before", in: folder)
        let library = WorkspaceLibrary(defaults: defaults)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        library.recordLaunch(of: url, at: when)

        let renamed = folder.appendingPathComponent("After.snapdesk")
        try FileManager.default.moveItem(at: url, to: renamed)

        XCTAssertEqual(WorkspaceLibrary(defaults: defaults).lastLaunched(renamed), when)
    }

    /// Dates for files that are gone would accumulate forever otherwise: nothing ever deletes
    /// them, and the user never sees the list to tidy it.
    func testEntriesForWorkspacesThatNoLongerExistArePrunedOnLoad() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        let kept = try write("Kept", in: folder)
        let deleted = try write("Deleted", in: folder)
        let library = WorkspaceLibrary(defaults: defaults)
        library.recordLaunch(of: kept)
        library.recordLaunch(of: deleted)
        XCTAssertEqual(library.entryCount, 2)

        try FileManager.default.removeItem(at: deleted)

        let reloaded = WorkspaceLibrary(defaults: defaults)
        XCTAssertEqual(reloaded.entryCount, 1)
        XCTAssertNotNil(reloaded.lastLaunched(kept))
        XCTAssertNil(reloaded.lastLaunched(deleted))
    }

    /// A restore must never write to the workspace file. This is the test that would catch it.
    func testRecordingALaunchDoesNotTouchTheWorkspaceFile() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        let url = try write("Coding", in: folder)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let contentsBefore = try Data(contentsOf: url)

        WorkspaceLibrary(defaults: defaults).recordLaunch(of: url)

        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), contentsBefore, "the document must be unchanged")
        XCTAssertEqual(
            before[.modificationDate] as? Date,
            after[.modificationDate] as? Date,
            "not even the modification date may move"
        )
    }

    // MARK: The folder

    /// Only workspaces, and only from the folder itself. A folder the user nominates is very
    /// likely a project directory with plenty else in it.
    func testScanningAFolderListsEveryWorkspaceAndNothingElse() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        try write("Coding", in: folder)
        try write("Writing", in: folder)
        try write("notes", in: folder, extension: "txt")
        try write("Archive", in: folder, extension: "snapdesk.bak")
        let library = WorkspaceLibrary(defaults: defaults)
        library.folder = folder

        let names = library.listing(recents: []).map(\.name)

        XCTAssertEqual(names.sorted(), ["Coding", "Writing"])
    }

    /// Without a folder the listing holds exactly the recents — the same set the sidebar showed
    /// before any of this existed; the order is the library's, pinned below.
    func testWithNoFolderTheListingIsJustRecents() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        let recent = try write("Coding", in: folder)
        let library = WorkspaceLibrary(defaults: defaults)

        XCTAssertEqual(library.listing(recents: [recent]).map(\.name), ["Coding"])
    }

    /// A workspace that is both in the folder and in recents is one workspace. Two rows with one
    /// identity is the bug this prevents.
    func testAWorkspaceInBothTheFolderAndRecentsAppearsOnce() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        let shared = try write("Coding", in: folder)
        let elsewhere = try scratchFolder()
        let other = try write("Writing", in: elsewhere)
        let library = WorkspaceLibrary(defaults: defaults)
        library.folder = folder

        let listing = library.listing(recents: [shared, other])

        XCTAssertEqual(listing.map(\.name).sorted(), ["Coding", "Writing"])
        XCTAssertEqual(listing.count, 2)
    }

    /// Most recently restored first, because that is what the user reaches for. Never-restored
    /// workspaces go last in name order rather than in whatever order the file system listed
    /// them, which is arbitrary and changes.
    func testTheListingPutsTheMostRecentlyLaunchedFirstAndTheRestByName() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        let old = try write("Old", in: folder)
        let recent = try write("Recent", in: folder)
        try write("Zebra", in: folder)
        try write("Apple", in: folder)
        let library = WorkspaceLibrary(defaults: defaults)
        library.folder = folder
        library.recordLaunch(of: old, at: Date(timeIntervalSince1970: 1_000))
        library.recordLaunch(of: recent, at: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(library.listing(recents: []).map(\.name), ["Recent", "Old", "Apple", "Zebra"])
    }

    /// The chosen folder is remembered across launches, or it would have to be picked every time.
    func testTheChosenFolderSurvivesAReload() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        try write("Coding", in: folder)
        let library = WorkspaceLibrary(defaults: defaults)
        library.folder = folder

        let reloaded = WorkspaceLibrary(defaults: defaults)
        // Compared by path: a directory URL resolved from a bookmark carries a trailing slash
        // that the URL it was made from does not, and the two are the same folder.
        XCTAssertEqual(reloaded.folder?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        XCTAssertEqual(reloaded.listing(recents: []).map(\.name), ["Coding"])
    }

    /// A folder that has been deleted or unmounted yields nothing rather than trapping, and the
    /// recents still list.
    func testAFolderThatIsGoneLeavesRecentsListing() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        try write("Coding", in: folder)
        let elsewhere = try scratchFolder()
        let recent = try write("Writing", in: elsewhere)
        let library = WorkspaceLibrary(defaults: defaults)
        library.folder = folder
        try FileManager.default.removeItem(at: folder)

        XCTAssertEqual(library.listing(recents: [recent]).map(\.name), ["Writing"])
    }

    /// The listing carries the date so the sidebar can show it without asking a second time.
    func testTheListingCarriesTheLastLaunchedDate() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        let url = try write("Coding", in: folder)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let library = WorkspaceLibrary(defaults: defaults)
        library.folder = folder
        library.recordLaunch(of: url, at: when)

        XCTAssertEqual(library.listing(recents: []).first?.lastLaunched, when)
    }

    // MARK: Persisted form

    /// The rewrite `WorkspaceBookmark.resolve` asks for has to reach defaults, or the same stale
    /// bookmark is resolved on every launch and the fallback path names a file that is gone.
    func testARenamedWorkspaceHasItsNewPathPersistedAfterAReload() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        let url = try write("Before", in: folder)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        WorkspaceLibrary(defaults: defaults).recordLaunch(of: url, at: when)

        let renamed = folder.appendingPathComponent("After.snapdesk")
        try FileManager.default.moveItem(at: url, to: renamed)
        XCTAssertEqual(WorkspaceLibrary(defaults: defaults).lastLaunched(renamed), when)

        let paths = try XCTUnwrap(defaults.array(forKey: "libraryPaths") as? [String])
        XCTAssertEqual(paths.map { URL(fileURLWithPath: $0).lastPathComponent }, ["After.snapdesk"])
        // And the refreshed bookmark keeps following the file through a second move.
        let again = folder.appendingPathComponent("Again.snapdesk")
        try FileManager.default.moveItem(at: renamed, to: again)
        XCTAssertEqual(WorkspaceLibrary(defaults: defaults).lastLaunched(again), when)
    }

    /// The nominated folder's setting follows the same rule.
    func testARenamedFolderHasItsNewPathPersisted() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        try write("Coding", in: folder)
        WorkspaceLibrary(defaults: defaults).folder = folder
        let renamed = folder.deletingLastPathComponent()
            .appendingPathComponent("snapdesk-library-renamed-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: folder, to: renamed)
        addTeardownBlock { try? FileManager.default.removeItem(at: renamed) }

        let reloaded = WorkspaceLibrary(defaults: defaults)
        XCTAssertEqual(reloaded.listing(recents: []).map(\.name), ["Coding"])
        XCTAssertEqual(
            URL(fileURLWithPath: defaults.string(forKey: "libraryFolderPath") ?? "").lastPathComponent,
            renamed.lastPathComponent
        )
    }

    /// Three arrays that disagree in length are read as the entries they agree on and written back
    /// in step, so the disagreement is not carried to the next launch.
    func testRaggedArraysInDefaultsLoadAsTheEntriesTheyAgreeOnAndAreRewritten() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        let a = try write("A", in: folder)
        let b = try write("B", in: folder)
        let library = WorkspaceLibrary(defaults: defaults)
        library.recordLaunch(of: a, at: Date(timeIntervalSince1970: 1_000))
        library.recordLaunch(of: b, at: Date(timeIntervalSince1970: 2_000))
        // Drop the last date, as a hand edit or a crash between the three writes could.
        defaults.set([Date(timeIntervalSince1970: 1_000)], forKey: "libraryDates")

        let reloaded = WorkspaceLibrary(defaults: defaults)

        XCTAssertEqual(reloaded.entryCount, 1)
        XCTAssertEqual(reloaded.lastLaunched(a), Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual((defaults.array(forKey: "libraryPaths") as? [String])?.count, 1)
        XCTAssertEqual((defaults.array(forKey: "libraryBookmarks") as? [Data])?.count, 1)
    }

    /// Pruning is written back too, or every launch prunes the same entries again.
    func testPruningADeletedWorkspaceIsWrittenBack() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        let kept = try write("Kept", in: folder)
        let deleted = try write("Deleted", in: folder)
        let library = WorkspaceLibrary(defaults: defaults)
        library.recordLaunch(of: kept)
        library.recordLaunch(of: deleted)
        try FileManager.default.removeItem(at: deleted)

        _ = WorkspaceLibrary(defaults: defaults)

        XCTAssertEqual((defaults.array(forKey: "libraryPaths") as? [String])?.count, 1)
        XCTAssertEqual((defaults.array(forKey: "libraryDates") as? [Date])?.count, 1)
    }

    /// The editor's Move to Trash clears the date too; the file is gone and so is its history.
    func testForgettingAWorkspaceDropsItsDate() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        let url = try write("Coding", in: folder)
        let library = WorkspaceLibrary(defaults: defaults)
        library.recordLaunch(of: url)

        library.forget(url)

        XCTAssertNil(library.lastLaunched(url))
        XCTAssertNil(WorkspaceLibrary(defaults: defaults).lastLaunched(url), "and it stays gone")
    }

    /// Without a folder the listing is the recents list as a set — but in the library's order,
    /// most recently restored first and then by name, which is not the store's most-recently-
    /// opened order. Two elements, because one cannot tell the two orders apart.
    func testWithNoFolderTheListingIsTheRecentsOrderedForTheSidebar() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        let restored = try write("Restored", in: folder)
        let opened = try write("Opened", in: folder)
        let library = WorkspaceLibrary(defaults: defaults)
        library.recordLaunch(of: restored, at: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(
            library.listing(recents: [opened, restored]).map(\.name),
            ["Restored", "Opened"]
        )
    }

    /// The sidebar has to be able to say that a folder is nominated but cannot be read right now,
    /// which is not the same as an empty one.
    func testAFolderThatCannotBeReadIsReportedAsUnavailable() throws {
        let defaults = scratchDefaults()
        let folder = try scratchFolder()
        let library = WorkspaceLibrary(defaults: defaults)
        XCTAssertEqual(library.folderAvailability(), .none)

        library.folder = folder
        guard case .listed(let listed) = library.folderAvailability() else {
            return XCTFail("a readable folder is listed")
        }
        XCTAssertEqual(listed.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)

        try FileManager.default.removeItem(at: folder)
        guard case .unavailable(let missing) = library.folderAvailability() else {
            return XCTFail("a deleted folder is unavailable, not none: the setting stays")
        }
        XCTAssertEqual(missing.lastPathComponent, folder.lastPathComponent)
    }
}
