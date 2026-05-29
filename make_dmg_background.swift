#!/usr/bin/swift
// Generates the DMG installer background image.
// Usage: swift make_dmg_background.swift <output.png>
// Output: 540x380 @2x (1080x760 pixels saved, displayed at 540x380 pt)

import AppKit
import CoreGraphics

let W: CGFloat = 540
let H: CGFloat = 380
let scale: CGFloat = 2

// ── Canvas ────────────────────────────────────────────────────────────────────
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)

NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

// ── Background gradient (top: near-white → bottom: light gray) ────────────────
let colors = [
    CGColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1),
    CGColor(red: 0.90, green: 0.90, blue: 0.90, alpha: 1)
]
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: colors as CFArray,
    locations: [0, 1])!
cg.drawLinearGradient(gradient,
    start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0),
    options: [])

// ── Subtle bottom stripe (slightly darker band for polish) ────────────────────
cg.setFillColor(CGColor(red: 0.83, green: 0.83, blue: 0.83, alpha: 1))
cg.fill(CGRect(x: 0, y: 0, width: W, height: 2))

// ── Arrow (pointing right, centered between icon positions) ───────────────────
// Icons sit at x≈135 and x≈405, so arrow center is x=270, y=175
let ax: CGFloat = 270   // arrow center x
let ay: CGFloat = 175   // arrow center y (icon area)
let bw: CGFloat = 68    // body width
let bh: CGFloat = 22    // body height
let hw: CGFloat = 34    // head width
let hh: CGFloat = 54    // head height

let arrow = NSBezierPath()
// Tip of head is at (ax + bw/2 + hw/2, ay)
let tipX  = ax + bw / 2 + hw / 2
let baseX = ax - bw / 2            // left end of body
let neckX = tipX - hw              // where head meets body

arrow.move(to:    NSPoint(x: baseX,  y: ay - bh / 2))
arrow.line(to:    NSPoint(x: neckX,  y: ay - bh / 2))
arrow.line(to:    NSPoint(x: neckX,  y: ay - hh / 2))
arrow.line(to:    NSPoint(x: tipX,   y: ay))
arrow.line(to:    NSPoint(x: neckX,  y: ay + hh / 2))
arrow.line(to:    NSPoint(x: neckX,  y: ay + bh / 2))
arrow.line(to:    NSPoint(x: baseX,  y: ay + bh / 2))
arrow.close()

NSColor(red: 0.60, green: 0.60, blue: 0.62, alpha: 1).setFill()
arrow.fill()

// ── "Drag to Applications to install" label ───────────────────────────────────
let para = NSMutableParagraphStyle()
para.alignment = .center
let labelAttrs: [NSAttributedString.Key: Any] = [
    .font:            NSFont.systemFont(ofSize: 12, weight: .medium),
    .foregroundColor: NSColor(white: 0.45, alpha: 1),
    .paragraphStyle:  para
]
("Drag Notepad to Applications to install" as NSString)
    .draw(in: NSRect(x: 70, y: 28, width: 400, height: 18), withAttributes: labelAttrs)

NSGraphicsContext.restoreGraphicsState()

// ── Write PNG ─────────────────────────────────────────────────────────────────
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/dmg_background.png"
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outputPath))
print("Background written to \(outputPath)")
