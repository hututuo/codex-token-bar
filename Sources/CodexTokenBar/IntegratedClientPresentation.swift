import Foundation
import AgentSpeedCore

/// One persisted source selection shared by the dashboard and all sidebar levels.
enum ClientDisplayScope {
    static let key = "multiClient.displayScope.v1"
    static func clients(_ raw: String, available: [String]) -> Set<String> {
        if raw == "all" { return Set(["codex"] + available) }
        if raw == "codex" || UsageClient(rawValue: raw) != nil { return [raw] }
        return ["codex"]
    }
    static func title(_ raw: String) -> String {
        raw == "all" ? "汇总" : raw == "codex" ? "Codex" : UsageClient(rawValue: raw)?.displayName ?? "Codex"
    }
}

enum ClientBrand {
    // Source references and evidence levels are retained in the design document.
    static func hex(_ client: String) -> String {
        switch client {
        case "codex": "#3941FF" // Classic community Codex icon; not an official universal swatch.
        case "claudeCode", "claudeDesktop": "#D97757"
        case "gemini": "#4796E4"
        case "deepseek": "#4D6BFE"
        case "opencode": "#B7B1B1"
        default: "#888888"
        }
    }
}

struct ClientQuotaItem: Identifiable, Equatable {
    let id: String
    let client: String
    let window: String
    let remaining: Double?
    let resetsAt: Date?
    let source: String
    let status: String
    var expected: Double? = nil
    var brand: String { ClientBrand.hex(client) }
    var fill: String { window == "5h" ? "#B6EF75" : window == "7d" ? "#B4ACFF" : "#78B7FF" }
    var shortClientTitle: String { client == "claudeCode" || client == "claudeDesktop" ? "Claude" : ClientDisplayScope.title(client) }
    var windowTitle: String { window == "5h" ? "5小时" : window == "7d" ? "7天" : window }
    var compactValue: String { remaining.map { String(format: "%.0f", $0) } ?? "—" }
    var value: String { remaining.map { String(format: "%.0f%%", $0) } ?? "—" }
    var title: String { ClientDisplayScope.title(client) + " · " + window }
}

/// Display preferences never fetch, mutate an observation, or change the ledger.
struct ClientQuotaSelection: Codable, Equatable {
    static let key = "multiClient.quotaSelection.v1"
    var order: [String] = []
    var hidden: Set<String> = []
    var enabled: Set<String> = []
    var colors: [String: String] = [:]
    var pairAcrossClients = false
    func includes(_ item: ClientQuotaItem) -> Bool {
        !hidden.contains(item.id) && (item.client == "codex" || item.client == "claudeCode" || enabled.contains(item.id))
    }
    func arranged(_ items: [ClientQuotaItem]) -> [ClientQuotaItem] {
        items.sorted {
            let a = order.firstIndex(of: $0.id) ?? Int.max
            let b = order.firstIndex(of: $1.id) ?? Int.max
            return a == b ? items.firstIndex(of: $0)! < items.firstIndex(of: $1)! : a < b
        }
    }
    static func decode(_ raw: String) -> Self {
        raw.data(using: .utf8).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
    var encoded: String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "" }
}

enum ClientQuotaProjection {
    static func items(codex: AccountQuotaSnapshot, claude: ClientQuotaReading, includeClaude: Bool, includeFiveHour: Bool = false, preview: Bool = false) -> [ClientQuotaItem] {
        // Explicit display-only fixture. Callers gate this to the isolated DEBUG preview;
        // never put simulated observations into AccountQuotaStore or quota history.
        if preview { return previewItems(includeClaude: includeClaude) }
        var items: [ClientQuotaItem] = []
        func add(_ id: String, _ label: String, _ window: AccountQuotaWindow?) {
            let data = QuotaSidebarQuotaPresentation.make(window: window, snapshot: codex)
            items.append(ClientQuotaItem(id: "codex:" + id, client: "codex", window: label,
                remaining: data.remaining.map(Double.init), resetsAt: window?.resetsAt,
                source: "Codex 现有额度观测", status: data.stale ? "旧数据" : window == nil ? "不可用" : "", expected: data.stale ? nil : window?.expectedRemainingPercentByEvenPace.map { Double($0) / 100 }))
        }
        if codex.fiveHour != nil
            || (includeFiveHour && codex.resolvedFiveHourAvailability != .absent) {
            add("5h", "5h", codex.fiveHour)
        }
        add("7d", "7d", codex.sevenDay)
        for window in codex.reserveWindows { add(window.label, window.compactDisplayLabel, window) }
        if includeClaude {
            for label in ["5h", "7d"] {
                let window = claude.windows.first { $0.label == label }
                let used = window?.usedPercent
                items.append(ClientQuotaItem(id: "claudeCode:" + label, client: "claudeCode", window: label,
                    remaining: used.flatMap { $0.isFinite ? min(100, max(0, 100 - $0)) : nil }, resetsAt: window?.resetsAt,
                    source: "本地缓存 · 未绑定账号", status: window == nil ? (claude.state == "notConnected" ? "未接入" : "不可用") : ""))
            }
        }
        return items
    }

    private static let previewStartedAt = Date()
    static func previewItems(includeClaude: Bool, now: Date? = nil) -> [ClientQuotaItem] {
        let now = now ?? previewStartedAt
        var items = [ClientQuotaItem(id: "codex:7d", client: "codex", window: "7d", remaining: 72,
            resetsAt: now.addingTimeInterval(3 * 86400), source: "模拟额度 · 不写入账本", status: "模拟")]
        if includeClaude {
            items += [("5h", 62.0, 7200.0), ("7d", 84.0, 4 * 86400.0)].map { window, remaining, seconds in
                ClientQuotaItem(id: "claudeCode:" + window, client: "claudeCode", window: window, remaining: remaining,
                    resetsAt: now.addingTimeInterval(seconds), source: "模拟额度 · 不写入账本", status: "模拟")
            }
        }
        return items
    }
}

enum ClientSidebarMetrics {
    static let ringSize = 46.0
    static let ringStroke = 3.0
    static let trackWidth = 4.0
    static let markerDiameter = 5.0
    static let capGap = 0.0
    static func trackHeight(_ total: Double) -> Double { max(2, total) }
}

struct ClientRailLayout: Equatable {
    let barHeight: Double
    let gap: Double
    let height: Double
    /// Keep the current 46pt tracks; overflowing content scrolls instead of
    /// silently switching styles or imposing an item-count limit.
    static func fixed(trackCount: Int, dotCount: Int = 0, availableHeight: Double) -> Self {
        let count = max(0, trackCount)
        let dots = min(count, max(0, dotCount))
        let preferred = Double(count - dots) * 46 + Double(dots) * 6 + Double(max(0, count - 1)) * 12 + 30
        let maxHeight = max(30, availableHeight.isFinite ? availableHeight : 900)
        return Self(barHeight: 46, gap: 12, height: min(maxHeight, preferred))
    }
}

// Read-only bundled rates. Never starts the Agent Speed monitor or its network sync.
// Aggregated usage cannot safely infer request tiers, fast mode or cache-write lifetime.
// Show a reference rate instead of inventing a billed total from those missing facts.
enum ClientReferencePrice {
    static func text(_ model: String) -> String {
        let table = AgentSpeedCore.PriceBook.bundled
        switch table.resolver.resolve(model: model, provider: nil) {
        case .free: return "免费模型"
        case let .priced(index, fast):
            guard let prices = table.models[index].pricing(endMs: nil, fast: fast)?.prices else { return "未计价" }
            return String(format: "$%.2f / $%.2f", Double(prices.input) / 1_000_000, Double(prices.output) / 1_000_000)
        case .unknown: return "未计价"
        }
    }
}


enum ClientActivityProjection {
    static func days(codex: [DayUsage], others: [ClientTrendBucket], allowed: Set<String>, now: Date = Date(), calendar: Calendar = .current) -> [DayUsage] {
        var sums: [Date: (tokens: Int, calls: Int)] = [:]
        func add(_ date: Date, _ tokens: Int, _ calls: Int) {
            guard date <= now else { return }
            let day = calendar.startOfDay(for: date)
            let old = sums[day] ?? (0, 0)
            sums[day] = (old.tokens + tokens, old.calls + calls)
        }
        if allowed.contains("codex") { for day in codex { add(day.date, day.tokens, day.calls) } }
        for row in others where allowed.contains(row.client.rawValue) {
            add(Date(timeIntervalSince1970: Double(row.startUnix)), Int(row.tokens), row.requests)
        }
        return sums.map { DayUsage(date: $0.key, tokens: $0.value.tokens, calls: $0.value.calls) }.sorted { $0.date < $1.date }
    }
}


extension ClientQuotaSelection {
    private enum CodingKeys: String, CodingKey { case order, hidden, enabled, colors, pairAcrossClients }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
        enabled = try c.decodeIfPresent(Set<String>.self, forKey: .enabled) ?? []
        colors = try c.decodeIfPresent([String: String].self, forKey: .colors) ?? [:]
        pairAcrossClients = try c.decodeIfPresent(Bool.self, forKey: .pairAcrossClients) ?? false
    }
}

struct ClientQuotaRingGroup: Identifiable, Equatable {
    let left: ClientQuotaItem
    let right: ClientQuotaItem?
    var id: String { left.id + "|" + (right?.id ?? "") }
    static func make(_ items: [ClientQuotaItem], acrossClients: Bool = false) -> [Self] {
        let clientOrder = items.map(\.client).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let groups = acrossClients ? [items] : clientOrder.map { client in items.filter { $0.client == client } }
        return groups.flatMap { group in
            stride(from: 0, to: group.count, by: 2).map { index in
                Self(left: group[index], right: index + 1 < group.count ? group[index + 1] : nil)
            }
        }
    }
}


enum ClientMoney {
    static func text(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "未计价" }
        return value > 0 && value < 0.01 ? "<$0.01" : String(format: "$%.2f", value)
    }
}
