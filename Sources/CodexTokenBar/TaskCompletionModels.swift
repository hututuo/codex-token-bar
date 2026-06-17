import Foundation

struct TaskCompletionFileState: Sendable {
    var offset: UInt64
    var sessionID: String
    var cwd: String
    var isSubagent: Bool
    var lastUserText: String
    var activeTurns: [String: TaskCompletionTurnState]
}

struct TaskCompletionTurnState: Sendable {
    var startedAt: TimeInterval
    var lastUserText: String
}

struct TaskCompletionEvent: Sendable {
    let id: String
    let threadID: String
    let title: String
    let body: String
}

struct TaskCompletionScanResult: Sendable {
    let states: [String: TaskCompletionFileState]
    let events: [TaskCompletionEvent]
    let fileCount: Int
}

struct CodexUnreadThreadState: Sendable {
    var threadIDs: Set<String> = []
}

enum CodexUnreadThreadReadResult: Sendable {
    case available(Set<String>)
    case unavailable
}
