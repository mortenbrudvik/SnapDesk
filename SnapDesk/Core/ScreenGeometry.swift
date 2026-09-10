import AppKit

/// Converts between AppKit screen coordinates (origin at the bottom-left of the *primary*
/// display, `NSScreen.screens[0]`, y up) and Accessibility / CoreGraphics coordinates
/// (origin at the top-left of that same display, y down). Both share the x axis and the
/// primary display's height, so the flip `y' = primaryMaxY - y - height` is its own inverse,
/// which is why `cocoaRect(fromAX:)` and `axRect(fromCocoa:)` are the same formula.
///
/// "Primary" is NOT `NSScreen.main` (the screen holding the key window). Using `.main` here
/// would corrupt every conversion whenever the key window sits on a secondary display.
///
/// Every function takes its inputs explicitly, so `primaryMaxY` is the only value read from the
/// live system; the display lookups are pure functions of the list they are handed.
enum ScreenGeometry {
    /// The primary display's height, which is also the Cocoa y of its top edge. Nil when no
    /// display is attached, in which case no coordinate conversion is meaningful.
    static var primaryMaxY: CGFloat? {
        NSScreen.screens.first?.frame.maxY
    }

    static func cocoaRect(fromAX ax: CGRect, primaryMaxY: CGFloat) -> CGRect {
        flipped(ax, primaryMaxY: primaryMaxY)
    }

    static func axRect(fromCocoa cocoa: CGRect, primaryMaxY: CGFloat) -> CGRect {
        flipped(cocoa, primaryMaxY: primaryMaxY)
    }

    static func axPoint(fromCocoa cocoa: CGPoint, primaryMaxY: CGFloat) -> CGPoint {
        CGPoint(x: cocoa.x, y: primaryMaxY - cocoa.y)
    }

    /// The display whose frame contains `point`. Exact containment wins, so a point on the edge
    /// shared by two displays goes to the one whose frame includes it. Only when no frame
    /// contains the point does a 1pt tolerance apply: `insetBy(dx: -1, dy: -1)` grows a frame on
    /// all four sides, so besides the top and right edges that `CGRect.contains` excludes it also
    /// swallows a point up to 1pt outside any other edge, including one inside the gap between
    /// two displays. Nil when the point is further out than that.
    ///
    /// The matching element is returned rather than a copy of its geometry, so two displays that
    /// report identical frames stay distinguishable to the caller.
    static func display(containing point: CGPoint, in displays: [LiveDisplay]) -> LiveDisplay? {
        displays.first { $0.frame.contains(point) }
            ?? displays.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
    }

    /// The display under the *centre* of `rect`. A window straddling two displays belongs to
    /// whichever holds its midpoint — not, despite the intuition, to whichever holds more than
    /// half its area; the two rules agree only for equal displays sharing a full-height edge.
    /// Area decides only when the centre is off every display, and then the largest intersection
    /// wins. Nil when the rect misses every display. This is what stamps `SavedWindow.displayId`
    /// at capture, so the centre rule is what a restored layout reproduces.
    static func display(containing rect: CGRect, in displays: [LiveDisplay]) -> LiveDisplay? {
        if let match = display(containing: CGPoint(x: rect.midX, y: rect.midY), in: displays) {
            return match
        }
        var best: LiveDisplay?
        var bestArea: CGFloat = 0
        for display in displays {
            let intersection = display.frame.intersection(rect)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = display
            }
        }
        return best
    }

    private static func flipped(_ rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.minY - rect.height, width: rect.width, height: rect.height)
    }
}
