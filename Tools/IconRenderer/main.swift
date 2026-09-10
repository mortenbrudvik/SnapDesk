// Draws the SnapDesk app icon and writes one PNG per size the asset catalog needs.
//
// The icon has source rather than being a folder of PNGs nobody can edit: the geometry below is
// the design, and regenerating it after a tweak is one command.
//
//   swift Tools/IconRenderer/main.swift SnapDesk/App/Assets.xcassets/AppIcon.appiconset
//
// What it draws: a blue rounded square holding three white panes — one tall on the left, two
// stacked on the right — which is a saved window layout, and the shape the menu bar symbol
// (`rectangle.3.group`) already uses.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: The design, on a 1024 grid

enum Design {
    /// Apple's macOS grid: the art sits in an 824pt rounded square inside a 1024pt canvas, so the
    /// shadow has room and every app's icon lines up with every other one.
    static let canvas: CGFloat = 1024
    static let squareInset: CGFloat = 100
    static var squareSide: CGFloat { canvas - squareInset * 2 }

    /// macOS corners are a squircle — a superellipse — not a circular round-rect. n = 5 is the
    /// standard approximation; circular corners read as subtly wrong beside system icons.
    static let cornerExponent: CGFloat = 5

    static let shadowOffset: CGFloat = 10
    static let shadowBlur: CGFloat = 30
    static let shadowAlpha: CGFloat = 0.18
    /// Below this pixel size the shadow is dropped. A blur that is a graceful lift at 512 is a
    /// grey halo two pixels wide at 16, and it makes the whole icon read as smudged rather than
    /// raised — so the small renders get a clean edge instead.

    static let gradientTop = (r: 0.290, g: 0.482, b: 0.969)   // #4A7BF7
    static let gradientBottom = (r: 0.137, g: 0.251, b: 0.722) // #2340B8

    /// How much of the rounded square the panes occupy. Generous, because this icon is read at
    /// 16pt far more often than at 512.
    static let contentInset: CGFloat = 0.175

    /// Fraction of the content width taken by the tall left pane.
    static let leftPaneWidth: CGFloat = 0.40
    static let paneCornerRadius: CGFloat = 0.05

    /// The gap between panes, as a fraction of the content box.
    ///
    /// Two values, because one does not work everywhere. At 512 a 7% gap is a crisp seam; at 16
    /// the same gap is a third of a pixel and the three panes blur into one rectangle, which is
    /// the failure this icon cannot afford. Small renders get a wider gap and solid white panes —
    /// the same trade every well-drawn macOS icon makes.
    static let gap: CGFloat = 0.075
    static let smallGap: CGFloat = 0.135
    /// At or below this pixel size, use the simplified drawing.
    static let smallThreshold = 40

    static let shadowThreshold = 32

    /// Depth, so the panes read as stacked windows rather than as a flat grid. A gentle step: at
    /// 0.76 the third pane read as grey rather than as white in shade.
    static let paneAlpha: (left: CGFloat, topRight: CGFloat, bottomRight: CGFloat) = (1.0, 0.92, 0.82)
}

// MARK: Drawing

/// A superellipse: |x/a|^n + |y/b|^n = 1, sampled into a path. Apple's icon corner.
func squirclePath(in rect: CGRect, exponent n: CGFloat, samples: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let power = 2 / n
    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), power)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), power)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// The three pane rectangles inside the content box.
///
/// `snapped` rounds every edge to a whole pixel and forces the gaps to at least one. Without it a
/// 16px render puts each seam on a fraction of a pixel, antialiasing paints it as a pale smear,
/// and the three panes read as one rectangle with a crease — at exactly the size this icon is
/// seen most. Large renders keep the exact proportions, where a sub-pixel edge is invisible.
func panes(in content: CGRect, snapped: Bool) -> (left: CGRect, topRight: CGRect, bottomRight: CGRect) {
    guard snapped else {
        let gap = Design.gap * content.width
        let leftWidth = (content.width - gap) * Design.leftPaneWidth
        let rightWidth = content.width - gap - leftWidth
        let rightHeight = (content.height - gap) / 2
        return (
            CGRect(x: content.minX, y: content.minY, width: leftWidth, height: content.height),
            CGRect(x: content.maxX - rightWidth, y: content.maxY - rightHeight, width: rightWidth, height: rightHeight),
            CGRect(x: content.maxX - rightWidth, y: content.minY, width: rightWidth, height: rightHeight)
        )
    }

    let x0 = content.minX.rounded(), y0 = content.minY.rounded()
    let width = (content.width).rounded(), height = (content.height).rounded()
    let gap = max(1, (Design.smallGap * content.width).rounded())
    let leftWidth = max(1, ((width - gap) * Design.leftPaneWidth).rounded())
    let rightWidth = max(1, width - gap - leftWidth)
    // Split what is left after the gap, giving the odd pixel to the top pane so the pair always
    // fills the box exactly rather than leaving a stray row of background.
    let bottomHeight = max(1, ((height - gap) / 2).rounded(.down))
    let topHeight = max(1, height - gap - bottomHeight)
    return (
        CGRect(x: x0, y: y0, width: leftWidth, height: height),
        CGRect(x: x0 + width - rightWidth, y: y0 + height - topHeight, width: rightWidth, height: topHeight),
        CGRect(x: x0 + width - rightWidth, y: y0, width: rightWidth, height: bottomHeight)
    )
}

func drawIcon(pixels: Int, into ctx: CGContext) {
    let scale = CGFloat(pixels) / Design.canvas
    let simplified = pixels <= Design.smallThreshold

    let side = Design.squareSide * scale
    let square = CGRect(
        x: Design.squareInset * scale,
        y: Design.squareInset * scale,
        width: side,
        height: side
    )
    let shape = squirclePath(in: square, exponent: Design.cornerExponent)

    // The shadow is cast by an opaque fill of the same shape, then painted over.
    if pixels > Design.shadowThreshold {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -Design.shadowOffset * scale),
            blur: Design.shadowBlur * scale,
            color: CGColor(gray: 0, alpha: Design.shadowAlpha)
        )
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let top = Design.gradientTop, bottom = Design.gradientBottom
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(colorSpace: space, components: [top.r, top.g, top.b, 1])!,
            CGColor(colorSpace: space, components: [bottom.r, bottom.g, bottom.b, 1])!,
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: square.midX, y: square.maxY),
        end: CGPoint(x: square.midX, y: square.minY),
        options: []
    )
    ctx.restoreGState()

    // The panes.
    let inset = side * Design.contentInset
    let content = square.insetBy(dx: inset, dy: inset)
    let radius = max(Design.paneCornerRadius * content.width, simplified ? 0 : 1)
    let (left, topRight, bottomRight) = panes(in: content, snapped: simplified)

    // Solid white when small: the alpha steps that give depth at 512 only muddy the edges at 16,
    // where every pane is a handful of pixels.
    let alphas = simplified
        ? (left: CGFloat(1), topRight: CGFloat(1), bottomRight: CGFloat(1))
        : Design.paneAlpha
    for (rect, alpha) in [(left, alphas.left), (topRight, alphas.topRight), (bottomRight, alphas.bottomRight)] {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(CGColor(gray: 1, alpha: alpha))
        ctx.fillPath()
    }
}

func renderPNG(pixels: Int, to url: URL) throws {
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw Failure("could not create a \(pixels)px context")
    }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    drawIcon(pixels: pixels, into: ctx)

    guard let image = ctx.makeImage() else { throw Failure("could not render \(pixels)px") }
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw Failure("could not write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure("could not finalize \(url.path)") }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: The catalog

/// Every entry macOS asks for. The same file serves two entries wherever a 1x and a 2x resolve to
/// the same pixel size.
let entries: [(size: String, scale: String, pixels: Int)] = [
    ("16x16", "1x", 16), ("16x16", "2x", 32),
    ("32x32", "1x", 32), ("32x32", "2x", 64),
    ("128x128", "1x", 128), ("128x128", "2x", 256),
    ("256x256", "1x", 256), ("256x256", "2x", 512),
    ("512x512", "1x", 512), ("512x512", "2x", 1024),
]

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: main.swift <appiconset directory>\n".utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for pixels in Set(entries.map(\.pixels)).sorted() {
    try renderPNG(pixels: pixels, to: outputDirectory.appendingPathComponent("icon_\(pixels).png"))
    print("rendered \(pixels)px")
}

let images = entries.map { entry in
    """
        {
          "filename" : "icon_\(entry.pixels).png",
          "idiom" : "mac",
          "scale" : "\(entry.scale)",
          "size" : "\(entry.size)"
        }
    """
}
let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(to: outputDirectory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
