#!/usr/bin/env swift

// Draws MacClipboard's app icon and writes every size Xcode's asset catalog asks for.
//
// Why the icon is drawn in code rather than exported from a design tool: it is a clipboard on a
// rounded square, and a hundred lines of Core Graphics is a smaller thing to maintain than a
// binary nobody can diff. Re-run it to change the colours or the shape; the PNGs it writes are
// checked in, so a normal build never needs Swift on the path.
//
// **No SF Symbol is used here, deliberately.** SF Symbols are licensed for use *in* an app's
// interface and explicitly not in app icons, so the clipboard is drawn by hand. The menu bar item
// keeps using `doc.on.clipboard`, which is exactly the use the licence allows.
//
// Usage: ./scripts/make-app-icon.swift

import AppKit
import Foundation

// MARK: - The design

/// The rounded square every macOS icon sits on.
///
/// Apple's grid for a macOS app icon puts the body in the middle 824 points of a 1024 point canvas
/// with a corner radius of 185.4, so the numbers below are those proportions rather than taste.
/// Getting them wrong is what makes an icon look a size too big or too small beside its neighbours
/// in the Dock.
enum Grid {
    static let bodyFraction: CGFloat = 824.0 / 1024.0
    static let cornerFraction: CGFloat = 185.4 / 824.0
}

/// Blue, because the app's own interface uses the system accent for everything it highlights, and
/// because the sibling app on this Mac (MacStats) is green: two menu bar apps whose icons are
/// twenty points wide have to be told apart by colour before anything else.
enum Palette {
    static let top = NSColor(srgbRed: 0.36, green: 0.60, blue: 1.00, alpha: 1)
    static let bottom = NSColor(srgbRed: 0.13, green: 0.31, blue: 0.85, alpha: 1)
}

/// The background gradient, which is painted twice: once over the whole rounded square, and again
/// through every shape that has to read as a gap in the white.
func makeGradient() -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [Palette.top.cgColor, Palette.bottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
}

/// Paints the background back through `path`.
///
/// This is how a gap in the clipboard is cut, rather than with `destinationOut`, and the first
/// version of this script got that wrong: erasing takes the *gradient* away with the white and
/// leaves a transparent hole, which is invisible against a white page and a hole in the icon
/// everywhere else. Re-drawing the same gradient through a clip is exact by construction.
func paintBackground(through path: CGPath, in body: CGRect, context: CGContext) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(
        makeGradient(),
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.minY),
        options: []
    )
    context.restoreGState()
}

/// The clipboard, drawn into `body` (the rounded square, already filled).
///
/// Three shapes: the board, the clip straddling its top edge, and two lines of writing. The lines
/// are dropped below 64 points, where they would be under a pixel tall and read as grey mush
/// rather than as writing. Everything is a fraction of the body, so a 16 point icon and a 1024
/// point one are the same drawing rather than one resampled from the other.
func drawClipboard(in body: CGRect, size: CGFloat, context: CGContext) {
    let boardWidth = body.width * 0.52
    let boardHeight = body.height * 0.60
    let board = CGRect(
        x: body.midX - boardWidth / 2,
        y: body.midY - boardHeight / 2 - body.height * 0.04,
        width: boardWidth,
        height: boardHeight
    )

    context.setFillColor(NSColor.white.cgColor)
    context.addPath(CGPath(
        roundedRect: board,
        cornerWidth: boardWidth * 0.14,
        cornerHeight: boardWidth * 0.14,
        transform: nil
    ))
    context.fillPath()

    // The clip. It straddles the board's top edge, which is what makes the shape read as a
    // clipboard rather than as a tablet: the gap around it is the background drawn back through,
    // so the clip is separated from the board by the icon's own colour.
    let clipWidth = boardWidth * 0.52
    let clipHeight = boardHeight * 0.17
    let clip = CGRect(
        x: board.midX - clipWidth / 2,
        y: board.maxY - clipHeight * 0.5,
        width: clipWidth,
        height: clipHeight
    )
    let gap = clip.insetBy(dx: -clipHeight * 0.28, dy: -clipHeight * 0.28)
    paintBackground(
        through: CGPath(roundedRect: gap, cornerWidth: gap.height / 2, cornerHeight: gap.height / 2, transform: nil),
        in: body,
        context: context
    )

    context.setFillColor(NSColor.white.cgColor)
    context.addPath(CGPath(
        roundedRect: clip,
        cornerWidth: clipHeight * 0.45,
        cornerHeight: clipHeight * 0.45,
        transform: nil
    ))
    context.fillPath()

    guard size >= 64 else { return }

    // Two lines of writing, cut out of the board the same way.
    let lineHeight = boardHeight * 0.072
    let lineInset = boardWidth * 0.18
    let lines = CGMutablePath()
    for (index, widthFraction) in [1.0, 0.60].enumerated() {
        let lineWidth = (boardWidth - lineInset * 2) * widthFraction
        let y = board.midY - lineHeight / 2 - CGFloat(index) * lineHeight * 2.6 + boardHeight * 0.07
        lines.addRoundedRect(
            in: CGRect(x: board.minX + lineInset, y: y, width: lineWidth, height: lineHeight),
            cornerWidth: lineHeight / 2,
            cornerHeight: lineHeight / 2
        )
    }
    paintBackground(through: lines, in: body, context: context)
}

// MARK: - Rendering

/// One icon, at one pixel size, drawn rather than scaled.
///
/// Rendering each size from the same proportions beats rendering 1024 and resampling: a resampled
/// 16 point icon is a soft grey square, and 16 is the size the menu bar and a settings list draw.
func renderIcon(size: CGFloat) -> Data {
    let pixels = Int(size)
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("could not create a \(pixels)x\(pixels) context")
    }

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    let body = canvas.insetBy(
        dx: size * (1 - Grid.bodyFraction) / 2,
        dy: size * (1 - Grid.bodyFraction) / 2
    )
    let corner = body.width * Grid.cornerFraction

    // The rounded square, clipped so the gradient stops at its edge.
    context.saveGState()
    context.addPath(CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil))
    context.clip()
    context.drawLinearGradient(
        makeGradient(),
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.minY),
        options: []
    )
    context.restoreGState()

    drawClipboard(in: body, size: size, context: context)

    guard let image = context.makeImage() else { fatalError("could not render \(pixels)x\(pixels)") }
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: pixels, height: pixels)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(pixels)x\(pixels) as PNG")
    }
    return data
}

// MARK: - The asset catalog

/// One entry per image the catalog asks for: the point size, the scale, and the pixels that means.
let entries: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

let scriptDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
let iconset = scriptDirectory
    .deletingLastPathComponent()
    .appendingPathComponent("MacClipboard/Assets.xcassets/AppIcon.appiconset")

guard FileManager.default.fileExists(atPath: iconset.path) else {
    FileHandle.standardError.write(Data("no AppIcon.appiconset at \(iconset.path)\n".utf8))
    exit(1)
}

var images: [[String: String]] = []
for entry in entries {
    let pixels = entry.points * entry.scale
    let name = "icon_\(entry.points)x\(entry.points)\(entry.scale == 2 ? "@2x" : "").png"
    try renderIcon(size: CGFloat(pixels)).write(to: iconset.appendingPathComponent(name))
    images.append([
        "idiom": "mac",
        "size": "\(entry.points)x\(entry.points)",
        "scale": "\(entry.scale)x",
        "filename": name,
    ])
    print("wrote \(name) (\(pixels)x\(pixels))")
}

// Written rather than edited by hand, so the filenames and the entries cannot drift apart. The key
// order matches what Xcode writes, so opening the catalog in Xcode leaves no diff behind.
let contents: [String: Any] = [
    "images": images.map { image in
        ["filename": image["filename"]!, "idiom": image["idiom"]!, "scale": image["scale"]!, "size": image["size"]!]
    },
    "info": ["author": "xcode", "version": 1],
]
let json = try JSONSerialization.data(
    withJSONObject: contents,
    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
)
try (String(data: json, encoding: .utf8)! + "\n").write(
    to: iconset.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)
print("wrote Contents.json")
