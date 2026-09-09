import Foundation

struct OrderedWindow: Equatable {
    var cgWindowID: UInt32?
    var isMinimized: Bool
    var label: String
}

enum CaptureOrdering {
    static func sort(
        candidates: [OrderedWindow],
        onScreenFrontToBack: [UInt32]
    ) -> [OrderedWindow] {
        var rank: [UInt32: Int] = [:]
        for (index, id) in onScreenFrontToBack.enumerated() where rank[id] == nil {
            rank[id] = index
        }

        var onScreen: [(rank: Int, sourceIndex: Int, window: OrderedWindow)] = []
        var trailing: [OrderedWindow] = []

        for (sourceIndex, window) in candidates.enumerated() {
            if !window.isMinimized,
               let id = window.cgWindowID,
               let r = rank[id] {
                onScreen.append((r, sourceIndex, window))
            } else {
                trailing.append(window)
            }
        }

        onScreen.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.sourceIndex < rhs.sourceIndex
        }

        return onScreen.map(\.window) + trailing
    }
}
