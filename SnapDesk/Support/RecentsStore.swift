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
        urls = Self.load(from: defaults)
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
            if let data = try? url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                bookmarks.append(data)
            } else {
                bookmarks.append(Data())
            }
        }

        defaults.set(bookmarks, forKey: Key.bookmarks)
        defaults.set(paths, forKey: Key.paths)
    }

    private static func load(from defaults: UserDefaults) -> [URL] {
        let bookmarks = defaults.array(forKey: Key.bookmarks) as? [Data] ?? []
        let paths = defaults.array(forKey: Key.paths) as? [String] ?? []
        let count = max(bookmarks.count, paths.count)
        var result: [URL] = []
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
                    result.append(resolved)
                    continue
                }
            }
            if let path, !path.isEmpty {
                result.append(URL(fileURLWithPath: path))
            }
        }

        return result
    }

    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        fileIdentity(a) == fileIdentity(b)
    }

    /// Symlink-resolved path so `/var/...` and `/private/var/...` match after bookmark reload.
    private static func fileIdentity(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }
}
