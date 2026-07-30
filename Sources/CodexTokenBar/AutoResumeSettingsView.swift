import SwiftUI

struct AutoResumeSettingsView: View {
    @ObservedObject var controller: AutoResumeTaskManager
    @State private var threadSearchQuery = ""
    @State private var selectedProjectID = ""
    @State private var composerThreadID = ""
    @State private var visibleThreadLimit = AutoResumeThreadPicker.visibleThreadPageSize
    @State private var expandedTaskID: String?
    @State private var pendingDeleteTaskID: String?
    @State private var localMessage: String?
    private let menuPickerWidth: CGFloat = 240

    var body: some View {
        VStack(spacing: 18) {
            safetyBanner
            creationSection
            taskListSection
        }
        .onAppear {
            synchronizeSelectedProject()
            if controller.availableThreads.isEmpty {
                controller.refreshThreads()
            }
        }
        .onChange(of: controller.availableThreads) {
            synchronizeSelectedProject()
        }
        .onChange(of: threadSearchQuery) {
            visibleThreadLimit = AutoResumeThreadPicker.visibleThreadPageSize
        }
        .confirmationDialog(
            "删除这条监控任务？",
            isPresented: Binding(
                get: { pendingDeleteTaskID != nil },
                set: { if !$0 { pendingDeleteTaskID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除任务", role: .destructive) {
                guard let id = pendingDeleteTaskID else { return }
                if controller.deleteTask(id: id) {
                    if expandedTaskID == id { expandedTaskID = nil }
                    localMessage = "监控任务已删除"
                } else {
                    localMessage = "任务正在续跑，请先停止后再删除"
                }
                pendingDeleteTaskID = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteTaskID = nil
            }
        } message: {
            Text("只会删除 Token Bar 中的监控配置，不会删除 Codex 会话。")
        }
    }

    private var safetyBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(AppTheme.accentBlue)
                .font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text("一条任务，保护一个 Codex 会话")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("每条任务独立设置触发条件；应用内串行执行，并与跨平台版共用会话锁和触发记录。只有显式开启“自动批准”时，当前 turn 的普通命令与文件变更才会逐条放行；破坏性操作、额外权限、人工输入和未知请求仍会拦截。“任务被中断”可能包含主动停止，只有勾选后才会续跑。")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(12)
        .background(AppTheme.selectedControlBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.accentBlue.opacity(0.2), lineWidth: 1)
        )
    }

    private var creationSection: some View {
        settingsSection(
            title: "创建监控任务",
            subtitle: "先选项目和会话；创建后默认暂停，再按需要开启保护条件"
        ) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "text.bubble.fill")
                    .foregroundStyle(AppTheme.accentBlue)
                    .frame(width: 18)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedComposerThread?.displayTitle ?? "尚未选择会话")
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(2)
                    Text(selectedComposerThread?.cwd ?? "读取本机 Codex 会话后即可创建监控任务")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Button {
                    controller.refreshThreads()
                } label: {
                    Label(
                        controller.isRefreshingThreads ? "刷新中" : "刷新会话",
                        systemImage: "arrow.clockwise"
                    )
                    .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(controller.isRefreshingThreads)
            }
            .padding(12)
            .autoResumeRowDivider()

            projectPickerRow
            threadSearchRow
            threadHistoryList

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(composerStatusTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(composerStatusDetail)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("创建任务") {
                    createSelectedTask()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(selectedComposerThread == nil)
                .accessibilityHint("创建后默认暂停，不会立即续跑")
            }
            .padding(12)
        }
    }

    private var taskListSection: some View {
        settingsSection(
            title: "监控任务",
            subtitle: "\(controller.tasks.filter { $0.configuration.enabled }.count) 条保护中 · \(controller.tasks.count) 条任务"
        ) {
            if controller.tasks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text("还没有监控任务")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("在上方选择一个 Codex 会话并创建；任务默认暂停，配置确认后再开启。")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(controller.tasks) { task in
                    taskCard(task)
                    if task.id != controller.tasks.last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            if let message = localMessage ?? controller.catalogError {
                Text(message)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(message.contains("失败") ? AppTheme.accentRed : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func taskCard(_ task: AutoResumeManagedTask) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    toggleTaskDisclosure(task)
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        Circle()
                            .fill(taskStatusColor(task))
                            .frame(width: 8, height: 8)
                            .shadow(color: taskStatusColor(task).opacity(0.28), radius: 3)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text(task.configuration.target?.displayTitle ?? "目标会话不可用")
                                    .font(.system(size: 11.8, weight: .semibold))
                                    .lineLimit(1)
                                statusPill(taskStatusTitle(task), color: taskStatusColor(task))
                            }
                            HStack(spacing: 5) {
                                ForEach(triggerLabels(task.configuration), id: \.self) { label in
                                    Text(label)
                                        .font(.system(size: 8.5, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .frame(height: 18)
                                        .background(AppTheme.panelBackgroundAlt, in: Capsule())
                                }
                                Text("ID \(String(task.configuration.target?.id.suffix(6) ?? ""))")
                                    .font(.system(size: 8.5, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .monospaced()
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: expandedTaskID == task.id ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 24)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityLabel(
                    "\(task.configuration.target?.displayTitle ?? "监控任务")，"
                        + (expandedTaskID == task.id ? "收起设置" : "展开设置")
                )
                Spacer(minLength: 10)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { task.configuration.enabled },
                        set: { enabled in
                            if enabled && !task.configuration.hasAutomaticTrigger {
                                localMessage = "请先为任务开启至少一个自动触发条件"
                                expandedTaskID = task.id
                                return
                            }
                            task.controller.setEnabled(enabled)
                            localMessage = enabled ? "任务已进入保护状态" : "任务已暂停"
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(task.isRunning)
                .accessibilityLabel("\(task.configuration.target?.displayTitle ?? "监控任务")保护开关")
            }
            .padding(12)

            if expandedTaskID == task.id {
                Divider().padding(.leading, 12)
                taskEditor(task)
            }
        }
        .background(
            task.configuration.enabled
                ? AppTheme.selectedControlBackground.opacity(0.36)
                : Color.clear
        )
    }

    private func taskEditor(_ task: AutoResumeManagedTask) -> some View {
        let taskController = task.controller
        let configuration = task.configuration
        let invisibleResumeEnabled = configuration.invisibleResumeEnabled
            ?? (configuration.prompt == AutoResumeConfiguration.defaultPrompt)
        return VStack(spacing: 0) {
            taskInfoRow(
                "当前状态",
                systemImage: "waveform.path.ecg",
                detail: task.runtimeState.statusMessage
            )
            Group {
                editorGroup(
                    title: "定时续跑",
                    subtitle: "按间隔或每天固定时间启动同一会话的下一轮",
                    systemImage: "calendar.badge.clock"
                ) {
                    pickerRow(
                        "定时方式",
                        systemImage: "calendar.badge.clock",
                        selection: Binding(
                            get: { configuration.scheduleMode.rawValue },
                            set: {
                                taskController.setScheduleMode(
                                    AutoResumeScheduleMode(rawValue: $0) ?? .off
                                )
                            }
                        ),
                        options: AutoResumeScheduleMode.allCases.map { ($0.rawValue, $0.label) }
                    )
                    if configuration.scheduleMode == .interval {
                        pickerRow(
                            "续跑间隔",
                            systemImage: "timer",
                            selection: Binding(
                                get: { String(configuration.intervalMinutes) },
                                set: { taskController.setIntervalMinutes(Int($0) ?? 60) }
                            ),
                            options: intervalOptions
                        )
                    } else if configuration.scheduleMode == .daily {
                        datePickerRow(
                            "每天时间",
                            systemImage: "clock",
                            selection: Binding(
                                get: {
                                    var components = Calendar.current.dateComponents(
                                        [.year, .month, .day],
                                        from: Date()
                                    )
                                    components.hour = configuration.dailyHour
                                    components.minute = configuration.dailyMinute
                                    return Calendar.current.date(from: components) ?? Date()
                                },
                                set: { taskController.setDailyTime($0) }
                            )
                        )
                    }
                }

                editorGroup(
                    title: "额度恢复续跑",
                    subtitle: "先观察额度降到低位，刷新恢复后再续跑",
                    systemImage: "gauge.with.dots.needle.33percent"
                ) {
                    checkboxRow(
                        "开启额度恢复续跑",
                        detail: "对应 Codex 的 usageLimitExceeded；只有勾选后才显示额度选项",
                        isOn: Binding(
                            get: { configuration.quotaRecoveryEnabled },
                            set: { taskController.setQuotaRecoveryEnabled($0) }
                        )
                    )
                    if configuration.quotaRecoveryEnabled {
                        pickerRow(
                            "观察额度",
                            systemImage: "chart.bar",
                            selection: Binding(
                                get: { configuration.quotaWindow.rawValue },
                                set: {
                                    taskController.setQuotaWindow(
                                        AutoResumeQuotaWindow(rawValue: $0) ?? .lowestRemaining
                                    )
                                }
                            ),
                            options: AutoResumeQuotaWindow.allCases.map { ($0.rawValue, $0.label) }
                        )
                        taskInfoRow(
                            "为什么需要两个数值",
                            systemImage: "arrow.down.and.line.horizontal.and.arrow.up",
                            detail: "额度先降到“开始等待刷新”值或以下，才记录本轮耗尽；之后恢复到“刷新后续跑”值或以上时续跑，避免在额度本来充足时误触发。"
                        )
                        sliderRow(
                            "开始等待刷新",
                            systemImage: "arrow.down.to.line",
                            value: Binding(
                                get: { Double(configuration.quotaArmAtOrBelowPercent) },
                                set: { taskController.setQuotaArmPercent(Int($0.rounded())) }
                            ),
                            range: 0...25,
                            display: "≤\(configuration.quotaArmAtOrBelowPercent)%"
                        )
                        sliderRow(
                            "刷新后续跑",
                            systemImage: "arrow.up.to.line",
                            value: Binding(
                                get: { Double(configuration.quotaResumeAtOrAbovePercent) },
                                set: { taskController.setQuotaResumePercent(Int($0.rounded())) }
                            ),
                            range: 10...100,
                            display: "≥\(configuration.quotaResumeAtOrAbovePercent)%"
                        )
                    }
                }

                editorGroup(
                    title: "失败 / 中断续跑",
                    subtitle: "仅按 Codex app-server 的结构化终态和错误码逐项匹配",
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                ) {
                    failureReasonSelector(
                        configuration: configuration,
                        controller: taskController
                    )
                }

                editorGroup(
                    title: "续跑方式",
                    subtitle: "选择无痕空输入，或发送一条可见提示词",
                    systemImage: "text.bubble"
                ) {
                    checkboxRow(
                        "无痕续跑",
                        detail: "通过 Codex app-server 的 turn/start + input: [] 启动同一 thread 的下一轮；旧版不接受空输入时才回退发送可见的“继续”",
                        isOn: Binding(
                            get: { invisibleResumeEnabled },
                            set: { taskController.setInvisibleResumeEnabled($0) }
                        )
                    )
                    textFieldRow(
                        "续跑提示词",
                        systemImage: "text.cursor",
                        text: Binding(
                            get: { configuration.prompt },
                            set: { taskController.setPrompt($0) }
                        ),
                        placeholder: AutoResumeConfiguration.defaultPrompt
                    )
                    .disabled(invisibleResumeEnabled)
                    .opacity(invisibleResumeEnabled ? 0.42 : 1)
                }

                editorGroup(
                    title: "自动批准",
                    subtitle: "只处理当前会话当前 turn 的结构化批准请求",
                    systemImage: "checkmark.shield"
                ) {
                    checkboxRow(
                        "自动批准普通操作",
                        detail: "逐条放行普通命令与文件变更；rm -rf、磁盘擦除、破坏性 Git / 数据库命令、额外权限扩张和无法解析的请求仍会拦截并停止本轮。",
                        isOn: Binding(
                            get: { configuration.autoApprovalEnabled },
                            set: { taskController.setAutoApprovalEnabled($0) }
                        )
                    )
                }

                editorGroup(
                    title: "保护限制",
                    subtitle: "限制自动执行频率，并决定是否通知结果",
                    systemImage: "shield.checkered"
                ) {
                    stepperRow(
                        "冷却时间",
                        systemImage: "snowflake",
                        value: Binding(
                            get: { configuration.cooldownMinutes },
                            set: { taskController.setCooldownMinutes($0) }
                        ),
                        range: 1...1_440,
                        display: "\(configuration.cooldownMinutes) 分钟"
                    )
                    stepperRow(
                        "每天最多",
                        systemImage: "shield.checkered",
                        value: Binding(
                            get: { configuration.maxRunsPerDay },
                            set: { taskController.setMaxRunsPerDay($0) }
                        ),
                        range: 1...24,
                        display: "\(configuration.maxRunsPerDay) 次"
                    )
                    toggleRow(
                        "结果通知",
                        systemImage: "bell.badge",
                        isOn: Binding(
                            get: { configuration.notifyOnResult },
                            set: { taskController.setNotifyOnResult($0) }
                        )
                    )
                }
            }
            .disabled(task.isRunning)
            HStack(spacing: 8) {
                Button("删除任务", role: .destructive) {
                    pendingDeleteTaskID = task.id
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(task.isRunning)
                Spacer()
                if task.isRunning {
                    Button("停止本次续跑") {
                        taskController.stopCurrentRun()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(AppTheme.accentAmber)
                }
                Button(task.isRunning ? "正在续跑" : "立即测试 / 续跑") {
                    taskController.runNow()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(task.isRunning)
            }
            .padding(12)
        }
    }

    private func failureReasonSelector(
        configuration: AutoResumeConfiguration,
        controller: AutoResumeController
    ) -> some View {
        let selected = configuration.selectedFailureReasons
        let allSelected = selected.count == AutoResumeFailureReason.allCases.count
        let hasRiskySelection = selected.contains(where: \.isRisky)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("选择失败原因")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("逐项匹配 Codex app-server 终态/错误码；未勾选的原因不会自动重试。")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(allSelected ? "清空" : "全选") {
                    controller.setAllFailureRecoveryReasons(!allSelected)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 7),
                    GridItem(.flexible(), spacing: 7),
                ],
                spacing: 7
            ) {
                ForEach(AutoResumeFailureReason.allCases, id: \.self) { reason in
                    failureReasonButton(
                        reason.label,
                        protocolCode: reason.rawValue,
                        selected: selected.contains(reason)
                    ) {
                        controller.setFailureRecoveryReason(
                            reason,
                            enabled: !selected.contains(reason)
                        )
                    }
                }
            }

            Text(
                hasRiskySelection
                    ? "谨慎条件可能包含主动停止或必须人工修复的问题；仍只按 Codex 的结构化状态判断。"
                    : "不按报错文案猜测；自动续跑产生的后续轮也不会再次触发失败续跑。"
            )
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(hasRiskySelection ? AppTheme.accentAmber : .secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failureReasonButton(
        _ title: String,
        protocolCode: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AppTheme.accentBlue : .secondary)
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(
                selected
                    ? AppTheme.selectedControlBackground.opacity(0.7)
                    : AppTheme.solidControlBackground,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(selected ? AppTheme.accentBlue.opacity(0.35) : AppTheme.border)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "已选择" : "未选择")
        .help("\(title) · \(protocolCode)")
    }

    private var projectPickerRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder.fill").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text("项目文件夹").font(.system(size: 11.5, weight: .medium))
                Text(selectedProject?.cwd ?? "刷新后选择项目文件夹")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 10)
            Picker("", selection: $selectedProjectID) {
                ForEach(projectOptions, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: menuPickerWidth, alignment: .trailing)
            .clipped()
            .disabled(projectDescriptors.isEmpty)
            .onChange(of: selectedProjectID) {
                threadSearchQuery = ""
                composerThreadID = ""
                visibleThreadLimit = AutoResumeThreadPicker.visibleThreadPageSize
            }
            .accessibilityLabel("自动续跑项目文件夹")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .autoResumeRowDivider()
    }

    private var threadSearchRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: 16)
            Text("搜索会话").font(.system(size: 11.5, weight: .medium))
            Spacer(minLength: 10)
            TextField("当前项目的标题或 thread ID", text: $threadSearchQuery)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit { controller.refreshThreads() }
                .frame(minWidth: 250)
                .accessibilityLabel("搜索自动续跑会话")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .autoResumeRowDivider()
    }

    private var threadHistoryList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(
                    selectedProject == nil
                        ? "请先选择项目"
                        : "当前显示 \(visibleThreads.count) / \(matchingThreads.count) 条"
                )
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if hasMoreThreads {
                    Text("向下滚动自动加载更多")
                        .font(.system(size: 8.8, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .autoResumeRowDivider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    if visibleThreads.isEmpty {
                        Text(
                            controller.isRefreshingThreads
                                ? "正在读取本机会话…"
                                : "当前项目没有匹配的会话"
                        )
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                    } else {
                        ForEach(visibleThreads) { thread in
                            Button {
                                composerThreadID = thread.id
                            } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(
                                        systemName: composerThreadID == thread.id
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    .foregroundStyle(
                                        composerThreadID == thread.id
                                            ? AppTheme.accentBlue
                                            : .secondary
                                    )
                                    .padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(thread.displayTitle)
                                            .font(.system(size: 10.8, weight: .semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Text(threadHistoryDetail(thread))
                                            .font(.system(size: 8.5, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .monospacedDigit()
                                    }
                                    Spacer(minLength: 8)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    composerThreadID == thread.id
                                        ? AppTheme.selectedControlBackground.opacity(0.7)
                                        : Color.clear
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(thread.displayTitle)，\(threadHistoryDetail(thread))")
                            .autoResumeRowDivider()
                        }
                        if hasMoreThreads {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text("继续下滑，加载后续会话")
                                    .font(.system(size: 8.8, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .onAppear {
                                revealMoreThreadsIfNeeded()
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 228)
        }
        .autoResumeRowDivider()
    }

    private var projectDescriptors: [AutoResumeProjectDescriptor] {
        AutoResumeThreadPicker.projects(from: controller.availableThreads)
    }

    private var selectedProject: AutoResumeProjectDescriptor? {
        projectDescriptors.first { $0.id == selectedProjectID }
    }

    private var visibleThreads: [AutoResumeThreadDescriptor] {
        AutoResumeThreadPicker.visibleThreads(
            from: controller.availableThreads,
            projectID: selectedProjectID,
            query: threadSearchQuery,
            selectedThreadID: composerThreadID,
            limit: visibleThreadLimit
        )
    }

    private var matchingThreads: [AutoResumeThreadDescriptor] {
        AutoResumeThreadPicker.matchingThreads(
            from: controller.availableThreads,
            projectID: selectedProjectID,
            query: threadSearchQuery
        )
    }

    private var hasMoreThreads: Bool {
        visibleThreadLimit < matchingThreads.count
    }

    private var selectedComposerThread: AutoResumeThreadDescriptor? {
        controller.availableThreads.first { $0.id == composerThreadID }
    }

    private var projectOptions: [(String, String)] {
        guard !projectDescriptors.isEmpty else { return [("", "暂无可选项目")] }
        return projectDescriptors.map { ($0.id, "\($0.displayName) · \($0.threadCount) 个会话") }
    }

    private var composerStatusTitle: String {
        guard let selectedComposerThread else { return "选择会话后创建" }
        if controller.tasks.contains(where: { $0.configuration.target?.id == selectedComposerThread.id }) {
            return "这个会话已经在任务列表中"
        }
        return "将创建为暂停状态"
    }

    private var composerStatusDetail: String {
        guard selectedComposerThread != nil else {
            return "创建任务本身不会发送任何内容；开启保护后才会按条件自动续跑。"
        }
        if composerStatusTitle.contains("已经") {
            return "点击“创建任务”会直接定位到已有任务，不会重复监控同一个会话。"
        }
        return "默认开启额度恢复条件，但保护开关保持关闭；可以逐项选择失败原因、定时和安全限制。"
    }

    private func createSelectedTask() {
        guard let target = selectedComposerThread else { return }
        let result = controller.createTask(target: target)
        switch result {
        case .created(let id):
            expandedTaskID = id
            localMessage = "任务已创建，确认条件后再开启保护"
        case .existing(let id):
            expandedTaskID = id
            localMessage = "已定位到这个会话的监控任务"
        }
    }

    private func revealMoreThreadsIfNeeded() {
        guard hasMoreThreads else { return }
        visibleThreadLimit = min(
            visibleThreadLimit + AutoResumeThreadPicker.visibleThreadPageSize,
            matchingThreads.count
        )
    }

    private func threadHistoryDetail(_ thread: AutoResumeThreadDescriptor) -> String {
        let updated = thread.updatedAt?.formatted(
            date: .numeric,
            time: .shortened
        ) ?? "时间未知"
        return "\(updated) · ID \(String(thread.id.suffix(8)))"
    }

    private func toggleTaskDisclosure(_ task: AutoResumeManagedTask) {
        expandedTaskID = expandedTaskID == task.id ? nil : task.id
        controller.selectTask(id: task.id)
        localMessage = nil
    }

    private func synchronizeSelectedProject() {
        let resolved = AutoResumeThreadPicker.resolvedProjectID(
            projects: projectDescriptors,
            currentID: selectedProjectID,
            preferredCWD: selectedComposerThread?.cwd ?? ""
        )
        if resolved != selectedProjectID {
            selectedProjectID = resolved
        }
    }

    private func triggerLabels(_ configuration: AutoResumeConfiguration) -> [String] {
        var labels: [String] = []
        if !configuration.failureRecoveryReasons.isEmpty {
            labels.append("失败 \(configuration.failureRecoveryReasons.count)项")
        }
        if configuration.scheduleMode != .off { labels.append("定时") }
        if configuration.quotaRecoveryEnabled { labels.append("额度恢复") }
        return labels.isEmpty ? ["未设触发"] : labels
    }

    private func taskStatusTitle(_ task: AutoResumeManagedTask) -> String {
        if task.isRunning { return "正在续跑" }
        switch task.runtimeState.status {
        case .requiresHuman: return "需人工处理"
        case .failed: return "检查失败"
        case .succeeded: return task.configuration.enabled ? "保护中" : "已暂停"
        default: return task.configuration.enabled ? "保护中" : "已暂停"
        }
    }

    private func taskStatusColor(_ task: AutoResumeManagedTask) -> Color {
        if task.isRunning { return AppTheme.accentBlue }
        switch task.runtimeState.status {
        case .requiresHuman, .failed: return AppTheme.accentRed
        default: return task.configuration.enabled ? .green : .secondary
        }
    }

    private func statusPill(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 19)
            .background(color.opacity(0.1), in: Capsule())
    }

    private let intervalOptions = AutoResumeConfiguration.allowedIntervalMinutes.map { minutes in
        let label = minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时"
        return (String(minutes), label)
    }

    private func settingsSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
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
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func editorGroup<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: systemImage)
                    .foregroundStyle(AppTheme.accentBlue)
                    .frame(width: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11.8, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 9.2, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .padding(12)
            .autoResumeRowDivider()
            VStack(spacing: 0) { content() }
        }
        .background(
            AppTheme.panelBackgroundAlt.opacity(0.32),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.border.opacity(0.8), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func checkboxRow(
        _ title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11.2, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9.1, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .autoResumeRowDivider()
    }

    private func toggleRow(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.system(size: 11.5, weight: .medium))
            Spacer(minLength: 10)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .autoResumeRowDivider()
    }

    private func pickerRow(
        _ title: String,
        systemImage: String,
        selection: Binding<String>,
        options: [(String, String)]
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.system(size: 11.5, weight: .medium))
            Spacer(minLength: 10)
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { value, label in Text(label).tag(value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: menuPickerWidth, alignment: .trailing)
            .clipped()
            .accessibilityLabel(title)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .autoResumeRowDivider()
    }

    private func textFieldRow(
        _ title: String,
        systemImage: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.system(size: 11.5, weight: .medium))
            Spacer(minLength: 10)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .autoResumeRowDivider()
    }

    private func datePickerRow(
        _ title: String,
        systemImage: String,
        selection: Binding<Date>
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.system(size: 11.5, weight: .medium))
            Spacer(minLength: 10)
            DatePicker("", selection: selection, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.field)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .autoResumeRowDivider()
    }

    private func sliderRow(
        _ title: String,
        systemImage: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.system(size: 11.5, weight: .medium)).frame(width: 88, alignment: .leading)
            Slider(value: value, in: range, step: 1)
            Text(display)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 58, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .autoResumeRowDivider()
    }

    private func stepperRow(
        _ title: String,
        systemImage: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        display: String
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.system(size: 11.5, weight: .medium))
            Spacer(minLength: 10)
            Text(display)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Stepper("", value: value, in: range)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .autoResumeRowDivider()
    }

    private func taskInfoRow(_ title: String, systemImage: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.accentBlue)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .autoResumeRowDivider()
    }
}

private extension View {
    func autoResumeRowDivider() -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.border.opacity(0.55))
                .frame(height: 1)
                .padding(.leading, 38)
        }
    }
}
