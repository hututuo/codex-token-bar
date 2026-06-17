import SwiftUI

struct FloatingUnreadEffectMenu: View {
    @Binding var selection: String
    let closeAction: () -> Void

    var body: some View {
        SettingsCalloutContainer(
            title: "提醒样式",
            subtitle: nil,
            systemImage: "bell.badge",
            closeAction: closeAction
        ) {
            Text("有完成的会话还没点开时，悬浮窗用选中的样式提醒。")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(AppTheme.calloutOptionBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            SettingsCalloutSection("样式") {
                VStack(spacing: 5) {
                    unreadEffectOption(.off)
                    unreadEffectOption(.ripple)
                    unreadEffectOption(.shimmer)
                }
                .padding(6)
            }
        }
    }

    private func unreadEffectOption(_ effect: FloatingPanelUnreadEffect) -> some View {
        let isSelected = selection == effect.rawValue
        return Button {
            selection = effect.rawValue
            triggerUnreadEffectPreview(effect)
            closeAction()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: unreadEffectIcon(effect))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(isSelected ? AppTheme.accentBlue : .secondary)
                    .frame(width: 15)

                VStack(alignment: .leading, spacing: 0) {
                    Text(unreadEffectTitle(effect))
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(unreadEffectSubtitle(effect))
                        .font(.system(size: 8.8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? AppTheme.accentBlue : .secondary.opacity(0.45))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AppTheme.selectedControlBackground : AppTheme.calloutOptionBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isSelected ? AppTheme.accentBlue.opacity(0.55) : AppTheme.border.opacity(0.50), lineWidth: 1)
        )
    }

    private func unreadEffectTitle(_ effect: FloatingPanelUnreadEffect) -> String {
        switch effect {
        case .off:
            return "关"
        case .ripple:
            return "涟漪"
        case .shimmer:
            return "扫光"
        }
    }

    private func unreadEffectSubtitle(_ effect: FloatingPanelUnreadEffect) -> String {
        switch effect {
        case .off:
            return "不显示动效"
        case .ripple:
            return "圆形水波"
        case .shimmer:
            return "柔和光带"
        }
    }

    private func unreadEffectIcon(_ effect: FloatingPanelUnreadEffect) -> String {
        switch effect {
        case .off:
            return "bell.slash"
        case .ripple:
            return "dot.radiowaves.left.and.right"
        case .shimmer:
            return "sparkles"
        }
    }

    private func triggerUnreadEffectPreview(_ effect: FloatingPanelUnreadEffect) {
        guard effect != .off else {
            UserDefaults.standard.set(0.0, forKey: FloatingPanelAppearance.unreadPreviewUntilKey)
            return
        }
        let duration: TimeInterval = 3.2
        let previewUntil = Date.timeIntervalSinceReferenceDate + duration
        UserDefaults.standard.set(previewUntil, forKey: FloatingPanelAppearance.unreadPreviewUntilKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.15) {
            let currentPreviewUntil = UserDefaults.standard.double(forKey: FloatingPanelAppearance.unreadPreviewUntilKey)
            if currentPreviewUntil <= previewUntil {
                UserDefaults.standard.set(0.0, forKey: FloatingPanelAppearance.unreadPreviewUntilKey)
            }
        }
    }
}

