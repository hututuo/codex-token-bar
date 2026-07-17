import SwiftUI

struct AutoResumeSettingsView: View {
    @ObservedObject var controller: AutoResumeController
    @State private var threadSearchQuery = ""

    var body: some View {
        VStack(spacing: 18) {
            statusSection
            targetSection
                .disabled(controller.isRunning)
            scheduleSection
                .disabled(controller.isRunning)
            capacitySection
                .disabled(controller.isRunning)
            quotaSection
                .disabled(controller.isRunning)
            safetySection
                .disabled(controller.isRunning)
            manualSection
        }
    }

    private var statusSection: some View {
        section(
            title: "运行状态",
            subtitle: "总开关默认关闭；设置页关闭后仍由应用根生命周期守候"
        ) {
            infoRow(statusTitle, systemImage: statusSystemImage, detail: statusDetail)
            toggleRow("启用自动续跑", systemImage: "play.circle.fill", isOn: enabledBinding)
        }
    }

    private var targetSection: some View {
        section(
            title: "目标与提示词",
            subtitle: "按 Codex thread ID 精确选择；同目录任务不会被合并"
        ) {
            actionRow(
                controller.configuration.target?.displayTitle ?? "尚未选择目标任务",
                systemImage: "text.bubble",
                detail: controller.configuration.target?.cwd ?? "刷新后从全部 Codex 任务中选择",
                buttonTitle: controller.isRefreshingThreads ? "刷新中" : "刷新任务",
                buttonSystemImage: "arrow.clockwise",
                action: controller.refreshThreads
            )
            textFieldRow(
                "搜索任务",
                systemImage: "magnifyingglass",
                text: $threadSearchQuery,
                placeholder: "标题、目录或 thread ID"
            )
            pickerRow(
                "目标任务",
                systemImage: "scope",
                selection: targetBinding,
                options: threadOptions
            )
            textFieldRow(
                "续跑提示词",
                systemImage: "text.cursor",
                text: promptBinding,
                placeholder: AutoResumeConfiguration.defaultPrompt
            )
        }
    }

    private var scheduleSection: some View {
        section(
            title: "定时触发",
            subtitle: "选择按间隔运行，或每天在本机固定时间运行一次"
        ) {
            pickerRow(
                "定时方式",
                systemImage: "calendar.badge.clock",
                selection: scheduleModeBinding,
                options: AutoResumeScheduleMode.allCases.map { ($0.rawValue, $0.label) }
            )
            if controller.configuration.scheduleMode == .interval {
                pickerRow(
                    "续跑间隔",
                    systemImage: "timer",
                    selection: intervalBinding,
                    options: intervalOptions
                )
            } else if controller.configuration.scheduleMode == .daily {
                datePickerRow(
                    "每天时间",
                    systemImage: "clock",
                    selection: dailyTimeBinding
                )
            }
        }
    }

    private var quotaSection: some View {
        section(
            title: "额度恢复触发",
            subtitle: "观察当前实际可用的额度窗口；先在低位武装，再在恢复或周期变化时续跑"
        ) {
            toggleRow(
                "额度恢复时续跑",
                systemImage: "battery.100percent.bolt",
                isOn: quotaEnabledBinding
            )
            if controller.configuration.quotaRecoveryEnabled {
                pickerRow(
                    "观察额度",
                    systemImage: "chart.bar",
                    selection: quotaWindowBinding,
                    options: AutoResumeQuotaWindow.allCases.map { ($0.rawValue, $0.label) }
                )
                sliderRow(
                    "低位武装",
                    systemImage: "arrow.down.to.line",
                    value: quotaArmBinding,
                    range: 0...25,
                    display: "≤\(controller.configuration.quotaArmAtOrBelowPercent)%"
                )
                sliderRow(
                    "恢复续跑",
                    systemImage: "arrow.up.to.line",
                    value: quotaResumeBinding,
                    range: 10...100,
                    display: "≥\(controller.configuration.quotaResumeAtOrAbovePercent)%"
                )
            }
        }
    }

    private var capacitySection: some View {
        section(
            title: "中断续跑",
            subtitle: "监督所选任务的最终失败状态；每个容量中断最多发送一次“继续”"
        ) {
            toggleRow(
                "容量不足时续跑",
                systemImage: "bolt.horizontal.circle.fill",
                isOn: capacityRecoveryEnabledBinding
            )
            infoRow(
                "只认服务容量不足",
                systemImage: "checkmark.shield.fill",
                detail: "仅处理 Codex 的 serverOverloaded；额度耗尽、上下文超限、用户主动停止、审批和人工输入都不会触发。自动发送的“继续”若仍容量不足，也不会循环重试。"
            )
        }
    }

    private var safetySection: some View {
        section(
            title: "安全限制",
            subtitle: "Swift 与 Tauri 共用同一任务锁、触发记录和跨端冷却"
        ) {
            stepperRow(
                "冷却时间",
                systemImage: "snowflake",
                value: cooldownBinding,
                range: 1...1_440,
                display: "\(controller.configuration.cooldownMinutes) 分钟"
            )
            stepperRow(
                "每天最多",
                systemImage: "shield.checkered",
                value: dailyLimitBinding,
                range: 1...24,
                display: "\(controller.configuration.maxRunsPerDay) 次"
            )
            toggleRow(
                "结果通知",
                systemImage: "bell.badge",
                isOn: notifyOnResultBinding
            )
            infoRow(
                "审批一律停下",
                systemImage: "hand.raised.fill",
                detail: "遇到命令或文件审批会明确拒绝；权限、用户输入或 elicitation 请求会返回错误并中断，绝不自动批准。"
            )
        }
    }

    private var manualSection: some View {
        section(
            title: "手动验证",
            subtitle: "即使自动开关关闭，也可以在所选任务上安全发送一次提示词"
        ) {
            manualActionRow
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller.configuration.enabled },
            set: { controller.setEnabled($0) }
        )
    }

    private var targetBinding: Binding<String> {
        Binding(
            get: { controller.selectedThreadID ?? "" },
            set: { controller.selectThread(id: $0.isEmpty ? nil : $0) }
        )
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { controller.configuration.prompt },
            set: { controller.setPrompt($0) }
        )
    }

    private var scheduleModeBinding: Binding<String> {
        Binding(
            get: { controller.configuration.scheduleMode.rawValue },
            set: { controller.setScheduleMode(AutoResumeScheduleMode(rawValue: $0) ?? .off) }
        )
    }

    private var intervalBinding: Binding<String> {
        Binding(
            get: { String(controller.configuration.intervalMinutes) },
            set: { controller.setIntervalMinutes(Int($0) ?? 60) }
        )
    }

    private var dailyTimeBinding: Binding<Date> {
        Binding(
            get: {
                var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                components.hour = controller.configuration.dailyHour
                components.minute = controller.configuration.dailyMinute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { controller.setDailyTime($0) }
        )
    }

    private var quotaEnabledBinding: Binding<Bool> {
        Binding(
            get: { controller.configuration.quotaRecoveryEnabled },
            set: { controller.setQuotaRecoveryEnabled($0) }
        )
    }

    private var capacityRecoveryEnabledBinding: Binding<Bool> {
        Binding(
            get: { controller.configuration.capacityRecoveryEnabled },
            set: { controller.setCapacityRecoveryEnabled($0) }
        )
    }

    private var quotaWindowBinding: Binding<String> {
        Binding(
            get: { controller.configuration.quotaWindow.rawValue },
            set: { controller.setQuotaWindow(AutoResumeQuotaWindow(rawValue: $0) ?? .lowestRemaining) }
        )
    }

    private var quotaArmBinding: Binding<Double> {
        Binding(
            get: { Double(controller.configuration.quotaArmAtOrBelowPercent) },
            set: { controller.setQuotaArmPercent(Int($0.rounded())) }
        )
    }

    private var quotaResumeBinding: Binding<Double> {
        Binding(
            get: { Double(controller.configuration.quotaResumeAtOrAbovePercent) },
            set: { controller.setQuotaResumePercent(Int($0.rounded())) }
        )
    }

    private var cooldownBinding: Binding<Int> {
        Binding(
            get: { controller.configuration.cooldownMinutes },
            set: { controller.setCooldownMinutes($0) }
        )
    }

    private var dailyLimitBinding: Binding<Int> {
        Binding(
            get: { controller.configuration.maxRunsPerDay },
            set: { controller.setMaxRunsPerDay($0) }
        )
    }

    private var notifyOnResultBinding: Binding<Bool> {
        Binding(
            get: { controller.configuration.notifyOnResult },
            set: { controller.setNotifyOnResult($0) }
        )
    }

    private var threadOptions: [(String, String)] {
        var values: [(String, String)] = [("", "请选择目标任务")]
        let query = threadSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let threads = controller.availableThreads.filter { thread in
            query.isEmpty
                || thread.displayTitle.lowercased().contains(query)
                || thread.cwd.lowercased().contains(query)
                || thread.id.lowercased().contains(query)
        }
        values.append(contentsOf: threads.map { thread in
            let folder = URL(fileURLWithPath: thread.cwd).lastPathComponent
            return (thread.id, "\(thread.displayTitle) · \(folder) · \(String(thread.id.suffix(6)))")
        })
        if let target = controller.configuration.target,
           !values.contains(where: { $0.0 == target.id }) {
            values.append((target.id, "\(target.displayTitle) · 已保存 · \(String(target.id.suffix(6)))"))
        }
        return values
    }

    private let intervalOptions = AutoResumeConfiguration.allowedIntervalMinutes.map { minutes in
        let label = minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时"
        return (String(minutes), label)
    }

    private var statusTitle: String {
        switch controller.runtimeState.status {
        case .requiresHuman: return "需要人工处理"
        case .running: return "正在续跑"
        case .succeeded: return "最近续跑成功"
        case .failed: return "最近续跑失败"
        case .refreshingThreads: return "正在刷新任务"
        case .stopped: return "续跑已停止"
        case .idle, .waiting: return controller.configuration.enabled ? "自动续跑待命" : "自动续跑已关闭"
        }
    }

    private var statusSystemImage: String {
        switch controller.runtimeState.status {
        case .requiresHuman: return "person.crop.circle.badge.exclamationmark"
        case .running, .refreshingThreads: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .stopped: return "stop.circle"
        case .idle, .waiting: return "clock.badge.checkmark"
        }
    }

    private var statusDetail: String {
        var parts = [controller.runtimeState.statusMessage]
        parts.append(
            "本端今日 \(controller.runsToday) 次 · 跨端上限 \(controller.configuration.maxRunsPerDay) 次"
        )
        if let last = controller.runtimeState.lastRunAt {
            parts.append("最近 \(last.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private var manualActionRow: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: "play.fill")
                .foregroundStyle(AppTheme.accentBlue)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.configuration.prompt)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(2)
                Text("获取跨端任务锁后，恢复指定任务并发送带确定性消息 ID 的续跑提示词。")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if controller.isRunning {
                Button("停止") { controller.stopCurrentRun() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(AppTheme.accentAmber)
                    .accessibilityLabel("停止当前自动续跑")
            }
            Button("立即测试 / 续跑") { controller.runNow() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(controller.configuration.target == nil || controller.isRunning)
                .accessibilityHint("在所选 Codex 任务中发送一次续跑提示词")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(
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
                .background(AppTheme.solidControlBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .accessibilityValue(isOn.wrappedValue ? "已开启" : "已关闭")
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
            .frame(minWidth: 170, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
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
                .accessibilityLabel(title)
                .accessibilityValue(display)
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
                .accessibilityLabel(title)
                .accessibilityValue(display)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .autoResumeRowDivider()
    }

    private func infoRow(_ title: String, systemImage: String, detail: String) -> some View {
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
    }

    private func actionRow(
        _ title: String,
        systemImage: String,
        detail: String,
        buttonTitle: String,
        buttonSystemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.accentBlue)
                .frame(width: 18)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Button(action: action) {
                Label(buttonTitle, systemImage: buttonSystemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(AppTheme.selectedControlBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(AppTheme.accentBlue.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.accentBlue)
            .disabled(controller.isRefreshingThreads)
            .accessibilityLabel(buttonTitle)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
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
