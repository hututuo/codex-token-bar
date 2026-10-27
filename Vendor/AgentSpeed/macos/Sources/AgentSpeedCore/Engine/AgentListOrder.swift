import Foundation

/// Tree and group order of the agents list (METRICS 6.7, steps 4 and 5).
enum AgentListOrder {
    private struct Group {
        var members: [EngineAgentStatus]
        var isGenerating: Bool
        var liveOutput: Double
        var latestActivity: Int64

        var rootId: String { members[0].agent.id }

        init(members: [EngineAgentStatus]) {
            self.members = members
            isGenerating = members.contains { $0.phase == .generating }
            liveOutput = members.reduce(0) { $0 + $1.live.output }
            latestActivity = members.map(AgentListOrder.activity).max() ?? 0
        }
    }

    /// Lists every row depth-first inside its group, with `parentId` set to the listed tree parent.
    static func arrange(_ listed: [String: EngineAgentStatus]) -> [EngineAgentStatus] {
        var parents: [String: String] = [:]
        for (id, row) in listed {
            if let parent = row.agent.parentId, parent != id, listed[parent] != nil { parents[id] = parent }
        }
        AgentParents.breakCycles(&parents)

        var roots: [EngineAgentStatus] = []
        var children: [String: [EngineAgentStatus]] = [:]
        for (id, var row) in listed {
            row.parentId = parents[id]
            if let parent = row.parentId {
                children[parent, default: []].append(row)
            } else {
                roots.append(row)
            }
        }
        for parent in Array(children.keys) {
            children[parent]?.sort(by: precedes)
        }

        var groups = roots.map { root in
            var members: [EngineAgentStatus] = []
            var stack = [root]
            while let row = stack.popLast() {
                members.append(row)
                stack.append(contentsOf: (children[row.agent.id] ?? []).reversed())
            }
            return Group(members: members)
        }
        groups.sort { lhs, rhs in
            if lhs.isGenerating != rhs.isGenerating { return lhs.isGenerating }
            if lhs.liveOutput != rhs.liveOutput { return lhs.liveOutput > rhs.liveOutput }
            if lhs.latestActivity != rhs.latestActivity { return lhs.latestActivity > rhs.latestActivity }
            return AgentParents.ordinal(lhs.rootId, precedes: rhs.rootId)
        }
        return groups.flatMap(\.members)
    }

    /// Sibling order: generating first, then live output, latest activity and id.
    private static func precedes(_ lhs: EngineAgentStatus, _ rhs: EngineAgentStatus) -> Bool {
        let lhsGenerating = lhs.phase == .generating
        let rhsGenerating = rhs.phase == .generating
        if lhsGenerating != rhsGenerating { return lhsGenerating }
        if lhs.live.output != rhs.live.output { return lhs.live.output > rhs.live.output }
        if activity(lhs) != activity(rhs) { return activity(lhs) > activity(rhs) }
        return AgentParents.ordinal(lhs.agent.id, precedes: rhs.agent.id)
    }

    private static func activity(_ row: EngineAgentStatus) -> Int64 {
        row.agent.lastLineMs ?? 0
    }
}
