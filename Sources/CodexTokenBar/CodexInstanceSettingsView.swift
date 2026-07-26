import AppKit
import SwiftUI

struct CodexInstanceSettingsView: View {
    private enum AddMode: String, CaseIterable, Identifiable {
        case empty
        case copyConfiguration
        case existing

        var id: String { rawValue }
        var title: String {
            switch self {
            case .empty: "空白实例"
            case .copyConfiguration: "复制配置"
            case .existing: "已有目录"
            }
        }
    }

    private struct Draft {
        var name = ""
        var sourceHome = ""
        var copyAuth = false
        var codexHome = ""
        var workingDirectory = ""
        var argumentsText = ""
        var autoSyncEnabled = false
    }

    @StateObject private var store: CodexInstanceStore
    @State private var selectedIDs = Set<String>()
    @State private var addMode: AddMode = .empty
    @State private var draft = Draft()
    @State private var editingInstance: CodexInstance?
    @State private var editDraft = Draft()
    @State private var deleteCandidate: CodexInstance?
    @State private var rollbackCandidate: CodexInstanceSyncTransactionSummary?

    init(defaultCodexHome: URL?) {
        _store = StateObject(wrappedValue: CodexInstanceStore(defaultCodexHome: defaultCodexHome))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let error = store.errorMessage {
                messageBanner(error, isError: true)
            }
            if let status = store.statusMessage {
                messageBanner(status, isError: false)
            }

            section(
                title: "实例列表",
                subtitle: "每个实例拥有独立 Codex Home 与桌面数据目录；默认实例只读，Token Bar 不会停止它"
            ) {
                if let snapshot = store.snapshot {
                    ForEach(snapshot.instances) { instance in
                        instanceRow(instance)
                        if instance.id != snapshot.instances.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                    if snapshot.instances.count == 1 {
                        Text("还没有额外实例。可以从空目录创建、复制配置，或登记已有 Codex Home。")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取 Codex 实例…")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(12)
                }
            }

            section(
                title: "添加实例",
                subtitle: "复制模式只复制配置、技能与可选登录文件，不复制正在变化的会话数据库"
            ) {
                Picker("实例来源", selection: $addMode) {
                    ForEach(AddMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(12)

                Divider()
                draftFields($draft, mode: addMode, includeSource: true)
                Divider()
                HStack {
                    Spacer()
                    Button(addMode == .existing ? "登记实例" : "创建实例") {
                        submitDraft()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(
                        store.busyAction != nil
                            || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (addMode == .existing
                                && draft.codexHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
                }
                .padding(10)
            }

            section(
                title: "会话同步",
                subtitle: "只复制缺失会话或严格前缀的较新版本；分叉会话保持原样，不会逐行拼接"
            ) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("已选择 \(selectedIDs.count) 个实例")
                            .font(.system(size: 11, weight: .semibold))
                        Text("同步前后均会重新检查所有相关实例已经停止")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button("预览") {
                        store.previewSync(instanceIDs: selectedIDs.sorted())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.busyAction != nil || selectedIDs.count < 2)

                    Button("执行同步") {
                        store.sync(instanceIDs: selectedIDs.sorted())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(
                        store.busyAction != nil
                            || store.preview?.instanceIds.sorted() != selectedIDs.sorted()
                    )
                }
                .padding(12)

                if let preview = store.preview {
                    Divider()
                    HStack(spacing: 0) {
                        previewMetric("\(preview.operations.count)", label: "安全写入")
                        Divider().frame(height: 34)
                        previewMetric("\(preview.conflicts.count)", label: "分歧保留")
                        Divider().frame(height: 34)
                        previewMetric("\(preview.unchangedThreads)", label: "已经一致")
                    }
                    .padding(.vertical, 8)
                }

                if let conflicts = store.snapshot?.conflicts, !conflicts.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("尚未处理的分歧")
                            .font(.system(size: 10.5, weight: .semibold))
                        ForEach(conflicts.prefix(6)) { conflict in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(shortID(conflict.threadId))
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .frame(width: 115, alignment: .leading)
                                Text(conflict.reason)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                }
            }

            section(
                title: "同步回滚",
                subtitle: "每次写入都有事务清单和校验备份；仅当文件仍是本次写入值时才允许回滚"
            ) {
                if store.transactions.isEmpty {
                    Text("还没有实例同步事务。")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(store.transactions.prefix(6).enumerated()), id: \.element.id) { index, transaction in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(formatTimestamp(transaction.createdAt))
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text("\(transaction.operations) 项写入 · \(transaction.conflicts) 个分歧 · \(transaction.state)")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("回滚") {
                                rollbackCandidate = transaction
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(
                                store.busyAction != nil
                                    || !["committed", "prepared", "failedNeedsRecovery"].contains(transaction.state)
                            )
                        }
                        .padding(12)
                        if index < min(store.transactions.count, 6) - 1 {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }

            if let registryPath = store.snapshot?.registryPath {
                Text("共享注册表 · \(registryPath)")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(registryPath)
            }
            Text("产品行为参考 Cockpit Tools；因其 CC BY-NC-SA 非商业许可，本功能为独立实现，未复制其源码。")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task {
            if store.snapshot == nil { store.refresh() }
        }
        .sheet(item: $editingInstance) { instance in
            editSheet(instance)
        }
        .confirmationDialog(
            deleteCandidate.map { $0.managed ? "删除托管实例？" : "取消登记外部实例？" } ?? "",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteCandidate
        ) { instance in
            Button(instance.managed ? "删除实例和托管目录" : "取消登记", role: .destructive) {
                store.delete(id: instance.id)
                deleteCandidate = nil
            }
            Button("取消", role: .cancel) { deleteCandidate = nil }
        } message: { instance in
            let rollbackCount = store.transactions.filter {
                $0.state == "committed" && $0.instanceIds.contains(instance.id)
            }.count
            let rollbackWarning = rollbackCount > 0
                ? " 此操作会使 \(rollbackCount) 个历史同步事务无法再完整回滚。"
                : ""
            Text(
                (instance.managed
                    ? "只有 Token Bar 管理的独立目录会被删除；运行中的实例不会允许删除。"
                    : "原 Codex Home 和文件不会删除。")
                    + rollbackWarning
            )
        }
        .confirmationDialog(
            "回滚实例同步？",
            isPresented: Binding(
                get: { rollbackCandidate != nil },
                set: { if !$0 { rollbackCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: rollbackCandidate
        ) { transaction in
            Button("回滚这次同步", role: .destructive) {
                store.rollback(transactionID: transaction.transactionId)
                rollbackCandidate = nil
            }
            Button("取消", role: .cancel) { rollbackCandidate = nil }
        } message: { transaction in
            Text(
                "\(formatTimestamp(transaction.createdAt)) 的事务只会恢复仍与本次写入值一致的文件。"
            )
        }
    }

    private func instanceRow(_ instance: CodexInstance) -> some View {
        let status = store.statuses[instance.id]
        let stopped = status?.running == false
        let statusLabel = status.map { $0.running ? "运行中" : "已停止" } ?? "状态未知"
        let statusIcon = status.map { $0.running ? "circle.fill" : "circle" }
            ?? "questionmark.circle"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { selectedIDs.contains(instance.id) },
                    set: { selected in
                        if selected {
                            selectedIDs.insert(instance.id)
                        } else {
                            selectedIDs.remove(instance.id)
                        }
                        store.clearPreview()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .accessibilityLabel("选择同步实例 \(instance.name)")

                VStack(alignment: .leading, spacing: 2) {
                    Text(instance.name)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(instance.isDefault ? "系统默认" : instance.managed ? "Token Bar 托管" : "外部目录")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                Label(
                    statusLabel,
                    systemImage: statusIcon
                )
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(status?.running == true ? Color.green : Color.secondary)

                if !instance.isDefault, stopped {
                    Button("启动") { store.launch(id: instance.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                }
                if status?.running == true, status?.controlled == true {
                    Button("切换") { store.focus(id: instance.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    Button("停止") { store.stop(id: instance.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                if !instance.isDefault {
                    Button("编辑") {
                        editDraft = Draft(
                            name: instance.name,
                            sourceHome: "",
                            copyAuth: false,
                            codexHome: instance.codexHome,
                            workingDirectory: instance.workingDirectory ?? "",
                            argumentsText: instance.arguments.joined(separator: "\n"),
                            autoSyncEnabled: instance.autoSyncEnabled
                        )
                        editingInstance = instance
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(!stopped)

                    Button(instance.managed ? "删除" : "取消登记", role: .destructive) {
                        deleteCandidate = instance
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(!stopped)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Home · \(instance.codexHome)")
                if !instance.electronDataDirectory.isEmpty {
                    Text("桌面数据 · \(instance.electronDataDirectory)")
                }
                Text(status?.message ?? "正在检查运行状态…")
                if instance.autoSyncEnabled {
                    Label("与默认实例在全部停止后自动同步", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(AppTheme.accentBlue)
                }
            }
            .font(.system(size: 8.7, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.leading, 26)
        }
        .padding(12)
        .disabled(store.busyAction != nil)
    }

    private func editSheet(_ instance: CodexInstance) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("编辑 Codex 实例").font(.system(size: 16, weight: .semibold))
                    Text(instance.codexHome)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("关闭") { editingInstance = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(16)
            Divider()
            draftFields($editDraft, mode: nil, includeSource: false)
            Divider()
            HStack {
                Spacer()
                Button("取消") { editingInstance = nil }
                    .buttonStyle(.bordered)
                Button("保存") {
                    store.update(CodexInstanceUpdateRequest(
                        id: instance.id,
                        name: editDraft.name,
                        workingDirectory: nullable(editDraft.workingDirectory),
                        arguments: parseArguments(editDraft.argumentsText),
                        autoSyncEnabled: editDraft.autoSyncEnabled
                    )) {
                        editingInstance = nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    store.busyAction != nil
                        || editDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(12)
        }
        .frame(width: 560)
        .background(AppTheme.panelBackground)
    }

    @ViewBuilder
    private func draftFields(
        _ draft: Binding<Draft>,
        mode: AddMode?,
        includeSource: Bool
    ) -> some View {
        VStack(spacing: 0) {
            fieldRow("实例名称", placeholder: "例如：工作账号", text: draft.name)
            if includeSource, mode == .copyConfiguration {
                Divider().padding(.leading, 12)
                pathRow(
                    "源 Codex Home",
                    placeholder: "留空使用当前默认目录",
                    text: draft.sourceHome
                )
                Divider().padding(.leading, 12)
                toggleRow(
                    "同时复制 auth.json",
                    detail: "会把登录凭据带入新实例",
                    isOn: draft.copyAuth
                )
            }
            if includeSource, mode == .existing {
                Divider().padding(.leading, 12)
                pathRow(
                    "已有 Codex Home",
                    placeholder: "/Users/you/.codex-work",
                    text: draft.codexHome
                )
            }
            Divider().padding(.leading, 12)
            pathRow(
                "工作目录",
                placeholder: "可选；作为启动环境传给 Codex",
                text: draft.workingDirectory
            )
            Divider().padding(.leading, 12)
            HStack(alignment: .top, spacing: 10) {
                Text("额外参数")
                    .font(.system(size: 10.5, weight: .medium))
                    .frame(width: 92, alignment: .leading)
                TextEditor(text: draft.argumentsText)
                    .font(.system(size: 10, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 54)
                    .padding(5)
                    .background(AppTheme.solidControlBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(AppTheme.border, lineWidth: 1)
                    )
                Text("每行一个，不经过 shell")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider().padding(.leading, 12)
            toggleRow(
                "自动安全同步",
                detail: "与默认实例及其他已开启实例在全部停止后同步",
                isOn: draft.autoSyncEnabled
            )
        }
    }

    private func fieldRow(
        _ title: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 92, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10.5))
        }
        .padding(12)
    }

    private func pathRow(
        _ title: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 92, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10.5))
            Button("选择") {
                if let selected = chooseDirectory() { text.wrappedValue = selected.path }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
    }

    private func toggleRow(
        _ title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 8.7, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(12)
    }

    private func section<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) { content() }
                .background(
                    AppTheme.solidControlBackground,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func messageBanner(_ text: String, isError: Bool) -> some View {
        Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isError ? Color.red : AppTheme.accentBlue)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (isError ? Color.red : AppTheme.accentBlue).opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }

    private func previewMetric(_ value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 14, weight: .semibold))
            Text(label)
                .font(.system(size: 8.8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func submitDraft() {
        if addMode == .existing {
            store.importExisting(CodexInstanceImportRequest(
                name: draft.name,
                codexHome: draft.codexHome,
                workingDirectory: nullable(draft.workingDirectory),
                arguments: parseArguments(draft.argumentsText),
                autoSyncEnabled: draft.autoSyncEnabled
            )) {
                draft = Draft()
            }
        } else {
            store.create(CodexInstanceCreateRequest(
                name: draft.name,
                mode: addMode == .copyConfiguration ? .copyConfiguration : .empty,
                sourceHome: nullable(draft.sourceHome),
                copyAuth: draft.copyAuth,
                workingDirectory: nullable(draft.workingDirectory),
                arguments: parseArguments(draft.argumentsText),
                autoSyncEnabled: draft.autoSyncEnabled
            )) {
                draft = Draft()
            }
        }
    }

    private func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func parseArguments(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func nullable(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func shortID(_ value: String) -> String {
        value.count > 18 ? "\(value.prefix(8))…\(value.suffix(6))" : value
    }

    private func formatTimestamp(_ milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }
}
