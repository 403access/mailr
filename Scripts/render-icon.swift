#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Draws the Mailr app icon.
//
// Usage: swift Scripts/render-icon.swift <output-directory>
//
// Produces a macOS master (squircle on Apple's 824pt grid with room for its
// shadow), an iOS master (full bleed, opaque), and small size proofs.

let canvas: CGFloat = 1024

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: colors as CFArray, locations: locations)!
}

/// A point-sampled superellipse, close to Apple's continuous-corner squircle.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Draws the artwork inside a square content box.
func drawIcon(in content: CGRect, fullBleed: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    ctx.saveGState()
    // Match UIKit/SwiftUI: origin at the top left, y growing downwards.
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShouldAntialias(true)

    // MARK: Field

    let shape = fullBleed ? CGPath(rect: content, transform: nil) : squircle(in: content)

    if !fullBleed {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 16), blur: 36, color: color(10, 20, 70, 0.38))
        ctx.addPath(shape)
        ctx.setFillColor(color(30, 45, 140))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Deep indigo, lit from the upper left.
    ctx.drawLinearGradient(
        gradient([color(112, 154, 255), color(64, 92, 226), color(36, 38, 134)],
                 [0, 0.52, 1]),
        start: CGPoint(x: content.minX, y: content.minY),
        end: CGPoint(x: content.maxX, y: content.maxY),
        options: []
    )
    ctx.drawRadialGradient(
        gradient([color(255, 255, 255, 0.30), color(255, 255, 255, 0)],
                 [0, 1]),
        startCenter: CGPoint(x: content.minX + content.width * 0.18,
                             y: content.minY + content.height * 0.12),
        startRadius: 0,
        endCenter: CGPoint(x: content.minX + content.width * 0.18,
                           y: content.minY + content.height * 0.12),
        endRadius: content.width * 0.75,
        options: []
    )

    // Settle the middle of the field so the paper separates cleanly.
    ctx.drawRadialGradient(
        gradient([color(10, 24, 90, 0.30), color(10, 24, 90, 0)],
                 [0, 1]),
        startCenter: CGPoint(x: content.midX, y: content.midY + content.height * 0.06),
        startRadius: 0,
        endCenter: CGPoint(x: content.midX, y: content.midY + content.height * 0.06),
        endRadius: content.width * 0.42,
        options: []
    )

    // MARK: Envelope

    let ew = content.width * 0.575
    let eh = ew * 0.705
    let body = CGRect(x: content.midX - ew / 2,
                      y: content.midY - eh / 2 + content.height * 0.022,
                      width: ew, height: eh)
    let radius = ew * 0.105
    let inset = ew * 0.030
    let apex = CGPoint(x: body.midX, y: body.minY + eh * 0.60)

    // Contact shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: eh * 0.10), blur: ew * 0.14,
                  color: color(8, 18, 70, 0.45))
    ctx.addPath(roundedRect(body, radius))
    ctx.setFillColor(color(240, 245, 255))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(roundedRect(body, radius))
    ctx.clip()

    // Paper.
    ctx.drawLinearGradient(
        gradient([color(255, 255, 255), color(238, 243, 255)], [0, 1]),
        start: CGPoint(x: body.midX, y: body.minY),
        end: CGPoint(x: body.midX, y: body.maxY),
        options: []
    )

    // Folded flap.
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: body.minX + inset, y: body.minY + inset))
    flap.addLine(to: apex)
    flap.addLine(to: CGPoint(x: body.maxX - inset, y: body.minY + inset))
    flap.closeSubpath()

    ctx.saveGState()
    ctx.addPath(flap)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(230, 238, 255), color(197, 216, 254)], [0, 1]),
        start: CGPoint(x: body.midX, y: body.minY),
        end: CGPoint(x: body.midX, y: apex.y),
        options: []
    )
    ctx.restoreGState()

    // Crease: soft shadow beneath the fold, bright edge on top of it.
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setShadow(offset: CGSize(width: 0, height: 5), blur: 9,
                  color: color(50, 85, 165, 0.22))
    ctx.setLineWidth(ew * 0.006)
    ctx.setStrokeColor(color(255, 255, 255, 0.9))
    ctx.move(to: CGPoint(x: body.minX + inset, y: body.minY + inset))
    ctx.addLine(to: apex)
    ctx.addLine(to: CGPoint(x: body.maxX - inset, y: body.minY + inset))
    ctx.strokePath()
    ctx.restoreGState()

    // Paper edge highlight.
    ctx.setLineWidth(ew * 0.004)
    ctx.setStrokeColor(color(255, 255, 255, 0.55))
    ctx.addPath(roundedRect(body.insetBy(dx: inset * 0.6, dy: inset * 0.6), radius - inset * 0.6))
    ctx.strokePath()

    ctx.restoreGState() // body clip

    // MARK: Unread badge

    let badgeR = ew * 0.125
    let badgeCenter = CGPoint(x: body.maxX - badgeR * 0.55, y: body.minY + badgeR * 0.55)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: badgeR * 0.18), blur: badgeR * 0.5,
                  color: color(10, 20, 70, 0.40))
    ctx.setFillColor(color(255, 255, 255))
    ctx.fillEllipse(in: CGRect(x: badgeCenter.x - badgeR * 1.10, y: badgeCenter.y - badgeR * 1.10,
                               width: badgeR * 2.20, height: badgeR * 2.20))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: badgeCenter.x - badgeR, y: badgeCenter.y - badgeR,
                              width: badgeR * 2, height: badgeR * 2))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(255, 146, 104), color(244, 90, 92)], [0, 1]),
        start: CGPoint(x: badgeCenter.x, y: badgeCenter.y - badgeR),
        end: CGPoint(x: badgeCenter.x, y: badgeCenter.y + badgeR),
        options: []
    )
    ctx.restoreGState()

    ctx.restoreGState() // field clip

    // Crisp edge along the silhouette.
    if !fullBleed {
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.setStrokeColor(color(255, 255, 255, 0.20))
        ctx.setLineWidth(2)
        ctx.strokePath()
        ctx.restoreGState()
    }

    ctx.restoreGState()
    image.unlockFocus()
    return image
}

func png(_ image: NSImage, size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Encodes without an alpha channel, as App Store icons require.
func pngOpaque(_ image: NSImage, size: CGFloat) -> Data {
    let context = CGContext(data: nil, width: Int(size), height: Int(size),
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// macOS: artwork sits on Apple's 1024 grid, inset for its shadow.
let mac = drawIcon(in: CGRect(x: 100, y: 100, width: 824, height: 824), fullBleed: false)
try! png(mac, size: 1024).write(to: out.appendingPathComponent("icon-macos-1024.png"))

// iOS: full bleed and opaque; the system applies the mask.
let ios = drawIcon(in: CGRect(x: 0, y: 0, width: 1024, height: 1024), fullBleed: true)
try! pngOpaque(ios, size: 1024).write(to: out.appendingPathComponent("icon-ios-1024.png"))

// Small-size proofs for checking legibility.
for size in [128, 64, 32, 16] {
    try! png(mac, size: CGFloat(size)).write(to: out.appendingPathComponent("preview-\(size).png"))
}

print("Wrote icons to \(out.path)")
