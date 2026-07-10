import Foundation

struct AccountQuotaWindow: Equatable, Sendable {
    let label: String
    let usedPercent: Int
    let resetsAt: Date?

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    var displayLabel: String {
        switch label {
        case "5h":
            return "5小时"
        case "7d":
            return "7天"
        default:
            return label
        }
    }

    var compactDisplayLabel: String {
        switch label {
        case "5h":
            return "5h"
        case "7d":
            return "7d"
        default:
            return label
        }
    }

    var expectedRemainingPercentByEvenPace: Int? {
        guard let resetsAt else { return nil }
        let durationMinutes: Double
        switch label {
        case "5h":
            durationMinutes = 300
        case "7d":
            durationMinutes = 10_080
        default:
            return nil
        }
        let remainingMinutes = max(0, resetsAt.timeIntervalSinceNow / 60.0)
        let elapsedFraction = min(1, max(0, (durationMinutes - remainingMinutes) / durationMinutes))
        return Int((100.0 - elapsedFraction * 100.0).rounded())
    }

    var compactResetText: String {
        guard let resetsAt else { return "--:--" }
        let calendar = Calendar.current
        if label == "5h" {
            return resetsAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        }
        if calendar.isDateInToday(resetsAt) {
            return resetsAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        }
        if calendar.isDateInTomorrow(resetsAt) {
            return "明 \(resetsAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))"
        }
        return resetsAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }

    var detailedResetText: String {
        guard let resetsAt else { return "--:--" }
        let calendar = Calendar.current
        let time = resetsAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if label == "5h" {
            return time
        }
        if calendar.isDateInToday(resetsAt) {
            return time
        }
        if calendar.isDateInTomorrow(resetsAt) {
            return "明天 \(time)"
        }
        return resetsAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    var accessibleResetText: String {
        guard let resetsAt else { return "未知" }
        return resetsAt.formatted(.dateTime.month().day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}

struct AccountQuotaLimitCard: Equatable, Sendable {
    let id: String
    let limitName: String?
    let planType: String?
    let fiveHour: AccountQuotaWindow?
    let sevenDay: AccountQuotaWindow?

    var displayName: String {
        if let limitName, !limitName.isEmpty {
            return limitName
        }
        return id
    }

    var hasQuotaWindows: Bool {
        fiveHour != nil || sevenDay != nil
    }
}

struct QuotaHistoryIdentity: Equatable, Hashable, Sendable {
    static let currentVersion = 1

    let version: Int
    let homeIdentity: String
    let stableAccountKey: String
    let planType: String
    let limitID: String

    init?(
        version: Int = currentVersion,
        homeIdentity: String?,
        stableAccountKey: String?,
        planType: String?,
        limitID: String?
    ) {
        guard version == Self.currentVersion,
              let homeIdentity = Self.nonempty(homeIdentity),
              let stableAccountKey = Self.nonempty(stableAccountKey),
              let limitID = Self.canonicalStableLimitID(limitID),
              let planType = Self.canonicalPlanType(planType)
        else {
            return nil
        }
        self.version = version
        self.homeIdentity = homeIdentity
        self.stableAccountKey = stableAccountKey
        self.planType = planType
        self.limitID = limitID
    }

    private static func canonicalPlanType(_ value: String?) -> String? {
        guard let value = nonempty(value) else { return nil }
        let normalized = value.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "plus", "chatgptplus":
            return "Plus"
        case "pro", "chatgptpro":
            return "Pro"
        case "team", "teams", "business":
            return "Team"
        case "enterprise":
            return "Enterprise"
        case "free":
            return "Free"
        case "unknown", "null", "none", "unread":
            return nil
        default:
            if value.contains("待读取") || value.contains("未知") {
                return nil
            }
            return value
        }
    }

    private static func canonicalStableLimitID(_ value: String?) -> String? {
        guard let value = nonempty(value) else { return nil }
        return value.caseInsensitiveCompare("codex") == .orderedSame ? "codex" : value
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}


enum AccountQuotaPaceSeverity: Equatable {
    case urgent
    case fast
    case slightlyFast
    case steady
    case roomy
}

struct AccountQuotaPaceStatus: Equatable {
    let severity: AccountQuotaPaceSeverity
    let iconName: String
    let title: String
    let compactTitle: String
    let detail: String
    let compactDetail: String
    let remainingPercent: Int
    let expectedRemainingPercent: Int
    let deltaPercent: Int
}

struct AccountQuotaSnapshot: Equatable, Sendable {
    var fiveHour: AccountQuotaWindow?
    var sevenDay: AccountQuotaWindow?
    var planType: String?
    var limitName: String?
    var accountName: String?
    var limitCards: [AccountQuotaLimitCard] = []
    var resetCreditsAvailableCount: Int?
    var resetCredits: [AccountQuotaResetCredit] = []
    var diagnostics: [AccountQuotaDiagnostic] = []
    var status: String = "额度未读取"
    var updatedAt: Date?
    var selectedLimitID: String?
    var historyIdentity: QuotaHistoryIdentity?

    static let empty = AccountQuotaSnapshot()

    var isAvailable: Bool {
        fiveHour != nil || sevenDay != nil
    }

    var staleDataDisplayed: Bool {
        diagnostics.contains { diagnostic in
            diagnostic.staleDataDisplayed || diagnostic.category == .staleCachedData
        }
    }

    var displayName: String {
        if let limitName, !limitName.isEmpty {
            return limitName
        }
        if let planType, !planType.isEmpty {
            return planType.uppercased()
        }
        return "账户额度"
    }

    var accountDisplayName: String {
        guard let accountName, !accountName.isEmpty else {
            return "Codex Token Bar"
        }
        return accountName
    }

    var compactLimitCardSuffix: String {
        guard limitCards.count > 1 else { return "" }
        return " · \(limitCards.count)卡"
    }

    var availableResetCreditCount: Int {
        max(resetCreditsAvailableCount ?? 0, resetCredits.filter(\.isAvailable).count)
    }

    var availableResetCredits: [AccountQuotaResetCredit] {
        resetCredits.filter(\.isAvailable)
    }

    var sortedResetCreditsForDisplay: [AccountQuotaResetCredit] {
        resetCredits.sorted(by: AccountQuotaResetCredit.displaySortPrecedes)
    }

    var nearestExpiringResetCredit: AccountQuotaResetCredit? {
        availableResetCredits
            .sorted(by: AccountQuotaResetCredit.displaySortPrecedes)
            .first
    }

    var nearestFutureExpiringResetCredit: AccountQuotaResetCredit? {
        let now = Date()
        return availableResetCredits
            .filter { credit in
                guard let expiresAt = credit.expiresAt else { return false }
                return expiresAt > now
            }
            .sorted(by: AccountQuotaResetCredit.displaySortPrecedes)
            .first
    }

    var compactResetCreditSummary: String? {
        guard resetCreditsAvailableCount != nil || !resetCredits.isEmpty else {
            return "获取失败"
        }
        let count = availableResetCreditCount
        guard count > 0 else { return "0 张重置卡" }
        return "\(count) 张重置卡"
    }

    var compactResetCreditCountSuffix: String {
        let count = availableResetCreditCount
        guard count > 0 else { return "" }
        return " · \(count)卡"
    }

    var compactResetCreditRateBarSuffix: String {
        let count = availableResetCreditCount
        guard count > 0 else { return "" }
        guard let countdown = nearestFutureExpiringResetCredit?.compactExpiryCountdownText else {
            return " · \(count)卡"
        }
        return " · \(count)卡 · \(countdown)"
    }

    var compactResetCreditStandaloneSuffix: String {
        let count = availableResetCreditCount
        guard count > 0 else { return "" }
        guard let countdown = nearestFutureExpiringResetCredit?.compactExpiryCountdownText else {
            return " · \(count)卡"
        }
        return " · \(count)卡 · 近\(countdown)到期"
    }

    var resetCreditDetailSummary: String {
        let countText = compactResetCreditSummary ?? "暂无可用重置卡"
        if let nearestFutureExpiringResetCredit {
            return "\(countText) · 最近 \(nearestFutureExpiringResetCredit.compactExpiryText)"
        }
        return countText
    }

    var resetCreditNearestLineText: String? {
        guard let nearestFutureExpiringResetCredit else { return nil }
        return "最近 \(nearestFutureExpiringResetCredit.compactRemainingTimeText)"
    }

    var resetCreditReadSummary: String {
        let total = resetCredits.count
        let available = availableResetCreditCount
        if total == 0 {
            if available > 0 {
                return "\(available) 张可用；未拿到单卡明细"
            }
            return "0 张"
        }
        var parts = ["共 \(total) 张", "可用 \(available) 张"]
        let used = resetCredits.filter { $0.redeemedAt != nil || $0.status == "redeemed" }.count
        let expired = resetCredits.filter { $0.status == "expired" }.count
        if used > 0 { parts.append("\(used) 张已使用") }
        if expired > 0 { parts.append("\(expired) 张已过期") }
        return parts.joined(separator: "；")
    }

    var resetCreditDetailSubtitle: String {
        guard !resetCredits.isEmpty else {
            return resetCreditReadSummary
        }
        let sortText = nearestFutureExpiringResetCredit == nil ? "按状态排序" : "按最近到期排序"
        return "\(resetCreditReadSummary) · \(sortText)"
    }

    var sevenDayPaceStatus: AccountQuotaPaceStatus? {
        guard let sevenDay,
              sevenDay.resetsAt != nil,
              let expectedRemaining = sevenDay.expectedRemainingPercentByEvenPace else {
            return nil
        }

        let remaining = sevenDay.remainingPercent
        let delta = remaining - expectedRemaining
        let remainingHours = max(0, sevenDay.resetsAt?.timeIntervalSinceNow ?? 0) / 3600.0
        let roundedHours = Int(ceil(remainingHours))
        let isLastDay = remainingHours <= 24
        let isFinalHours = remainingHours <= 8
        let hour = Calendar.current.component(.hour, from: Date())
        let isEvening = hour >= 18 || hour < 2
        let deltaText: String
        if delta < 0 {
            deltaText = "余量低 \(abs(delta))%"
        } else if delta > 0 {
            deltaText = "余量高 \(delta)%"
        } else {
            deltaText = "正好贴线"
        }
        let resetText = remainingHours <= 36 ? " · 还剩 \(roundedHours)h" : ""
        let detail = "7d 剩 \(remaining)% · 均速应剩 \(expectedRemaining)% · \(deltaText)\(resetText)"

        if remaining <= 3 {
            return AccountQuotaPaceStatus(
                severity: .urgent,
                iconName: "exclamationmark.triangle",
                title: "不够烧了，先省着",
                compactTitle: "先省着",
                detail: detail,
                compactDetail: "\(remaining)%剩",
                remainingPercent: remaining,
                expectedRemainingPercent: expectedRemaining,
                deltaPercent: delta
            )
        }

        if isFinalHours && (delta < 0 || remaining < 12) {
            return AccountQuotaPaceStatus(
                severity: .urgent,
                iconName: "moon.stars",
                title: "最后几小时，别梭哈",
                compactTitle: "别梭哈",
                detail: detail,
                compactDetail: "\(roundedHours)h",
                remainingPercent: remaining,
                expectedRemainingPercent: expectedRemaining,
                deltaPercent: delta
            )
        }

        if isLastDay && isEvening && (delta < 0 || remaining < 18) {
            return AccountQuotaPaceStatus(
                severity: .urgent,
                iconName: "moon.stars",
                title: "最后一晚，省着点",
                compactTitle: "省着点",
                detail: detail,
                compactDetail: deltaText,
                remainingPercent: remaining,
                expectedRemainingPercent: expectedRemaining,
                deltaPercent: delta
            )
        }

        if isLastDay && delta >= 0 {
            return AccountQuotaPaceStatus(
                severity: .steady,
                iconName: "flag.checkered",
                title: "最后一天，稳稳收官",
                compactTitle: "收官稳",
                detail: detail,
                compactDetail: deltaText,
                remainingPercent: remaining,
                expectedRemainingPercent: expectedRemaining,
                deltaPercent: delta
            )
        }

        switch delta {
        case ...(-35):
            return AccountQuotaPaceStatus(
                severity: .urgent,
                iconName: "exclamationmark.triangle",
                title: "额度掉太快，先刹一脚",
                compactTitle: "刹一脚",
                detail: detail,
                compactDetail: deltaText,
                remainingPercent: remaining,
                expectedRemainingPercent: expectedRemaining,
                deltaPercent: delta
            )
        case ...(-20):
            return AccountQuotaPaceStatus(
                severity: .urgent,
                iconName: "exclamationmark.triangle",
                title: "余量低不少，先省着",
                compactTitle: "先省着",
                detail: detail,
                compactDetail: deltaText,
                remainingPercent: remaining,
                expectedRemainingPercent: expectedRemaining,
                deltaPercent: delta
            )
        case ...(-8):
            return AccountQuotaPaceStatus(
                severity: .fast,
                iconName: "speedometer",
                title: "7天用快了，慢一点",
                compactTitle: "慢一点",
                detail: detail,
                compactDetail: deltaText,
                remainingPercent: remaining,
                expectedRemainingPercent: expectedRemaining,
                deltaPercent: delta
            )
        case ..<0:
            return AccountQuotaPaceStatus(
                severity: .slightlyFast,
                iconName: "speedometer",
                title: "略快于均速",
                compactTitle: "略快",
                detail: detail,
                compactDetail: deltaText,
                remainingPercent: remaining,
                expectedRemainingPercent: expectedRemaining,
                deltaPercent: delta
            )
        case 20...:
            return AccountQuotaPaceStatus(
                severity: .roomy,
                iconName: "checkmark.seal",
                title: "余量很富，可以喘口气",
                compactTitle: "余量足",
                detail: detail,
                compactDetail: deltaText,
                remainingPercent: remaining,
                expectedRemainingPercent: expectedRemaining,
                deltaPercent: delta
            )
        default:
            return AccountQuotaPaceStatus(
                severity: .steady,
                iconName: "checkmark.seal",
                title: "节奏稳，照这样来",
                compactTitle: "节奏稳",
                detail: detail,
                compactDetail: deltaText,
                remainingPercent: remaining,
                expectedRemainingPercent: expectedRemaining,
                deltaPercent: delta
            )
        }
    }
}
