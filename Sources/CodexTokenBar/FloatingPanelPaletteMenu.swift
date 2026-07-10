import AppKit
import SwiftUI

struct FloatingPanelPaletteMenu: View {
    @Binding var startHex: String
    @Binding var endHex: String
    @Binding var directionRaw: String
    @Binding var styleRaw: String
    let closeAction: () -> Void
    @State private var startColorDraft: Color
    @State private var endColorDraft: Color

    init(
        startHex: Binding<String>,
        endHex: Binding<String>,
        directionRaw: Binding<String>,
        styleRaw: Binding<String>,
        closeAction: @escaping () -> Void
    ) {
        _startHex = startHex
        _endHex = endHex
        _directionRaw = directionRaw
        _styleRaw = styleRaw
        self.closeAction = closeAction
        _startColorDraft = State(initialValue: Self.color(from: startHex.wrappedValue, fallbackHex: FloatingPanelAppearance.defaultStartHex))
        _endColorDraft = State(initialValue: Self.color(from: endHex.wrappedValue, fallbackHex: FloatingPanelAppearance.defaultEndHex))
    }

    var body: some View {
        SettingsCalloutContainer(
            title: "悬浮窗样式",
            subtitle: nil,
            systemImage: "paintpalette",
            closeAction: closePaletteNow
        ) {
            SettingsCalloutSection("颜色") {
                VStack(spacing: 0) {
                    FloatingStyleControlRow(title: "起始色", systemImage: "circle.fill") {
                        ColorPicker("", selection: draftColorBinding($startColorDraft, hex: $startHex), supportsOpacity: false)
                            .labelsHidden()
                            .accessibilityLabel("起始色")
                    }

                    FloatingStyleDivider()

                    FloatingStyleControlRow(title: "结束色", systemImage: "circle.lefthalf.filled") {
                        ColorPicker("", selection: draftColorBinding($endColorDraft, hex: $endHex), supportsOpacity: false)
                            .labelsHidden()
                            .accessibilityLabel("结束色")
                    }
                }
            }

            SettingsCalloutSection("渐变") {
                VStack(spacing: 0) {
                    FloatingStyleControlRow(title: "方向", systemImage: "arrow.up.right") {
                        Picker("", selection: normalizedDirectionBinding) {
                            ForEach(FloatingPanelGradientDirection.allCases) { direction in
                                Text(direction.label).tag(direction.rawValue)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("渐变方向")
                        .pickerStyle(.menu)
                        .frame(maxWidth: 150, alignment: .trailing)
                    }

                    FloatingStyleDivider()

                    FloatingStyleControlRow(title: "类型", systemImage: "swirl.circle.righthalf.filled") {
                        Picker("", selection: normalizedStyleBinding) {
                            ForEach(FloatingPanelGradientStyle.allCases) { style in
                                Text(style.label).tag(style.rawValue)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("渐变类型")
                        .pickerStyle(.segmented)
                        .frame(width: 168)
                    }
                }
            }

            Button {
                let defaultStartHex = FloatingPanelAppearance.defaultStartHex
                let defaultEndHex = FloatingPanelAppearance.defaultEndHex
                startHex = defaultStartHex
                endHex = defaultEndHex
                startColorDraft = Self.color(from: defaultStartHex, fallbackHex: defaultStartHex)
                endColorDraft = Self.color(from: defaultEndHex, fallbackHex: defaultEndHex)
                directionRaw = FloatingPanelAppearance.defaultDirection
                styleRaw = FloatingPanelAppearance.defaultStyle
            } label: {
                Label("恢复默认", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(AppTheme.calloutOptionBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.58), lineWidth: 1)
            )
        }
        .frame(width: 338, alignment: .leading)
        .onDisappear {
            NSColorPanel.shared.close()
        }
    }

    private var normalizedDirectionBinding: Binding<String> {
        Binding(
            get: {
                FloatingPanelGradientDirection(rawValue: directionRaw)?.rawValue
                    ?? FloatingPanelAppearance.defaultDirection
            },
            set: { directionRaw = $0 }
        )
    }

    private var normalizedStyleBinding: Binding<String> {
        Binding(
            get: {
                FloatingPanelGradientStyle(rawValue: styleRaw)?.rawValue
                    ?? FloatingPanelAppearance.defaultStyle
            },
            set: { styleRaw = $0 }
        )
    }

    private func draftColorBinding(_ draftColor: Binding<Color>, hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: {
                draftColor.wrappedValue
            },
            set: { newValue in
                draftColor.wrappedValue = newValue
                if let nextHex = newValue.floatingPanelHexString() {
                    hex.wrappedValue = nextHex
                }
            }
        )
    }

    private static func color(from hex: String, fallbackHex: String) -> Color {
        Color(floatingPanelHex: hex)
            ?? Color(floatingPanelHex: fallbackHex)
            ?? AppTheme.panelBackgroundAlt
    }

    private func closePaletteNow() {
        NSColorPanel.shared.close()
        closeAction()
    }
}

private struct FloatingStyleControlRow<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 15)

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            content
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
    }
}

private struct FloatingStyleDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.border.opacity(0.58))
            .frame(height: 1)
            .padding(.leading, 35)
    }
}
