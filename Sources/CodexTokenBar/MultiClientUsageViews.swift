import AppKit
import SwiftUI

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
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("多客户端 Token 用量").font(.title3.bold())
                Spacer()
                Button(store.refreshing ? "读取中…" : "读取本地记录") { store.refresh() }.disabled(store.refreshing)
            }
            Text("只读本地日志，各客户端账本与 Codex 并列保存。关闭读取或删除原会话都不会删除已经记录的用量。")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(Array(store.preferences.enumerated()), id: \.element.id) { index, preference in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle().fill(Color(nsColor: NSColor(clientHex: preference.color))).frame(width: 9, height: 9)
                        Text(preference.client.displayName).font(.headline)
                        Spacer()
                        Toggle("读取本地用量", isOn: binding(preference, \.enabled)).toggleStyle(.switch)
                        Button { store.move(preference.client, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                        Button { store.move(preference.client, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == store.preferences.count - 1)
                    }
                    HStack(spacing: 16) {
                        Toggle("侧栏", isOn: binding(preference, \.showSidebar))
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

struct MultiClientUsageDashboardCard: View {
    @ObservedObject private var store = MultiClientUsageStore.shared
    var body: some View {
        if store.preferences.contains(where: \.enabled) || !store.summaries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("其他客户端 · 本地 Token 账本").font(.headline)
                    Spacer()
                    Text("累计已记录").font(.caption).foregroundStyle(.secondary)
                    Button("设置") { AppSettingsRouteRequest.request(.multiClientUsage) }
                    Button("刷新") { store.refresh() }.disabled(store.refreshing)
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                    GridRow {
                        Text("客户端 / 模型"); Text("输入"); Text("输出"); Text("缓存读取"); Text("缓存写入"); Text("思考¹"); Text("请求")
                    }.font(.caption).foregroundStyle(.secondary)
                    ForEach(store.preferences) { preference in
                        ForEach(store.summaries.filter { $0.client == preference.client }) { item in
                            GridRow {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.client.displayName).foregroundStyle(Color(nsColor: NSColor(clientHex: preference.color)))
                                    Text(item.model).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(amount(item.inputTokens)); Text(amount(item.outputTokens))
                                Text(optional(item.cacheReadTokens)); Text(optional(item.cacheWriteTokens)); Text(optional(item.reasoningTokens))
                                Text(String(item.requests))
                            }.font(.callout).monospacedDigit()
                        }
                    }
                }
                if store.summaries.isEmpty { Text(store.refreshing ? "正在读取本地记录…" : "尚无可识别的本地用量记录").foregroundStyle(.secondary) }
                Text("输入包含缓存；¹思考是输出的子集，不重复相加。— 表示来源未提供；部分字段仅汇总已提供值。这里不是订阅剩余额度。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(store.diagnostics, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }.padding(18).background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 16))
        }
    }
    private func amount(_ value: Int64) -> String { MultiClientUsageStore.compact(value) }
    private func optional(_ value: Int64?) -> String { value.map(amount) ?? "—" }
}

struct MultiClientUsageSidebarRows: View {
    @ObservedObject private var store = MultiClientUsageStore.shared
    @AppStorage("multiClient.claudeQuotaSidebar") private var claudeQuota = false
    @AppStorage("multiClient.claudeQuotaColor") private var claudeColor = "#d87757"
    @AppStorage("multiClient.claudeQuotaFirst") private var claudeFirst = false
    @AppStorage("multiClient.claudeQuotaStyle") private var claudeStyle = "compact"
    var body: some View {
        if claudeQuota && claudeFirst { quotaRow }
        ForEach(store.preferences.filter(\.showSidebar)) { preference in
            Button { AppSettingsRouteRequest.request(.multiClientUsage) } label: {
                VStack(spacing: 3) {
                    Text(preference.client.displayName).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(store.summaries.contains { $0.client == preference.client } ? MultiClientUsageStore.compact(store.total(preference.client)) : "—").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    if preference.style == "detailed" { Text("累计 Token").font(.system(size: 8)) }
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
    @State private var quota = ClaudeLocalQuota.missing
    var body: some View {
        VStack(alignment: compact ? .center : .leading, spacing: 4) {
            Text(compact ? "Claude 额度" : "Claude Code · 本地状态栏额度").font(compact ? .system(size: 9) : .headline)
            if quota.state == "available" {
                if let window = quota.fiveHour { reading("5h", window) }
                if let window = quota.sevenDay { reading("7d", window) }
            } else {
                Text(quota.state == "stale" ? "已过期" : "未采集").font(compact ? .system(size: 11) : .callout).foregroundStyle(.secondary)
            }
            if !compact, let captured = quota.capturedAt {
                Text("采集于 \(captured.formatted()) · 最近 Claude 进程，未绑定账号").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            while !Task.isCancelled {
                quota = await Task.detached(priority: .utility) { ClaudeLocalQuota.read() }.value
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
    private func reading(_ name: String, _ window: ClaudeLocalQuota.Window) -> some View {
        VStack(alignment: compact ? .center : .leading, spacing: 2) {
            Text("\(name) 剩余 \(Int((100 - window.usedPercent).rounded()))%").font(compact ? .system(size: 10) : .callout)
            if !compact || showReset { Text("重置 \(window.resetsAt.formatted())").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
