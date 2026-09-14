import Foundation

/// One workspace file remembered across launches: the bookmark that follows it when the user moves
/// or renames it, and the path that stands in when there is no bookmark or it no longer resolves.
///
/// Extracted from `RecentsStore` when the workspace hotkeys needed exactly the same thing. Stale
/// bookmarks are fiddly enough — macOS resolves one and simultaneously tells you to rewrite it —
/// that a second copy of the handling would be a second thing to get wrong.
struct WorkspaceBookmark: Equatable {
    var path: String
    var bookmark: Data

    var isEmpty: Bool { path.isEmpty && bookmark.isEmpty }

    static let none = WorkspaceBookmark(path: "", bookmark: Data())

    /// What resolving an entry answers: where the file is now, and the entry to keep.
    ///
    /// `bookmark` is a fresh one when macOS reported the stored one stale or the file has moved
    /// since it was made, and otherwise the entry that was resolved. A caller persists it either
    /// way, so the rewrite cannot be forgotten — which is what happened to `WorkspaceLibrary`
    /// when this was an `inout` flag the caller had to act on.
    struct Resolution: Equatable {
        var url: URL
        var bookmark: WorkspaceBookmark
    }

    /// A bookmark can fail to be made — the file may not exist yet, or be on a volume that does
    /// not support them. The entry survives on its path alone: it still opens, it just stops
    /// following the file if the user moves it.
    static func make(for url: URL) -> WorkspaceBookmark {
        do {
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return WorkspaceBookmark(path: url.path, bookmark: bookmark)
        } catch {
            Log.app.error(
                "no bookmark for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return WorkspaceBookmark(path: url.path, bookmark: Data())
        }
    }

    /// The bookmark first, because it follows a file the user has moved or renamed; the path only
    /// when there is no bookmark or it no longer resolves.
    ///
    /// A file in the Trash counts as gone. Measured: a bookmark follows a file into the Trash and
    /// resolves there, stale — so without this rule a hotkey restored a workspace the user had
    /// deleted, and the binding was rewritten to point into the Trash. Falling through to the
    /// path, which no longer exists, is what makes the launch path say "could not be found". The
    /// bookmark itself is kept, so a file put back from the Trash is found again.
    func resolve() -> Resolution? {
        if !bookmark.isEmpty {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if Self.isInTrash(resolved) {
                    Log.app.notice(
                        "the bookmark for \(path, privacy: .public) resolves into the Trash; treating the file as deleted"
                    )
                } else {
                    let moved = path.isEmpty
                        || Self.identity(of: resolved) != Self.identity(of: URL(fileURLWithPath: path))
                    return Resolution(
                        url: resolved,
                        bookmark: isStale || moved ? WorkspaceBookmark.make(for: resolved) : self
                    )
                }
            } else {
                // Not silent: from here on this entry no longer follows the file, and if the file is
                // gone it will report "could not be found" every time it is used.
                Log.app.notice(
                    "the bookmark for \(path, privacy: .public) no longer resolves; keeping the entry by path"
                )
            }
        }
        guard !path.isEmpty else { return nil }
        return Resolution(url: URL(fileURLWithPath: path), bookmark: self)
    }

    /// Symlink-resolved, so `/var/…` and `/private/var/…` are one file after a bookmark reload.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        identity(of: a) == identity(of: b)
    }

    static func identity(of url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The Trash of the volume the file is on: `~/.Trash` for the boot volume, `.Trashes/<uid>`
    /// on an external one.
    private static func isInTrash(_ url: URL) -> Bool {
        guard let trash = try? FileManager.default.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: url,
            create: false
        ) else { return false }
        return identity(of: url).hasPrefix(identity(of: trash) + "/")
    }
}

extension WorkspaceBookmark {
    /// The on-disk shape every store here uses: two parallel arrays, the bookmarks under one key
    /// and the paths under another. That is what earlier builds wrote for recents, so that store
    /// stays readable by them, and the newer stores use the same shape so there is one codec.
    ///
    /// Short arrays are padded rather than dropped, so a defaults dictionary an older or newer
    /// build wrote cannot change what an index means. `count` fixes how many entries come back;
    /// nil takes however many the longer array holds.
    static func list(
        in defaults: UserDefaults,
        bookmarks bookmarkKey: String,
        paths pathKey: String,
        count: Int? = nil
    ) -> [WorkspaceBookmark] {
        let bookmarks = defaults.array(forKey: bookmarkKey) as? [Data] ?? []
        let paths = defaults.array(forKey: pathKey) as? [String] ?? []
        return (0..<(count ?? max(bookmarks.count, paths.count))).map { i in
            WorkspaceBookmark(
                path: i < paths.count ? paths[i] : "",
                bookmark: i < bookmarks.count ? bookmarks[i] : Data()
            )
        }
    }

    static func store(
        _ entries: [WorkspaceBookmark],
        in defaults: UserDefaults,
        bookmarks bookmarkKey: String,
        paths pathKey: String
    ) {
        defaults.set(entries.map(\.bookmark), forKey: bookmarkKey)
        defaults.set(entries.map(\.path), forKey: pathKey)
    }
}

/// One bookmarked URL kept under a pair of `UserDefaults` keys — the bookmark under one, the path
/// under the other, the shape every workspace reference here uses.
///
/// A type rather than the same twenty lines in two files: the startup workspace and the nominated
/// folder differ only in which keys they use, and the one subtle rule — persist the entry
/// `resolve` hands back, through the storage and never through the setter — is stated once.
@MainActor
final class BookmarkedURLSetting {
    private let defaults: UserDefaults
    private let bookmarkKey: String
    private let pathKey: String
    private var stored: WorkspaceBookmark

    init(defaults: UserDefaults, bookmarkKey: String, pathKey: String) {
        self.defaults = defaults
        self.bookmarkKey = bookmarkKey
        self.pathKey = pathKey
        stored = WorkspaceBookmark(
            path: defaults.string(forKey: pathKey) ?? "",
            bookmark: defaults.data(forKey: bookmarkKey) ?? Data()
        )
    }

    /// Resolved on every read, so a file renamed since launch is still found. The rewrite goes
    /// through `write` directly: assigning to a property from inside its own getter is how a
    /// re-entrant accessor is written by accident, and the compiler says so.
    var url: URL? {
        get {
            guard let resolution = stored.resolve() else { return nil }
            if resolution.bookmark != stored {
                write(resolution.bookmark)
            }
            return resolution.url
        }
        set { write(newValue.map(WorkspaceBookmark.make(for:)) ?? .none) }
    }

    /// Clears the setting when it names this file and leaves it alone otherwise — the editor's
    /// Move to Trash reaching a setting that would otherwise keep pointing into the Trash.
    func forget(_ file: URL) {
        guard let current = url, WorkspaceBookmark.sameFile(current, file) else { return }
        url = nil
    }

    private func write(_ entry: WorkspaceBookmark) {
        stored = entry
        defaults.set(entry.bookmark, forKey: bookmarkKey)
        defaults.set(entry.path, forKey: pathKey)
    }
}
