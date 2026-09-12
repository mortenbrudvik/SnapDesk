import Foundation

/// When each workspace was last restored, and — with a folder nominated — every workspace the
/// user owns rather than only the ones they opened lately.
///
/// The date lives here, in preferences, and deliberately not in the `.snapdesk` file. PowerToys
/// writes `lastLaunchedTime` into the workspace itself; doing that would mean a restore modifies
/// the user's document, which dirties version control, fails outright on a read-only file, and
/// changes a file they did not edit. A workspace is a document, and restoring one is a read.
@MainActor
final class WorkspaceLibrary {
    private enum Key {
        static let bookmarks = "libraryBookmarks"
        static let paths = "libraryPaths"
        static let dates = "libraryDates"
    }

    /// One remembered workspace: where it is, and when it was last restored.
    private struct Entry {
        var reference: WorkspaceBookmark
        var url: URL
        var lastLaunched: Date
    }

    private let defaults: UserDefaults
    private var entries: [Entry]

    /// How many dates are remembered. For tests and for the pruning assertions; the list itself
    /// is not exposed, because a caller wants `lastLaunched` or the merged listing, never this.
    var entryCount: Int { entries.count }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = Self.load(from: defaults)
        entries = loaded.entries
        // Pruned or rewritten entries are only corrected in memory until they are written back,
        // and the next launch would do the same work again.
        if loaded.needsRewrite {
            persist()
        }
    }

    func lastLaunched(_ url: URL) -> Date? {
        entries.first { Self.sameFile($0.url, url) }?.lastLaunched
    }

    /// Records that a workspace was restored. Called on the restore path, where the one thing it
    /// must not do is touch the document.
    func recordLaunch(of url: URL, at date: Date = Date()) {
        entries.removeAll { Self.sameFile($0.url, url) }
        entries.append(
            Entry(reference: WorkspaceBookmark.make(for: url), url: url, lastLaunched: date)
        )
        persist()
    }

    private func persist() {
        defaults.set(entries.map(\.reference.bookmark), forKey: Key.bookmarks)
        defaults.set(entries.map(\.reference.path), forKey: Key.paths)
        defaults.set(entries.map(\.lastLaunched), forKey: Key.dates)
    }

    private static func load(from defaults: UserDefaults) -> (entries: [Entry], needsRewrite: Bool) {
        let bookmarks = defaults.array(forKey: Key.bookmarks) as? [Data] ?? []
        let paths = defaults.array(forKey: Key.paths) as? [String] ?? []
        let dates = defaults.array(forKey: Key.dates) as? [Date] ?? []
        let count = min(min(bookmarks.count, paths.count), dates.count)

        var needsRewrite = bookmarks.count != count || paths.count != count || dates.count != count
        var result: [Entry] = []
        var seen: Set<String> = []

        for i in 0..<count {
            let reference = WorkspaceBookmark(path: paths[i], bookmark: bookmarks[i])
            guard let url = reference.resolve(needsRewrite: &needsRewrite) else {
                needsRewrite = true
                continue
            }
            // A date for a file that is gone would sit here forever: nothing deletes these and the
            // user never sees the list to tidy it. The file itself is the only authority on
            // whether the entry is still worth anything.
            guard FileManager.default.fileExists(atPath: url.path) else {
                needsRewrite = true
                continue
            }
            guard seen.insert(fileIdentity(url)).inserted else {
                needsRewrite = true
                continue
            }
            result.append(Entry(reference: reference, url: url, lastLaunched: dates[i]))
        }

        return (result, needsRewrite)
    }

    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        fileIdentity(a) == fileIdentity(b)
    }

    /// Symlink-resolved, so `/var/…` and `/private/var/…` are one file after a bookmark reload.
    private static func fileIdentity(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }
}
