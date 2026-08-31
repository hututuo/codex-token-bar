import Foundation

enum RunningThreadFreshness: String, Equatable, Sendable {
    case loading
    case fresh
    case stale
    case unavailable
}

struct RunningThreadModelBreakdown: Equatable, Hashable, Sendable, Identifiable {
    let model: String?
    let reasoningEffort: String?
    let count: Int

    init(model: String?, reasoningEffort: String?, count: Int) {
        self.model = Self.cleaned(model)
        self.reasoningEffort = Self.cleaned(reasoningEffort)
        self.count = max(0, count)
    }

    var id: String {
        "\(model ?? "unknown")|\(reasoningEffort ?? "unknown")"
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

struct RunningThreadMember: Equatable, Hashable, Sendable, Identifiable {
    let threadID: String
    let title: String?
    let model: String?
    let reasoningEffort: String?

    init(
        threadID: String,
        title: String?,
        model: String?,
        reasoningEffort: String?
    ) {
        self.threadID = threadID
        self.title = Self.cleaned(title)
        self.model = Self.cleaned(model)
        self.reasoningEffort = Self.cleaned(reasoningEffort)
    }

    var id: String { threadID }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

struct RunningThreadGroup: Equatable, Hashable, Sendable, Identifiable {
    let mainThread: RunningThreadMember
    let subagents: [RunningThreadMember]

    var id: String { mainThread.threadID }
}

struct RunningThreadSummary: Equatable, Sendable {
    let main: Int
    let subagents: Int
    let mainModels: [RunningThreadModelBreakdown]
    let subagentModels: [RunningThreadModelBreakdown]
    let groups: [RunningThreadGroup]
    let unassignedSubagents: [RunningThreadMember]
    /// The time at which the source was successfully checked. This is not a
    /// claim that the underlying session data changed at this time.
    let lastCheckedAt: Date?
    /// The newest source-file modification represented by this summary.
    let dataUpdatedAt: Date?
    /// A stable process-independent fingerprint of the business summary. It
    /// remains unchanged when a check observes the same running sessions.
    let summaryRevision: UInt64
    let freshness: RunningThreadFreshness

    init(
        main: Int,
        subagents: Int,
        mainModels: [RunningThreadModelBreakdown] = [],
        subagentModels: [RunningThreadModelBreakdown] = [],
        groups: [RunningThreadGroup] = [],
        unassignedSubagents: [RunningThreadMember] = [],
        updatedAt: Date?,
        freshness: RunningThreadFreshness
    ) {
        self.init(
            main: main,
            subagents: subagents,
            mainModels: mainModels,
            subagentModels: subagentModels,
            groups: groups,
            unassignedSubagents: unassignedSubagents,
            lastCheckedAt: updatedAt,
            dataUpdatedAt: updatedAt,
            summaryRevision: 0,
            freshness: freshness
        )
    }

    init(
        main: Int,
        subagents: Int,
        mainModels: [RunningThreadModelBreakdown] = [],
        subagentModels: [RunningThreadModelBreakdown] = [],
        groups: [RunningThreadGroup] = [],
        unassignedSubagents: [RunningThreadMember] = [],
        lastCheckedAt: Date? = nil,
        dataUpdatedAt: Date? = nil,
        summaryRevision: UInt64 = 0,
        freshness: RunningThreadFreshness
    ) {
        self.main = max(0, main)
        self.subagents = max(0, subagents)
        self.mainModels = mainModels.filter { $0.count > 0 }
        self.subagentModels = subagentModels.filter { $0.count > 0 }
        self.groups = groups
        self.unassignedSubagents = unassignedSubagents
        self.lastCheckedAt = lastCheckedAt
        self.dataUpdatedAt = dataUpdatedAt
        self.summaryRevision = summaryRevision
        self.freshness = freshness
    }

    /// Compatibility alias for older callers. New code must use
    /// `dataUpdatedAt` when it needs the source-data timestamp.
    var updatedAt: Date? {
        dataUpdatedAt
    }

    var total: Int {
        main + subagents
    }

    var runningModelDetailsRowCount: Int {
        groups.count + (unassignedSubagents.isEmpty ? 0 : 1)
    }

    var runningModelDetailsRowUnits: Int {
        let groupedUnits = groups.reduce(0) { partial, group in
            partial + max(1, Self.distinctConfigurationCount(in: group.subagents))
        }
        guard !unassignedSubagents.isEmpty else { return groupedUnits }
        return groupedUnits + max(
            1,
            Self.distinctConfigurationCount(in: unassignedSubagents)
        )
    }

    private static func distinctConfigurationCount(
        in members: [RunningThreadMember]
    ) -> Int {
        Set(members.map {
            "\($0.model ?? "unknown")|\($0.reasoningEffort ?? "unknown")"
        }).count
    }

    static let loading = RunningThreadSummary(
        main: 0,
        subagents: 0,
        updatedAt: nil,
        freshness: .loading
    )

    static let unavailable = RunningThreadSummary(
        main: 0,
        subagents: 0,
        updatedAt: nil,
        freshness: .unavailable
    )

    func markedStale() -> RunningThreadSummary {
        guard freshness == .fresh || freshness == .stale else {
            return .unavailable
        }
        return RunningThreadSummary(
            main: main,
            subagents: subagents,
            mainModels: mainModels,
            subagentModels: subagentModels,
            groups: groups,
            unassignedSubagents: unassignedSubagents,
            lastCheckedAt: lastCheckedAt,
            dataUpdatedAt: dataUpdatedAt,
            summaryRevision: summaryRevision,
            freshness: .stale
        )
    }
}

struct RunningThreadPresentation: Equatable {
    let summary: RunningThreadSummary

    var displayText: String {
        guard hasCounts else {
            return "运行 -- · 主 -- · 子 --"
        }
        return "运行 \(summary.total) · 主 \(summary.main) · 子 \(summary.subagents)"
    }

    var accessibilityText: String {
        switch summary.freshness {
        case .loading:
            return "正在读取当前运行线程"
        case .unavailable:
            return "当前运行线程暂时无法读取"
        case .fresh:
            return "当前运行 \(summary.total) 个线程，主线程 \(summary.main) 个，子 Agent \(summary.subagents) 个"
        case .stale:
            return "当前显示上次读取的运行线程，共 \(summary.total) 个，主线程 \(summary.main) 个，子 Agent \(summary.subagents) 个"
        }
    }

    var hasCounts: Bool {
        summary.freshness == .fresh || summary.freshness == .stale
    }
}

enum RunningThreadLifecycle: Equatable, Sendable {
    case unknown
    case running
    case idle
}

struct RunningThreadFileState: Equatable, Sendable {
    let deviceID: UInt64?
    let fileID: UInt64?
    var offset: UInt64
    var observedSize: UInt64
    var boundarySignature: UInt64
    var sessionID: String
    var isSubagent: Bool
    var parentThreadID: String?
    var lifecycle: RunningThreadLifecycle
    var lifecycleAt: Date?
    var modifiedAt: Date
}

struct RunningThreadScanResult: Equatable, Sendable {
    let states: [String: RunningThreadFileState]
    let summary: RunningThreadSummary
}
