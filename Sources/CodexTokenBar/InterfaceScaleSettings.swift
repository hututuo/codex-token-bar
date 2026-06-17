import AppKit
import SwiftUI

enum InterfaceScaleSettings {
    static let autoEnabledKey = "interfaceScaleAutoEnabled"
    static let manualMultiplierKey = "interfaceScaleManualMultiplier"
    static let defaultAutoEnabled = true
    static let defaultManualMultiplier = 1.0
    static let manualRange = 0.90...1.30
    static let effectiveRange = 0.90...1.45
    static let step = 0.05
    static let baseDashboardContentWidth: CGFloat = 1088

    @MainActor
    static func activeScreen() -> NSScreen? {
        NSApp.keyWindow?.screen
            ?? NSApp.mainWindow?.screen
            ?? NSScreen.main
    }

    static func autoScale(for screen: NSScreen?) -> Double {
        guard let screen = screen ?? NSScreen.main else { return 1.0 }
        let visibleFrame = screen.visibleFrame
        let longSide = max(visibleFrame.width, visibleFrame.height)
        let pixelLongSide = longSide * max(screen.backingScaleFactor, 1)

        return autoScale(logicalLongSide: longSide, pixelLongSide: pixelLongSide)
    }

    static func autoScale(logicalLongSide: CGFloat, pixelLongSide: CGFloat) -> Double {
        var scale: Double
        switch logicalLongSide {
        case 2800...:
            scale = 1.24
        case 2400..<2800:
            scale = 1.18
        case 2100..<2400:
            scale = 1.13
        case 1800..<2100:
            scale = 1.07
        default:
            scale = 1.0
        }

        if pixelLongSide >= 6000 {
            scale = max(scale, 1.14)
        } else if pixelLongSide >= 5000 {
            scale = max(scale, 1.08)
        }

        return clampedEffective(scale)
    }

    static func effectiveScale(
        manualMultiplier: Double,
        autoEnabled: Bool,
        screen: NSScreen?
    ) -> Double {
        let manual = clampedManual(manualMultiplier)
        let automatic = autoEnabled ? autoScale(for: screen) : 1.0
        return clampedEffective(manual * automatic)
    }

    static func dashboardScale(
        requestedScale: CGFloat,
        availableWidth: CGFloat
    ) -> CGFloat {
        guard requestedScale > 1 else { return requestedScale }
        let widthLimitedScale = max(1, availableWidth / baseDashboardContentWidth)
        return min(requestedScale, widthLimitedScale)
    }

    static func displayValue(_ scale: Double) -> String {
        "\(Int((scale * 100).rounded()))%"
    }

    static func nudgeManual(_ value: Double, delta: Double) -> Double {
        clampedManual(value + delta)
    }

    static func clampedManual(_ value: Double) -> Double {
        min(max(value, manualRange.lowerBound), manualRange.upperBound)
    }

    static func clampedEffective(_ value: Double) -> Double {
        min(max(value, effectiveRange.lowerBound), effectiveRange.upperBound)
    }
}

private struct InterfaceScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var interfaceScale: CGFloat {
        get { self[InterfaceScaleKey.self] }
        set { self[InterfaceScaleKey.self] = newValue }
    }
}

private struct InterfaceScaledContentSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 || next.height > 0 {
            value = next
        }
    }
}

struct InterfaceScaledContainer<Content: View>: View {
    let scale: CGFloat
    let visualWidth: CGFloat
    private let content: Content
    @State private var contentSize = CGSize.zero

    init(scale: CGFloat, visualWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.scale = scale
        self.visualWidth = visualWidth
        self.content = content()
    }

    private var safeScale: CGFloat {
        max(scale, 0.1)
    }

    var body: some View {
        content
            .environment(\.interfaceScale, safeScale)
            .frame(width: visualWidth / safeScale, alignment: .top)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: InterfaceScaledContentSizeKey.self, value: proxy.size)
                }
            )
            .scaleEffect(safeScale, anchor: .top)
            .frame(
                width: visualWidth,
                height: max(1, contentSize.height * safeScale),
                alignment: .top
            )
            .onPreferenceChange(InterfaceScaledContentSizeKey.self) { newSize in
                guard abs(newSize.width - contentSize.width) > 0.5
                    || abs(newSize.height - contentSize.height) > 0.5
                else { return }
                contentSize = newSize
            }
    }
}

struct InterfaceScaleMenuContent: View {
    @AppStorage(InterfaceScaleSettings.autoEnabledKey) private var autoEnabled = InterfaceScaleSettings.defaultAutoEnabled
    @AppStorage(InterfaceScaleSettings.manualMultiplierKey) private var manualMultiplier = InterfaceScaleSettings.defaultManualMultiplier

    private var automaticScale: Double {
        InterfaceScaleSettings.autoScale(for: InterfaceScaleSettings.activeScreen())
    }

    private var effectiveScale: Double {
        InterfaceScaleSettings.effectiveScale(
            manualMultiplier: manualMultiplier,
            autoEnabled: autoEnabled,
            screen: InterfaceScaleSettings.activeScreen()
        )
    }

    var body: some View {
        Toggle("自动适配屏幕", isOn: $autoEnabled)

        Divider()

        Text("当前界面大小 \(InterfaceScaleSettings.displayValue(effectiveScale))")
        Text("屏幕建议 \(InterfaceScaleSettings.displayValue(autoEnabled ? automaticScale : 1.0))")

        Divider()

        Button("缩小一点") {
            manualMultiplier = InterfaceScaleSettings.nudgeManual(manualMultiplier, delta: -InterfaceScaleSettings.step)
        }
        .disabled(manualMultiplier <= InterfaceScaleSettings.manualRange.lowerBound)

        Button("放大一点") {
            manualMultiplier = InterfaceScaleSettings.nudgeManual(manualMultiplier, delta: InterfaceScaleSettings.step)
        }
        .disabled(manualMultiplier >= InterfaceScaleSettings.manualRange.upperBound)

        Button("恢复默认大小") {
            autoEnabled = InterfaceScaleSettings.defaultAutoEnabled
            manualMultiplier = InterfaceScaleSettings.defaultManualMultiplier
        }
    }
}

struct InterfaceScaleMenuButton: View {
    @AppStorage(InterfaceScaleSettings.autoEnabledKey) private var autoEnabled = InterfaceScaleSettings.defaultAutoEnabled
    @AppStorage(InterfaceScaleSettings.manualMultiplierKey) private var manualMultiplier = InterfaceScaleSettings.defaultManualMultiplier

    private var effectiveScale: Double {
        InterfaceScaleSettings.effectiveScale(
            manualMultiplier: manualMultiplier,
            autoEnabled: autoEnabled,
            screen: InterfaceScaleSettings.activeScreen()
        )
    }

    var body: some View {
        Menu {
            InterfaceScaleMenuContent()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "textformat.size")
                    .font(.system(size: 11, weight: .semibold))
                Text(InterfaceScaleSettings.displayValue(effectiveScale))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(AppTheme.raisedBackground)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .help("自动适配高分辨率屏幕，也可以手动微调界面大小")
    }
}
