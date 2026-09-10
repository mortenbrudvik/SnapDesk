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
        // Whatever `load` had to correct — a bookmark macOS reported as stale, or entries beyond
        // the cap — is only corrected in memory until it is written back, and the next launch
        // would resolve the same stale bookmarks again.
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

    private func persist() {
        var bookmarks: [Data] = []
        var paths: [String] = []
        bookmarks.reserveCapacity(urls.count)
        paths.reserveCapacity(urls.count)

        for url in urls {
            paths.append(url.path)
            do {
                bookmarks.append(
                    try url.bookmarkData(
                        options: .minimalBookmark,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                )
            } catch {
                // The entry stays in the list on its path alone: it still opens, it just stops
                // following the file if the user moves or renames it.
                Log.app.error(
                    "no bookmark for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                bookmarks.append(Data())
            }
        }

        defaults.set(bookmarks, forKey: Key.bookmarks)
        defaults.set(paths, forKey: Key.paths)
    }

    private static func load(from defaults: UserDefaults) -> (urls: [URL], needsRewrite: Bool) {
        let bookmarks = defaults.array(forKey: Key.bookmarks) as? [Data] ?? []
        let paths = defaults.array(forKey: Key.paths) as? [String] ?? []
        let count = max(bookmarks.count, paths.count)
        var result: [URL] = []
        var needsRewrite = false
        result.reserveCapacity(count)

        for i in 0..<count {
            let path = i < paths.count ? paths[i] : nil
            let bookmark = i < bookmarks.count ? bookmarks[i] : Data()

            if !bookmark.isEmpty {
                var isStale = false
                if let resolved = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    // A stale bookmark still resolved, but macOS is saying this copy of it will
                    // not keep working; the resolved URL is exactly what a fresh one is made from.
                    needsRewrite = needsRewrite || isStale
                    result.append(resolved)
                    continue
                }
            }
            if let path, !path.isEmpty {
                result.append(URL(fileURLWithPath: path))
            }
        }

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
