import Foundation

/// Stable content identities shared by the compact rail, expanded menu and settings.
/// Detail pages are navigation destinations, not a second layout configuration.
enum QuotaSidebarItem: Hashable, Identifiable, Sendable {
    case modeltrace, speed, tps, quota(String), models, tasks, radar, credits, clientUsage

    var id: String {
        switch self {
        case let .quota(client): "quota:" + client
        case .modeltrace: "modeltrace"
        case .speed: "speed"
        case .tps: "tps"
        case .models: "models"
        case .tasks: "tasks"
        case .radar: "radar"
        case .credits: "credits"
        case .clientUsage: "clientUsage"
        }
    }

    init?(id: String) {
        switch id {
        case "modeltrace": self = .modeltrace
        case "speed": self = .speed
        case "tps": self = .tps
        case "models": self = .models
        case "tasks": self = .tasks
        case "radar": self = .radar
        case "credits": self = .credits
        case "clientUsage": self = .clientUsage
        default:
            guard id.hasPrefix("quota:") else { return nil }
            let client = String(id.dropFirst(6))
            guard !client.isEmpty, client.utf8.count <= 64,
                  client.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }) else { return nil }
            self = .quota(client)
        }
    }

    var title: String {
        switch self {
        case .modeltrace: "模型检测"
        case .speed: "实时速度"
        case .tps: "正文 TPS"
        case let .quota(client): ClientDisplayScope.title(client) + " 额度"
        case .models: "模型占比"
        case .tasks: "运行任务"
        case .radar: "雷达"
        case .credits: "重置卡"
        case .clientUsage: "客户端用量"
        }
    }

    var detail: QuotaSidebarDetail {
        switch self {
        case .speed, .tps: .speeds
        case .quota, .models: .overview
        case .modeltrace: .modeltrace
        case .tasks: .tasks
        case .radar: .radar
        case .credits: .credits
        case .clientUsage: .clientUsage
        }
    }

    var hasCompactRepresentation: Bool {
        switch self { case .speed, .quota, .models, .tasks: true; default: false }
    }

    static let defaults: [Self] = [.modeltrace, .speed, .tps, .quota("codex"), .quota("claudeCode"), .models, .tasks, .radar, .credits, .clientUsage]
}

enum QuotaSidebarLevel { case compact, expanded }

struct QuotaSidebarItemLayout: Codable, Equatable, Sendable {
    static let key = "quotaSidebarLayout.v1"
    var version = 1
    var order = QuotaSidebarItem.defaults.map(\.id)
    var hidden: Set<String> = [QuotaSidebarItem.clientUsage.id]
    var hiddenCompact: Set<String> = []
    var hiddenExpanded: Set<String> = []

    init() {}
    private enum CodingKeys: String, CodingKey { case version, order, hidden, hiddenCompact, hiddenExpanded }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        order = try values.decode([String].self, forKey: .order)
        hidden = try values.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? [QuotaSidebarItem.clientUsage.id]
        hiddenCompact = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenCompact) ?? []
        hiddenExpanded = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenExpanded) ?? []
    }

    static func decode(_ data: Data?) -> Self? {
        guard let data, var value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1 else { return nil }
        value.normalize()
        return value
    }

    mutating func normalize() {
        var seen = Set<String>()
        order = order.filter { QuotaSidebarItem(id: $0) != nil && seen.insert($0).inserted }
        order += QuotaSidebarItem.defaults.map(\.id).filter { !seen.contains($0) }
        hidden = hidden.filter { QuotaSidebarItem(id: $0) != nil }
        hiddenCompact = hiddenCompact.filter { QuotaSidebarItem(id: $0) != nil }
        hiddenExpanded = hiddenExpanded.filter { QuotaSidebarItem(id: $0) != nil }
    }

    /// Unavailable clients stay persisted so temporary source/scope changes never
    /// erase the user's placement or visibility choice.
    func arranged(availableQuotaClients clients: [String]) -> [QuotaSidebarItem] {
        let clients = clients.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let available = Set(clients)
        var items = order.compactMap(QuotaSidebarItem.init(id:)).filter {
            if case let .quota(client) = $0 { return available.contains(client) }
            return true
        }
        let missing = clients.map(QuotaSidebarItem.quota).filter { !items.contains($0) }
        let insertion = items.lastIndex { if case .quota = $0 { return true }; return false }.map { $0 + 1 }
            ?? items.firstIndex(of: .models) ?? items.count
        items.insert(contentsOf: missing, at: insertion)
        return items
    }

    func isVisible(_ item: QuotaSidebarItem) -> Bool { isVisible(item, in: .compact) || isVisible(item, in: .expanded) }
    func isVisible(_ item: QuotaSidebarItem, in level: QuotaSidebarLevel) -> Bool {
        guard !hidden.contains(item.id) else { return false }
        return level == .compact ? item.hasCompactRepresentation && !hiddenCompact.contains(item.id) : !hiddenExpanded.contains(item.id)
    }

    mutating func setVisible(_ item: QuotaSidebarItem, in level: QuotaSidebarLevel, visible: Bool) {
        guard level != .compact || item.hasCompactRepresentation else { return }
        if hidden.remove(item.id) != nil {
            hiddenCompact.insert(item.id); hiddenExpanded.insert(item.id)
        }
        if level == .compact {
            if visible { hiddenCompact.remove(item.id) } else { hiddenCompact.insert(item.id) }
        } else {
            if visible { hiddenExpanded.remove(item.id) } else { hiddenExpanded.insert(item.id) }
        }
    }

    mutating func move(_ item: QuotaSidebarItem, relativeTo target: QuotaSidebarItem, after: Bool) {
        guard item != target else { return }
        if !order.contains(target.id) { order.append(target.id) }
        order.removeAll { $0 == item.id }
        guard let index = order.firstIndex(of: target.id) else { return }
        order.insert(item.id, at: index + (after ? 1 : 0))
    }

    static func migrate(moduleOrder: [QuotaSidebarDetail], hiddenModules: Set<QuotaSidebarDetail>, quotaWindowOrder: [String]) -> Self {
        var clients = [String]()
        for window in quotaWindowOrder {
            guard let separator = window.firstIndex(of: ":") else { continue }
            let client = String(window[..<separator])
            if QuotaSidebarItem(id: "quota:" + client) != nil, !clients.contains(client) { clients.append(client) }
        }
        clients += ["codex", "claudeCode"].filter { !clients.contains($0) }
        var result = Self()
        result.order = []
        result.hidden = []
        for module in moduleOrder {
            let children: [QuotaSidebarItem]
            switch module {
            case .speeds: children = [.speed, .tps]
            case .overview: children = clients.map(QuotaSidebarItem.quota) + [.models]
            case .modeltrace: children = [.modeltrace]
            case .tasks: children = [.tasks]
            case .radar: children = [.radar]
            case .credits: children = [.credits]
            case .clientUsage: children = [.clientUsage]
            case .settings: children = []
            }
            result.order += children.map(\.id)
            if hiddenModules.contains(module) { result.hidden.formUnion(children.map(\.id)) }
        }
        result.normalize()
        return result
    }
}

enum QuotaSidebarContentOrder {
    static func compactIDs(items: [QuotaSidebarItem], quotas: [ClientQuotaItem]) -> [String] {
        items.flatMap { item -> [String] in
            switch item {
            case let .quota(client): quotaWindows(quotas, client: client).map(\.id)
            case .speed, .models, .tasks: [item.id]
            default: []
            }
        }
    }

    static func quotaWindows(_ items: [ClientQuotaItem], client: String) -> [ClientQuotaItem] {
        let windows = items.filter { $0.client == client }
        func rank(_ item: ClientQuotaItem) -> Int { item.window == "5h" ? 0 : item.window == "7d" ? 1 : 2 }
        return windows.enumerated().sorted { a, b in
            rank(a.element) == rank(b.element) ? a.offset < b.offset : rank(a.element) < rank(b.element)
        }.map(\.element)
    }
}
