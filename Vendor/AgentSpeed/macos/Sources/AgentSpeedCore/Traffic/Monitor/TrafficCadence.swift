import Foundation

/// The nettop interval (METRICS 10.10): stopped while no agent process exists; `-s 5` while agent processes exist but
/// no agent has been active for 60 s and nothing visible shows per-source or per-agent traffic; else `-s 1`. A running
/// child changes its interval at most once per 30 s.
struct TrafficCadence: Equatable {
    static let fastInterval = 1
    static let slowInterval = 5
    static let idleAfterMs: Int64 = 60_000
    static let minimumChangeMs: Int64 = 30_000

    /// The interval to run at, or nil for standby.
    static func desiredInterval(hasAgentProcess: Bool, lastActiveWallMs: Int64?, nowWallMs: Int64, detailDemand: Bool,
                                forced: Int?) -> Int? {
        if let forced { return forced > 0 ? forced : nil }
        guard hasAgentProcess else { return nil }
        if detailDemand { return fastInterval }
        guard let lastActiveWallMs, nowWallMs - lastActiveWallMs < idleAfterMs else { return slowInterval }
        return fastInterval
    }

    /// Whether a child running at `current` (nil: none) should be (re)started at `desired` now.
    static func shouldApply(desired: Int, current: Int?, lastChangeMs: Int64?, nowMs: Int64, forced: Bool) -> Bool {
        guard let current else { return true }
        guard current != desired else { return false }
        if forced { return true }
        return lastChangeMs.map { nowMs - $0 >= minimumChangeMs } ?? true
    }

    /// The newest moment any agent was active (METRICS 10.6): working now, or its last line.
    static func lastActive(_ agents: [TrafficAgent], nowWallMs: Int64) -> Int64? {
        var newest: Int64?
        for agent in agents {
            guard case .live(let working, let lastLineMs) = agent.activity else { continue }
            let moment = working ? nowWallMs : lastLineMs
            if let moment, moment > (newest ?? .min) { newest = moment }
        }
        return newest
    }
}

extension TrafficAgent {
    /// The traffic view of one 6.7 row: its transcript when the id is a path (OpenCode ids are not).
    init(_ status: AgentStatus) {
        let lastLineMs = Int64((status.lastActivity.timeIntervalSince1970 * 1000).rounded(.down))
        self.init(
            id: status.id, source: status.source, parentId: status.parentId, cwdPath: status.cwdPath,
            transcript: status.id.hasPrefix("/") ? status.id : nil,
            activity: .live(working: status.phase != .idle, lastLineMs: lastLineMs > 0 ? lastLineMs : nil))
    }
}
