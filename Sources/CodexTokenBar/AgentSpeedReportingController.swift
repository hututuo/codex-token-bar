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
    private let makeMonitor: (SpeedStore) -> any AgentSpeedReportingMonitor
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
         makeMonitor: @escaping (SpeedStore) -> any AgentSpeedReportingMonitor = {
             AgentSpeedCore.LiveMonitor(store: $0, pricing: PriceBook())
         }) {
        self.defaults = defaults
        self.api = ReportAPI(transport: transport, userAgent: Self.userAgent)
        self.makeSigner = makeSigner
        self.makeMonitor = makeMonitor
        self.monotonic = monotonic
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
            fail("发现服务暂不可用，可稍后重试"); return
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
            let monitor = makeMonitor(store)
            self.monitor = monitor
            phase = "preparing"; message = "正在识别本地软件 · 历史记录不会补报"
            monitor.start()
        } catch { if valid(token) { fail("设备签名密钥不可用，请重试；已有身份会保留") } }
    }

    static func accepts(_ document: ReportDiscovery) -> Bool {
        document.supportsThisClient && document.api.string == apiURL && document.apiKeyMode != .required
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
        let sample = ReportSample(snapshot: snapshot, traffic: .off)
        lastSample = sample
        if Date().timeIntervalSince(uiTick) >= 1 {
            uiTick = Date()
            liveOutputTps = sample.live.output; estimatedShare = sample.estimatedShare
            sources = snapshot.sources.filter { $0.available && $0.enabled }.map {
                Source(id: $0.kind.rawValue, name: Self.sourceName($0.kind), tps: $0.live.output)
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
                run.bodies[ticket.seq] = ReportBody.data(envelope, content, sample, Self.options(document))
                self.run = run; windowStarted = true
            case .send(let ticket): send(ticket)
            case .delivered(let ticket), .lost(let ticket): run?.bodies[ticket.seq] = nil
            }
        }
        run?.window.observe(sample, peaks: !windowStarted)
    }

    private func send(_ ticket: ReportScheduler.Ticket) {
        guard let run, let body = run.bodies[ticket.seq], let signer else { return }
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
        let builder = ReportRequestBuilder(userAgent: Self.userAgent, deviceId: deviceID, apiKey: nil)
        let url = document.api.appending(endpoint: endpoint), timestamp = Self.nowMS / 1000 + clockCorrection
        do {
            let request = try await Task.detached(priority: .utility) {
                try builder.make(method: method, url: url, body: body, signer: signer, timestamp: timestamp)
            }.value
            guard enabled, !Task.isCancelled else { return .failure(.other(-999)) }
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
