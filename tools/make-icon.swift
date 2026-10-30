// swift tools/make-icon.swift <source.png> <out-dir>
// Cuts the rounded tile out of the black-cornered source art: logo.png (full bleed, for the
// sidebar) and AppIcon.icns (macOS grid: 824pt tile centred in 1024 with transparent margin).
import AppKit

let source = NSImage(contentsOfFile: CommandLine.arguments[1])!
let out = URL(fileURLWithPath: CommandLine.arguments[2])
// Tile bounds in the 1254px source (measured), slightly inset to drop the black rim.
let tile = NSRect(x: 62, y: 52, width: 1130, height: 1130)

func render(size: Int, inset: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let box = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: CGFloat(size) * inset, dy: CGFloat(size) * inset)
    NSBezierPath(roundedRect: box, xRadius: box.width * 0.2237, yRadius: box.width * 0.2237).addClip()
    // NSImage origin is bottom-left; the measured rect is top-left based.
    let from = NSRect(x: tile.minX, y: source.size.height - tile.maxY, width: tile.width, height: tile.height)
    source.draw(in: box, from: from, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try render(size: 512, inset: 0).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("logo.png"))
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: base * scale, inset: 0.0977).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
