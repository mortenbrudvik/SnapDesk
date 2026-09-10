import Foundation

/// The two facts that decide where a captured window sorts. Deliberately carries no payload: the
/// caller keeps its own array and gets back positions into it, so nothing about the window has to
/// be squeezed through this type and decoded again on the way out.
struct OrderedWindow: Equatable {
    var cgWindowID: UInt32?
    var isMinimized: Bool
}

enum CaptureOrdering {
    /// Positions into `candidates`, front-most first: the windows CoreGraphics reports as on-screen
    /// in its front-to-back order, then everything else — minimized windows, windows with no
    /// CoreGraphics id, and windows on another Space — in the order they were given.
    ///
    /// Returns indices rather than reordered windows so a caller can carry whatever it likes
    /// alongside each candidate without this type having to know about it.
    static func sortedIndices(
        of candidates: [OrderedWindow],
        onScreenFrontToBack: [UInt32]
    ) -> [Int] {
        var rank: [UInt32: Int] = [:]
        // Should the window list mention an id twice, its first mention is the front-most one,
        // so a later mention must not push the window backwards.
        for (index, id) in onScreenFrontToBack.enumerated() where rank[id] == nil {
            rank[id] = index
        }

        var onScreen: [(rank: Int, sourceIndex: Int)] = []
        var trailing: [Int] = []

        for (sourceIndex, window) in candidates.enumerated() {
            if !window.isMinimized,
               let id = window.cgWindowID,
               let r = rank[id] {
                onScreen.append((r, sourceIndex))
            } else {
                trailing.append(sourceIndex)
            }
        }

        onScreen.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.sourceIndex < rhs.sourceIndex
        }

        return onScreen.map(\.sourceIndex) + trailing
    }
}
