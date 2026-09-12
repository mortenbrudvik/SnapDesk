import Foundation

/// When each workspace was last restored, and — with a folder nominated — every workspace the
/// user owns rather than only the ones they opened lately.
///
/// The date lives here, in preferences, and deliberately not in the `.snapdesk` file. PowerToys
/// writes `lastLaunchedTime` into the workspace itself; doing that would mean a restore modifies
/// the user's document, which dirties version control, fails outright on a read-only file, and
/// changes a file they did not edit. A workspace is a document, and restoring one is a read.
/// One row of the workspace list: where it is, what to call it, and when it was last restored.
/// The name comes from the file name, never from decoding the document — a sidebar showing fifty
/// workspaces would otherwise parse fifty files to draw itself.
struct WorkspaceListing: Equatable, Identifiable {
    var url: URL
    var name: String
    var lastLaunched: Date?

    var id: URL { url }
}

@MainActor
final class WorkspaceLibrary {
    private enum Key {
        static let bookmarks = "libraryBookmarks"
        static let paths = "libraryPaths"
        static let dates = "libraryDates"
        static let folderBookmark = "libraryFolderBookmark"
        static let folderPath = "libraryFolderPath"
    }

    /// One remembered workspace: where it is, and when it was last restored.
    private struct Entry {
        var reference: WorkspaceBookmark
        var url: URL
        var lastLaunched: Date
    }

    private let defaults: UserDefaults
    private var entries: [Entry]
    private var storedFolder: WorkspaceBookmark

    /// How many dates are remembered. For tests and for the pruning assertions; the list itself
    /// is not exposed, because a caller wants `lastLaunched` or the merged listing, never this.
    var entryCount: Int { entries.count }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedFolder = WorkspaceBookmark(
            path: defaults.string(forKey: Key.folderPath) ?? "",
            bookmark: defaults.data(forKey: Key.folderBookmark) ?? Data()
        )
        let loaded = Self.load(from: defaults)
        entries = loaded.entries
        // Pruned or rewritten entries are only corrected in memory until they are written back,
        // and the next launch would do the same work again.
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
        get {
            var needsRewrite = false
            guard let resolved = storedFolder.resolve(needsRewrite: &needsRewrite) else { return nil }
            if needsRewrite {
                // Through the storage directly, never through the setter; see `AppSettings.store`.
                storeFolder(resolved)
            }
            return resolved
        }
        set { storeFolder(newValue) }
    }

    private func storeFolder(_ url: URL?) {
        storedFolder = url.map(WorkspaceBookmark.make(for:)) ?? .none
        defaults.set(storedFolder.bookmark, forKey: Key.folderBookmark)
        defaults.set(storedFolder.path, forKey: Key.folderPath)
    }

    /// Every workspace worth showing: the nominated folder's contents merged with `recents`,
    /// ordered for a sidebar.
    ///
    /// Most-recently-restored first, because that is what the user reaches for. Everything never
    /// restored follows in name order — the order `contentsOfDirectory` returns is arbitrary and
    /// changes, which would make the list shuffle between launches for no reason the user can see.
    func listing(recents: [URL]) -> [WorkspaceListing] {
        var seen: Set<String> = []
        var found: [URL] = []
        for url in folderWorkspaces() + recents where seen.insert(Self.fileIdentity(url)).inserted {
            found.append(url)
        }

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

    /// The folder's own `.snapdesk` files. Not recursive, and never decodes one: the name comes
    /// from the file name, so listing a folder of fifty workspaces costs one directory read.
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
