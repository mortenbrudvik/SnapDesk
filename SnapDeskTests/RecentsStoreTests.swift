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

    func testCapIsTwenty() throws {
        let defaults = scratchDefaults()
        let store = RecentsStore(defaults: defaults)

        for i in 0..<21 {
            store.add(try makeTempFile(named: "file-\(i)"))
        }

        XCTAssertEqual(store.urls.count, 20)
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
