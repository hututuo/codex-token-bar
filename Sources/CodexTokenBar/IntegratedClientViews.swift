import SwiftUI
import Charts

struct ClientScopePicker: View {
    @ObservedObject private var clients = MultiClientUsageStore.shared
    @AppStorage(ClientDisplayScope.key) private var scope = "codex"
    private var choices: [MultiClientUsagePreference] {
        clients.availablePreferences.filter { preference in preference.enabled || clients.summaries.contains { $0.client == preference.client } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 0) {
                scopeButton("Codex", id: "codex")
                ForEach(choices.prefix(2)) { scopeButton($0.client.displayName, id: $0.client.rawValue) }
                if choices.count > 2 {
                    Menu("更多") { ForEach(choices.dropFirst(2)) { value in Button(value.client.displayName) { scope = value.client.rawValue } } }
                        .menuStyle(.borderlessButton).frame(width: 68)
                }
                scopeButton("汇总", id: "all")
                Spacer()
                if scope != "codex" { Text("本地已记录 · 各额度独立").font(.caption).foregroundStyle(.secondary) }
            }
            MultiClientDiscoveryNotice()
        }.task { clients.start() }
    }
    private func scopeButton(_ title: String, id: String) -> some View {
        Button { scope = id } label: {
            HStack(spacing: 6) {
                if id != "all" { Circle().fill(Color(nsColor: NSColor(clientHex: ClientBrand.hex(id)))).frame(width: 7, height: 7) }
                Text(title).font(.system(size: 14, weight: .semibold))
            }.padding(.horizontal, 16).padding(.vertical, 10)
                .background(scope == id ? AppTheme.accentGreen.opacity(0.16) : AppTheme.panelBackground,
                    in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityAddTraits(scope == id ? .isSelected : [])
    }
}

struct ClientQuotaSettingsView: View {
    let codex: AccountQuotaSnapshot
    @ObservedObject private var clients = MultiClientUsageStore.shared
    @AppStorage(ClientQuotaSelection.key) private var selectionRaw = ""
    @AppStorage("multiClient.railLength.v1") private var length = "auto"
    private var selection: ClientQuotaSelection { .decode(selectionRaw) }
    private var items: [ClientQuotaItem] {
        selection.arranged(ClientQuotaProjection.items(codex: codex,
            claude: clients.quotaReading(.claudeCode), includeClaude: clients.availablePreferences.contains { $0.client == .claudeCode || $0.client == .claudeDesktop }, includeFiveHour: selection.enabled.contains("codex:5h")))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("额度项目").font(.headline)
            Picker("竖条长度", selection: $length) { Text("长条").tag("long"); Text("短条").tag("short"); Text("自动").tag("auto") }.pickerStyle(.segmented)
            Text("自动：超出原推荐高度 25% 时使用短条，保留全部项目。").font(.caption).foregroundStyle(.secondary)
            Toggle("将不同客户端的额度合在一个环内", isOn: Binding(get: { selection.pairAcrossClients }, set: { value in
                var next = selection; next.pairAcrossClients = value; selectionRaw = next.encoded
            })).toggleStyle(.checkbox).font(.caption)
            Text("默认按客户端配对：一项用整环，两项用左右半环。").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    Circle().fill(Color(nsColor: NSColor(clientHex: item.brand))).frame(width: 7, height: 7)
                    Toggle(item.title, isOn: Binding(get: { selection.includes(item) }, set: { show in
                        var next = selection
                        if show { next.hidden.remove(item.id); next.enabled.insert(item.id) } else { next.hidden.insert(item.id); next.enabled.remove(item.id) }
                        selectionRaw = next.encoded
                    })).toggleStyle(.checkbox).font(.system(size: 11))
                    Spacer(minLength: 0)
                    ColorPicker("填充", selection: Binding(get: { Color(nsColor: NSColor(clientHex: selection.colors[item.id] ?? item.brand)) }, set: { color in
                        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                        var next = selection
                        next.colors[item.id] = String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
                        selectionRaw = next.encoded
                    }), supportsOpacity: false).labelsHidden()
                    Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                    Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == items.count - 1)
                }
            }
            Text("范围跟随主页面；窗口百分比不相加。Claude 只读本地缓存，联网额度关闭。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func move(_ index: Int, by offset: Int) {
        var ids = items.map(\.id); ids.swapAt(index, index + offset)
        var next = selection; next.order = ids; selectionRaw = next.encoded
    }
}

struct ClientQuotaRings: View {
    @AppStorage(ClientQuotaSelection.key) private var selectionRaw = ""
    let items: [ClientQuotaItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(items.map(\.client).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }, id: \.self) { client in
                VStack(alignment: .leading, spacing: 8) {
                    Label { Text(ClientDisplayScope.title(client)).font(.headline) } icon: {
                        Circle().fill(Color(nsColor: NSColor(clientHex: ClientBrand.hex(client)))).frame(width: 8, height: 8)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 12) {
                        ForEach(items.filter { $0.client == client }) { item in
                            VStack(spacing: 5) {
                                ZStack {
                                    Circle().stroke(.secondary.opacity(0.15), lineWidth: 6)
                                    Circle().trim(from: 0, to: (item.remaining ?? 0) / 100)
                                        .stroke(Color(nsColor: NSColor(clientHex: ClientQuotaSelection.decode(selectionRaw).colors[item.id] ?? item.brand)), style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                                    if let expected = item.expected {
                                        Rectangle().fill(.primary).frame(width: 2, height: 10).offset(y: -44).rotationEffect(.degrees(expected * 360))
                                    }
                                    VStack(spacing: 3) { Text(item.value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit(); Text(item.window).font(.caption) }
                                }.frame(width: 90, height: 90).padding(4)
                                Text(item.resetsAt.map { "重置 " + $0.formatted(date: .numeric, time: .shortened) } ?? "重置时间未知").font(.system(size: 10)).foregroundStyle(.secondary)
                                if !item.status.isEmpty { Text(item.status).font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
                        }
                    }
                    Text(items.first { $0.client == client }?.source ?? "").font(.caption).foregroundStyle(.secondary)
                    if client == "claudeCode", items.filter({ $0.client == client }).allSatisfy({ $0.remaining == nil }) {
                        DisclosureGroup("查看接入说明") { Text(ClaudeCapturedQuotaProvider.setup).font(.caption).textSelection(.enabled) }
                    }
                }
            }
            Text("各窗口独立，不合计额度").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Two independent half tracks share a circular outline. Never draws an upper semicircle gauge.
struct ClientPairedQuotaRing: View {
    @AppStorage(ClientQuotaSelection.key) private var selectionRaw = ""
    let left: ClientQuotaItem
    let right: ClientQuotaItem?
    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                if let right {
                    Circle().trim(from: 0.006, to: 0.494).stroke(.white.opacity(0.15), lineWidth: 3).rotationEffect(.degrees(90))
                    half(left, rotation: 90)
                    Circle().trim(from: 0.006, to: 0.494).stroke(.white.opacity(0.15), lineWidth: 3).rotationEffect(.degrees(-90))
                    half(right, rotation: -90)
                } else {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 3)
                    Circle().trim(from: 0, to: (left.remaining ?? 0) / 100)
                        .stroke(Color(nsColor: NSColor(clientHex: ClientQuotaSelection.decode(selectionRaw).colors[left.id] ?? left.brand)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90)).opacity(left.remaining == nil ? 0 : 1)
                }
                if let expected = left.expected {
                    Rectangle().fill(.white).frame(width: 1.5, height: 7).offset(y: -29).rotationEffect(.degrees(right == nil ? expected * 360 : 180 + expected * 180))
                }
                if let expected = right?.expected {
                    Rectangle().fill(.white).frame(width: 1.5, height: 7).offset(y: -29).rotationEffect(.degrees(expected * 180))
                }
                HStack(spacing: 2) {
                    Text(left.value)
                    if let right { Text("|").foregroundStyle(.gray); Text(right.value) }
                }.font(.system(size: right == nil ? 17 : 9, weight: .semibold, design: .rounded)).monospacedDigit()
            }.frame(width: 58, height: 58)
            legend(left)
            if let right { legend(right) }
        }.frame(width: 74).padding(.vertical, 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(right.map { "左侧 \(left.title) \(left.value)，右侧 \($0.title) \($0.value)" } ?? "\(left.title) 剩余 \(left.value)，完整圆环")
    }
    private func half(_ item: ClientQuotaItem, rotation: Double) -> some View {
        Circle().trim(from: 0.006, to: 0.006 + 0.488 * (item.remaining ?? 0) / 100)
            .stroke(Color(nsColor: NSColor(clientHex: ClientQuotaSelection.decode(selectionRaw).colors[item.id] ?? item.brand)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(rotation)).opacity(item.remaining == nil ? 0 : 1)
    }
    private func legend(_ item: ClientQuotaItem) -> some View {
        HStack(spacing: 3) {
            Circle().fill(Color(nsColor: NSColor(clientHex: item.brand))).frame(width: 4, height: 4)
            Text(item.title).lineLimit(1).minimumScaleFactor(0.8)
        }.font(.system(size: 8)).foregroundStyle(.white.opacity(0.8))
    }
}

struct ScopedClientTokenSummary: View, @preconcurrency Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.compact == rhs.compact && lhs.allowed == rhs.allowed && lhs.codex.generatedAt == rhs.codex.generatedAt && lhs.codex.exactGeneration == rhs.codex.exactGeneration
    }
    let codex: DashboardSnapshot
    let allowed: Set<String>
    var compact = false
    @ObservedObject private var clients = MultiClientUsageStore.shared
    private var rows: [ClientUsageSummary] { clients.summaries.filter { allowed.contains($0.client.rawValue) } }
    private var knownCosts: [Double] {
        rows.compactMap(\.apiCostUSD) + (allowed.contains("codex") ? codex.cacheUsage.modelBreakdowns.compactMap(codexCost) : [])
    }
    private var unpricedRequests: Int { rows.reduce(0) { $0 + $1.unpricedRequests } }
    private func codexCost(_ row: ModelTokenBreakdown) -> Double? {
        guard let model = row.model, StandardAPIPriceSchedule.quote(for: model, at: nil) != nil else { return nil }
        let items = FloatingTodayModelUsagePresentation.items(from: [row], fallbackModel: .gpt56Sol, mergeAutoReview: true)
        return FloatingTodayModelUsagePresentation.knownCostUSD(in: items)
    }
    private func compactRow(_ title: String, tokens: String, model: String, cost: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(title).lineLimit(1); Spacer(); Text(tokens).monospacedDigit() }
            HStack { Text("标准 API 等值"); Spacer(); Text(ClientMoney.text(cost)).help("参考单价 " + ClientReferencePrice.text(model)) }
                .foregroundStyle(.secondary)
        }.font(.caption)
    }
    var body: some View {
        let input = rows.reduce(0) { $0 + $1.inputTokens } + (allowed.contains("codex") ? Int64(codex.stats.totalInputTokens ?? 0) : 0)
        let output = rows.reduce(0) { $0 + $1.outputTokens } + (allowed.contains("codex") ? Int64(codex.stats.totalOutputTokens ?? 0) : 0)
        let total = rows.reduce(0) { $0 + $1.inputTokens + $1.outputTokens } + (allowed.contains("codex") ? Int64(codex.stats.totalTokens) : 0)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                metric("累计 Token 数", total)
                Divider().frame(height: 40)
                metric("输入 Token", input)
                Divider().frame(height: 40)
                metric("输出 Token", output)
                Divider().frame(height: 40)
                VStack { Text("部分").font(.title3); Text("本地已记录").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Text("模型 / API 等值 · 累计已记录").font(.callout.weight(.semibold))
                Spacer()
                Text("已知小计 " + ClientMoney.text(knownCosts.isEmpty ? nil : knownCosts.reduce(0, +))).font(.callout.bold()).monospacedDigit()
            }
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    if allowed.contains("codex") {
                        ForEach(Array(codex.cacheUsage.modelBreakdowns.enumerated()), id: \.offset) { _, row in
                            compactRow("Codex · " + (row.model ?? "未知模型"), tokens: row.breakdown.totalTokens.abbreviatedTokens,
                                model: row.model ?? "", cost: codexCost(row))
                        }
                    }
                    ForEach(rows) { row in
                        compactRow(row.client.displayName + " · " + row.model,
                            tokens: MultiClientUsageStore.compact(row.inputTokens + row.outputTokens), model: row.model, cost: row.apiCostUSD)
                    }
                }
            } else {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow { Text("客户端 · 模型"); Text("Token"); Text("缓存读 / 写"); Text("标准 API 等值") }.font(.caption).foregroundStyle(.secondary)
                if allowed.contains("codex") {
                    ForEach(Array(codex.cacheUsage.modelBreakdowns.enumerated()), id: \.offset) { _, row in
                        GridRow { Text("Codex · " + (row.model ?? "未知模型")); Text(row.breakdown.totalTokens.abbreviatedTokens); Text(row.breakdown.cachedInputTokens.abbreviatedTokens + " / —"); Text(ClientMoney.text(codexCost(row))).help("参考单价（输入/输出，每百万Token） " + ClientReferencePrice.text(row.model ?? "")) }.font(.caption)
                    }
                }
                ForEach(rows) { row in
                    GridRow {
                        Text(row.client.displayName + " · " + row.model)
                        Text(MultiClientUsageStore.compact(row.inputTokens + row.outputTokens))
                        Text((row.cacheReadTokens.map(MultiClientUsageStore.compact) ?? "—") + " / " + (row.cacheWriteTokens.map(MultiClientUsageStore.compact) ?? "—"))
                        Text(ClientMoney.text(row.apiCostUSD)).help("参考单价（输入/输出，每百万Token） " + ClientReferencePrice.text(row.model))
                    }.font(.caption).monospacedDigit()
                }
            }
            }
            Text("标准 API 价估算 · 缓存与思考不重复累加 · 不是订阅扣费记录").font(.caption).foregroundStyle(.secondary)
            if unpricedRequests > 0 { Text("\(unpricedRequests) 次请求因价目规则或用量字段不足，未计入金额").font(.caption).foregroundStyle(.secondary) }
        }.padding(18).background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 16))
    }
    private func metric(_ title: String, _ value: Int64) -> some View {
        VStack(spacing: 5) { Text(MultiClientUsageStore.compact(value)).font(.system(size: 22, weight: .semibold)).monospacedDigit(); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity)
    }
}

struct ScopedClientUsageChart: View, @preconcurrency Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.allowed == rhs.allowed && lhs.codex.generatedAt == rhs.codex.generatedAt && lhs.codex.exactGeneration == rhs.codex.exactGeneration
    }
    let codex: DashboardSnapshot
    let allowed: Set<String>
    @ObservedObject private var clients = MultiClientUsageStore.shared
    @State private var days = 1
    @State private var split = false
    @State private var selected: Date?
    var body: some View {
        let source = ClientUsageChartProjection.points(codex: codex.recentBins, others: clients.trendBuckets, days: days, now: clients.updatedAt ?? Date(), allowed: allowed)
        let points = split ? source : Dictionary(grouping: source, by: \.start).map { date, values in ClientChartPoint(client: "all", start: date, tokens: values.reduce(0) { $0 + $1.tokens }) }.sorted { $0.start < $1.start }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("近期 Token 用量").font(.headline)
                Spacer()
                if allowed.count > 1 { Toggle("按客户端", isOn: $split).toggleStyle(.checkbox) }
                Picker("范围", selection: $days) { Text("24 小时").tag(1); Text("7 天").tag(7); Text("30 天").tag(30) }.pickerStyle(.segmented).frame(width: 240)
            }
            Chart(points) { point in
                LineMark(x: .value("时间", point.start), y: .value("Token", point.tokens), series: .value("客户端", point.client))
                    .foregroundStyle(by: .value("客户端", point.client))
            }.chartForegroundStyleScale(domain: ["all"] + allowed.sorted(), range: [AppTheme.accentGreen] + allowed.sorted().map { Color(nsColor: NSColor(clientHex: ClientBrand.hex($0))) })
                .chartXSelection(value: $selected).chartLegend(.hidden).frame(height: 240)
            if let selected, let point = source.min(by: { abs($0.start.timeIntervalSince(selected)) < abs($1.start.timeIntervalSince(selected)) }) {
                Text(point.start.formatted() + " · " + source.filter { $0.start == point.start }.map { ClientDisplayScope.title($0.client) + " " + MultiClientUsageStore.compact($0.tokens) }.joined(separator: " · ")).font(.caption).monospacedDigit()
            }
            Text("\(days == 1 ? "5 分钟" : days == 7 ? "1 小时" : "6 小时")桶（含两端未满桶）· 本地已记录，缺失记录不补推").font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 16))
    }
}


struct ScopedClientActivity: View, @preconcurrency Equatable {
    let codex: DashboardSnapshot
    let allowed: Set<String>
    @ObservedObject private var clients = MultiClientUsageStore.shared
    @State private var mode = ActivityMode.daily
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.allowed == rhs.allowed && lhs.codex.generatedAt == rhs.codex.generatedAt && lhs.codex.exactGeneration == rhs.codex.exactGeneration
    }
    var body: some View {
        ActivitySection(dailyUsage: ClientActivityProjection.days(codex: codex.dailyUsage,
            others: clients.dailyBuckets, allowed: allowed), cacheDaily: [], quotaDaily: [], selectedMode: $mode, tokensOnly: true)
    }
}

/// The dashboard retains its original horizontal quota tracks; full rings belong
/// to the larger third-level detail, not a new standalone dashboard card.
struct ClientDashboardQuotaStrip: View {
    let items: [ClientQuotaItem]
    @AppStorage(ClientQuotaSelection.key) private var selectionRaw = ""
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240))], alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Circle().fill(Color(nsColor: NSColor(clientHex: item.brand))).frame(width: 6, height: 6)
                        Text(item.title).font(.callout.weight(.medium))
                        Spacer()
                        Text(item.value).monospacedDigit().font(.callout.weight(.semibold))
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.secondary.opacity(0.15))
                            Capsule().fill(Color(nsColor: NSColor(clientHex: ClientQuotaSelection.decode(selectionRaw).colors[item.id] ?? item.brand)))
                                .frame(width: geometry.size.width * (item.remaining ?? 0) / 100).opacity(item.remaining == nil ? 0 : 1)
                        }
                    }.frame(height: 7)
                    Text(item.remaining == nil ? item.status : item.resetsAt.map { "重置 " + $0.formatted(date: .numeric, time: .shortened) } ?? "重置时间未知")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
