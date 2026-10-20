import Foundation

/// Decode large snapshots without materializing historic messages/tool output as Foundation objects.
/// The wire frame is bounded by Desktop's 256 MiB limit. Only live-turn metadata survives decoding.
enum DesktopSnapshotProjection {
    static func project(_ data: Data) -> [String: Any]? {
        guard data.count <= 268_435_456, let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.type == "broadcast", envelope.method == "thread-stream-state-changed",
              envelope.version == 11, envelope.params.hostId == "local", envelope.params.change.type == "snapshot" else { return nil }
        let state = envelope.params.change.conversationState
        guard state.id == envelope.params.conversationId else { return nil }
        return ["type": envelope.type, "method": envelope.method, "version": envelope.version,
                "sourceClientId": envelope.sourceClientId,
                "params": ["hostId": envelope.params.hostId, "conversationId": envelope.params.conversationId,
                           "change": ["type": "snapshot", "revision": envelope.params.change.revision,
                                      "conversationState": state.object]]]
    }
    private struct Envelope: Decodable {
        var type: String; var method: String; var version: Int; var sourceClientId: String; var params: Parameters
    }
    private struct Parameters: Decodable {
        var hostId: String; var conversationId: String; var change: Change
    }
    private struct Change: Decodable {
        var type: String; var revision: Int; var conversationState: State
    }
    private struct State: Decodable {
        var id: String
        var turns: [Turn]?
        var turnHistory: HistoryEnvelope?
        var object: [String: Any] {
            var value: [String: Any] = ["id": id]
            if let turns { value["turns"] = turns.map(\.object) }
            if let turnHistory { value["turnHistory"] = ["history": ["entitiesByKey": turnHistory.history.entitiesByKey.mapValues(\.object)]] }
            return value
        }
    }
    private struct HistoryEnvelope: Decodable { var history: History }
    private struct History: Decodable { var entitiesByKey: [String: Turn] }
    private struct ParametersModel: Decodable { var model: String? }
    private struct Item: Decodable {
        var id: String
        var type: String
        var object: [String: Any] { ["id": id, "type": type, "_tokenbarUnknownTextLength": true] }
    }
    private struct Turn: Decodable {
        var id: String?; var status: String; var model: String?; var items: [Item]; var completed: [String: Bool]
        enum CodingKeys: String, CodingKey { case turnId, status, params, items, completedItemIds }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .turnId)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
            model = try c.decodeIfPresent(ParametersModel.self, forKey: .params)?.model
            if ["inProgress", "pending", "queued", "starting", "waiting"].contains(status) {
                items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
                completed = try c.decodeIfPresent([String: Bool].self, forKey: .completedItemIds) ?? [:]
            } else { items = []; completed = [:] }
        }
        var object: [String: Any] {
            var result: [String: Any] = ["turnId": id ?? NSNull() as Any, "status": status,
                                         "params": ["model": model ?? NSNull() as Any],
                                         "completedItemIds": completed]
            // Preserve indices when a long active turn has more than 512 items. The decoder
            // itself retains just its trailing 512 metadata items.
            result["items"] = items.map(\.object)
            return result
        }
    }
}
