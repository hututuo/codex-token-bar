import SwiftUI

private enum SidebarPalette {
    static let green = Color(red: 182.0 / 255, green: 239.0 / 255, blue: 117.0 / 255)
    static let purple = Color(red: 180.0 / 255, green: 172.0 / 255, blue: 1)
    static let amber = Color(red: 239.0 / 255, green: 192.0 / 255, blue: 119.0 / 255)
    static let blue = Color(red: 120.0 / 255, green: 183.0 / 255, blue: 1)
    static let background = Color(red: 0.035, green: 0.045, blue: 0.038)
}

// Animate the fill dimensions inside a fixed track. Rebuilding the capsule
// at its actual size keeps both end caps round, even for small readings.
private struct SidebarValueBar: View {
    let fraction: Double?
    let color: Color
    var vertical = false
    var modelRates: [ModelRateContribution]? = nil
    var emphasis = 1.0
    var expected: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var amount: Double { min(1, max(0, fraction ?? 0)) }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: vertical ? .bottom : .leading) {
                Capsule().fill(.white.opacity(0.12))
                SmoothRateFillBar(fraction: amount, minimumFraction: 0,
                    colors: [color.opacity(emphasis)], modelRates: modelRates)
                    .frame(width: vertical ? geometry.size.height : geometry.size.width,
                           height: vertical ? geometry.size.width : geometry.size.height)
                    .rotationEffect(.degrees(vertical ? -90 : 0))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .opacity(fraction == nil || amount == 0 ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay {
                if let expected {
                    Rectangle().fill(.white)
                        .frame(width: vertical ? geometry.size.width : 1.5,
                               height: vertical ? 1.5 : geometry.size.height)
                        .position(x: vertical ? geometry.size.width / 2 : geometry.size.width * min(1, max(0, expected)),
                                  y: vertical ? geometry.size.height * (1 - min(1, max(0, expected))) : geometry.size.height / 2)
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: emphasis)
    }
}

/// A brighter client dot overlaps the top of the original continuous track.
struct ClientQuotaRailTrack: View {
    let item: ClientQuotaItem
    let height: Double
    let fillHex: String
    var body: some View {
        ZStack(alignment: .top) {
            MatchedStrokeMorphParticipant(ids: [item.id], size: CGSize(width: ClientSidebarMetrics.trackWidth, height: height - 2.5)) {
                SidebarValueBar(fraction: item.remaining.map { $0 / 100 },
                    color: Color(nsColor: NSColor(clientHex: fillHex)), vertical: true)
            }.padding(.top, 2.5)
            MatchedStrokeMorphParticipant(ids: ["marker:" + item.id], size: CGSize(width: 5, height: 5)) {
                Circle().fill(Color(nsColor: NSColor(clientHex: item.brand))).frame(width: 5, height: 5)
            }.allowsHitTesting(false)
            if let expected = item.expected {
                MatchedStrokeMorphParticipant(ids: ["pace:" + item.id], size: CGSize(width: ClientSidebarMetrics.markerDiameter, height: 1.5)) {
                    Rectangle().fill(.white)
                }.position(x: ClientSidebarMetrics.markerDiameter / 2,
                           y: 2.5 + (height - 2.5) * (1 - min(1, max(0, expected))))
                    .allowsHitTesting(false).zIndex(3)
            }
        }.frame(width: ClientSidebarMetrics.markerDiameter, height: height)
    }
}

private struct SidebarValueRing: View {
    let fraction: Double?
    let color: Color
    var modelRates: [ModelRateContribution]? = nil
    var emphasis = 1.0
    var expected: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var fillStyle: AnyShapeStyle {
        guard let modelRates else { return AnyShapeStyle(color.opacity(emphasis)) }
        return AnyShapeStyle(AngularGradient(gradient: Gradient(stops: ModelRatePresentation.stops(modelRates)),
            center: .center, startAngle: .zero, endAngle: .degrees(360 * min(1, max(0, fraction ?? 0)))))
    }
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 3)
            Circle().trim(from: 0, to: min(1, max(0, fraction ?? 0)))
                .stroke(fillStyle, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90)).opacity(fraction == nil ? 0 : 1)
            if let expected {
                Rectangle().fill(.white).frame(width: 1.5, height: 7)
                    .offset(y: -23).rotationEffect(.degrees(min(1, max(0, expected)) * 360))
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.34), value: fraction)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: emphasis)
    }
}

/// Both the real compact rail and the optional settings preview render this
/// same lightweight stack. The preview never creates another menu/controller.
struct QuotaSidebarCompactBars: View {
    let items: [QuotaSidebarItem]
    let quotas: [ClientQuotaItem]
    let layout: ClientRailLayout
    var rateFraction: Double? = nil
    var modelRates: [ModelRateContribution]? = nil
    var shares: [FloatingTodayModelUsageItem] = []
    var taskStateLabel = "任务状态，非进度百分比"
    var highlightedItem: QuotaSidebarItem? = nil
    var colors: [String: String] = [:]
    var usesMorphAnchors = false

    var body: some View {
        VStack(spacing: layout.gap) {
            ForEach(items.filter(\.hasCompactRepresentation)) { item in
                Group {
                    switch item {
                    case .speed:
                        compactStroke(id: "speed") {
                            SidebarValueBar(fraction: rateFraction, color: SidebarPalette.blue, vertical: true, modelRates: modelRates)
                                .frame(width: 4, height: layout.barHeight)
                        }.help("全会话实时速率（估算）")
                    case .tasks:
                        compactStroke(id: "tasks") {
                            Capsule().fill(SidebarPalette.amber.opacity(0.5)).frame(width: 4, height: layout.barHeight)
                        }.help(taskStateLabel).accessibilityLabel(taskStateLabel)
                    case let .quota(client):
                        ForEach(QuotaSidebarContentOrder.quotaWindows(quotas, client: client)) { quota in
                            if usesMorphAnchors {
                                quotaTrack(quota).anchorPreference(key: ClientQuotaMorphAnchors.self, value: .bounds) { ["track:" + quota.id: $0] }
                            } else { quotaTrack(quota) }
                        }
                    case .models:
                        compactStroke(id: "models") {
                            SidebarModelShareStrip(items: shares, vertical: true).frame(width: 4, height: layout.barHeight)
                        }
                    default:
                        EmptyView()
                    }
                }.overlay {
                    Capsule().stroke(SidebarPalette.green.opacity(highlightedItem == item ? 0.85 : 0), lineWidth: 1).padding(.horizontal, -3)
                }
            }
        }.frame(width: 16).padding(.vertical, 15)
    }

    private func compactStroke<Content: View>(id: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        MatchedStrokeMorphParticipant(ids: [id], size: CGSize(width: 4, height: layout.barHeight), content: content)
            .anchorPreference(key: ClientQuotaMorphAnchors.self, value: .bounds) { usesMorphAnchors ? ["track:" + id: $0] : [:] }
    }

    private func quotaTrack(_ item: ClientQuotaItem) -> some View {
        ClientQuotaRailTrack(item: item, height: layout.barHeight, fillHex: colors[item.id] ?? item.fill)
            .help(item.title + " · " + item.value + " " + item.status)
    }
}

struct QuotaSidebarRail: View {
    @ObservedObject var controller: QuotaSidebarController
    @ObservedObject var store: CodexUsageStore
    @ObservedObject var quota: AccountQuotaStore
    @ObservedObject var tasks: TaskCompletionMonitor
    @ObservedObject var radar: CodexRadarStore
    @ObservedObject var monitor: LiveRateMonitor
    var quotaItemsOverride: [ClientQuotaItem]? = nil
    @AppStorage(TokenRateScaleSettings.key) private var fullScale = TokenRateScaleSettings.defaultValue
    @AppStorage("cacheHitAdviceEnabled") private var cacheRemindersEnabled = true
    @AppStorage("cacheHitAdviceDismissed") private var dismissedCacheAdviceID = ""
    @ObservedObject private var clients = MultiClientUsageStore.shared
    @ObservedObject private var claudeRuntime = ClaudeLocalRuntime.shared
    @ObservedObject private var upstreamActivity = AgentSpeedDisplayRuntime.shared
    @AppStorage(ActivitySpeedDisplayMode.key) private var speedModeRaw = ActivitySpeedDisplayMode.bar.rawValue
    @AppStorage(ClientDisplayScope.sidebarKey) private var clientScope = "all"
    @AppStorage(ClientQuotaSelection.key) private var quotaSelectionRaw = ""
    private var quotaSelection: ClientQuotaSelection { .decode(quotaSelectionRaw) }
    private var supportsCodex: Bool { clientScope == "codex" || clientScope == "all" }
    private var allowedClients: Set<String> { ClientDisplayScope.clients(clientScope, available: clients.displayClientIDs) }
    private var localLive: ClaudeLocalRuntimeSnapshot { claudeRuntime.projection(allowed: allowedClients) }
    private var liveRates: [ModelRateContribution] { ClientLocalRuntimePresentation.rates(codex: monitor.totalSnapshot.modelRates, claude: localLive.modelRates, allowed: allowedClients, mode: .normalized(speedModeRaw), upstreamCodex: AgentSpeedDisplayRuntime.modelRates(snapshot: upstreamActivity.snapshot, source: .codex, now: Date()), others: upstreamActivity.externalModelRates(allowed: allowedClients)) }
    @ObservedObject private var speedPalette = SpeedDisplayPreferences.shared
    private var barRates: [ModelRateContribution] {
        guard speedPalette.grouping == .client else { return liveRates }
        return allowedClients.sorted().compactMap { client in
            let rates: [ModelRateContribution]
            if client == "codex" { rates = speedModeRaw == "agentSpeed" ? AgentSpeedDisplayRuntime.modelRates(snapshot: upstreamActivity.snapshot, source: .codex, now: Date()) : monitor.totalSnapshot.modelRates }
            else if client == "claudeCode" || client == "claudeDesktop" { rates = claudeRuntime.projection(allowed: [client]).modelRates }
            else { rates = upstreamActivity.externalModelRates(allowed: [client]) }
            let total = rates.reduce(0) { $0 + $1.tokensPerSecond }
            return total > 0 ? .init(model: "client:" + client, tokensPerSecond: total) : nil
        }
    }
    private var liveRate: Double { liveRates.reduce(0) { $0 + $1.tokensPerSecond } }
    private var taskClients: Set<String> { allowedClients.filter { id in
        id == "codex" || clients.preferences.contains { $0.client.rawValue == id && $0.enabled }
    } }
    private var runningSummary: RunningThreadSummary { ClientLocalRuntimePresentation.running(codex: tasks.runningThreadSummary, claude: localLive.running, allowed: taskClients) }
    private var selectedModelRows: [ModelTokenBreakdown] { ClientLocalRuntimePresentation.models(codex: store.todayModelBreakdowns, clients: clients.todaySummaries, allowed: allowedClients) }
    private var availableQuotaItems: [ClientQuotaItem] {
        if let quotaItemsOverride { return quotaItemsOverride }
        let allowed = ClientDisplayScope.clients(clientScope, available: clients.displayClientIDs)
        return ClientQuotaProjection.items(codex: quota.snapshot, claude: clients.quotaReading(.claudeCode),
            includeClaude: clients.availablePreferences.contains { $0.client == .claudeCode || $0.client == .claudeDesktop },
            includeFiveHour: quotaSelection.enabled.contains("codex:5h"), preview: ClientPreviewMode.simulated)
            .filter { allowed.contains($0.client) || ($0.client == "claudeCode" && allowed.contains("claudeDesktop")) }
    }
    @State private var bodySpeedNow = Date().timeIntervalSince1970
    private var recentBodySpeeds: [ModelSpeedSummary] { RecentBodySpeed.readings(monitor.latestModelSpeeds30m, now: bodySpeedNow) }
    private var bodySpeedDeadlineKey: String { (monitor.sidebarBodyMedianSource ?? "") + monitor.latestModelSpeeds30m.map { "\($0.model):\($0.lastMeasuredAt ?? 0):\($0.tokensPerSecond)" }.joined(separator: "|") }
    private var sidebarItems: [QuotaSidebarItem] {
        controller.sidebarLayout.arranged(availableQuotaClients: availableQuotaItems.map(\.client))
            .filter { ((supportsCodex && !recentBodySpeeds.isEmpty) || $0 != .tps) && (supportsCodex || localLive.enabled || !$0.requiresCodexLiveData) }
    }
    private var compactItems: [QuotaSidebarItem] { sidebarItems.filter { controller.sidebarLayout.isVisible($0, in: .compact) } }
    private var expandedItems: [QuotaSidebarItem] { sidebarItems.filter { controller.sidebarLayout.isVisible($0, in: .expanded) } }
    private var quotaItems: [ClientQuotaItem] {
        sidebarItems.flatMap { item -> [ClientQuotaItem] in
            guard case let .quota(client) = item else { return [] }
            return QuotaSidebarContentOrder.quotaWindows(availableQuotaItems, client: client).filter(quotaSelection.includes)
        }
    }
    private func railLayout(_ height: CGFloat) -> ClientRailLayout {
        .fixed(trackCount: QuotaSidebarContentOrder.compactIDs(items: compactItems, quotas: quotaItems).count,
               dotCount: compactItems.filter(\.usesCompactDot).count, availableHeight: Double(height))
    }
    @StateObject private var morphRegistry = MatchedStrokeMorphRegistry()
    @State private var shares: [FloatingTodayModelUsageItem] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var morphEnabled: Bool {
        !reduceMotion && !controller.isDragging && cacheWarning == nil && sidebarItems.contains {
            switch $0 { case .speed, .tasks, .quota: true; default: false }
        }
    }

    private var disclosureFade: Animation? {
        guard !reduceMotion else { return nil }
        // Labels emerge while the ring is taking shape, rather than becoming
        // opaque in 60ms. Use the same endpoints as the native reveal, without
        // delayed tasks that could survive a quick pointer reversal.
        return controller.interaction.expanded
            ? .timingCurve(0.35, 0, 0.2, 1, duration: MatchedStrokeMorphTiming.standard.openingDuration)
            : .timingCurve(1.0 / 3, 1, 2.0 / 3, 1, duration: MatchedStrokeMorphTiming.standard.closingDuration)
    }

    private func morphRoutes(_ anchors: [String: Anchor<CGRect>], in proxy: GeometryProxy) -> [ClientQuotaMorphRoute] {
        let viewport = anchors["quota-viewport"].map { proxy[$0] }
        var routes = ClientQuotaRingGroup.make(quotaItems).flatMap { group -> [ClientQuotaMorphRoute] in
            let members = [(group.left, group.right == nil ? 0 : -1)] + (group.right.map { [($0, 1)] } ?? [])
            return members.compactMap { entry -> ClientQuotaMorphRoute? in
                let (item, half) = entry
                guard let source = anchors["ring:" + item.id], let target = anchors["track:" + item.id] else { return nil }
                let ring = proxy[source], track = proxy[target]
                guard viewport?.contains(ring) != false else { return nil }
                return ClientQuotaMorphRoute(id: item.id, ring: ring, track: track, half: half,
                    fraction: item.remaining.map { $0 / 100 }, color: NSColor(clientHex: quotaSelection.colors[item.id] ?? item.fill),
                    marker: anchors["marker:" + item.id].map { proxy[$0] }, markerColor: NSColor(clientHex: item.brand), expected: item.expected)
            }
        }
        for item in [QuotaSidebarItem.speed, .tasks, .models] where sidebarItems.contains(item) {
            guard let source = anchors[(item == .models ? "strip:" : "ring:") + item.id], let target = anchors["track:" + item.id] else { continue }
            let ring = proxy[source], track = proxy[target]
            guard viewport?.contains(ring) != false else { continue }
            if item == .models {
                var edge = 0.0
                let segments = shares.map { item in
                    let start = edge; edge += item.share
                    return ClientQuotaMorphColorSegment(id: item.id, start: start, end: edge, color: NSColor(item.color))
                }
                routes.append(ClientQuotaMorphRoute(id: item.id, ring: ring, track: track, half: 0, fraction: 1,
                    color: .gray, segments: segments, shape: .strip))
            } else if item == .speed {
                var edge = 0.0
                let segments = ModelRatePresentation.slices(liveRates).map { slice in
                    let start = edge; edge += slice.share
                    return ClientQuotaMorphColorSegment(id: "model:" + slice.model, start: start, end: edge, color: NSColor(slice.color))
                }
                routes.append(ClientQuotaMorphRoute(id: item.id, ring: ring, track: track, half: 0,
                    fraction: rateFraction, color: NSColor(ModelUsagePresentation.color(for: "unknown")), segments: segments))
            } else {
                routes.append(ClientQuotaMorphRoute(id: item.id, ring: ring, track: track, half: 0, fraction: 1,
                    color: NSColor(SidebarPalette.amber), expandedTrackOpacity: 0, collapsedTrackOpacity: 0, fillOpacity: 0.5))
            }
        }
        return routes
    }

    private var cacheWarning: CacheUsageAdvice? {
        guard CacheMissReminderFeature.isEnabled, monitor.monitoringEnabled, monitor.displayRateAvailable,
              let advice = monitor.totalSnapshot.cacheAdvice,
              advice.shouldRemind(enabled: cacheRemindersEnabled, dismissedID: dismissedCacheAdviceID) else { return nil }
        return advice
    }

    var body: some View {
        ZStack(alignment: controller.edge == .right ? .trailing : .leading) {
            Group {
                if let advice = cacheWarning {
                    cacheNotice(advice)
                        .frame(height: controller.expandedContentHeight)
                        .transition(.opacity)
                } else {
                VStack(spacing: 7) {
                    HStack(spacing: 4) {
                        Button { controller.togglePin() } label: {
                            Image(systemName: controller.interaction.pinned ? "pin.fill" : "pin")
                                .foregroundStyle(controller.interaction.pinned ? SidebarPalette.green : .gray)
                                .frame(width: 24, height: 24).contentShape(Rectangle())
                        }.help(controller.interaction.pinned ? "取消固定" : "固定")
                            .accessibilityLabel(controller.interaction.pinned ? "取消固定" : "固定")
                            .accessibilityIdentifier("quota-sidebar-pin")
                        Button { quota.refresh(force: true) } label: {
                            Image(systemName: "arrow.clockwise").foregroundStyle(.gray)
                                .frame(width: 24, height: 24).contentShape(Rectangle())
                        }.help("刷新额度与重置卡").accessibilityLabel("刷新数据")
                            .accessibilityIdentifier("quota-sidebar-refresh")
                        Button { controller.openDashboard() } label: {
                            Image(systemName: "macwindow").foregroundStyle(.gray)
                                .frame(width: 24, height: 24).contentShape(Rectangle())
                        }.help("打开主页面").accessibilityLabel("打开主页面")
                            .accessibilityIdentifier("quota-sidebar-dashboard")
                    }.font(.system(size: 12)).buttonStyle(SidebarPulseButtonStyle())
                    ScrollView(.vertical) {
                        VStack(spacing: 7) {
                            ForEach(expandedItems) { item in
                                moduleContent(item, shares: shares)
                                    .background {
                                        RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(controller.settingsHighlightedItem == item && controller.interaction.detail == .settings ? 0.055 : 0))
                                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(SidebarPalette.green.opacity(controller.settingsHighlightedItem == item && controller.interaction.detail == .settings ? 0.55 : 0), lineWidth: 1))
                                    }
                            }
                        }.frame(width: 88).fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: QuotaSidebarContentMeasurementKey.self,
                                    value: QuotaSidebarContentMeasurement(contentHeight: proxy.size.height + 66))
                            })
                    }.scrollIndicators(.hidden).frame(maxHeight: .infinity)
                        .transformAnchorPreference(key: ClientQuotaMorphAnchors.self, value: .bounds) { values, anchor in values["quota-viewport"] = anchor }
                    Button { controller.select(.settings) } label: {
                        Label("侧栏设置", systemImage: "slider.horizontal.3")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                            .frame(width: 74, height: 28).contentShape(Rectangle())
                    }.buttonStyle(SidebarPulseButtonStyle())
                        .help("调整侧栏模块显示与顺序")
                        .accessibilityIdentifier("quota-sidebar-settings")
                }.padding(.vertical, 12)
                    .frame(width: 88, height: controller.expandedContentHeight)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
                }
            }
            // Opacity alone leaves every numeric/ring animation running in
            // the clipped 88pt canvas. Keep measurement/data alive while making
            // the invisible menu's updates immediate and animation-free.
            .transaction { transaction in
                if !controller.interaction.expanded {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            .opacity(controller.interaction.expanded ? 1 : 0)
            .animation(disclosureFade, value: controller.interaction.expanded)
            .allowsHitTesting(controller.interaction.expanded)
            .accessibilityHidden(!controller.interaction.expanded)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: monitor.latestModelSpeeds30m.count)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controller.sidebarLayout)
            Group {
                GeometryReader { geometry in
                    let layout = railLayout(geometry.size.height)
                    ScrollView(.vertical) {
                        QuotaSidebarCompactBars(items: compactItems, quotas: quotaItems, layout: layout,
                            rateFraction: Double(rateFraction),
                            modelRates: barRates, shares: shares, taskStateLabel: "任务状态：" + runningText + "，非进度百分比", colors: quotaSelection.colors,
                            usesMorphAnchors: true)
                            .frame(minHeight: geometry.size.height)
                    }.scrollIndicators(.hidden)
                }.frame(width: 16).frame(maxHeight: .infinity)
                    .overlay(alignment: .center) {
                        if let advice = cacheWarning {
                            Circle().fill(.orange).frame(width: 6, height: 6)
                                .offset(y: quota.snapshot.fiveHour == nil ? -89 : -118)
                                .allowsHitTesting(false)
                                .help("缓存命中偏低 · \(advice.displayTitle)")
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(cacheWarning.map { "缓存命中偏低，\($0.displayTitle)，悬停查看提醒" } ?? "额度侧栏，实时速率\(rateText)，悬停展开简略信息，可拖动调整位置")
                    .contentShape(Rectangle())
                    .onTapGesture { controller.enter() }
            }
            .opacity(controller.interaction.expanded ? 0 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: controller.interaction.expanded)
            .allowsHitTesting(!controller.interaction.expanded)
            .accessibilityHidden(controller.interaction.expanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: controller.edge == .right ? .trailing : .leading)
        .background(SidebarPalette.background)
        .overlayPreferenceValue(ClientQuotaMorphAnchors.self) { anchors in
            GeometryReader { proxy in
                ClientQuotaMorphSurface(expanded: controller.interaction.expanded, enabled: morphEnabled,
                    routes: morphRoutes(anchors, in: proxy))
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .task(id: bodySpeedDeadlineKey) {
            bodySpeedNow = Date().timeIntervalSince1970
            while !Task.isCancelled, let expiry = RecentBodySpeed.nextExpiry(monitor.latestModelSpeeds30m, now: bodySpeedNow) {
                do { try await Task.sleep(for: .seconds(max(0.002, expiry - Date().timeIntervalSince1970))) } catch { return }
                bodySpeedNow = Date().timeIntervalSince1970
            }
        }
        .onChange(of: recentBodySpeeds.map(\.model)) { _, _ in updateCompactLayout() }
        .onChange(of: selectedModelRows, initial: true) { _, rows in
            shares = FloatingTodayModelUsagePresentation.items(from: rows,
                fallbackModel: .gpt56Sol, mergeAutoReview: false).filter { $0.share > 0 }
        }
        .onChange(of: quotaItems, initial: true) { _, _ in updateCompactLayout() }
        .onChange(of: controller.sidebarLayout) { _, _ in updateCompactLayout() }
        .onChange(of: controller.availableRailHeight) { _, _ in updateCompactLayout() }
        .onPreferenceChange(QuotaSidebarContentMeasurementKey.self) { controller.updateContentMeasurement($0) }
        .clipShape(QuotaSidebarEdgeShape(edge: controller.edge))
        .foregroundStyle(.white)
        .onHover { if $0 { controller.enter() } }
        .environment(\.matchedStrokeMorphRegistry, morphEnabled ? morphRegistry : nil)
        .onChange(of: cacheWarning?.presentationID, initial: true) { _, id in controller.updateCacheAdvice(id) }
    }

    private func updateCompactLayout() {
        let layout = railLayout(controller.availableRailHeight)
        controller.updateCompactHeight(layout.height)
    }

    @ViewBuilder
    private func moduleContent(_ item: QuotaSidebarItem, shares: [FloatingTodayModelUsageItem]) -> some View {
        switch item {
        case .speed:
            rateRing
            ActivitySpeedSummaryView(allowed: allowedClients, compact: true, onOpen: { controller.select(.speeds, section: "activity-speed-curve") })
        case .tps:
            if supportsCodex {
                QuotaSidebarBodySpeedReadings(monitor: monitor, latest: recentBodySpeeds, active: controller.interaction.expanded, onOpen: { controller.select(.speeds) })
            }

        case .clientUsage:
            VStack(spacing: 5) {
                Text("累计 Token").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                MultiClientUsageSidebarRows(codexTokens: Int64(store.snapshot.stats.totalTokens),
                    onOpen: { controller.select(.overview, section: "usage") })
            }
        case .modeltrace:
            Button { controller.select(.modeltrace) } label: {
                Label("模型检测", systemImage: "checkmark.shield")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(SidebarPalette.green)
                    .frame(width: 74, height: 28).contentShape(Rectangle())
            }.buttonStyle(SidebarPulseButtonStyle()).help("打开 ModelTrace，手动检测模型")
                .accessibilityIdentifier("quota-sidebar-modeltrace")
        case let .quota(client):
            ForEach(ClientQuotaRingGroup.make(quotaItems.filter { $0.client == client })) { group in
                Button { controller.select(.overview) } label: {
                    ClientPairedQuotaRing(left: group.left, right: group.right)
                }.buttonStyle(SidebarPulseButtonStyle())
            }
        case .models:
            Button { controller.select(.overview, section: "models") } label: {
                VStack(spacing: 6) {
                    MatchedStrokeMorphParticipant(ids: ["models"], size: CGSize(width: 52, height: 4)) {
                        SidebarModelShareStrip(items: shares).frame(width: 52, height: 4)
                    }.anchorPreference(key: ClientQuotaMorphAnchors.self, value: .bounds) { ["strip:models": $0] }
                    Text("模型占比").font(.system(size: 9)).foregroundStyle(.gray)
                }.frame(maxWidth: .infinity, minHeight: 30).contentShape(Rectangle())
            }.buttonStyle(SidebarPulseButtonStyle())
        case .tasks:
            Button { controller.select(.tasks) } label: {
                VStack(spacing: 5) {
                    ZStack {
                        MatchedStrokeMorphParticipant(ids: ["tasks"], size: CGSize(width: ClientSidebarMetrics.ringSize, height: ClientSidebarMetrics.ringSize)) {
                            Circle().stroke(SidebarPalette.amber.opacity(0.5), lineWidth: 3)
                        }.anchorPreference(key: ClientQuotaMorphAnchors.self, value: .bounds) { ["ring:tasks": $0] }
                        Text(runningSummary.freshness == .fresh ? "\(runningSummary.total)" : "—").font(.system(size: 18, weight: .medium, design: .rounded)).foregroundStyle(SidebarPalette.amber)
                    }.frame(width: ClientSidebarMetrics.ringSize, height: ClientSidebarMetrics.ringSize)
                    Text(runningText).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: runningText)
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.vertical, 0)
                .contentShape(Rectangle())
            }.buttonStyle(SidebarPulseButtonStyle())
                .accessibilityLabel("查看任务，\(runningText)")
                .help("所选客户端的本地主任务与子 Agent；过期活动标记为未知")
                .accessibilityIdentifier("quota-sidebar-tasks")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { controller.select(.tasks) }
        case .radar:
            let recommendations = QuotaSidebarRadarPresentation.rankedModels(radar.crowdSnapshot)
            QuotaSidebarRecommendations(models: recommendations, stale: radar.crowdStaleDataDisplayed) {
                controller.select(.radar, section: "ranking")
            }.id(recommendations.map(\.id))
            Rectangle().fill(.white.opacity(0.13)).frame(width: 52, height: 1)
            TimelineView(QuotaSidebarRadarPresentation.schedule(radar.snapshot, updatedAt: radar.lastSuccessfulRefreshAt)) { tick in
                let state = QuotaSidebarRadarPresentation.windowState(radar.snapshot, stale: radar.staleDataDisplayed, updatedAt: radar.lastSuccessfulRefreshAt, now: tick.date)
                Button { controller.select(.radar) } label: {
                    VStack(spacing: 4) {
                        Text(state.text)
                        if state.active, let end = CodexRadarPresentationText.countdownDeadline(snapshot: radar.snapshot), end > tick.date {
                            Text(CodexRadarPresentationText.actionDisplay(snapshot: radar.snapshot, now: tick.date).replacingOccurrences(of: "速登 ", with: ""))
                                .monospacedDigit()
                        }
                    }.font(.system(size: 10)).foregroundStyle(state.active ? .red : .gray)
                        .frame(maxWidth: .infinity).contentShape(Rectangle().inset(by: -10))
                }.buttonStyle(SidebarPulseButtonStyle())
            }
        case .credits:
            if quota.snapshot.resetCreditsAvailableCount != nil {
                Button { controller.select(.credits) } label: {
                    VStack(spacing: 2) {
                        Text("重置卡 \(quota.snapshot.availableResetCreditCount) 张").foregroundStyle(SidebarPalette.amber)
                        if let card = quota.snapshot.nearestFutureExpiringResetCredit, let expires = card.expiresAt {
                            Text(expires.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                                .font(.system(size: 8)).foregroundStyle(.gray).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }.font(.system(size: 9)).frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(SidebarPulseButtonStyle())
            }
        }
    }

    private func cacheNotice(_ advice: CacheUsageAdvice) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 7) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 22, weight: .medium))
                Text("缓存命中\n偏低")
                    .font(.system(size: 13, weight: .semibold)).lineSpacing(2)
            }.accessibilityElement(children: .combine)
            VStack(spacing: 3) {
                Text(String(format: "%.1f", advice.hitRate * 100) + "%")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.8).lineLimit(1)
                Text("本次请求").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("相关会话").font(.system(size: 10)).foregroundStyle(SidebarPalette.amber.opacity(0.8))
                    Text(advice.displayTitle).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95)).fixedSize(horizontal: false, vertical: true)
                        .help(advice.displayTitle)
                    if advice.affectedThreads > 1 {
                        Text("等 \(advice.affectedThreads) 个会话").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                    }
                    Rectangle().fill(SidebarPalette.amber.opacity(0.2)).frame(height: 1)
                    Text("本次请求的缓存复用较少。可能与切换模型或上下文变化有关，请检查最近的相关操作。")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
            }.scrollIndicators(.automatic).frame(maxHeight: .infinity)
            VStack(spacing: 6) {
                Button { controller.select(.overview, section: "usage") } label: {
                    HStack(spacing: 3) {
                        Text("查看详情")
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    }.font(.system(size: 10)).frame(maxWidth: .infinity, minHeight: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("查看缓存命中详情，\(advice.displayTitle)")
                    .accessibilityIdentifier("quota-sidebar-cache-advice")
                Button {
                    dismissedCacheAdviceID = advice.presentationID
                    controller.dismiss()
                } label: {
                    Label("关闭提醒", systemImage: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(SidebarPalette.amber.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(SidebarPalette.amber.opacity(0.65)))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help("关闭本次提醒；点击侧栏外也可收起")
                    .accessibilityLabel("关闭本次缓存提醒")
                Text("点击外部\n也可收起").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
            }
        }.multilineTextAlignment(.center).foregroundStyle(SidebarPalette.amber)
            .padding(.horizontal, 8).padding(.vertical, 24)
            .frame(width: 88).frame(maxHeight: .infinity)
            .background(SidebarPalette.amber.opacity(0.06))
    }

    private var rateRing: some View {
        Button { controller.select(.speeds) } label: {
            VStack(spacing: 5) {
                ZStack {
                    MatchedStrokeMorphParticipant(ids: ["speed"], size: CGSize(width: ClientSidebarMetrics.ringSize, height: ClientSidebarMetrics.ringSize)) {
                        SidebarValueRing(fraction: rateFraction, color: SidebarPalette.blue, modelRates: barRates)
                    }.anchorPreference(key: ClientQuotaMorphAnchors.self, value: .bounds) { ["ring:speed": $0] }
                    Text("速率").font(.system(size: 11))
                }.frame(width: ClientSidebarMetrics.ringSize, height: ClientSidebarMetrics.ringSize)
                Text(rateText).font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: rateText)
            }
            .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 0).contentShape(Rectangle())
        }.buttonStyle(SidebarPulseButtonStyle())
            .accessibilityLabel("全会话实时速率（估算）\(rateText)，点击查看详情")
            .accessibilityIdentifier("quota-sidebar-rate")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { controller.select(.speeds) }
    }

    private var rateFraction: CGFloat {
        CGFloat(QuotaSidebarRatePresentation.fraction(rate: liveRate,
            fullScale: fullScale, available: (supportsCodex && monitor.monitoringEnabled && monitor.dataSource != nil) || localLive.sourceAvailable))
    }

    private var rateText: String {
        guard monitor.monitoringEnabled || localLive.enabled else { return "已关闭" }
        guard (supportsCodex && monitor.dataSource != nil) || localLive.sourceAvailable else { return "待读取" }
        return "\(LiveRateSnapshot.rateDisplayText(liveRate)) tok/s"
    }

    private var runningText: String {
        let summary = runningSummary
        switch summary.freshness {
        case .fresh: return "\(summary.main) 主 · \(summary.subagents) 子"
        case .stale:
            let issue = ClientLocalRuntimePresentation.taskSourceIssue(codex: tasks.runningThreadSummary,
                claude: localLive.running, allowed: taskClients) ?? "上次数据"
            return "\(summary.total) 运行\n\(issue)"
        case .loading: return "读取任务中"
        case .unavailable: return "任务未知"
        }
    }


}

struct SidebarPulseButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background {
            RoundedRectangle(cornerRadius: 11).fill(.white.opacity(configuration.isPressed ? 0.22 : 0))
                .animation(configuration.isPressed ? nil : .easeOut(duration: reduceMotion ? 0.12 : 0.38), value: configuration.isPressed)
        }
    }
}

private struct SidebarModelShareStrip: View {
    let items: [FloatingTodayModelUsageItem]
    var vertical = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Capsule().fill(.white.opacity(0.12))
                if vertical {
                    VStack(spacing: 0) {
                        ForEach(items) { item in item.color.frame(height: geometry.size.height * item.share) }
                    }
                } else {
                    HStack(spacing: 0) {
                        ForEach(items) { item in item.color.frame(width: geometry.size.width * item.share) }
                    }
                }
            }.clipShape(Capsule())
                .animation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.34), value: items)
        }.help(items.isEmpty ? "今日模型占比待读取" : "今日模型 Token 占比：" + items.map { $0.label + " " + $0.valueText(for: .share) }.joined(separator: "，"))
    }
}

struct QuotaSidebarDetailView: View {
    @ObservedObject private var clients = MultiClientUsageStore.shared
    @ObservedObject private var claudeRuntime = ClaudeLocalRuntime.shared
    @ObservedObject private var upstreamActivity = AgentSpeedDisplayRuntime.shared
    @AppStorage(ActivitySpeedDisplayMode.key) private var speedModeRaw = ActivitySpeedDisplayMode.bar.rawValue
    @State private var clientProjectionCache = ClientDashboardProjectionCache()
    @AppStorage(ClientDisplayScope.sidebarKey) private var clientScope = "all"

    @ObservedObject var controller: QuotaSidebarController
    @ObservedObject var store: CodexUsageStore
    @ObservedObject var monitor: LiveRateMonitor
    @ObservedObject var quota: AccountQuotaStore
    @ObservedObject var tasks: TaskCompletionMonitor
    @ObservedObject var radar: CodexRadarStore
    @ObservedObject var history: QuotaHistoryStore
    var quotaItemsOverride: [ClientQuotaItem]? = nil

    private var allowedClients: Set<String> { ClientDisplayScope.clients(clientScope, available: clients.displayClientIDs) }
    private var selectedRunning: RunningThreadSummary {
        let taskClients = allowedClients.filter { id in
            id == "codex" || clients.preferences.contains { $0.client.rawValue == id && $0.enabled }
        }
        return ClientLocalRuntimePresentation.running(codex: tasks.runningThreadSummary,
            claude: claudeRuntime.projection(allowed: taskClients).running, allowed: taskClients)
    }
    var body: some View {
        // Capture one projection for every quota, usage and running field in
        // this render, so the cards and the model denominator agree.
        let snapshot = TokenDisplaySnapshot.make(store: store, monitor: monitor, quota: quota,
                                                  runningThreads: selectedRunning)
        VStack(alignment: .leading, spacing: 6) {
            header(snapshot.quota)
            if monitor.monitoringEnabled {
                CacheUsageAdviceView(monitor: monitor)
            }
            HStack(spacing: 12) {
                tab("额度概览", detail: .overview)
                tab("测速", detail: .speeds)
                tab("任务", detail: .tasks)
                tab("雷达", detail: .radar)
                tab("重置卡", detail: .credits)
                tab("模型检测", detail: .modeltrace)
                Spacer(minLength: 0)
                Button { controller.select(.settings) } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12))
                        .foregroundStyle(controller.interaction.detail == .settings ? SidebarPalette.green : .gray)
                }.buttonStyle(SidebarPulseButtonStyle()).help("侧栏设置").accessibilityLabel("侧栏设置")
            }
            Divider().overlay(.white.opacity(0.12))
            ScrollViewReader { proxy in
            ScrollView {
                if controller.interaction.detail == .settings {
                    QuotaSidebarModuleSettingsView(controller: controller, quotaSnapshot: quota.snapshot, monitor: monitor, modelShares: snapshot.todayModelBreakdowns, quotaItemsOverride: quotaItemsOverride).id("top")
                }
                else if controller.interaction.detail == .speeds {
                    if clientScope == "codex" || clientScope == "all" {
                    if clientScope == "all" { Text("Codex · 正文 TPS").font(.caption).foregroundStyle(.secondary) }
                    Text("Codex · 正文 TPS").font(.caption.weight(.semibold)).id("top")
                    Divider().overlay(.white.opacity(0.12))
                    ObservedSpeedSidebarView(monitor: monitor, quotaHistory: history.snapshot, onOpenDetails: {
                        BodySpeedHistoryWindowController.shared.present(monitor: monitor,
                            screen: controller.detailPanel?.screen ?? controller.railPanel?.screen)
                    })
                    }
                    SpeedDisplayControls()
                    ActivitySpeedSummaryView(allowed: allowedClients).id("activity-speed-curve")
                }
                else if controller.interaction.detail == .modeltrace {
                    ModelTraceView(controller: ModelTraceController.shared, compact: true).id("top")
                }
                else if controller.interaction.detail == .tasks { taskContent(snapshot.runningThreads) }
                else if controller.interaction.detail == .credits { resetCreditList(snapshot.quota).id("top") }
                else if controller.interaction.detail == .radar {
                    QuotaSidebarRadarContent(snapshot: radar.snapshot, crowd: radar.crowdSnapshot,
                                             officialStale: radar.staleDataDisplayed,
                                             crowdStale: radar.crowdStaleDataDisplayed,
                                             status: radar.status, updatedAt: radar.lastSuccessfulRefreshAt, initialShowsCrowd: controller.detailScrollTarget == "ranking")
                        .id("radar-content-" + controller.detailScrollTarget)
                } else { overview(snapshot) }
            }.scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(controller.detailScrollTarget, anchor: .top) }
                .onChange(of: controller.detailScrollRevision) { _, _ in proxy.scrollTo(controller.detailScrollTarget, anchor: .top) }
            }
            activitySummary(snapshot.runningThreads)
            Text(controller.interaction.pinned ? "已固定 · 点击关闭收起" : "移出后收起 · 图钉固定详情")
                .font(.system(size: 9)).foregroundStyle(.gray)
        }
        .padding(.horizontal, 18).padding(.vertical, 14).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SidebarPalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12), lineWidth: 1))
        .foregroundStyle(.white)
        .onHover { if $0 { controller.enter() } }
    }

    private func header(_ quota: AccountQuotaSnapshot) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "terminal").font(.system(size: 22)).foregroundStyle(SidebarPalette.green)
                .padding(9).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ClientDisplayScope.title(clientScope)).font(.system(size: 19, weight: .semibold))
                    if clientScope == "codex" || clientScope == "all" {
                    Text((clientScope == "all" ? "Codex · " : "") + quota.displayName).font(.system(size: 9, weight: .semibold))
                        .lineLimit(1).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(SidebarPalette.green.opacity(0.12), in: Capsule())
                        .foregroundStyle(SidebarPalette.green)
                    }
                }
                Text(clientScope == "codex" || clientScope == "all" ? quota.accountDisplayName : "本地记录 · 额度来源独立").font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Text(clientScope == "codex" || clientScope == "all" ? quota.updatedAt.map { "Codex 额度更新 \($0.formatted(date: .omitted, time: .shortened))" } ?? "Codex 额度尚未读取" : "额度仅来自本地缓存")
                    .font(.system(size: 9)).foregroundStyle(.gray)
            }
            Spacer(minLength: 0)
            Button { controller.openDashboard() } label: {
                Image(systemName: "macwindow")
                    .foregroundStyle(.gray)
            }.help("打开主界面").accessibilityLabel("打开主界面")
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

    private func detailQuotaItems(_ quota: AccountQuotaSnapshot) -> [ClientQuotaItem] {
        let allowed = ClientDisplayScope.clients(clientScope, available: clients.displayClientIDs)
        return ClientQuotaProjection.items(codex: quota, claude: clients.quotaReading(.claudeCode),
            includeClaude: allowed.contains("claudeCode") || allowed.contains("claudeDesktop"), preview: ClientPreviewMode.simulated)
            .filter { allowed.contains($0.client) || ($0.client == "claudeCode" && allowed.contains("claudeDesktop")) }
    }

    @ViewBuilder
    private func overview(_ snapshot: TokenDisplaySnapshot) -> some View {
        let allowed = ClientDisplayScope.clients(clientScope, available: clients.displayClientIDs)
        if allowed == ["codex"] { codexOverview(snapshot) }
        else {
            let display = clientProjectionCache.value(codex: store.snapshot, clients: clients, allowed: allowed)
            let today = clients.todaySummaries.filter { allowed.contains($0.client.rawValue) }
            let todayRows = (allowed.contains("codex") ? snapshot.todayModelBreakdowns : []) + today.map { row in
                ModelTokenBreakdown(model: row.model, breakdown: .init(inputTokens: Int(row.inputTokens), cachedInputTokens: Int(row.cacheReadTokens ?? 0), outputTokens: Int(row.outputTokens), reasoningOutputTokens: Int(row.reasoningTokens ?? 0), totalTokens: Int(row.inputTokens + row.outputTokens), calls: row.requests))
            }
            let scoped = TokenDisplaySnapshot(title: ClientDisplayScope.title(clientScope), status: "本地统计",
                rate: allowed.contains("codex") ? snapshot.rate : 0,
                consumedTokens: display.stats.totalTokens,
                todayTokens: todayRows.map(\.breakdown).combined.totalTokens,
                todayRequests: todayRows.map(\.breakdown).combined.calls, todayModelBreakdowns: todayRows,
                quota: snapshot.quota, updatedAt: display.generatedAt)
            codexOverview(scoped, projected: display)
        }
    }

    private func codexOverview(_ snapshot: TokenDisplaySnapshot, projected: DashboardSnapshot? = nil) -> some View {
        let total = snapshot.todayModelBreakdowns.map(\.breakdown).combined
        let models = FloatingTodayModelUsagePresentation.items(from: snapshot.todayModelBreakdowns, fallbackModel: .gpt56Sol, mergeAutoReview: false).filter { $0.share > 0 }
        let cost = FloatingTodayModelUsagePresentation.knownCostUSD(in: models)
        let costLabel = models.contains { !$0.isReferenceOnly && $0.costUSD == nil } ? "今日 API 等值 · 已知小计" : "今日 API 等值"

        return VStack(alignment: .leading, spacing: 6) {
            ClientQuotaRings(items: detailQuotaItems(snapshot.quota)).id("top")
            if let pace = snapshot.quota.sevenDayPaceStatus {
                Text(pace.compactDetail).font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Color.clear.frame(height: 0).id("usage")
                sectionTitle("用量", subtitle: "本地统计")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), alignment: .leading, spacing: 7) {
                    metric("今日 Tokens", snapshot.todayTokensText, color: SidebarPalette.green)
                    metric("累计 Tokens", snapshot.consumedTokensText, color: .white)
                    metric("今日缓存命中", total.inputTokens > 0 ? String(format: "%.1f%%", Double(total.cachedInputTokens) / Double(total.inputTokens) * 100) : "—", color: SidebarPalette.purple)
                    metric(costLabel, models.isEmpty ? "—" : (cost?.quotaEstimatorMoneyText ?? "—"), color: SidebarPalette.green)
                    metric("今日请求", snapshot.todayRequestsText, color: .white)
                    metric("实时 Tokens / 秒", LiveRateSnapshot.rateDisplayText(snapshot.rate), color: SidebarPalette.amber)
                }
                if let diagnostic = snapshot.metadataOnlyStatusText {
                    Text(diagnostic).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1).help(diagnostic)
                }
                Text("实时：\(snapshot.status)").font(.system(size: 9)).foregroundStyle(.gray).lineLimit(1).help(snapshot.status)
            }
            modelUsage(snapshot).id("models")
            SidebarTrendView(bins: Array((projected ?? store.snapshot).recentBins.suffix(288)), quota: projected == nil ? Array(history.snapshot.recentBins.suffix(288)) : [])
            tokenComposition(snapshot)
        }.padding(.bottom, 2)
    }

    private func tokenComposition(_ snapshot: TokenDisplaySnapshot) -> some View {
        let total = snapshot.todayModelBreakdowns.map(\.breakdown).combined
        let parts: [(String, Int, Color)] = [
            ("未缓存输入", max(0, total.inputTokens - total.cachedInputTokens), .init(red: 0.47, green: 0.72, blue: 1)),
            ("缓存输入", total.cachedInputTokens, SidebarPalette.purple),
            ("输出", total.outputTokens, SidebarPalette.green)
        ]
        let denominator = max(1, parts.reduce(0) { $0 + $1.1 })
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("今日 Token 构成", subtitle: "缓存包含在输入内")
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(parts.indices, id: \.self) { index in
                        Rectangle().fill(parts[index].2)
                            .frame(width: geometry.size.width * Double(parts[index].1) / Double(denominator))
                    }
                }
            }.frame(height: 8).background(.white.opacity(0.1)).clipShape(Capsule())
            HStack {
                ForEach(parts.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(parts[index].0).font(.system(size: 9)).foregroundStyle(parts[index].2)
                        Text(snapshot.todayModelBreakdowns.isEmpty ? "—" : parts[index].1.abbreviatedTokens)
                            .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            
        }.padding(8).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func resetCreditList(_ quota: AccountQuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("重置卡", subtitle: "可用 \(quota.availableResetCreditCount) 张")
            if quota.sortedResetCreditsForDisplay.isEmpty {
                Text(quota.resetCreditStatus).font(.system(size: 10)).foregroundStyle(.gray)
            }
            ForEach(Array(quota.sortedResetCreditsForDisplay.enumerated()), id: \.element.id) { index, card in
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text("重置卡 \(index + 1)"); Spacer(); Text(card.statusText).foregroundStyle(card.isAvailable ? SidebarPalette.amber : .gray) }
                    Text("发放  " + card.detailedGrantedText).foregroundStyle(.gray)
                    Text("到期  " + card.detailedExpiryText).foregroundStyle(.gray)
                    if let redeemed = card.detailedRedeemedText { Text("使用  " + redeemed).foregroundStyle(.gray) }
                }.font(.system(size: 10)).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer()
            Text(subtitle).font(.system(size: 9)).foregroundStyle(.gray)
        }
    }

    private func modelUsage(_ snapshot: TokenDisplaySnapshot) -> some View {
        let items = Array(FloatingTodayModelUsagePresentation.items(from: snapshot.todayModelBreakdowns, fallbackModel: .gpt56Sol, mergeAutoReview: false).filter { $0.share > 0 })
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("今日模型用量", subtitle: "Token 占比 · API 等值")
            if items.isEmpty {
                Text("尚无可信的今日模型明细").font(.system(size: 11)).foregroundStyle(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            } else {
                ForEach(items) { item in
                    VStack(spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(item.color).frame(width: 5, height: 5)
                            Text(item.label).font(.system(size: 10, weight: .medium)).lineLimit(1).help(item.label)
                            Spacer(minLength: 0)
                            Text(item.tokens.abbreviatedTokens).foregroundStyle(.white.opacity(0.8))
                            Text(String(format: "%.1f%%", item.share * 100)).foregroundStyle(.gray).frame(width: 42, alignment: .trailing)
                        }.font(.system(size: 10)).monospacedDigit()
                        HStack {
                            Spacer()
                            Text("API 等值 " + item.valueText(for: .cost)).font(.system(size: 9)).foregroundStyle(.gray)
                        }
                        SidebarValueBar(fraction: item.share, color: item.color, emphasis: 0.7).frame(height: 3)
                    }
                }
            }
        }.padding(8).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
    }

    private func metric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 16, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(.gray)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
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
            }.padding(8).background(SidebarPalette.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topTrailing) {
                    if summary.freshness == .stale { Text("刷新未成功").font(.system(size: 8)).foregroundStyle(.orange).padding(4) }
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
                    VStack(alignment: .leading, spacing: 6) {
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
                    }.padding(8).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
                }
                if summary.total == 0 {
                    taskNotice("当前没有运行中的任务", icon: "checkmark.circle")
                } else if summary.groups.isEmpty && summary.unassignedSubagents.isEmpty {
                    taskNotice("已读取运行数量，尚无任务层级明细", icon: "list.bullet.rectangle")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                taskBadge("主任务", color: SidebarPalette.amber)
                Spacer()
                Text("\(group.subagents.count) 个子代理").font(.system(size: 9)).foregroundStyle(.gray)
            }
            taskIdentity(group.mainThread, titleSize: 13)
            if !group.subagents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(SidebarPalette.purple)
                taskBadge("子代理", color: SidebarPalette.purple)
            }
            taskIdentity(member, titleSize: 11)
        }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
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
