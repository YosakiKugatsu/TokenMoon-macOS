// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreGraphics

let side = 1024
let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func ink(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}
let colors = CGColorSpace(name: CGColorSpace.sRGB)!
let plate = CGPath(roundedRect: CGRect(x: 77, y: 77, width: 870, height: 870), cornerWidth: 202, cornerHeight: 202, transform: nil)
context.saveGState()
context.addPath(plate)
context.clip()
context.drawLinearGradient(CGGradient(colorsSpace: colors, colors: [
    ink(0.12, 0.14, 0.31), ink(0.25, 0.22, 0.53), ink(0.32, 0.24, 0.59)
] as CFArray, locations: [0, 0.64, 1])!, start: CGPoint(x: 150, y: 115), end: CGPoint(x: 930, y: 890), options: [.drawsAfterEndLocation])
context.restoreGState()
context.addPath(plate)
context.setStrokeColor(ink(0.76, 0.75, 0.96, 0.32))
context.setLineWidth(4)
context.strokePath()
let moon = CGMutablePath()
moon.addEllipse(in: CGRect(x: 245, y: 240, width: 487, height: 487))
context.saveGState()
context.addPath(moon)
context.clip()
let cutout = CGMutablePath()
cutout.addRect(CGRect(x: 0, y: 0, width: side, height: side))
cutout.addEllipse(in: CGRect(x: 401, y: 331, width: 414, height: 414))
context.addPath(cutout)
context.clip(using: .evenOdd)
context.drawLinearGradient(CGGradient(colorsSpace: colors, colors: [
    ink(0.96, 0.95, 1), ink(0.68, 0.76, 1), ink(0.56, 0.46, 0.97)
] as CFArray, locations: [0, 0.57, 1])!, start: CGPoint(x: 310, y: 668), end: CGPoint(x: 723, y: 245), options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
context.restoreGState()
let star = CGMutablePath()
let origin = CGPoint(x: 683, y: 647)
star.move(to: CGPoint(x: origin.x, y: origin.y + 86))
star.addQuadCurve(to: CGPoint(x: origin.x + 84, y: origin.y), control: CGPoint(x: origin.x + 10, y: origin.y + 10))
star.addQuadCurve(to: CGPoint(x: origin.x, y: origin.y - 86), control: CGPoint(x: origin.x + 10, y: origin.y - 10))
star.addQuadCurve(to: CGPoint(x: origin.x - 84, y: origin.y), control: CGPoint(x: origin.x - 10, y: origin.y - 10))
star.addQuadCurve(to: CGPoint(x: origin.x, y: origin.y + 86), control: CGPoint(x: origin.x - 10, y: origin.y + 10))
context.addPath(star)
context.setFillColor(ink(0.92, 0.90, 1))
context.fillPath()
let image = NSBitmapImageRep(cgImage: context.makeImage()!)
try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
