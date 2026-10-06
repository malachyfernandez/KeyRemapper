import Cocoa
import Foundation

// Generates the KeyRemapper app icon: a dark squircle with a keycap
// and clean ⇄ swap arrows, matching the app's Apple/system theme.
// Usage: ./gen_icon <output.png>   (draws at 2048x2048)

let size: CGFloat = 2048
let rect = NSRect(x: 0, y: 0, width: size, height: size)

let image = NSImage(size: rect.size)
image.lockFocus()

// ── Squircle background: dark gray gradient (system dark theme) ──
let radius = size * 0.224
let bgPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
NSGradient(colors: [
    NSColor(srgbRed: 0.26, green: 0.26, blue: 0.29, alpha: 1),
    NSColor(srgbRed: 0.115, green: 0.115, blue: 0.13, alpha: 1),
])!.draw(in: bgPath, angle: -90)

// Rim light
NSColor(white: 1, alpha: 0.10).setStroke()
bgPath.lineWidth = 6
bgPath.stroke()

// ── Keycap ──
let kw: CGFloat = 960, kh: CGFloat = 880
let kx = (size - kw) / 2
let ky = (size - kh) / 2 + 30
let keyPath = NSBezierPath(
    roundedRect: NSRect(x: kx, y: ky, width: kw, height: kh),
    xRadius: 150, yRadius: 150)

// Soft drop shadow under the keycap
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -14)

NSGraphicsContext.saveGraphicsState()
shadow.set()
NSGradient(colors: [
    NSColor(srgbRed: 0.30, green: 0.30, blue: 0.335, alpha: 1),
    NSColor(srgbRed: 0.215, green: 0.215, blue: 0.24, alpha: 1),
])!.draw(in: keyPath, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Keycap edge highlight
NSColor(white: 1, alpha: 0.14).setStroke()
keyPath.lineWidth = 4
keyPath.stroke()

// Top inner highlight (keycap "light")
let topHighlight = NSBezierPath(
    roundedRect: NSRect(x: kx + 10, y: ky + kh - 34, width: kw - 20, height: 24),
    xRadius: 12, yRadius: 12)
NSColor(white: 1, alpha: 0.06).setFill()
topHighlight.fill()

// ── Swap arrows inside the keycap ──
// Top arrow points right (system blue), bottom points left (light gray).

func drawArrow(fromX: CGFloat, toX: CGFloat, y: CGFloat, color: NSColor) {
    let shaftWidth: CGFloat = 88
    let headLen: CGFloat = 150
    let headHalfH: CGFloat = 105

    let dir: CGFloat = toX > fromX ? 1 : -1
    let shaftEnd = toX - dir * headLen * 0.55

    // Shaft
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: fromX, y: y))
    shaft.line(to: NSPoint(x: shaftEnd, y: y))
    shaft.lineWidth = shaftWidth
    shaft.lineCapStyle = .round
    color.setStroke()
    shaft.stroke()

    // Head (triangle)
    let head = NSBezierPath()
    head.move(to: NSPoint(x: toX, y: y))
    head.line(to: NSPoint(x: toX - dir * headLen, y: y + headHalfH))
    head.line(to: NSPoint(x: toX - dir * headLen, y: y - headHalfH))
    head.close()
    color.setFill()
    head.fill()
}

let blue = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1)   // #0a84ff
let light = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)

let pad: CGFloat = 130
let topY = ky + kh * 0.63
let botY = ky + kh * 0.37

drawArrow(fromX: kx + pad, toX: kx + kw - pad, y: topY, color: blue)
drawArrow(fromX: kx + kw - pad, toX: kx + pad, y: botY, color: light)

image.unlockFocus()

// ── Save PNG ──
let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-2048.png"
try! png.write(to: URL(fileURLWithPath: out))
print("Icon saved to \(out)")
