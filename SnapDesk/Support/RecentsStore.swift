import Foundation

@MainActor
final class RecentsStore {
    private enum Key {
        static let bookmarks = "recentsBookmarks"
        static let paths = "recentsPaths"
    }

    private static let cap = 20

    private(set) var urls: [URL] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = Self.load(from: defaults)
        urls = loaded.urls
        // Whatever `load` had to correct — a bookmark macOS reported as stale, a duplicate, or
        // entries beyond the cap — is only corrected in memory until it is written back, and the
        // next launch would resolve the same stale bookmarks again.
        if loaded.needsRewrite {
            persist()
        }
    }

    func add(_ url: URL) {
        urls.removeAll { Self.sameFile($0, url) }
        urls.insert(url, at: 0)
        if urls.count > Self.cap {
            urls = Array(urls.prefix(Self.cap))
        }
        persist()
    }

    func remove(_ url: URL) {
        urls.removeAll { Self.sameFile($0, url) }
        persist()
    }

    /// Stored as two parallel arrays under `Key.bookmarks` and `Key.paths` — the on-disk shape
    /// earlier builds wrote, so this stays readable by them; `WorkspaceBookmark` is what pairs
    /// them up.
    private func persist() {
        let stored = urls.map(WorkspaceBookmark.make(for:))
        defaults.set(stored.map(\.bookmark), forKey: Key.bookmarks)
        defaults.set(stored.map(\.path), forKey: Key.paths)
    }

    private static func stored(in defaults: UserDefaults) -> [WorkspaceBookmark] {
        let bookmarks = defaults.array(forKey: Key.bookmarks) as? [Data] ?? []
        let paths = defaults.array(forKey: Key.paths) as? [String] ?? []
        return (0..<max(bookmarks.count, paths.count)).map { i in
            WorkspaceBookmark(
                path: i < paths.count ? paths[i] : "",
                bookmark: i < bookmarks.count ? bookmarks[i] : Data()
            )
        }
    }

    private static func load(from defaults: UserDefaults) -> (urls: [URL], needsRewrite: Bool) {
        var result: [URL] = []
        var needsRewrite = false

        for entry in stored(in: defaults) {
            if let resolved = entry.resolve(needsRewrite: &needsRewrite) {
                result.append(resolved)
            }
        }

        // Two entries can resolve to the same file — one deleted and another renamed into its
        // place. `add` keeps the list unique; so must this, or the sidebar shows two rows with
        // one identity.
        var seen: Set<String> = []
        let unique = result.filter { seen.insert(fileIdentity($0)).inserted }
        if unique.count != result.count {
            needsRewrite = true
        }
        result = unique

        // The cap is enforced here as well as in `add`, so a defaults dictionary holding more than
        // `cap` entries — hand-edited, or written by an older build — does not stay oversized until
        // the next `add` happens to trim it. The list is newest first, so the tail is the oldest.
        if result.count > cap {
            result = Array(result.prefix(cap))
            needsRewrite = true
        }

        return (result, needsRewrite)
    }

    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        fileIdentity(a) == fileIdentity(b)
    }

    /// Symlink-resolved path so `/var/...` and `/private/var/...` match after bookmark reload.
    private static func fileIdentity(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }
}
