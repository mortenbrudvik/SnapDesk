import Foundation

enum WindowMatcher {
    static func match(
        slot: SavedWindow,
        among: [MatchableWindow],
        claimed: Set<String>
    ) -> MatchableWindow? {
        let candidates = among.filter {
            !claimed.contains($0.id) && $0.bundleIdentifier == slot.bundleIdentifier
        }
        if let exact = candidates.first(where: { $0.title == slot.title }) {
            return exact
        }
        return candidates.first
    }
}
