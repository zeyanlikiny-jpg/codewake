#!/usr/bin/env swift
// Renders the CodeWake app icon with the approved B laptop-and->_ mark.
// CoreGraphics keeps the source artwork reproducible without a window server.
// Run: swift scripts/make_icon.swift Resources/icon_1024.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "Resources/icon_1024.png"
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("Could not create app-icon context.") }

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r / 255, g / 255, b / 255, 1])!
}

context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
let background = CGRect(x: 61, y: 61, width: 902, height: 902)
let outline = CGPath(
    roundedRect: background, cornerWidth: 213, cornerHeight: 213,
    transform: nil
)
context.saveGState()
context.addPath(outline)
context.clip()
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [rgb(65, 74, 157), rgb(31, 30, 72), rgb(70, 30, 183)] as CFArray,
    locations: [0, 0.64, 1]
)!
context.drawLinearGradient(
    gradient, start: CGPoint(x: 512, y: 963), end: CGPoint(x: 512, y: 61),
    options: []
)
context.restoreGState()
context.addPath(outline)
context.setStrokeColor(rgb(103, 105, 175))
context.setLineWidth(5)
context.strokePath()

// Same 18-point geometry as the approved menu-bar laptop, scaled into the tile.
context.saveGState()
context.translateBy(x: 152, y: 152)
context.scaleBy(x: 40, y: 40)
context.setFillColor(rgb(248, 249, 255))
context.setStrokeColor(rgb(248, 249, 255))
let screen = CGMutablePath()
screen.addRoundedRect(
    in: CGRect(x: 2, y: 4.05, width: 14, height: 11.85),
    cornerWidth: 2.8, cornerHeight: 2.8
)
screen.addRoundedRect(
    in: CGRect(x: 3.35, y: 5.4, width: 11.3, height: 9.15),
    cornerWidth: 1.45, cornerHeight: 1.45
)
context.addPath(screen)
context.fillPath(using: .evenOdd)
context.addPath(CGPath(
    roundedRect: CGRect(x: 1, y: 1.5, width: 16, height: 1.55),
    cornerWidth: 0.775, cornerHeight: 0.775, transform: nil
))
context.fillPath()
let terminal = CGMutablePath()
terminal.move(to: CGPoint(x: 5.55, y: 12.05))
terminal.addLine(to: CGPoint(x: 7.65, y: 10.05))
terminal.addLine(to: CGPoint(x: 5.55, y: 8.05))
terminal.move(to: CGPoint(x: 9.65, y: 8.05))
terminal.addLine(to: CGPoint(x: 12.15, y: 8.05))
context.setLineWidth(1.5)
context.setLineCap(.round)
context.setLineJoin(.round)
context.addPath(terminal)
context.strokePath()
context.restoreGState()

guard let image = context.makeImage() else { fatalError("Could not render app icon.") }
let destinationURL = URL(fileURLWithPath: output)
guard let destination = CGImageDestinationCreateWithURL(
    destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil
) else { fatalError("Could not create app-icon PNG.") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write app-icon PNG.") }
print("wrote \(output)")
