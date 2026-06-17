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
