import Cocoa
import Foundation

// Generates a background image for the DMG with an arrow from the app
// to the Applications folder, matching the app's Apple/system theme.

let width = 640
let height = 340
let rect = NSRect(x: 0, y: 0, width: width, height: height)

let image = NSImage(size: rect.size)
image.lockFocus()

// ── Background: dark, matching app theme ──
let bgPath = NSBezierPath(rect: rect)
let bgGrad = NSGradient(colors: [
    NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1.0),
    NSColor(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 1.0),
])!
bgGrad.draw(in: bgPath, angle: -120)

// ── Subtle rounded rectangle border ──
let borderInset: CGFloat = 8
let borderRect = NSRect(x: borderInset, y: borderInset,
                        width: CGFloat(width) - 2 * borderInset,
                        height: CGFloat(height) - 2 * borderInset)
let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: 16, yRadius: 16)
NSColor(white: 0.0, alpha: 0.08).setStroke()
borderPath.lineWidth = 1.5
borderPath.stroke()

// ── Arrow from left (app) to right (Applications) ──
let arrowColor = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 0.85)
arrowColor.setStroke()

// App icon position (left side, center vertically)
let appX: CGFloat = 150
let appY: CGFloat = 200

// Applications position (right side)
let appsX: CGFloat = 490
let appsY: CGFloat = 200

// Draw a curved arrow from app to Applications
let arrowStart = NSPoint(x: appX + 60, y: appY)
let arrowEnd = NSPoint(x: appsX - 60, y: appsY)
let midX = (arrowStart.x + arrowEnd.x) / 2

let arrowPath = NSBezierPath()
arrowPath.move(to: arrowStart)
arrowPath.curve(to: arrowEnd,
                controlPoint1: NSPoint(x: midX, y: arrowStart.y + 40),
                controlPoint2: NSPoint(x: midX, y: arrowEnd.y + 40))
arrowPath.lineWidth = 3
arrowPath.lineCapStyle = .round
arrowPath.stroke()

// Arrowhead (pointing right)
let arrowSize: CGFloat = 14
let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: arrowEnd.x + arrowSize, y: arrowEnd.y))
arrowHead.line(to: NSPoint(x: arrowEnd.x - arrowSize * 0.5, y: arrowEnd.y + arrowSize * 0.8))
arrowHead.line(to: NSPoint(x: arrowEnd.x - arrowSize * 0.5, y: arrowEnd.y - arrowSize * 0.8))
arrowHead.close()
arrowColor.setFill()
arrowHead.fill()

// ── Labels ──
let labelColor = NSColor(white: 0.0, alpha: 0.55)
let labelAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
    .foregroundColor: labelColor,
]

// "Drag to install" label above the arrow — the icon names are drawn
// by Finder itself, so we don't bake any in.
let dragText = NSAttributedString(string: "Drag to Install", attributes: labelAttrs)
let dragSize = dragText.size()
dragText.draw(at: NSPoint(x: midX - dragSize.width / 2, y: arrowStart.y + 55))

image.unlockFocus()

// ── Save as PNG ──
let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
try! png.write(to: URL(fileURLWithPath: output))
print("Background saved to \(output) (\(width)x\(height))")
