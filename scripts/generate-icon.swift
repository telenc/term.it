#!/usr/bin/env swift
// Génère Resources/AppIcon.icns : fond sombre arrondi + prompt ">_" vert.
// Usage : swift scripts/generate-icon.swift
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let fm = FileManager.default
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    // Fond arrondi (squircle approximé par un rounded rect continu).
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = (s - 2 * inset) * 0.235
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()

    // Dégradé sombre.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
    ])!
    gradient.draw(in: rect, angle: -90)

    // Prompt ">_" vert, monospace gras.
    let glyph = "›_"
    let fontSize = s * 0.42
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(srgbRed: 0.40, green: 0.92, blue: 0.55, alpha: 1)
    ]
    let str = NSAttributedString(string: glyph, attributes: attrs)
    let textSize = str.size()
    str.draw(at: NSPoint(x: (s - textSize.width) / 2, y: (s - textSize.height) / 2 + s * 0.02))

    image.unlockFocus()
    return image
}

func png(_ image: NSImage, _ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Écrit les variantes de l'iconset.
func write(_ pixels: Int, _ name: String) {
    let data = png(render(pixels), pixels)
    try! data.write(to: iconset.appendingPathComponent(name))
}
write(16, "icon_16x16.png");    write(32, "icon_16x16@2x.png")
write(32, "icon_32x32.png");    write(64, "icon_32x32@2x.png")
write(128, "icon_128x128.png"); write(256, "icon_128x128@2x.png")
write(256, "icon_256x256.png"); write(512, "icon_256x256@2x.png")
write(512, "icon_512x512.png"); write(1024, "icon_512x512@2x.png")

// Compile en .icns.
try? fm.createDirectory(at: URL(fileURLWithPath: "Resources"), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print("✅ Resources/AppIcon.icns généré")
