import AppKit
import SwiftUI

enum AppTheme {
    static let pageBackground = adaptive(
        light: rgba(0.955, 0.965, 0.980),
        dark: rgba(0.035, 0.045, 0.060)
    )
    static let panelBackground = adaptive(
        light: rgba(1.000, 1.000, 1.000, 0.82),
        dark: rgba(0.070, 0.085, 0.110)
    )
    static let panelBackgroundAlt = adaptive(
        light: rgba(0.935, 0.950, 0.970),
        dark: rgba(0.085, 0.105, 0.135)
    )
    static let insetBackground = adaptive(
        light: rgba(0.915, 0.930, 0.955),
        dark: rgba(0.045, 0.055, 0.075)
    )
    static let raisedBackground = adaptive(
        light: rgba(0.930, 0.945, 0.965),
        dark: rgba(0.105, 0.125, 0.160)
    )
    static let border = adaptive(
        light: rgba(0.000, 0.000, 0.000, 0.070),
        dark: rgba(1.000, 1.000, 1.000, 0.080)
    )
    static let borderStrong = adaptive(
        light: rgba(0.000, 0.000, 0.000, 0.130),
        dark: rgba(1.000, 1.000, 1.000, 0.140)
    )
    static let shadow = adaptive(
        light: rgba(0.000, 0.000, 0.000, 0.055),
        dark: rgba(0.000, 0.000, 0.000, 0.280)
    )
    static let grid = adaptive(
        light: rgba(0.000, 0.000, 0.000, 0.055),
        dark: rgba(1.000, 1.000, 1.000, 0.075)
    )
    static let emptyCell = adaptive(
        light: rgba(0.000, 0.000, 0.000, 0.080),
        dark: rgba(1.000, 1.000, 1.000, 0.055)
    )
    static let accentBlue = adaptive(
        light: rgba(0.080, 0.410, 0.850),
        dark: rgba(0.290, 0.620, 1.000)
    )
    static let accentCyan = adaptive(
        light: rgba(0.030, 0.600, 0.780),
        dark: rgba(0.210, 0.800, 0.940)
    )
    static let accentOrange = adaptive(
        light: rgba(0.880, 0.430, 0.100),
        dark: rgba(1.000, 0.620, 0.260)
    )
    static let hoverBubble = adaptive(
        light: rgba(1.000, 1.000, 1.000, 0.960),
        dark: rgba(0.080, 0.100, 0.135, 0.960)
    )
    static let calloutBackground = adaptive(
        light: rgba(1.000, 1.000, 1.000),
        dark: rgba(0.090, 0.110, 0.145)
    )
    static let calloutOptionBackground = adaptive(
        light: rgba(0.945, 0.955, 0.975),
        dark: rgba(0.125, 0.145, 0.185)
    )

    static func heatmapColor(ratio: Double) -> Color {
        switch ratio {
        case 0..<0.18:
            return adaptive(light: rgba(0.780, 0.890, 1.000), dark: rgba(0.105, 0.180, 0.260))
        case 0.18..<0.38:
            return adaptive(light: rgba(0.550, 0.780, 1.000), dark: rgba(0.120, 0.280, 0.430))
        case 0.38..<0.62:
            return adaptive(light: rgba(0.290, 0.620, 0.960), dark: rgba(0.130, 0.400, 0.660))
        case 0.62..<0.82:
            return adaptive(light: rgba(0.100, 0.450, 0.860), dark: rgba(0.110, 0.520, 0.850))
        default:
            return adaptive(light: rgba(0.020, 0.320, 0.680), dark: rgba(0.180, 0.680, 1.000))
        }
    }

    static func cacheHitColor(rate: Double) -> Color {
        switch rate {
        case 0..<0.84:
            return adaptive(light: rgba(0.960, 0.460, 0.100), dark: rgba(1.000, 0.540, 0.180))
        case 0.84..<0.88:
            return adaptive(light: rgba(0.900, 0.620, 0.050), dark: rgba(1.000, 0.720, 0.180))
        case 0.88..<0.92:
            return adaptive(light: rgba(0.160, 0.660, 0.680), dark: rgba(0.140, 0.820, 0.880))
        case 0.92..<0.96:
            return adaptive(light: rgba(0.080, 0.500, 0.930), dark: rgba(0.230, 0.680, 1.000))
        default:
            return adaptive(light: rgba(0.020, 0.250, 0.760), dark: rgba(0.340, 0.760, 1.000))
        }
    }

    static func quotaRemainingColor(percent: Double) -> Color {
        switch percent {
        case 0..<20:
            return accentOrange
        case 20..<45:
            return adaptive(light: rgba(0.900, 0.620, 0.050), dark: rgba(1.000, 0.720, 0.180))
        case 45..<70:
            return accentCyan
        default:
            return accentBlue
        }
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            isDark(appearance) ? dark : light
        })
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
