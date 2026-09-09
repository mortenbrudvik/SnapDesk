import CoreGraphics
import Foundation

enum DisplayMap {
    static func match(saved: SavedDisplay, among live: [LiveDisplay]) -> LiveDisplay? {
        if let byID = live.first(where: { $0.id == saved.id }) {
            return byID
        }
        if let byName = live.first(where: { $0.name == saved.name }) {
            return byName
        }
        let savedSize = saved.visibleFrame.cgRect.size
        return live.min { a, b in
            distance(a.visibleFrame.size, savedSize) < distance(b.visibleFrame.size, savedSize)
        }
    }

    static func resolve(
        displayId: String,
        saved: [SavedDisplay],
        live: [LiveDisplay],
        main: LiveDisplay
    ) -> LiveDisplay {
        guard let savedDisplay = saved.first(where: { $0.id == displayId }) else {
            return main
        }
        return match(saved: savedDisplay, among: live) ?? main
    }

    private static func distance(_ a: CGSize, _ b: CGSize) -> CGFloat {
        let dw = a.width - b.width
        let dh = a.height - b.height
        return (dw * dw + dh * dh).squareRoot()
    }
}
