// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

enum ModelChartPalette {
    // Use separated hues before introducing variants. Text labels and model
    // swatches remain visible even when a larger catalog has similar hues.
    private static let colors: [UInt32] = [
        0x3278D2, 0xCE711E, 0x198B6C, 0x9159C1, 0xCB4F72, 0x168CA1,
        0xA88714, 0x5966BC, 0x658E37, 0xA86746, 0x308FBF, 0xB74C3E,
    ]

    static func color(slot: Int?) -> Color {
        guard let slot, slot >= 0 else { return .secondary }
        if colors.indices.contains(slot) {
            let rgb = colors[slot]
            return Color(red: Double((rgb >> 16) & 255) / 255,
                         green: Double((rgb >> 8) & 255) / 255,
                         blue: Double(rgb & 255) / 255)
        }
        let index = slot - colors.count
        let hue = (0.09 + Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: [0.72, 0.52, 0.83][index % 3],
                     brightness: [0.73, 0.64, 0.83][(index / 3) % 3])
    }
}
