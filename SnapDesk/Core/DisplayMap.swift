import CoreGraphics
import Foundation

enum DisplayMap {
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
        if !saved.id.isEmpty, let byID = live.first(where: { $0.id == saved.id }) {
            return byID
        }
        if !saved.name.isEmpty, let byName = live.first(where: { $0.name == saved.name }) {
            return byName
        }
        let savedSize = saved.visibleFrame.cgRect.size
        return live.min { a, b in
            distance(a.visibleFrame.size, savedSize) < distance(b.visibleFrame.size, savedSize)
        }
    }

    /// The screen to place a window on. Logs whenever the answer is not the display the window was
    /// captured on, because that is the whole explanation for a layout that comes back "wrong":
    /// every slot still reports success, it is just aimed at a substitute screen.
    static func resolve(
        displayId: String,
        saved: [SavedDisplay],
        live: [LiveDisplay],
        main: LiveDisplay
    ) -> LiveDisplay {
        guard let savedDisplay = saved.first(where: { $0.id == displayId }) else {
            Log.displays.notice("no saved display \"\(displayId, privacy: .public)\" in this workspace; placing its windows on \(main.name, privacy: .public)")
            return main
        }
        guard let matched = match(saved: savedDisplay, among: live) else {
            return main
        }
        if matched.id != savedDisplay.id {
            Log.displays.notice("display \(savedDisplay.name, privacy: .public) is not attached; its windows go to \(matched.name, privacy: .public)")
        }
        return matched
    }

    private static func distance(_ a: CGSize, _ b: CGSize) -> CGFloat {
        let dw = a.width - b.width
        let dh = a.height - b.height
        return (dw * dw + dh * dh).squareRoot()
    }
}
