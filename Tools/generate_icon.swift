#!/usr/bin/env swift
// Generates the app icon in the same periodic-table style as M3 Tracker: atomic number
// "27", tipped 45° to the left, the "Cl" symbol, and the name along the bottom, on
// a deep camera-lens blue.
// Run with:
//   swift Tools/generate_icon.swift
//
// Produces two variants, because the name is an unreadable smudge at the 16
// and 32 point sizes macOS uses in Finder lists and dialogs:
//   Resources/AppIcon.png       — full tile, used from 128pt up
//   Resources/AppIcon-small.png — no name, larger symbol, used at 16-64pt

import AppKit

let textColor = NSColor.white

func renderIcon(includeName: Bool) -> NSImage {
let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))

image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no graphics context")
}

// A small margin keeps the tile from looking oversized beside other Dock icons.
let margin = canvas * 0.045
let tile = CGRect(x: margin, y: margin, width: canvas - margin * 2, height: canvas - margin * 2)
let side = tile.width
let cornerRadius = side * 0.215

let tilePath = CGPath(roundedRect: tile, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

// MARK: - Blue body

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bodyColors = [
    NSColor(srgbRed: 0.27, green: 0.52, blue: 1.00, alpha: 1.0).cgColor,
    NSColor(srgbRed: 0.08, green: 0.20, blue: 0.68, alpha: 1.0).cgColor,
] as CFArray
let bodyGradient = CGGradient(colorsSpace: colorSpace, colors: bodyColors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(
    bodyGradient,
    start: CGPoint(x: tile.minX, y: tile.maxY),
    end: CGPoint(x: tile.maxX, y: tile.minY),
    options: []
)

// Glossy sheen sweeping across the upper-left, as in the reference art.
let gloss = CGMutablePath()
gloss.move(to: CGPoint(x: tile.minX, y: tile.minY + side * 0.52))
gloss.addCurve(
    to: CGPoint(x: tile.minX + side * 0.68, y: tile.maxY),
    control1: CGPoint(x: tile.minX + side * 0.30, y: tile.minY + side * 0.78),
    control2: CGPoint(x: tile.minX + side * 0.34, y: tile.maxY)
)
gloss.addLine(to: CGPoint(x: tile.minX, y: tile.maxY))
gloss.closeSubpath()
ctx.addPath(gloss)
ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
ctx.fillPath()

ctx.restoreGState()

// MARK: - Text

func draw(_ string: String, size: CGFloat, at point: CGPoint) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .bold),
        .foregroundColor: textColor,
    ]
    NSAttributedString(string: string, attributes: attributes).draw(at: point)
}

func size(of string: String, size: CGFloat) -> NSSize {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .bold)
    ]
    return NSAttributedString(string: string, attributes: attributes).size()
}

// Atomic number, top-left, tipped 45° to the left (counterclockwise) about
// its own center. Nudged up in the small variant so it still reads once the
// name is gone.
let number = "27"
let numberSize = side * (includeName ? 0.115 : 0.135)
let numberInset = side * 0.075
let numberBox = size(of: number, size: numberSize)
let numberCenter = CGPoint(
    x: tile.minX + numberInset + numberBox.width / 2,
    y: tile.maxY - numberInset - numberBox.height / 2
)
ctx.saveGState()
ctx.translateBy(x: numberCenter.x, y: numberCenter.y)
ctx.rotate(by: .pi / 4)
draw(number, size: numberSize, at: CGPoint(x: -numberBox.width / 2, y: -numberBox.height / 2))
ctx.restoreGState()

// The element symbol, centered. Without the name below it, it grows and recenters to
// fill the tile.
let symbol = "Cl"
// A two-letter symbol is wider than M3's "M³", so the nameless variant can't grow as far without
// running into the 27; it sits a little below center to clear it.
drawSymbol("Cl", in: tile, includeName: includeName, ctx: ctx)

// Name along the bottom.
if includeName {
    let nameSize = side * 0.088
    let name = "CaptureLens"
    let nameWidth = size(of: name, size: nameSize).width
    draw(name, size: nameSize, at: CGPoint(
        x: tile.midX - nameWidth / 2,
        y: tile.minY + side * 0.105
    ))
}

image.unlockFocus()
return image
}

// MARK: - Element symbol (shared rule across every app's icon)

/// Draws the element symbol at the same visual size in every app's icon, matched to
/// Migraine Tracker's "Mt": capitals 43.5% of the tile tall, baseline 29% of the way up.
/// A wide symbol shrinks only as far as needed to stay within 66% of the tile's width.
/// Without the name (the 16-64pt variant) it grows a little and sits just below center,
/// clear of the 27.
func drawSymbol(_ symbol: String, in tile: CGRect, includeName: Bool, ctx: CGContext,
                superscript: String? = nil) {
    let side = tile.width
    let capTarget = side * (includeName ? 0.435 : 0.46)
    let maxWidth = side * (includeName ? 0.66 : 0.70)
    func font(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: .bold) }
    func line(_ text: String, _ size: CGFloat) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font(size), .foregroundColor: textColor,
        ]))
    }
    func ink(_ text: String, _ size: CGFloat) -> CGRect {
        ctx.textPosition = .zero
        return CTLineGetImageBounds(line(text, size), ctx)
    }
    // A superscript (M3 Tracker's "³") rides at 40% of the symbol's size, top-aligned with it.
    func totalWidth(_ size: CGFloat) -> CGFloat {
        let main = ink(symbol, size)
        guard let superscript else { return main.width }
        return main.maxX - main.minX + ink(superscript, size * 0.40).width + size * 0.02
    }
    let reference: CGFloat = 100
    let size = min(capTarget / font(reference).capHeight * reference,
                   maxWidth / totalWidth(reference) * reference)
    let capHeight = font(size).capHeight
    let main = ink(symbol, size)
    let x = tile.midX - totalWidth(size) / 2 - main.minX
    let baseline = includeName ? tile.minY + side * 0.29 : tile.midY - capHeight / 2 - side * 0.07

    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(line(symbol, size), ctx)
    if let superscript {
        let small = size * 0.40
        let supInk = ink(superscript, small)
        ctx.textPosition = CGPoint(x: x + main.maxX + size * 0.02 - supInk.minX,
                                   y: baseline + capHeight - supInk.maxY)
        CTLineDraw(line(superscript, small), ctx)
    }
    ctx.restoreGState()
}


// MARK: - Write PNGs

func write(_ image: NSImage, to path: String) throws {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("failed to render PNG")
    }
    try png.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path)")
}

try write(renderIcon(includeName: true), to: "Resources/AppIcon.png")
try write(renderIcon(includeName: false), to: "Resources/AppIcon-small.png")
