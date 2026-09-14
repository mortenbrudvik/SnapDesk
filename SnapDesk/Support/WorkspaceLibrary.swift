import Foundation

/// One row of the workspace list: where it is, what to call it, and when it was last restored.
///
/// The name is the file name. The sidebar shows the name inside the document instead, read through
/// `RecentNameCache`, which parses a file only when its modification date has changed — so the
/// library never decodes a file to list it, and the sidebar decodes each one once.
struct WorkspaceListing: Equatable {
    var url: URL
    var name: String
    var lastLaunched: Date?
}

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
        static let folderBookmark = "libraryFolderBookmark"
        static let folderPath = "libraryFolderPath"
    }

    /// One remembered workspace: the entry as it is persisted, where it resolved to, and when it
    /// was last restored.
    private struct Entry {
        var reference: WorkspaceBookmark
        var url: URL
        var lastLaunched: Date
    }

    private let defaults: UserDefaults
    private var entries: [Entry]
    private let folderStorage: BookmarkedURLSetting

    /// How many dates are remembered. For tests and for the pruning assertions; the list itself
    /// is not exposed, because a caller wants `lastLaunched` or the merged listing, never this.
    var entryCount: Int { entries.count }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folderStorage = BookmarkedURLSetting(
            defaults: defaults,
            bookmarkKey: Key.folderBookmark,
            pathKey: Key.folderPath
        )
        let loaded = Self.load(from: defaults)
        entries = loaded.entries
        // Whatever `load` corrected — a refreshed bookmark, a pruned entry, arrays out of step —
        // is only corrected in memory until it is written back, and the next launch would do the
        // same work again.
        if loaded.needsRewrite {
            persist()
        }
    }

    /// A folder the user has nominated as where their workspaces live, or nil.
    ///
    /// A plain bookmark rather than a security-scoped one: SnapDesk is not sandboxed — it cannot
    /// be, because the App Sandbox blocks the Accessibility calls it exists for — so there is no
    /// scope to reclaim, and a security-scoped bookmark would only add a start/stop dance around
    /// every read that does nothing here.
    var folder: URL? {
        get { folderStorage.url }
        set { folderStorage.url = newValue }
    }

    /// Whether the nominated folder can be listed right now.
    enum FolderAvailability: Equatable {
        case none
        case listed(URL)
        /// Deleted, renamed or unmounted. The setting stays — the volume may come back — and
        /// the sidebar says so, rather than looking like an empty folder.
        case unavailable(URL)
    }

    func folderAvailability() -> FolderAvailability {
        guard let folder else { return .none }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue, FileManager.default.isReadableFile(atPath: folder.path) else {
            return .unavailable(folder)
        }
        return .listed(folder)
    }

    /// Every workspace worth showing: the nominated folder's contents merged with `recents`,
    /// ordered for a sidebar. With no folder it is the recents list as a *set*, in this order
    /// rather than the store's most-recently-opened one.
    ///
    /// Most-recently-restored first, because that is what the user reaches for. Everything never
    /// restored follows in file-name order — the order `contentsOfDirectory` returns is arbitrary
    /// and changes, which would make the list shuffle between launches for no reason the user
    /// can see.
    func listing(recents: [URL]) -> [WorkspaceListing] {
        var seen: Set<String> = []
        let found = (folderWorkspaces() + recents).filter { seen.insert(Self.fileIdentity($0)).inserted }

        let rows = found.map {
            WorkspaceListing(
                url: $0,
                name: $0.deletingPathExtension().lastPathComponent,
                lastLaunched: lastLaunched($0)
            )
        }

        return rows.sorted { a, b in
            switch (a.lastLaunched, b.lastLaunched) {
            case let (x?, y?):
                return x > y
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// The folder's own `.snapdesk` files. Not recursive, and never decodes one: listing a folder
    /// of fifty workspaces costs one directory read here.
    private func folderWorkspaces() -> [URL] {
        guard let folder else { return [] }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            // A folder that has been deleted, renamed or unmounted. The setting stays — the volume
            // may come back — and the listing falls back to recents alone.
            Log.app.notice("the workspace folder could not be read; listing recents only")
            return []
        }
        return contents.filter { $0.pathExtension == WorkspaceFileType.fileExtension }
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

    /// Drops the date of a file the editor has moved to the Trash. Measured: a bookmark follows a
    /// file into the Trash, so an entry left behind would keep resolving until the Trash is
    /// emptied, and sort a deleted workspace to the top of the list.
    func forget(_ url: URL) {
        let before = entries.count
        entries.removeAll { Self.sameFile($0.url, url) }
        if entries.count != before {
            persist()
        }
    }

    private func persist() {
        WorkspaceBookmark.store(
            entries.map(\.reference),
            in: defaults,
            bookmarks: Key.bookmarks,
            paths: Key.paths
        )
        defaults.set(entries.map(\.lastLaunched), forKey: Key.dates)
    }

    private static func load(from defaults: UserDefaults) -> (entries: [Entry], needsRewrite: Bool) {
        let bookmarks = defaults.array(forKey: Key.bookmarks) as? [Data] ?? []
        let paths = defaults.array(forKey: Key.paths) as? [String] ?? []
        let dates = defaults.array(forKey: Key.dates) as? [Date] ?? []
        // Three arrays where the other stores keep two, and a third can be out of step with the
        // other two: only the entries all three agree on are trusted, and the disagreement is
        // written back resolved rather than carried to the next launch.
        let count = min(bookmarks.count, paths.count, dates.count)

        var needsRewrite = bookmarks.count != count || paths.count != count || dates.count != count
        if needsRewrite {
            Log.app.notice(
                "the workspace library's arrays are out of step (\(bookmarks.count)/\(paths.count)/\(dates.count)); keeping the first \(count)"
            )
        }
        var result: [Entry] = []
        var seen: Set<String> = []

        for i in 0..<count {
            let reference = WorkspaceBookmark(path: paths[i], bookmark: bookmarks[i])
            guard let resolution = reference.resolve() else {
                // `resolve` has said why.
                needsRewrite = true
                continue
            }
            if resolution.bookmark != reference {
                needsRewrite = true
            }
            // A date for a file that is gone would sit here forever: nothing deletes these and the
            // user never sees the list to tidy it. The file itself is the only authority on
            // whether the entry is still worth anything.
            guard FileManager.default.fileExists(atPath: resolution.url.path) else {
                Log.app.notice(
                    "dropping the launch date of \(resolution.url.path, privacy: .public): the file is gone"
                )
                needsRewrite = true
                continue
            }
            guard seen.insert(fileIdentity(resolution.url)).inserted else {
                Log.app.notice(
                    "dropping a duplicate launch date for \(resolution.url.path, privacy: .public)"
                )
                needsRewrite = true
                continue
            }
            result.append(Entry(reference: resolution.bookmark, url: resolution.url, lastLaunched: dates[i]))
        }

        return (result, needsRewrite)
    }

    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        WorkspaceBookmark.sameFile(a, b)
    }

    private static func fileIdentity(_ url: URL) -> String {
        WorkspaceBookmark.identity(of: url)
    }
}
