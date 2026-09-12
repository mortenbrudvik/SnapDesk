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
    /// `needsRewrite` is set when macOS reports the bookmark stale — it still resolved, but this
    /// copy of it will stop working, and the resolved URL is exactly what a fresh one is made
    /// from. A caller that does not write the corrected value back will resolve the same stale
    /// bookmark again on the next launch.
    func resolve(needsRewrite: inout Bool) -> URL? {
        if !bookmark.isEmpty {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                needsRewrite = needsRewrite || isStale
                return resolved
            }
            // Not silent: from here on this entry no longer follows the file, and if the file is
            // gone it will report "could not be found" every time it is used.
            Log.app.notice(
                "the bookmark for \(path, privacy: .public) no longer resolves; keeping the entry by path"
            )
        }
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
