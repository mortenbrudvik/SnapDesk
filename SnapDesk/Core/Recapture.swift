import Foundation

enum Recapture {
    /// The result follows `new`, so an empty capture merges to no windows at all. Callers decide
    /// whether an empty capture is a real snapshot or a failed read; see `EditorSession.applyCapture`.
    static func merge(old: [SavedWindow], new: [SavedWindow]) -> [SavedWindow] {
        var unused = old
        return new.map { window in
            var result = window
            if let index = unused.firstIndex(where: {
                $0.bundleIdentifier == window.bundleIdentifier && $0.title == window.title
            }) ?? unused.firstIndex(where: {
                $0.bundleIdentifier == window.bundleIdentifier
            }) {
                let previous = unused.remove(at: index)
                result.arguments = previous.arguments
                // A document the user typed by hand — Safari vends none, so the help tells them
                // to — survives a recapture the way arguments do. One the app vends now is the
                // current one, and wins.
                if result.document == nil {
                    result.document = previous.document
                }
            }
            return result
        }
    }
}
