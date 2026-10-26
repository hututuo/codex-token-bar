import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QuotaSidebarModuleSettingsView: View {
    @ObservedObject var controller: QuotaSidebarController
    var quotaSnapshot: AccountQuotaSnapshot = .empty
    @ObservedObject var monitor: LiveRateMonitor
    var modelShares: [ModelTokenBreakdown] = []
    var quotaItemsOverride: [ClientQuotaItem]? = nil
    @ObservedObject private var clients = MultiClientUsageStore.shared
    @ObservedObject private var runtime = ClaudeLocalRuntime.shared
    @AppStorage(ClientQuotaSelection.key) private var selectionRaw = ""
    @AppStorage(ClientDisplayScope.key) private var clientScope = "codex"
    @AppStorage(TokenRateScaleSettings.key) private var fullScale = TokenRateScaleSettings.defaultValue
    @State private var compactPreviewOpen = false
    @State private var draggedItem: QuotaSidebarItem?
    @State private var dragSessionID: UUID?
    @State private var dropTarget: SidebarSettingsDropTarget?
    @State private var rowHeights: [QuotaSidebarItem: CGFloat] = [:]

    private var selection: ClientQuotaSelection { .decode(selectionRaw) }
    private var quotas: [ClientQuotaItem] {
        if let quotaItemsOverride { return quotaItemsOverride }
        return ClientQuotaProjection.items(codex: quotaSnapshot, claude: clients.quotaReading(.claudeCode),
            includeClaude: clients.availablePreferences.contains { $0.client == .claudeCode || $0.client == .claudeDesktop },
            includeFiveHour: selection.enabled.contains("codex:5h"), preview: ClientPreviewMode.simulated)
            .filter { scopeIncludes($0.client) }
    }
    private var supportsCodex: Bool { quotaItemsOverride?.contains { $0.client == "codex" } ?? allowedClients.contains("codex") }
    private var items: [QuotaSidebarItem] {
        controller.sidebarLayout.arranged(availableQuotaClients: quotas.map(\.client))
            .filter { supportsCodex || !allowedClients.isDisjoint(with: ["claudeCode", "claudeDesktop"]) || !$0.requiresCodexLiveData }
    }
    private var allowedClients: Set<String> { ClientDisplayScope.clients(clientScope, available: clients.displayClientIDs) }
    private var selectedRates: [ModelRateContribution] { ClientLocalRuntimePresentation.rates(codex: monitor.totalSnapshot.modelRates, claude: runtime.projection(allowed: allowedClients).modelRates, allowed: allowedClients) }
    private var previewItems: [QuotaSidebarItem] {
        items.filter { item in
            guard controller.sidebarLayout.isVisible(item, in: .compact) else { return false }
            return true
        }
    }
    private var previewQuotas: [ClientQuotaItem] {
        previewItems.flatMap { item -> [ClientQuotaItem] in
            guard case let .quota(client) = item else { return [] }
            return QuotaSidebarContentOrder.quotaWindows(quotas, client: client).filter(selection.includes)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("侧栏设置").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("恢复默认顺序") { controller.resetSidebarItemOrder() }.font(.system(size: 10))
            }
            Text("拖动排序；一级、二级分别勾选。指向一行，侧栏对应模块高亮。")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
            DisclosureGroup("查看收起后的一级外观", isExpanded: $compactPreviewOpen) {
                if compactPreviewOpen { compactPreview }
            }.font(.system(size: 11)).tint(Color(red: 182/255, green: 239/255, blue: 117/255))
                .accessibilityIdentifier("quota-sidebar-compact-preview")
            VStack(spacing: 7) {
                ForEach(items) { item in
                    SidebarSettingsRow(item: item,
                        compactVisible: controller.sidebarLayout.isVisible(item, in: .compact),
                        expandedVisible: controller.sidebarLayout.isVisible(item, in: .expanded),
                        highlighted: controller.settingsHighlightedItem == item,
                        dragging: draggedItem == item, placement: dropTarget?.item == item ? dropTarget?.after : nil,
                        windows: quotaWindows(for: item), selection: selection,
                        onVisibility: { level, visible in controller.setSidebarItemVisible(item, in: level, visible: visible) },
                        onWindow: { id, visible in
                            var next = selection
                            if visible { next.hidden.remove(id); next.enabled.insert(id) }
                            else { next.hidden.insert(id); next.enabled.remove(id) }
                            selectionRaw = next.encoded
                        },
                        onHover: { if draggedItem == nil { controller.highlightSidebarItem(item) } },
                        onDragBegin: { session in
                            dragSessionID = session; draggedItem = item; dropTarget = nil
                            controller.setSettingsReordering(true)
                            controller.highlightSidebarItem(item)
                        },
                        onDragEnd: { session in if dragSessionID == session { finishDrag() } },
                        onMove: { offset in move(item, by: offset) })
                    .onDrop(of: [UTType.text.identifier], delegate: SidebarSettingsDropDelegate(
                        target: item, height: rowHeights[item] ?? 46,
                        draggedItem: $draggedItem, dropTarget: $dropTarget,
                        onDrop: { source, target, after in
                            controller.moveSidebarItem(source, relativeTo: target, after: after)
                            controller.highlightSidebarItem(source)
                            finishDrag()
                        }))
                }
            }.onPreferenceChange(SidebarSettingsRowHeightsKey.self) { if rowHeights != $0 { rowHeights = $0 } }
            Text("显示范围跟随主页面；隐藏的项目保留顺序，设置入口固定在底部。")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
            DisclosureGroup("额度填充颜色") {
                ClientQuotaSettingsView(codex: quotaSnapshot, quotaItems: quotas, showVisibility: false)
                    .padding(.top, 8)
            }.font(.system(size: 11))
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                if controller.settingsHighlightedItem == nil {
                    controller.highlightSidebarItem(items.first { if case .quota = $0 { return true }; return false } ?? items.first)
                }
            }
            .onDisappear { finishDrag(); controller.highlightSidebarItem(nil) }
    }

    private var compactPreview: some View {
        let count = QuotaSidebarContentOrder.compactIDs(items: previewItems, quotas: previewQuotas).count
        let layout = ClientRailLayout.fixed(trackCount: count, dotCount: previewItems.filter(\.usesCompactDot).count, availableHeight: controller.availableRailHeight)
        let shares = FloatingTodayModelUsagePresentation.items(from: ClientLocalRuntimePresentation.models(codex: modelShares, clients: clients.todaySummaries, allowed: allowedClients), fallbackModel: .gpt56Sol, mergeAutoReview: true).filter { $0.share > 0 }
        return HStack(alignment: .center, spacing: 24) {
            if count > 0 {
                ScrollView(.vertical) {
                    QuotaSidebarCompactBars(items: previewItems, quotas: previewQuotas, layout: layout,
                        rateFraction: QuotaSidebarRatePresentation.fraction(rate: selectedRates.reduce(0) { $0 + $1.tokensPerSecond },
                            fullScale: fullScale, available: (allowedClients.contains("codex") && monitor.monitoringEnabled && monitor.dataSource != nil) || runtime.projection(allowed: allowedClients).sourceAvailable),
                        modelRates: selectedRates, shares: shares, colors: selection.colors)
                }.scrollIndicators(.hidden).frame(width: 16, height: min(layout.height, 330))
                    .background(Color.black, in: Capsule())
            }
            Text(count > 0 ? "仅预览收起状态。\n设置打开时，侧栏保持二级菜单。" : "当前没有显示在一级的项目。")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
        }.padding(.vertical, 10).frame(maxWidth: .infinity)
    }

    private func quotaWindows(for item: QuotaSidebarItem) -> [ClientQuotaItem] {
        guard case let .quota(client) = item else { return [] }
        return QuotaSidebarContentOrder.quotaWindows(quotas, client: client)
    }
    private func scopeIncludes(_ client: String) -> Bool {
        allowedClients.contains(client) || (client == "claudeCode" && allowedClients.contains("claudeDesktop"))
    }
    private func move(_ item: QuotaSidebarItem, by offset: Int) {
        guard let index = items.firstIndex(of: item), items.indices.contains(index + offset) else { return }
        controller.moveSidebarItem(item, relativeTo: items[index + offset], after: offset > 0)
    }
    private func finishDrag() {
        draggedItem = nil; dropTarget = nil; dragSessionID = nil
        controller.setSettingsReordering(false)
    }
}

/// Read-only companion of the real expanded sidebar, mounted only while its
/// settings are open. It reuses the compact renderer and the same preferences.
struct QuotaSidebarSettingsRailPreview: View {
    @ObservedObject var controller: QuotaSidebarController
    @ObservedObject var store: CodexUsageStore
    @ObservedObject var quota: AccountQuotaStore
    @ObservedObject var tasks: TaskCompletionMonitor
    @ObservedObject var monitor: LiveRateMonitor
    var quotaItemsOverride: [ClientQuotaItem]? = nil
    @ObservedObject private var clients = MultiClientUsageStore.shared
    @ObservedObject private var runtime = ClaudeLocalRuntime.shared
    @AppStorage(ClientDisplayScope.key) private var scope = "codex"
    @AppStorage(ClientQuotaSelection.key) private var selectionRaw = ""
    @AppStorage(TokenRateScaleSettings.key) private var fullScale = TokenRateScaleSettings.defaultValue
    @State private var shares: [FloatingTodayModelUsageItem] = []
    private var selection: ClientQuotaSelection { .decode(selectionRaw) }
    private var quotas: [ClientQuotaItem] {
        if let quotaItemsOverride { return quotaItemsOverride.filter(selection.includes) }
        let allowed = ClientDisplayScope.clients(scope, available: clients.displayClientIDs)
        return ClientQuotaProjection.items(codex: quota.snapshot, claude: clients.quotaReading(.claudeCode),
            includeClaude: clients.availablePreferences.contains { $0.client == .claudeCode || $0.client == .claudeDesktop },
            includeFiveHour: selection.enabled.contains("codex:5h"), preview: ClientPreviewMode.simulated)
            .filter { (allowed.contains($0.client) || ($0.client == "claudeCode" && allowed.contains("claudeDesktop"))) && selection.includes($0) }
    }
    private var items: [QuotaSidebarItem] {
        controller.sidebarLayout.arranged(availableQuotaClients: quotas.map(\.client)).filter {
            controller.sidebarLayout.isVisible($0, in: .compact) && ((scope == "all" || scope == "codex" || scope == "claudeCode" || scope == "claudeDesktop") || !$0.requiresCodexLiveData)
        }
    }
    private var allowedClients: Set<String> { ClientDisplayScope.clients(scope, available: clients.displayClientIDs) }
    private var selectedRates: [ModelRateContribution] { ClientLocalRuntimePresentation.rates(codex: monitor.totalSnapshot.modelRates, claude: runtime.projection(allowed: allowedClients).modelRates, allowed: allowedClients) }
    private var selectedModels: [ModelTokenBreakdown] { ClientLocalRuntimePresentation.models(codex: store.todayModelBreakdowns, clients: clients.todaySummaries, allowed: allowedClients) }
    private var selectedRunning: RunningThreadSummary { ClientLocalRuntimePresentation.running(codex: tasks.runningThreadSummary, claude: runtime.projection(allowed: allowedClients).running, allowed: allowedClients) }
    var body: some View {
        let layout = ClientRailLayout.fixed(trackCount: QuotaSidebarContentOrder.compactIDs(items: items, quotas: quotas).count, dotCount: items.filter(\.usesCompactDot).count, availableHeight: controller.availableRailHeight)
        ScrollView(.vertical) {
            QuotaSidebarCompactBars(items: items, quotas: quotas, layout: layout,
                rateFraction: QuotaSidebarRatePresentation.fraction(rate: selectedRates.reduce(0) { $0 + $1.tokensPerSecond }, fullScale: fullScale, available: (allowedClients.contains("codex") && monitor.monitoringEnabled && monitor.dataSource != nil) || runtime.projection(allowed: allowedClients).sourceAvailable),
                modelRates: selectedRates, shares: shares,
                taskStateLabel: "任务状态：\(selectedRunning.total) 个运行任务，非进度百分比", highlightedItem: controller.settingsHighlightedItem, colors: selection.colors)
                .frame(minHeight: layout.height)
        }.scrollIndicators(.hidden).frame(width: 16)
            .background(Color(red: 0.035, green: 0.045, blue: 0.038), in: Capsule())
            .help("一级菜单实时预览；修改显示与顺序可立即查看")
            .onChange(of: selectedModels, initial: true) { _, rows in
                shares = FloatingTodayModelUsagePresentation.items(from: rows, fallbackModel: .gpt56Sol, mergeAutoReview: true).filter { $0.share > 0 }
            }
    }
}

private struct SidebarSettingsDropTarget: Equatable {
    let item: QuotaSidebarItem
    let after: Bool
}

private struct SidebarSettingsRow: View {
    let item: QuotaSidebarItem
    let compactVisible: Bool
    let expandedVisible: Bool
    let highlighted: Bool
    let dragging: Bool
    let placement: Bool?
    let windows: [ClientQuotaItem]
    let selection: ClientQuotaSelection
    let onVisibility: (QuotaSidebarLevel, Bool) -> Void
    let onWindow: (String, Bool) -> Void
    let onHover: () -> Void
    let onDragBegin: (UUID) -> Void
    let onDragEnd: (UUID) -> Void
    let onMove: (Int) -> Void
    private let green = Color(red: 182/255, green: 239/255, blue: 117/255)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                dragHandle
                HStack(spacing: 5) {
                        if case let .quota(client) = item {
                            Circle().fill(Color(nsColor: NSColor(clientHex: ClientBrand.hex(client)))).frame(width: 6, height: 6)
                        }
                        Text(item.title).font(.system(size: 11, weight: .medium))
                }
                Spacer(minLength: 0)
                if item.hasCompactRepresentation {
                    Toggle("一级", isOn: Binding(get: { compactVisible }, set: { onVisibility(.compact, $0) }))
                        .toggleStyle(.checkbox).tint(green).font(.system(size: 10))
                        .accessibilityLabel("一级显示" + item.title)
                } else { Text("—").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).frame(width: 42).help("此模块只在二级菜单显示") }
                Toggle("二级", isOn: Binding(get: { expandedVisible }, set: { onVisibility(.expanded, $0) }))
                    .toggleStyle(.checkbox).tint(green).font(.system(size: 10))
                    .accessibilityLabel("二级显示" + item.title)
            }
            if !windows.isEmpty {
                HStack(spacing: 12) {
                    ForEach(windows) { window in
                        Toggle(window.windowTitle, isOn: Binding(get: { selection.includes(window) }, set: { onWindow(window.id, $0) }))
                            .toggleStyle(.checkbox).tint(green).font(.system(size: 10))
                            .accessibilityIdentifier("sidebar-window-visible-" + window.id)
                    }
                }.padding(.leading, 24).disabled(!compactVisible && !expandedVisible)
            }
        }.padding(.horizontal, 9).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { proxy in Color.clear.preference(key: SidebarSettingsRowHeightsKey.self, value: [item: proxy.size.height]) })
            .background(.white.opacity(highlighted ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(highlighted ? green.opacity(0.55) : .white.opacity(0.065), lineWidth: 1))
            .overlay(alignment: placement == true ? .bottom : .top) {
                if placement != nil { Rectangle().fill(green).frame(height: 2).offset(y: placement == true ? 4 : -4) }
            }
            .opacity(dragging ? 0.4 : 1)
            .onHover { if $0 { onHover() } }
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            .frame(width: 17, height: 22)
            .overlay {
                FloatingStructureDragSource(payload: item.id, previewSize: NSSize(width: 210, height: 40),
                    cursorAnchor: NSPoint(x: 15, y: 20), onBegin: onDragBegin, onEnd: onDragEnd) {
                    HStack(spacing: 9) { Image(systemName: "line.3.horizontal"); Text(item.title); Spacer() }
                        .font(.system(size: 12)).foregroundStyle(.white).padding(11)
                        .frame(width: 210, height: 40).background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(green.opacity(0.5), lineWidth: 1))
                }
            }
            .help("拖动排序：" + item.title)
            .accessibilityLabel("拖动排序：" + item.title)
            .accessibilityAction(named: "上移") { onMove(-1) }
            .accessibilityAction(named: "下移") { onMove(1) }
    }
}

private struct SidebarSettingsRowHeightsKey: PreferenceKey {
    static let defaultValue: [QuotaSidebarItem: CGFloat] = [:]
    static func reduce(value: inout [QuotaSidebarItem: CGFloat], nextValue: () -> [QuotaSidebarItem: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SidebarSettingsDropDelegate: DropDelegate {
    let target: QuotaSidebarItem
    let height: CGFloat
    @Binding var draggedItem: QuotaSidebarItem?
    @Binding var dropTarget: SidebarSettingsDropTarget?
    let onDrop: (QuotaSidebarItem, QuotaSidebarItem, Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool { draggedItem != nil && draggedItem != target }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
        dropTarget = SidebarSettingsDropTarget(item: target, after: info.location.y > height / 2)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { if dropTarget?.item == target { dropTarget = nil } }
    func performDrop(info: DropInfo) -> Bool {
        guard let source = draggedItem, source != target else { return false }
        onDrop(source, target, info.location.y > height / 2)
        return true
    }
}
