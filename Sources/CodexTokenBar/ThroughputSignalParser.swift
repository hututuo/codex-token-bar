import Foundation

extension ThroughputSignal {
    static func parse(object: [String: Any], payload: [String: Any], at: Double, turn: String?) -> ThroughputSignal? {
        let record = object["type"] as? String ?? ""
        let type = payload["type"] as? String ?? ""
        let turnID = payload["turn_id"] as? String ?? turn ?? ""
        var signal = ThroughputSignal(kind: "", timestamp: at, turnID: turnID)
        if record == "turn_context" {
            signal.kind = "context"; signal.model = payload["model"] as? String ?? "unknown"
        } else if record == "token_usage_record", let usage = payload["usage"] as? [String: Any] {
            signal.kind = "usage"; signal.itemID = payload["response_id"] as? String ?? "\(at)"
            signal.output = (usage["output_tokens"] as? NSNumber)?.doubleValue ?? 0
            signal.reasoning = (usage["reasoning_output_tokens"] as? NSNumber)?.doubleValue ?? 0
        } else if record == "event_msg" {
            switch type {
            case "task_started": signal.kind = "start"
            case "task_complete": signal.kind = payload["error"] == nil || payload["error"] is NSNull ? "complete" : "failure"
            case "turn_aborted", "task_aborted": signal.kind = "abort"
            case "item_completed":
                let item = payload["item"] as? [String: Any] ?? [:]
                signal.itemID = item["id"] as? String ?? payload["item_id"] as? String ?? ""
                signal.kind = "itemDone"
                if (item["type"] as? String)?.lowercased() == "reasoning" {
                    signal.kind = "reasoning"
                    let start = (payload["started_at_ms"] as? NSNumber)?.doubleValue ?? (item["started_at_ms"] as? NSNumber)?.doubleValue
                    let end = (payload["completed_at_ms"] as? NSNumber)?.doubleValue ?? (item["completed_at_ms"] as? NSNumber)?.doubleValue
                    if let start, let end, end >= start { signal.duration = (end - start) / 1000 }
                }
            default: return nil
            }
        } else { return nil }
        return signal
    }
}
