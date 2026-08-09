import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FloatingPanelStructureEditor: View {
    @Binding var visibility: FloatingPanelContentVisibility
    let snapshot: TokenDisplaySnapshot
    let radarPresentation: CodexRadarPresentationState
    let opacity: Double
    let scale: Double
    let textTone: Double
    let appearance: FloatingPanelAppearance
    let quotaColorMode: String
    let quotaFixedHex: String

    @State private var draggedItem: DraggedItem?
    @State private var selectedRowID: String?
    @State private var undoState: UndoState?
    @State private var resetConfirmationPresented = false

    private struct UndoState: Identifiable {
        let id = UUID()
        let previous: FloatingPanelContentVisibility
        let message: String
    }

    fileprivate enum DraggedItem: Equatable {
        case row(id: String, groups: [FloatingPanelContentGroup])
        case page(FloatingPanelContentGroup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("悬浮窗布局")
                        .font(.system(size: 13, weight: .semibold))
                    Text("每一块就是悬浮窗的一行；拖动行排序，拖动胶囊组合或拆分。")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("恢复默认布局") {
                    resetConfirmationPresented = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(alignment: .top, spacing: 12) {
                editorColumn
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                previewColumn
                    .frame(width: 238, alignment: .top)
            }

            HStack(spacing: 6) {
                Image(systemName: "dollarsign.circle")
                    .foregroundStyle(AppTheme.accentBlue)
                Text("费用按真实模型与缓存价格计算；未知模型使用回退模型，Spark 为独立额度。")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(AppTheme.solidControlBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        .overlay(alignment: .bottom) {
            if let undoState {
                undoBar(undoState)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.16), value: undoState?.id)
        .confirmationDialog(
            "恢复默认悬浮窗布局？",
            isPresented: $resetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("恢复默认", role: .destructive) {
                commit(.default, message: "已恢复默认悬浮窗布局")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将恢复默认显示、顺序和“今日模型占比 → 今日模型费用”翻页组合。")
        }
        .onAppear {
            if selectedRowID == nil {
                selectedRowID = visibility.layoutRows.first?.id
            }
        }
        .onChange(of: visibility) {
            if let selectedRowID, visibility.layoutRows.contains(where: { $0.id == selectedRowID }) {
                return
            }
            selectedRowID = visibility.layoutRows.first?.id
        }
    }

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("结构编辑器")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 5) {
                ForEach(Array(visibility.layoutRows.enumerated()), id: \.element.id) { index, row in
                    rowDropGap(target: row, placement: .before)
                    editorRow(row, index: index)
                }
                if let last = visibility.layoutRows.last {
                    rowDropGap(target: last, placement: .after)
                }
            }

            hiddenZone
        }
    }

    private func editorRow(_ row: FloatingPanelLayoutRow, index: Int) -> some View {
        let groups = visibility.editorGroups(for: row)
        let inlineGroups = Set(groups).subtracting(row.groups)
        let isSelected = selectedRowID == row.id

        return HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 28)
                .contentShape(Rectangle())
                .onDrag {
                    draggedItem = .row(id: row.id, groups: groups)
                    return NSItemProvider(object: "row:\(row.id)" as NSString)
                }
                .help("拖动整行")

            HStack(spacing: 5) {
                ForEach(groups) { group in
                    pageChip(
                        group,
                        isDefault: row.isPaged && row.groups.first == group,
                        isInline: inlineGroups.contains(group),
                        isPaged: row.isPaged
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if row.isPaged {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("悬浮窗内可左右翻页")
            }

            Menu {
                Button("整行上移") { moveRow(row, by: -1) }
                    .disabled(index == 0)
                Button("整行下移") { moveRow(row, by: 1) }
                    .disabled(index == visibility.layoutRows.count - 1)
                if row.isPaged, let second = row.groups.dropFirst().first {
                    Divider()
                    Button("交换默认页") { swapDefault(second) }
                    Button("拆分组合") { splitPage(second) }
                }
                Divider()
                Button("隐藏此行") { hide(groups) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .accessibilityLabel("\(groups.map(\.title).joined(separator: "、"))更多操作")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? AppTheme.selectedControlBackground : AppTheme.calloutOptionBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isSelected ? AppTheme.accentBlue.opacity(0.42) : AppTheme.border.opacity(0.6), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { selectedRowID = row.id }
        .onDrop(
            of: [UTType.text.identifier],
            delegate: FloatingStructureRowDropDelegate(
                target: row,
                draggedItem: $draggedItem,
                onDrop: { item, placement in handleDrop(item, on: row, placement: placement) }
            )
        )
    }

    private func pageChip(
        _ group: FloatingPanelContentGroup,
        isDefault: Bool,
        isInline: Bool,
        isPaged: Bool
    ) -> some View {
        HStack(spacing: 3) {
            if isDefault {
                Image(systemName: "star.fill")
                    .font(.system(size: 7))
            }
            Text(group.title)
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1)
            if isDefault || isInline {
                Text(isInline ? "内联" : "默认")
                    .font(.system(size: 7.2, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 25)
        .foregroundStyle(isDefault ? AppTheme.accentBlue : Color.primary)
        .background(
            Capsule()
                .fill(isDefault ? AppTheme.accentBlue.opacity(0.1) : AppTheme.solidControlBackground)
        )
        .overlay(
            Capsule()
                .stroke(isDefault ? AppTheme.accentBlue.opacity(0.34) : AppTheme.border, lineWidth: 1)
        )
        .onDrag {
            guard group.supportsPaging, !isInline else {
                return NSItemProvider(object: "inline:\(group.rawValue)" as NSString)
            }
            draggedItem = .page(group)
            return NSItemProvider(object: "page:\(group.rawValue)" as NSString)
        }
        .onTapGesture(count: 2) {
            if isPaged && !isDefault {
                swapDefault(group)
            }
        }
        .help(group.supportsPaging && !isInline ? "拖到另一行组合，拖到行间拆分" : "内联内容随整行移动")
    }

    private func rowDropGap(
        target: FloatingPanelLayoutRow,
        placement: FloatingPanelContentDropPlacement
    ) -> some View {
        Capsule()
            .fill(draggedPage == nil ? Color.clear : AppTheme.accentBlue.opacity(0.18))
            .frame(height: draggedPage == nil ? 1 : 5)
            .animation(.easeOut(duration: 0.12), value: draggedPage)
            .onDrop(
                of: [UTType.text.identifier],
                delegate: FloatingStructureGapDropDelegate(
                    target: target,
                    placement: placement,
                    draggedItem: $draggedItem,
                    onDrop: { item in handleGapDrop(item, target: target, placement: placement) }
                )
            )
    }

    private var hiddenZone: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("已隐藏")
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Text("恢复后回到原位置")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if hiddenGroups.isEmpty {
                Text("没有隐藏内容")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(hiddenGroups, id: \.self) { groups in
                        Button {
                            restore(groups)
                        } label: {
                            HStack(spacing: 5) {
                                Text(groups.map(\.title).joined(separator: " · "))
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(9)
        .background(AppTheme.panelBackgroundAlt, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(AppTheme.border.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("实时预览")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("点击预览中的行可对应左侧结构")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            ScrollView([.vertical, .horizontal], showsIndicators: false) {
                previewCard
                    .padding(10)
            }
            .frame(maxWidth: .infinity, minHeight: 290, maxHeight: 390)
            .background(AppTheme.panelBackgroundAlt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        }
    }

    private var previewCard: some View {
        let previewScale = min(0.82, max(0.72, FloatingTokenPanelMetrics.clampedScale(scale)))
        let size = FloatingTokenPanelMetrics.size(scale: Double(previewScale), visibility: visibility)
        let textTonePreference = FloatingPanelTextTonePreference.mode(for: textTone)
        let automaticPalettes = appearance.textPalettes(
            panelSize: size,
            scale: previewScale,
            opacity: opacity,
            automaticStrength: textTonePreference.automaticStrength,
            visibility: visibility,
            hasPreciseTokenUsage: snapshot.hasPreciseTokenUsage
        )
        let overridePalette = textTonePreference.manualWhite.map(FloatingPanelReadableTextPalette.init(fixedWhite:))
        let baseTextPalette = overridePalette ?? automaticPalettes.controlPalette
        let rowTextPalettes = overridePalette.map { palette in
            Dictionary(uniqueKeysWithValues: FloatingPanelContentGroup.allCases.map { ($0, palette) })
        } ?? automaticPalettes.rowPalettes
        let metricTextPalettes = overridePalette.map { palette in
            Dictionary(uniqueKeysWithValues: FloatingPanelMetricTextRegion.allCases.map { ($0, palette) })
        } ?? automaticPalettes.metricPalettes
        let quotaColorStyle = FloatingQuotaColorStyle(
            modeRaw: quotaColorMode,
            fixedHex: quotaFixedHex,
            gradientAppearance: appearance
        )

        return ZStack {
            TokenGlassBackground(
                opacity: opacity,
                cornerRadius: FloatingTokenPanelMetrics.baseCornerRadius * previewScale,
                appearance: appearance
            )
            TokenDisplayCard(
                snapshot: snapshot,
                radarSnapshot: radarPresentation.snapshot,
                radarPresentation: radarPresentation,
                visibility: visibility,
                onClose: nil,
                selectedPreviewRowID: selectedRowID,
                onPreviewRowSelect: { selectedRowID = $0 }
            )
            .environment(\.tokenDisplayScale, previewScale)
            .environment(\.tokenDisplayTextPalette, baseTextPalette)
            .environment(\.tokenDisplayRowTextPalettes, rowTextPalettes)
            .environment(\.tokenDisplayMetricTextPalettes, metricTextPalettes)
            .environment(\.tokenDisplayQuotaColorStyle, quotaColorStyle)
            .environment(
                \.tokenDisplayEmbeddedUsageStatusTextPalette,
                overridePalette ?? automaticPalettes.embeddedUsageStatusPalette
            )
            .environment(
                \.tokenDisplayStandaloneUsageStatusTextPalette,
                overridePalette ?? automaticPalettes.standaloneUsageStatusPalette
            )
            .environment(\.tokenDisplayRadarActionTextPalette, overridePalette ?? automaticPalettes.radarActionPalette)
            .environment(\.tokenDisplayRadarModelTextPalette, overridePalette ?? automaticPalettes.radarModelPalette)
            .padding(.vertical, FloatingTokenPanelMetrics.verticalPadding * previewScale)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: FloatingTokenPanelMetrics.baseCornerRadius * previewScale, style: .continuous))
    }

    private var draggedPage: FloatingPanelContentGroup? {
        guard case let .page(group) = draggedItem else { return nil }
        return group
    }

    private var hiddenGroups: [[FloatingPanelContentGroup]] {
        let hidden = Set(visibility.groupOrder.filter { !visibility.shows($0) })
        var consumed = Set<FloatingPanelContentGroup>()
        var result: [[FloatingPanelContentGroup]] = []
        for group in visibility.groupOrder where hidden.contains(group) && !consumed.contains(group) {
            if let pair = visibility.pagePairs.first(where: { $0.contains(group) }),
               pair.groups.allSatisfy(hidden.contains) {
                result.append(pair.groups)
                consumed.formUnion(pair.groups)
            } else {
                result.append([group])
                consumed.insert(group)
            }
        }
        return result
    }

    private func handleDrop(
        _ item: DraggedItem,
        on target: FloatingPanelLayoutRow,
        placement: FloatingPanelContentDropPlacement
    ) {
        switch item {
        case let .row(id, groups):
            guard id != target.id else { return }
            var next = visibility
            next.groupOrder = FloatingPanelContentVisibility.movingRow(
                in: visibility.groupOrder,
                groups: groups,
                relativeTo: visibility.editorGroups(for: target),
                placement: placement
            )
            commit(next, message: "已移动整行")
        case let .page(group):
            let targetGroup = target.groups[0]
            guard group != targetGroup, targetGroup.supportsPaging else { return }
            var next = visibility
            let oldPartner = visibility.pagePairs.first(where: { $0.contains(targetGroup) })?.partner(of: targetGroup)
            next.pagePairs = FloatingPanelContentVisibility.mergingPage(
                in: visibility.pagePairs,
                group: group,
                into: targetGroup
            )
            next.groupOrder = FloatingPanelContentVisibility.reorderedOrder(
                visibility.groupOrder,
                moving: group,
                relativeTo: targetGroup,
                placement: .after
            )
            next.setVisible(true, for: [group, targetGroup])
            let suffix = oldPartner.map { "，\($0.title)已恢复单独显示" } ?? ""
            commit(next, message: "已将\(group.title)与\(targetGroup.title)成组\(suffix)")
        }
    }

    private func handleGapDrop(
        _ item: DraggedItem,
        target: FloatingPanelLayoutRow,
        placement: FloatingPanelContentDropPlacement
    ) {
        guard case let .page(group) = item else { return }
        var next = visibility
        next.pagePairs = FloatingPanelContentVisibility.splittingPage(in: visibility.pagePairs, group: group)
        next.groupOrder = FloatingPanelContentVisibility.movingRow(
            in: visibility.groupOrder,
            groups: [group],
            relativeTo: visibility.editorGroups(for: target),
            placement: placement
        )
        commit(next, message: "已将\(group.title)拆成单独一行")
    }

    private func moveRow(_ row: FloatingPanelLayoutRow, by delta: Int) {
        let rows = visibility.layoutRows
        guard let index = rows.firstIndex(where: { $0.id == row.id }),
              rows.indices.contains(index + delta) else { return }
        let target = rows[index + delta]
        var next = visibility
        next.groupOrder = FloatingPanelContentVisibility.movingRow(
            in: visibility.groupOrder,
            groups: visibility.editorGroups(for: row),
            relativeTo: visibility.editorGroups(for: target),
            placement: delta < 0 ? .before : .after
        )
        commit(next, message: "已移动整行")
    }

    private func splitPage(_ group: FloatingPanelContentGroup) {
        var next = visibility
        next.pagePairs = FloatingPanelContentVisibility.splittingPage(in: visibility.pagePairs, group: group)
        commit(next, message: "已拆分\(group.title)所在翻页行")
    }

    private func swapDefault(_ group: FloatingPanelContentGroup) {
        var next = visibility
        next.pagePairs = FloatingPanelContentVisibility.swappingDefaultPage(in: visibility.pagePairs, for: group)
        commit(next, message: "已将\(group.title)设为默认页")
    }

    private func hide(_ groups: [FloatingPanelContentGroup]) {
        var next = visibility
        next.setVisible(false, for: groups)
        commit(next, message: "已隐藏\(groups.map(\.title).joined(separator: "、"))")
    }

    private func restore(_ groups: [FloatingPanelContentGroup]) {
        var next = visibility
        next.setVisible(true, for: groups)
        commit(next, message: "已恢复\(groups.map(\.title).joined(separator: "、"))")
    }

    private func commit(_ next: FloatingPanelContentVisibility, message: String) {
        guard next != visibility else { return }
        let state = UndoState(previous: visibility, message: message)
        visibility = next
        undoState = state
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if undoState?.id == state.id {
                undoState = nil
            }
        }
    }

    private func undoBar(_ state: UndoState) -> some View {
        HStack(spacing: 10) {
            Text(state.message)
                .font(.system(size: 9.5, weight: .medium))
            Button("撤销") {
                visibility = state.previous
                undoState = nil
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(AppTheme.panelBackground, in: Capsule())
        .overlay(Capsule().stroke(AppTheme.borderStrong, lineWidth: 1))
    }
}

private struct FloatingStructureRowDropDelegate: DropDelegate {
    let target: FloatingPanelLayoutRow
    @Binding var draggedItem: FloatingPanelStructureEditor.DraggedItem?
    let onDrop: (FloatingPanelStructureEditor.DraggedItem, FloatingPanelContentDropPlacement) -> Void

    func validateDrop(info: DropInfo) -> Bool { draggedItem != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedItem else { return false }
        let placement: FloatingPanelContentDropPlacement = info.location.y < 22 ? .before : .after
        onDrop(draggedItem, placement)
        self.draggedItem = nil
        return true
    }
}

private struct FloatingStructureGapDropDelegate: DropDelegate {
    let target: FloatingPanelLayoutRow
    let placement: FloatingPanelContentDropPlacement
    @Binding var draggedItem: FloatingPanelStructureEditor.DraggedItem?
    let onDrop: (FloatingPanelStructureEditor.DraggedItem) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard let draggedItem, case .page = draggedItem else { return false }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedItem else { return false }
        onDrop(draggedItem)
        self.draggedItem = nil
        return true
    }
}
