import Foundation

struct LiveRateSnapshot: Equatable {
    var threadID: String = ""
    var threadTitle: String = "等待当前会话"
    var sourceLabel: String = "logs_2.sqlite"
    var status: String = "等待输出"
    var rollingTokensPerSecond: Double = 0
    var averageTokensPerSecond: Double = 0
    var outputTokens: Int = 0
    var outputCharacters: Int = 0
    var breakdown = LiveTokenBreakdown()
    var scopeLabel: String = "单会话"
    var interfaceLabel: String = "stream deltas + calibrated"
    var updatedAt: Date = Date()

    var shortThreadID: String {
        guard !threadID.isEmpty else { return "未定位" }
        return String(threadID.prefix(8))
    }
}

struct LiveTokenBreakdown: Equatable {
    var visibleText = 0
    var toolArguments = 0
    var patchInput = 0
    var patchApplied = 0
    var toolOutput = 0
    var reasoning = 0
    var exactModelOutput = 0

    var modelGeneratedEstimate: Int {
        visibleText + toolArguments + patchInput + reasoning
    }

    var modelGenerated: Int {
        guard exactModelOutput > 0 else { return modelGeneratedEstimate }
        return max(exactModelOutput, visibleText + toolArguments + patchInput)
    }

    var observedTotal: Int {
        modelGenerated + patchApplied + toolOutput
    }
}

struct LiveThreadOption: Identifiable, Hashable {
    let id: String
    let title: String
    let updatedAtMS: Int
    let rolloutPath: String

    var displayTitle: String {
        title.isEmpty ? "未命名会话" : title
    }

    var shortID: String {
        String(id.prefix(8))
    }
}

enum LiveTokenCategory: String {
    case visibleText
    case toolArguments
    case patchInput
    case patchApplied
    case toolOutput
    case reasoning
}

enum LiveMetricSource {
    case sse
    case websocket
    case rollout
}

struct LiveMetricEvent {
    let source: LiveMetricSource
    let timestamp: TimeInterval
    let startTimestamp: TimeInterval?
    let threadID: String?
    let turnID: String?
    let itemID: String
    let callID: String?
    let sequenceNumber: Int?
    let category: LiveTokenCategory?
    let text: String
    let exactTokens: Int?
    let exactOutputTokens: Int?
    let rollingOnly: Bool
    let isDelta: Bool

    init(
        source: LiveMetricSource,
        timestamp: TimeInterval,
        startTimestamp: TimeInterval? = nil,
        threadID: String? = nil,
        turnID: String? = nil,
        itemID: String,
        callID: String? = nil,
        sequenceNumber: Int? = nil,
        category: LiveTokenCategory?,
        text: String,
        exactTokens: Int? = nil,
        exactOutputTokens: Int? = nil,
        rollingOnly: Bool = false,
        isDelta: Bool = false
    ) {
        self.source = source
        self.timestamp = timestamp
        self.startTimestamp = startTimestamp
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.callID = callID
        self.sequenceNumber = sequenceNumber
        self.category = category
        self.text = text
        self.exactTokens = exactTokens
        self.exactOutputTokens = exactOutputTokens
        self.rollingOnly = rollingOnly
        self.isDelta = isDelta
    }
}

struct RolloutMetricEvent {
    let timestamp: TimeInterval
    let startTimestamp: TimeInterval?
    let key: String
    let category: LiveTokenCategory?
    let text: String
    let exactTokens: Int?
    let exactOutputTokens: Int?
    let rollingOnly: Bool

    init(
        timestamp: TimeInterval,
        startTimestamp: TimeInterval? = nil,
        key: String,
        category: LiveTokenCategory?,
        text: String,
        exactTokens: Int? = nil,
        exactOutputTokens: Int? = nil,
        rollingOnly: Bool = false
    ) {
        self.timestamp = timestamp
        self.startTimestamp = startTimestamp
        self.key = key
        self.category = category
        self.text = text
        self.exactTokens = exactTokens
        self.exactOutputTokens = exactOutputTokens
        self.rollingOnly = rollingOnly
    }
}
