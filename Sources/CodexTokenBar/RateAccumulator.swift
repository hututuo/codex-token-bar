import Foundation

struct RateAccumulator {
    // Completion-only payloads arrive after a tool/edit finishes. Spread them with
    // a conservative virtual rate so the live gauge does not show a completion spike.
    private static let completionPayloadTokensPerSecond: Double = 55
    private static let minimumCompletionPayloadSeconds: TimeInterval = 1
    private static let maximumCompletionPayloadSeconds: TimeInterval = 30
    private static let distributionStepSeconds: TimeInterval = 0.5
    private static let duplicateVisibleCompletionSeconds: TimeInterval = 10
    private static let deltaEstimatorOverlapCharacters = 96

    let resetsOnNewItem: Bool
    private(set) var breakdown = LiveTokenBreakdown()
    var outputTokens: Int { breakdown.observedTotal }
    private(set) var outputCharacters = 0
    private var currentKey = ""
    private var itemText: [String: String] = [:]
    private var itemTokens: [String: Int] = [:]
    private var itemFractionalTokenCarry: [String: Double] = [:]
    private var firstDeltaAt: TimeInterval?
    private var lastDeltaAt: TimeInterval?
    private var rollingDeltas: [(time: TimeInterval, tokens: Int)] = []
    private var recentVisibleCompletions: [String: TimeInterval] = [:]

    init(resetsOnNewItem: Bool) {
        self.resetsOnNewItem = resetsOnNewItem
    }

    var averageRate: Double {
        guard let firstDeltaAt, let lastDeltaAt else { return 0 }
        return Double(outputTokens) / max(0.25, lastDeltaAt - firstDeltaAt)
    }

    mutating func clear() {
        breakdown = LiveTokenBreakdown()
        outputCharacters = 0
        currentKey = ""
        itemText.removeAll()
        itemTokens.removeAll()
        itemFractionalTokenCarry.removeAll()
        firstDeltaAt = nil
        lastDeltaAt = nil
        rollingDeltas.removeAll()
        recentVisibleCompletions.removeAll()
    }

    mutating func add(
        delta: String,
        category: LiveTokenCategory,
        key: String,
        at timestamp: TimeInterval,
        windowSeconds: TimeInterval,
        estimator: (String) -> Int
    ) {
        if resetsOnNewItem, !currentKey.isEmpty, key != currentKey {
            clear()
        }
        currentKey = key

        let previousTail = itemText[key] ?? ""
        let previousTokens = itemTokens[key] ?? 0
        let deltaTokens = estimatedDeltaTokens(
            key: key,
            previousTail: previousTail,
            delta: delta,
            estimator: estimator
        )

        itemText[key] = Self.suffix(previousTail + delta, maxCharacters: Self.deltaEstimatorOverlapCharacters)
        itemTokens[key] = previousTokens + deltaTokens
        outputCharacters += delta.count

        guard deltaTokens > 0 else { return }
        if category.usesConservativeDeltaLiveRate {
            addDistributedLiveRate(tokens: deltaTokens, category: category, key: key, endingAt: timestamp, windowSeconds: windowSeconds)
            return
        }
        add(tokens: deltaTokens, category: category, key: key, at: timestamp, windowSeconds: windowSeconds)
    }

    mutating func add(
        text: String,
        category: LiveTokenCategory,
        key: String,
        at timestamp: TimeInterval,
        windowSeconds: TimeInterval,
        estimator: (String) -> Int
    ) {
        guard !shouldSuppressDuplicateVisibleCompletion(text: text, category: category, key: key, at: timestamp) else {
            return
        }
        let tokens = estimator(text)
        outputCharacters += text.count
        add(tokens: tokens, category: category, key: key, at: timestamp, windowSeconds: windowSeconds)
    }

    mutating func addRollingOnly(
        text: String,
        key: String,
        at timestamp: TimeInterval,
        windowSeconds: TimeInterval,
        estimator: (String) -> Int
    ) {
        let tokens = estimator(text)
        guard tokens > 0 else { return }
        currentKey = key
        outputCharacters += text.count
        if firstDeltaAt == nil {
            firstDeltaAt = timestamp
        }
        lastDeltaAt = timestamp
        rollingDeltas.append((timestamp, tokens))
        prune(now: timestamp, windowSeconds: windowSeconds)
    }

    private mutating func addDistributedLiveRate(
        tokens: Int,
        category: LiveTokenCategory,
        key: String,
        endingAt timestamp: TimeInterval,
        windowSeconds: TimeInterval
    ) {
        addToBreakdown(tokens: tokens, category: category)
        guard category.contributesToLiveRate else { return }

        let duration = estimatedDistributionDuration(tokens: tokens)
        let start = timestamp - duration
        if firstDeltaAt == nil {
            firstDeltaAt = start
        } else if let existing = firstDeltaAt {
            firstDeltaAt = min(existing, start)
        }
        lastDeltaAt = timestamp

        let chunkCount = max(1, min(tokens, Int(ceil(duration / Self.distributionStepSeconds))))
        var emitted = 0
        for index in 1...chunkCount {
            let cumulative = Int((Double(tokens) * Double(index) / Double(chunkCount)).rounded())
            let chunkTokens = cumulative - emitted
            emitted = cumulative
            guard chunkTokens > 0 else { continue }
            let ratio = Double(index) / Double(chunkCount)
            rollingDeltas.append((start + duration * ratio, chunkTokens))
        }

        prune(now: timestamp, windowSeconds: windowSeconds)
    }

    private mutating func estimatedDeltaTokens(
        key: String,
        previousTail: String,
        delta: String,
        estimator: (String) -> Int
    ) -> Int {
        guard !delta.isEmpty else { return 0 }
        let context = Self.suffix(previousTail, maxCharacters: Self.deltaEstimatorOverlapCharacters)
        let previousContextTokens = estimator(context)
        let nextContextTokens = estimator(context + delta)
        let deltaTokens = max(0, nextContextTokens - previousContextTokens)

        if deltaTokens > 0 {
            itemFractionalTokenCarry.removeValue(forKey: key)
            return deltaTokens
        }

        guard context.count >= Self.deltaEstimatorOverlapCharacters else { return 0 }

        let density = Double(previousContextTokens) / Double(context.count)
        guard density.isFinite, density > 0 else { return 0 }

        let carry = (itemFractionalTokenCarry[key] ?? 0) + density * Double(delta.count)
        let carriedTokens = Int(carry.rounded(.down))
        itemFractionalTokenCarry[key] = carry - Double(carriedTokens)
        return max(0, carriedTokens)
    }

    private static func suffix(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let start = text.index(text.endIndex, offsetBy: -maxCharacters)
        return String(text[start...])
    }

    mutating func addDistributed(
        text: String,
        category: LiveTokenCategory,
        key: String,
        startTimestamp: TimeInterval?,
        endingAt timestamp: TimeInterval,
        windowSeconds: TimeInterval,
        estimator: (String) -> Int
    ) {
        guard !shouldSuppressDuplicateVisibleCompletion(text: text, category: category, key: key, at: timestamp) else {
            return
        }
        let tokens = estimator(text)
        outputCharacters += text.count
        addDistributed(tokens: tokens, category: category, key: key, startTimestamp: startTimestamp, endingAt: timestamp, windowSeconds: windowSeconds)
    }

    mutating func add(
        tokens: Int,
        category: LiveTokenCategory,
        key: String,
        at timestamp: TimeInterval,
        windowSeconds: TimeInterval
    ) {
        guard tokens > 0 else { return }
        currentKey = key
        addToBreakdown(tokens: tokens, category: category)
        guard category.contributesToLiveRate else { return }
        if firstDeltaAt == nil {
            firstDeltaAt = timestamp
        }
        lastDeltaAt = timestamp
        rollingDeltas.append((timestamp, tokens))
        prune(now: timestamp, windowSeconds: windowSeconds)
    }

    mutating func addDistributed(
        tokens: Int,
        category: LiveTokenCategory,
        key: String,
        startTimestamp: TimeInterval?,
        endingAt timestamp: TimeInterval,
        windowSeconds: TimeInterval
    ) {
        guard tokens > 0 else { return }
        currentKey = key
        let previousTokens = itemTokens[key] ?? 0
        let deltaTokens = max(0, tokens - previousTokens)
        itemTokens[key] = max(previousTokens, tokens)
        guard deltaTokens > 0 else { return }

        addToBreakdown(tokens: deltaTokens, category: category)
        guard category.contributesToLiveRate else { return }

        let estimatedDuration = estimatedDistributionDuration(tokens: deltaTokens)
        let start: TimeInterval
        let duration: TimeInterval
        let spreadsForward = startTimestamp == nil
        if let startTimestamp {
            start = min(startTimestamp, timestamp)
            duration = max(0.25, max(timestamp - start, estimatedDuration))
        } else {
            start = timestamp
            duration = estimatedDuration
        }

        if firstDeltaAt == nil {
            firstDeltaAt = start
        } else if let existing = firstDeltaAt {
            firstDeltaAt = min(existing, start)
        }
        lastDeltaAt = spreadsForward ? timestamp + duration : timestamp

        let chunkCount = max(1, min(deltaTokens, Int(ceil(duration / Self.distributionStepSeconds))))
        var emitted = 0
        for index in 1...chunkCount {
            let cumulative = Int((Double(deltaTokens) * Double(index) / Double(chunkCount)).rounded())
            let chunkTokens = cumulative - emitted
            emitted = cumulative
            guard chunkTokens > 0 else { continue }
            let ratio = Double(index) / Double(chunkCount)
            let chunkTime = spreadsForward ? start + duration * ratio : start + duration * ratio
            rollingDeltas.append((chunkTime, chunkTokens))
        }

        prune(now: timestamp, windowSeconds: windowSeconds)
    }

    mutating func addExactModelOutput(_ tokens: Int) {
        guard tokens > 0 else { return }
        breakdown.exactModelOutput += tokens
    }

    mutating func prune(now: TimeInterval, windowSeconds: TimeInterval) {
        guard let firstVisibleIndex = rollingDeltas.firstIndex(where: { now - $0.time <= windowSeconds }) else {
            rollingDeltas.removeAll(keepingCapacity: true)
            return
        }
        if firstVisibleIndex > rollingDeltas.startIndex {
            rollingDeltas.removeSubrange(..<firstVisibleIndex)
        }
    }

    func rollingRate(now: TimeInterval, windowSeconds: TimeInterval, minimumSpan: TimeInterval) -> Double {
        let visibleDeltas = rollingDeltas.filter { $0.time <= now }
        guard let first = visibleDeltas.first else { return 0 }
        let span = max(minimumSpan, min(windowSeconds, now - first.time))
        return Double(visibleDeltas.reduce(0) { $0 + $1.tokens }) / span
    }

    func hasRecentActivity(now: TimeInterval, windowSeconds: TimeInterval) -> Bool {
        rollingDeltas.contains { $0.time <= now && now - $0.time <= windowSeconds }
    }

    func hasRetainedRollingActivity(now: TimeInterval, windowSeconds: TimeInterval) -> Bool {
        rollingDeltas.contains { $0.time > now || now - $0.time <= windowSeconds }
    }

    private mutating func addToBreakdown(tokens: Int, category: LiveTokenCategory) {
        switch category {
        case .visibleText:
            breakdown.visibleText += tokens
        case .toolArguments:
            breakdown.toolArguments += tokens
        case .patchInput:
            breakdown.patchInput += tokens
        case .patchApplied:
            breakdown.patchApplied += tokens
        case .toolOutput:
            breakdown.toolOutput += tokens
        case .reasoning:
            breakdown.reasoning += tokens
        }
    }

    private func estimatedDistributionDuration(tokens: Int) -> TimeInterval {
        min(
            Self.maximumCompletionPayloadSeconds,
            max(Self.minimumCompletionPayloadSeconds, Double(tokens) / Self.completionPayloadTokensPerSecond)
        )
    }

    private mutating func shouldSuppressDuplicateVisibleCompletion(
        text: String,
        category: LiveTokenCategory,
        key: String,
        at timestamp: TimeInterval
    ) -> Bool {
        guard category == .visibleText, !text.isEmpty else { return false }
        recentVisibleCompletions = recentVisibleCompletions.filter { timestamp - $0.value <= Self.duplicateVisibleCompletionSeconds }
        let fingerprint = "\(scopePrefix(from: key)):\(text)"
        if let previous = recentVisibleCompletions[fingerprint],
           timestamp - previous <= Self.duplicateVisibleCompletionSeconds {
            return true
        }
        recentVisibleCompletions[fingerprint] = timestamp
        return false
    }

    private func scopePrefix(from key: String) -> String {
        key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? key
    }
}

extension LiveTokenCategory {
    var contributesToLiveRate: Bool {
        switch self {
        case .visibleText, .toolArguments, .patchInput:
            return true
        case .patchApplied, .toolOutput, .reasoning:
            return false
        }
    }

    var usesConservativeDeltaLiveRate: Bool {
        switch self {
        case .toolArguments, .patchInput:
            return true
        case .visibleText, .patchApplied, .toolOutput, .reasoning:
            return false
        }
    }
}
