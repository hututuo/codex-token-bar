import AppKit
import SwiftUI

struct AlignedSettingSliderRow: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    let displayValue: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 42, alignment: .leading)

            Slider(value: $value, in: range, step: step)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(title)
                .accessibilityValue(displayValue)

            Text(displayValue)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: 44, alignment: .trailing)
        }
        .frame(height: 22)
    }
}

struct AppearanceSliderDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.border.opacity(0.45))
            .frame(height: 1)
            .padding(.leading, 52)
            .padding(.trailing, 40)
    }
}

struct DisplaySurfaceToggleButton: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? AppTheme.accentBlue.opacity(0.14) : AppTheme.calloutOptionBackground)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isOn ? AppTheme.accentBlue.opacity(0.24) : AppTheme.border.opacity(0.82), lineWidth: 1)

                Label(title, systemImage: isOn ? "checkmark.circle.fill" : systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .foregroundStyle(isOn ? AppTheme.accentBlue : .secondary)
        .help(isOn ? "关闭\(title)" : "开启\(title)")
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .accessibilityHint(isOn ? "点击关闭\(title)" : "点击开启\(title)")
    }
}

struct CompactFloatingSlider: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    let displayValue: String
    var showsBackground = true

    var body: some View {
        AlignedSettingSliderRow(
            title: title,
            systemImage: systemImage,
            value: $value,
            range: range,
            step: step,
            displayValue: displayValue
        )
        .padding(.horizontal, showsBackground ? 6 : 2)
        .padding(.vertical, showsBackground ? 4 : 0)
        .background(
            Group {
                if showsBackground {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.calloutOptionBackground)
                }
            }
        )
    }
}
