import SwiftUI

struct SettingsCalloutContainer<Content: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    var accent: Color = AppTheme.accentBlue
    var closeAction: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accent.opacity(0.13))
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(accent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                if let closeAction {
                    Button(action: closeAction) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("关闭")
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.calloutOptionBackground)
            )

            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.calloutBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.borderStrong.opacity(0.42), lineWidth: 1)
        )
        .compositingGroup()
    }
}

struct SettingsCalloutSection<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.calloutOptionBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.62), lineWidth: 1)
            )
        }
    }
}

struct SettingsCalloutRow: View {
    let title: String
    let value: String
    var systemImage: String?
    var isEmphasized = false
    var isLast = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isEmphasized ? AppTheme.accentBlue : .secondary)
                    .frame(width: 15)
            }

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)

            Text(value)
                .font(.system(size: 11, weight: isEmphasized ? .bold : .semibold))
                .foregroundStyle(isEmphasized ? .primary : .secondary)
                .monospacedDigit()
                .lineLimit(5)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(AppTheme.border.opacity(0.58))
                    .frame(height: 1)
                    .padding(.leading, systemImage == nil ? 11 : 35)
            }
        }
    }
}
