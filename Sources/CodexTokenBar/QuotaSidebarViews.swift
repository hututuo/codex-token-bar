import SwiftUI

private enum SidebarPalette {
    static let green = Color(red: 182.0 / 255, green: 239.0 / 255, blue: 117.0 / 255)
    static let purple = Color(red: 180.0 / 255, green: 172.0 / 255, blue: 1)
    static let amber = Color(red: 239.0 / 255, green: 192.0 / 255, blue: 119.0 / 255)
    static let blue = Color(red: 120.0 / 255, green: 183.0 / 255, blue: 1)
    static let background = Color(red: 0.035, green: 0.045, blue: 0.038)
}

// Value interpolation belongs to SwiftUI, not a timer per meter. Scaling a
// fixed track leaves surrounding layout unchanged throughout the transition.
private struct SidebarValueBar: View {
    let fraction: Double?
    let color: Color
    var vertical = false
    var emphasis = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var amount: Double { min(1, max(0, fraction ?? 0)) }
    var body: some View {
        ZStack {
            Capsule().fill(.white.opacity(0.12))
            Capsule().fill(color.opacity(emphasis))
                .scaleEffect(x: vertical ? 1 : amount, y: vertical ? amount : 1,
                             anchor: vertical ? .bottom : .leading)
                .opacity(fraction == nil ? 0 : 1)
        }
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.34), value: fraction)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: emphasis)
    }
}

private struct SidebarValueRing: View {
    let fraction: Double?
    let color: Color
    var emphasis = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 3)
            Circle().trim(from: 0, to: min(1, max(0, fraction ?? 0)))
                .stroke(color.opacity(emphasis), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90)).opacity(fraction == nil ? 0 : 1)
        }
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.34), value: fraction)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: emphasis)
    }
}

struct QuotaSidebarRail: View {
    @ObservedObject var controller: QuotaSidebarController
    @ObservedObject var quota: AccountQuotaStore
    @ObservedObject var tasks: TaskCompletionMonitor
    @ObservedObject var radar: CodexRadarStore
    @ObservedObject var monitor: LiveRateMonitor
    @AppStorage(TokenRateScaleSettings.key) private var fullScale = TokenRateScaleSettings.defaultValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: controller.edge == .right ? .trailing : .leading) {
            if controller.interaction.expanded {
                VStack(spacing: 8) {
                    Text("速览").font(.system(size: 10)).foregroundStyle(.gray)
                        .help("拖动侧栏调整位置，松手吸附边缘")
                    rateRing
                    if let fiveHour = quota.snapshot.fiveHour {
                        ring(label: "5h", window: fiveHour, color: SidebarPalette.green)
                    }
                    ring(label: "7d", window: quota.snapshot.sevenDay, color: SidebarPalette.purple)
                    Rectangle().fill(.white.opacity(0.13)).frame(width: 30, height: 1)
                    Button { controller.select(.tasks) } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                Circle().stroke(SidebarPalette.amber.opacity(0.5), lineWidth: 3)
                                Text(tasks.runningThreadSummary.freshness == .fresh ? "\(tasks.runningThreadSummary.total)" : "—").font(.system(size: 18, weight: .medium, design: .rounded)).foregroundStyle(SidebarPalette.amber)
                            }.frame(width: 46, height: 46)
                            Text(runningText).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                                .contentTransition(.numericText())
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: runningText)
                        }
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("查看任务，\(runningText)")
                        .accessibilityIdentifier("quota-sidebar-tasks")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { controller.select(.tasks) }
                    Button { controller.select(.radar) } label: {
                        VStack(spacing: 4) {
                            Text("众测推荐").foregroundStyle(.gray)
                            ForEach(Array(QuotaSidebarRadarPresentation.rankedModels(radar.crowdSnapshot).prefix(3))) { model in
                                Text(CodexRadarPresentationText.compactModelName(model.model) + " " + model.effort)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                            if radar.crowdStaleDataDisplayed { Text("旧数据").foregroundStyle(.orange) }
                        }.font(.system(size: 9)).frame(maxWidth: .infinity).padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Rectangle().fill(.white.opacity(0.13)).frame(width: 52, height: 1)
                    TimelineView(CodexRadarCountdownTimelineSchedule(deadline: CodexRadarPresentationText.countdownDeadline(snapshot: radar.snapshot))) { tick in
                        let active = QuotaSidebarRadarPresentation.isActiveWindow(radar.snapshot, stale: radar.staleDataDisplayed, updatedAt: radar.lastSuccessfulRefreshAt, now: tick.date)
                        Button { controller.select(.radar) } label: {
                            VStack(spacing: 4) {
                                Text(active ? "速登窗口" : "等待")
                                if active, let end = CodexRadarPresentationText.countdownDeadline(snapshot: radar.snapshot), end > tick.date {
                                    Text(CodexRadarPresentationText.actionDisplay(snapshot: radar.snapshot, now: tick.date).replacingOccurrences(of: "速登 ", with: ""))
                                        .monospacedDigit()
                                }
                            }.font(.system(size: 10)).foregroundStyle(active ? .red : .gray)
                                .frame(maxWidth: .infinity).contentShape(Rectangle().inset(by: -10))
                        }.buttonStyle(.plain)
                    }
                }.frame(width: 88).fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
            }
            Group {
                VStack(spacing: 12) {
                    SidebarValueBar(fraction: Double(rateFraction), color: SidebarPalette.blue, vertical: true)
                        .frame(width: 4, height: 46)
                        .help("全会话实时速率（估算）\(rateText)")
                    if let fiveHour = quota.snapshot.fiveHour {
                        bar(window: fiveHour, color: SidebarPalette.green)
                    }
                    bar(window: quota.snapshot.sevenDay, color: SidebarPalette.purple)
                }.frame(width: 16).frame(maxHeight: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("额度侧栏，实时速率\(rateText)，悬停展开简略信息，可拖动调整位置")
                    .contentShape(Rectangle())
                    .onTapGesture { controller.enter() }
            }
            .opacity(controller.interaction.expanded ? 0 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.interaction.expanded)
            .allowsHitTesting(!controller.interaction.expanded)
            .accessibilityHidden(controller.interaction.expanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: controller.edge == .right ? .trailing : .leading)
        .background(SidebarPalette.background)
        .clipShape(QuotaSidebarEdgeShape(edge: controller.edge))
        .foregroundStyle(.white)
        .onHover { if $0 { controller.enter() } }
    }

    private var rateRing: some View {
        Button { controller.select(.overview) } label: {
            VStack(spacing: 5) {
                ZStack {
                    SidebarValueRing(fraction: Double(rateFraction), color: SidebarPalette.blue)
                    Text("速率").font(.system(size: 11))
                }.frame(width: 46, height: 46)
                Text(rateText).font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: rateText)
            }
            .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("全会话实时速率（估算）\(rateText)，点击查看详情")
            .accessibilityIdentifier("quota-sidebar-rate")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { controller.select(.overview) }
    }

    private var rateFraction: CGFloat {
        CGFloat(QuotaSidebarRatePresentation.fraction(rate: monitor.totalSnapshot.rollingTokensPerSecond,
            fullScale: fullScale, available: monitor.monitoringEnabled && monitor.dataSource != nil))
    }

    private var rateText: String {
        guard monitor.monitoringEnabled else { return "已关闭" }
        guard monitor.dataSource != nil, monitor.totalSnapshot.rollingTokensPerSecond.isFinite else { return "待读取" }
        return "\(monitor.totalSnapshot.rollingTokensPerSecondText) tok/s"
    }

    private var runningText: String {
        let summary = tasks.runningThreadSummary
        switch summary.freshness {
        case .fresh: return "\(summary.main) 主 · \(summary.subagents) 子"
        case .stale: return "\(summary.total) 运行 · 旧"
        case .loading: return "读取任务中"
        case .unavailable: return "任务未知"
        }
    }

    private func bar(window: AccountQuotaWindow?, color: Color) -> some View {
        let data = QuotaSidebarQuotaPresentation.make(window: window, snapshot: quota.snapshot)
        return SidebarValueBar(fraction: data.remaining.map { Double($0) / 100 }, color: color,
                               vertical: true, emphasis: data.stale ? 0.4 : 1)
            .frame(width: 4, height: 46)
    }

    private func ring(label: String, window: AccountQuotaWindow?, color: Color) -> some View {
        let data = QuotaSidebarQuotaPresentation.make(window: window, snapshot: quota.snapshot)
        return Button { controller.select(.overview) } label: {
            VStack(spacing: 5) {
                ZStack {
                    SidebarValueRing(fraction: data.remaining.map { Double($0) / 100 }, color: color,
                                     emphasis: data.stale ? 0.45 : 1)
                    Text(label).font(.system(size: 12, weight: .medium))
                }.frame(width: 46, height: 46)
                Text(data.text).font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: data.remaining)
                if data.stale { Text("旧数据").font(.system(size: 8)).foregroundStyle(.orange) }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 4)
            // Hit testing includes the ring, value and every blank pixel in
            // this row. The native rail remains exactly 88 pt wide.
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(label) 剩余 \(data.accessibilityText)，点击查看详情")
            .accessibilityIdentifier("quota-sidebar-\(label)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { controller.select(.overview) }
    }
}

struct QuotaSidebarDetailView: View {
    @ObservedObject var controller: QuotaSidebarController
    @ObservedObject var store: CodexUsageStore
    @ObservedObject var monitor: LiveRateMonitor
    @ObservedObject var quota: AccountQuotaStore
    @ObservedObject var tasks: TaskCompletionMonitor
    @ObservedObject var radar: CodexRadarStore

    var body: some View {
        // Capture one projection for every quota, usage and running field in
        // this render, so the cards and the model denominator agree.
        let snapshot = TokenDisplaySnapshot.make(store: store, monitor: monitor, quota: quota,
                                                  runningThreads: tasks.runningThreadSummary)
        VStack(alignment: .leading, spacing: 13) {
            header(snapshot.quota)
            HStack(spacing: 22) {
                tab("额度概览", detail: .overview)
                tab("任务", detail: .tasks)
                tab("雷达", detail: .radar)
                Spacer()
                Text("本地实时视图").font(.system(size: 9)).foregroundStyle(.gray)
            }
            Divider().overlay(.white.opacity(0.12))
            ScrollView {
                if controller.interaction.detail == .tasks { taskContent(snapshot.runningThreads) }
                else if controller.interaction.detail == .radar {
                    QuotaSidebarRadarContent(snapshot: radar.snapshot, crowd: radar.crowdSnapshot,
                                             officialStale: radar.staleDataDisplayed,
                                             crowdStale: radar.crowdStaleDataDisplayed,
                                             status: radar.status, updatedAt: radar.lastSuccessfulRefreshAt)
                } else { overview(snapshot) }
            }.scrollIndicators(.hidden)
            activitySummary(snapshot.runningThreads)
            Text(controller.interaction.pinned ? "已固定 · 点击关闭收起" : "移出后收起 · 图钉固定详情")
                .font(.system(size: 9)).foregroundStyle(.gray)
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SidebarPalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12), lineWidth: 1))
        .foregroundStyle(.white)
        .onHover { if $0 { controller.enter() } }
    }

    private func header(_ quota: AccountQuotaSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 22)).foregroundStyle(SidebarPalette.green)
                .padding(9).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Codex").font(.system(size: 19, weight: .semibold))
                    Text(quota.displayName).font(.system(size: 9, weight: .semibold))
                        .lineLimit(1).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(SidebarPalette.green.opacity(0.12), in: Capsule())
                        .foregroundStyle(SidebarPalette.green)
                }
                Text(quota.accountDisplayName).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Text(quota.updatedAt.map { "额度更新 \($0.formatted(date: .omitted, time: .shortened))" } ?? "额度尚未读取")
                    .font(.system(size: 9)).foregroundStyle(.gray)
            }
            Spacer(minLength: 0)
            Button { controller.togglePin() } label: {
                Image(systemName: controller.interaction.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(controller.interaction.pinned ? SidebarPalette.green : .gray)
            }.help(controller.interaction.pinned ? "取消固定详情" : "固定详情")
                .accessibilityLabel(controller.interaction.pinned ? "取消固定详情" : "固定详情")
            Button { controller.dismiss() } label: { Image(systemName: "xmark").foregroundStyle(.gray) }
                .help("收起额度侧栏").accessibilityLabel("收起额度侧栏")
        }.buttonStyle(.plain)
    }

    private func tab(_ title: String, detail: QuotaSidebarDetail) -> some View {
        Button { controller.select(detail) } label: {
            Text(title).font(.system(size: 11, weight: .medium))
                .foregroundStyle(controller.interaction.detail == detail ? SidebarPalette.green : .gray)
        }.buttonStyle(.plain)
    }

    private func overview(_ snapshot: TokenDisplaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                if let fiveHour = snapshot.quota.fiveHour {
                    quotaRow("5 小时额度", window: fiveHour, snapshot: snapshot.quota, color: SidebarPalette.green)
                }
                quotaRow("7 天额度", window: snapshot.quota.sevenDay, snapshot: snapshot.quota, color: SidebarPalette.purple)
                if let pace = snapshot.quota.sevenDayPaceStatus,
                   !QuotaSidebarQuotaPresentation.make(window: snapshot.quota.sevenDay, snapshot: snapshot.quota).stale {
                    HStack(spacing: 6) {
                        Image(systemName: pace.iconName)
                        Text("均匀使用参考 · 余量应为 \(pace.expectedRemainingPercent)%")
                        Spacer(minLength: 0)
                    }.font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
                }
                if !snapshot.quota.isAvailable || snapshot.quota.staleDataDisplayed {
                    Text(snapshot.quota.status).font(.system(size: 9)).foregroundStyle(.orange)
                        .lineLimit(1).help(snapshot.quota.status)
                }
            }.padding(14).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("用量", subtitle: "本地统计")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 9) {
                    metric("今日 Tokens", snapshot.todayTokensText, color: SidebarPalette.green)
                    metric("累计 Tokens", snapshot.consumedTokensText, color: .white)
                    metric("今日请求", snapshot.todayRequestsText, color: .white)
                    metric("实时 Tokens / 秒", LiveRateSnapshot.rateDisplayText(snapshot.rate), color: SidebarPalette.amber)
                }
                if let diagnostic = snapshot.metadataOnlyStatusText {
                    Text(diagnostic).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1).help(diagnostic)
                }
                Text("实时：\(snapshot.status)").font(.system(size: 9)).foregroundStyle(.gray).lineLimit(1).help(snapshot.status)
            }
            modelUsage(snapshot)
        }.padding(.bottom, 2)
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer()
            Text(subtitle).font(.system(size: 9)).foregroundStyle(.gray)
        }
    }

    private func modelUsage(_ snapshot: TokenDisplaySnapshot) -> some View {
        let items = QuotaSidebarModelUsage.items(snapshot: snapshot)
        let colors = [SidebarPalette.green, SidebarPalette.purple, SidebarPalette.amber, Color.cyan]
        return VStack(alignment: .leading, spacing: 11) {
            sectionTitle("今日模型用量", subtitle: "占已读取模型 Tokens · 前 4 项")
            if items.isEmpty {
                Text("尚无可信的今日模型明细").font(.system(size: 11)).foregroundStyle(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Circle().fill(colors[index]).frame(width: 5, height: 5)
                            Text(item.label).font(.system(size: 10, weight: .medium)).lineLimit(1).help(item.label)
                            Spacer(minLength: 0)
                            Text(item.tokens.abbreviatedTokens).foregroundStyle(.white.opacity(0.8))
                            Text(String(format: "%.1f%%", item.share * 100)).foregroundStyle(.gray).frame(width: 42, alignment: .trailing)
                        }.font(.system(size: 10)).monospacedDigit()
                        SidebarValueBar(fraction: item.share, color: colors[index], emphasis: 0.7).frame(height: 3)
                    }
                }
            }
        }.padding(14).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
    }

    private func quotaRow(_ title: String, window: AccountQuotaWindow?, snapshot: AccountQuotaSnapshot, color: Color) -> some View {
        let data = QuotaSidebarQuotaPresentation.make(window: window, snapshot: snapshot)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(data.text).font(.system(size: 26, weight: .medium, design: .rounded)).foregroundStyle(color).monospacedDigit()
                Text("剩余").font(.system(size: 10)).foregroundStyle(.gray)
            }
            SidebarValueBar(fraction: data.remaining.map { Double($0) / 100 }, color: color,
                            emphasis: data.stale ? 0.4 : 1).frame(height: 5)
            HStack {
                Text(window.map { $0.resetsAt == nil ? "重置时间未知" : "重置：\($0.compactResetText)" } ?? "重置时间未知")
                Spacer(minLength: 0)
                if data.stale { Text("旧数据").foregroundStyle(.orange) }
            }.font(.system(size: 9)).foregroundStyle(.gray)
        }
    }

    private func metric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(.gray)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private var unreadText: String {
        tasks.unreadThreadCountAvailable ? "\(tasks.unreadThreadCount) 个任务待查看" : tasks.statusText
    }

    private func activitySummary(_ summary: RunningThreadSummary) -> some View {
        let available = summary.freshness == .fresh || summary.freshness == .stale
        return Button { controller.select(.tasks) } label: {
            HStack(spacing: 0) {
                activityMetric(available ? "\(summary.main)" : "—", "运行主任务", color: SidebarPalette.amber)
                Spacer()
                activityMetric(available ? "\(summary.subagents)" : "—", "子代理", color: SidebarPalette.purple)
                Spacer()
                activityMetric(tasks.unreadThreadCountAvailable ? "\(tasks.unreadThreadCount)" : "—", "待查看", color: SidebarPalette.green)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.gray).padding(.leading, 14)
            }.padding(12).background(SidebarPalette.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topTrailing) {
                    if summary.freshness == .stale { Text("旧数据").font(.system(size: 8)).foregroundStyle(.orange).padding(4) }
                }
        }.buttonStyle(.plain).accessibilityLabel("查看运行任务与未读状态")
    }

    private func activityMetric(_ value: String, _ label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 18, weight: .medium, design: .rounded)).foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(.gray)
        }
    }

    private func taskContent(_ summary: RunningThreadSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("运行中的任务", subtitle: "主任务与子代理")
            switch summary.freshness {
            case .loading:
                taskNotice("正在读取运行任务…", icon: "clock")
            case .unavailable:
                taskNotice("运行任务状态暂不可用", icon: "questionmark.circle")
            case .fresh, .stale:
                if summary.freshness == .stale {
                    Text("以下为上次读取的任务状态").font(.system(size: 10)).foregroundStyle(.orange)
                }
                ForEach(summary.groups) { group in
                    taskGroup(group)
                }
                if !summary.unassignedSubagents.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("未关联主任务").font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Text("\(summary.unassignedSubagents.count) 个子代理")
                                .font(.system(size: 9)).foregroundStyle(.gray)
                        }
                        Text("当前数据未提供归属关系").font(.system(size: 9)).foregroundStyle(.gray)
                        ForEach(summary.unassignedSubagents) { member in
                            childTask(member)
                        }
                    }.padding(14).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
                }
                if summary.total == 0 {
                    taskNotice("当前没有运行中的任务", icon: "checkmark.circle")
                } else if summary.groups.isEmpty && summary.unassignedSubagents.isEmpty {
                    taskNotice("已读取运行数量，尚无任务层级明细", icon: "list.bullet.rectangle")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(unreadText).font(.system(size: 11)).foregroundStyle(SidebarPalette.green)
                if !tasks.lastCompletedTitle.isEmpty {
                    Text("最近完成").font(.system(size: 9)).foregroundStyle(.gray)
                    Text(tasks.lastCompletedTitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                        .lineLimit(3).help(tasks.lastCompletedTitle)
                }
            }.padding(.vertical, 5)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func taskNotice(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 11)).foregroundStyle(.gray)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
    }

    private func taskGroup(_ group: RunningThreadGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                taskBadge("主任务", color: SidebarPalette.amber)
                Spacer()
                Text("\(group.subagents.count) 个子代理").font(.system(size: 9)).foregroundStyle(.gray)
            }
            taskIdentity(group.mainThread, titleSize: 13)
            if !group.subagents.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(group.subagents) { member in
                        childTask(member)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(SidebarPalette.purple.opacity(0.25)).frame(width: 1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.06), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func childTask(_ member: RunningThreadMember) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(SidebarPalette.purple)
                taskBadge("子代理", color: SidebarPalette.purple)
            }
            taskIdentity(member, titleSize: 11)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(SidebarPalette.purple.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .contain)
    }

    private func taskBadge(_ title: String, color: Color) -> some View {
        Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
    }

    private func taskIdentity(_ member: RunningThreadMember, titleSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(member.title ?? "未命名任务")
                .font(.system(size: titleSize, weight: .medium))
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .help(member.title ?? "未命名任务")
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("模型").foregroundStyle(.gray).frame(width: 28, alignment: .leading)
                Text(member.model ?? "未知").foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 9))
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("推理").foregroundStyle(.gray).frame(width: 28, alignment: .leading)
                Text(member.reasoningEffort ?? "未提供").foregroundStyle(.white.opacity(0.65))
            }.font(.system(size: 9))
        }
    }
}


struct QuotaSidebarEdgeShape: Shape {
    let edge: QuotaSidebarEdge
    func path(in rect: CGRect) -> Path {
        let radius = min(22, max(8, 8 + (rect.width - 16) * 14 / 72))
        return UnevenRoundedRectangle(topLeadingRadius: edge == .right ? radius : 0,
            bottomLeadingRadius: edge == .right ? radius : 0,
            bottomTrailingRadius: edge == .left ? radius : 0,
            topTrailingRadius: edge == .left ? radius : 0).path(in: rect)
    }
}
