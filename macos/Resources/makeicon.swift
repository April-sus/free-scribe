import AppKit
import CoreGraphics
import Foundation

// Composes the layers described by Icon.icon/icon.json into a flat 1024pt macOS
// icon: light background gradient, three copies of the mark at 0.75 scale.
let assetPath = "/Users/april/Documents/Free scribe/Icon.icon/Assets/Asset.png"
let outPath = CommandLine.arguments[1]
let dark = CommandLine.arguments.contains("dark")
/// iOS masks the icon itself and refuses one with transparency, so the phone wants
/// the same artwork full-bleed and opaque rather than pre-rounded.
let square = CommandLine.arguments.contains("square")

let side: CGFloat = 1024
// macOS 26 icons are full-bleed: the squircle fills the canvas, which is the grid
// Icon Composer positions layers on. Insetting it clipped the outer marks.
let content = CGRect(x: 0, y: 0, width: side, height: side)
let radius: CGFloat = side * 0.2246

let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
guard let ctx = CGContext(
    data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8,
    bytesPerRow: 0, space: colorSpace,
    bitmapInfo: (square ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue
) else { fatalError("context") }

func p3(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, 1])!
}

// Squircle-ish rounded rect, then everything else clips to it.
if !square {
    let shape = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(shape)
    ctx.clip()
}

// Background gradient. Light and dark specs both come from icon.json.
let (top, bottom, startY, stopY): (CGColor, CGColor, CGFloat, CGFloat) = dark
    ? (p3(0, 0, 0), p3(0.13299, 0.13299, 0.13299), 0.3, 1.0)
    : (p3(0.52757, 0.50592, 0.52889), p3(0.93285, 0.94971, 0.96783), 0.0, 0.7)

let gradient = CGGradient(colorsSpace: colorSpace, colors: [top, bottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: side / 2, y: side - startY * side),
    end: CGPoint(x: side / 2, y: side - stopY * side),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)

// The mark, three times across, as the json positions them.
guard let asset = NSImage(contentsOfFile: assetPath),
      let markCG = asset.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fatalError("asset") }

let scale: CGFloat = 0.75
let markSide = side * scale
for translation in [-337.0, 0.375, 334.9453125] as [CGFloat] {
    let rect = CGRect(
        x: side / 2 + translation - markSide / 2,
        y: side / 2 - markSide / 2,
        width: markSide,
        height: markSide
    )
    if dark {
        // Dark appearance paints the mark with a gradient rather than flat black.
        ctx.saveGState()
        ctx.clip(to: rect, mask: markCG)
        let markGradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [p3(1.0, 0.9878, 0.9878), p3(0.11418, 0.11279, 0.11279)] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(
            markGradient,
            start: CGPoint(x: side / 2, y: side * 0.7),
            end: CGPoint(x: side / 2, y: -side * 0.1),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.restoreGState()
    } else {
        ctx.draw(markCG, in: rect)
    }
}

guard let image = ctx.makeImage() else { fatalError("image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
