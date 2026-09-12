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

    /// Without a folder the listing is exactly the recents list, which is what the sidebar showed
    /// before any of this existed.
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
}
