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
/// Every function takes its inputs explicitly so it is pure and testable; the live values come
/// from `primaryMaxY` and `Display.all`.
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

    /// The display whose frame contains `point`. Exact containment wins, so a point on the
    /// edge shared by two displays goes to the one whose frame includes it. A 1pt tolerance
    /// then catches the pointer resting exactly on the top or right edge of the outermost
    /// display, which `CGRect.contains` excludes. Nil when the point is on no display.
    static func display(containing point: CGPoint, in displays: [Display] = Display.all) -> Display? {
        displays.first { $0.frame.contains(point) }
            ?? displays.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
    }

    /// The display under the centre of `rect`. A window straddling two displays belongs to
    /// the one holding more than half of it. If the centre is off every display, the display
    /// with the largest intersection wins; none if the rect misses every display.
    static func display(containing rect: CGRect, in displays: [Display] = Display.all) -> Display? {
        if let match = display(containing: CGPoint(x: rect.midX, y: rect.midY), in: displays) {
            return match
        }
        var best: Display?
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
