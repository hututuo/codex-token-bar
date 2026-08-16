import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FloatingStructureDragLifecycle: Equatable {
    private(set) var activeSessionID: UUID?

    mutating func begin(_ sessionID: UUID) {
        activeSessionID = sessionID
    }

    @discardableResult
    mutating func finish(_ sessionID: UUID? = nil) -> Bool {
        guard let activeSessionID else { return false }
        if let sessionID, sessionID != activeSessionID {
            return false
        }
        self.activeSessionID = nil
        return true
    }
}

struct FloatingPanelStructureEditor: View {
    private static let editorRowHeight: CGFloat = 42
    private static let editorGapHeight: CGFloat = 7
    private final class DropPreviewRevision {
        var value = 0

        func advance() {
            value &+= 1
        }
    }
    @Binding var visibility: FloatingPanelContentVisibility
    let snapshot: TokenDisplaySnapshot
    let radarPresentation: CodexRadarPresentationState
    let opacity: Double
    let scale: Double
    let textTone: Double
    let appearance: FloatingPanelAppearance
    let quotaColorMode: String
    let quotaFixedHex: String
    @Binding var selectedRowID: String?
    let showsPreview: Bool

    @State private var draggedItem: DraggedItem?
    @State private var dropPreview: DropPreview?
    @State private var dropPreviewRevision = DropPreviewRevision()
    @State private var dragLifecycle = FloatingStructureDragLifecycle()
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

    fileprivate enum DropPreview: Equatable {
        case gap(targetID: String, placement: FloatingPanelContentDropPlacement)
        case pageSlot(
            targetID: String,
            placement: FloatingPanelContentDropPlacement,
            group: FloatingPanelContentGroup
        )
        case hidden
    }

    private enum PageChipRenderItem: Identifiable {
        case group(FloatingPanelContentGroup)
        case placeholder(FloatingPanelContentGroup)

        var id: String {
            switch self {
            case let .group(group): "group:\(group.rawValue)"
            case let .placeholder(group): "placeholder:\(group.rawValue)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("悬浮窗布局")
                        .font(.system(size: 13, weight: .semibold))
                    Text("每一块就是悬浮窗的一行；拖动行排序，拖到“已隐藏”即可隐藏。")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                HStack(spacing: 10) {
                    Toggle("显示翻页箭头", isOn: pageNavigationArrowsBinding)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 9.5, weight: .medium))
                        .fixedSize()
                        .help("关闭后只隐藏箭头图案，左右边缘仍可点击翻页")
                    Button("恢复默认布局") {
                        resetConfirmationPresented = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                editorColumn
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                if showsPreview {
                    previewColumn
                        .frame(width: 238, alignment: .top)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "dollarsign.circle")
                    .foregroundStyle(AppTheme.accentBlue)
                Text("费用按真实模型与缓存价格计算；未知模型使用回退模型；Spark 使用暂定 API 参考价，但独立额度不计入总计。")
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
            Text("将恢复默认显示、顺序、翻页箭头和“今日模型占比 → 今日模型费用”组合。")
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
        .onDisappear {
            finishDrag()
        }
    }

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("结构编辑器")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
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
        let isSelected = selectedRowID == row.id && draggedItem == nil
        let pageItems = pageChipItems(for: row, groups: groups, inlineGroups: inlineGroups)
        let dragPreviewWidth = rowDragPreviewWidth(for: groups)
        let previewsPageSlot: Bool = {
            if case let .pageSlot(targetID, _, _) = dropPreview {
                return targetID == row.id
            }
            return false
        }()
        let displaysPaging = row.isPaged || previewsPageSlot
        let isDragSource: Bool = {
            if case let .row(id, _) = draggedItem { return id == row.id }
            return false
        }()

        return HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 28)
                .contentShape(Rectangle())
                .overlay {
                    FloatingStructureDragSource(
                        payload: "row:\(row.id)",
                        previewSize: NSSize(width: dragPreviewWidth, height: Self.editorRowHeight),
                        cursorAnchor: NSPoint(x: 18, y: Self.editorRowHeight / 2),
                        onBegin: { sessionID in
                            beginDrag(.row(id: row.id, groups: groups), sessionID: sessionID)
                        },
                        onEnd: { sessionID in
                            finishDrag(sessionID: sessionID)
                        }
                    ) {
                        rowDragPreview(row: row, groups: groups, inlineGroups: inlineGroups, width: dragPreviewWidth)
                    }
                }
                .help("拖动整行")

            HStack(spacing: 5) {
                ForEach(Array(pageItems.enumerated()), id: \.element.id) { index, item in
                    switch item {
                    case let .group(group):
                        pageChip(
                            group,
                            isDefault: displaysPaging && index == 0,
                            isInline: inlineGroups.contains(group),
                            isPaged: displaysPaging
                        )
                    case let .placeholder(group):
                        pagePlaceholder(group, isDefault: displaysPaging && index == 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                if case .page = draggedItem {
                    HStack(spacing: 0) {
                        pageDropZone(target: row, placement: .before)
                        pageDropZone(target: row, placement: .after)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: dropPreview)

            if displaysPaging {
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
        .frame(height: Self.editorRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? AppTheme.selectedControlBackground : AppTheme.calloutOptionBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    isSelected ? AppTheme.accentBlue.opacity(0.42) : AppTheme.border.opacity(0.6),
                    style: StrokeStyle(lineWidth: 1, dash: isDragSource ? [4, 3] : [])
                )
        )
        .opacity(isDragSource ? 0.44 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .id("floating-structure-row:\(row.id)")
        .onTapGesture { selectedRowID = row.id }
        .onDrop(
            of: [UTType.text.identifier],
            delegate: FloatingStructureRowDropDelegate(
                target: row,
                draggedItem: $draggedItem,
                canDrop: { item, placement in canDropOnRow(item, target: row, placement: placement) },
                previewForPlacement: { placement in canonicalGapPreview(target: row, placement: placement) },
                showPreview: showDropPreview,
                clearPreview: clearDropPreview,
                clearPreviewAfterExit: clearDropPreviewAfterExit,
                onDrop: { item, placement in handleDrop(item, on: row, placement: placement) },
                finishDrag: { finishDrag() }
            )
        )
    }

    private func beginDrag(_ item: DraggedItem, sessionID: UUID) {
        dragLifecycle.begin(sessionID)
        draggedItem = item
        clearDropPreview()
    }

    private func finishDrag(sessionID: UUID? = nil) {
        let finishedActiveSession = dragLifecycle.finish(sessionID)
        guard finishedActiveSession || sessionID == nil else { return }
        draggedItem = nil
        clearDropPreview()
    }

    private func showDropPreview(_ preview: DropPreview) {
        dropPreviewRevision.advance()
        guard dropPreview != preview else { return }
        dropPreview = preview
    }

    private func clearDropPreview() {
        dropPreviewRevision.advance()
        guard dropPreview != nil else { return }
        dropPreview = nil
    }

    private func clearDropPreviewAfterExit(_ preview: DropPreview) {
        let revision = dropPreviewRevision.value
        DispatchQueue.main.async {
            guard dropPreviewRevision.value == revision, dropPreview == preview else { return }
            dropPreviewRevision.advance()
            dropPreview = nil
        }
    }

    private func canonicalGapPreview(
        target: FloatingPanelLayoutRow,
        placement: FloatingPanelContentDropPlacement
    ) -> DropPreview {
        guard placement == .after,
              let targetIndex = visibility.layoutRows.firstIndex(where: { $0.id == target.id }),
              visibility.layoutRows.indices.contains(targetIndex + 1) else {
            return .gap(targetID: target.id, placement: placement)
        }
        return .gap(targetID: visibility.layoutRows[targetIndex + 1].id, placement: .before)
    }

    private func pageChip(
        _ group: FloatingPanelContentGroup,
        isDefault: Bool,
        isInline: Bool,
        isPaged: Bool
    ) -> some View {
        let dragPreviewWidth = pageDragPreviewWidth(for: group)
        return HStack(spacing: 3) {
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
        .overlay {
            if group.supportsPaging, !isInline {
                FloatingStructureDragSource(
                    payload: "page:\(group.rawValue)",
                    previewSize: NSSize(width: dragPreviewWidth, height: 34),
                    cursorAnchor: NSPoint(x: 20, y: 17),
                    onBegin: { sessionID in
                        beginDrag(.page(group), sessionID: sessionID)
                    },
                    onEnd: { sessionID in
                        finishDrag(sessionID: sessionID)
                    },
                    onDoubleClick: {
                        if isPaged, !isDefault {
                            swapDefault(group)
                        }
                    }
                ) {
                    pageDragPreview(group)
                }
            }
        }
        .onTapGesture(count: 2) {
            if isPaged && !isDefault {
                swapDefault(group)
            }
        }
        .help(group.supportsPaging && !isInline ? "拖到另一行组合，拖到行间拆分" : "内联内容随整行移动")
    }

    private func rowDragPreview(
        row: FloatingPanelLayoutRow,
        groups: [FloatingPanelContentGroup],
        inlineGroups: Set<FloatingPanelContentGroup>,
        width: CGFloat
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            HStack(spacing: 5) {
                ForEach(Array(groups.enumerated()), id: \.element) { index, group in
                    FloatingStructureDragPreviewChip(
                        group: group,
                        isDefault: row.isPaged && index == 0,
                        isInline: inlineGroups.contains(group)
                    )
                }
            }

            Spacer(minLength: 4)

            if row.isPaged {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: Self.editorRowHeight)
        .background(AppTheme.calloutOptionBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(AppTheme.accentBlue.opacity(0.48), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 5, y: 2)
    }

    private func pageDragPreview(_ group: FloatingPanelContentGroup) -> some View {
        HStack(spacing: 5) {
            Image(systemName: group.systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(group.title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
            Text("翻页项")
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .foregroundStyle(Color.primary)
        .background(AppTheme.solidControlBackground, in: Capsule())
        .overlay(Capsule().stroke(AppTheme.accentBlue.opacity(0.52), lineWidth: 1))
        .padding(2)
        .shadow(color: Color.black.opacity(0.16), radius: 4, y: 2)
    }

    private func rowDragPreviewWidth(for groups: [FloatingPanelContentGroup]) -> CGFloat {
        let titleWidth = groups.reduce(CGFloat.zero) { partial, group in
            partial + CGFloat(group.title.count) * 10.5 + 35
        }
        return min(620, max(280, titleWidth + 72))
    }

    private func pageDragPreviewWidth(for group: FloatingPanelContentGroup) -> CGFloat {
        max(132, CGFloat(group.title.count) * 11 + 82)
    }

    private func pageChipItems(
        for row: FloatingPanelLayoutRow,
        groups: [FloatingPanelContentGroup],
        inlineGroups: Set<FloatingPanelContentGroup>
    ) -> [PageChipRenderItem] {
        guard case let .pageSlot(targetID, placement, draggedGroup) = dropPreview,
              targetID == row.id,
              let targetGroup = pageMergeTarget(for: draggedGroup, in: row),
              targetGroup != draggedGroup else {
            return groups.map(PageChipRenderItem.group)
        }

        // `pagePairs` is intentionally a two-page V01 format. A full paged
        // row therefore cannot absorb a third page without changing the
        // persisted contract. Keep both existing chips in their stored
        // order and show the dropped item as a third, same-sized right slot;
        // the drop handler turns it into the adjacent standalone row.
        if row.isPaged, placement == .after, !row.groups.contains(draggedGroup) {
            return groups.map(PageChipRenderItem.group) + [.placeholder(draggedGroup)]
        }

        let pair: [PageChipRenderItem]
        switch placement {
        case .before:
            pair = [.placeholder(draggedGroup), .group(targetGroup)]
        case .after:
            pair = [.group(targetGroup), .placeholder(draggedGroup)]
        }
        let inline = groups
            .filter { inlineGroups.contains($0) && $0 != draggedGroup && $0 != targetGroup }
            .map(PageChipRenderItem.group)
        return pair + inline
    }

    private func pagePlaceholder(
        _ group: FloatingPanelContentGroup,
        isDefault: Bool
    ) -> some View {
        HStack(spacing: 3) {
            if isDefault {
                Image(systemName: "star.fill")
                    .font(.system(size: 7))
            }
            Text(group.title)
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1)
            if isDefault {
                Text("默认")
                    .font(.system(size: 7.2, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 25)
        .foregroundStyle(AppTheme.accentBlue.opacity(0.82))
        .background(Capsule().fill(AppTheme.accentBlue.opacity(0.07)))
        .overlay(Capsule().stroke(AppTheme.accentBlue.opacity(0.42), lineWidth: 1))
        .shadow(color: AppTheme.accentBlue.opacity(0.05), radius: 1)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
        .accessibilityLabel("\(group.title)可放置位置")
    }

    private func pageDropZone(
        target: FloatingPanelLayoutRow,
        placement: FloatingPanelContentDropPlacement
    ) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.001))
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(
                of: [UTType.text.identifier],
                delegate: FloatingStructurePageSlotDropDelegate(
                    target: target,
                    placement: placement,
                    draggedItem: $draggedItem,
                    canDrop: { item in canDropPage(item, target: target, placement: placement) },
                    showPreview: showDropPreview,
                    clearPreview: clearDropPreview,
                    clearPreviewAfterExit: clearDropPreviewAfterExit,
                    onDrop: { item in handlePageDrop(item, target: target, placement: placement) },
                    finishDrag: { finishDrag() }
                )
            )
    }

    private func rowDropGap(
        target: FloatingPanelLayoutRow,
        placement: FloatingPanelContentDropPlacement
    ) -> some View {
        let preview = canonicalGapPreview(target: target, placement: placement)
        let isTarget = dropPreview == preview
        return ZStack {
            if isTarget {
                Capsule()
                    .fill(AppTheme.accentBlue.opacity(0.9))
                    .frame(height: 2)
                    .padding(.horizontal, 7)
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.editorGapHeight)
            .padding(.horizontal, 4)
            .onDrop(
                of: [UTType.text.identifier],
                delegate: FloatingStructureGapDropDelegate(
                    target: target,
                    placement: placement,
                    draggedItem: $draggedItem,
                    canDrop: { item in canDropIntoGap(item, target: target, placement: placement) },
                    preview: preview,
                    showPreview: showDropPreview,
                    clearPreview: clearDropPreview,
                    clearPreviewAfterExit: clearDropPreviewAfterExit,
                    onDrop: { item in handleGapDrop(item, target: target, placement: placement) },
                    finishDrag: { finishDrag() }
                )
            )
    }

    private var hiddenZone: some View {
        let isDropTarget = dropPreview == .hidden
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("已隐藏")
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Text(isDropTarget ? "松手即可隐藏" : "拖到这里隐藏")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(isDropTarget ? AppTheme.accentBlue : Color.secondary)
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
        .background(
            isDropTarget ? AppTheme.accentBlue.opacity(0.1) : AppTheme.panelBackgroundAlt,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    isDropTarget ? AppTheme.accentBlue.opacity(0.9) : AppTheme.border.opacity(0.7),
                    style: StrokeStyle(lineWidth: isDropTarget ? 1.5 : 1, dash: [4, 3])
                )
        )
        .onDrop(
            of: [UTType.text.identifier],
            delegate: FloatingStructureHiddenDropDelegate(
                draggedItem: $draggedItem,
                showPreview: showDropPreview,
                clearPreview: clearDropPreview,
                clearPreviewAfterExit: clearDropPreviewAfterExit,
                onDrop: handleHiddenDrop,
                finishDrag: { finishDrag() }
            )
        )
    }

    private var previewColumn: some View {
        FloatingPanelLivePreview(
            visibility: visibility,
            snapshot: snapshot,
            radarPresentation: radarPresentation,
            opacity: opacity,
            scale: scale,
            textTone: textTone,
            appearance: appearance,
            quotaColorMode: quotaColorMode,
            quotaFixedHex: quotaFixedHex,
            selectedRowID: $selectedRowID
        )
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
        case .page:
            return
        }
    }

    private func canDropOnRow(
        _ item: DraggedItem,
        target: FloatingPanelLayoutRow,
        placement: FloatingPanelContentDropPlacement
    ) -> Bool {
        switch item {
        case let .row(id, groups):
            guard id != target.id else { return false }
            let nextOrder = FloatingPanelContentVisibility.movingRow(
                in: visibility.groupOrder,
                groups: groups,
                relativeTo: visibility.editorGroups(for: target),
                placement: placement
            )
            return nextOrder != visibility.groupOrder
        case .page:
            return false
        }
    }

    private func pageMergeTarget(
        for group: FloatingPanelContentGroup,
        in target: FloatingPanelLayoutRow
    ) -> FloatingPanelContentGroup? {
        target.groups.first(where: { $0 != group }) ?? target.groups.first
    }

    private func canDropPage(
        _ item: DraggedItem,
        target: FloatingPanelLayoutRow,
        placement: FloatingPanelContentDropPlacement
    ) -> Bool {
        guard case let .page(group) = item, group.supportsPaging else { return false }

        // `pagePairs` is intentionally a two-page V01 format. Dropping into
        // the full row's rightmost slot must not replace either stored page;
        // preview it as a third chip and commit it as the adjacent standalone
        // row instead.
        if target.isPaged, placement == .after {
            guard !target.groups.contains(group) else { return false }
            var next = visibility
            next.pagePairs = FloatingPanelContentVisibility.splittingPage(
                in: visibility.pagePairs,
                group: group
            )
            next.groupOrder = FloatingPanelContentVisibility.movingRow(
                in: visibility.groupOrder,
                groups: [group],
                relativeTo: visibility.editorGroups(for: target),
                placement: .after
            )
            next.setVisible(true, for: [group])
            return next != visibility
        }

        guard let targetGroup = pageMergeTarget(for: group, in: target),
              group != targetGroup,
              targetGroup.supportsPaging else { return false }
        var next = visibility
        next.pagePairs = FloatingPanelContentVisibility.mergingPage(
            in: visibility.pagePairs,
            group: group,
            into: targetGroup
        )
        if placement == .before {
            next.pagePairs = FloatingPanelContentVisibility.swappingDefaultPage(
                in: next.pagePairs,
                for: group
            )
        }
        next.groupOrder = FloatingPanelContentVisibility.reorderedOrder(
            visibility.groupOrder,
            moving: group,
            relativeTo: targetGroup,
            placement: placement
        )
        next.setVisible(true, for: [group, targetGroup])
        return next != visibility
    }

    private func handlePageDrop(
        _ item: DraggedItem,
        target: FloatingPanelLayoutRow,
        placement: FloatingPanelContentDropPlacement
    ) {
        guard case let .page(group) = item, group.supportsPaging else { return }

        if target.isPaged, placement == .after {
            guard !target.groups.contains(group) else { return }
            var next = visibility
            next.pagePairs = FloatingPanelContentVisibility.splittingPage(
                in: visibility.pagePairs,
                group: group
            )
            next.groupOrder = FloatingPanelContentVisibility.movingRow(
                in: visibility.groupOrder,
                groups: [group],
                relativeTo: visibility.editorGroups(for: target),
                placement: .after
            )
            next.setVisible(true, for: [group])
            commit(next, message: "已将\(group.title)拆成独立一行，置于此翻页行之后")
            return
        }

        guard let targetGroup = pageMergeTarget(for: group, in: target),
              group != targetGroup,
              targetGroup.supportsPaging else { return }
        var next = visibility
        let oldPartner = visibility.pagePairs
            .first(where: { $0.contains(targetGroup) })?
            .partner(of: targetGroup)
        next.pagePairs = FloatingPanelContentVisibility.mergingPage(
            in: visibility.pagePairs,
            group: group,
            into: targetGroup
        )
        if placement == .before {
            next.pagePairs = FloatingPanelContentVisibility.swappingDefaultPage(
                in: next.pagePairs,
                for: group
            )
        }
        next.groupOrder = FloatingPanelContentVisibility.reorderedOrder(
            visibility.groupOrder,
            moving: group,
            relativeTo: targetGroup,
            placement: placement
        )
        next.setVisible(true, for: [group, targetGroup])
        let suffix = oldPartner.flatMap { $0 == group ? nil : "，\($0.title)已恢复单独显示" } ?? ""
        commit(next, message: "已将\(group.title)与\(targetGroup.title)成组\(suffix)")
    }

    private func canDropIntoGap(
        _ item: DraggedItem,
        target: FloatingPanelLayoutRow,
        placement: FloatingPanelContentDropPlacement
    ) -> Bool {
        switch item {
        case let .row(id, groups):
            guard id != target.id else { return false }
            return FloatingPanelContentVisibility.movingRow(
                in: visibility.groupOrder,
                groups: groups,
                relativeTo: visibility.editorGroups(for: target),
                placement: placement
            ) != visibility.groupOrder
        case let .page(group):
            var next = visibility
            next.pagePairs = FloatingPanelContentVisibility.splittingPage(in: visibility.pagePairs, group: group)
            next.groupOrder = FloatingPanelContentVisibility.movingRow(
                in: visibility.groupOrder,
                groups: [group],
                relativeTo: visibility.editorGroups(for: target),
                placement: placement
            )
            return next != visibility
        }
    }

    private func handleGapDrop(
        _ item: DraggedItem,
        target: FloatingPanelLayoutRow,
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
    }

    private func handleHiddenDrop(_ item: DraggedItem) {
        switch item {
        case let .row(_, groups):
            hide(groups)
        case let .page(group):
            hide([group])
        }
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

    private var pageNavigationArrowsBinding: Binding<Bool> {
        Binding(
            get: { visibility.showPageNavigationArrows },
            set: { isVisible in
                var next = visibility
                next.showPageNavigationArrows = isVisible
                commit(next, message: isVisible ? "已显示翻页箭头" : "已隐藏翻页箭头")
            }
        )
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

struct FloatingPanelLivePreview: View {
    let visibility: FloatingPanelContentVisibility
    let snapshot: TokenDisplaySnapshot
    let radarPresentation: CodexRadarPresentationState
    let opacity: Double
    let scale: Double
    let textTone: Double
    let appearance: FloatingPanelAppearance
    let quotaColorMode: String
    let quotaFixedHex: String
    @Binding var selectedRowID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("实时预览")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("预览固定在这里；点击其中一行可定位左侧结构")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            ScrollView([.vertical, .horizontal], showsIndicators: false) {
                previewCard
                    .padding(10)
            }
            .frame(maxWidth: .infinity, minHeight: 310, maxHeight: 430)
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
}

private struct FloatingStructureDragPreviewChip: View {
    let group: FloatingPanelContentGroup
    let isDefault: Bool
    let isInline: Bool

    var body: some View {
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
    }
}

struct FloatingStructureDragSource: NSViewRepresentable {
    let payload: String
    let previewSize: NSSize
    let cursorAnchor: NSPoint
    let preview: AnyView
    let onBegin: (UUID) -> Void
    let onEnd: (UUID) -> Void
    let onDoubleClick: (() -> Void)?

    init<Preview: View>(
        payload: String,
        previewSize: NSSize,
        cursorAnchor: NSPoint,
        onBegin: @escaping (UUID) -> Void,
        onEnd: @escaping (UUID) -> Void,
        onDoubleClick: (() -> Void)? = nil,
        @ViewBuilder preview: () -> Preview
    ) {
        self.payload = payload
        self.previewSize = previewSize
        self.cursorAnchor = cursorAnchor
        self.preview = AnyView(preview())
        self.onBegin = onBegin
        self.onEnd = onEnd
        self.onDoubleClick = onDoubleClick
    }

    func makeNSView(context: Context) -> FloatingStructureDragSourceView {
        let view = FloatingStructureDragSourceView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: FloatingStructureDragSourceView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: FloatingStructureDragSourceView) {
        view.payload = payload
        view.previewSize = previewSize
        view.cursorAnchor = cursorAnchor
        view.preview = preview
        view.onBegin = onBegin
        view.onEnd = onEnd
        view.onDoubleClick = onDoubleClick
    }
}

final class FloatingStructureDragSourceView: NSView, NSDraggingSource {
    var payload = ""
    var previewSize = NSSize(width: 1, height: 1)
    var cursorAnchor = NSPoint.zero
    var preview = AnyView(EmptyView())
    var onBegin: ((UUID) -> Void)?
    var onEnd: ((UUID) -> Void)?
    var onDoubleClick: (() -> Void)?

    private var activeSessionID: UUID?

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard activeSessionID == nil else { return }

        let pasteboardItem = NSPasteboardItem()
        guard pasteboardItem.setString(payload, forType: .string) else { return }

        let image = renderedPreview()
        let sessionID = UUID()
        activeSessionID = sessionID
        onBegin?(sessionID)

        let location = convert(event.locationInWindow, from: nil)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(
            NSRect(
                x: location.x - cursorAnchor.x,
                y: location.y - cursorAnchor.y,
                width: previewSize.width,
                height: previewSize.height
            ),
            contents: image
        )

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard let sessionID = activeSessionID else { return }
        activeSessionID = nil
        onEnd?(sessionID)
    }

    private func renderedPreview() -> NSImage {
        let hostingView = NSHostingView(rootView: preview)
        hostingView.frame = NSRect(origin: .zero, size: previewSize)
        hostingView.appearance = effectiveAppearance
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        if let image = NSImage(data: hostingView.dataWithPDF(inside: hostingView.bounds)) {
            image.size = previewSize
            return image
        }
        return NSImage(size: previewSize)
    }
}

private struct FloatingStructureRowDropDelegate: DropDelegate {
    let target: FloatingPanelLayoutRow
    @Binding var draggedItem: FloatingPanelStructureEditor.DraggedItem?
    let canDrop: (FloatingPanelStructureEditor.DraggedItem, FloatingPanelContentDropPlacement) -> Bool
    let previewForPlacement: (FloatingPanelContentDropPlacement) -> FloatingPanelStructureEditor.DropPreview
    let showPreview: (FloatingPanelStructureEditor.DropPreview) -> Void
    let clearPreview: () -> Void
    let clearPreviewAfterExit: (FloatingPanelStructureEditor.DropPreview) -> Void
    let onDrop: (FloatingPanelStructureEditor.DraggedItem, FloatingPanelContentDropPlacement) -> Void
    let finishDrag: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        switch draggedItem {
        case let .row(id, _):
            return id != target.id
        case .page:
            return false
        case nil:
            return false
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let placement = placement(info)
        guard let draggedItem,
              validateDrop(info: info),
              canDrop(draggedItem, placement) else {
            return nil
        }
        showPreview(previewForPlacement(placement))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        clearPreviewAfterExit(previewForPlacement(.before))
        clearPreviewAfterExit(previewForPlacement(.after))
    }

    func performDrop(info: DropInfo) -> Bool {
        let placement = placement(info)
        guard let draggedItem, canDrop(draggedItem, placement) else {
            clearPreview()
            finishDrag()
            return false
        }
        onDrop(draggedItem, placement)
        finishDrag()
        return true
    }

    private func placement(_ info: DropInfo) -> FloatingPanelContentDropPlacement {
        info.location.y < 22 ? .before : .after
    }
}

private struct FloatingStructurePageSlotDropDelegate: DropDelegate {
    let target: FloatingPanelLayoutRow
    let placement: FloatingPanelContentDropPlacement
    @Binding var draggedItem: FloatingPanelStructureEditor.DraggedItem?
    let canDrop: (FloatingPanelStructureEditor.DraggedItem) -> Bool
    let showPreview: (FloatingPanelStructureEditor.DropPreview) -> Void
    let clearPreview: () -> Void
    let clearPreviewAfterExit: (FloatingPanelStructureEditor.DropPreview) -> Void
    let onDrop: (FloatingPanelStructureEditor.DraggedItem) -> Void
    let finishDrag: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard let draggedItem, case .page = draggedItem else { return false }
        return canDrop(draggedItem)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let draggedItem, case let .page(group) = draggedItem, canDrop(draggedItem) else {
            return nil
        }
        showPreview(.pageSlot(targetID: target.id, placement: placement, group: group))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if case let .page(group) = draggedItem {
            clearPreviewAfterExit(.pageSlot(targetID: target.id, placement: placement, group: group))
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedItem, case .page = draggedItem, canDrop(draggedItem) else {
            clearPreview()
            finishDrag()
            return false
        }
        onDrop(draggedItem)
        finishDrag()
        return true
    }
}

private struct FloatingStructureGapDropDelegate: DropDelegate {
    let target: FloatingPanelLayoutRow
    let placement: FloatingPanelContentDropPlacement
    @Binding var draggedItem: FloatingPanelStructureEditor.DraggedItem?
    let canDrop: (FloatingPanelStructureEditor.DraggedItem) -> Bool
    let preview: FloatingPanelStructureEditor.DropPreview
    let showPreview: (FloatingPanelStructureEditor.DropPreview) -> Void
    let clearPreview: () -> Void
    let clearPreviewAfterExit: (FloatingPanelStructureEditor.DropPreview) -> Void
    let onDrop: (FloatingPanelStructureEditor.DraggedItem) -> Void
    let finishDrag: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard let draggedItem else { return false }
        return canDrop(draggedItem)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let draggedItem, canDrop(draggedItem) else {
            return nil
        }
        showPreview(preview)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        clearPreviewAfterExit(preview)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedItem, canDrop(draggedItem) else {
            clearPreview()
            finishDrag()
            return false
        }
        onDrop(draggedItem)
        finishDrag()
        return true
    }
}

private struct FloatingStructureHiddenDropDelegate: DropDelegate {
    @Binding var draggedItem: FloatingPanelStructureEditor.DraggedItem?
    let showPreview: (FloatingPanelStructureEditor.DropPreview) -> Void
    let clearPreview: () -> Void
    let clearPreviewAfterExit: (FloatingPanelStructureEditor.DropPreview) -> Void
    let onDrop: (FloatingPanelStructureEditor.DraggedItem) -> Void
    let finishDrag: () -> Void

    func validateDrop(info: DropInfo) -> Bool { draggedItem != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard draggedItem != nil else {
            return nil
        }
        showPreview(.hidden)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        clearPreviewAfterExit(.hidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedItem else {
            clearPreview()
            finishDrag()
            return false
        }
        onDrop(draggedItem)
        finishDrag()
        return true
    }
}
