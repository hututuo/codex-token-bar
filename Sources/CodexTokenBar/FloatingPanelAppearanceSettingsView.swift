import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FloatingUnreadEffectButtonBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct FloatingPanelPaletteButtonBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct FloatingPanelContentSettingsButtonBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct FloatingPanelAppearanceSettings: View {
    @Binding var floatingPanelOpacity: Double
    @Binding var floatingPanelScale: Double
    @Binding var startHex: String
    @Binding var endHex: String
    @Binding var directionRaw: String
    @Binding var styleRaw: String
    @Binding var unreadEffectRaw: String
    @Binding var isPaletteMenuPresented: Bool
    @Binding var isUnreadEffectMenuPresented: Bool
    @AppStorage(FloatingPanelAppearance.textWhiteOverrideKey) private var floatingPanelTextWhiteOverride = FloatingPanelAppearance.defaultTextWhiteOverride

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            VStack(spacing: 4) {
                FloatingPanelPaletteControl(
                    startHex: $startHex,
                    endHex: $endHex,
                    directionRaw: $directionRaw,
                    styleRaw: $styleRaw,
                    isPresented: $isPaletteMenuPresented,
                    willOpen: {
                        isUnreadEffectMenuPresented = false
                    }
                )
                .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)

                FloatingUnreadEffectPicker(
                    selection: normalizedUnreadEffectBinding,
                    isPresented: $isUnreadEffectMenuPresented,
                    willOpen: {
                        isPaletteMenuPresented = false
                    }
                )
                    .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
            }
            .frame(width: 76, alignment: .leading)
            .zIndex(2)

            VStack(spacing: 0) {
                CompactFloatingSlider(
                    title: "透明度",
                    systemImage: "circle.lefthalf.filled",
                    value: $floatingPanelOpacity,
                    range: 0.45...0.98,
                    displayValue: "\(Int((floatingPanelOpacity * 100).rounded()))%",
                    showsBackground: false
                )

                AppearanceSliderDivider()

                CompactFloatingSlider(
                    title: "大小",
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    value: $floatingPanelScale,
                    range: FloatingTokenPanelMetrics.scaleRange,
                    displayValue: "\(Int((floatingPanelScale * 100).rounded()))%",
                    showsBackground: false
                )

                AppearanceSliderDivider()

                CompactFloatingSlider(
                    title: "字体",
                    systemImage: "textformat",
                    value: $floatingPanelTextWhiteOverride,
                    range: -1...1,
                    displayValue: FloatingPanelTextTonePreference.displayText(for: floatingPanelTextWhiteOverride),
                    showsBackground: false
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .zIndex(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 86)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.solidControlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.border.opacity(0.56), lineWidth: 1)
        )
        .zIndex(isUnreadEffectMenuPresented ? 50 : 0)
    }

    private var normalizedUnreadEffectBinding: Binding<String> {
        Binding(
            get: {
                FloatingPanelUnreadEffect(rawValue: unreadEffectRaw)?.rawValue
                    ?? FloatingPanelAppearance.defaultUnreadEffect
            },
            set: { unreadEffectRaw = $0 }
        )
    }

}

struct FloatingPanelContentSettingsButton: View {
    @Binding var isPresented: Bool
    let willOpen: () -> Void

    var body: some View {
        Button {
            if !isPresented {
                willOpen()
            }
            isPresented.toggle()
        } label: {
            FloatingAppearanceMiniButtonLabel(
                title: "选项设置",
                systemImage: "slider.horizontal.3",
                showsChevron: true,
                isAccent: false
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .anchorPreference(key: FloatingPanelContentSettingsButtonBoundsKey.self, value: .bounds) { anchor in
            anchor
        }
        .help("选择悬浮窗显示内容并拖动排序")
        .accessibilityLabel("选项设置")
        .accessibilityHint("打开悬浮窗显示内容和排序设置")
    }
}

struct FloatingPanelContentSettingsMenu: View {
    @AppStorage(FloatingPanelContentVisibility.rateAndBarKey) private var showRateAndBar = FloatingPanelContentVisibility.default.showRateAndBar
    @AppStorage(FloatingPanelContentVisibility.usageStatusKey) private var showUsageStatus = FloatingPanelContentVisibility.default.showUsageStatus
    @AppStorage(FloatingPanelContentVisibility.metricsKey) private var showMetrics = FloatingPanelContentVisibility.default.showMetrics
    @AppStorage(FloatingPanelContentVisibility.quotaKey) private var showQuota = FloatingPanelContentVisibility.default.showQuota
    @AppStorage(FloatingPanelContentVisibility.radarKey) private var showRadar = FloatingPanelContentVisibility.default.showRadar
    @AppStorage(FloatingPanelContentVisibility.orderKey) private var orderRaw = FloatingPanelContentVisibility.defaultOrderRaw
    @State private var dropTarget: FloatingPanelContentGroup?
    @State private var draggingGroup: FloatingPanelContentGroup?
    let closeAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("选项设置", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Button(action: closeAction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Rectangle()
                .fill(AppTheme.border.opacity(0.58))
                .frame(height: 1)

            VStack(spacing: 2) {
                ForEach(orderedGroups) { group in
                    FloatingPanelContentSettingsRow(
                        group: group,
                        isOn: isOnBinding(for: group),
                        isDropTarget: dropTarget == group,
                        draggingGroup: $draggingGroup
                    )
                    .onDrop(of: [UTType.text.identifier],
                        delegate: FloatingPanelContentDropDelegate(
                            target: group,
                            orderRaw: $orderRaw,
                            draggingGroup: $draggingGroup,
                            dropTarget: $dropTarget
                        )
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.solidControlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.border.opacity(0.58), lineWidth: 1)
        )
    }

    private var orderedGroups: [FloatingPanelContentGroup] {
        FloatingPanelContentVisibility.order(from: orderRaw)
    }

    private func isOnBinding(for group: FloatingPanelContentGroup) -> Binding<Bool> {
        switch group {
        case .rateAndBar:
            return $showRateAndBar
        case .usageStatus:
            return $showUsageStatus
        case .metrics:
            return $showMetrics
        case .quota:
            return $showQuota
        case .radar:
            return $showRadar
        }
    }
}

private struct FloatingPanelContentSettingsRow: View {
    let group: FloatingPanelContentGroup
    @Binding var isOn: Bool
    let isDropTarget: Bool
    @Binding var draggingGroup: FloatingPanelContentGroup?

    var body: some View {
        HStack(spacing: 9) {
            FloatingPanelContentDragHandle()
                .onDrag {
                    draggingGroup = group
                    return NSItemProvider(object: group.rawValue as NSString)
                }

            Image(systemName: group.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.accentBlue)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let settingsSubtitle = group.settingsSubtitle {
                    Text(settingsSubtitle)
                        .font(.system(size: 8.6, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(minHeight: group.settingsSubtitle == nil ? 32 : 39)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDropTarget ? AppTheme.accentBlue.opacity(0.12) : AppTheme.calloutOptionBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isDropTarget ? AppTheme.accentBlue.opacity(0.34) : AppTheme.border.opacity(0.42), lineWidth: 1)
        )
    }
}

private struct FloatingPanelContentDragHandle: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary.opacity(0.72))
            .frame(width: 20, height: 24)
            .contentShape(Rectangle())
            .help("拖动排序")
            .accessibilityLabel("拖动排序")
    }
}

private struct FloatingPanelContentDropDelegate: DropDelegate {
    let target: FloatingPanelContentGroup
    @Binding var orderRaw: String
    @Binding var draggingGroup: FloatingPanelContentGroup?
    @Binding var dropTarget: FloatingPanelContentGroup?

    func validateDrop(info: DropInfo) -> Bool {
        draggingGroup != nil
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggingGroup,
              dragged != target
        else { return }

        let order = FloatingPanelContentVisibility.order(from: orderRaw)
        guard let sourceIndex = order.firstIndex(of: dragged),
              let targetIndex = order.firstIndex(of: target)
        else { return }

        dropTarget = target
        let placement: FloatingPanelContentDropPlacement = sourceIndex < targetIndex ? .after : .before
        let reordered = FloatingPanelContentVisibility.reorderedOrder(
            order,
            moving: dragged,
            relativeTo: target,
            placement: placement
        )
        guard reordered != order else { return }
        orderRaw = FloatingPanelContentVisibility.encodedOrder(reordered)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTarget == target {
            dropTarget = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        draggingGroup = nil
        return true
    }
}

private struct FloatingAppearanceMiniButtonLabel: View {
    let title: String
    let systemImage: String
    var showsChevron = false
    var isAccent = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))

            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.72))
                } else {
                    Color.clear
                }
            }
            .frame(width: 8, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, minHeight: 20, maxHeight: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .foregroundStyle(isAccent ? AppTheme.accentBlue : .primary)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.calloutOptionBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isAccent ? AppTheme.accentBlue.opacity(0.18) : AppTheme.border.opacity(0.74), lineWidth: 1)
        )
    }
}

private struct FloatingUnreadEffectPicker: View {
    @Binding var selection: String
    @Binding var isPresented: Bool
    let willOpen: () -> Void

    var body: some View {
        Button {
            if !isPresented {
                willOpen()
            }
            isPresented.toggle()
        } label: {
            FloatingAppearanceMiniButtonLabel(
                title: "提醒",
                systemImage: "bell.badge",
                showsChevron: true,
                isAccent: false
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .anchorPreference(key: FloatingUnreadEffectButtonBoundsKey.self, value: .bounds) { anchor in
            anchor
        }
        .zIndex(isPresented ? 20 : 0)
        .help("选择未读时悬浮窗背景动效")
        .accessibilityLabel("提醒样式")
        .accessibilityValue(selectionTitle)
        .accessibilityHint("选择有未读会话时悬浮窗的提醒动画")
    }

    private var selectionTitle: String {
        switch FloatingPanelUnreadEffect(rawValue: selection) ?? .ripple {
        case .off:
            return "关"
        case .ripple:
            return "涟漪"
        case .shimmer:
            return "扫光"
        }
    }
}


struct FloatingPanelPaletteControl: View {
    @Binding var startHex: String
    @Binding var endHex: String
    @Binding var directionRaw: String
    @Binding var styleRaw: String
    @Binding var isPresented: Bool
    var isVertical = false
    let willOpen: () -> Void

    var body: some View {
        Button {
            if !isPresented {
                willOpen()
            }
            isPresented.toggle()
        } label: {
            FloatingAppearanceMiniButtonLabel(
                title: isVertical ? "调色" : "调色盘",
                systemImage: "paintpalette",
                showsChevron: true,
                isAccent: false
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .anchorPreference(key: FloatingPanelPaletteButtonBoundsKey.self, value: .bounds) { anchor in
            anchor
        }
        .zIndex(isPresented ? 22 : 0)
        .help("调整悬浮窗背景与额度条配色")
        .accessibilityLabel("调色盘")
        .accessibilityHint("调整悬浮窗背景和额度条颜色方案")
    }
}
