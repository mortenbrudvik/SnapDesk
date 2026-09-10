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
                result.arguments = unused.remove(at: index).arguments
            }
            return result
        }
    }
}
