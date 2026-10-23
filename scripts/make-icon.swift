import AppKit

// Renders the app icon: a smiley on a warm gradient squircle. Usage: swift make-icon.swift out.png
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let inset = size * 0.1
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
NSGradient(colors: [NSColor(red: 1, green: 0.78, blue: 0.29, alpha: 1), NSColor(red: 1, green: 0.47, blue: 0.36, alpha: 1)])!
    .draw(in: path, angle: -90)
let emoji = "🫠" as NSString
let font = NSFont.systemFont(ofSize: size * 0.5)
let attrs: [NSAttributedString.Key: Any] = [.font: font]
let textSize = emoji.size(withAttributes: attrs)
emoji.draw(at: NSPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2), withAttributes: attrs)
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
