import AppKit
import SwiftUI

struct TokenQuotaMiniStrip: View {
    let snapshot: AccountQuotaSnapshot
    @Environment(\.tokenDisplayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let windows = [snapshot.fiveHour, snapshot.sevenDay].compactMap { $0 }
            let spacing = 4.scaled(by: displayScale)
            let height = 16.5.scaled(by: displayScale)
            let segmentWidth = max(56.scaled(by: displayScale), (proxy.size.width - spacing * CGFloat(max(windows.count - 1, 0))) / CGFloat(max(windows.count, 1)))

            HStack(spacing: spacing) {
                ForEach(windows, id: \.label) { window in
                    TokenQuotaMiniSegment(window: window)
                        .frame(width: segmentWidth, height: height)
                }
                if !snapshot.isAvailable {
                    Text("额度 --")
                        .font(.system(size: 9.2.scaled(by: displayScale), weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(width: proxy.size.width, height: height, alignment: .center)
        }
        .frame(height: 16.5.scaled(by: displayScale))
        .help(quotaHelpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("账户额度")
        .accessibilityValue(quotaHelpText)
    }

    private var quotaHelpText: String {
        guard snapshot.isAvailable else { return snapshot.status }
        let chunks = [snapshot.fiveHour, snapshot.sevenDay].compactMap { window -> String? in
            guard let window else { return nil }
            return "\(window.label) 剩余 \(window.remainingPercent)%，\(window.accessibleResetText) 重置"
        }
        return chunks.joined(separator: "；")
    }
}

struct TokenQuotaMiniSegment: View {
    let window: AccountQuotaWindow
    @Environment(\.tokenDisplayScale) private var displayScale

    private var fillFraction: CGFloat {
        CGFloat(Double(window.remainingPercent) / 100.0)
    }

    var body: some View {
        GeometryReader { proxy in
            let clampedFraction = min(max(fillFraction, 0), 1)
            let fillWidth = proxy.size.width * clampedFraction
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(floatingTrackColor)
                    if fillWidth > 0 {
                        Capsule()
                            .fill(AppTheme.accentBlue.opacity(0.78))
                            .frame(width: min(proxy.size.width, max(proxy.size.height, fillWidth)), height: proxy.size.height)
                    }
                }
                .clipShape(Capsule())
                .overlay(Capsule().stroke(floatingTrackBorder, lineWidth: 0.45.scaled(by: displayScale)))

                Text("\(window.compactDisplayLabel) \(window.remainingPercent)% \(window.compactResetText)")
                    .font(.system(size: 9.4.scaled(by: displayScale), weight: .bold))
                    .foregroundStyle(.primary.opacity(0.82))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 3.scaled(by: displayScale))
            }
        }
        .frame(height: 16.5.scaled(by: displayScale))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.displayLabel)额度")
        .accessibilityValue("剩余 \(window.remainingPercent)%，已用 \(window.usedPercent)%，\(window.accessibleResetText) 重置")
    }

    private var floatingTrackColor: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.16)
                : NSColor.white.withAlphaComponent(0.78)
        })
    }

    private var floatingTrackBorder: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.055)
        })
    }
}

struct TokenDisplayUsageStatusLine: View {
    let text: String
    @Environment(\.tokenDisplayScale) private var displayScale

    var body: some View {
        Text(text)
            .font(.system(size: 13.6.scaled(by: displayScale), weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.88))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .truncationMode(.tail)
            .padding(.horizontal, 6.scaled(by: displayScale))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("趣味化余量")
            .accessibilityValue(text)
    }
}

struct TokenDisplayRadarStrip: View {
    let snapshot: CodexRadarSnapshot?
    @Environment(\.tokenDisplayScale) private var displayScale

    var body: some View {
        let latest = snapshot?.modelIQ.latest
        HStack(spacing: 7.scaled(by: displayScale)) {
            VStack(alignment: .leading, spacing: 2.scaled(by: displayScale)) {
                Text("动作 \(snapshot?.recommendedAction ?? "--")")
                    .font(.system(size: 9.3.scaled(by: displayScale), weight: .bold))
                Text("24h \(tokenDisplayRadarProbabilityText(snapshot?.prediction.probability24hPercent))  48h \(tokenDisplayRadarProbabilityText(snapshot?.prediction.probability48hPercent))")
                    .font(.system(size: 8.4.scaled(by: displayScale), weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.78))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.74)
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 19.scaled(by: displayScale))

            VStack(alignment: .trailing, spacing: 1.scaled(by: displayScale)) {
                HStack(alignment: .lastTextBaseline, spacing: 3.scaled(by: displayScale)) {
                    Text(latest?.scoreDisplayText ?? "IQ --")
                        .font(.system(size: 11.8.scaled(by: displayScale), weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(latest?.modelDisplayName ?? "模型 --")
                        .font(.system(size: 7.7.scaled(by: displayScale), weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.66)
                }
                Text("\(tokenDisplayRadarIQText(snapshot, effort: "high"))  \(tokenDisplayRadarIQText(snapshot, effort: "xhigh"))")
                    .font(.system(size: 8.1.scaled(by: displayScale), weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .monospacedDigit()
            }
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(Color.white.opacity(0.86))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex 雷达")
        .accessibilityValue(accessibilityText)
    }

    private var accessibilityText: String {
        guard let snapshot else { return "等待读取" }
        return "建议 \(snapshot.recommendedAction)，24 小时概率 \(snapshot.prediction.probability24hPercent)%，48 小时概率 \(snapshot.prediction.probability48hPercent)%，\(snapshot.modelIQ.latest.scoreDisplayText)"
    }
}

private func tokenDisplayRadarProbabilityText(_ percent: Int?) -> String {
    guard let percent else { return "--" }
    return "\(percent)%"
}

private func tokenDisplayRadarIQText(_ snapshot: CodexRadarSnapshot?, effort: String) -> String {
    let label = effort == "xhigh" ? "X high" : effort
    guard let row = snapshot?.modelIQ.comparisonRows.first(where: { row in
        row.point.reasoningEffort?.caseInsensitiveCompare(effort) == .orderedSame
            || row.label.localizedCaseInsensitiveContains(effort)
    }) else {
        return "\(label) --"
    }
    return "\(label) \(CodexRadarModelIQPoint.display(row.point.score))"
}

struct TokenDisplayRateBar: View {
    let rate: Double
    let usageStatus: String?
    @Environment(\.tokenDisplayScale) private var displayScale
    @AppStorage(TokenRateScaleSettings.key) private var tokenRateFullScale = TokenRateScaleSettings.defaultValue

    private var fillFraction: CGFloat {
        let scale = TokenRateScaleSettings.clamped(tokenRateFullScale)
        return CGFloat(min(max(rate, 0), scale) / scale)
    }

    var body: some View {
        GeometryReader { proxy in
            let height = FloatingTokenPanelMetrics.rateRowHeight.scaled(by: displayScale)
            let statusHeight = 13.scaled(by: displayScale)
            let barHeight = 5.5.scaled(by: displayScale)
            let barWidth = max(1, proxy.size.width)
            let fillWidth = max(3.scaled(by: displayScale), barWidth * fillFraction)
            let barCenterY = 22.scaled(by: displayScale)

            ZStack(alignment: .topLeading) {
                if let usageStatus {
                    Text(usageStatus)
                        .font(.system(size: 10.2.scaled(by: displayScale), weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                        .truncationMode(.tail)
                        .frame(width: barWidth, height: statusHeight, alignment: .leading)
                        .position(x: barWidth / 2, y: 7.5.scaled(by: displayScale))
                }

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(floatingTrackColor)
                        .overlay(Capsule().stroke(floatingTrackBorder, lineWidth: 0.45.scaled(by: displayScale)))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.cyan.opacity(0.98), Color.blue.opacity(0.92)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: fillWidth)
                }
                .frame(width: barWidth, height: barHeight, alignment: .leading)
                .position(x: barWidth / 2, y: barCenterY)
            }
            .frame(width: proxy.size.width, height: height, alignment: .topLeading)
        }
        .frame(height: FloatingTokenPanelMetrics.rateRowHeight.scaled(by: displayScale), alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("实时速率条")
        .accessibilityValue(String(format: "%.1f token 每秒", rate))
    }

    private var floatingTrackColor: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.17)
                : NSColor.white.withAlphaComponent(0.82)
        })
    }

    private var floatingTrackBorder: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.13)
                : NSColor.black.withAlphaComponent(0.055)
        })
    }
}

struct TokenDisplayMetric: View {
    let label: String
    let value: String
    @Environment(\.tokenDisplayScale) private var displayScale

    var body: some View {
        HStack(spacing: 3.scaled(by: displayScale)) {
            Text(label)
                .font(.system(size: 9.4.scaled(by: displayScale), weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 9.4.scaled(by: displayScale), weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct TokenGlassBackground: View {
    var opacity = 0.88
    var cornerRadius: CGFloat = 14
    var appearance = FloatingPanelAppearance.default

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(appearance.endColor.opacity(opacity))
            .overlay(
                gradientOverlay
                    .opacity(min(0.96, max(0.62, opacity + 0.04)))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), Color.white.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), Color.white.opacity(0.045)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
    }

    @ViewBuilder
    private var gradientOverlay: some View {
        let direction = appearance.direction
        let colors = [appearance.startColor, appearance.endColor]
        switch appearance.style {
        case .linear:
            LinearGradient(colors: colors, startPoint: direction.startPoint, endPoint: direction.endPoint)
        case .radial:
            RadialGradient(
                colors: colors,
                center: direction.startPoint,
                startRadius: 4,
                endRadius: 240
            )
        case .angular:
            AngularGradient(
                colors: [appearance.startColor, appearance.endColor, appearance.startColor],
                center: .center,
                angle: .degrees(direction == .bottomLeadingToTopTrailing ? 45 : 0)
            )
        }
    }
}
