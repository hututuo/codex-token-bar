import Foundation

/// Parent links between agents (METRICS 6.7).
enum AgentParents {
    /// What parent resolution needs to know about one tracked agent.
    struct Member: Equatable, Sendable {
        var id: String
        var family: TranscriptFamily
        var thread: SessionThread?

        init(id: String, family: TranscriptFamily, thread: SessionThread? = nil) {
            self.id = id
            self.family = family
            self.thread = thread
        }
    }

    /// Like `resolve(_:)`, plus links that are known directly (OpenCode sessions name their parent session).
    static func resolve(_ members: [Member], direct: [String: String]) -> [String: String] {
        guard !direct.isEmpty else { return resolve(members) }
        var parents = resolve(members)
        for (id, parent) in direct where parent != id { parents[id] = parent }
        breakCycles(&parents)
        return parents
    }

    /// Parent id of every member that has one. Self references and cycles resolve to no parent.
    static func resolve(_ members: [Member]) -> [String: String] {
        var ids = Set<String>()
        var ompIds = Set<String>()
        var workbuddyIds: [TranscriptFamily: Set<String>] = [:]
        // Codex threads and DeepSeek sessions, each by family: the earliest created file names a thread.
        var threads: [TranscriptFamily: [String: (createdMs: Int64, id: String)]] = [:]
        let geminiMains = geminiMainSessions(members)
        let conversations = antigravityConversations(members)
        let grokSessions = Dictionary(grouping: members.filter { $0.family == .grokBuild && $0.thread?.id != nil }, by: { $0.thread!.id! })
        for member in members {
            ids.insert(member.id)
            if member.family == .omp { ompIds.insert(member.id) }
            if member.family.isWorkBuddy { workbuddyIds[member.family, default: []].insert(member.id) }
            guard member.family == .codex || member.family == .dsh,
                  let thread = member.thread, let threadId = thread.id else { continue }
            if let earliest = threads[member.family]?[threadId],
               earliest.createdMs < thread.createdMs
                || (earliest.createdMs == thread.createdMs && ordinal(earliest.id, precedes: member.id)) {
                continue
            }
            threads[member.family, default: [:]][threadId] = (thread.createdMs, member.id)
        }
        var parents: [String: String] = [:]
        for member in members {
            let parent: String?
            switch member.family {
            case .codex, .dsh:
                parent = member.thread?.parentId.flatMap { threads[member.family]?[$0]?.id }
            case .claude:
                parent = claudeParentPath(of: member.id).flatMap { ids.contains($0) ? $0 : nil }
            case .gemini:
                parent = geminiSessionKey(ofSubagent: member).flatMap { geminiMains[$0] }
            case .omp:
                // `thread.parentId` is the path `<dir>.jsonl` of a sub-agent's starter (METRICS 6.7).
                parent = member.thread?.parentId.flatMap { ompIds.contains($0) ? $0 : nil }
            case .antigravity:
                parent = antigravityParent(of: member, in: conversations)
            case .kimi:
                parent = member.thread?.parentId.flatMap { ids.contains($0) ? $0 : nil }
            case .grokBuild:
                parent = member.thread?.parentId.flatMap { parent in
                    let workspace = ((member.id as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                    return grokSessions[parent]?.min { lhs, rhs in
                        let leftWorkspace = ((lhs.id as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                        let rightWorkspace = ((rhs.id as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                        if (leftWorkspace == workspace) != (rightWorkspace == workspace) { return leftWorkspace == workspace }
                        let leftCreated = lhs.thread?.createdMs ?? 0, rightCreated = rhs.thread?.createdMs ?? 0
                        if leftCreated != rightCreated { return leftCreated < rightCreated }
                        return ordinal(lhs.id, precedes: rhs.id)
                    }?.id
                }
            case .workbuddy, .workbuddyAi:
                // As Claude, within the same edition: nested sub-agents are stored flat under the main session.
                parent = claudeParentPath(of: member.id).flatMap { workbuddyIds[member.family]?.contains($0) == true ? $0 : nil }
            }
            if let parent, parent != member.id { parents[member.id] = parent }
        }
        breakCycles(&parents)
        return parents
    }

    /// Gemini CLI main sessions (files directly in `chats`) by `<chats path>` + sanitized session id; with several
    /// candidates `.jsonl` wins over `.json`, then the earliest `startTime`, then ordinal path.
    private static func geminiMainSessions(_ members: [Member]) -> [String: String] {
        var best: [String: Member] = [:]
        for member in members where member.family == .gemini {
            guard let id = member.thread?.id, !id.isEmpty else { continue }
            let folder = (member.id as NSString).deletingLastPathComponent
            guard (folder as NSString).lastPathComponent == "chats" else { continue }
            let key = folder + "\u{0}" + sanitizedGeminiId(id)
            if let current = best[key], !geminiPrecedes(member, current) { continue }
            best[key] = member
        }
        return best.mapValues(\.id)
    }

    private static func geminiPrecedes(_ lhs: Member, _ rhs: Member) -> Bool {
        let lhsRank = lhs.id.hasSuffix(".jsonl") ? 0 : 1, rhsRank = rhs.id.hasSuffix(".jsonl") ? 0 : 1
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        let lhsCreated = lhs.thread?.createdMs ?? 0, rhsCreated = rhs.thread?.createdMs ?? 0
        if lhsCreated != rhsCreated { return lhsCreated < rhsCreated }
        return ordinal(lhs.id, precedes: rhs.id)
    }

    /// Antigravity databases by lower-cased conversation id (`thread.id`).
    private static func antigravityConversations(_ members: [Member]) -> [String: [String]] {
        var byId: [String: [String]] = [:]
        for member in members where member.family == .antigravity {
            guard let id = member.thread?.id, !id.isEmpty else { continue }
            byId[id.lowercased(), default: []].append(member.id)
        }
        return byId
    }

    /// The database whose conversation id equals `parent_conversation_id` (case-insensitively); with copies in
    /// several stores the one in the same `conversations` folder wins, then the ordinally smallest path.
    private static func antigravityParent(of member: Member, in conversations: [String: [String]]) -> String? {
        guard let parent = member.thread?.parentId, !parent.isEmpty,
              let candidates = conversations[parent.lowercased()] else { return nil }
        let folder = (member.id as NSString).deletingLastPathComponent
        return candidates.min { lhs, rhs in
            let lhsElsewhere = (lhs as NSString).deletingLastPathComponent != folder
            let rhsElsewhere = (rhs as NSString).deletingLastPathComponent != folder
            if lhsElsewhere != rhsElsewhere { return !lhsElsewhere }
            return ordinal(lhs, precedes: rhs)
        }
    }

    /// `<chats>/<dir>/<file>` → the key of the main session named `<dir>`.
    private static func geminiSessionKey(ofSubagent member: Member) -> String? {
        guard let folder = member.thread?.parentId, !folder.isEmpty else { return nil }
        let chats = ((member.id as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return chats + "\u{0}" + folder
    }

    /// Every character outside `[A-Za-z0-9_-]` becomes `_`, as Gemini CLI names sub-agent folders.
    static func sanitizedGeminiId(_ id: String) -> String {
        var result = ""
        result.unicodeScalars.reserveCapacity(id.unicodeScalars.count)
        for scalar in id.unicodeScalars {
            let allowed = scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-")
            result.unicodeScalars.append(allowed ? scalar : "_")
        }
        return result
    }

    /// `<dir>/<session>/subagents/<name>.jsonl` → `<dir>/<session>.jsonl`.
    static func claudeParentPath(of path: String) -> String? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let folder = path[..<slash]
        let marker = "/subagents"
        guard folder.hasSuffix(marker) else { return nil }
        let session = folder.dropLast(marker.count)
        guard let last = session.last, last != "/" else { return nil }
        return session + ".jsonl"
    }

    /// Drops the link of every agent whose chain of parents loops, visiting agents in ordinal id order.
    static func breakCycles(_ parents: inout [String: String]) {
        for id in parents.keys.sorted(by: ordinal) {
            var seen: Set<String> = []
            var current: String? = id
            while let node = current, seen.insert(node).inserted {
                current = parents[node]
            }
            if current != nil { parents[id] = nil }
        }
    }

    /// Ordinal (UTF-16 code unit) order, as on Windows.
    static func ordinal(_ lhs: String, precedes rhs: String) -> Bool {
        lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
    }
}
