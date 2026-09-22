// Renders the .iconset the build script feeds to iconutil. Run as a script:
//   swift tools/MakeIcon.swift <output-iconset-dir>
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("usage: MakeIcon.swift <iconset-dir>\n".data(using: .utf8)!)
    exit(1)
}
let outputDir = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func pigment(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1)
}

/// A week, in miniature.
///
/// Not a dot grid and not a page-with-a-date: the icon is the thing the app
/// actually shows you — seven columns of ink with pigment blocks laid across
/// them, and the red now-line cutting through. It carries the same rule as the
/// interface: the ground is monochrome, and every bit of colour is an event.
///
/// At 16pt the blocks collapse to coloured dashes, which still reads as a
/// schedule rather than turning to mud.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }
    NSGraphicsContext.current?.imageInterpolation = .high

    let s = { (v: CGFloat) in v * size / 1024 }
    let body = NSRect(x: s(100), y: s(100), width: s(824), height: s(824))
    let squircle = NSBezierPath(roundedRect: body, xRadius: s(185), yRadius: s(185))

    NSGradient(colors: [pigment(0x23272E), pigment(0x14161A)])?.draw(in: squircle, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()

    // Five columns, inset from the squircle so nothing crowds the corners.
    let field = body.insetBy(dx: s(112), dy: s(126))
    let columns = 5
    let gap = s(26)
    let columnWidth = (field.width - gap * CGFloat(columns - 1)) / CGFloat(columns)

    func columnX(_ index: Int) -> CGFloat {
        field.minX + CGFloat(index) * (columnWidth + gap)
    }

    // Faint column rules: the grid the blocks sit on.
    pigment(0xFFFFFF).withAlphaComponent(0.07).setFill()
    for index in 0..<columns {
        NSRect(x: columnX(index), y: field.minY, width: columnWidth, height: field.height).fill()
    }

    // (column, top, bottom) as fractions down the field, with a pigment each.
    let blocks: [(Int, CGFloat, CGFloat, NSColor)] = [
        (0, 0.16, 0.38, pigment(0x2A6C9C)),   // Cerulean
        (1, 0.04, 0.24, pigment(0xC2402D)),   // Vermilion
        (1, 0.52, 0.70, pigment(0xBE9A1F)),   // Ochre
        (2, 0.30, 0.60, pigment(0x34877A)),   // Verdigris
        (3, 0.10, 0.30, pigment(0x4A48A0)),   // Ultramarine
        (3, 0.68, 0.86, pigment(0xA63F76)),   // Magenta
        (4, 0.40, 0.58, pigment(0xCE7C22)),   // Amber
    ]

    let radius = s(14)
    for (column, top, bottom, colour) in blocks {
        let y = field.maxY - bottom * field.height
        let height = (bottom - top) * field.height
        let rect = NSRect(x: columnX(column), y: y, width: columnWidth, height: height)
        colour.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    // The now-line: the one hue the chrome allows itself, here as everywhere.
    let nowY = field.maxY - 0.635 * field.height
    pigment(0xC7332A).setFill()
    NSRect(x: body.minX, y: nowY, width: body.width, height: s(9)).fill()
    NSBezierPath(ovalIn: NSRect(x: field.minX - s(30), y: nowY - s(15),
                                width: s(40), height: s(40))).fill()

    NSGraphicsContext.restoreGraphicsState()
    return image
}

func write(_ image: NSImage, pixels: Int, to name: String) {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else { return }
    bitmap.size = NSSize(width: pixels, height: pixels)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: outputDir.appendingPathComponent(name))
}

for base in [16, 32, 128, 256, 512] {
    write(drawIcon(size: CGFloat(base)), pixels: base, to: "icon_\(base)x\(base).png")
    write(drawIcon(size: CGFloat(base * 2)), pixels: base * 2, to: "icon_\(base)x\(base)@2x.png")
}
print("wrote iconset to \(outputDir.path)")
