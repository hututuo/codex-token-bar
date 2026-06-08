import AppKit
import SwiftUI

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
    let updatedAt: Date

    @MainActor
    static func make(store: CodexUsageStore, monitor: LiveRateMonitor) -> TokenDisplaySnapshot {
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
            updatedAt: max(store.snapshot.generatedAt, monitor.totalSnapshot.updatedAt)
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
}

struct TokenDisplayCard: View {
    let snapshot: TokenDisplaySnapshot
    let onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 6) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", snapshot.rate))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 48, alignment: .leading)
                    Text("tok/s")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                TokenDisplayRateBar(rate: snapshot.rate, onClose: onClose)
                    .frame(width: 58, alignment: .trailing)
            }

            HStack(spacing: 4) {
                TokenDisplayMetric(label: "总", value: snapshot.consumedTokens.abbreviatedTokens)
                TokenDisplayMetric(label: "今", value: snapshot.todayTokens.abbreviatedTokens)
                TokenDisplayMetric(label: "次", value: "\(snapshot.todayRequests)")
            }
        }
    }
}

struct TokenDisplayRateBar: View {
    let rate: Double
    let onClose: (() -> Void)?

    private var fillFraction: CGFloat {
        CGFloat(min(max(rate, 0), 120) / 120)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 1) {
                Text("总速")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(.secondary.opacity(0.72))
                            .frame(width: 9, height: 9)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            GeometryReader { proxy in
                let width = max(3, proxy.size.width * fillFraction)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.cyan.opacity(0.98), Color.blue.opacity(0.92)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: width)
                }
            }
            .frame(height: 4)
        }
        .frame(height: 18)
    }
}

struct TokenDisplayMetric: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 7, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TokenGlassBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(AppTheme.panelBackground.opacity(0.94))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.08),
                                AppTheme.accentCyan.opacity(0.12),
                                AppTheme.accentBlue.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
}
