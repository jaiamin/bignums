// Draws the app icon and writes Resources/AppIcon.icns. Run from the project root: swift scripts/make-icon.swift
import AppKit

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    // The macOS icon shape: a rounded square inset a little from the canvas.
    let inset = s * 0.0977
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.27, alpha: 1), NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1)])!
        .draw(in: path, angle: -90)
    // A light, large dollar sign, like the figure in the menu.
    let font = NSFont.systemFont(ofSize: rect.width * 0.62, weight: .light)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.97, alpha: 1)]
    let text = NSAttributedString(string: "$", attributes: attributes)
    let textSize = text.size()
    text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2 - rect.height * 0.01))
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try process.run()
process.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(process.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
