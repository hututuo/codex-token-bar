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

struct InterfaceScaleButtonBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
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
            .fixedSize(horizontal: false, vertical: true)
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

struct InterfaceScaleSettingsCard: View {
    @Binding var autoEnabled: Bool
    @Binding var manualMultiplier: Double
    let closeAction: () -> Void
    @State private var customPercentText = ""
    @FocusState private var customPercentFocused: Bool

    private var automaticScale: Double {
        InterfaceScaleSettings.autoScale(for: InterfaceScaleSettings.activeScreen())
    }

    private var manualPercent: Double {
        InterfaceScaleSettings.clampedManual(manualMultiplier) * 100
    }

    private var effectiveScale: Double {
        InterfaceScaleSettings.effectiveScale(
            manualMultiplier: manualMultiplier,
            autoEnabled: autoEnabled,
            screen: InterfaceScaleSettings.activeScreen()
        )
    }

    private var percentBinding: Binding<Double> {
        Binding(
            get: { manualPercent },
            set: { newPercent in
                manualMultiplier = InterfaceScaleSettings.clampedManual(newPercent / 100)
                customPercentText = "\(Int((manualMultiplier * 100).rounded()))"
            }
        )
    }

    var body: some View {
        SettingsCalloutContainer(
            title: "界面大小",
            subtitle: "当前 \(InterfaceScaleSettings.displayValue(effectiveScale))",
            systemImage: "textformat.size",
            closeAction: closeAction
        ) {
            Text("自动适配会按屏幕大小给建议值；下面的百分比可以继续微调，也可以直接输入。")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(AppTheme.calloutOptionBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            SettingsCalloutSection("模式") {
                Button {
                    autoEnabled.toggle()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: autoEnabled ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(autoEnabled ? AppTheme.accentBlue : .secondary.opacity(0.55))
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("自动适配屏幕")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(.primary)
                            Text("屏幕建议 \(InterfaceScaleSettings.displayValue(automaticScale))")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Text(autoEnabled ? "开" : "关")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(autoEnabled ? AppTheme.accentBlue : .secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            SettingsCalloutSection("百分比") {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            adjustManualPercent(by: -5)
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(AppTheme.raisedBackground))

                        Slider(value: percentBinding, in: 90...130, step: 1)
                            .accessibilityLabel("界面大小百分比")
                            .accessibilityValue("\(Int(manualPercent.rounded()))%")

                        Button {
                            adjustManualPercent(by: 5)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(AppTheme.raisedBackground))
                    }

                    HStack(spacing: 8) {
                        Text("自定义")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        TextField("100", text: $customPercentText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .focused($customPercentFocused)
                            .frame(width: 54)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(AppTheme.raisedBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(customPercentFocused ? AppTheme.accentBlue.opacity(0.65) : AppTheme.border, lineWidth: 1)
                            )
                            .onSubmit(applyCustomPercent)

                        Text("%")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)

                        Button("应用") {
                            applyCustomPercent()
                        }
                        .font(.system(size: 11, weight: .bold))
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.accentBlue)

                        Spacer(minLength: 8)

                        Text("最终 \(InterfaceScaleSettings.displayValue(effectiveScale))")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                    }
                }
                .padding(10)
            }

            HStack(spacing: 8) {
                Button("恢复默认") {
                    autoEnabled = InterfaceScaleSettings.defaultAutoEnabled
                    manualMultiplier = InterfaceScaleSettings.defaultManualMultiplier
                    syncCustomPercentText()
                }
                .buttonStyle(InterfaceScaleCardFooterButtonStyle())

                Spacer(minLength: 8)

                Button("完成") {
                    closeAction()
                }
                .buttonStyle(InterfaceScaleCardFooterButtonStyle(prominent: true))
            }
        }
        .onAppear(perform: syncCustomPercentText)
        .onChange(of: manualMultiplier) {
            guard !customPercentFocused else { return }
            syncCustomPercentText()
        }
    }

    private func adjustManualPercent(by delta: Double) {
        manualMultiplier = InterfaceScaleSettings.clampedManual((manualPercent + delta) / 100)
        syncCustomPercentText()
    }

    private func applyCustomPercent() {
        let cleaned = customPercentText
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let percent = Double(cleaned) else {
            syncCustomPercentText()
            return
        }
        manualMultiplier = InterfaceScaleSettings.clampedManual(percent / 100)
        syncCustomPercentText()
        customPercentFocused = false
    }

    private func syncCustomPercentText() {
        customPercentText = "\(Int((manualMultiplier * 100).rounded()))"
    }
}

private struct InterfaceScaleCardFooterButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .bold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(prominent ? AppTheme.accentBlue : AppTheme.calloutOptionBackground)
                    .opacity(configuration.isPressed ? 0.82 : 1)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(prominent ? Color.clear : AppTheme.border.opacity(0.72), lineWidth: 1)
            )
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
    @Binding var isPresented: Bool
    @Binding var autoEnabled: Bool
    @Binding var manualMultiplier: Double

    private var effectiveScale: Double {
        InterfaceScaleSettings.effectiveScale(
            manualMultiplier: manualMultiplier,
            autoEnabled: autoEnabled,
            screen: InterfaceScaleSettings.activeScreen()
        )
    }

    var body: some View {
        Button {
            isPresented.toggle()
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
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .anchorPreference(key: InterfaceScaleButtonBoundsKey.self, value: .bounds) { anchor in
            anchor
        }
        .zIndex(isPresented ? 20 : 0)
        .help("自动适配高分辨率屏幕，也可以手动微调界面大小")
    }
}
