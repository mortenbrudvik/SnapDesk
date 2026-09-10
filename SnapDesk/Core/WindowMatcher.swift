import Foundation

enum WindowMatcher {
    /// The window each slot claims out of one catalog snapshot, keyed by the slot's position in
    /// `slots`; a slot that claimed nothing is absent. `slots` arrives in the order the workspace
    /// lists them.
    ///
    /// Every exact title is settled, for every slot, before any slot is handed a leftover — and out
    /// of the *same* snapshot. A slot whose own window is gone must not swallow the window a later
    /// slot is named after, or both survivors land on the wrong saved frame. Two passes over two
    /// separate catalog reads does not achieve that: a window that vends between the reads is still
    /// there for an earlier slot to steal. Leftovers then go in slot order, so that when an app
    /// vends fewer windows than the workspace saved, the slots the user listed first win them.
    /// `takingLeftovers` names the positions that may settle for a window they are not named after;
    /// the rest get their exact title or nothing. `LaunchService` passes only the slots whose app
    /// has finished vending, because a slot whose own window is merely late still has one coming.
    /// Nil means every slot may take one, which is the right reading once the wait is over.
    static func assign(
        slots: [SavedWindow],
        among: [MatchableWindow],
        claimed: Set<String> = [],
        takingLeftovers: Set<Int>? = nil
    ) -> [Int: MatchableWindow] {
        var result = exactTitles(slots: slots, among: among, claimed: claimed)
        var taken = claimed.union(result.values.map(\.id))
        for (position, slot) in slots.enumerated() where result[position] == nil {
            guard takingLeftovers?.contains(position) ?? true else { continue }
            guard let leftover = free(among, for: slot, notIn: taken).first else { continue }
            taken.insert(leftover.id)
            result[position] = leftover
        }
        return result
    }

    /// The exact-title half of `assign` on its own. `LaunchService` claims these while it is still
    /// waiting for the rest of an app's windows to vend: a leftover handed out that early spends
    /// the window whose own slot is merely late.
    static func exactTitles(
        slots: [SavedWindow],
        among: [MatchableWindow],
        claimed: Set<String> = []
    ) -> [Int: MatchableWindow] {
        var taken = claimed
        var result: [Int: MatchableWindow] = [:]
        for (position, slot) in slots.enumerated() {
            guard let exact = free(among, for: slot, notIn: taken)
                .first(where: { $0.title == slot.title })
            else { continue }
            taken.insert(exact.id)
            result[position] = exact
        }
        return result
    }

    private static func free(
        _ among: [MatchableWindow],
        for slot: SavedWindow,
        notIn taken: Set<String>
    ) -> [MatchableWindow] {
        among.filter { !taken.contains($0.id) && $0.bundleIdentifier == slot.bundleIdentifier }
    }
}
