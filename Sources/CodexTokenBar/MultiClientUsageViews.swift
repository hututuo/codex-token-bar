import AppKit
import SwiftUI
import Charts

struct MultiClientUsageSettingsView: View {
    @ObservedObject private var store = MultiClientUsageStore.shared
    @AppStorage("multiClient.codexQuotaSidebar") private var codexSidebar = true
    @AppStorage("multiClient.codexQuotaColor") private var codexColor = "#b6ef75"
    @AppStorage("multiClient.claudeQuotaSidebar") private var claudeSidebar = false
    @AppStorage("multiClient.claudeQuotaMenuBar") private var claudeMenuBar = false
    @AppStorage("multiClient.claudeQuotaColor") private var claudeColor = "#d87757"
    @AppStorage("multiClient.claudeQuotaFirst") private var claudeFirst = false
    @AppStorage("multiClient.claudeQuotaStyle") private var claudeStyle = "compact"
    @State private var backupMessage = ""
    @State private var showCustom = false
    @AppStorage("multiClient.overviewSidebar") private var overviewSidebar = false
    private var visiblePreferences: [MultiClientUsagePreference] { showCustom ? store.preferences : store.availablePreferences }
    private func move(_ preference: MultiClientUsagePreference, by delta: Int) {
        guard let current = visiblePreferences.firstIndex(of: preference), visiblePreferences.indices.contains(current + delta),
              let source = store.preferences.firstIndex(of: preference),
              let target = store.preferences.firstIndex(of: visiblePreferences[current + delta]) else { return }
        store.move(preference.client, by: target - source)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("多客户端 Token 用量").font(.title3.bold())
                Spacer()
                Button(store.refreshing ? "读取中…" : "读取本地记录") { store.refresh() }.disabled(store.refreshing)
            }
            Text("只读本地日志，各客户端账本与 Codex 并列保存。关闭读取或删除原会话都不会删除已经记录的用量。")
                .font(.callout).foregroundStyle(.secondary)
            MultiClientDiscoveryNotice()
            Toggle("侧栏显示合计（Codex + 已启用客户端）", isOn: $overviewSidebar)
            ForEach(Array(visiblePreferences.enumerated()), id: \.element.id) { index, preference in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle().fill(Color(nsColor: NSColor(clientHex: preference.color))).frame(width: 9, height: 9)
                        Text(preference.client.displayName).font(.headline)
                        Spacer()
                        Toggle("读取本地用量", isOn: binding(preference, \.enabled)).toggleStyle(.switch)
                        Button { move(preference, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                        Button { move(preference, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == visiblePreferences.count - 1)
                    }
                    HStack(spacing: 16) {
                        Toggle("侧栏", isOn: binding(preference, \.showSidebar))
                        Toggle("额度", isOn: binding(preference, \.showQuota))
                        Toggle("菜单栏", isOn: binding(preference, \.showMenuBar))
                        Picker("样式", selection: binding(preference, \.style)) {
                            Text("紧凑").tag("compact"); Text("详细").tag("detailed")
                        }.frame(width: 180)
                        ColorPicker("颜色", selection: Binding(get: { Color(nsColor: NSColor(clientHex: preference.color)) }, set: { color in
                            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                            var next = preference
                            next.color = String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                            store.update(next)
                        }), supportsOpacity: false)
                    }.toggleStyle(.checkbox).font(.callout)
                    TextField("自动发现；也可指定本地日志目录或文件", text: binding(preference, \.path)).textFieldStyle(.roundedBorder)
                    if preference.client == .claudeDesktop {
                        Text("仅支持本地 Code / Agent 会话；云端聊天未落地的用量无法读取。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
            Button(showCustom ? "只显示已发现的客户端" : "手动接入其他日志目录") { showCustom.toggle() }
            Divider()
            Text("额度显示").font(.headline)
            Toggle("侧栏显示 Codex 额度", isOn: $codexSidebar)
            ColorPicker("Codex 额度颜色", selection: Binding(get: { Color(nsColor: NSColor(clientHex: codexColor)) }, set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                codexColor = String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            }), supportsOpacity: false)
            Toggle("侧栏显示 Claude Code 额度状态", isOn: $claudeSidebar)
            Toggle("菜单栏显示 Claude Code 额度状态", isOn: $claudeMenuBar)
            HStack {
                Toggle("Claude 额度排在其他客户端前面", isOn: $claudeFirst)
                Picker("额度样式", selection: $claudeStyle) {
                    Text("紧凑").tag("compact"); Text("详细").tag("detailed")
                }.frame(width: 180)
                ColorPicker("Claude 额度颜色", selection: Binding(get: { Color(nsColor: NSColor(clientHex: claudeColor)) }, set: { color in
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    claudeColor = String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                }), supportsOpacity: false)
            }
            .onChange(of: claudeMenuBar) { _, _ in store.refreshPresentation() }
            .onChange(of: claudeColor) { _, _ in store.refreshPresentation() }
            .onChange(of: claudeFirst) { _, _ in store.refreshPresentation() }
            ClaudeLocalQuotaReadings()
            Text("只读 Claude-Code-Usage-Monitor 已保存的状态栏额度，不安装钩子、不读取凭据、不联网。记录属于最近一个 Claude 进程，无法绑定账户；超过 10 分钟或窗口到期就不再显示百分比。Codex 菜单栏额度开关与顺序继续使用「状态栏」设置。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("备份其他客户端账本") {
                    Task {
                        do { backupMessage = "已保存：\(try await store.backup().path)" }
                        catch { backupMessage = error.localizedDescription }
                    }
                }
                Text("Codex 原始账本不参与迁移或改写").font(.caption).foregroundStyle(.secondary)
            }
            if !backupMessage.isEmpty { Text(backupMessage).font(.caption).textSelection(.enabled) }
            ForEach(store.diagnostics, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).task { store.start() }
    }
    private func binding<Value>(_ preference: MultiClientUsagePreference, _ key: WritableKeyPath<MultiClientUsagePreference, Value>) -> Binding<Value> {
        Binding(get: { store.preferences.first { $0.client == preference.client }?[keyPath: key] ?? preference[keyPath: key] },
                set: { value in var next = store.preferences.first { $0.client == preference.client } ?? preference; next[keyPath: key] = value; store.update(next) })
    }
}

struct MultiClientDiscoveryNotice: View {
    @ObservedObject private var store = MultiClientUsageStore.shared
    var body: some View {
        ForEach(store.newDetections) { detection in
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("发现 \(detection.client.displayName)").font(.callout.bold())
                    Text("启用后在本机统计 Token，随时可关闭。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("启用") { store.enable(detection.client) }
                Button("暂不启用") { store.acknowledge(detection.client) }
            }.padding(12).background(.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct MultiClientUsageDashboardCard: View {
    var codex: DashboardSnapshot = .empty
    var codexQuota: AccountQuotaSnapshot = .empty
    @ObservedObject private var store = MultiClientUsageStore.shared
    @State private var selected = "codex"
    @State private var days = 1
    @State private var combined = false
    @State private var selectedDate: Date?
    private var clients: [MultiClientUsagePreference] {
        store.preferences.filter { value in value.enabled || store.summaries.contains { $0.client == value.client } }
    }
    private var allowed: Set<String> { selected == "all" ? Set(["codex"] + clients.map { $0.client.rawValue }) : [selected] }
    private var points: [ClientChartPoint] {
        ClientUsageChartProjection.points(codex: codex.hourlyUsage, others: store.trendBuckets, days: days,
                                         now: store.updatedAt ?? codex.generatedAt, allowed: allowed)
    }
    private var chartPoints: [ClientChartPoint] {
        if !combined || selected != "all" { return points }
        return Dictionary(grouping: points, by: \.start).map { date, rows in
            ClientChartPoint(client: "all", start: date, tokens: rows.reduce(0) { $0 + $1.tokens })
        }.sorted { $0.start < $1.start }
    }
    private func name(_ client: String) -> String { client == "codex" ? "Codex" : client == "all" ? "合计" : UsageClient(rawValue: client)?.displayName ?? client }
    private func color(_ client: String) -> Color { Color(nsColor: NSColor(clientHex: store.preferences.first { $0.client.rawValue == client }?.color ?? "#72b743")) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MultiClientDiscoveryNotice()
            if !clients.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("客户端用量").font(.headline)
                        Spacer()
                        Button("显示设置") { AppSettingsRouteRequest.request(.multiClientUsage) }
                    }
                    HStack {
                        Picker("客户端", selection: $selected) {
                            Text("Codex").tag("codex"); Text("全部客户端").tag("all")
                            ForEach(clients) { Text($0.client.displayName).tag($0.client.rawValue) }
                        }.frame(maxWidth: 240)
                        Spacer()
                        Picker("时间", selection: $days) { Text("24小时").tag(1); Text("7天").tag(7); Text("30天").tag(30) }.pickerStyle(.segmented).frame(width: 210)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(MultiClientUsageStore.compact(points.reduce(0) { $0 + $1.tokens })).font(.title2.bold()).monospacedDigit()
                        Text("区间已记录 Token").foregroundStyle(.secondary)
                        Spacer()
                        if selected == "all" { Toggle("合并总量", isOn: $combined).toggleStyle(.checkbox) }
                    }
                    Chart(chartPoints) { point in
                        BarMark(x: .value("时间", point.start), y: .value("Token", point.tokens))
                            .foregroundStyle(by: .value("客户端", point.client))
                    }
                    .chartForegroundStyleScale(domain: ["codex", "all"] + store.preferences.map { $0.client.rawValue },
                                               range: [color("codex"), color("all")] + store.preferences.map { color($0.client.rawValue) })
                    .chartLegend(.hidden).chartXSelection(value: $selectedDate).frame(height: 170)
                    if let selectedDate, let nearest = points.min(by: { abs($0.start.timeIntervalSince(selectedDate)) < abs($1.start.timeIntervalSince(selectedDate)) }) {
                        Text(nearest.start.formatted() + " · " + points.filter { $0.start == nearest.start }.map { "\(name($0.client)) \(MultiClientUsageStore.compact($0.tokens))" }.joined(separator: "  ·  "))
                            .font(.caption).monospacedDigit()
                    }
                    HStack(spacing: 14) {
                        ForEach(allowed.sorted(), id: \.self) { client in
                            Label(name(client), systemImage: "circle.fill").font(.caption).foregroundStyle(color(client))
                        }
                    }
                    if allowed.contains("codex") && codex.hourlyUsage.isEmpty {
                        Text("Codex 图表尚无可用记录，当前合计可能不完整。").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(days == 1 ? "每小时 Token · UTC 时桶 · 点选查看数值" : "每日 Token · UTC 日桶 · 点选查看数值").font(.caption).foregroundStyle(.secondary)
                    if selected == "codex" || selected == "all" {
                        ClientQuotaReadingView(reading: CodexObservedQuotaProvider(snapshot: codexQuota).reading())
                    }
                    ForEach(clients.filter { selected == "all" || $0.client.rawValue == selected }) { preference in
                        HStack { Text(preference.client.displayName).foregroundStyle(color(preference.client.rawValue)); Spacer(); Text("累计已记录 " + MultiClientUsageStore.compact(store.total(preference.client))) }.font(.callout)
                        ClientQuotaReadingView(reading: store.quotaReading(preference.client))
                    }
                    if selected != "codex" {
                        DisclosureGroup("模型与 Token 明细（累计已记录）") {
                            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                                GridRow { Text("模型"); Text("输入"); Text("输出"); Text("缓存读/写"); Text("思考"); Text("请求") }.font(.caption).foregroundStyle(.secondary)
                                ForEach(store.summaries.filter { selected == "all" || $0.client.rawValue == selected }) { row in
                                    GridRow {
                                        Text(row.client.displayName + " · " + row.model).lineLimit(1)
                                        Text(MultiClientUsageStore.compact(row.inputTokens)); Text(MultiClientUsageStore.compact(row.outputTokens))
                                        Text((row.cacheReadTokens.map(MultiClientUsageStore.compact) ?? "—") + " / " + (row.cacheWriteTokens.map(MultiClientUsageStore.compact) ?? "—"))
                                        Text(row.reasoningTokens.map(MultiClientUsageStore.compact) ?? "—"); Text(String(row.requests))
                                    }.font(.caption).monospacedDigit()
                                }
                            }
                        }
                    }
                    Text("合计仅包含已记录的输入 + 输出，缓存与思考不重复相加。历史分批读取，缺失日志不补推。下方原有统计和费用仍属于 Codex。").font(.caption).foregroundStyle(.secondary)
                    ForEach(store.diagnostics, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }.padding(18).background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

struct ClientQuotaReadingView: View {
    let reading: ClientQuotaReading
    var compact = false
    var body: some View {
        VStack(alignment: compact ? .center : .leading, spacing: 3) {
            if reading.state == "available" {
                ForEach(reading.windows, id: \.label) { window in
                    Text("\(window.label) 剩余 \(Int((100 - window.usedPercent).rounded()))%").font(compact ? .system(size: 9) : .callout)
                }
            } else {
                Text(reading.state == "notConnected" ? "额度未接入" : "额度不可用").font(compact ? .system(size: 9) : .callout)
            }
            if !compact { Text(reading.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.help(reading.notice)
    }
}

struct MultiClientUsageSidebarRows: View {
    var codexTokens: Int64? = nil
    @AppStorage("multiClient.overviewSidebar") private var showOverview = false
    @ObservedObject private var store = MultiClientUsageStore.shared
    @AppStorage("multiClient.claudeQuotaSidebar") private var claudeQuota = false
    @AppStorage("multiClient.claudeQuotaColor") private var claudeColor = "#d87757"
    @AppStorage("multiClient.claudeQuotaFirst") private var claudeFirst = false
    @AppStorage("multiClient.claudeQuotaStyle") private var claudeStyle = "compact"
    var body: some View {
        if showOverview {
            VStack(spacing: 3) {
                Text("合计 · 已记录").font(.system(size: 9))
                Text(MultiClientUsageStore.compact((codexTokens ?? 0) + store.preferences.filter(\.enabled).reduce(0) { $0 + store.total($1.client) })).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                if codexTokens == nil { Text("Codex 暂不可用").font(.system(size: 8)) }
            }.frame(width: 74).padding(.vertical, 5)
        }
        if claudeQuota && claudeFirst { quotaRow }
        ForEach(store.preferences.filter(\.showSidebar)) { preference in
            Button { AppSettingsRouteRequest.request(.multiClientUsage) } label: {
                VStack(spacing: 3) {
                    Text(preference.client.displayName).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(store.summaries.contains { $0.client == preference.client } ? MultiClientUsageStore.compact(store.total(preference.client)) : "—").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    if preference.style == "detailed" { Text("累计 Token").font(.system(size: 8)) }
                    if preference.showQuota { ClientQuotaReadingView(reading: store.quotaReading(preference.client), compact: true) }
                }.foregroundStyle(Color(nsColor: NSColor(clientHex: preference.color))).frame(width: 74).padding(.vertical, 5)
            }.buttonStyle(SidebarPulseButtonStyle())
        }
        if claudeQuota && !claudeFirst { quotaRow }
    }
    private var quotaRow: some View {
        ClaudeLocalQuotaReadings(compact: true, showReset: claudeStyle == "detailed")
            .foregroundStyle(Color(nsColor: NSColor(clientHex: claudeColor)))
            .frame(width: 74).padding(.vertical, 5)
    }
}


struct ClaudeLocalQuotaReadings: View {
    var compact = false
    var showReset = false
    @ObservedObject private var store = MultiClientUsageStore.shared
    var body: some View {
        VStack(alignment: compact ? .center : .leading, spacing: 4) {
            Text("Claude Code 额度").font(compact ? .system(size: 9) : .headline)
            ClientQuotaReadingView(reading: ClaudeCapturedQuotaProvider(snapshot: store.claudeQuota).reading(), compact: compact)
            if !compact { Text("联网额度：关闭（尚未接入）").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
