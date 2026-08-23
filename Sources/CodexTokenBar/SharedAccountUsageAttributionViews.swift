import SwiftUI

struct SharedAccountUsageAttributionPresentation: Equatable {
    let result: SharedAccountUsageAttributionResult

    var iconName: String {
        switch result.state {
        case .withinTolerance: "checkmark.circle"
        case .suspectedNonLocalUsage: "person.2.fill"
        case .localEstimateExceedsAccountDrop: "exclamationmark.triangle"
        case .disabled: "person.2.slash"
        case .preciseUsageStale: "arrow.clockwise.circle"
        case .attributionStorageUnavailable: "externaldrive.badge.exclamationmark"
        case .localHistoryAmbiguous: "archivebox.badge.exclamationmark"
        case .awaitingAccountSwitchBaseline: "person.crop.circle.badge.clock"
        default: "hourglass"
        }
    }

    var accentRole: SemanticAccentRole {
        if result.usedHighWatermark { return .amber }
        return switch result.state {
        case .withinTolerance: .green
        case .suspectedNonLocalUsage: .amber
        case .localEstimateExceedsAccountDrop: .amber
        case .disabled, .preciseUsagePending, .preciseUsageStale, .attributionStorageUnavailable,
             .awaitingAccountSwitchBaseline,
             .missingSevenDayQuota, .missingQuotaReset,
             .missingStableAccountIdentity, .localHistoryAmbiguous,
             .missingRadarTierBaseline, .missingCompatiblePriceRevision, .awaitingQuotaRefresh:
            .blue
        }
    }

    var stateTitle: String {
        switch result.state {
        case .disabled: return "共享归因已关闭"
        case .preciseUsagePending: return "精确 token 待读取"
        case .preciseUsageStale: return "等待精确用量刷新"
        case .attributionStorageUnavailable: return "归因安全记录不可用"
        case .localHistoryAmbiguous: return "本机历史无法安全对账"
        case .awaitingAccountSwitchBaseline:
            return switch result.cutoverReason {
            case .continuityGap: "等待数据连续性基线"
            case .storageRecovery: "等待重建后的安全基线"
            case .legacyMigration: "等待升级安全基线"
            case .initialActivation: "等待首次安全基线"
            case .accountSwitch, .none: "等待账号切换基线"
            }
        case .missingSevenDayQuota: return "7 天额度待读取"
        case .missingQuotaReset: return "等待 7 天重置时间"
        case .missingStableAccountIdentity: return "等待稳定账号身份"
        case .missingRadarTierBaseline: return "Radar 套餐基准缺失"
        case .missingCompatiblePriceRevision: return "Radar 价格版本未知"
        case .awaitingQuotaRefresh:
            if result.quotaDataStale && result.radarDataStale { return "等待额度与 Radar 刷新" }
            if result.radarDataStale { return "等待 Radar 刷新" }
            if result.quotaDataStale { return "等待额度刷新" }
            return "等待额度刷新"
        case .withinTolerance: return "差值在估算误差内"
        case .suspectedNonLocalUsage: return "检测到正的非本机差额"
        case .localEstimateExceedsAccountDrop: return "本机估值高于账号实降"
        }
    }

    var summaryLine: String {
        guard let account = result.accountUsedPercent,
              let local = result.localSharePercent,
              let difference = result.nonLocalDifferencePercent else {
            return stateTitle
        }
        let accountLabel = result.usesSegmentBaseline ? "账号本段" : "账号"
        guard result.hasFinalAttributionConclusion else {
            return "\(accountLabel) \(Self.percent(account))  ｜  本机 \(Self.percent(local))  ｜  \(stateTitle)"
        }
        return "\(accountLabel) \(Self.percent(account))  ｜  本机 \(Self.percent(local))  ｜  差 \(Self.signedPercent(difference))"
    }

    var summaryDetail: String {
        guard result.hasComputedAttribution else {
            return "\(result.tier.title) · \(modelLine)"
        }
        var parts = [result.tier.title, result.priceRevision.isLegacy ? "Radar 旧价" : "现行价", stateTitle]
        if result.quotaDataStale { parts.append("额度旧数据") }
        if result.radarDataStale { parts.append("Radar 旧数据") }
        if result.usedHighWatermark { parts.append("已保护历史高水位") }
        return parts.joined(separator: " · ")
    }

    var modelLine: String {
        let detected = result.detectedModels.map(\.quotaEstimateShortTitle)
        let excludedText = !result.excludedModels.isEmpty
            ? "\(result.excludedModels.joined(separator: "/")) \(result.excludedCalls) 次独立额度，不参与 API 等值"
            : ""
        if detected.isEmpty {
            if result.fallbackModelCalls == 0, !excludedText.isEmpty {
                return excludedText
            }
            return "未知模型回退：\(result.model.title)\(excludedText.isEmpty ? "" : " · \(excludedText)")"
        }
        let automatic = "自动：\(detected.joined(separator: "/"))"
        let fallback = result.fallbackModelCalls > 0
            ? " · \(result.fallbackModelCalls) 次回退 \(result.model.quotaEstimateShortTitle)"
            : ""
        return automatic + fallback + (excludedText.isEmpty ? "" : " · \(excludedText)")
    }

    var compactSummaryLine: String {
        guard let local = result.localSharePercent,
              let difference = result.nonLocalDifferencePercent else {
            switch result.state {
            case .preciseUsagePending: return "归因待读取"
            case .preciseUsageStale: return "归因待精确刷新"
            case .attributionStorageUnavailable: return "归因记录异常"
            case .localHistoryAmbiguous: return "归因待历史核对"
            case .awaitingAccountSwitchBaseline:
                return result.cutoverReason == .continuityGap
                    || result.cutoverReason == .storageRecovery
                    ? "归因待安全基线"
                    : "归因待切换基线"
            case .missingSevenDayQuota, .missingQuotaReset: return "归因待额度"
            case .missingStableAccountIdentity: return "归因待账号"
            case .missingRadarTierBaseline: return "归因待 Radar"
            case .missingCompatiblePriceRevision: return "归因待价格"
            case .awaitingQuotaRefresh: return "归因待刷新"
            case .disabled: return "归因已关"
            case .withinTolerance, .suspectedNonLocalUsage, .localEstimateExceedsAccountDrop:
                return "归因待计算"
            }
        }
        switch result.state {
        case .suspectedNonLocalUsage:
            return "本≈\(Self.compactPercent(local))·差\(Self.compactSignedPercent(difference))"
        case .withinTolerance:
            return "本≈\(Self.compactPercent(local))·差<2%"
        case .localEstimateExceedsAccountDrop:
            return "本机估高\(Self.compactSignedPercent(difference))"
        case .awaitingQuotaRefresh:
            return "本≈\(Self.compactPercent(local))·待刷新"
        case .disabled, .preciseUsagePending, .preciseUsageStale, .attributionStorageUnavailable,
             .awaitingAccountSwitchBaseline,
             .missingSevenDayQuota, .missingQuotaReset,
             .missingStableAccountIdentity, .localHistoryAmbiguous,
             .missingRadarTierBaseline, .missingCompatiblePriceRevision:
            return "归因待计算"
        }
    }

    var localFormula: String {
        guard let localCost = result.localComparableCostUSD,
              let radarTotal = result.radarSevenDayTotalUSD,
              let localShare = result.localSharePercent else {
            return "本机占比 = 本机同基准金额 ÷ Radar \(result.tier.title) 7 天总额 × 100"
        }
        return "本机占比 = \(Self.money(localCost)) ÷ \(Self.money(radarTotal)) × 100 = \(Self.percent(localShare))"
    }

    var differenceFormula: String {
        guard result.hasFinalAttributionConclusion else {
            return "非本机差额暂不归因：等待额度、精确用量与安全基线对齐"
        }
        guard let account = result.accountUsedPercent,
              let local = result.localSharePercent,
              let difference = result.nonLocalDifferencePercent else {
            return "非本机差额 = 账号当前归因段已用 − 本机占比"
        }
        let prefix = result.usesSegmentBaseline ? "账号本段" : "账号当前周期"
        return "非本机差额 = \(prefix) \(Self.percent(account)) − \(Self.percent(local)) = \(Self.signedPercent(difference))"
    }

    var accessibilityValue: String {
        "\(summaryLine)，\(summaryDetail)"
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    static func signedPercent(_ value: Double) -> String {
        String(format: "%+.1f%%", value)
    }

    static func compactPercent(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }

    static func compactSignedPercent(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%+d%%", Int(value)) : String(format: "%+.1f%%", value)
    }

    static func money(_ value: Double) -> String {
        if value >= 1_000 {
            return String(format: "$%.2f", value)
        }
        if value >= 100 {
            return String(format: "$%.1f", value)
        }
        return String(format: "$%.2f", value)
    }
}

struct SharedAccountUsageAttributionSummaryButton: View {
    let result: SharedAccountUsageAttributionResult
    let action: () -> Void

    private var presentation: SharedAccountUsageAttributionPresentation {
        SharedAccountUsageAttributionPresentation(result: result)
    }

    private var accent: Color {
        AppTheme.accentColor(for: presentation.accentRole)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(presentation.compactSummaryLine)
                    .font(.system(size: 7.5, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Image(systemName: "chevron.right")
                    .font(.system(size: 6.5, weight: .bold))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 4)
            .frame(height: 16)
            .background(
                Capsule()
                    .fill(accent.opacity(0.10))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("查看共享账号本机与非本机用量归因")
        .accessibilityLabel("共享账号用量归因")
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint("打开计算详情")
    }
}

struct SharedAccountUsageAttributionDetailView: View {
    let result: SharedAccountUsageAttributionResult
    let safetyRecoveryState: SharedAccountUsageSafetyRecoveryState
    let recoveryAvailable: Bool
    let onRebuildSafetyBaseline: () -> Void
    let onClose: () -> Void

    private var presentation: SharedAccountUsageAttributionPresentation {
        SharedAccountUsageAttributionPresentation(result: result)
    }

    private var accent: Color {
        AppTheme.accentColor(for: presentation.accentRole)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(AppTheme.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    metricRow
                    formulaSection
                    tokenSection
                    sourceSection
                    errorSection
                }
                .padding(20)
            }
        }
        .background(AppTheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.borderStrong, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("共享账号用量归因详情")
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: presentation.iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("共享账号用量归因")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(presentation.stateTitle) · \(cycleText)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(result.tier.title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(AppTheme.accentBlue)
                .padding(.horizontal, 8)
                .frame(height: 23)
                .background(AppTheme.accentBlue.opacity(0.1), in: Capsule())
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭共享账号用量归因详情")
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    private var metricRow: some View {
        HStack(spacing: 10) {
            metricCard(
                title: result.usesSegmentBaseline ? "账号本段实降" : "账号实降",
                value: result.accountUsedPercent.map(SharedAccountUsageAttributionPresentation.percent) ?? "--",
                detail: accountSegmentDetail,
                color: AppTheme.accentBlue
            )
            metricCard(
                title: "本机折算",
                value: result.localSharePercent.map(SharedAccountUsageAttributionPresentation.percent) ?? "--",
                detail: result.localComparableCostUSD.map(SharedAccountUsageAttributionPresentation.money) ?? "等待同基准金额",
                color: AppTheme.accentGreen
            )
            metricCard(
                title: result.hasFinalAttributionConclusion ? "非本机差额" : "暂算差额",
                value: result.hasFinalAttributionConclusion
                    ? (result.nonLocalDifferencePercent.map(SharedAccountUsageAttributionPresentation.signedPercent) ?? "--")
                    : "--",
                detail: result.hasFinalAttributionConclusion ? "保留正负，不截断" : "等待数据对齐，不作归因",
                color: accent
            )
        }
    }

    private var formulaSection: some View {
        detailSection(title: "计算", systemImage: "function") {
            VStack(alignment: .leading, spacing: 7) {
                formulaRow("1", presentation.localFormula)
                formulaRow("2", presentation.differenceFormula)
            }
        }
    }

    private var tokenSection: some View {
        detailSection(title: "本归因段本机 token", systemImage: "number") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 0) {
                    compactValue("非缓存输入", result.breakdown.uncachedInputTokens.abbreviatedTokens)
                    Divider().frame(height: 28)
                    compactValue("缓存输入", result.breakdown.cachedInputTokens.abbreviatedTokens)
                    Divider().frame(height: 28)
                    compactValue("输出", result.breakdown.outputTokens.abbreviatedTokens)
                    Divider().frame(height: 28)
                    compactValue("请求", "\(result.breakdown.calls)")
                }
                if result.boundaryBreakdown.hasUsage {
                    Text("首尾边缘桶独立统计：\(result.boundaryBreakdown.totalTokens.abbreviatedTokens) Token")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sourceSection: some View {
        detailSection(title: "基准与来源", systemImage: "dot.radiowaves.left.and.right") {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    sourceValue("Radar \(result.tier.title) 7 天总额", result.radarSevenDayTotalUSD.map(SharedAccountUsageAttributionPresentation.money) ?? "--")
                    sourceValue("归因价格", result.priceRevision.title)
                    sourceValue("当前 API 等值", result.localCurrentOfficialCostUSD.map(SharedAccountUsageAttributionPresentation.money) ?? "--")
                    Link(destination: URL(string: "https://codexradar.com")!) {
                        Label("Codex 雷达", systemImage: "arrow.up.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(AppTheme.accentBlue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("在浏览器打开 Codex Radar")
                }
                HStack(spacing: 12) {
                    sourceValue("模型", presentation.modelLine)
                    sourceValue("basis", nonempty(result.radarBasis))
                    sourceValue("Radar 日期", nonempty(result.radarDate))
                }
                HStack(spacing: 12) {
                    sourceValue("定价基准日", nonempty(result.radarPricingBasisDate))
                    sourceValue("更新时间", nonempty(result.radarUpdatedAt))
                    sourceValue("来源", nonempty(result.radarSource))
                }
            }
        }
    }

    private var errorSection: some View {
        detailSection(title: "误差与解释", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 6) {
                if recoveryAvailable || safetyRecoveryState != .idle {
                    safetyRecoveryAction
                        .padding(.bottom, 4)
                }
                explanationLine("额度按整数百分比显示、Radar 总额为众测估算，约 ±2 个百分点内不判定为明显非本机使用。")
                explanationLine("本机金额会按每次 token 记录之前最近的 turn_context 自动识别 Sol、Terra 或 Luna；旧记录、自动路由和未知别名才按设置中的回退模型计算。当前索引仍无法逐事件识别 cache write、超过 272K 的长上下文和 Fast/service tier 附加项，因此不是精确账单。")
                explanationLine("正差额只表示疑似来自其他设备、其他共用者或价格/刷新误差，不等同于已确认他人使用。")
                explanationLine("负差额会原样保留，通常表示价格基准、额度取整或刷新时点仍有偏差。")
                explanationLine("账号隔离从本功能首次观察到当前 Home 起生效；首次启用不会回算无法证明完整的本周期早期历史。")
                explanationLine("若会话归档与新调用落在同一个已完成的 5 分钟桶，聚合数据无法区分旧数据恢复和真实新增，可能低估该桶新增量；后续新桶仍会正常累计。")
                if result.priceRevision.isLegacy {
                    explanationLine("本次归因按 Radar 2026-07-30 同期旧价格计算；现行官方 API 等值已单独列出，未混用。")
                }
                if result.usedHighWatermark {
                    explanationLine("本轮部分 5 分钟桶低于同一账号/周期已记录值，可能有会话归档或本地历史变化；已逐桶保留原始 token 高水位，后续新桶仍会继续累计。")
                }
                if result.localHistoryAmbiguous {
                    explanationLine("本归因段遇到旧版聚合记录、精确索引世代变化或非追加式来源改写，无法证明前后来源贡献可连续对账；当前仍保留本机金额，但停止给出正向非本机归因。")
                }
                if result.switchedAccountDuringCycle {
                    explanationLine("本机在当前 7 天周期内检测到账号切换：token 从下一完整 5 分钟桶起算，额度基线等到边界后的首个新鲜快照再固定，避免把边界前用量误判为其他人使用。")
                    explanationLine("从 5 分钟边界到额度基线快照之间的本机 token 会保留，但账号差值从基线后起算；这一小段只会让本机估值偏高，不会据此误报其他人使用。")
                }
                if result.cutoverReason == .continuityGap {
                    explanationLine("本机精确观察曾中断（例如读取失败、应用重启或监控暂停），无法证明中断期间已经消失的本机历史完整；恢复后已从下一完整 5 分钟桶重新建立额度基线，不会把这段未知消耗归给其他共用者。")
                }
                if result.cutoverReason == .storageRecovery {
                    explanationLine("异常的安全记录已完整移到隔离目录；当前从重建后的新额度与本机精确用量重新建立基线，旧记录不会被当作可用结论复活。")
                }
                if result.cutoverReason == .legacyMigration {
                    explanationLine("旧预览记录缺少安全的切换边界；升级后已从新鲜额度快照重新建立基线，不会直接沿用旧记录作正向归因。")
                }
                if result.cutoverReason == .initialActivation {
                    explanationLine("首次启用时无法证明本周期早先已归档或删除的本机历史完整，因此从启用后的下一完整 5 分钟桶重新建立额度基线，不会把早期缺口归给其他共用者。")
                }
                if result.quotaDataStale {
                    explanationLine("账号额度当前来自读取失败后保留的旧快照；结果已降级为等待刷新，但新鲜本机 token 仍先写入原始高水位，避免额度恢复前归档会话造成丢失。")
                }
                if result.radarDataStale {
                    explanationLine("Radar 当前来自刷新失败后保留的旧快照；金额分母仍可查看，但结论已降级为等待刷新。")
                }
                if result.state == .preciseUsageStale {
                    explanationLine("本机精确时间序列尚未覆盖最新额度快照；结果已降级为等待精确用量刷新，并停止新增归因高水位，避免把尚未扫描到的本机消耗误判为非本机使用。")
                }
                if result.state == .attributionStorageUnavailable {
                    explanationLine("归因分段、高水位或连续性记录无法安全读取；当前已停止给出共享差额，也不会用反复重扫本地历史来掩盖存储问题。")
                }
                if result.state == .awaitingAccountSwitchBaseline {
                    explanationLine("正在等待安全切点之后的新鲜额度快照；在基线对齐前不计算非本机差额。")
                }
                explanationLine("如果自然 7 天重置时刻不在 5 分钟整点，起点所在的混合桶会整体计入本机；其中重置前的少量 token 可能让本机估值略高，但不会因此把用量误报给其他共用者。")
            }
        }
    }

    private var cycleText: String {
        guard let start = result.localSegmentStart ?? result.cycleStart,
              let end = result.cycleEnd else { return "周期待读取" }
        return "\(start.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))) – \(end.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))"
    }

    private var accountSegmentDetail: String {
        switch result.cutoverReason {
        case .initialActivation: "从功能启用后的安全基线起"
        case .accountSwitch: "从本机检测到账号切换起"
        case .continuityGap: "从精确观察恢复后的安全基线起"
        case .storageRecovery: "从安全记录重建后的基线起"
        case .legacyMigration: "从升级后的安全基线起"
        case .none: "当前 7 天周期"
        }
    }

    @ViewBuilder
    private var safetyRecoveryAction: some View {
        HStack(spacing: 10) {
            Image(systemName: safetyRecoveryState == .rebuilding
                ? "arrow.triangle.2.circlepath"
                : "wrench.and.screwdriver")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.accentAmber)
                .frame(width: 28, height: 28)
                .background(
                    AppTheme.accentAmber.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(recoveryTitle)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(recoveryDetail)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if recoveryAvailable,
               safetyRecoveryState != .rebuilding,
               safetyRecoveryState != .awaitingFreshBaseline {
                Button("重新准备共享统计", action: onRebuildSafetyBaseline)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityHint("保留异常记录副本，并从新的额度与本机用量重新开始")
            } else if safetyRecoveryState == .rebuilding {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
        .background(
            AppTheme.accentAmber.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.accentAmber.opacity(0.22), lineWidth: 1)
        )
    }

    private var recoveryTitle: String {
        switch safetyRecoveryState {
        case .rebuilding: "正在重新准备共享统计"
        case .awaitingFreshBaseline: "共享统计已重新开始"
        case .failed: "暂时未能重新准备"
        case .required: "共享统计需要修复"
        case .idle: "共享统计暂不可用"
        }
    }

    private var recoveryDetail: String {
        switch safetyRecoveryState {
        case .rebuilding: "正在保留异常记录副本，并创建一套新的统计记录。"
        case .awaitingFreshBaseline: "正在等待新额度和本机用量对齐；完成前不会判断其他人用了多少。"
        case .failed: "原记录仍然保留，稍后可以再次尝试。"
        case .required, .idle: "会先保留异常记录副本，再从新数据开始，不会沿用可能有问题的旧结果。"
        }
    }

    private func metricCard(title: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
            Text(detail).font(.system(size: 8.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(AppTheme.insetBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private func detailSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.solidControlBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private func formulaRow(_ index: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(index)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.accentBlue)
                .frame(width: 20, height: 20)
                .background(AppTheme.accentBlue.opacity(0.1), in: Circle())
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private func compactValue(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func sourceValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 9.5, weight: .semibold)).lineLimit(1).truncationMode(.middle).help(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func explanationLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(AppTheme.accentBlue.opacity(0.55)).frame(width: 4, height: 4).padding(.top, 5)
            Text(text).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nonempty(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "--" : trimmed
    }
}
