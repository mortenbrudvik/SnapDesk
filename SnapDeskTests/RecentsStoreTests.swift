import XCTest
@testable import SnapDesk

@MainActor
final class RecentsStoreTests: XCTestCase {
    private func scratchDefaults() -> UserDefaults {
        let name = "com.brudvik.snapdesk.tests.recents.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeTempFile(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).snapdesk")
        try Data("test".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAddOrdersMostRecentFirstAndPersistsAcrossReload() throws {
        let defaults = scratchDefaults()
        let first = try makeTempFile(named: "first")
        let second = try makeTempFile(named: "second")

        let store = RecentsStore(defaults: defaults)
        store.add(first)
        store.add(second)

        XCTAssertEqual(store.urls, [second, first])

        store.remove(first)

        let reloaded = RecentsStore(defaults: defaults)
        XCTAssertEqual(reloaded.urls.map(\.standardizedFileURL), [second.standardizedFileURL])
    }

    func testAddExistingURLMovesItToFront() throws {
        let defaults = scratchDefaults()
        let first = try makeTempFile(named: "first")
        let second = try makeTempFile(named: "second")

        let store = RecentsStore(defaults: defaults)
        store.add(first)
        store.add(second)
        store.add(first)

        XCTAssertEqual(store.urls.first, first)
        XCTAssertEqual(store.urls, [first, second])
    }

    func testCapKeepsTheTwentyNewestAndDropsTheOldest() throws {
        let defaults = scratchDefaults()
        let store = RecentsStore(defaults: defaults)

        var added: [URL] = []
        for i in 0..<21 {
            let url = try makeTempFile(named: "file-\(i)")
            added.append(url)
            store.add(url)
        }

        XCTAssertEqual(store.urls.count, 20)
        XCTAssertEqual(store.urls.map(\.path), added.dropFirst().reversed().map(\.path))
        XCTAssertFalse(
            store.urls.contains { $0.path == added[0].path },
            "the oldest entry is the one the cap drops"
        )
    }

    /// The cap has to hold on load too: a defaults dictionary that already holds more than twenty
    /// entries would otherwise stay oversized until the next `add` happened to trim it.
    func testLoadTrimsAnOversizedListAndWritesTheTrimBack() {
        let defaults = scratchDefaults()
        // Seeded through the raw keys `persist` writes, newest first, with no bookmarks — the
        // shape an older build or a hand-edited plist leaves behind.
        let paths = (0..<25).map { "/tmp/snapdesk-recent-\($0).snapdesk" }
        defaults.set(paths, forKey: "recentsPaths")

        let store = RecentsStore(defaults: defaults)

        XCTAssertEqual(store.urls.map(\.path), Array(paths.prefix(20)))
        XCTAssertEqual(
            defaults.array(forKey: "recentsPaths") as? [String],
            Array(paths.prefix(20)),
            "the trim must be persisted, not just held in memory"
        )
    }

    /// Two entries can resolve to the same file — one deleted and another renamed into its place —
    /// and `add` dedupes but `load` did not, so the sidebar got two rows with the same identity.
    func testLoadDedupesEntriesThatResolveToTheSameFileAndWritesTheTrimBack() throws {
        let defaults = scratchDefaults()
        let url = try makeTempFile(named: "twice")
        defaults.set([url.path, url.path], forKey: "recentsPaths")

        let store = RecentsStore(defaults: defaults)

        XCTAssertEqual(store.urls.count, 1)
        XCTAssertEqual(defaults.array(forKey: "recentsPaths") as? [String], [url.path])
    }

    /// The bookmark exists so a renamed file keeps resolving; the path is only the fallback.
    func testARenamedFileIsStillFoundThroughItsBookmark() throws {
        let defaults = scratchDefaults()
        let original = try makeTempFile(named: "before")
        let renamed = original.deletingLastPathComponent()
            .appendingPathComponent("after-\(UUID().uuidString).snapdesk")
        addTeardownBlock { try? FileManager.default.removeItem(at: renamed) }
        let store = RecentsStore(defaults: defaults)
        store.add(original)

        try FileManager.default.moveItem(at: original, to: renamed)
        let reloaded = RecentsStore(defaults: defaults)

        XCTAssertEqual(reloaded.urls.map { $0.resolvingSymlinksInPath().path }, [renamed.resolvingSymlinksInPath().path])
        XCTAssertEqual(
            (defaults.array(forKey: "recentsPaths") as? [String])?.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [renamed.resolvingSymlinksInPath().path],
            "the path fallback is rewritten to where the file is now"
        )
    }

    func testMissingFilesRemainListed() throws {
        let defaults = scratchDefaults()
        let url = try makeTempFile(named: "gone")

        let store = RecentsStore(defaults: defaults)
        store.add(url)
        try FileManager.default.removeItem(at: url)

        let reloaded = RecentsStore(defaults: defaults)
        XCTAssertEqual(reloaded.urls.count, 1)
        XCTAssertEqual(
            reloaded.urls[0].resolvingSymlinksInPath().path,
            url.resolvingSymlinksInPath().path
        )
    }

    func testReloadThenReAddDoesNotDuplicateAndRemoveWorks() throws {
        let defaults = scratchDefaults()
        let first = try makeTempFile(named: "first")
        let second = try makeTempFile(named: "second")

        let store = RecentsStore(defaults: defaults)
        store.add(first)
        store.add(second)

        let reloaded = RecentsStore(defaults: defaults)
        XCTAssertEqual(reloaded.urls.count, 2)
        // Prefer the symlink case (/var vs /private/var) when the environment provides it.
        if second.path != second.resolvingSymlinksInPath().path {
            XCTAssertNotEqual(reloaded.urls[0].path, second.path)
        }

        reloaded.add(second)
        XCTAssertEqual(reloaded.urls.count, 2, "re-add after reload must not duplicate")
        XCTAssertEqual(reloaded.urls[0].resolvingSymlinksInPath().path, second.resolvingSymlinksInPath().path)

        reloaded.remove(first)
        XCTAssertEqual(reloaded.urls.count, 1)
        XCTAssertEqual(reloaded.urls[0].resolvingSymlinksInPath().path, second.resolvingSymlinksInPath().path)
    }
}
