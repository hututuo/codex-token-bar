import Foundation

struct LiveRatePollReadPlan: Equatable {
    let readStreamRows: Bool
    let readRolloutUpdates: Bool
    let recordIdleFallbackPollAt: Bool
    let displayOnlyFastPollActive: Bool

    var readsAnyDataSource: Bool {
        readStreamRows || readRolloutUpdates
    }

    init(
        now: TimeInterval,
        hasLogChangeSignal: Bool,
        fastDisplayWindowActive: Bool,
        activeRollingWindowPresent: Bool,
        lastFallbackPollAt: TimeInterval,
        lastRolloutReadAt: TimeInterval,
        idleFallbackPollInterval: TimeInterval,
        rolloutFallbackPollInterval: TimeInterval
    ) {
        let streamDue = now - lastFallbackPollAt >= idleFallbackPollInterval
        let rolloutDue = now - lastRolloutReadAt >= rolloutFallbackPollInterval

        readStreamRows = hasLogChangeSignal || streamDue
        readRolloutUpdates = hasLogChangeSignal || rolloutDue
        recordIdleFallbackPollAt = readStreamRows && !hasLogChangeSignal
        displayOnlyFastPollActive = (fastDisplayWindowActive || activeRollingWindowPresent)
            && !readStreamRows
            && !readRolloutUpdates
    }
}
