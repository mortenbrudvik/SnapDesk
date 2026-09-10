import CoreGraphics
import Foundation

enum DisplayMap {
    /// Which of the three rules in `match` answered, so a caller can tell a real match from a guess.
    enum MatchRule: Equatable {
        case sameID
        case sameName
        case closestSize
    }

    /// Finds the screen a saved display refers to now, in descending order of confidence:
    ///
    /// 1. Same UUID — the same physical display, wherever it has been moved to. A real match.
    /// 2. Same localized name — the display was replaced or re-registered and lost its UUID, but
    ///    "LG UltraFine" is still almost certainly the one meant. A likely match.
    /// 3. Closest `visibleFrame` size — a GUESS, not a match: it always returns something as long
    ///    as any display is attached, so restoring a three-monitor workspace on an undocked laptop
    ///    piles every window onto the built-in display. Callers that care should say so to the
    ///    user; `resolve` logs it.
    ///
    /// Empty ids and names never match, so displays that could not be identified at capture (see
    /// `LiveDisplay.identity(for:)`) fall through to the size guess instead of matching each other.
    /// Nil only when no display is attached at all.
    static func match(saved: SavedDisplay, among live: [LiveDisplay]) -> LiveDisplay? {
        matchWithRule(saved: saved, among: live)?.display
    }

    static func matchWithRule(
        saved: SavedDisplay,
        among live: [LiveDisplay]
    ) -> (display: LiveDisplay, rule: MatchRule)? {
        if !saved.id.isEmpty, let byID = live.first(where: { $0.id == saved.id }) {
            return (byID, .sameID)
        }
        if !saved.name.isEmpty, let byName = live.first(where: { $0.name == saved.name }) {
            return (byName, .sameName)
        }
        let savedSize = saved.visibleFrame.cgRect.size
        let closest = live.min { a, b in
            distance(a.visibleFrame.size, savedSize) < distance(b.visibleFrame.size, savedSize)
        }
        return closest.map { ($0, .closestSize) }
    }

    /// The screen to place a window on. `primary` is `NSScreen.screens[0]` — the display that
    /// anchors the coordinate system — and not `NSScreen.main`, and it is where a window lands
    /// whose display cannot be found at all. Logs whenever the answer is not the display the
    /// window was captured on, naming the rule, because "matched by name" is almost certainly the
    /// screen meant and "closest size" is a guess: the two need different reactions from whoever
    /// reads the log after a layout came back "wrong" with every slot reporting success.
    static func resolve(
        displayId: String,
        saved: [SavedDisplay],
        live: [LiveDisplay],
        primary: LiveDisplay
    ) -> LiveDisplay {
        guard let savedDisplay = saved.first(where: { $0.id == displayId }) else {
            Log.displays.notice("no saved display \"\(displayId, privacy: .public)\" in this workspace; placing its windows on \(primary.name, privacy: .public)")
            return primary
        }
        guard let (matched, rule) = matchWithRule(saved: savedDisplay, among: live) else {
            return primary
        }
        switch rule {
        case .sameID:
            break
        case .sameName:
            Log.displays.notice("display \(savedDisplay.name, privacy: .public) is not attached by id; its windows go to the display of the same name, \(matched.name, privacy: .public)")
        case .closestSize:
            Log.displays.notice("display \(savedDisplay.name, privacy: .public) is not attached; its windows go to \(matched.name, privacy: .public), the closest size — a guess")
        }
        return matched
    }

    private static func distance(_ a: CGSize, _ b: CGSize) -> CGFloat {
        let dw = a.width - b.width
        let dh = a.height - b.height
        return (dw * dw + dh * dh).squareRoot()
    }
}
