import AppKit
import SwiftUI

struct SemanticAccentRGB: Equatable {
    let red: Int
    let green: Int
    let blue: Int
}

enum SemanticAccentRole: Equatable {
    case red
    case amber
    case green
    case blue
}

enum AppTheme {
    static let pageBackground = adaptive(
        light: rgba(0.955, 0.965, 0.980),
        dark: rgba(0.035, 0.045, 0.060)
    )
    static let panelBackground = adaptive(
        light: rgba(1.000, 1.000, 1.000),
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
    static let accentRed = accentColor(for: .red)
    static let accentAmber = accentColor(for: .amber)
    static let accentGreen = accentColor(for: .green)
    static let hoverBubble = adaptive(
        light: rgba(1.000, 1.000, 1.000, 0.960),
        dark: rgba(0.080, 0.100, 0.135, 0.960)
    )
    static let calloutBackground = adaptive(
        light: rgba(1.000, 1.000, 1.000),
        dark: rgba(0.055, 0.065, 0.085)
    )
    static let calloutOptionBackground = adaptive(
        light: rgba(0.946, 0.954, 0.968),
        dark: rgba(0.100, 0.118, 0.150)
    )
    static let calloutHeaderBackground = adaptive(
        light: rgba(0.928, 0.940, 0.958),
        dark: rgba(0.086, 0.102, 0.132)
    )
    static let solidControlBackground = adaptive(
        light: rgba(0.972, 0.978, 0.988),
        dark: rgba(0.115, 0.135, 0.170)
    )
    static let selectedControlBackground = adaptive(
        light: rgba(0.880, 0.930, 1.000),
        dark: rgba(0.125, 0.205, 0.315)
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
        semanticMetricColor(percent: percent)
    }

    static func semanticMetricRGB(percent: Double) -> SemanticAccentRGB {
        let stops: [(percent: Double, color: SemanticAccentRGB)] = [
            (0, .init(red: 202, green: 60, blue: 73)),
            (35, .init(red: 204, green: 139, blue: 38)),
            (70, .init(red: 31, green: 158, blue: 94)),
            (100, .init(red: 20, green: 105, blue: 204))
        ]
        let value = percent.isFinite ? min(100, max(0, percent)) : 0
        guard let upperIndex = stops.firstIndex(where: { value <= $0.percent }), upperIndex > 0 else {
            return stops[0].color
        }
        let lower = stops[upperIndex - 1]
        let upper = stops[upperIndex]
        let progress = (value - lower.percent) / (upper.percent - lower.percent)
        return SemanticAccentRGB(
            red: interpolateChannel(lower.color.red, upper.color.red, progress: progress),
            green: interpolateChannel(lower.color.green, upper.color.green, progress: progress),
            blue: interpolateChannel(lower.color.blue, upper.color.blue, progress: progress)
        )
    }

    static func semanticMetricColor(percent: Double) -> Color {
        let rgb = semanticMetricRGB(percent: percent)
        return Color(
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255
        )
    }

    static func radarScorePercent(passed: Int, tasks: Int, score: Double) -> Double {
        if tasks > 0 {
            return min(100, max(0, Double(passed) / Double(tasks) * 100))
        }
        return min(100, max(0, score / 1.5))
    }

    static func radarScoreColor(passed: Int, tasks: Int, score: Double) -> Color {
        let rgb = radarScoreRGB(passed: passed, tasks: tasks, score: score)
        return Color(
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255
        )
    }

    static func radarScoreRGB(passed: Int, tasks: Int, score: Double) -> SemanticAccentRGB {
        semanticMetricRGB(percent: radarScorePercent(passed: passed, tasks: tasks, score: score) * 0.7)
    }

    static func radarActionRole(_ action: String?) -> SemanticAccentRole {
        switch CodexRadarPresentationText.actionKey(action) {
        case "wait", "waiting", "hold", "等待", "暂缓":
            return .amber
        case "run", "go", "open", "运行", "可运行", "开放":
            return .green
        case "closed", "关闭", "use window", "use windows", "usewindow", "usewindows", "use remaining tokens", "速登窗口":
            return .red
        default:
            return .blue
        }
    }

    static func radarActionColor(_ action: String?) -> Color {
        accentColor(for: radarActionRole(action))
    }

    static func quotaPaceRole(_ label: String?) -> SemanticAccentRole {
        let value = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.range(of: "太快|先省|省着|别梭哈|告急|紧张|余量低|很低|不够烧|掉太快", options: .regularExpression) != nil {
            return .red
        }
        if value.range(of: "偏快|稍快|用得快", options: .regularExpression) != nil {
            return .amber
        }
        if value.range(of: "稳定|节奏很好|节奏稳|贴线|稳稳收官", options: .regularExpression) != nil {
            return .green
        }
        return .blue
    }

    static func accentColor(for role: SemanticAccentRole) -> Color {
        switch role {
        case .red:
            return semanticMetricColor(percent: 0)
        case .amber:
            return semanticMetricColor(percent: 35)
        case .green:
            return semanticMetricColor(percent: 70)
        case .blue:
            return semanticMetricColor(percent: 100)
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

    private static func interpolateChannel(_ lower: Int, _ upper: Int, progress: Double) -> Int {
        Int((Double(lower) + Double(upper - lower) * progress).rounded())
    }
}
