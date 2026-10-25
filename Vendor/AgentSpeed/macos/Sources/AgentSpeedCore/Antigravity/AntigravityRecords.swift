import Foundation

/// `ModelUsageStats` of a planner step (METRICS 4.8). Token fields are the raw unsigned values, at most
/// `AntigravityBlobs.maxTokens` each (a larger value makes the step malformed).
struct AntigravityUsage: Equatable, Sendable {
    /// `input_tokens` (2), excluding cached input.
    var input: Int64 = 0
    /// `output_tokens` (3), including thinking.
    var output: Int64 = 0
    /// `cache_read_tokens` (5).
    var cacheRead: Int64 = 0
    /// `thinking_output_tokens` (9).
    var thinking: Int64 = 0
    /// `response_output_tokens` (10).
    var response: Int64 = 0
    /// `response_id` (11) when non-empty, else `message_id` (7) when non-empty.
    var key: String?

    var hasTokens: Bool { input > 0 || output > 0 || cacheRead > 0 || thinking > 0 || response > 0 }

    /// Normalized usage (METRICS 4.8 Tokens).
    var tokens: TokenUsage {
        TokenUsage(
            input: Int(input + cacheRead),
            cachedInput: Int(cacheRead),
            cacheWriteInput: 0,
            output: Int(output > 0 ? output : thinking + response),
            reasoning: Int(thinking)
        )
    }
}

/// `CortexStepMetadata` (`steps.metadata`). Timestamps are Unix milliseconds of valid `Timestamp`s, else nil.
struct AntigravityStepMetadata: Equatable, Sendable {
    /// `created_at` (1).
    var createdMs: Int64?
    /// `viewable_at` (6).
    var viewableMs: Int64?
    /// `finished_generating_at` (7).
    var finishedGeneratingMs: Int64?
    /// `completed_at` (8).
    var completedMs: Int64?
    /// `last_completed_chunk_at` (22).
    var lastCompletedChunkMs: Int64?
    /// `started_at` (32).
    var startedMs: Int64?
    /// `model_usage` (9), when present.
    var usage: AntigravityUsage?

    /// Every valid timestamp of the row.
    var timestamps: [Int64] {
        [createdMs, viewableMs, finishedGeneratingMs, completedMs, lastCompletedChunkMs, startedMs].compactMap { $0 }
    }
}

/// `CortexStepGeneratorMetadata` (`gen_metadata.data`).
struct AntigravityGeneration: Equatable, Sendable {
    /// `step_indices` (2), packed or unpacked.
    var stepIndices: Set<UInt64> = []
    /// `chat_model.response_model` (1 → 19), else `chat_model.model_display_name` (1 → 21); empty strings are nil.
    var model: String?
}

/// `ExecutorMetadata` (`executor_metadata.data`).
struct AntigravityExecutor: Equatable, Sendable {
    /// `termination_reason` (1); 0 while the run has not ended.
    var terminationReason: Int64 = 0
    /// `last_step_idx` (3), signed.
    var lastStepIdx: Int64 = 0
    /// `cascade_config.planner_config.model_name` (10 → 1 → 28); empty is nil.
    var model: String?
}

/// `CortexTrajectoryMetadata` (`trajectory_metadata_blob.data`).
struct AntigravityTrajectory: Equatable, Sendable {
    /// `created_at` (2).
    var createdMs: Int64?
    /// Basename of the first `workspace_uris` entry, else of the first workspace's folder URI.
    var project: String?
    /// The local path of the URI `project` comes from, when it is a `file:` URI (METRICS 10.6).
    var cwdPath: String?
    /// `parent_conversation_id` (5); empty is nil.
    var parentConversationId: String?
    /// A parent id, `nesting_depth > 0` or a `subagent_spec`.
    var isSubagent = false
}

/// A `steps` row as read (METRICS 4.8). `metadata` is nil when the column is NULL or over the size guard.
struct AntigravityStepRow: Equatable, Sendable {
    var idx: Int64
    var stepType: Int64
    var status: Int64
    var metadata: LineExtraction<AntigravityStepMetadata>?
}

/// A `gen_metadata` or `executor_metadata` row; `value` is nil when the blob is NULL or over the size guard.
struct AntigravityIndexedRow<Value: Equatable & Sendable>: Equatable, Sendable {
    var idx: Int64
    var value: LineExtraction<Value>?
}

/// The rows of one read of a conversation database, in `idx, rowid` order per table (METRICS 5.4).
struct AntigravityBatch: Equatable, Sendable {
    /// The database has no `steps` table with the required columns: it contributes nothing (`unsupportedFormat`).
    var unsupported = false
    /// The trajectory metadata row, when this read looked for it and found a non-NULL blob.
    var trajectory: LineExtraction<AntigravityTrajectory>?
    var generations: [AntigravityIndexedRow<AntigravityGeneration>] = []
    var executors: [AntigravityIndexedRow<AntigravityExecutor>] = []
    var steps: [AntigravityStepRow] = []
}

/// Step types and statuses of METRICS 4.8.
enum AntigravityStep {
    static let userInput: Int64 = 14
    static let plannerResponse: Int64 = 15
    static let done: Int64 = 3
    /// `PENDING`, `RUNNING`, `GENERATING`, `WAITING`, `QUEUED`; every other status is terminal.
    static let openStatuses: Set<Int64> = [1, 2, 8, 9, 11]
    /// `CANCELED`, `ERROR`, `INTERRUPTED`: responses count in totals only.
    static let failedStatuses: Set<Int64> = [6, 7, 12]

    static func isOpen(_ status: Int64) -> Bool { openStatuses.contains(status) }
}
