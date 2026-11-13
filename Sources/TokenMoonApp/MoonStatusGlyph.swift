// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreText

struct MoonStatusGlyph: Equatable {
    struct Metric: Equatable {
        let title: String
        let value: String
        var isDimmed = false
    }

    let metrics: [Metric]
    var trend: [Int]? = nil
    let height: CGFloat
    var showsIcon = true

    @MainActor private enum Fonts {
        static let label = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
        static let value = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        static let unit = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    }

    @MainActor func image() -> NSImage {
        let titles = metrics.map { Self.title($0.title) }
        let values = metrics.map { Self.value($0.value.replacingOccurrences(of: "E-", with: "e−"), dimmed: $0.isDimmed) }
        let railWidths: [CGFloat]
        if showsIcon {
            let width = max(55, ceil((titles + values).map(\.width).max() ?? 0))
            railWidths = Array(repeating: width, count: metrics.count)
        } else {
            // Match PerfMoon's compact columns; widen only the column whose text needs it.
            railWidths = zip(titles, values).map { title, value in
                max(34, ceil(max(title.width, value.width)))
            }
        }
        let inset: CGFloat = showsIcon ? 19 : 0
        let gap: CGFloat = showsIcon ? 5 : 10
        let metricsEnd = metrics.isEmpty ? (showsIcon ? 14 : 0)
            : inset + railWidths.reduce(0, +) + CGFloat(metrics.count - 1) * gap
        let size = NSSize(width: max(1, metricsEnd + (trend == nil ? 0 : 24)), height: height)

        // Match PerfMoon's cap-height baselines on the native menu bar canvas.
        let valueCap = Fonts.value.capHeight
        let labelCap = Fonts.label.capHeight
        let valueBaseline = Self.halfPoint((height - (valueCap + 2 + labelCap)) / 2)
        let labelBaseline = Self.halfPoint(valueBaseline + valueCap + 2)
        let image = NSImage(size: size)
        for scale: CGFloat in [1, 2] {
            guard let context = CGContext(data: nil, width: Int(ceil(size.width * scale)),
                height: Int(ceil(size.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            context.scaleBy(x: scale, y: scale)
            if showsIcon { Self.drawMark(context, height: height) }
            var left = inset
            for index in titles.indices {
                let railWidth = railWidths[index]
                let center = left + railWidth / 2
                titles[index].draw(context, center: center, baseline: labelBaseline, backingScale: scale)
                values[index].draw(context, center: center, baseline: valueBaseline, backingScale: scale)
                left += railWidth + gap
            }
            if let trend {
                Self.drawTrend(trend, context: context, start: metricsEnd + 4, baseline: valueBaseline, height: valueCap)
            }
            guard let pixels = context.makeImage() else { continue }
            let bitmap = NSBitmapImageRep(cgImage: pixels)
            bitmap.size = size
            image.addRepresentation(bitmap)
        }
        image.isTemplate = true
        return image
    }

    @MainActor private static func title(_ text: String) -> InkLine {
        InkLine(NSAttributedString(string: text, attributes: [
            .font: Fonts.label, .kern: 0.4, .foregroundColor: NSColor.black.withAlphaComponent(0.78),
        ]))
    }

    @MainActor private static func value(_ text: String, dimmed: Bool) -> InkLine {
        let unit = text.last.flatMap { "KMBT%$".contains($0) ? String($0) : nil }
        let number = unit == nil ? text : String(text.dropLast())
        let opacity: CGFloat = text == "—" || dimmed ? 0.6 : 1
        func styled(_ digits: String) -> NSAttributedString {
            let result = NSMutableAttributedString(string: digits, attributes: [
                .font: Fonts.value, .foregroundColor: NSColor.black.withAlphaComponent(opacity),
            ])
            if let unit, result.length > 0 {
                result.addAttribute(.kern, value: 0.6, range: NSRange(location: result.length - 1, length: 1))
                result.append(NSAttributedString(string: unit, attributes: [
                    .font: Fonts.unit, .foregroundColor: NSColor.black.withAlphaComponent(0.78 * opacity),
                ]))
            }
            return result
        }
        // Shape the visible value, but center a tabular zero template to
        // avoid the glyphs sliding sideways when only the digits change.
        let probe = String(number.map { $0.isASCII && $0.isWholeNumber ? "0" : $0 })
        return InkLine(styled(number), measuring: styled(probe))
    }

    private struct InkLine {
        let line: CTLine
        let center: CGFloat
        let width: CGFloat

        init(_ text: NSAttributedString, measuring probe: NSAttributedString? = nil) {
            line = CTLineCreateWithAttributedString(text)
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let measured = probe.map { CTLineCreateWithAttributedString($0) } ?? line
            let bounds = CTLineGetBoundsWithOptions(measured, .useGlyphPathBounds)
            let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            center = bounds.isNull || bounds.width <= 0 ? advance / 2 : bounds.midX
            width = ink.isNull ? advance : max(advance, 2 * max(center - ink.minX, ink.maxX - center))
        }

        func draw(_ context: CGContext, center x: CGFloat, baseline y: CGFloat, backingScale: CGFloat) {
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: ((x - center) * backingScale).rounded() / backingScale, y: y)
            CTLineDraw(line, context)
        }
    }

    private static func drawTrend(_ values: [Int], context: CGContext, start: CGFloat, baseline: CGFloat, height: CGFloat) {
        let values = values.suffix(6)
        let left = start + (20 - CGFloat(values.count * 3 - 1)) / 2
        for (index, value) in values.enumerated() {
            let x = left + CGFloat(index * 3)
            let track = CGRect(x: x, y: baseline, width: 2, height: height)
            let bar = CGRect(x: x, y: baseline, width: 2, height: min(height, max(1, CGFloat(value) / 2)))
            context.setFillColor(gray: 0, alpha: 0.2)
            context.addPath(CGPath(roundedRect: track, cornerWidth: 1, cornerHeight: 1, transform: nil))
            context.fillPath()
            context.setFillColor(gray: 0, alpha: 1)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 1, cornerHeight: min(1, bar.height / 2), transform: nil))
            context.fillPath()
        }
    }

    private static func drawMark(_ context: CGContext, height: CGFloat) {
        let s: CGFloat = 14
        let c = CGPoint(x: s * 0.44, y: s * 0.56)
        context.saveGState()
        context.translateBy(x: 0, y: (height + s) / 2)
        context.scaleBy(x: 1, y: -1)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(gray: 0, alpha: 1)
        context.fillEllipse(in: CGRect(x: c.x - s * 0.32, y: c.y - s * 0.32, width: s * 0.64, height: s * 0.64))
        context.setBlendMode(.destinationOut)
        context.fillEllipse(in: CGRect(x: c.x - s * 0.12, y: c.y - s * 0.46, width: s * 0.56, height: s * 0.56))
        context.endTransparencyLayer()
        func point(_ angle: Double) -> CGPoint {
            CGPoint(x: c.x + s * 0.44 * cos(angle), y: c.y + s * 0.44 * sin(angle))
        }
        context.setStrokeColor(gray: 0, alpha: 0.45)
        context.setLineWidth(1)
        context.setLineCap(.round)
        context.addLines(between: (0...14).map { point(-1.9 + Double($0) * 0.13) })
        context.strokePath()
        let dot = point(-0.75)
        context.setFillColor(gray: 0, alpha: 0.45)
        context.fillEllipse(in: CGRect(x: dot.x - s * 0.08, y: dot.y - s * 0.08, width: s * 0.16, height: s * 0.16))
        context.restoreGState()
    }

    private static func halfPoint(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
}
