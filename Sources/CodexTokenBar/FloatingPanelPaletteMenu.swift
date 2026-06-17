import AppKit
import SwiftUI

struct FloatingPanelPaletteMenu: View {
    @Binding var startHex: String
    @Binding var endHex: String
    @Binding var directionRaw: String
    @Binding var styleRaw: String
    let closeAction: () -> Void
    @State private var scheduledClose: DispatchWorkItem?

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
                        ColorPicker("", selection: colorBinding($startHex), supportsOpacity: false)
                            .labelsHidden()
                            .accessibilityLabel("起始色")
                    }

                    FloatingStyleDivider()

                    FloatingStyleControlRow(title: "结束色", systemImage: "circle.lefthalf.filled") {
                        ColorPicker("", selection: colorBinding($endHex), supportsOpacity: false)
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
                startHex = FloatingPanelAppearance.defaultStartHex
                endHex = FloatingPanelAppearance.defaultEndHex
                directionRaw = FloatingPanelAppearance.defaultDirection
                styleRaw = FloatingPanelAppearance.defaultStyle
                closePaletteSoon()
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
        .onChange(of: startHex) { _, _ in
            schedulePaletteClose(after: 0.85)
        }
        .onChange(of: endHex) { _, _ in
            schedulePaletteClose(after: 0.85)
        }
        .onChange(of: directionRaw) { _, _ in
            closePaletteSoon()
        }
        .onChange(of: styleRaw) { _, _ in
            closePaletteSoon()
        }
        .onDisappear {
            scheduledClose?.cancel()
            scheduledClose = nil
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

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: {
                Color(floatingPanelHex: hex.wrappedValue)
                    ?? Color(floatingPanelHex: FloatingPanelAppearance.defaultStartHex)
                    ?? AppTheme.panelBackgroundAlt
            },
            set: { newValue in
                if let nextHex = newValue.floatingPanelHexString() {
                    hex.wrappedValue = nextHex
                }
            }
        )
    }

    private func schedulePaletteClose(after delay: TimeInterval) {
        scheduledClose?.cancel()
        let work = DispatchWorkItem {
            closePaletteNow()
        }
        scheduledClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func closePaletteSoon() {
        schedulePaletteClose(after: 0.12)
    }

    private func closePaletteNow() {
        scheduledClose?.cancel()
        scheduledClose = nil
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
