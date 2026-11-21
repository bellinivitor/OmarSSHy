import AppKit

func drawIcon(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(size) / 1024)
    scale.concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 87, y: 87, width: 850, height: 850), xRadius: 185, yRadius: 185)
    NSColor(srgbRed: 228 / 255.0, green: 0, blue: 43 / 255.0, alpha: 1).setFill()
    tile.fill()

    let glyph = NSBezierPath()
    glyph.move(to: NSPoint(x: 307, y: 628))
    glyph.line(to: NSPoint(x: 442, y: 512))
    glyph.line(to: NSPoint(x: 307, y: 396))
    glyph.move(to: NSPoint(x: 507, y: 396))
    glyph.line(to: NSPoint(x: 714, y: 396))
    glyph.lineWidth = 55
    glyph.lineCapStyle = .round
    glyph.lineJoinStyle = .round
    NSColor.white.setStroke()
    glyph.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

func iconChunk(_ type: String, data: Data) -> Data {
    var result = Data(type.utf8)
    let length = UInt32(data.count + 8).bigEndian
    withUnsafeBytes(of: length) { result.append(contentsOf: $0) }
    result.append(data)
    return result
}

let sizes = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)]
var representation = Data()
for (type, size) in sizes {
    representation.append(iconChunk(type, data: drawIcon(size: size)))
}
try iconChunk("icns", data: representation).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
