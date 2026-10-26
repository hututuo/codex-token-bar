import AppKit
import SwiftUI

struct MultiClientUsageSettingsView: View {
    var codexQuota: AccountQuotaSnapshot = .empty
    @ObservedObject private var store = MultiClientUsageStore.shared
    @State private var backupMessage = ""
    @State private var showCustom = false
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
            ClientQuotaSettingsView(codex: codexQuota)
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
        ForEach(Array(store.newDetections.prefix(1))) { detection in
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("发现 \(detection.client.displayName)").font(.callout.bold())
                    Text("启用后在本机统计 Token，随时可关闭。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("启用") { store.enable(detection.client) }
                Button("暂不启用") { store.acknowledge(detection.client) }
            }.padding(.vertical, 5).help("只读取本地日志，不开启排行榜上报")
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
    @AppStorage(ClientDisplayScope.key) private var clientScope = "codex"
    var codexTokens: Int64? = nil
    var onOpen: (() -> Void)? = nil
    @AppStorage("multiClient.overviewSidebar") private var showOverview = false
    @ObservedObject private var store = MultiClientUsageStore.shared
    var body: some View {
        if ClientDisplayScope.clients(clientScope, available: store.displayClientIDs).contains("codex") {
            Button { onOpen?() } label: {
                VStack(spacing: 3) {
                    Text("Codex").font(.system(size: 9))
                    Text(codexTokens.map(MultiClientUsageStore.compact) ?? "—").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Text("累计 Token").font(.system(size: 8)).foregroundStyle(.secondary)
                }.frame(width: 74).padding(.vertical, 5)
            }.buttonStyle(SidebarPulseButtonStyle())
        }
        if showOverview && clientScope == "all" {
            VStack(spacing: 3) {
                Text("合计 · 已记录").font(.system(size: 9))
                Text(MultiClientUsageStore.compact((codexTokens ?? 0) + store.preferences.filter(\.enabled).reduce(0) { $0 + store.total($1.client) })).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                if codexTokens == nil { Text("Codex 暂不可用").font(.system(size: 8)) }
            }.frame(width: 74).padding(.vertical, 5)
        }

        ForEach(store.preferences.filter { $0.showSidebar && (clientScope == "all" || clientScope == $0.client.rawValue) }) { preference in
            Button { if let onOpen { onOpen() } else { AppSettingsRouteRequest.request(.multiClientUsage) } } label: {
                VStack(spacing: 3) {
                    Text(preference.client.displayName).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(store.summaries.contains { $0.client == preference.client } ? MultiClientUsageStore.compact(store.total(preference.client)) : "—").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Text("累计 Token").font(.system(size: 8)).foregroundStyle(.secondary)

                }.foregroundStyle(Color(nsColor: NSColor(clientHex: preference.color))).frame(width: 74).padding(.vertical, 5)
            }.buttonStyle(SidebarPulseButtonStyle())
        }

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
