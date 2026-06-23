import SwiftUI

struct FloatingPanelCloseButton: View {
    let scale: CGFloat
    let action: () -> Void
    @Environment(\.tokenDisplayTextTone) private var textTone

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .frame(width: 24 * scale, height: 24 * scale)
                Image(systemName: "xmark")
                    .font(.system(size: 7.8 * scale, weight: .bold))
                    .foregroundStyle(textTone.primaryColor)
                    .frame(width: 10 * scale, height: 10 * scale, alignment: .center)
                    .padding(.trailing, 5.5 * scale)
                    .padding(.top, 4.5 * scale)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("关闭悬浮窗")
        .accessibilityLabel("关闭悬浮窗")
        .accessibilityHint("关闭当前悬浮窗显示")
    }
}

struct FloatingPanelLockButton: View {
    let state: TokenDisplayLockState
    let targetDescription: String?
    let scale: CGFloat
    let action: () -> Void
    @Environment(\.tokenDisplayTextTone) private var textTone

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: 24 * scale, height: 24 * scale)
                Image(systemName: state.systemImage)
                    .font(.system(size: 7.8 * scale, weight: .bold))
                    .foregroundStyle(textTone.primaryColor)
                    .frame(width: 10 * scale, height: 10 * scale, alignment: .center)
                    .padding(.leading, 5.5 * scale)
                    .padding(.top, 4.5 * scale)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(state == .locked ? "悬浮窗已锁定" : "锁定悬浮窗")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(state == .locked ? "解除悬浮窗锁定" : "锁定到最近选择的窗口")
    }

    private var helpText: String {
        guard state == .locked else {
            return TokenDisplayLockState.unlocked.helpText
        }
        if let targetDescription, !targetDescription.isEmpty {
            return "已锁定到 \(targetDescription)"
        }
        return TokenDisplayLockState.locked.helpText
    }

    private var accessibilityValue: String {
        guard state == .locked else { return "未锁定" }
        if let targetDescription, !targetDescription.isEmpty {
            return "已锁定到 \(targetDescription)"
        }
        return "已锁定"
    }
}
