import AppKit

// The approved mist-lilac artwork is kept in Resources as SVG and 1024px PNG.
// Generate every macOS icon size from that same PNG without redrawing the logo.
let directory = CommandLine.arguments[1]
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: sourceURL) else {
    fatalError("Cannot load Orvia logo: \(sourceURL.path)")
}
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot create \(size)px icon bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode \(size)px icon")
    }
    let name: String
    switch size {
    case 16: name = "icon_16x16.png"
    case 32: name = "icon_16x16@2x.png"
    case 64: name = "icon_32x32@2x.png"
    case 128: name = "icon_128x128.png"
    case 256: name = "icon_128x128@2x.png"
    case 512: name = "icon_256x256@2x.png"
    default: name = "icon_512x512@2x.png"
    }
    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    if size == 32 || size == 256 || size == 512 {
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("icon_\(size)x\(size).png"))
    }
}
