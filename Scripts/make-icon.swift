// Draws MountMate's app icon and writes Resources/MountMate.icns.
//
// The drawing code is the source of truth; the .icns is a build product. Changing a
// colour means editing this file and re-running, not opening an image editor.
//
//   swift Scripts/make-icon.swift
//
// Artwork sits on Apple's macOS icon grid: an 824pt rounded square centred in a
// 1024pt canvas, not a full-bleed square. A full-bleed icon looks oversized beside
// system icons, which is the most common way a hand-made macOS icon announces itself.
//
// The corners are circular rather than Apple's continuous ("squircle") curve. At icon
// sizes the difference is slight, and a circular corner needs no hand-fitted bezier.
//
// The gaps between the three elements are ~96pt, which is deliberate: at 32px — Finder
// sidebar size — the whole icon is a 32x downscale, so a 36pt gap renders as one pixel
// and the bars merge into a block. Legibility at the smallest size sets the spacing.

import AppKit
import Foundation

let canvas: CGFloat = 1024

let tileTop = CGColor(red: 0.36, green: 0.62, blue: 0.87, alpha: 1)
let tileBottom = CGColor(red: 0.13, green: 0.36, blue: 0.66, alpha: 1)
let cutout = CGColor(red: 0.13, green: 0.36, blue: 0.66, alpha: 1)

/// Draws the icon into `context`, which is assumed to be `pixels` square with the
/// origin at the bottom left. All coordinates below are in the 1024pt design space.
func draw(into context: CGContext, pixels: CGFloat) {
    context.scaleBy(x: pixels / canvas, y: pixels / canvas)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(
        roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil
    )

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space, colors: [tileTop, tileBottom] as CFArray, locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 512, y: 924),
        end: CGPoint(x: 512, y: 100),
        options: []
    )
    context.restoreGState()

    // Two drive bars, each with an indicator dot punched back out in the tile colour.
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    for barY in [CGFloat(674), CGFloat(468)] {
        let bar = CGRect(x: 262, y: barY, width: 500, height: 110)
        context.addPath(
            CGPath(roundedRect: bar, cornerWidth: 30, cornerHeight: 30, transform: nil)
        )
        context.fillPath()
    }

    context.setFillColor(cutout)
    for dotY in [CGFloat(729), CGFloat(523)] {
        context.addEllipse(in: CGRect(x: 322, y: dotY - 26, width: 52, height: 52))
        context.fillPath()
    }

    // The heartbeat: what the app actually does is watch, not just attach.
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setLineWidth(50)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 262, y: 300))
    context.addLine(to: CGPoint(x: 380, y: 300))
    context.addLine(to: CGPoint(x: 432, y: 366))
    context.addLine(to: CGPoint(x: 498, y: 236))
    context.addLine(to: CGPoint(x: 552, y: 300))
    context.addLine(to: CGPoint(x: 762, y: 300))
    context.strokePath()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

/// Renders one PNG and verifies it came out at the size asked for. A half-built icon
/// that looks fine until Finder caches it is worse than a loud failure here.
func render(pixels: Int, to url: URL) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { fail("could not allocate a \(pixels)px bitmap") }

    guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
        fail("could not make a drawing context for \(pixels)px")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    draw(into: graphics.cgContext, pixels: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fail("could not encode \(pixels)px as PNG")
    }
    do { try data.write(to: url) } catch { fail("could not write \(url.path): \(error)") }

    guard let written = NSBitmapImageRep(data: data),
          written.pixelsWide == pixels, written.pixelsHigh == pixels else {
        fail("\(url.lastPathComponent) is not \(pixels)x\(pixels)")
    }
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let iconset = root.appendingPathComponent(".build/MountMate.iconset")
let resources = root.appendingPathComponent("Resources")
let output = resources.appendingPathComponent("MountMate.icns")

try? FileManager.default.removeItem(at: iconset)
do {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
} catch { fail("could not create output directories: \(error)") }

// The ten representations iconutil expects. Note 32 and 256 appear twice under
// different names: that is required, not a mistake.
let representations: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for representation in representations {
    render(
        pixels: representation.pixels,
        to: iconset.appendingPathComponent(representation.name)
    )
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
do { try iconutil.run() } catch { fail("could not run iconutil: \(error)") }
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fail("iconutil exited \(iconutil.terminationStatus)")
}

let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
guard let bytes = attributes?[.size] as? Int, bytes > 10_000 else {
    fail("\(output.path) is missing or implausibly small")
}

print("Wrote \(output.path) (\(bytes) bytes, \(representations.count) representations)")
