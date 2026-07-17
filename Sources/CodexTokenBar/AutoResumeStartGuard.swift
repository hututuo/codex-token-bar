import Foundation

enum AutoResumeStartGuardError: LocalizedError, Equatable, Sendable {
    case invalidated

    var errorDescription: String? {
        "自动续跑设置已变化，旧触发已作废"
    }
}

private enum AutoResumeStartSource: Equatable, Sendable {
    case interval
    case daily
    case quota
    case capacity
}

private struct AutoResumeStartToken: Equatable, Sendable {
    let source: AutoResumeStartSource
    let targetID: String
    let generation: UInt64
}

struct AutoResumeStartAuthorization: Sendable {
    fileprivate let gate: AutoResumeStartGuard
    fileprivate let token: AutoResumeStartToken

    var isValid: Bool {
        gate.isValid(token)
    }

    func withValidatedStart<T>(_ operation: () throws -> T) throws -> T {
        try gate.withValidatedStart(token, operation: operation)
    }
}

final class AutoResumeStartGuard: @unchecked Sendable {
    private struct ScheduleSignature: Equatable {
        let enabled: Bool
        let targetID: String?
        let mode: AutoResumeScheduleMode
        let intervalMinutes: Int
        let dailyHour: Int
        let dailyMinute: Int
        let cooldownMinutes: Int
        let maxRunsPerDay: Int
    }

    private struct QuotaSignature: Equatable {
        let enabled: Bool
        let targetID: String?
        let quotaRecoveryEnabled: Bool
        let window: AutoResumeQuotaWindow
        let armAtOrBelowPercent: Int
        let resumeAtOrAbovePercent: Int
        let cooldownMinutes: Int
        let maxRunsPerDay: Int
    }

    private struct CapacitySignature: Equatable {
        let enabled: Bool
        let targetID: String?
        let capacityRecoveryEnabled: Bool
        let prompt: String
        let cooldownMinutes: Int
        let maxRunsPerDay: Int
    }

    private let lock = NSLock()
    private var configuration: AutoResumeConfiguration
    private var scheduleSignature: ScheduleSignature
    private var quotaSignature: QuotaSignature
    private var capacitySignature: CapacitySignature
    private var scheduleGeneration: UInt64 = 0
    private var quotaGeneration: UInt64 = 0
    private var capacityGeneration: UInt64 = 0

    init(configuration: AutoResumeConfiguration) {
        let configuration = configuration.normalized
        self.configuration = configuration
        scheduleSignature = Self.scheduleSignature(configuration)
        quotaSignature = Self.quotaSignature(configuration)
        capacitySignature = Self.capacitySignature(configuration)
    }

    func update(configuration: AutoResumeConfiguration) {
        let configuration = configuration.normalized
        lock.lock()
        defer { lock.unlock() }
        let nextScheduleSignature = Self.scheduleSignature(configuration)
        let nextQuotaSignature = Self.quotaSignature(configuration)
        let nextCapacitySignature = Self.capacitySignature(configuration)
        if nextScheduleSignature != scheduleSignature {
            scheduleGeneration &+= 1
            scheduleSignature = nextScheduleSignature
        }
        if nextQuotaSignature != quotaSignature {
            quotaGeneration &+= 1
            quotaSignature = nextQuotaSignature
        }
        if nextCapacitySignature != capacitySignature {
            capacityGeneration &+= 1
            capacitySignature = nextCapacitySignature
        }
        self.configuration = configuration
    }

    func authorization(
        for triggerKind: AutoResumeTriggerKind,
        targetID: String
    ) -> AutoResumeStartAuthorization? {
        lock.lock()
        defer { lock.unlock() }
        let source: AutoResumeStartSource
        let generation: UInt64
        switch triggerKind {
        case .manual:
            return nil
        case .interval:
            guard configuration.enabled,
                  configuration.target?.id == targetID,
                  configuration.scheduleMode == .interval else {
                return nil
            }
            source = .interval
            generation = scheduleGeneration
        case .daily:
            guard configuration.enabled,
                  configuration.target?.id == targetID,
                  configuration.scheduleMode == .daily else {
                return nil
            }
            source = .daily
            generation = scheduleGeneration
        case .quotaRecovery:
            guard configuration.enabled,
                  configuration.target?.id == targetID,
                  configuration.quotaRecoveryEnabled else {
                return nil
            }
            source = .quota
            generation = quotaGeneration
        case .capacityRecovery:
            guard configuration.enabled,
                  configuration.target?.id == targetID,
                  configuration.capacityRecoveryEnabled else {
                return nil
            }
            source = .capacity
            generation = capacityGeneration
        }
        return AutoResumeStartAuthorization(
            gate: self,
            token: AutoResumeStartToken(
                source: source,
                targetID: targetID,
                generation: generation
            )
        )
    }

    fileprivate func isValid(_ token: AutoResumeStartToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isValidLocked(token)
    }

    fileprivate func withValidatedStart<T>(
        _ token: AutoResumeStartToken,
        operation: () throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard isValidLocked(token) else {
            throw AutoResumeStartGuardError.invalidated
        }
        return try operation()
    }

    private func isValidLocked(_ token: AutoResumeStartToken) -> Bool {
        guard configuration.enabled, configuration.target?.id == token.targetID else {
            return false
        }
        switch token.source {
        case .interval:
            return configuration.scheduleMode == .interval
                && token.generation == scheduleGeneration
        case .daily:
            return configuration.scheduleMode == .daily
                && token.generation == scheduleGeneration
        case .quota:
            return configuration.quotaRecoveryEnabled
                && token.generation == quotaGeneration
        case .capacity:
            return configuration.capacityRecoveryEnabled
                && token.generation == capacityGeneration
        }
    }

    private static func scheduleSignature(
        _ configuration: AutoResumeConfiguration
    ) -> ScheduleSignature {
        ScheduleSignature(
            enabled: configuration.enabled,
            targetID: configuration.target?.id,
            mode: configuration.scheduleMode,
            intervalMinutes: configuration.intervalMinutes,
            dailyHour: configuration.dailyHour,
            dailyMinute: configuration.dailyMinute,
            cooldownMinutes: configuration.cooldownMinutes,
            maxRunsPerDay: configuration.maxRunsPerDay
        )
    }

    private static func quotaSignature(
        _ configuration: AutoResumeConfiguration
    ) -> QuotaSignature {
        QuotaSignature(
            enabled: configuration.enabled,
            targetID: configuration.target?.id,
            quotaRecoveryEnabled: configuration.quotaRecoveryEnabled,
            window: configuration.quotaWindow,
            armAtOrBelowPercent: configuration.quotaArmAtOrBelowPercent,
            resumeAtOrAbovePercent: configuration.quotaResumeAtOrAbovePercent,
            cooldownMinutes: configuration.cooldownMinutes,
            maxRunsPerDay: configuration.maxRunsPerDay
        )
    }

    private static func capacitySignature(
        _ configuration: AutoResumeConfiguration
    ) -> CapacitySignature {
        CapacitySignature(
            enabled: configuration.enabled,
            targetID: configuration.target?.id,
            capacityRecoveryEnabled: configuration.capacityRecoveryEnabled,
            prompt: configuration.prompt,
            cooldownMinutes: configuration.cooldownMinutes,
            maxRunsPerDay: configuration.maxRunsPerDay
        )
    }
}
