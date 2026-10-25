import Foundation

/// One agent of the 6.7 list as traffic attribution sees it (METRICS 10.6).
struct TrafficAgent: Equatable, Sendable {
    enum Activity: Equatable, Sendable {
        /// Recorded intervals `[from, to]` in which the agent was generating, running tools or writing lines (fixtures).
        case intervals([ClosedRange<Int64>])
        /// The live list: the phase after the staleness rule is `generating`/`tools`, and the last line time.
        case live(working: Bool, lastLineMs: Int64?)
    }

    var id: String
    var source: SourceKind
    var parentId: String?
    var cwdPath: String?
    /// The transcript (or database) a process may hold open; nil when the id is not a path.
    var transcript: String?
    var activity: Activity

    /// Active during `[startMs, endMs]`: working, or a line at or after `startMs − 2000`.
    func isActive(startMs: Int64, endMs: Int64) -> Bool {
        switch activity {
        case .intervals(let intervals):
            intervals.contains { $0.lowerBound <= endMs && $0.upperBound >= startMs - 2000 }
        case .live(let working, let lastLineMs):
            working || (lastLineMs.map { $0 >= startMs - 2000 } ?? false)
        }
    }
}

/// The agent trees of the 6.7 list (roots with their sub-agents) and the candidate rule of METRICS 10.6.
struct AgentTrees {
    private(set) var agents: [String: TrafficAgent] = [:]
    private var rootOf: [String: String] = [:]
    private var membersOf: [String: [TrafficAgent]] = [:]
    private var rootsBySource: [SourceKind: [String]] = [:]
    /// Every tree's root id, sorted.
    private(set) var roots: [String] = []

    init(_ list: [TrafficAgent] = []) {
        replace(list)
    }

    mutating func replace(_ list: [TrafficAgent]) {
        agents = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        rootOf = [:]
        membersOf = [:]
        rootsBySource = [:]
        for agent in agents.values {
            let root = resolveRoot(agent.id)
            rootOf[agent.id] = root
            membersOf[root, default: []].append(agent)
        }
        var bySource: [SourceKind: Set<String>] = [:]
        for agent in agents.values { bySource[agent.source, default: []].insert(rootOf[agent.id] ?? agent.id) }
        rootsBySource = bySource.mapValues { $0.sorted() }
        roots = Set(rootOf.values).sorted()
    }

    func root(of id: String) -> String? { rootOf[id] }

    private func resolveRoot(_ id: String) -> String {
        var seen: Set<String> = []
        var current = id
        while let parent = agents[current]?.parentId, agents[parent] != nil, !seen.contains(current) {
            seen.insert(current)
            current = parent
        }
        return current
    }

    func isTreeActive(_ root: String, startMs: Int64, endMs: Int64) -> Bool {
        membersOf[root]?.contains { $0.isActive(startMs: startMs, endMs: endMs) } ?? false
    }

    /// Some agent was active during `[startMs, endMs]` (METRICS 10.10 cadence).
    func anyActive(startMs: Int64, endMs: Int64) -> Bool {
        agents.values.contains { $0.isActive(startMs: startMs, endMs: endMs) }
    }

    /// The candidate trees of `source` for one root process (METRICS 10.6 steps 1–3; each step only applies when it
    /// leaves at least one). `openFiles` and `workingDirectory` are only asked when more than one candidate is active.
    func candidates(
        source: SourceKind,
        startMs: Int64,
        endMs: Int64,
        platform: TrafficPlatform,
        openFiles: () -> Set<String>,
        workingDirectory: () -> String?
    ) -> [String] {
        var candidates = (rootsBySource[source] ?? []).filter { isTreeActive($0, startMs: startMs, endMs: endMs) }
        guard candidates.count > 1 else { return candidates }
        let open = openFiles()
        if !open.isEmpty {
            let owned = candidates.filter { root in
                membersOf[root]?.contains { agent in agent.transcript.map { open.contains(platform.normalize($0)) } ?? false } ?? false
            }
            if !owned.isEmpty { candidates = owned }
        }
        if candidates.count > 1, let directory = workingDirectory(), !directory.isEmpty {
            let wanted = platform.normalize(directory)
            let same = candidates.filter { root in
                agents[root]?.cwdPath.map { platform.normalize($0) == wanted } ?? false
            }
            if !same.isEmpty { candidates = same }
        }
        return candidates
    }
}
