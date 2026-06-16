import Foundation

struct RateAccumulator {
    // Completion-only payloads arrive after a tool/edit finishes. Spread them with
    // a conservative virtual rate so the live gauge does not show a completion spike.
    private static let completionPayloadTokensPerSecond: Double = 55
    private static let minimumCompletionPayloadSeconds: TimeInterval = 1
    private static let maximumCompletionPayloadSeconds: TimeInterval = 30
    private static let distributionStepSeconds: TimeInterval = 0.5

    let resetsOnNewItem: Bool
    private(set) var breakdown = LiveTokenBreakdown()
    var outputTokens: Int { breakdown.observedTotal }
    private(set) var outputCharacters = 0
    private var currentKey = ""
    private var itemText: [String: String] = [:]
    private var itemTokens: [String: Int] = [:]
    private var firstDeltaAt: TimeInterval?
    private var lastDeltaAt: TimeInterval?
    private var rollingDeltas: [(time: TimeInterval, tokens: Int)] = []

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
        firstDeltaAt = nil
        lastDeltaAt = nil
        rollingDeltas.removeAll()
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

        let previousText = itemText[key] ?? ""
        let nextText = previousText + delta
        let previousTokens = itemTokens[key] ?? 0
        let nextTokens = estimator(nextText)
        let deltaTokens = max(0, nextTokens - previousTokens)

        itemText[key] = nextText
        itemTokens[key] = nextTokens
        outputCharacters += delta.count

        guard deltaTokens > 0 else { return }
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

    mutating func addDistributed(
        text: String,
        category: LiveTokenCategory,
        key: String,
        startTimestamp: TimeInterval?,
        endingAt timestamp: TimeInterval,
        windowSeconds: TimeInterval,
        estimator: (String) -> Int
    ) {
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
        rollingDeltas.removeAll { now - $0.time > windowSeconds }
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
}
