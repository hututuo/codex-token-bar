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
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                scopeButton("Codex", id: "codex")
                ForEach(choices.prefix(2)) { scopeButton($0.client.displayName, id: $0.client.rawValue) }
                if choices.count > 2 {
                    Menu("更多") { ForEach(choices.dropFirst(2)) { value in Button(value.client.displayName) { scope = value.client.rawValue } } }
                        .menuStyle(.borderlessButton).frame(width: 68)
                }
                scopeButton("汇总", id: "all")
                }.padding(3).background(AppTheme.solidControlBackground, in: RoundedRectangle(cornerRadius: 8))
                Spacer()
                if ClientPreviewMode.simulated { Text("Codex / Claude 模拟数据").font(.caption.weight(.medium)).foregroundStyle(AppTheme.accentAmber) }
            }
            MultiClientDiscoveryNotice()
        }.frame(maxWidth: 980, alignment: .leading).task { clients.start() }
    }
    private func scopeButton(_ title: String, id: String) -> some View {
        Button { scope = id } label: {
            HStack(spacing: 6) {
                if id != "all" { Circle().fill(Color(nsColor: NSColor(clientHex: ClientBrand.hex(id)))).frame(width: 7, height: 7) }
                Text(title).font(.system(size: 12, weight: .medium))
            }.padding(.horizontal, 12).frame(height: 29)
                .foregroundStyle(scope == id ? AppTheme.accentBlue : .primary)
                .background(scope == id ? AppTheme.selectedControlBackground : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityAddTraits(scope == id ? .isSelected : [])
    }
}

struct ClientQuotaSettingsView: View {
    let codex: AccountQuotaSnapshot
    var quotaItems: [ClientQuotaItem]? = nil
    @ObservedObject private var clients = MultiClientUsageStore.shared
    @AppStorage(ClientQuotaSelection.key) private var selectionRaw = ""
    @AppStorage("multiClient.railLength.v1") private var length = "auto"
    private var selection: ClientQuotaSelection { .decode(selectionRaw) }
    private var items: [ClientQuotaItem] {
        selection.arranged(quotaItems ?? ClientQuotaProjection.items(codex: codex,
            claude: clients.quotaReading(.claudeCode), includeClaude: clients.availablePreferences.contains { $0.client == .claudeCode || $0.client == .claudeDesktop }, includeFiveHour: selection.enabled.contains("codex:5h"), preview: ClientPreviewMode.simulated))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("额度显示与外观").font(.headline)
                Spacer()
                Button("恢复默认") { selectionRaw = ClientQuotaSelection().encoded; length = "auto" }.font(.caption)
            }
            Picker("竖条长度", selection: $length) { Text("长条").tag("long"); Text("短条").tag("short"); Text("自动").tag("auto") }.pickerStyle(.segmented)
            Text("自动：超出原推荐高度 25% 时使用短条，保留全部项目。").font(.caption).foregroundStyle(.secondary)
            Toggle("将不同客户端的额度合在一个环内", isOn: Binding(get: { selection.pairAcrossClients }, set: { value in
                var next = selection; next.pairAcrossClients = value; selectionRaw = next.encoded
            })).toggleStyle(.checkbox).font(.caption)
            Text("默认按客户端配对：一项用整环，两项用左右半环。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("显示的额度"); Spacer(); Text("填充颜色"); Text("顺序").frame(width: 50)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    Circle().fill(Color(nsColor: NSColor(clientHex: item.brand))).frame(width: 7, height: 7)
                    Toggle(item.title, isOn: Binding(get: { selection.includes(item) }, set: { show in
                        var next = selection
                        if show { next.hidden.remove(item.id); next.enabled.insert(item.id) } else { next.hidden.insert(item.id); next.enabled.remove(item.id) }
                        selectionRaw = next.encoded
                    })).toggleStyle(.checkbox).font(.system(size: 11))
                    Spacer(minLength: 0)
                    ColorPicker("填充", selection: Binding(get: { Color(nsColor: NSColor(clientHex: selection.colors[item.id] ?? item.fill)) }, set: { color in
                        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                        var next = selection
                        next.colors[item.id] = String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
                        selectionRaw = next.encoded
                    }), supportsOpacity: false).labelsHidden().help(item.title + "：自定义额度填充颜色")
                    Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("上移 " + item.title).accessibilityLabel("上移 " + item.title)
                    Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == items.count - 1).help("下移 " + item.title).accessibilityLabel("下移 " + item.title)
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
                                        .stroke(Color(nsColor: NSColor(clientHex: ClientQuotaSelection.decode(selectionRaw).colors[item.id] ?? item.fill)), style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
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
                        .stroke(Color(nsColor: NSColor(clientHex: ClientQuotaSelection.decode(selectionRaw).colors[left.id] ?? left.fill)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90)).opacity(left.remaining == nil ? 0 : 1)
                }
                if let expected = left.expected {
                    Rectangle().fill(.white).frame(width: 1.5, height: 7).offset(y: -ClientSidebarMetrics.ringSize / 2).rotationEffect(.degrees(right == nil ? expected * 360 : 180 + expected * 180))
                }
                if let expected = right?.expected {
                    Rectangle().fill(.white).frame(width: 1.5, height: 7).offset(y: -ClientSidebarMetrics.ringSize / 2).rotationEffect(.degrees(expected * 180))
                }
                if let right {
                    HStack(spacing: 1) {
                        Text(left.compactValue).frame(width: 14)
                        Rectangle().fill(.white.opacity(0.35)).frame(width: 1, height: 8)
                        Text(right.compactValue).frame(width: 14)
                    }.font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                } else {
                    Text(left.value).font(.system(size: 14, weight: .medium, design: .rounded)).monospacedDigit()
                }
            }.frame(width: ClientSidebarMetrics.ringSize, height: ClientSidebarMetrics.ringSize)
            VStack(spacing: 3) {
                HStack(spacing: 0) {
                    windowLabel(left)
                    if let right { windowLabel(right) }
                }
                if let right, right.client != left.client {
                    HStack(spacing: 2) { legend(left); legend(right) }
                } else { legend(left) }
            }
        }.frame(width: 74).padding(.vertical, 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(right.map { "左侧 \(left.title) \(left.value)，右侧 \($0.title) \($0.value)" } ?? "\(left.title) 剩余 \(left.value)，完整圆环")
    }
    private func half(_ item: ClientQuotaItem, rotation: Double) -> some View {
        Circle().trim(from: 0.006, to: 0.006 + 0.488 * (item.remaining ?? 0) / 100)
            .stroke(Color(nsColor: NSColor(clientHex: ClientQuotaSelection.decode(selectionRaw).colors[item.id] ?? item.fill)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(rotation)).opacity(item.remaining == nil ? 0 : 1)
    }
    private func windowLabel(_ item: ClientQuotaItem) -> some View {
        Text(item.windowTitle).font(.system(size: 9))
            .foregroundStyle(Color(nsColor: NSColor(clientHex: ClientQuotaSelection.decode(selectionRaw).colors[item.id] ?? item.fill)))
            .lineLimit(1).minimumScaleFactor(0.75).frame(width: right == nil ? 68 : 34)
    }
    private func legend(_ item: ClientQuotaItem) -> some View {
        HStack(spacing: 3) {
            Circle().fill(Color(nsColor: NSColor(clientHex: item.brand))).frame(width: 4, height: 4)
            Text(item.shortClientTitle).lineLimit(1).minimumScaleFactor(0.8)
        }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
    }
}
