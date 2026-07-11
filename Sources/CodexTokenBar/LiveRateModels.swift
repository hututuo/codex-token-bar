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

    var rollingTokensPerSecondText: String {
        Self.rateDisplayText(rollingTokensPerSecond)
    }

    static func rateDisplayText(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0.0" }
        return String(format: "%.1f", value)
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

    var normalizedRolloutPath: String? {
        let trimmed = rolloutPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    var hasRolloutPath: Bool {
        normalizedRolloutPath != nil
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

struct RecentFingerprintSet {
    private let limit: Int
    private var values: Set<String> = []
    private var insertionOrder: [String] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var count: Int {
        values.count
    }

    func contains(_ value: String) -> Bool {
        values.contains(value)
    }

    mutating func insertIfNew(_ value: String) -> Bool {
        guard !values.contains(value) else { return false }
        values.insert(value)
        insertionOrder.append(value)
        pruneOverflow()
        return true
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
    }

    private mutating func pruneOverflow() {
        let overflow = insertionOrder.count - limit
        guard overflow > 0 else { return }
        for oldValue in insertionOrder.prefix(overflow) {
            values.remove(oldValue)
        }
        insertionOrder.removeFirst(overflow)
    }
}

enum LiveMetricSource {
    case sse
    case websocket
    case bridgedLog
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
    let turnID: String?
    let itemID: String?
    let category: LiveTokenCategory?
    let text: String
    let exactTokens: Int?
    let exactOutputTokens: Int?
    let rollingOnly: Bool

    init(
        timestamp: TimeInterval,
        startTimestamp: TimeInterval? = nil,
        key: String,
        turnID: String? = nil,
        itemID: String? = nil,
        category: LiveTokenCategory?,
        text: String,
        exactTokens: Int? = nil,
        exactOutputTokens: Int? = nil,
        rollingOnly: Bool = false
    ) {
        self.timestamp = timestamp
        self.startTimestamp = startTimestamp
        self.key = key
        self.turnID = turnID
        self.itemID = itemID
        self.category = category
        self.text = text
        self.exactTokens = exactTokens
        self.exactOutputTokens = exactOutputTokens
        self.rollingOnly = rollingOnly
    }
}

struct VisibleTextSummary: Equatable {
    private(set) var utf8Count = 0
    private(set) var hashA: UInt64 = 14_695_981_039_346_656_037
    private(set) var hashB: UInt64 = 5_381
    private(set) var prefix: [UInt8] = []
    private(set) var suffix: [UInt8] = []
    private(set) var exactText: String? = ""

    init() {}

    init(text: String) {
        append(text)
    }

    var identityComponent: String {
        "\(utf8Count):\(hashA):\(hashB):\(prefix):\(suffix)"
    }

    mutating func append(_ text: String) {
        let bytes = Array(text.utf8)
        utf8Count += bytes.count
        for byte in bytes {
            hashA = (hashA ^ UInt64(byte)) &* 1_099_511_628_211
            hashB = ((hashB &* 33) ^ UInt64(byte)) &+ 0x9e3779b97f4a7c15
        }
        if prefix.count < 64 {
            prefix.append(contentsOf: bytes.prefix(64 - prefix.count))
        }
        suffix.append(contentsOf: bytes)
        if suffix.count > 64 {
            suffix.removeFirst(suffix.count - 64)
        }
        if let current = exactText, current.utf8.count + bytes.count <= 32_768 {
            exactText = current + text
        } else {
            exactText = nil
        }
    }
}

enum VisibleMessageIdentity {
    static func key(threadID: String, turnID: String?, itemID: String) -> String {
        if let turnID, !turnID.isEmpty {
            return "thread:\(threadID)|turn:\(turnID)|item:\(itemID)"
        }
        return fallbackKey(threadID: threadID, itemID: itemID)
    }

    static func fallbackKey(threadID: String, itemID: String) -> String {
        "thread:\(threadID)|item:\(itemID)"
    }
}

struct RecentVisibleTextAssemblies {
    private struct Entry {
        let threadID: String
        let itemID: String
        var turnID: String?
        var summary = VisibleTextSummary()
    }

    private let limit: Int
    private var values: [String: Entry] = [:]
    private var insertionOrder: [String] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var count: Int { values.count }

    mutating func append(_ text: String, threadID: String, turnID: String?, itemID: String) {
        guard !text.isEmpty else { return }
        let key = VisibleMessageIdentity.key(threadID: threadID, turnID: turnID, itemID: itemID)
        if let turnID, !turnID.isEmpty {
            let fallbackKey = VisibleMessageIdentity.fallbackKey(threadID: threadID, itemID: itemID)
            let hasKnownTurnAssembly = values.values.contains {
                $0.threadID == threadID && $0.itemID == itemID && $0.turnID?.isEmpty == false
            }
            if !hasKnownTurnAssembly,
               key != fallbackKey,
               values[key] == nil,
               var fallback = values.removeValue(forKey: fallbackKey) {
                fallback.turnID = turnID
                values[key] = fallback
                if let index = insertionOrder.firstIndex(of: fallbackKey) {
                    insertionOrder[index] = key
                }
            }
        }
        if values[key] == nil {
            insertionOrder.append(key)
        }
        var entry = values[key] ?? Entry(threadID: threadID, itemID: itemID, turnID: turnID)
        entry.turnID = entry.turnID ?? turnID
        entry.summary.append(text)
        values[key] = entry
        let overflow = insertionOrder.count - limit
        guard overflow > 0 else { return }
        for expired in insertionOrder.prefix(overflow) {
            values.removeValue(forKey: expired)
        }
        insertionOrder.removeFirst(overflow)
    }

    func matchingIdentities(
        text: String,
        threadID: String,
        turnID: String?,
        itemID: String?
    ) -> [String] {
        let summary = VisibleTextSummary(text: text)
        let hasKnownTurnAssembly: Bool
        if let itemID, !itemID.isEmpty, let turnID, !turnID.isEmpty {
            hasKnownTurnAssembly = values.values.contains {
                $0.threadID == threadID && $0.itemID == itemID && $0.turnID?.isEmpty == false
            }
        } else {
            hasKnownTurnAssembly = false
        }
        return insertionOrder.filter { key in
            guard let entry = values[key], entry.threadID == threadID, entry.summary == summary else { return false }
            if let itemID, !itemID.isEmpty {
                guard entry.itemID == itemID else { return false }
                if let turnID, !turnID.isEmpty {
                    if entry.turnID == turnID { return true }
                    return entry.turnID?.isEmpty != false && !hasKnownTurnAssembly
                }
                return true
            }
            guard let turnID else { return false }
            return entry.turnID == turnID
        }
    }

    mutating func removeAll() {
        values.removeAll()
        insertionOrder.removeAll()
    }
}
