import Foundation

enum Recapture {
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
