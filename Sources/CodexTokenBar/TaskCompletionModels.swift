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
    let legacyIDs: Set<String>

    init(
        id: String,
        threadID: String,
        title: String,
        body: String,
        legacyIDs: Set<String> = []
    ) {
        self.id = id
        self.threadID = threadID
        self.title = title
        self.body = body
        self.legacyIDs = legacyIDs
    }
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
