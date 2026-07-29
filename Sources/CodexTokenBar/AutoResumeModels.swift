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

struct AutoResumeProjectDescriptor: Equatable, Identifiable, Sendable {
    let id: String
    let cwd: String
    let displayName: String
    let threadCount: Int
    let updatedAt: Date?
}

enum AutoResumeThreadPicker {
    static let visibleThreadLimit = 100
    static let missingProjectID = "__codex_token_bar_no_cwd__"

    static func projectID(for cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return missingProjectID }
        return (trimmed as NSString).standardizingPath
    }

    static func projects(from threads: [AutoResumeThreadDescriptor]) -> [AutoResumeProjectDescriptor] {
        Dictionary(grouping: threads, by: { projectID(for: $0.cwd) })
            .map { id, projectThreads in
                let cwd = id == missingProjectID ? "" : id
                let folderName = cwd.isEmpty ? "未记录工作目录" : URL(fileURLWithPath: cwd).lastPathComponent
                return AutoResumeProjectDescriptor(
                    id: id,
                    cwd: cwd,
                    displayName: folderName.isEmpty ? cwd : folderName,
                    threadCount: projectThreads.count,
                    updatedAt: projectThreads.compactMap(\.updatedAt).max()
                )
            }
            .sorted { left, right in
                let leftDate = left.updatedAt ?? .distantPast
                let rightDate = right.updatedAt ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
                let nameOrder = left.displayName.localizedCaseInsensitiveCompare(right.displayName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return left.cwd.localizedCaseInsensitiveCompare(right.cwd) == .orderedAscending
            }
    }

    static func resolvedProjectID(
        projects: [AutoResumeProjectDescriptor],
        currentID: String,
        preferredCWD: String
    ) -> String {
        if projects.contains(where: { $0.id == currentID }) { return currentID }
        let preferredID = projectID(for: preferredCWD)
        if projects.contains(where: { $0.id == preferredID }) { return preferredID }
        return projects.first?.id ?? ""
    }

    static func threads(
        from threads: [AutoResumeThreadDescriptor],
        projectID: String
    ) -> [AutoResumeThreadDescriptor] {
        guard !projectID.isEmpty else { return [] }
        return threads
            .filter { self.projectID(for: $0.cwd) == projectID }
            .sorted(by: threadSort)
    }

    static func visibleThreads(
        from threads: [AutoResumeThreadDescriptor],
        projectID: String,
        query: String,
        selectedThreadID: String? = nil,
        limit: Int = visibleThreadLimit
    ) -> [AutoResumeThreadDescriptor] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = self.threads(from: threads, projectID: projectID).filter { thread in
            normalizedQuery.isEmpty
                || thread.displayTitle.localizedCaseInsensitiveContains(normalizedQuery)
                || thread.cwd.localizedCaseInsensitiveContains(normalizedQuery)
                || thread.id.localizedCaseInsensitiveContains(normalizedQuery)
        }
        let boundedLimit = max(1, limit)
        var visible = Array(matches.prefix(boundedLimit))
        guard let selectedThreadID,
              !visible.contains(where: { $0.id == selectedThreadID }),
              let selected = matches.first(where: { $0.id == selectedThreadID }) else {
            return visible
        }
        if visible.count == boundedLimit {
            visible.removeLast()
        }
        visible.append(selected)
        return visible
    }

    private static func threadSort(
        left: AutoResumeThreadDescriptor,
        right: AutoResumeThreadDescriptor
    ) -> Bool {
        let leftDate = left.updatedAt ?? .distantPast
        let rightDate = right.updatedAt ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        return left.id < right.id
    }
}

enum AutoResumeFailureReason: String, Codable, CaseIterable, Hashable, Sendable {
    case capacity
    case network
    case rateLimit
    case serverError
    case timeout
    case retryLimit
    case contextWindow
    case sessionBudget
    case requestConflict
    case authentication
    case sandbox
    case interrupted
    case other

    var label: String {
        switch self {
        case .capacity: return "容量不足"
        case .network: return "网络断开"
        case .rateLimit: return "请求限流"
        case .serverError: return "服务端错误"
        case .timeout: return "请求超时"
        case .retryLimit: return "重试次数耗尽"
        case .contextWindow: return "上下文超限"
        case .sessionBudget: return "会话预算耗尽"
        case .requestConflict: return "请求状态冲突"
        case .authentication: return "登录或鉴权失败"
        case .sandbox: return "沙盒或权限错误"
        case .interrupted: return "任务被中断"
        case .other: return "其他失败"
        }
    }

    var isRisky: Bool {
        switch self {
        case .contextWindow, .sessionBudget, .requestConflict, .authentication,
             .sandbox, .interrupted, .other:
            return true
        case .capacity, .network, .rateLimit, .serverError, .timeout, .retryLimit:
            return false
        }
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
    var failureRecoveryPolicyVersion = 0
    var failureRecoveryReasons: [AutoResumeFailureReason] = []
    // 兼容旧设置与旧版跨端读取。规范化后它表示“至少选择了一个即时失败原因”。
    var capacityRecoveryEnabled = false
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
        let requestedReasons: [AutoResumeFailureReason]
        if failureRecoveryPolicyVersion <= 0 {
            requestedReasons = capacityRecoveryEnabled ? [.capacity] : []
        } else {
            requestedReasons = failureRecoveryReasons
        }
        let selected = Set(requestedReasons)
        copy.failureRecoveryPolicyVersion = 1
        copy.failureRecoveryReasons = AutoResumeFailureReason.allCases.filter(selected.contains)
        copy.capacityRecoveryEnabled = !copy.failureRecoveryReasons.isEmpty
        copy.quotaArmAtOrBelowPercent = min(max(quotaArmAtOrBelowPercent, 0), 99)
        copy.quotaResumeAtOrAbovePercent = min(
            max(quotaResumeAtOrAbovePercent, copy.quotaArmAtOrBelowPercent + 1),
            100
        )
        copy.cooldownMinutes = min(max(cooldownMinutes, 1), 24 * 60)
        copy.maxRunsPerDay = min(max(maxRunsPerDay, 1), 24)
        return copy
    }

    var hasAutomaticTrigger: Bool {
        scheduleMode != .off || capacityRecoveryEnabled || quotaRecoveryEnabled
    }

    var selectedFailureReasons: Set<AutoResumeFailureReason> {
        Set(normalized.failureRecoveryReasons)
    }
}

struct AutoResumeTaskDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let createdAt: Date
    var updatedAt: Date
    var configuration: AutoResumeConfiguration

    init(
        id: String = UUID().uuidString.lowercased(),
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        configuration: AutoResumeConfiguration
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.configuration = configuration.normalized
    }

    var normalized: AutoResumeTaskDefinition {
        var copy = self
        copy.configuration = configuration.normalized
        if copy.configuration.target == nil || !copy.configuration.hasAutomaticTrigger {
            copy.configuration.enabled = false
        }
        return copy
    }
}

struct AutoResumeTaskCollection: Codable, Equatable, Sendable {
    var schemaVersion = 2
    var selectedTaskID: String?
    var tasks: [AutoResumeTaskDefinition] = []

    static let empty = AutoResumeTaskCollection()

    var normalized: AutoResumeTaskCollection {
        var seenTaskIDs = Set<String>()
        var seenThreadIDs = Set<String>()
        let normalizedTasks = tasks.compactMap { task -> AutoResumeTaskDefinition? in
            let normalized = task.normalized
            guard !normalized.id.isEmpty,
                  seenTaskIDs.insert(normalized.id).inserted,
                  let threadID = normalized.configuration.target?.id,
                  !threadID.isEmpty,
                  seenThreadIDs.insert(threadID).inserted else {
                return nil
            }
            return normalized
        }
        let selected = selectedTaskID.flatMap { id in
            normalizedTasks.contains(where: { $0.id == id }) ? id : nil
        } ?? normalizedTasks.first?.id
        return AutoResumeTaskCollection(
            schemaVersion: 2,
            selectedTaskID: selected,
            tasks: normalizedTasks
        )
    }
}

enum AutoResumeTriggerKind: String, Codable, Equatable, Sendable {
    case manual
    case interval
    case daily
    case quotaRecovery
    case capacityRecovery

    var label: String {
        switch self {
        case .manual: return "手动续跑"
        case .interval: return "间隔定时"
        case .daily: return "每日定时"
        case .quotaRecovery: return "额度恢复"
        case .capacityRecovery: return "失败中断续跑"
        }
    }
}

struct AutoResumeTrigger: Equatable, Sendable {
    let kind: AutoResumeTriggerKind
    let key: String
    let firedAt: Date
    let repeatAfter: Date?

    init(
        kind: AutoResumeTriggerKind,
        key: String,
        firedAt: Date,
        repeatAfter: Date? = nil
    ) {
        self.kind = kind
        self.key = key
        self.firedAt = firedAt
        self.repeatAfter = repeatAfter
    }
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

struct AutoResumeLatestTurnObservation: Equatable, Sendable {
    static let automaticCapacityClientIDPrefix = "capacity:"
    static let automaticFailureClientIDPrefix = "failure:"

    let turnID: String
    let status: String
    let startedAt: Date?
    let completedAt: Date?
    let errorMessage: String?
    let codexErrorCode: String?
    let httpStatusCode: Int?
    let clientUserMessageID: String?

    init(
        turnID: String,
        status: String,
        startedAt: Date? = nil,
        completedAt: Date?,
        errorMessage: String?,
        codexErrorCode: String?,
        httpStatusCode: Int? = nil,
        clientUserMessageID: String?
    ) {
        self.turnID = turnID
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.codexErrorCode = codexErrorCode
        self.httpStatusCode = httpStatusCode
        self.clientUserMessageID = clientUserMessageID
    }

    var freshness: AutoResumeThreadFreshness {
        AutoResumeThreadFreshness(updatedAt: completedAt ?? startedAt, lastTurnID: turnID)
    }

    var monitorKey: String {
        let code = codexErrorCode?.lowercased() ?? "none"
        return "\(turnID)|\(normalizedStatus)|\(code)"
    }

    var isGeneratedByAutomaticRecovery: Bool {
        guard let clientUserMessageID else { return false }
        return clientUserMessageID.hasPrefix(Self.automaticCapacityClientIDPrefix)
            || clientUserMessageID.hasPrefix(Self.automaticFailureClientIDPrefix)
    }

    var isGeneratedByCapacityRecovery: Bool {
        isGeneratedByAutomaticRecovery
    }

    var isServerCapacityFailure: Bool {
        failureReason == .capacity
    }

    var isRecoverableCapacityFailure: Bool {
        failureReason == .capacity
            && clientUserMessageID != nil
            && !isGeneratedByAutomaticRecovery
    }

    var isQuotaLimitFailure: Bool {
        guard normalizedStatus == "failed" else { return false }
        if normalizedErrorCode == "usagelimitexceeded" {
            return true
        }
        return Self.messageContains(
            errorMessage,
            anyOf: [
                "usage limit", "usage_limit", "insufficient_quota", "quota exceeded",
                "额度耗尽", "额度已用完", "使用额度已达上限",
            ]
        )
    }

    var failureReason: AutoResumeFailureReason? {
        if normalizedStatus == "interrupted" {
            return .interrupted
        }
        guard normalizedStatus == "failed", !isQuotaLimitFailure else { return nil }

        switch normalizedErrorCode {
        case "serveroverloaded":
            return .capacity
        case "contextwindowexceeded":
            return .contextWindow
        case "sessionbudgetexceeded":
            return .sessionBudget
        case "httpconnectionfailed", "responsestreamconnectionfailed",
             "responsestreamdisconnected":
            if let statusReason { return statusReason }
            return .network
        case "responsetoomanyfailedattempts":
            return .retryLimit
        case "activeturnnotsteerable", "badrequest":
            return .requestConflict
        case "unauthorized":
            return .authentication
        case "sandboxerror":
            return .sandbox
        case "internalservererror":
            return .serverError
        case "other":
            return .other
        default:
            break
        }

        if Self.messageContains(
            errorMessage,
            anyOf: [
                "selected model is at capacity", "server is overloaded", "server overloaded",
                "insufficient capacity", "no available capacity",
                "currently experiencing high demand", "服务容量不足", "服务器容量不足",
            ]
        ) {
            return .capacity
        }
        if let statusReason { return statusReason }
        if Self.messageContains(
            errorMessage,
            anyOf: [
                "rate limit", "rate_limit", "too many requests", "请求过于频繁", "限流",
            ]
        ) {
            return .rateLimit
        }
        if Self.messageContains(
            errorMessage,
            anyOf: ["timed out", "timeout", "deadline exceeded", "请求超时", "连接超时"]
        ) {
            return .timeout
        }
        if Self.messageContains(
            errorMessage,
            anyOf: [
                "connection reset", "connection refused", "connection failed",
                "network error", "network unreachable", "dns", "stream disconnected",
                "stream connection", "网络连接", "网络中断", "连接断开",
            ]
        ) {
            return .network
        }
        if Self.messageContains(
            errorMessage,
            anyOf: ["context window", "context length", "上下文窗口", "上下文超限"]
        ) {
            return .contextWindow
        }
        if Self.messageContains(
            errorMessage,
            anyOf: ["session budget", "会话预算", "本轮预算"]
        ) {
            return .sessionBudget
        }
        if Self.messageContains(
            errorMessage,
            anyOf: ["unauthorized", "authentication", "invalid api key", "鉴权", "未授权"]
        ) {
            return .authentication
        }
        if Self.messageContains(
            errorMessage,
            anyOf: ["sandbox", "permission denied", "沙盒", "权限不足"]
        ) {
            return .sandbox
        }
        if Self.messageContains(
            errorMessage,
            anyOf: ["too many failed attempts", "retry attempts", "重试次数"]
        ) {
            return .retryLimit
        }
        if Self.messageContains(
            errorMessage,
            anyOf: ["bad request", "not steerable", "conflict", "请求冲突", "状态冲突"]
        ) {
            return .requestConflict
        }
        if Self.messageContains(
            errorMessage,
            anyOf: ["internal server", "service unavailable", "server error", "服务端错误"]
        ) {
            return .serverError
        }
        return .other
    }

    func isRecoverableFailure(selectedReasons: Set<AutoResumeFailureReason>) -> Bool {
        guard let failureReason else { return false }
        return selectedReasons.contains(failureReason)
            && clientUserMessageID != nil
            && !isGeneratedByAutomaticRecovery
    }

    private var normalizedErrorCode: String? {
        codexErrorCode?.lowercased().filter(\.isLetter)
    }

    private var statusReason: AutoResumeFailureReason? {
        guard let httpStatusCode else { return nil }
        switch httpStatusCode {
        case 401, 403: return .authentication
        case 408: return .timeout
        case 429: return .rateLimit
        case 500...599: return .serverError
        default: return nil
        }
    }

    private static func messageContains(_ message: String?, anyOf needles: [String]) -> Bool {
        guard let message = message?.lowercased() else { return false }
        return needles.contains { message.contains($0) }
    }

    private var normalizedStatus: String {
        status.lowercased().filter(\.isLetter)
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
    var capacityMonitorArmedAt: Date?
    var lastCapacityMonitorObservationKey: String?
    var lastCapacityObservedTurnID: String?
    var capacityPendingFreshness: AutoResumePendingFreshness?
    var quotaArmed = false
    var quotaArmedCycleID: String?
    var quotaArmedWindowLabel: String?
    var quotaRecoveryRequiresTransition = false
    var quotaRecoveryObservedLow = false
    var quotaRecoveryArmObservationAt: Date?
    // 本轮武装期内"曾进入低位"的窗口标签（"5h"/"7d"）。lowestRemaining 恢复
    // 门槛只对这些窗口生效，与 Rust 端按窗口的 armed 标志同语义。
    var quotaLowObservedWindowLabels: [String] = []
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
        case failureRecoveryPolicyVersion
        case failureRecoveryReasons
        case capacityRecoveryEnabled
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
        value.failureRecoveryPolicyVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .failureRecoveryPolicyVersion
        ) ?? 0
        value.failureRecoveryReasons = try container.decodeIfPresent(
            [AutoResumeFailureReason].self,
            forKey: .failureRecoveryReasons
        ) ?? []
        value.capacityRecoveryEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .capacityRecoveryEnabled
        ) ?? value.capacityRecoveryEnabled
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
        self = value.normalized
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
        case capacityMonitorArmedAt
        case lastCapacityMonitorObservationKey
        case lastCapacityObservedTurnID
        case capacityPendingFreshness
        case quotaArmed
        case quotaArmedCycleID
        case quotaArmedWindowLabel
        case quotaRecoveryRequiresTransition
        case quotaRecoveryObservedLow
        case quotaRecoveryArmObservationAt
        case quotaLowObservedWindowLabels
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
        value.capacityMonitorArmedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .capacityMonitorArmedAt
        )
        value.lastCapacityMonitorObservationKey = try container.decodeIfPresent(
            String.self,
            forKey: .lastCapacityMonitorObservationKey
        )
        value.lastCapacityObservedTurnID = try container.decodeIfPresent(
            String.self,
            forKey: .lastCapacityObservedTurnID
        )
        value.capacityPendingFreshness = try container.decodeIfPresent(
            AutoResumePendingFreshness.self,
            forKey: .capacityPendingFreshness
        )
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
        value.quotaLowObservedWindowLabels = try container.decodeIfPresent(
            [String].self,
            forKey: .quotaLowObservedWindowLabels
        ) ?? []
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
