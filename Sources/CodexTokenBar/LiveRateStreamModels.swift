import Foundation

extension LiveRateMonitor {
    struct ThreadRow: Decodable {
        let id: String
        let title: String
        let updatedAtMS: Int
        let rolloutPath: String

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case updatedAtMS = "updated_at_ms"
            case rolloutPath = "rollout_path"
        }
    }

    struct LogRow: Decodable {
        let id: Int
        let threadID: String?
        let ts: Int
        let tsNanos: Int
        let target: String
        let feedbackLogBody: String

        enum CodingKeys: String, CodingKey {
            case id
            case threadID = "thread_id"
            case ts
            case tsNanos = "ts_nanos"
            case target
            case feedbackLogBody = "feedback_log_body"
        }
    }

    struct ResponseStreamEvent: Decodable {
        let type: String
        let delta: String?
        let text: String?
        let itemID: String?
        let turnID: String?
        let sequenceNumber: Int?
        let arguments: String?
        let item: ResponseStreamItem?
        let response: ResponseStreamResponse?

        enum CodingKeys: String, CodingKey {
            case type
            case delta
            case text
            case itemID = "item_id"
            case turnID = "turn_id"
            case sequenceNumber = "sequence_number"
            case arguments
            case item
            case response
        }
    }

    struct ResponseStreamItem: Decodable {
        let id: String
        let type: String
        let name: String?
        let callID: String?
        let arguments: String?
        let input: String?
        let content: [ResponseStreamContentPart]?
        let metadata: ResponseStreamMetadata?

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case name
            case callID = "call_id"
            case arguments
            case input
            case content
            case metadata
        }
    }

    struct ResponseStreamContentPart: Decodable {
        let type: String?
        let text: String?
    }

    struct ResponseStreamMetadata: Decodable {
        let turnID: String?

        enum CodingKeys: String, CodingKey {
            case turnID = "turn_id"
        }
    }

    struct ResponseStreamResponse: Decodable {
        let usage: ResponseStreamUsage?
    }

    struct ResponseStreamUsage: Decodable {
        let outputTokens: Int?
        let reasoningOutputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case outputTokens = "output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
        }
    }

    struct RolloutRead {
        let threadID: String
        let path: String
        let newOffset: UInt64
        let events: [RolloutMetricEvent]
    }
}
