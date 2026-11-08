import Foundation

/// Bounded, display-only extraction. Never feeds task identity, parent links,
/// liveness, deletion authorization or telemetry.
enum RunningTaskTitle {
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        for line in raw.prefix(4096).split(whereSeparator: \.isNewline) {
            var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("#") {
                text = String(text.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
            }
            text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { continue }
            return text.count > 240 ? String(text.prefix(239)) + "…" : text
        }
        return nil
    }

    static func agent(_ metadata: [String: Any]) -> String? {
        let source = metadata["source"] as? [String: Any]
        let subagent = source?["subagent"] as? [String: Any]
        let spawn = subagent?["thread_spawn"] as? [String: Any] ?? [:]
        func value(_ key: String) -> String? { clean(metadata[key] as? String) ?? clean(spawn[key] as? String) }
        let nickname = value("agent_nickname")
        let path = value("agent_path")?.split(separator: "/").last.map(String.init)
        let task = path.flatMap { $0 == "root" ? nil : $0 }
        let role = value("agent_role")
        if let nickname, let detail = task ?? role, detail != nickname { return clean(nickname + " · " + detail) }
        return nickname ?? task ?? role
    }

    static func message(_ object: [String: Any], subagent: Bool) -> String? {
        let type = object["type"] as? String
        let payload = object["payload"] as? [String: Any] ?? object
        let subtype = payload["type"] as? String
        var text: String?
        if type == "event_msg", subtype == "user_message" || subagent && subtype == "agent_message" {
            text = payload["message"] as? String
        } else if type == "response_item", subtype == "message", payload["role"] as? String == "user" {
            text = (payload["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        guard let text else { return nil }
        if subagent, let task = text.prefix(4096).split(whereSeparator: \.isNewline).first(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("task name:")
        }) { return clean(String(task.trimmingCharacters(in: .whitespaces).dropFirst(10))) }
        if type == "event_msg", subtype == "agent_message" { return nil }
        let title = clean(text)
        // Environment/instruction envelopes are not a task title.
        if let title, title.hasPrefix("<"), !title.hasPrefix("<task>") { return nil }
        if title?.hasPrefix("AGENTS.md instructions") == true { return nil }
        return title
    }

    static func fallback(id: String, subagent: Bool) -> String {
        let identifier = id.split(separator: ":").last.map(String.init) ?? id
        return "\(subagent ? "子代理" : "任务") · \(identifier.prefix(8))"
    }
}
