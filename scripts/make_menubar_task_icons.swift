#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates the approved B logo: a compact laptop with a >_ terminal mark.
/// All variants stay 18 points square. Idle uses an outlined screen; ordinary
/// keep-awake uses a filled screen with a transparent terminal cutout. Working
/// and attention retain their existing green/red colors and outlined geometry.
/// The asset catalogs keep neutral variants as templates and task colors original.
let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let repositoryRoot = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let assetRoot = repositoryRoot.appendingPathComponent("Resources/Assets.xcassets")
let pointSize = 18

struct Variant {
    let assetName: String
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let filledScreen: Bool
}

let variants = [
    Variant(assetName: "MenubarLaptop", red: 255, green: 255, blue: 255, filledScreen: false),
    Variant(assetName: "MenubarLaptopActive", red: 255, green: 255, blue: 255, filledScreen: true),
    Variant(assetName: "MenubarLaptopWorking", red: 52, green: 199, blue: 89, filledScreen: false),
    Variant(assetName: "MenubarLaptopAttention", red: 255, green: 59, blue: 48, filledScreen: false),
]

func render(destinationURL: URL, variant: Variant, scale: Int) {
    let width = pointSize * scale
    let height = width
    let bytesPerRow = width * 4
    let byteCount = bytesPerRow * height
    let pixels = UnsafeMutableRawPointer.allocate(
        byteCount: byteCount,
        alignment: MemoryLayout<UInt32>.alignment
    )
    defer { pixels.deallocate() }
    pixels.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        fatalError("Could not create bitmap context for \(destinationURL.path)")
    }

    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    guard let tintColor = CGColor(
        colorSpace: colorSpace,
        components: [
            CGFloat(variant.red) / 255,
            CGFloat(variant.green) / 255,
            CGFloat(variant.blue) / 255,
            1,
        ]
    ) else {
        fatalError("Could not create sRGB tint for \(variant.assetName)")
    }
    context.setFillColor(tintColor)
    context.setStrokeColor(tintColor)

    // A 1.35-point frame and a separate rounded base preserve the laptop
    // silhouette at 1x without enlarging the menu-bar item's hit area.
    let screen = CGMutablePath()
    screen.addRoundedRect(
        in: CGRect(x: 2, y: 4.05, width: 14, height: 11.85),
        cornerWidth: 2.8,
        cornerHeight: 2.8
    )
    if !variant.filledScreen {
        screen.addRoundedRect(
            in: CGRect(x: 3.35, y: 5.4, width: 11.3, height: 9.15),
            cornerWidth: 1.45,
            cornerHeight: 1.45
        )
    }
    context.addPath(screen)
    context.fillPath(using: .evenOdd)
    context.addPath(CGPath(
        roundedRect: CGRect(x: 1, y: 1.5, width: 16, height: 1.55),
        cornerWidth: 0.775,
        cornerHeight: 0.775,
        transform: nil
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
    if variant.filledScreen {
        // Template icons need an alpha cutout, not a painted black symbol,
        // so the filled screen works on both light and dark menu bars.
        context.setBlendMode(.clear)
    }
    context.addPath(terminal)
    context.strokePath()

    let bytes = pixels.assumingMemoryBound(to: UInt8.self)
    var visiblePixelCount = 0
    let allVisiblePixelsHaveTargetColor = stride(
        from: 0,
        to: byteCount,
        by: 4
    ).allSatisfy { offset in
        let alpha = Int(bytes[offset + 3])
        guard alpha > 0 else { return true }
        visiblePixelCount += 1
        let expectedRed = Int(variant.red) * alpha / 255
        let expectedGreen = Int(variant.green) * alpha / 255
        let expectedBlue = Int(variant.blue) * alpha / 255
        return abs(Int(bytes[offset]) - expectedRed) <= 2
            && abs(Int(bytes[offset + 1]) - expectedGreen) <= 2
            && abs(Int(bytes[offset + 2]) - expectedBlue) <= 2
    }
    guard visiblePixelCount > 0,
          allVisiblePixelsHaveTargetColor,
          let outputImage = context.makeImage() else {
        fatalError("Render validation failed for \(destinationURL.path)")
    }

    guard let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("Could not create \(destinationURL.path)")
    }
    CGImageDestinationAddImage(destination, outputImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not encode \(destinationURL.path)")
    }
}

for variant in variants {
    let destinationRoot = assetRoot.appendingPathComponent("\(variant.assetName).imageset")
    try FileManager.default.createDirectory(
        at: destinationRoot,
        withIntermediateDirectories: true
    )

    for scale in 1...3 {
        let suffix = scale == 1 ? "" : "@\(scale)x"
        let destinationURL = destinationRoot.appendingPathComponent(
            "\(variant.assetName)\(suffix).png"
        )
        render(destinationURL: destinationURL, variant: variant, scale: scale)
        print("wrote \(destinationURL.path)")
    }
}
