import AppKit
import SwiftUI

struct TokenQuotaMiniStrip: View {
    let snapshot: AccountQuotaSnapshot
    @Environment(\.tokenDisplayScale) private var displayScale
    @Environment(\.tokenDisplayTextPalette) private var textPalette

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
                        .foregroundStyle(textPalette.secondaryColor)
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
    @Environment(\.tokenDisplayTextPalette) private var textPalette
    @Environment(\.tokenDisplayQuotaColorStyle) private var quotaColorStyle

    private var fillFraction: CGFloat {
        CGFloat(Double(window.remainingPercent) / 100.0)
    }

    var body: some View {
        GeometryReader { proxy in
            let clampedFraction = min(max(fillFraction, 0), 1)
            let fillWidth = proxy.size.width * clampedFraction
            let quotaSegmentShape = quotaSegmentShape(height: proxy.size.height)
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    quotaSegmentShape
                        .fill(floatingTrackColor)
                    if fillWidth > 0 {
                        quotaSegmentShape
                            .fill(
                                quotaColorStyle.fillStyle(
                                    remainingPercent: Double(window.remainingPercent),
                                    expectedRemainingPercent: window.expectedRemainingPercentByEvenPace.map(Double.init)
                                )
                            )
                            .opacity(0.78)
                            .frame(width: min(proxy.size.width, max(proxy.size.height, fillWidth)), height: proxy.size.height)
                    }
                }
                .clipShape(quotaSegmentShape)
                .overlay(quotaSegmentShape.stroke(floatingTrackBorder, lineWidth: 0.45.scaled(by: displayScale)))

                Text("\(window.compactDisplayLabel) \(window.remainingPercent)% \(window.compactResetText)")
                    .font(.system(size: 9.4.scaled(by: displayScale), weight: .bold))
                    .foregroundStyle(textPalette.primaryColor)
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

    private func quotaSegmentShape(height: CGFloat) -> RoundedRectangle {
        let quotaSegmentCornerRadius = max(4.scaled(by: displayScale), height * 0.34)
        return RoundedRectangle(cornerRadius: quotaSegmentCornerRadius, style: .continuous)
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
    @Environment(\.tokenDisplayTextPalette) private var textPalette

    var body: some View {
        Text(text)
            .font(.system(size: 9.5.scaled(by: displayScale), weight: .semibold))
            .foregroundStyle(textPalette.primaryColor)
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

struct TokenDisplayRunningThreadsRow: View {
    let summary: RunningThreadSummary
    var showsTotal = true
    @Environment(\.tokenDisplayScale) private var displayScale
    @Environment(\.tokenDisplayTextPalette) private var textPalette

    var body: some View {
        let presentation = RunningThreadPresentation(summary: summary)
        HStack(spacing: 0) {
            if showsTotal {
                value("运行", count: presentation.hasCounts ? summary.total : nil)
            }
            value("主", count: presentation.hasCounts ? summary.main : nil)
            value("子", count: presentation.hasCounts ? summary.subagents : nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(presentation.accessibilityText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("运行线程")
        .accessibilityValue(presentation.accessibilityText)
    }

    private func value(_ label: String, count: Int?) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 3.scaled(by: displayScale)) {
            Text(label)
                .fontWeight(.medium)
                .foregroundStyle(textPalette.secondaryColor)
            Text(count.map { String($0) } ?? "--")
                .fontWeight(.semibold)
                .foregroundStyle(summary.freshness == .stale ? Color.orange : textPalette.primaryColor)
                .monospacedDigit()
        }
        .font(.system(size: 9.4.scaled(by: displayScale)))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct TokenDisplayRadarColumns<Leading: View, Trailing: View>: View {
    let dividerColor: Color
    let leadingFraction: CGFloat?
    let leading: Leading
    let trailing: Trailing
    @Environment(\.tokenDisplayScale) private var displayScale

    init(
        dividerColor: Color,
        leadingFraction: CGFloat? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.dividerColor = dividerColor
        self.leadingFraction = leadingFraction
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        GeometryReader { proxy in
            let spacing = 7.scaled(by: displayScale)
            let contentWidth = max(0, proxy.size.width - spacing * 2 - 1)
            let leadingWidth = leadingFraction.map { contentWidth * $0 }
            HStack(spacing: spacing) {
                leading
                    .frame(width: leadingWidth, alignment: .leading)
                Rectangle()
                    .fill(dividerColor)
                    .frame(width: 1, height: 19.scaled(by: displayScale))
                trailing
                    .frame(width: leadingWidth.map { max(0, contentWidth - $0) }, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
    }
}

struct TokenDisplayRadarStrip: View {
    let presentation: CodexRadarPresentationState
    @Environment(\.tokenDisplayScale) private var displayScale
    @Environment(\.tokenDisplayTextPalette) private var textPalette
    @Environment(\.tokenDisplayRadarActionTextPalette) private var actionTextPalette
    @Environment(\.tokenDisplayRadarModelTextPalette) private var modelTextPalette

    var body: some View {
        let snapshot = presentation.snapshot
        let primary = snapshot?.modelIQ.primaryModelPoint
        let actionPalette = actionTextPalette ?? textPalette
        let modelPalette = modelTextPalette ?? textPalette
        let effectiveActionText = CodexRadarPresentationText.effectiveAction(snapshot: snapshot)
        let actionAccent = AppTheme.radarActionColor(effectiveActionText)
        let isSpeedWindow = effectiveActionText == "速登窗口"
        let modelLimit = isSpeedWindow ? 2 : 3
        let actionPrimaryColor = AppTheme.radarActionRole(effectiveActionText) == .red
            ? actionAccent
            : actionPalette.primaryColor
        let primaryAccent = primary.map {
            AppTheme.radarScoreColor(passed: $0.passed, tasks: $0.tasks, score: $0.score)
        } ?? AppTheme.accentBlue
        TokenDisplayRadarColumns(
            dividerColor: textPalette.dividerColor,
            leadingFraction: isSpeedWindow ? 0.42 : nil
        ) {
            VStack(alignment: .leading, spacing: 2.scaled(by: displayScale)) {
                HStack(alignment: .firstTextBaseline, spacing: 3.scaled(by: displayScale)) {
                    Circle()
                        .fill(actionAccent)
                        .frame(width: 4.scaled(by: displayScale), height: 4.scaled(by: displayScale))
                    TimelineView(CodexRadarCountdownTimelineSchedule(
                        deadline: CodexRadarPresentationText.countdownDeadline(snapshot: snapshot)
                    )) { context in
                        Text(CodexRadarPresentationText.actionDisplay(snapshot: snapshot, now: context.date))
                            .font(.system(size: 11.2.scaled(by: displayScale), weight: .bold))
                            .foregroundStyle(actionPrimaryColor)
                    }
                    if let marker = presentation.compactMarkerText {
                        Text(marker)
                            .font(.system(size: 6.8.scaled(by: displayScale), weight: .bold, design: .rounded))
                            .foregroundStyle(actionPalette.secondaryColor)
                            .padding(.horizontal, 2.4.scaled(by: displayScale))
                            .padding(.vertical, 0.8.scaled(by: displayScale))
                            .background(
                                Capsule(style: .continuous)
                                    .fill(actionPalette.secondaryColor.opacity(0.16))
                            )
                    }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.74)
        } trailing: {
            VStack(alignment: .leading, spacing: 1.scaled(by: displayScale)) {
                HStack(alignment: .lastTextBaseline, spacing: 3.scaled(by: displayScale)) {
                    Circle()
                        .fill(primaryAccent)
                        .frame(width: 4.scaled(by: displayScale), height: 4.scaled(by: displayScale))
                    Text(primary?.scoreDisplayText ?? "IQ --")
                        .font(.system(size: 11.8.scaled(by: displayScale), weight: .bold, design: .rounded))
                        .foregroundStyle(modelPalette.primaryColor)
                        .monospacedDigit()
                    Text(primary.map { CodexRadarPresentationText.compactModelName($0.modelDisplayName) } ?? "模型 --")
                        .font(.system(size: 8.4.scaled(by: displayScale), weight: .semibold))
                        .foregroundStyle(modelPalette.primaryColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Text(tokenDisplayRadarSecondaryIQText(snapshot, limit: modelLimit))
                    .font(.system(size: 8.1.scaled(by: displayScale), weight: .semibold))
                    .foregroundStyle(modelPalette.secondaryColor)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
        .foregroundStyle(textPalette.primaryColor)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex 雷达")
        .accessibilityValue(accessibilityText)
    }

    private var accessibilityText: String {
        guard let snapshot = presentation.snapshot else {
            return presentation.compactAccessibilityText ?? "等待读取"
        }
        let score = snapshot.modelIQ.primaryModelPoint?.scoreDisplayText ?? "IQ --"
        let base = "建议 \(CodexRadarPresentationText.actionDisplay(snapshot: snapshot))，\(score)"
        guard let compactAccessibility = presentation.compactAccessibilityText else {
            return base
        }
        return "\(base)，\(compactAccessibility)"
    }

}

struct TokenDisplayCrowdRadarRow: View {
    let presentation: CodexRadarPresentationState
    var pageIndex = 0
    @Environment(\.tokenDisplayScale) private var displayScale
    @Environment(\.tokenDisplayTextPalette) private var textPalette

    var body: some View {
        if let crowd = presentation.crowdSnapshot, !crowd.rankedModels.isEmpty {
            let start = max(0, pageIndex) * 3
            let leaders = crowd.rankedModels(page: pageIndex)
            TokenDisplayRadarColumns(dividerColor: textPalette.dividerColor, leadingFraction: 0.37) {
                resultView(leaders.first, position: start + 1)
            } trailing: {
                HStack(spacing: 4.scaled(by: displayScale)) {
                    resultView(leaders.dropFirst().first, position: start + 2)
                    Rectangle()
                        .fill(textPalette.dividerColor)
                        .frame(
                            width: 1,
                            height: (14 * FloatingTokenPanelMetrics.crowdRadarTypographyScale).scaled(by: displayScale)
                        )
                    resultView(leaders.dropFirst(2).first, position: start + 3)
                }
            }
            .font(.system(
                size: (7.4 * FloatingTokenPanelMetrics.crowdRadarTypographyScale).scaled(by: displayScale),
                weight: .medium
            ))
            .foregroundStyle(textPalette.primaryColor)
            .lineLimit(1)
            .minimumScaleFactor(0.76)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("众测雷达")
            .accessibilityValue(accessibilityValue(leaders, start: start))
        } else {
            HStack {
                Spacer()
                Text("排名待读取")
                Spacer()
            }
            .font(.system(
                size: (7.8 * FloatingTokenPanelMetrics.crowdRadarTypographyScale).scaled(by: displayScale),
                weight: .semibold
            ))
            .foregroundStyle(textPalette.secondaryColor)
        }
    }

    private func resultView(_ model: CodexCrowdRadarModel?, position: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.map { "\(position) \($0.label)" } ?? "\(position) --")
                .fontWeight(.semibold)
            Text(model.map { "IQ \(String(format: "%.1f", $0.iq)) · \($0.scorePassed)/\($0.scoreSamples)" } ?? "IQ -- · --/--")
                .foregroundStyle(textPalette.secondaryColor)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accessibilityValue(_ leaders: [CodexCrowdRadarModel], start: Int) -> String {
        leaders.enumerated().map { index, model in
            "第\(start + index + 1)名 \(model.label)，IQ \(String(format: "%.1f", model.iq))，本口径通过 \(model.scorePassed)/\(model.scoreSamples)"
        }.joined(separator: "；")
    }
}

private func tokenDisplayRadarSecondaryIQText(_ snapshot: CodexRadarSnapshot?, limit: Int = 3) -> String {
    let rows = snapshot?.modelIQ.secondaryModelRows.prefix(limit) ?? []
    guard !rows.isEmpty else { return "其他模型 --" }
    return rows.map { row in
        "\(tokenDisplayRadarShortModelLabel(row.label)) \(CodexRadarModelIQPoint.display(row.point.score))"
    }.joined(separator: "  ")
}

private func tokenDisplayRadarShortModelLabel(_ label: String) -> String {
    CodexRadarPresentationText.compactModelName(label)
}

struct TokenDisplayRateBar: View {
    let rate: Double
    let usageStatus: String?
    @Environment(\.tokenDisplayScale) private var displayScale
    @Environment(\.tokenDisplayTextPalette) private var textPalette
    @Environment(\.tokenDisplayEmbeddedUsageStatusTextPalette) private var embeddedUsageStatusTextPalette
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
            let statusBarGap = 4.scaled(by: displayScale)
            let contentHeight = usageStatus == nil ? barHeight : statusHeight + statusBarGap + barHeight
            let contentTop = max(0, (height - contentHeight) / 2)
            let barWidth = max(1, proxy.size.width)
            let minimumFillFraction = 3.scaled(by: displayScale) / barWidth
            let statusCenterY = contentTop + statusHeight / 2
            let barCenterY = usageStatus == nil
                ? height / 2
                : contentTop + statusHeight + statusBarGap + barHeight / 2
            let statusPalette = embeddedUsageStatusTextPalette ?? textPalette

            ZStack(alignment: .topLeading) {
                if let usageStatus {
                    Text(usageStatus)
                        .font(.system(size: 9.1.scaled(by: displayScale), weight: .semibold))
                        .foregroundStyle(statusPalette.primaryColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                        .truncationMode(.tail)
                        .frame(width: barWidth, height: statusHeight, alignment: .leading)
                        .position(x: barWidth / 2, y: statusCenterY)
                }

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(floatingTrackColor)
                        .overlay(Capsule().stroke(floatingTrackBorder, lineWidth: 0.45.scaled(by: displayScale)))
                    SmoothRateFillBar(
                        fraction: Double(fillFraction),
                        minimumFraction: Double(minimumFillFraction),
                        colors: [Color.cyan.opacity(0.98), Color.blue.opacity(0.92)],
                        startPoint: .bottom,
                        endPoint: .top
                    )
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
    var expands = true
    @Environment(\.tokenDisplayScale) private var displayScale
    @Environment(\.tokenDisplayTextPalette) private var textPalette

    var body: some View {
        HStack(spacing: 3.scaled(by: displayScale)) {
            Text(label)
                .font(.system(size: 9.4.scaled(by: displayScale), weight: .medium))
                .foregroundStyle(textPalette.secondaryColor)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 9.4.scaled(by: displayScale), weight: .semibold))
                .foregroundStyle(textPalette.primaryColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: expands ? .infinity : nil, alignment: .center)
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
