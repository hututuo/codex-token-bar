import Foundation

enum RunningThreadFreshness: String, Equatable, Sendable {
    case loading
    case fresh
    case stale
    case unavailable
}

struct RunningThreadSummary: Equatable, Sendable {
    let main: Int
    let subagents: Int
    let updatedAt: Date?
    let freshness: RunningThreadFreshness

    init(
        main: Int,
        subagents: Int,
        updatedAt: Date?,
        freshness: RunningThreadFreshness
    ) {
        self.main = max(0, main)
        self.subagents = max(0, subagents)
        self.updatedAt = updatedAt
        self.freshness = freshness
    }

    var total: Int {
        main + subagents
    }

    static let loading = RunningThreadSummary(
        main: 0,
        subagents: 0,
        updatedAt: nil,
        freshness: .loading
    )

    static let unavailable = RunningThreadSummary(
        main: 0,
        subagents: 0,
        updatedAt: nil,
        freshness: .unavailable
    )

    func markedStale() -> RunningThreadSummary {
        guard freshness == .fresh || freshness == .stale else {
            return .unavailable
        }
        return RunningThreadSummary(
            main: main,
            subagents: subagents,
            updatedAt: updatedAt,
            freshness: .stale
        )
    }
}

struct RunningThreadPresentation: Equatable {
    let summary: RunningThreadSummary

    var displayText: String {
        guard hasCounts else {
            return "运行 -- · 主 -- · 子 --"
        }
        return "运行 \(summary.total) · 主 \(summary.main) · 子 \(summary.subagents)"
    }

    var accessibilityText: String {
        switch summary.freshness {
        case .loading:
            return "正在读取当前运行线程"
        case .unavailable:
            return "当前运行线程暂时无法读取"
        case .fresh:
            return "当前运行 \(summary.total) 个线程，主线程 \(summary.main) 个，子 Agent \(summary.subagents) 个"
        case .stale:
            return "当前显示上次读取的运行线程，共 \(summary.total) 个，主线程 \(summary.main) 个，子 Agent \(summary.subagents) 个"
        }
    }

    var hasCounts: Bool {
        summary.freshness == .fresh || summary.freshness == .stale
    }
}

enum RunningThreadLifecycle: Equatable, Sendable {
    case unknown
    case running
    case idle
}

struct RunningThreadFileState: Equatable, Sendable {
    let deviceID: UInt64?
    let fileID: UInt64?
    var offset: UInt64
    var observedSize: UInt64
    var boundarySignature: UInt64
    var sessionID: String
    var isSubagent: Bool
    var lifecycle: RunningThreadLifecycle
    var lifecycleAt: Date?
    var modifiedAt: Date
}

struct RunningThreadScanResult: Equatable, Sendable {
    let states: [String: RunningThreadFileState]
    let summary: RunningThreadSummary
}
