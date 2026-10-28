import AgentSpeedCore
import Combine
import Foundation

@MainActor
protocol AgentSpeedReportingMonitor: AnyObject { func start(); func stop() }
extension AgentSpeedCore.LiveMonitor: AgentSpeedReportingMonitor {}

/// Consent, identity and network lifetime around the pinned upstream measurement core.
/// No use of Token Bar's body samples, animated curve, quota ledger or account credentials.
@MainActor
final class AgentSpeedReportingController: ObservableObject {
    static let shared = AgentSpeedReportingController()
    static let enabledKey = "agentSpeedReporting.enabled.v1"
    static let invitationKey = "agentSpeedReporting.invitationShown.v1"
    static let usernameKey = "agentSpeedReporting.username.v1"
    static let deviceKey = "agentSpeedReporting.device.v1"
    static let serviceURL = "https://deng.codexradar.com"
    static let apiURL = "https://speed-api.codexradar.com/api/agent-speed"
    static let website = URL(string: serviceURL + "/")!
    /// Claude remains available to local collection; this reporting monitor never reads either Claude source.
    static let deniedReportingSources: Set<SourceKind> = [.claudeCode, .claudeDesktop]
    static let reportableSources = Set(SourceKind.allCases.filter { !deniedReportingSources.contains($0) })

    struct Source: Identifiable, Equatable {
        let id: String
        let name: String
        let tps: Double
    }
    @Published private(set) var enabled: Bool
    @Published private(set) var username: String
    @Published private(set) var message = "未参加 · 采集与上报已关闭"
    @Published private(set) var phase = "off"
    @Published private(set) var liveOutputTps = 0.0
    @Published private(set) var estimatedShare = 0.0
    @Published private(set) var sources: [Source] = []
    @Published private(set) var lastReportAt: Date?
    @Published private(set) var profileURL: URL?
    @Published var showingInvitation = false

    private let defaults: UserDefaults
    private let api: ReportAPI
    private let makeSigner: @Sendable (String) throws -> any ReportSigner
    private let makeMonitor: ((SpeedStore) -> any AgentSpeedReportingMonitor)?
    private var selectedCodexHome: URL?
    private var codexSelectionKnown = false
    private var localPreferences: [MultiClientUsagePreference] = []
    private(set) var reportingConfiguration = ActivitySourceConfiguration.make(codexEnabled: false, codexHome: nil, preferences: []).monitorConfiguration
    private let monotonic: () -> Int64
    private let store = SpeedStore()
    private var monitor: (any AgentSpeedReportingMonitor)?
    private var listener: UUID?
    private var work: Task<Void, Never>?
    private var delivery: Task<Void, Never>?
    private var generation = UUID()
    private var signer: (any ReportSigner)?
    private var document: ReportDiscovery?
    private var deviceID = ""
    private var run: Run?
    private var clockCorrection: Int64 = 0
    private var lastRegistration = Date.distantPast
    private var discoveryAt = Date.distantPast
    private var started = false
    private var lastSample = ReportSample()
    private var uiTick = Date.distantPast

    private struct Run {
        let id = ReportCanonical.newUUID()
        var scheduler: ReportScheduler
        var window: ReportWindow
        var title = ReportTitleTracker()
        var bodies: [Int: Data] = [:]
    }
    static var client: ReportClientInfo {
        .current(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.7")
    }
    static var userAgent: String { "CodexTokenBar/" + client.version }
    static var nowMS: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static var monotonicMS: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    init(defaults: UserDefaults = .standard,
         transport: any ReportTransport = URLSessionReportTransport(),
         makeSigner: @escaping @Sendable (String) throws -> any ReportSigner = AgentSpeedReportingIdentity.signer,
         monotonic: @escaping () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) },
         makeMonitor: ((SpeedStore) -> any AgentSpeedReportingMonitor)? = nil) {
        self.defaults = defaults
        self.api = ReportAPI(transport: transport, userAgent: Self.userAgent)
        self.makeSigner = makeSigner
        self.makeMonitor = makeMonitor
        self.monotonic = monotonic
        reportingConfiguration.enabledSources = Self.reportableSources
        enabled = defaults.bool(forKey: Self.enabledKey)
        username = defaults.string(forKey: Self.usernameKey) ?? "TokenBar-" + UUID().uuidString.prefix(8).lowercased()
    }

    func start() {
        guard !started else { return }
        started = true
        if enabled { begin() }
    }

    /// Shown once, including if the user dismisses the window without making a choice.
    func offerInvitation() {
        guard !enabled, !defaults.bool(forKey: Self.invitationKey) else { return }
        defaults.set(true, forKey: Self.invitationKey)
        showingInvitation = true
    }
    func dismissInvitation() { showingInvitation = false; defaults.set(true, forKey: Self.invitationKey) }

    func setEnabled(_ value: Bool, username requested: String? = nil) {
        if value {
            let name = ReportUsername.normalized((requested ?? username).trimmingCharacters(in: .whitespacesAndNewlines))
            guard ReportUsername.validate(name, rules: .standard) == nil else {
                message = "昵称需为 2–32 个有效字符"; return
            }
            username = name
            defaults.set(name, forKey: Self.usernameKey)
        }
        dismissInvitation()
        defaults.set(value, forKey: Self.enabledKey)
        enabled = value
        stopRuntime()
        if value { begin() }
    }

    /// Configuration only while reporting is off. An actual root transition
    /// starts a fresh reporting baseline, never uploads the previous home's tail.
    func configureCodexHome(_ home: URL?) {
        selectedCodexHome = home; codexSelectionKnown = true
        reconcileLocalSources()
    }
    func configureLocalPreferences(_ preferences: [MultiClientUsagePreference]) {
        localPreferences = preferences
        reconcileLocalSources()
    }
    private func reconcileLocalSources() {
        var next = ActivitySourceConfiguration.make(codexEnabled: false, codexHome: selectedCodexHome, preferences: localPreferences).monitorConfiguration
        next.enabledSources = Self.reportableSources
        if codexSelectionKnown && selectedCodexHome == nil { next.enabledSources.remove(.codex) }
        guard next != reportingConfiguration else { return }
        reportingConfiguration = next
        if started && enabled { stopRuntime(); begin() }
    }

    func retry() { guard enabled else { return }; stopRuntime(); begin() }
    func shutdown() { stopRuntime() }

    private func stopRuntime() {
        generation = UUID()
        work?.cancel(); work = nil
        delivery?.cancel(); delivery = nil
        monitor?.stop(); monitor = nil
        if let listener { store.removeLiveListener(listener) }
        listener = nil
        run = nil; document = nil; signer = nil
        lastSample = ReportSample()
        liveOutputTps = 0; estimatedShare = 0; sources = []
        phase = "off"; message = "未参加 · 采集与上报已关闭"
        // An opt-out cancels in-flight work immediately; no final telemetry packet after consent withdrawal.
    }

    private func begin() {
        guard enabled else { return }
        phase = "connecting"; message = "正在连接速蹬排行榜…"
        let token = generation
        work = Task { [weak self] in await self?.setup(token: token) }
    }

    private func setup(token: UUID) async {
        guard let service = try? ReportServiceURL.parse(Self.serviceURL).get() else { return }
        let outcome = await api.discover(service)
        guard valid(token) else { return }
        guard case .document(let discovered, _) = outcome else {
            fail(Self.discoveryFailureMessage(outcome)); return
        }
        guard Self.accepts(discovered) else {
            fail("服务协议或接收地址已变化，请更新客户端后重试"); return
        }
        guard ReportUsername.validate(username, rules: discovered.usernameRules) == nil else {
            fail("服务不接受这个昵称，请修改后重试"); return
        }
        document = discovered
        discoveryAt = Date()
        if let saved = defaults.string(forKey: Self.deviceKey), ReportCanonical.isDeviceId(saved) { deviceID = saved }
        else { deviceID = ReportCanonical.newUUID(); defaults.set(deviceID, forKey: Self.deviceKey) }
        do {
            let id = deviceID, factory = makeSigner
            let key = try await Task.detached(priority: .utility) { try factory(id) }.value
            guard valid(token) else { return }
            signer = key
            let body = ReportDocuments.registration(deviceId: id, username: username, publicKey: key.publicKey, client: Self.client)
            let reply = await request(endpoint: ReportEndpoint.devices, body: body, signer: key)
            guard valid(token) else { return }
            guard case .success(let value) = reply, value.isSuccess,
                  value.deviceId == id, let registeredName = value.username,
                  ["created", "exists", "updated"].contains(value.result ?? "") else {
                fail(Self.failureMessage(reply)); return
            }
            if registeredName != username {
                let renamed = await request(endpoint: ReportEndpoint.device(id), body: ReportDocuments.rename(username: username), signer: key, method: "PATCH")
                guard valid(token) else { return }
                guard case .success(let renamedReply) = renamed, renamedReply.isSuccess, renamedReply.username == username else {
                    fail(Self.failureMessage(renamed)); return
                }
            } else { username = registeredName }
            defaults.set(username, forKey: Self.usernameKey)
            profileURL = Self.safeProfile(value.profileURL)
            lastRegistration = Date()
            listener = store.addLiveListener { [weak self] snapshot in self?.receive(snapshot) }
            let monitor = makeMonitor?(store) ?? SharedAgentSpeedMonitorPool.shared.lease(store: store,
                configuration: reportingConfiguration, sources: reportingConfiguration.enabledSources)
            self.monitor = monitor
            phase = "preparing"; message = "正在识别本地软件 · 历史记录不会补报"
            monitor.start()
        } catch { if valid(token) { fail("设备签名密钥不可用，请重试；已有身份会保留") } }
    }

    static func accepts(_ document: ReportDiscovery) -> Bool {
        document.supportsThisClient && document.api.string == apiURL && document.apiKeyMode != .required
    }

    static func discoveryFailureMessage(_ outcome: ReportAPI.DiscoveryOutcome) -> String {
        switch outcome {
        case .failed(.unreachable): "连接失败或超时，请检查网络或代理规则"
        case .failed(.insecure): "安全连接失败，请检查证书或代理设置"
        case .failed(.response), .invalid: "服务配置无法读取，请稍后重试或更新客户端"
        case .gone: "上报服务已停止"
        case .notSupported: "此地址未提供兼容的上报服务"
        default: "上报服务暂时未正常响应，请稍后重试"
        }
    }

    /// Source-filter both identity-bearing rows and aggregates before they reach the report window.
    static func reportableSample(_ sample: ReportSample) -> ReportSample {
        let sources = sample.sources.filter { reportableSources.contains($0.key) }
        var live = Rate.zero
        var estimatedOutput = 0.0
        var liveCost = LiveCost.zero
        for source in sources.values {
            live.output += source.live.output
            live.total += source.live.total
            estimatedOutput += source.liveEstimated.output
            liveCost.add(source.liveCost)
        }
        let counters = ReportCounters(
            byModel: sample.facts.counters.byModel.filter { reportableSources.contains($0.key.source) },
            byMode: sample.facts.counters.byMode.filter { reportableSources.contains($0.key.model.source) }
        )
        let facts = ReportLiveFacts(
            agents: sample.facts.agents.filter { reportableSources.contains($0.key) },
            generatingModels: sample.facts.generatingModels.filter { reportableSources.contains($0.key.source) },
            counters: counters
        )
        return ReportSample(
            live: live,
            estimatedShare: live.output > 0 ? estimatedOutput / live.output : 0,
            liveCost: liveCost,
            sources: sources,
            facts: facts,
            traffic: .off
        )
    }

    /// The last in-process boundary before a report is signed or passed to HTTP.
    static func reportPayloadHasOnlyReportableSources(_ data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        var hasSourceProvenance = false
        var sourceReferenceCount = 0
        if let sources = root["sources"] {
            guard let rows = sources as? [[String: Any]] else { return false }
            hasSourceProvenance = true
            for row in rows {
                guard let raw = row["source"] as? String,
                      let source = SourceKind(rawValue: raw), reportableSources.contains(source) else { return false }
                sourceReferenceCount += 1
            }
        }
        if let models = root["models"] {
            guard let rows = models as? [[String: Any]] else { return false }
            hasSourceProvenance = true
            for row in rows {
                guard let rawSources = row["sources"] as? [String] else { return false }
                for raw in rawSources {
                    guard let source = SourceKind(rawValue: raw), reportableSources.contains(source) else { return false }
                    sourceReferenceCount += 1
                }
                if let harness = row["harnessRequests"] {
                    guard let entries = harness as? [[String: Any]] else { return false }
                    for entry in entries {
                        guard let raw = entry["source"] as? String,
                              let source = SourceKind(rawValue: raw), reportableSources.contains(source) else { return false }
                        sourceReferenceCount += 1
                    }
                }
                if let modes = row["modeUsage"] {
                    guard let entries = modes as? [[String: Any]] else { return false }
                    for entry in entries {
                        guard let raw = entry["source"] as? String,
                              let source = SourceKind(rawValue: raw), reportableSources.contains(source) else { return false }
                        sourceReferenceCount += 1
                    }
                }
            }
        }
        guard hasSourceProvenance else { return false }
        let hasSourceRows = (root["sources"] as? [[String: Any]])?.isEmpty == false
        let hasModelRows = (root["models"] as? [[String: Any]])?.contains(where: {
            ($0["sources"] as? [String])?.isEmpty == false
        }) == true
        if Self.containsNonzeroNumber(root["live"]) || Self.containsNonzeroNumber(root["peak"]) {
            guard hasSourceRows else { return false }
        }
        if Self.containsNonzeroNumber(root["delta"]), sourceReferenceCount == 0 || (!hasSourceRows && !hasModelRows) {
            return false
        }
        return true
    }

    private static func containsNonzeroNumber(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        if let object = value as? [String: Any] { return object.values.contains(where: containsNonzeroNumber) }
        if let array = value as? [Any] { return array.contains(where: containsNonzeroNumber) }
        return false
    }

    static func safeProfile(_ url: URL?) -> URL? {
        guard let url, url.scheme == "https", url.host == "deng.codexradar.com", url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func options(_ document: ReportDiscovery) -> ReportOptions {
        .init(sections: Set([ReportSection.sources, .models]).intersection(document.sections),
              maxModels: document.limits.maxModels, bodyLimit: document.limits.sendLimitBytes,
              extensions: .init(modelHarnessRequests: document.extensions?.modelHarnessRequests == true,
                                executionModes: document.extensions?.executionModes == true))
    }

    func receive(_ snapshot: SpeedSnapshot) {
        guard enabled, document != nil, signer != nil else { return }
        if snapshot.state == .noSources { phase = "waiting"; message = "已参加 · 等待本地软件产生日志"; return }
        guard snapshot.state == .running else { return }
        if phase == "waiting" { phase = "running"; message = "已参加 · 等待新的请求统计" }
        // Refresh discovery daily; a fresh monitor/run baselines all prior counters.
        if Date().timeIntervalSince(discoveryAt) >= 86400 { retry(); return }
        let sample = Self.reportableSample(ReportSample(snapshot: snapshot, traffic: .off))
        lastSample = sample
        if Date().timeIntervalSince(uiTick) >= 1 {
            uiTick = Date()
            liveOutputTps = sample.live.output; estimatedShare = sample.estimatedShare
            let availableKinds = Set(snapshot.sources.filter {
                $0.available && $0.enabled && Self.reportableSources.contains($0.kind)
            }.map(\.kind))
            sources = sample.sources.filter { availableKinds.contains($0.key) }.map {
                Source(id: $0.key.rawValue, name: Self.sourceName($0.key), tps: $0.value.live.output)
            }
        }
        if run == nil, let document {
            run = Run(scheduler: ReportScheduler(limits: document.limits), window: ReportWindow(sample))
            phase = "running"; message = "已参加 · 等待新的请求统计"
        }
        guard var run else { return }
        let now = monotonic()
        let active = sample.facts.agents.values.contains { $0.generating + $0.tools > 0 }
            || sample.live.output > 0 || run.window.hasTokenIncrement(sample)
        run.title.update(value: sample.live.output, redline: 2000, now: Double(now) / 1000)
        let actions = run.scheduler.tick(at: now, active: active, blocked: false)
        self.run = run
        apply(actions, sample: sample)
    }

    private func apply(_ actions: [ReportScheduler.Action], sample: ReportSample) {
        var windowStarted = false
        for action in actions {
            switch action {
            case .discard(let keepingTick): run?.window.discard(sample, keepingTick: keepingTick); windowStarted = true
            case .build(let ticket):
                guard var run, let document else { continue }
                let content = run.window.take(sample)
                let envelope = ReportEnvelope(client: Self.client, deviceId: deviceID, username: username,
                    runId: run.id, seq: ticket.seq, sentAtMs: Self.nowMS + clockCorrection * 1000,
                    windowMs: ticket.windowMs, activity: ticket.activity, titleLevel: run.title.level)
                let body = ReportBody.data(envelope, content, sample, Self.options(document))
                guard Self.reportPayloadHasOnlyReportableSources(body) else {
                    fail("报告来源无法确认，已停止上报")
                    return
                }
                run.bodies[ticket.seq] = body
                self.run = run; windowStarted = true
            case .send(let ticket): send(ticket)
            case .delivered(let ticket), .lost(let ticket): run?.bodies[ticket.seq] = nil
            }
        }
        run?.window.observe(sample, peaks: !windowStarted)
    }

    private func send(_ ticket: ReportScheduler.Ticket) {
        guard let run, let body = run.bodies[ticket.seq], let signer else { return }
        guard Self.reportPayloadHasOnlyReportableSources(body) else {
            fail("报告来源无法确认，已停止上报")
            return
        }
        let token = generation, runID = run.id
        delivery = Task { [weak self] in
            guard let self else { return }
            let result = await request(endpoint: ReportEndpoint.reports, body: body, signer: signer)
            guard valid(token), self.run?.id == runID else { return }
            let (outcome, reaction) = ReportOutcome.classify(result, hasPendingKey: false)
            if case .delivered = outcome { lastReportAt = Date(); message = "已参加 · 统计已上报" }
            else if case .transient = outcome { message = "连接暂不可用 · 将自动重试" }
            else if case .rateLimited = outcome { message = "服务限流 · 已暂停并等待重试" }
            let actions = self.run?.scheduler.finish(ticket, outcome, at: monotonic()) ?? []
            apply(actions, sample: lastSample)
            switch reaction {
            case .none: break
            case .correctClock(let serverTime):
                if let serverTime, abs(serverTime - Self.nowMS / 1000) <= 86400 { clockCorrection = serverTime - Self.nowMS / 1000 }
            case .newRun: self.run = nil
            case .reRegister, .recheckRegistration:
                if Date().timeIntervalSince(lastRegistration) >= 3600 { retry() }
                else { fail("设备注册需要确认，请重试连接") }
            case .refreshDiscovery: fail("服务协议有变化，请重试连接")
            case .rename, .needsUser, .strike, .usePendingKey: fail(Self.failureMessage(result))
            }
        }
    }

    private func request(endpoint: String, body: Data, signer: any ReportSigner, method: String = "POST") async -> Result<ReportReply, ReportTransportError> {
        guard enabled, !Task.isCancelled, let document else { return .failure(.other(-999)) }
        if endpoint == ReportEndpoint.reports && !Self.reportPayloadHasOnlyReportableSources(body) {
            return .failure(.other(-999))
        }
        let builder = ReportRequestBuilder(userAgent: Self.userAgent, deviceId: deviceID, apiKey: nil)
        let url = document.api.appending(endpoint: endpoint), timestamp = Self.nowMS / 1000 + clockCorrection
        do {
            let request = try await Task.detached(priority: .utility) {
                try builder.make(method: method, url: url, body: body, signer: signer, timestamp: timestamp)
            }.value
            guard enabled, !Task.isCancelled else { return .failure(.other(-999)) }
            if endpoint == ReportEndpoint.reports && !Self.reportPayloadHasOnlyReportableSources(request.body) {
                return .failure(.other(-999))
            }
            return await api.call(request)
        } catch { return .failure(.other(-1)) }
    }

    private func valid(_ token: UUID) -> Bool { enabled && token == generation && !Task.isCancelled }
    private func fail(_ text: String) {
        monitor?.stop(); monitor = nil
        if let listener { store.removeLiveListener(listener) }; listener = nil
        run = nil; liveOutputTps = 0; estimatedShare = 0; sources = []
        phase = "error"; message = text
    }
    static func failureMessage(_ result: Result<ReportReply, ReportTransportError>) -> String {
        guard case .success(let reply) = result else { return "连接暂不可用，请稍后重试" }
        switch reply.code {
        case "username_taken": return "昵称已被使用，请换一个昵称；已有账号请使用网站的设备关联功能"
        case "device_conflict", "signature_invalid": return "设备签名未通过，已停止上报；请重试连接"
        case "version_unsupported": return "服务暂未支持此客户端，请等待兼容更新"
        case "forbidden": return "服务拒绝了此次接入，已停止上报"
        default: return "服务暂未接受此次接入（HTTP \(reply.status)），请重试"
        }
    }
    static func sourceName(_ source: SourceKind) -> String {
        switch source {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .deepseek: "DSH"
        case .opencode: "OpenCode"
        case .gemini: "Gemini CLI"
        case .omp: "omp"
        case .antigravity: "Antigravity"
        case .workbuddy: "WorkBuddy"
        case .workbuddyAi: "WorkBuddy AI"
        case .zcode: "ZCode"
        case .kimi: "Kimi Code"
        case .grokBuild: "Grok Build"
        }
    }
}
