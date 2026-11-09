import Foundation

struct DetectedUsageClient: Identifiable, Equatable, Sendable {
    let client: UsageClient
    let evidence: String
    var id: UsageClient { client }
}

/// Only probes known paths; never launches a CLI, reads credentials, or recursively scans history.
enum UsageClientDetection {
    static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       environment: [String: String] = ProcessInfo.processInfo.environment,
                       applications: URL = URL(fileURLWithPath: "/Applications")) -> [DetectedUsageClient] {
        let fm = FileManager.default
        func root(_ key: String, _ fallback: String) -> URL {
            environment[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(fallback)
        }
        func executable(_ name: String) -> Bool {
            let paths = (environment["PATH"] ?? "").split(separator: ":").prefix(64)
            return paths.contains { fm.isExecutableFile(atPath: URL(fileURLWithPath: String($0)).appendingPathComponent(name).path) }
                || fm.isExecutableFile(atPath: home.appendingPathComponent(".local/bin/" + name).path)
        }
        let roots: [(UsageClient, [URL], String)] = [
            (.claudeCode, [root("CLAUDE_CONFIG_DIR", ".claude").appendingPathComponent("projects")], "claude"),
            (.claudeDesktop, [applications.appendingPathComponent("Claude.app"), home.appendingPathComponent("Applications/Claude.app"), home.appendingPathComponent("Library/Application Support/Claude")], ""),
            (.deepseek, [root("DSH_HOME", ".dsh").appendingPathComponent("sessions")], "dsh"),
            (.gemini, [root("GEMINI_CLI_HOME", "").appendingPathComponent(".gemini/tmp"), root("GEMINI_CLI_HOME", "").appendingPathComponent(".cache/.gemini/tmp")], "gemini"),
            (.opencode, [root("OPENCODE_DATA_DIR", ".local/share/opencode"), root("XDG_DATA_HOME", ".local/share").appendingPathComponent("opencode")], "opencode"),
            (.antigravity, AntigravityUsageSource.roots(home: home) + [applications.appendingPathComponent("Antigravity.app")], "antigravity")
        ]
        return roots.compactMap { client, paths, command in
            if paths.contains(where: { fm.fileExists(atPath: $0.path) }) {
                return DetectedUsageClient(client: client, evidence: "发现本地应用或记录目录")
            }
            if !command.isEmpty && executable(command) { return DetectedUsageClient(client: client, evidence: "发现已安装的命令行客户端") }
            return nil
        }
    }
}

struct ClientTrendBucket: Equatable, Sendable {
    let client: UsageClient
    let startUnix: Int64
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64?
    let cacheWriteTokens: Int64?
    let reasoningTokens: Int64?
    let requests: Int
    // Already priced per request by the ledger (date/tier/cache TTL retained).
    // Nil with requests means no known price, never a fabricated zero.
    var apiCostMicroUSD: Int64? = nil
    var unpricedRequests: Int = 0
    var tokens: Int64 { inputTokens + outputTokens }
}

struct ClientQuotaReading: Equatable, Sendable {
    struct Window: Equatable, Sendable { let label: String; let usedPercent: Double; let resetsAt: Date? }
    let client: String
    let state: String
    let source: String
    let windows: [Window]
    let notice: String
    var capturedAt: Date? = nil
}

/// Providers project already-observed values. Creating or displaying a provider never fetches remotely.
protocol ClientQuotaProvider {
    var allowsNetwork: Bool { get }
    func reading() -> ClientQuotaReading
}
struct CodexObservedQuotaProvider: ClientQuotaProvider {
    let snapshot: AccountQuotaSnapshot
    let allowsNetwork = false
    func reading() -> ClientQuotaReading {
        let windows = [snapshot.fiveHour, snapshot.sevenDay].compactMap { $0 }.map {
            ClientQuotaReading.Window(label: $0.label, usedPercent: Double($0.usedPercent), resetsAt: $0.resetsAt)
        }
        return ClientQuotaReading(client: "codex", state: windows.isEmpty ? "unavailable" : "available", source: "codex-existing", windows: windows, notice: "沿用 Codex 现有额度刷新，不额外请求")
    }
}
struct ClaudeCapturedQuotaProvider: ClientQuotaProvider {
    let snapshot: ClaudeLocalQuota
    var client: UsageClient = .claudeCode
    let allowsNetwork = false
    static let setup = "可手动将本地 TokenBarClaudeLocal 配置为 Claude Code statusLine 命令；也兼容已有 claude-monitor --statusline 缓存。本软件不修改 Claude 配置、不读凭据、不联网。"
    func reading() -> ClientQuotaReading {
        let desktop = client == .claudeDesktop
        if !desktop && snapshot.state == "api" {
            return ClientQuotaReading(client: client.rawValue, state: "api", source: "local-config", windows: [],
                notice: "API 接入 · 订阅额度不适用")
        }
        let windows = [("5h", snapshot.fiveHour), ("7d", snapshot.sevenDay)].compactMap { label, value in
            value.map { ClientQuotaReading.Window(label: label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) }
        }
        let state = snapshot.state == "available" && !windows.isEmpty ? "available" : snapshot.state == "stale" && desktop ? "stale" : snapshot.state == "missing" ? "notConnected" : "unavailable"
        let notice: String
        if desktop {
            notice = state == "available" ? "Desktop 本地历史采样；未验证当前账号。文件不含重置时间，不与 CLI 额度合并。"
                : state == "stale" ? "Desktop 本地采样超过 20 分钟，已过期。官方后台轮询可能暂停；本软件不会唤醒轮询或发网络请求。"
                : "未读到可用的 Desktop 本地额度历史。仅读取 plan-usage-history.json，不发网络请求。"
        } else { notice = windows.isEmpty ? Self.setup : "最近 Claude 进程，未绑定账号；缓存有效期 10 分钟。" }
        return ClientQuotaReading(client: client.rawValue, state: state,
                                  source: desktop ? "local-desktop-history" : "local-statusline",
                                  windows: state == "available" ? windows : [], notice: notice, capturedAt: snapshot.capturedAt)
    }
}
struct UnavailableClientQuotaProvider: ClientQuotaProvider {
    let client: UsageClient
    let allowsNetwork = false
    func reading() -> ClientQuotaReading {
        ClientQuotaReading(client: client.rawValue, state: "notConnected", source: "unsupported", windows: [], notice: "此客户端尚无本地额度提供者；Token 用量仍可读取。联网额度保持关闭。")
    }
}

struct ClientChartPoint: Identifiable, Equatable {
    let client: String
    let start: Date
    let tokens: Int64
    var id: String { client + ":" + String(start.timeIntervalSince1970) }
}
enum ClientUsageChartProjection {
    /// Fixed UTC buckets give every source the same boundaries. Gaps stay zero, never interpolated.
    static func points(codex: [BinUsage], others: [ClientTrendBucket], days: Int, now: Date, allowed: Set<String>) -> [ClientChartPoint] {
        let seconds = days == 1 ? 300.0 : days == 7 ? 3600.0 : 21600.0
        let last = floor(now.timeIntervalSince1970 / seconds) * seconds
        let count = days * 86400 / Int(seconds) + 1
        let first = last - Double(count - 1) * seconds
        var sums: [String: [Double: Int64]] = [:]
        func add(_ client: String, _ timestamp: Double, _ tokens: Int64) {
            guard allowed.contains(client), timestamp <= now.timeIntervalSince1970 else { return }
            let start = floor(timestamp / seconds) * seconds
            guard start >= first && start <= last else { return }
            sums[client, default: [:]][start, default: 0] += max(0, tokens)
        }
        for point in codex { add("codex", point.start.timeIntervalSince1970, Int64(point.tokens)) }
        for point in others { add(point.client.rawValue, Double(point.startUnix), point.tokens) }
        return allowed.sorted().flatMap { client in
            (0..<count).map { i in
                let start = first + Double(i) * seconds
                return ClientChartPoint(client: client, start: Date(timeIntervalSince1970: start), tokens: sums[client]?[start] ?? 0)
            }
        }
    }
}
