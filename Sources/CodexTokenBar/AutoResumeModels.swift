import Foundation

enum AutoResumeScheduleMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case interval
    case daily

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "不定时"
        case .interval: return "按间隔"
        case .daily: return "每天固定时间"
        }
    }
}

enum AutoResumeQuotaWindow: String, Codable, CaseIterable, Identifiable, Sendable {
    case fiveHour
    case sevenDay
    case lowestRemaining

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fiveHour: return "5 小时额度（若可用）"
        case .sevenDay: return "7 天额度（若可用）"
        case .lowestRemaining: return "可用额度中剩余更低者"
        }
    }
}

struct AutoResumeThreadDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let cwd: String
    let updatedAt: Date?

    var displayTitle: String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? String(id.prefix(12)) : normalized
    }
}

struct AutoResumeConfiguration: Codable, Equatable, Sendable {
    static let defaultPrompt = "继续"
    static let allowedIntervalMinutes = [15, 30, 60, 120, 360, 720]

    var enabled = false
    var target: AutoResumeThreadDescriptor?
    var prompt = defaultPrompt
    var scheduleMode: AutoResumeScheduleMode = .off
    var intervalMinutes = 60
    var dailyHour = 9
    var dailyMinute = 0
    var quotaRecoveryEnabled = true
    var quotaWindow: AutoResumeQuotaWindow = .lowestRemaining
    var quotaArmAtOrBelowPercent = 5
    var quotaResumeAtOrAbovePercent = 20
    var cooldownMinutes = 30
    var maxRunsPerDay = 6
    var notifyOnResult = true

    static let `default` = AutoResumeConfiguration()

    var normalized: AutoResumeConfiguration {
        var copy = self
        copy.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.prompt.isEmpty {
            copy.prompt = Self.defaultPrompt
        }
        copy.intervalMinutes = Self.allowedIntervalMinutes.contains(intervalMinutes)
            ? intervalMinutes
            : 60
        copy.dailyHour = min(max(dailyHour, 0), 23)
        copy.dailyMinute = min(max(dailyMinute, 0), 59)
        copy.quotaArmAtOrBelowPercent = min(max(quotaArmAtOrBelowPercent, 0), 99)
        copy.quotaResumeAtOrAbovePercent = min(
            max(quotaResumeAtOrAbovePercent, copy.quotaArmAtOrBelowPercent + 1),
            100
        )
        copy.cooldownMinutes = min(max(cooldownMinutes, 1), 24 * 60)
        copy.maxRunsPerDay = min(max(maxRunsPerDay, 1), 24)
        return copy
    }
}

enum AutoResumeTriggerKind: String, Codable, Equatable, Sendable {
    case manual
    case interval
    case daily
    case quotaRecovery

    var label: String {
        switch self {
        case .manual: return "手动续跑"
        case .interval: return "间隔定时"
        case .daily: return "每日定时"
        case .quotaRecovery: return "额度恢复"
        }
    }
}

struct AutoResumeTrigger: Equatable, Sendable {
    let kind: AutoResumeTriggerKind
    let key: String
    let firedAt: Date
}

struct AutoResumeThreadFreshness: Codable, Equatable, Sendable {
    let updatedAt: Date?
    let lastTurnID: String?

    func hasProgressed(since baseline: AutoResumeThreadFreshness) -> Bool {
        if let baselineTurnID = baseline.lastTurnID {
            guard let lastTurnID else { return false }
            return lastTurnID != baselineTurnID
        }
        if lastTurnID != nil {
            return true
        }
        guard let baselineUpdatedAt = baseline.updatedAt,
              let updatedAt else {
            return false
        }
        return updatedAt > baselineUpdatedAt
    }
}

struct AutoResumePendingFreshness: Codable, Equatable, Sendable {
    let threadID: String
    let armedAt: Date
    var baseline: AutoResumeThreadFreshness?
}

enum AutoResumeExecutionStatus: String, Codable, Equatable, Sendable {
    case idle
    case refreshingThreads
    case waiting
    case running
    case succeeded
    case failed
    case requiresHuman
    case stopped
}

struct AutoResumeRuntimeState: Codable, Equatable, Sendable {
    var status: AutoResumeExecutionStatus = .idle
    var statusMessage = "自动续跑未启用"
    var enabledAt: Date?
    var lastRunAt: Date?
    var lastSuccessAt: Date?
    var lastTriggerKey: String?
    var lastTriggerKind: AutoResumeTriggerKind?
    var lastError: String?
    var sharedDailyLimitUntil: Date?
    var runHistory: [Date] = []
    var lastIntervalFireAt: Date?
    var lastDailyTriggerKey: String?
    var quotaArmed = false
    var quotaArmedCycleID: String?
    var quotaArmedWindowLabel: String?
    var quotaRecoveryRequiresTransition = false
    var quotaRecoveryObservedLow = false
    var quotaRecoveryArmObservationAt: Date?
    var lastQuotaRemainingPercent: Int?
    var lastQuotaCycleID: String?
    var lastQuotaWindowLabel: String?
    var lastQuotaObservedAt: Date?
    var schedulePendingFreshness: AutoResumePendingFreshness?
    var quotaPendingFreshness: AutoResumePendingFreshness?

    static let `default` = AutoResumeRuntimeState()

    mutating func pruneRunHistory(now: Date, calendar: Calendar) {
        guard let start = calendar.date(byAdding: .day, value: -2, to: now) else { return }
        runHistory.removeAll { $0 < start }
    }
}

struct AutoResumeQuotaObservation: Equatable, Sendable {
    let windowLabel: String
    let remainingPercent: Int
    let cycleID: String
}

struct AutoResumeRunResult: Equatable, Sendable {
    let threadID: String
    let turnID: String
    let status: String
    let message: String?
}

extension AutoResumeConfiguration {
    private enum CodingKeys: String, CodingKey {
        case enabled
        case target
        case prompt
        case scheduleMode
        case intervalMinutes
        case dailyHour
        case dailyMinute
        case quotaRecoveryEnabled
        case quotaWindow
        case quotaArmAtOrBelowPercent
        case quotaResumeAtOrAbovePercent
        case cooldownMinutes
        case maxRunsPerDay
        case notifyOnResult
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var value = Self.default
        value.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? value.enabled
        value.target = try container.decodeIfPresent(AutoResumeThreadDescriptor.self, forKey: .target)
        value.prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? value.prompt
        value.scheduleMode = try container.decodeIfPresent(
            AutoResumeScheduleMode.self,
            forKey: .scheduleMode
        ) ?? value.scheduleMode
        value.intervalMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .intervalMinutes
        ) ?? value.intervalMinutes
        value.dailyHour = try container.decodeIfPresent(Int.self, forKey: .dailyHour) ?? value.dailyHour
        value.dailyMinute = try container.decodeIfPresent(Int.self, forKey: .dailyMinute) ?? value.dailyMinute
        value.quotaRecoveryEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .quotaRecoveryEnabled
        ) ?? value.quotaRecoveryEnabled
        value.quotaWindow = try container.decodeIfPresent(
            AutoResumeQuotaWindow.self,
            forKey: .quotaWindow
        ) ?? value.quotaWindow
        value.quotaArmAtOrBelowPercent = try container.decodeIfPresent(
            Int.self,
            forKey: .quotaArmAtOrBelowPercent
        ) ?? value.quotaArmAtOrBelowPercent
        value.quotaResumeAtOrAbovePercent = try container.decodeIfPresent(
            Int.self,
            forKey: .quotaResumeAtOrAbovePercent
        ) ?? value.quotaResumeAtOrAbovePercent
        value.cooldownMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .cooldownMinutes
        ) ?? value.cooldownMinutes
        value.maxRunsPerDay = try container.decodeIfPresent(
            Int.self,
            forKey: .maxRunsPerDay
        ) ?? value.maxRunsPerDay
        value.notifyOnResult = try container.decodeIfPresent(
            Bool.self,
            forKey: .notifyOnResult
        ) ?? value.notifyOnResult
        self = value
    }
}

extension AutoResumeRuntimeState {
    private enum CodingKeys: String, CodingKey {
        case status
        case statusMessage
        case enabledAt
        case lastRunAt
        case lastSuccessAt
        case lastTriggerKey
        case lastTriggerKind
        case lastError
        case sharedDailyLimitUntil
        case runHistory
        case lastIntervalFireAt
        case lastDailyTriggerKey
        case quotaArmed
        case quotaArmedCycleID
        case quotaArmedWindowLabel
        case quotaRecoveryRequiresTransition
        case quotaRecoveryObservedLow
        case quotaRecoveryArmObservationAt
        case lastQuotaRemainingPercent
        case lastQuotaCycleID
        case lastQuotaWindowLabel
        case lastQuotaObservedAt
        case schedulePendingFreshness
        case quotaPendingFreshness
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var value = Self.default
        value.status = try container.decodeIfPresent(
            AutoResumeExecutionStatus.self,
            forKey: .status
        ) ?? value.status
        value.statusMessage = try container.decodeIfPresent(
            String.self,
            forKey: .statusMessage
        ) ?? value.statusMessage
        value.enabledAt = try container.decodeIfPresent(Date.self, forKey: .enabledAt)
        value.lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        value.lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        value.lastTriggerKey = try container.decodeIfPresent(String.self, forKey: .lastTriggerKey)
        value.lastTriggerKind = try container.decodeIfPresent(
            AutoResumeTriggerKind.self,
            forKey: .lastTriggerKind
        )
        value.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        value.sharedDailyLimitUntil = try container.decodeIfPresent(
            Date.self,
            forKey: .sharedDailyLimitUntil
        )
        value.runHistory = try container.decodeIfPresent([Date].self, forKey: .runHistory) ?? []
        value.lastIntervalFireAt = try container.decodeIfPresent(Date.self, forKey: .lastIntervalFireAt)
        value.lastDailyTriggerKey = try container.decodeIfPresent(String.self, forKey: .lastDailyTriggerKey)
        value.quotaArmed = try container.decodeIfPresent(Bool.self, forKey: .quotaArmed) ?? false
        value.quotaArmedCycleID = try container.decodeIfPresent(String.self, forKey: .quotaArmedCycleID)
        value.quotaArmedWindowLabel = try container.decodeIfPresent(
            String.self,
            forKey: .quotaArmedWindowLabel
        )
        value.quotaRecoveryRequiresTransition = try container.decodeIfPresent(
            Bool.self,
            forKey: .quotaRecoveryRequiresTransition
        ) ?? false
        value.quotaRecoveryObservedLow = try container.decodeIfPresent(
            Bool.self,
            forKey: .quotaRecoveryObservedLow
        ) ?? false
        value.quotaRecoveryArmObservationAt = try container.decodeIfPresent(
            Date.self,
            forKey: .quotaRecoveryArmObservationAt
        )
        value.lastQuotaRemainingPercent = try container.decodeIfPresent(
            Int.self,
            forKey: .lastQuotaRemainingPercent
        )
        value.lastQuotaCycleID = try container.decodeIfPresent(String.self, forKey: .lastQuotaCycleID)
        value.lastQuotaWindowLabel = try container.decodeIfPresent(
            String.self,
            forKey: .lastQuotaWindowLabel
        )
        value.lastQuotaObservedAt = try container.decodeIfPresent(Date.self, forKey: .lastQuotaObservedAt)
        value.schedulePendingFreshness = try container.decodeIfPresent(
            AutoResumePendingFreshness.self,
            forKey: .schedulePendingFreshness
        )
        value.quotaPendingFreshness = try container.decodeIfPresent(
            AutoResumePendingFreshness.self,
            forKey: .quotaPendingFreshness
        )
        self = value
    }
}
