import AppKit
import SwiftUI

private enum TokenDisplayLayout {
    static let metricOutset: CGFloat = 9
}

enum TokenDisplayLockState {
    case unlocked
    case locked

    var systemImage: String {
        switch self {
        case .unlocked:
            return "lock.open"
        case .locked:
            return "lock.fill"
        }
    }

    var helpText: String {
        switch self {
        case .unlocked:
            return "锁定悬浮窗到当前窗口位置"
        case .locked:
            return "解除悬浮窗锁定"
        }
    }
}

private struct TokenDisplayScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var tokenDisplayScale: CGFloat {
        get { self[TokenDisplayScaleKey.self] }
        set { self[TokenDisplayScaleKey.self] = newValue }
    }
}

private extension CGFloat {
    func scaled(by scale: CGFloat) -> CGFloat {
        self * Swift.max(scale, 0.1)
    }
}

private extension BinaryInteger {
    func scaled(by scale: CGFloat) -> CGFloat {
        CGFloat(self) * Swift.max(scale, 0.1)
    }
}

enum TokenDisplayMode: String, CaseIterable, Identifiable {
    case off
    case floating
    case statusBar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:
            return "关闭"
        case .floating:
            return "悬浮窗"
        case .statusBar:
            return "状态栏"
        }
    }

    var controlLabel: String {
        label
    }

    var systemImage: String {
        switch self {
        case .off:
            return "slash.circle"
        case .floating:
            return "rectangle.on.rectangle"
        case .statusBar:
            return "menubar.rectangle"
        }
    }
}

struct TokenDisplaySnapshot {
    let title: String
    let status: String
    let rate: Double
    let consumedTokens: Int
    let todayTokens: Int
    let todayRequests: Int
    let quota: AccountQuotaSnapshot
    let updatedAt: Date

    @MainActor
    static func make(store: CodexUsageStore, monitor: LiveRateMonitor, quota: AccountQuotaStore) -> TokenDisplaySnapshot {
        let calendar = Calendar.current
        let today = Date()
        let todayUsage = store.snapshot.dailyUsage.first { calendar.isDate($0.date, inSameDayAs: today) }

        return TokenDisplaySnapshot(
            title: "全会话实时",
            status: monitor.totalSnapshot.status,
            rate: monitor.totalSnapshot.rollingTokensPerSecond,
            consumedTokens: store.snapshot.stats.totalTokens,
            todayTokens: todayUsage?.tokens ?? 0,
            todayRequests: todayUsage?.calls ?? 0,
            quota: quota.snapshot,
            updatedAt: max(store.snapshot.generatedAt, max(monitor.totalSnapshot.updatedAt, quota.snapshot.updatedAt ?? .distantPast))
        )
    }

    var statusBarTitle: String {
        if rate >= 100 {
            return "\(Int(rate.rounded()))/s"
        }
        if rate < 10 {
            return String(format: "%.1f/s", rate)
        }
        return "\(Int(rate.rounded()))/s"
    }

    var compactUsageStatus: String {
        let cardSuffix = quota.compactLimitCardSuffix
        guard quota.isAvailable else {
            if quota.status.contains("失败") {
                return "读取失败"
            }
            return "读取中"
        }

        if let pace = quota.sevenDayPaceStatus {
            return "\(pace.compactTitle)(\(pace.compactDetail)\(cardSuffix))"
        }

        if let sevenDay = quota.sevenDay {
            return "7d剩\(sevenDay.remainingPercent)%\(cardSuffix)"
        }
        if let fiveHour = quota.fiveHour {
            return "5h剩\(fiveHour.remainingPercent)%\(cardSuffix)"
        }
        return "额度已读\(cardSuffix)"
    }
}

struct TokenDisplayCard: View {
    let snapshot: TokenDisplaySnapshot
    let onClose: (() -> Void)?
    var lockState: TokenDisplayLockState? = nil
    var lockTargetDescription: String? = nil
    var onToggleLock: (() -> Void)? = nil
    @Environment(\.tokenDisplayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let rowSpacing = 4.scaled(by: displayScale)
            let rateRowHeight = 30.scaled(by: displayScale)
            let metricRowHeight = 13.scaled(by: displayScale)
            let quotaRowHeight = 16.5.scaled(by: displayScale)
            let fixedContentHeight = rateRowHeight + metricRowHeight + quotaRowHeight + rowSpacing * 2
            let topInset = max(0, (proxy.size.height - fixedContentHeight) / 2)

            VStack(alignment: .center, spacing: rowSpacing) {
                rateRow
                    .frame(height: rateRowHeight, alignment: .center)

                metricRow
                    .frame(height: metricRowHeight, alignment: .center)

                TokenQuotaMiniStrip(snapshot: snapshot.quota)
                    .frame(height: quotaRowHeight, alignment: .center)
            }
            .padding(.top, topInset)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .overlay(alignment: .topLeading) {
                cardLockButton
            }
            .overlay(alignment: .topTrailing) {
                cardCloseButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var rateRow: some View {
        HStack(alignment: .center, spacing: 9.scaled(by: displayScale)) {
            HStack(alignment: .lastTextBaseline, spacing: 4.scaled(by: displayScale)) {
                Text(String(format: "%.1f", snapshot.rate))
                    .font(.system(size: 20.scaled(by: displayScale), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 64.scaled(by: displayScale), alignment: .leading)
                    .offset(x: 3.scaled(by: displayScale), y: 3.scaled(by: displayScale))
                Text("tok/s")
                    .font(.system(size: 8.6.scaled(by: displayScale), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .offset(y: 3.5.scaled(by: displayScale))
            }
            .frame(height: 30.scaled(by: displayScale), alignment: .center)

            TokenDisplayRateBar(
                rate: snapshot.rate,
                usageStatus: snapshot.compactUsageStatus,
                lockState: nil,
                lockTargetDescription: nil,
                onToggleLock: nil,
                onClose: nil
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var cardLockButton: some View {
        if let lockState, let onToggleLock {
            Button(action: onToggleLock) {
                Image(systemName: lockState.systemImage)
                    .font(.system(size: 7.8.scaled(by: displayScale), weight: .bold))
                    .foregroundStyle(.primary.opacity(0.9))
                    .frame(width: 26.scaled(by: displayScale), height: 22.scaled(by: displayScale), alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(cardLockHelpText)
            .padding(.leading, 1.scaled(by: displayScale))
            .padding(.top, 1.scaled(by: displayScale))
            .zIndex(10)
        }
    }

    @ViewBuilder
    private var cardCloseButton: some View {
        if let onClose {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.8.scaled(by: displayScale), weight: .bold))
                    .foregroundStyle(.secondary.opacity(0.78))
                    .frame(width: 22.scaled(by: displayScale), height: 20.scaled(by: displayScale), alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 1.scaled(by: displayScale))
            .padding(.top, 1.scaled(by: displayScale))
            .zIndex(10)
        }
    }

    private var cardLockHelpText: String {
        guard lockState == .locked else {
            return TokenDisplayLockState.unlocked.helpText
        }
        if let lockTargetDescription, !lockTargetDescription.isEmpty {
            return "已锁定到 \(lockTargetDescription)"
        }
        return TokenDisplayLockState.locked.helpText
    }

    private var metricRow: some View {
        HStack(spacing: 6.scaled(by: displayScale)) {
            TokenDisplayMetric(label: "总", value: snapshot.consumedTokens.abbreviatedTokens)
                .offset(x: -TokenDisplayLayout.metricOutset.scaled(by: displayScale))
            TokenDisplayMetric(label: "今", value: snapshot.todayTokens.abbreviatedTokens)
            TokenDisplayMetric(label: "次", value: "\(snapshot.todayRequests)")
                .offset(x: TokenDisplayLayout.metricOutset.scaled(by: displayScale))
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

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
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(floatingTrackColor)
                    .overlay(Capsule().stroke(floatingTrackBorder, lineWidth: 0.45.scaled(by: displayScale)))
                Capsule()
                    .fill(AppTheme.accentBlue.opacity(0.78))
                    .frame(width: max(2, proxy.size.width * fillFraction))
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

struct TokenDisplayRateBar: View {
    let rate: Double
    let usageStatus: String
    let lockState: TokenDisplayLockState?
    let lockTargetDescription: String?
    let onToggleLock: (() -> Void)?
    let onClose: (() -> Void)?
    @Environment(\.tokenDisplayScale) private var displayScale
    @AppStorage(TokenRateScaleSettings.key) private var tokenRateFullScale = TokenRateScaleSettings.defaultValue

    private var fillFraction: CGFloat {
        let scale = TokenRateScaleSettings.clamped(tokenRateFullScale)
        return CGFloat(min(max(rate, 0), scale) / scale)
    }

    private var controlHitSize: CGFloat {
        max(30, 24.scaled(by: displayScale))
    }

    private var leadingControlInset: CGFloat {
        lockState != nil && onToggleLock != nil ? 13.scaled(by: displayScale) : 0
    }

    private var trailingControlInset: CGFloat {
        onClose != nil ? 11.scaled(by: displayScale) : 0
    }

    private var lockHelpText: String {
        guard lockState == .locked else {
            return TokenDisplayLockState.unlocked.helpText
        }
        if let lockTargetDescription, !lockTargetDescription.isEmpty {
            return "已锁定到 \(lockTargetDescription)"
        }
        return TokenDisplayLockState.locked.helpText
    }

    var body: some View {
        GeometryReader { proxy in
            let height = 30.scaled(by: displayScale)
            let statusHeight = 13.scaled(by: displayScale)
            let barHeight = 5.scaled(by: displayScale)
            let contentDrop = 3.5.scaled(by: displayScale)
            let statusTextDrop = contentDrop + 2.scaled(by: displayScale)
            let barTop = 18.scaled(by: displayScale) + contentDrop
            let leadingInset = leadingControlInset
            let trailingInset = trailingControlInset
            let contentWidth = max(1, proxy.size.width - leadingInset - trailingInset)
            let barWidth = max(1, proxy.size.width - trailingInset)
            let fillWidth = max(3.scaled(by: displayScale), barWidth * fillFraction)

            ZStack(alignment: .topLeading) {
                Text(usageStatus)
                    .font(.system(size: 10.2.scaled(by: displayScale), weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                    .truncationMode(.tail)
                    .frame(width: contentWidth, height: statusHeight, alignment: .leading)
                    .position(x: leadingInset + contentWidth / 2, y: statusHeight / 2 + statusTextDrop)

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
                .position(x: barWidth / 2, y: barTop + barHeight / 2)

                controls
                    .frame(width: proxy.size.width, height: height, alignment: .topLeading)
            }
            .frame(width: proxy.size.width, height: height, alignment: .topLeading)
        }
        .frame(height: 30.scaled(by: displayScale), alignment: .top)
    }

    @ViewBuilder
    private var controls: some View {
        ZStack(alignment: .topLeading) {
            if let lockState, let onToggleLock {
                Button(action: onToggleLock) {
                    Image(systemName: lockState.systemImage)
                        .font(.system(size: 7.8.scaled(by: displayScale), weight: .bold))
                        .foregroundStyle(.primary.opacity(0.88))
                        .frame(width: controlHitSize, height: controlHitSize, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(lockHelpText)
                .position(x: 4.5.scaled(by: displayScale), y: 3.5.scaled(by: displayScale))
            }

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.8.scaled(by: displayScale), weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.76))
                        .frame(width: controlHitSize, height: controlHitSize, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .offset(x: 7.scaled(by: displayScale), y: -5.scaled(by: displayScale))
            }
        }
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
