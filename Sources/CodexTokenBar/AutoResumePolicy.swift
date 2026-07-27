import Foundation

enum AutoResumeSafetyBlock: Equatable, Sendable {
    case cooldown(until: Date)
    case dailyLimit
}

enum AutoResumePolicy {
    static let capacityRecoveryLookback: TimeInterval = 5 * 60

    static func scheduledTrigger(
        configuration: AutoResumeConfiguration,
        state: AutoResumeRuntimeState,
        now: Date,
        calendar: Calendar = .current
    ) -> AutoResumeTrigger? {
        let configuration = configuration.normalized
        guard configuration.enabled, let target = configuration.target else { return nil }

        switch configuration.scheduleMode {
        case .off:
            return nil
        case .interval:
            let anchor = state.lastIntervalFireAt ?? state.enabledAt ?? now
            let interval = TimeInterval(configuration.intervalMinutes * 60)
            guard now.timeIntervalSince(anchor) >= interval else { return nil }
            let bucket = Int(floor(now.timeIntervalSince1970 / interval))
            return AutoResumeTrigger(
                kind: .interval,
                key: "interval:\(target.id):\(configuration.intervalMinutes):\(bucket)",
                firedAt: now
            )
        case .daily:
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = configuration.dailyHour
            components.minute = configuration.dailyMinute
            components.second = 0
            guard let scheduled = calendar.date(from: components), now >= scheduled else { return nil }
            if let enabledAt = state.enabledAt, scheduled < enabledAt {
                return nil
            }
            let day = dayKey(for: now, calendar: calendar)
            let key = String(
                format: "daily:%@:%@:%02d%02d",
                target.id,
                day,
                configuration.dailyHour,
                configuration.dailyMinute
            )
            guard state.lastDailyTriggerKey != key else { return nil }
            return AutoResumeTrigger(kind: .daily, key: key, firedAt: now)
        }
    }

    static func quotaObservation(
        snapshot: AccountQuotaSnapshot,
        window: AutoResumeQuotaWindow,
        preferredWindowLabel: String? = nil
    ) -> AutoResumeQuotaObservation? {
        guard snapshot.isAvailable, !snapshot.staleDataDisplayed else { return nil }

        let selected: AccountQuotaWindow?
        switch window {
        case .fiveHour:
            selected = snapshot.fiveHour
        case .sevenDay:
            selected = snapshot.sevenDay
        case .lowestRemaining:
            if let preferredWindowLabel {
                selected = [snapshot.fiveHour, snapshot.sevenDay]
                    .compactMap { $0 }
                    .first { $0.label == preferredWindowLabel }
            } else {
                selected = [snapshot.fiveHour, snapshot.sevenDay]
                    .compactMap { $0 }
                    .min { lhs, rhs in lhs.remainingPercent < rhs.remainingPercent }
            }
        }
        guard let selected else { return nil }

        let resetEpoch = selected.resetsAt.map { Int($0.timeIntervalSince1970) }
        let cycle = resetEpoch.map(String.init) ?? "unknown"
        return AutoResumeQuotaObservation(
            windowLabel: selected.label,
            remainingPercent: selected.remainingPercent,
            cycleID: "\(selected.label):\(cycle)"
        )
    }

    private static func quotaRecoveryKeyObservation(
        configuration: AutoResumeConfiguration,
        state: AutoResumeRuntimeState,
        snapshot: AccountQuotaSnapshot,
        selectedObservation: AutoResumeQuotaObservation
    ) -> AutoResumeQuotaObservation? {
        guard configuration.quotaWindow == .lowestRemaining else {
            return selectedObservation
        }

        // 跨端 key 契约：lowestRemaining 有多个真实低位窗口同时恢复时，
        // 两端都按 5h、7d 的固定顺序选择一个单窗口周期。不能继续沿用最初
        // armed 的窗口，否则 7d 先低、5h 后低时 Swift 取 7d、Rust 取 5h。
        var eligibleLabels = Set(state.quotaLowObservedWindowLabels)
        if eligibleLabels.isEmpty,
           let armedLabel = state.quotaArmedWindowLabel {
            eligibleLabels.insert(armedLabel)
        }
        let candidates = [snapshot.fiveHour, snapshot.sevenDay].compactMap { $0 }
        for candidate in candidates
        where eligibleLabels.contains(candidate.label)
            && candidate.remainingPercent >= configuration.quotaResumeAtOrAbovePercent {
            let cycle = candidate.resetsAt
                .map { String(Int($0.timeIntervalSince1970)) }
                ?? "unknown"
            return AutoResumeQuotaObservation(
                windowLabel: candidate.label,
                remainingPercent: candidate.remainingPercent,
                cycleID: "\(candidate.label):\(cycle)"
            )
        }
        return nil
    }

    static func observeQuota(
        configuration: AutoResumeConfiguration,
        state: inout AutoResumeRuntimeState,
        snapshot: AccountQuotaSnapshot,
        now: Date
    ) -> AutoResumeTrigger? {
        let configuration = configuration.normalized
        let preferredWindowLabel = state.quotaArmed
            ? state.quotaArmedWindowLabel
            : nil
        guard configuration.enabled,
              configuration.quotaRecoveryEnabled,
              let target = configuration.target,
              let observation = quotaObservation(
                  snapshot: snapshot,
                  window: configuration.quotaWindow,
                  preferredWindowLabel: preferredWindowLabel
              )
        else {
            return nil
        }

        if state.quotaRecoveryRequiresTransition,
           let armedAt = state.quotaRecoveryArmObservationAt {
            guard let observedAt = snapshot.updatedAt, observedAt > armedAt else {
                return nil
            }
        }

        let hasBaseline = state.lastQuotaCycleID != nil
            && state.lastQuotaWindowLabel != nil
        state.lastQuotaRemainingPercent = observation.remainingPercent
        state.lastQuotaCycleID = observation.cycleID
        state.lastQuotaWindowLabel = observation.windowLabel
        state.lastQuotaObservedAt = snapshot.updatedAt

        // 逐窗口记录"曾进入低位"（与 Rust observe_window 的 armed 标志同语义）：
        // lowestRemaining 的恢复门槛只对这些窗口生效。首次观察仅建立基线，不记录。
        if hasBaseline {
            for window in [snapshot.fiveHour, snapshot.sevenDay].compactMap({ $0 })
            where window.remainingPercent <= configuration.quotaArmAtOrBelowPercent
                && !state.quotaLowObservedWindowLabels.contains(window.label) {
                state.quotaLowObservedWindowLabels.append(window.label)
            }
        }

        if state.quotaArmed {
            if state.quotaArmedWindowLabel == nil {
                state.quotaArmedWindowLabel = observation.windowLabel
            }
            if state.quotaArmedCycleID == nil {
                state.quotaArmedCycleID = observation.cycleID
            }
            if observation.remainingPercent <= configuration.quotaArmAtOrBelowPercent {
                state.quotaRecoveryObservedLow = true
            }

            let cycleChanged = state.quotaArmedCycleID != nil
                && state.quotaArmedCycleID != observation.cycleID
            let everyLowWindowRecovered: Bool
            if configuration.quotaWindow == .lowestRemaining {
                let measuredWindows = [snapshot.fiveHour, snapshot.sevenDay].compactMap { $0 }
                // 决策口径：只有"曾进入低位"的已测窗口才需要达到恢复阈值；从未
                // 低位的另一窗口长期低于恢复阈值（如 7d 常年 10%）不得阻塞触发。
                // 撞限武装（quotaRecoveryRequiresTransition）无法归因触顶窗口，
                // 保守要求全部已测窗口恢复。与 Rust selected_quota_recovered 同语义。
                let windowsRequiredToRecover = state.quotaRecoveryRequiresTransition
                    ? measuredWindows
                    : measuredWindows.filter {
                        state.quotaLowObservedWindowLabels.contains($0.label)
                            || $0.label == state.quotaArmedWindowLabel
                    }
                everyLowWindowRecovered = !measuredWindows.isEmpty
                    && windowsRequiredToRecover.allSatisfy {
                        $0.remainingPercent >= configuration.quotaResumeAtOrAbovePercent
                    }
            } else {
                everyLowWindowRecovered = true
            }
            let recovered = observation.remainingPercent >= configuration.quotaResumeAtOrAbovePercent
                && (state.quotaRecoveryObservedLow || cycleChanged)
                && everyLowWindowRecovered
            guard recovered,
                  let keyObservation = quotaRecoveryKeyObservation(
                      configuration: configuration,
                      state: state,
                      snapshot: snapshot,
                      selectedObservation: observation
                  ) else {
                return nil
            }
            let repeatAfter = keyObservation.cycleID.hasSuffix(":unknown")
                ? state.quotaRecoveryArmObservationAt
                : nil
            // 缺少 reset 时间时，共享 ledger 需要本轮进入低位的时间来区分
            // “同一恢复事件的两个端”和“未来下一轮恢复”。没有这个边界就不能
            // 安全地产生可重复 key，继续等待比跨端双发更安全。
            if keyObservation.cycleID.hasSuffix(":unknown"), repeatAfter == nil {
                return nil
            }

            state.quotaArmed = false
            state.quotaArmedCycleID = nil
            state.quotaArmedWindowLabel = nil
            state.quotaRecoveryRequiresTransition = false
            state.quotaRecoveryObservedLow = false
            state.quotaRecoveryArmObservationAt = nil
            state.quotaLowObservedWindowLabels = []
            return AutoResumeTrigger(
                kind: .quotaRecovery,
                key: "quota:\(target.id):\(keyObservation.cycleID)",
                firedAt: now,
                repeatAfter: repeatAfter
            )
        }

        guard hasBaseline else {
            return nil
        }

        if observation.remainingPercent <= configuration.quotaArmAtOrBelowPercent {
            state.quotaArmed = true
            state.quotaArmedCycleID = observation.cycleID
            state.quotaArmedWindowLabel = observation.windowLabel
            state.quotaRecoveryRequiresTransition = false
            state.quotaRecoveryObservedLow = true
            state.quotaRecoveryArmObservationAt = snapshot.updatedAt
        }
        return nil
    }

    static func armAfterQuotaLimit(
        configuration: AutoResumeConfiguration,
        state: inout AutoResumeRuntimeState,
        now: Date = Date()
    ) {
        let configuration = configuration.normalized
        guard configuration.enabled, configuration.quotaRecoveryEnabled else { return }
        state.quotaArmed = true
        state.quotaArmedCycleID = state.lastQuotaCycleID
        state.quotaArmedWindowLabel = state.lastQuotaWindowLabel
        state.quotaRecoveryRequiresTransition = true
        state.quotaRecoveryObservedLow = false
        // 这是新一轮额度等待的起点，必须晚于刚完成的失败 claim。若沿用上一次
        // 额度采样时间，无 reset 周期会被共享 ledger 判断成旧事件而永久去重。
        state.quotaRecoveryArmObservationAt = now
    }

    static func capacityRecoveryTrigger(
        configuration: AutoResumeConfiguration,
        state: AutoResumeRuntimeState,
        observation: AutoResumeLatestTurnObservation,
        now: Date,
        lookback: TimeInterval = capacityRecoveryLookback
    ) -> AutoResumeTrigger? {
        let configuration = configuration.normalized
        guard configuration.enabled,
              configuration.capacityRecoveryEnabled,
              let target = configuration.target,
              observation.isRecoverableCapacityFailure,
              state.lastCapacityObservedTurnID != observation.turnID else {
            return nil
        }
        let isPending = state.capacityPendingFreshness?.threadID == target.id
            && state.capacityPendingFreshness?.baseline?.lastTurnID == observation.turnID
        if !isPending {
            if let eventAt = observation.completedAt ?? observation.startedAt {
                let oldestAllowed = now.addingTimeInterval(-max(1, lookback))
                guard eventAt >= oldestAllowed,
                      eventAt <= now.addingTimeInterval(60) else {
                    return nil
                }
            } else {
                guard let previousKey = state.lastCapacityMonitorObservationKey,
                      previousKey != observation.monitorKey else {
                    return nil
                }
            }
        }
        return AutoResumeTrigger(
            kind: .capacityRecovery,
            key: "capacity:\(target.id):\(observation.turnID)",
            firedAt: now
        )
    }

    static func safetyBlock(
        configuration: AutoResumeConfiguration,
        state: AutoResumeRuntimeState,
        now: Date,
        calendar: Calendar = .current
    ) -> AutoResumeSafetyBlock? {
        let configuration = configuration.normalized
        if let lastRunAt = state.lastRunAt {
            let cooldownUntil = lastRunAt.addingTimeInterval(
                TimeInterval(configuration.cooldownMinutes * 60)
            )
            if now < cooldownUntil {
                return .cooldown(until: cooldownUntil)
            }
        }

        if let sharedDailyLimitUntil = state.sharedDailyLimitUntil,
           now < sharedDailyLimitUntil {
            return .dailyLimit
        }

        let runsToday = state.runHistory.filter { calendar.isDate($0, inSameDayAs: now) }.count
        if runsToday >= configuration.maxRunsPerDay {
            return .dailyLimit
        }
        return nil
    }

    static func markTriggerAccepted(
        _ trigger: AutoResumeTrigger,
        state: inout AutoResumeRuntimeState
    ) {
        state.lastTriggerKey = trigger.key
        state.lastTriggerKind = trigger.kind
        switch trigger.kind {
        case .interval:
            state.lastIntervalFireAt = trigger.firedAt
        case .daily:
            state.lastDailyTriggerKey = trigger.key
        case .manual, .quotaRecovery, .capacityRecovery:
            break
        }
    }

    static func nextScheduledDate(
        configuration: AutoResumeConfiguration,
        state: AutoResumeRuntimeState,
        now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        let configuration = configuration.normalized
        guard configuration.enabled else { return nil }
        switch configuration.scheduleMode {
        case .off:
            return nil
        case .interval:
            let anchor = state.lastIntervalFireAt ?? state.enabledAt ?? now
            return anchor.addingTimeInterval(TimeInterval(configuration.intervalMinutes * 60))
        case .daily:
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = configuration.dailyHour
            components.minute = configuration.dailyMinute
            components.second = 0
            guard let today = calendar.date(from: components) else { return nil }
            let key = dailyKey(
                threadID: configuration.target?.id ?? "",
                date: now,
                hour: configuration.dailyHour,
                minute: configuration.dailyMinute,
                calendar: calendar
            )
            if now < today, state.lastDailyTriggerKey != key {
                return today
            }
            return calendar.date(byAdding: .day, value: 1, to: today)
        }
    }

    private static func dailyKey(
        threadID: String,
        date: Date,
        hour: Int,
        minute: Int,
        calendar: Calendar
    ) -> String {
        String(
            format: "daily:%@:%@:%02d%02d",
            threadID,
            dayKey(for: date, calendar: calendar),
            hour,
            minute
        )
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            values.year ?? 0,
            values.month ?? 0,
            values.day ?? 0
        )
    }
}
