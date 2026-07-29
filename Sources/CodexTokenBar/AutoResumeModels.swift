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
    static let visibleThreadPageSize = 100
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

    static func matchingThreads(
        from threads: [AutoResumeThreadDescriptor],
        projectID: String,
        query: String
    ) -> [AutoResumeThreadDescriptor] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.threads(from: threads, projectID: projectID).filter { thread in
            normalizedQuery.isEmpty
                || thread.displayTitle.localizedCaseInsensitiveContains(normalizedQuery)
                || thread.cwd.localizedCaseInsensitiveContains(normalizedQuery)
                || thread.id.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    static func visibleThreads(
        from threads: [AutoResumeThreadDescriptor],
        projectID: String,
        query: String,
        selectedThreadID: String? = nil,
        limit: Int = visibleThreadPageSize
    ) -> [AutoResumeThreadDescriptor] {
        let matches = matchingThreads(
            from: threads,
            projectID: projectID,
            query: query
        )
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
    // Keep this list aligned with Codex app-server's CodexErrorInfo variants
    // whose affects_turn_status() value is true. UsageLimitExceeded is handled
    // separately by quota recovery. ThreadRollbackFailed and
    // ActiveTurnNotSteerable do not fail a turn and therefore cannot be
    // observed by this post-turn monitor.
    case serverOverloaded
    case httpConnectionFailed
    case responseStreamConnectionFailed
    case responseStreamDisconnected
    case responseTooManyFailedAttempts
    case internalServerError
    case interrupted
    case contextWindowExceeded
    case sessionBudgetExceeded
    case unauthorized
    case badRequest
    case sandboxError
    case cyberPolicy
    case other

    var label: String {
        switch self {
        case .serverOverloaded: return "服务容量不足"
        case .httpConnectionFailed: return "HTTP 连接失败"
        case .responseStreamConnectionFailed: return "响应流连接失败"
        case .responseStreamDisconnected: return "响应流中途断开"
        case .responseTooManyFailedAttempts: return "响应重试耗尽"
        case .internalServerError: return "Codex 内部错误"
        case .interrupted: return "任务被中断"
        case .contextWindowExceeded: return "上下文窗口超限"
        case .sessionBudgetExceeded: return "会话预算耗尽"
        case .unauthorized: return "未授权"
        case .badRequest: return "错误请求"
        case .sandboxError: return "沙盒错误"
        case .cyberPolicy: return "安全策略拒绝"
        case .other: return "其他未分类失败"
        }
    }

    var isRisky: Bool {
        switch self {
        case .interrupted, .contextWindowExceeded, .sessionBudgetExceeded,
             .unauthorized, .badRequest, .sandboxError, .cyberPolicy, .other:
            return true
        case .serverOverloaded, .httpConnectionFailed,
             .responseStreamConnectionFailed, .responseStreamDisconnected,
             .responseTooManyFailedAttempts, .internalServerError:
            return false
        }
    }

    // Trigger keys are persisted in the shared cross-runtime ledger. Preserve
    // the v1 key components so an upgrade cannot run the same failed turn a
    // second time merely because the user-facing taxonomy became exact.
    var triggerKeyComponent: String {
        switch self {
        case .serverOverloaded: return "capacity"
        case .httpConnectionFailed, .responseStreamConnectionFailed,
             .responseStreamDisconnected:
            return "network"
        case .responseTooManyFailedAttempts: return "retryLimit"
        case .internalServerError: return "serverError"
        case .interrupted: return "interrupted"
        case .contextWindowExceeded: return "contextWindow"
        case .sessionBudgetExceeded: return "sessionBudget"
        case .unauthorized: return "authentication"
        case .badRequest: return "requestConflict"
        case .sandboxError: return "sandbox"
        case .cyberPolicy, .other: return "other"
        }
    }

    static func migratedLegacyReasons(_ rawReasons: [String]) -> [Self] {
        var migrated = Set<Self>()
        for rawReason in rawReasons {
            if let exact = Self(rawValue: rawReason) {
                migrated.insert(exact)
                continue
            }
            switch rawReason {
            case "capacity":
                migrated.insert(.serverOverloaded)
            case "serverError":
                migrated.insert(.internalServerError)
            case "retryLimit":
                migrated.insert(.responseTooManyFailedAttempts)
            case "contextWindow":
                migrated.insert(.contextWindowExceeded)
            case "sessionBudget":
                migrated.insert(.sessionBudgetExceeded)
            case "requestConflict":
                migrated.insert(.badRequest)
            case "authentication":
                migrated.insert(.unauthorized)
            case "sandbox":
                migrated.insert(.sandboxError)
            case "interrupted":
                migrated.insert(.interrupted)
            case "other":
                migrated.insert(.other)
            // These former buckets partitioned the same connection variants
            // using HTTP status/message guesses. There is no equally narrow
            // CodexErrorInfo value, so broadening any of them is unsafe.
            case "network", "rateLimit", "timeout":
                break
            default:
                break
            }
        }
        return allCases.filter(migrated.contains)
    }
}

struct AutoResumeConfiguration: Codable, Equatable, Sendable {
    static let defaultPrompt = "继续"
    static let allowedIntervalMinutes = [15, 30, 60, 120, 360, 720]

    var enabled = false
    var target: AutoResumeThreadDescriptor?
    var prompt = defaultPrompt
    // Optional keeps old persisted settings decodable. Normalization migrates
    // the former implicit rule: exact “继续” meant app-server empty input.
    var invisibleResumeEnabled: Bool?
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
        copy.invisibleResumeEnabled = invisibleResumeEnabled
            ?? (copy.prompt == Self.defaultPrompt)
        copy.intervalMinutes = Self.allowedIntervalMinutes.contains(intervalMinutes)
            ? intervalMinutes
            : 60
        copy.dailyHour = min(max(dailyHour, 0), 23)
        copy.dailyMinute = min(max(dailyMinute, 0), 59)
        let requestedReasons: [AutoResumeFailureReason]
        if failureRecoveryPolicyVersion <= 0 {
            requestedReasons = capacityRecoveryEnabled ? [.serverOverloaded] : []
        } else {
            requestedReasons = failureRecoveryReasons
        }
        let selected = Set(requestedReasons)
        copy.failureRecoveryPolicyVersion = 2
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
        failureReason == .serverOverloaded
    }

    var isRecoverableCapacityFailure: Bool {
        failureReason == .serverOverloaded
            && clientUserMessageID != nil
            && !isGeneratedByAutomaticRecovery
    }

    var isQuotaLimitFailure: Bool {
        normalizedStatus == "failed" && normalizedErrorCode == "usagelimitexceeded"
    }

    var failureReason: AutoResumeFailureReason? {
        if normalizedStatus == "interrupted" {
            return .interrupted
        }
        guard normalizedStatus == "failed", !isQuotaLimitFailure else { return nil }

        switch normalizedErrorCode {
        case "serveroverloaded":
            return .serverOverloaded
        case "contextwindowexceeded":
            return .contextWindowExceeded
        case "sessionbudgetexceeded":
            return .sessionBudgetExceeded
        case "httpconnectionfailed":
            return .httpConnectionFailed
        case "responsestreamconnectionfailed":
            return .responseStreamConnectionFailed
        case "responsestreamdisconnected":
            return .responseStreamDisconnected
        case "responsetoomanyfailedattempts":
            return .responseTooManyFailedAttempts
        case "internalservererror":
            return .internalServerError
        case "unauthorized":
            return .unauthorized
        case "badrequest":
            return .badRequest
        case "sandboxerror":
            return .sandboxError
        case "cyberpolicy":
            return .cyberPolicy
        case "other":
            return .other
        // These are real CodexErrorInfo values, but Codex explicitly marks
        // them as not affecting turn status. A post-turn failure monitor must
        // not pretend it can trigger on them.
        case "threadrollbackfailed", "activeturnnotsteerable":
            return nil
        default:
            return nil
        }
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
        case invisibleResumeEnabled
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
        value.invisibleResumeEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .invisibleResumeEnabled
        )
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
        let storedFailurePolicyVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .failureRecoveryPolicyVersion
        ) ?? 0
        let storedFailureReasons = try container.decodeIfPresent(
            [String].self,
            forKey: .failureRecoveryReasons
        ) ?? []
        value.failureRecoveryPolicyVersion = storedFailurePolicyVersion
        if storedFailurePolicyVersion == 1 {
            value.failureRecoveryReasons = AutoResumeFailureReason.migratedLegacyReasons(
                storedFailureReasons
            )
            value.failureRecoveryPolicyVersion = 2
        } else {
            value.failureRecoveryReasons = storedFailureReasons.compactMap(
                AutoResumeFailureReason.init(rawValue:)
            )
        }
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
