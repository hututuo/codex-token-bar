import AppKit
import SwiftUI

enum SessionManagementLayout {
    // The wide layout has 890 pt of declared pane minima before split-view
    // dividers. Switch with a little breathing room so a refresh cannot make
    // the middle pane grow beyond the sheet and appear clipped.
    static let compactWidth: CGFloat = 920

    static func usesCompactLayout(width: CGFloat) -> Bool {
        width < compactWidth
    }
}

private enum SessionManagementCompactPane: String, CaseIterable, Identifiable {
    case collections
    case sessions
    case details

    var id: String { rawValue }

    var title: String {
        switch self {
        case .collections: return "项目"
        case .sessions: return "会话"
        case .details: return "详情"
        }
    }
}

private enum SessionManagementOfficialConfirmation: Identifiable {
    case archive
    case unarchive

    var id: String {
        switch self {
        case .archive: return "archive"
        case .unarchive: return "unarchive"
        }
    }
}

struct SessionManagementView: View {
    @StateObject private var store: SessionManagementStore
    @ObservedObject private var autoResumeManager: AutoResumeTaskManager
    let onClose: () -> Void
    @State private var compactPane: SessionManagementCompactPane = .sessions
    @State private var officialConfirmation: SessionManagementOfficialConfirmation?
    @State private var showingDeleteOptions = false
    @State private var deleteAcknowledged = false
    @State private var pendingDeletionConfirmation:
        SessionManagementDeletionConfirmation?

    init(
        dataSource: CodexDataSource?,
        autoResumeManager: AutoResumeTaskManager,
        service: any SessionManagementServicing = FoundationSessionManagementBackend(),
        onClose: @escaping () -> Void
    ) {
        self.autoResumeManager = autoResumeManager
        _store = StateObject(
            wrappedValue: SessionManagementStore(
                dataSource: dataSource,
                service: service,
                autoResumeManager: autoResumeManager
            )
        )
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)
            globalStatusBanner
            GeometryReader { proxy in
                if SessionManagementLayout.usesCompactLayout(width: proxy.size.width) {
                    compactBody
                } else {
                    wideBody
                }
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .background(AppTheme.panelBackground)
        .onAppear { store.refresh() }
        .onExitCommand {
            guard !store.isPerformingMutation else { return }
            onClose()
        }
        .alert(item: $officialConfirmation) { action in
            switch action {
            case .archive:
                return Alert(
                    title: Text("官方归档这个会话？"),
                    message: Text("它会从 Codex 普通列表移入官方归档；不会压缩磁盘内容，可随时用官方恢复。"),
                    primaryButton: .default(Text("归档"), action: store.archiveSelected),
                    secondaryButton: .cancel()
                )
            case .unarchive:
                return Alert(
                    title: Text("恢复这个官方归档？"),
                    message: Text("Codex 会把会话恢复到普通会话列表。"),
                    primaryButton: .default(Text("恢复"), action: store.unarchiveSelected),
                    secondaryButton: .cancel()
                )
            }
        }
        .overlay {
            if showingDeleteOptions {
                deleteConfirmationOverlay
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.gearshape")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(AppTheme.accentBlue)
                .frame(width: 34, height: 34)
                .background(AppTheme.selectedControlBackground)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("会话管理")
                    .font(.system(size: 18, weight: .semibold))
                Text(store.statusMessage.isEmpty ? "项目、上下文、归档与容量清理" : store.statusMessage)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if store.isLoadingCatalog || store.isPerformingMutation {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                store.refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(store.isLoadingCatalog || store.isPerformingMutation)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.isPerformingMutation)
            .help(store.isPerformingMutation ? "操作完成前不能关闭" : "关闭会话管理")
        }
        .padding(.horizontal, 18)
        .frame(height: 66)
    }

    private var wideBody: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 190, idealWidth: 218, maxWidth: 280)
            threadList
                .frame(minWidth: 310, idealWidth: 360, maxWidth: 480)
            detail
                .frame(minWidth: 390, maxWidth: .infinity)
        }
    }

    private var compactBody: some View {
        VStack(spacing: 0) {
            Picker("会话管理区域", selection: $compactPane) {
                ForEach(SessionManagementCompactPane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)

            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)

            switch compactPane {
            case .collections:
                sidebar
            case .sessions:
                threadList
            case .details:
                detail
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sidebarHeading("智能集合")
                VStack(spacing: 3) {
                    ForEach(SessionManagementCollection.allCases) { collection in
                        sidebarCollectionButton(collection)
                    }
                }

                sidebarHeading("项目")
                if store.projects.isEmpty {
                    Text("暂无项目会话")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                } else {
                    VStack(spacing: 3) {
                        ForEach(store.projects) { project in
                            sidebarProjectButton(project)
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(AppTheme.panelBackgroundAlt)
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
    }

    private func sidebarCollectionButton(
        _ collection: SessionManagementCollection
    ) -> some View {
        let selected = store.selectedProjectID == nil
            && store.selectedCollection == collection
        return Button {
            store.selectCollection(collection)
            compactPane = .sessions
        } label: {
            HStack(spacing: 8) {
                Image(systemName: collection.systemImage)
                    .frame(width: 16)
                Text(collection.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(collectionCount(collection))")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? AppTheme.accentBlue : Color.primary.opacity(0.82))
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AppTheme.selectedControlBackground : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sidebarProjectButton(
        _ project: SessionManagementProject
    ) -> some View {
        let selected = store.selectedProjectID == project.id
        return Button {
            store.selectProject(project.id)
            compactPane = .sessions
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.displayName)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text("\(project.threadCount) 个")
                        Text(formatBytes(project.totalBytes))
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
            }
            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? AppTheme.accentBlue : Color.primary.opacity(0.82))
            .padding(.horizontal, 9)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AppTheme.selectedControlBackground : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(project.cwd)
    }

    private var threadList: some View {
        VStack(spacing: 0) {
            VStack(spacing: 9) {
                HStack(spacing: 8) {
                    TextField("搜索标题、正文首条、目录或 ID", text: $store.query)
                        .textFieldStyle(.roundedBorder)
                    Picker("排序", selection: $store.sort) {
                        ForEach(SessionManagementSort.allCases) { sort in
                            Text(sort.label).tag(sort)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 112)
                }

                if store.selectedCollection == .large {
                    largeFilters
                }

                HStack(spacing: 8) {
                    Text("\(store.matchingThreads.count) 个结果")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    if !store.checkedThreadIDs.isEmpty {
                        Text(
                            "已选 \(store.checkedThreadIDs.count) 个 · \(formatBytes(store.checkedBytes))"
                                + (store.checkedOutsideCurrentResultsCount > 0
                                    ? " · \(store.checkedOutsideCurrentResultsCount) 个不在当前结果"
                                    : "")
                        )
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(AppTheme.accentBlue)
                    }
                    Spacer()
                    if !store.visibleThreads.filter(\.canDelete).isEmpty {
                        Button("选择当前显示", action: store.toggleAllVisibleChecked)
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5))
                    }
                    if !store.checkedThreadIDs.isEmpty {
                        Button("清除选择", action: store.clearChecked)
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5))
                        Button(role: .destructive) {
                            presentDeleteConfirmation()
                        } label: {
                            Label("删除所选", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            store.isPerformingMutation
                                || store.checkedThreads.contains(where: { !$0.canDelete })
                        )
                    }
                }
            }
            .padding(12)

            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)

            if store.visibleThreads.isEmpty {
                emptyThreadList
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(store.visibleThreads) { thread in
                            sessionRow(thread)
                        }

                        if store.hiddenThreadCount > 0 {
                            Button {
                                store.showMore()
                            } label: {
                                Label(
                                    "继续显示 \(min(SessionManagementPresentation.visiblePageSize, store.hiddenThreadCount)) 个（剩余 \(store.hiddenThreadCount)）",
                                    systemImage: "chevron.down"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .padding(.top, 6)
                        } else if store.matchingThreads.count
                            > SessionManagementPresentation.visiblePageSize {
                            Button("收起到前 100 个", action: store.collapseVisible)
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(AppTheme.panelBackground)
    }

    private var largeFilters: some View {
        HStack(spacing: 8) {
            Picker("未使用", selection: $store.minimumInactiveDays) {
                Text("不限时间").tag(Int?.none)
                Text("≥ 7 天").tag(Int?.some(7))
                Text("≥ 30 天").tag(Int?.some(30))
                Text("≥ 90 天").tag(Int?.some(90))
            }
            Picker("最小容量", selection: $store.minimumBytes) {
                Text("≥ 100 MB").tag(Int64?.some(100 * 1024 * 1024))
                Text("≥ 500 MB").tag(Int64?.some(500 * 1024 * 1024))
                Text("≥ 1 GB").tag(Int64?.some(1024 * 1024 * 1024))
            }
            Spacer()
        }
        .font(.system(size: 10.5))
    }

    private var emptyThreadList: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(store.isLoadingCatalog ? "正在读取会话…" : "没有符合条件的会话")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sessionRow(_ thread: SessionManagementThread) -> some View {
        let selected = store.selectedThreadID == thread.id
        let checked = store.checkedThreadIDs.contains(thread.id)
        return HStack(alignment: .top, spacing: 8) {
            Button {
                store.toggleChecked(thread.id)
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? AppTheme.accentBlue : Color.secondary)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!thread.canDelete || store.isPerformingMutation)
            .help(
                thread.canDelete
                    ? "选择会话进行批量清理"
                    : (thread.protectionReasons.first ?? "当前状态不允许危险操作")
            )
            .accessibilityLabel(
                checked
                    ? "取消选择 \(thread.displayTitle)"
                    : "选择会话 \(thread.displayTitle)"
            )

            Button {
                store.selectThread(thread.id)
                compactPane = .details
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(thread.displayTitle)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Circle()
                            .fill(statusColor(thread.status))
                            .frame(width: 6, height: 6)
                    }

                    HStack(spacing: 5) {
                        if thread.archived {
                            compactBadge("归档", color: AppTheme.accentAmber)
                        }
                        if thread.isSubagent {
                            compactBadge("Subagent", color: AppTheme.accentCyan)
                        } else if thread.hasForkLineage {
                            compactBadge("Fork", color: AppTheme.accentBlue)
                        }
                        if thread.similarityGroupID != nil {
                            compactBadge("可能相似", color: AppTheme.accentOrange)
                        }
                        Spacer()
                    }

                    HStack(spacing: 8) {
                        Label(formatBytes(thread.fileBytes), systemImage: "internaldrive")
                        Label(formatRelativeDate(thread.lastUsedAt), systemImage: "clock")
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.vertical, 8)
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? AppTheme.selectedControlBackground : AppTheme.panelBackgroundAlt)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(selected ? AppTheme.accentBlue.opacity(0.45) : AppTheme.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var detail: some View {
        Group {
            if let thread = store.selectedThread {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        detailHeader(thread)
                        warningCards
                        metadataCard(thread)
                        lineageCard(thread)
                        contextCard(thread)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("选择一个会话查看上下文")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppTheme.pageBackground)
    }

    private func detailHeader(_ thread: SessionManagementThread) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(thread.displayTitle)
                        .font(.system(size: 18, weight: .semibold))
                        .textSelection(.enabled)
                    Text(thread.id)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Text(thread.status.label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(statusColor(thread.status))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor(thread.status).opacity(0.12))
                    .clipShape(Capsule())
            }

            HStack(spacing: 7) {
                if thread.canArchive {
                    Button {
                        officialConfirmation = .archive
                    } label: {
                        Label("官方归档", systemImage: "archivebox")
                    }
                    .buttonStyle(.borderedProminent)
                }
                if thread.canUnarchive {
                    Button {
                        officialConfirmation = .unarchive
                    } label: {
                        Label("恢复归档", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    store.createRecoveryPackage()
                } label: {
                    Label("深度压缩恢复包", systemImage: "doc.zipper")
                }
                .buttonStyle(.bordered)
                .disabled(
                    !thread.canDelete
                        || !thread.status.permitsMutation
                        || !thread.rolloutIdentityVerified
                        || store.isPerformingMutation
                )
                .help("创建并完整回读校验恢复包；不等于官方归档，也不会删除原会话。")

                Button {
                    presentDeleteConfirmation()
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.accentRed)
                .disabled(!thread.canDelete || store.isPerformingMutation)

                Spacer()
            }

            if let url = store.lastRecoveryPackageURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("在 Finder 中显示最新恢复包", systemImage: "folder")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AppTheme.accentBlue)
            }
        }
    }

    @ViewBuilder
    private var globalStatusBanner: some View {
        if let error = store.errorMessage {
            messageCard(
                error,
                systemImage: "exclamationmark.triangle.fill",
                color: AppTheme.accentRed
            )
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        } else if let summary = store.operationSummary {
            messageCard(
                summary,
                systemImage: store.operationSummaryHasFailures
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.circle.fill",
                color: store.operationSummaryHasFailures
                    ? AppTheme.accentAmber
                    : AppTheme.accentGreen
            )
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        } else if let warning = store.catalog.warnings.first {
            let suffix = store.catalog.warnings.count > 1
                ? "（另有 \(store.catalog.warnings.count - 1) 条提醒）"
                : ""
            messageCard(
                warning + suffix,
                systemImage: "shield.lefthalf.filled",
                color: AppTheme.accentAmber
            )
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var warningCards: some View {
        ForEach(Array(store.catalog.warnings.enumerated()), id: \.offset) { _, warning in
            messageCard(
                warning,
                systemImage: "shield.lefthalf.filled",
                color: AppTheme.accentAmber
            )
        }
        if let reason = store.catalog.capabilities.recoveryRestoreUnavailableReason {
            messageCard(
                "恢复包与官方归档分开：\(reason)",
                systemImage: "info.circle",
                color: AppTheme.accentBlue
            )
        }
    }

    private func messageCard(
        _ text: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(color.opacity(0.22), lineWidth: 1)
        )
    }

    private func metadataCard(_ thread: SessionManagementThread) -> some View {
        detailCard(title: "会话概览", systemImage: "info.square") {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 150)),
                    GridItem(.flexible(minimum: 150)),
                ],
                alignment: .leading,
                spacing: 12
            ) {
                metadataItem("项目", value: projectDisplayName(thread.cwd))
                metadataItem("容量", value: formatBytes(thread.fileBytes))
                metadataItem("最后使用", value: formatDate(thread.lastUsedAt))
                metadataItem("创建时间", value: formatDate(thread.createdAt))
                metadataItem("Token 元数据", value: formatInteger(thread.tokensUsed))
                metadataItem("来源", value: thread.source.isEmpty ? "—" : thread.source)
                metadataItem("模型", value: thread.model.isEmpty ? "—" : thread.model)
                metadataItem("Git 分支", value: thread.gitBranch.isEmpty ? "—" : thread.gitBranch)
            }
            if !thread.rolloutPath.isEmpty {
                Text(thread.rolloutPath)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private func lineageCard(_ thread: SessionManagementThread) -> some View {
        if thread.hasForkLineage
            || thread.isSubagent
            || thread.similarityGroupID != nil
            || !thread.protectionReasons.isEmpty {
            detailCard(title: "关系与安全", systemImage: "point.3.connected.trianglepath.dotted") {
                if let forkedFromID = thread.forkedFromID {
                    relationRow("Fork 来源", value: forkedFromID)
                }
                if thread.forkChildCount > 0 {
                    relationRow("Fork 子分支", value: "\(thread.forkChildCount) 个")
                }
                if let parentThreadID = thread.parentThreadID {
                    relationRow("Subagent 父会话", value: parentThreadID)
                }
                if thread.spawnChildCount > 0 {
                    relationRow("Spawned 后代", value: "\(thread.spawnChildCount) 个")
                }
                if let group = thread.similarityGroupID {
                    relationRow("可能相似组", value: group)
                    Text(thread.similarityReason ?? "仅为本地候选，不会自动当成重复或删除。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if !thread.protectionReasons.isEmpty {
                    Text(thread.protectionReasons.joined(separator: " · "))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppTheme.accentAmber)
                }
            }
        }
    }

    private func contextCard(_ thread: SessionManagementThread) -> some View {
        detailCard(title: "上下文", systemImage: "text.bubble") {
            if store.contextHasMoreBefore {
                Button {
                    store.loadOlderContext()
                } label: {
                    Label(
                        store.isLoadingContext ? "读取中…" : "加载更早的 30 条消息",
                        systemImage: "arrow.up"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(store.isLoadingContext)
            }

            ForEach(Array(store.contextWarnings.enumerated()), id: \.offset) { _, warning in
                Text(warning)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppTheme.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.isLoadingContext && store.contextMessages.isEmpty {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在按页读取会话正文…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } else if store.contextMessages.isEmpty {
                Text("该会话暂无可显示的用户或助手消息。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.contextMessages) { message in
                        contextMessage(message)
                    }
                }
            }
        }
    }

    private func contextMessage(
        _ message: SessionManagementContextMessage
    ) -> some View {
        let isUser = message.role == "user"
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(
                    isUser ? "用户" : "Codex",
                    systemImage: isUser ? "person.fill" : "sparkles"
                )
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isUser ? AppTheme.accentBlue : AppTheme.accentGreen)
                Spacer()
                if let timestamp = message.timestamp {
                    Text(timestamp)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Text(message.text)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if message.isTruncated {
                Text("此处只显示该条消息的 64 KB 预览；原始正文未截断，可继续使用完整导出。")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(AppTheme.accentAmber)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isUser ? AppTheme.selectedControlBackground.opacity(0.6) : AppTheme.panelBackgroundAlt)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private func detailCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
            content()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private func metadataItem(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func relationRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func compactBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }

    private func collectionCount(_ collection: SessionManagementCollection) -> Int {
        SessionManagementPresentation.filteredThreads(
            in: store.catalog,
            collection: collection,
            projectID: nil,
            query: "",
            sort: .recent
        ).count
    }

    private func statusColor(_ status: SessionManagementThreadStatus) -> Color {
        switch status {
        case .notLoaded: return .secondary
        case .idle, .loaded: return AppTheme.accentAmber
        case .active: return AppTheme.accentGreen
        case .systemError: return AppTheme.accentRed
        case .unknown: return .secondary
        }
    }

    private var deletionTargets: [SessionManagementThread] {
        store.checkedThreads.isEmpty
            ? store.selectedThread.map { [$0] } ?? []
            : store.checkedThreads
    }

    private var deletionTargetsCanBePackaged: Bool {
        !deletionImpact.affected.isEmpty
            && deletionBlockedAffectedThreads.isEmpty
            && deletionImpact.affected.allSatisfy {
                $0.status.permitsMutation
                    && $0.rolloutIdentityVerified
                    && $0.canDelete
            }
    }

    private var deletionImpact: SessionManagementDeletionImpact {
        pendingDeletionConfirmation?.impact ?? .empty
    }

    private var deletionBlockedAffectedThreads: [SessionManagementThread] {
        let protected = autoResumeManager.protectedThreadIDs
        return deletionImpact.affected.filter {
            !$0.status.permitsMutation
                || !$0.rolloutIdentityVerified
                || !$0.canDelete
                || protected.contains($0.id)
        }
    }

    private var deleteConfirmationTitle: String {
        "永久删除实际影响的 \(deletionImpact.affected.count) 个会话？"
    }

    private var deleteConfirmationMessage: String {
        let size = formatBytes(deletionImpact.totalBytes)
        let scope =
            "勾选 \(deletionImpact.requested.count) 个，归并为 \(deletionImpact.effectiveRoots.count) 个删除根；另含 \(deletionImpact.indirectDescendants.count) 个 spawned 后代，合计 \(size)。"
        if !deletionBlockedAffectedThreads.isEmpty {
            return "\(scope) 其中 \(deletionBlockedAffectedThreads.count) 个正在运行、加载、自动续跑或身份无法验证，本次删除已安全关闭。"
        }
        return "\(scope) 删除前会为完整影响范围逐项创建并校验恢复包；只有全部恢复材料通过复核后，才会调用 Codex 官方删除命令。"
    }

    private var deleteConfirmationOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture {
                    guard !store.isPerformingMutation else { return }
                    showingDeleteOptions = false
                    pendingDeletionConfirmation = nil
                }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(deleteConfirmationTitle)
                            .font(.system(size: 17, weight: .semibold))
                        Text(deleteConfirmationMessage)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button {
                        showingDeleteOptions = false
                        pendingDeletionConfirmation = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isPerformingMutation)
                }

                HStack(spacing: 1) {
                    impactMetric("实际影响", "\(deletionImpact.affected.count)")
                    impactMetric("间接后代", "\(deletionImpact.indirectDescendants.count)")
                    impactMetric(
                        "外部 Fork",
                        "\(deletionImpact.externalForkReferences.count)"
                    )
                    impactMetric("总大小", formatBytes(deletionImpact.totalBytes))
                }
                .background(AppTheme.border)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                DisclosureGroup("核对完整影响范围（\(deletionImpact.affected.count)）") {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(deletionImpact.affected) { thread in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(thread.displayTitle)
                                            .font(.system(size: 10, weight: .semibold))
                                            .lineLimit(1)
                                        Text(thread.id)
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Text(formatBytes(thread.fileBytes))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(AppTheme.pageBackground)
                            }
                        }
                    }
                    .frame(maxHeight: 190)
                }
                .font(.system(size: 10.5, weight: .medium))

                if !deletionBlockedAffectedThreads.isEmpty {
                    Label(
                        "\(deletionBlockedAffectedThreads.count) 个受影响会话未通过安全门禁，无法删除。",
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppTheme.accentRed)
                }

                Toggle(
                    "我已核对完整影响范围，确认理解官方删除会递归处理 spawned 后代。",
                    isOn: $deleteAcknowledged
                )
                .toggleStyle(.checkbox)
                .font(.system(size: 10.5))

                HStack {
                    Spacer()
                    Button("取消") {
                        showingDeleteOptions = false
                        pendingDeletionConfirmation = nil
                    }
                    Button("完整备份并永久删除") {
                        guard let confirmation =
                                pendingDeletionConfirmation else { return }
                        showingDeleteOptions = false
                        pendingDeletionConfirmation = nil
                        store.deleteConfirmed(confirmation: confirmation)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accentRed)
                    .disabled(
                        !deleteAcknowledged
                            || !deletionTargetsCanBePackaged
                    )
                }
            }
            .padding(16)
            .frame(width: 600)
            .background(AppTheme.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 22, y: 10)
        }
    }

    private func presentDeleteConfirmation() {
        let impact = store.deletionImpact
        guard !impact.requested.isEmpty else { return }
        Task {
            guard let confirmation =
                    await store.prepareDeletionConfirmation() else {
                return
            }
            pendingDeletionConfirmation = confirmation
            deleteAcknowledged = false
            showingDeleteOptions = true
        }
    }

    private func impactMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(AppTheme.pageBackground)
    }

    private func formatBytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(
            fromByteCount: value,
            countStyle: .file
        )
    }

    private func formatInteger(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.grouping(.automatic))
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func formatRelativeDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.relative(presentation: .numeric))
    }

    private func projectDisplayName(_ cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未记录工作目录" }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        return name.isEmpty ? trimmed : name
    }
}
