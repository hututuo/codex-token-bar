import Foundation

struct AccountQuotaResetCredit: Equatable, Identifiable, Sendable {
    let id: String
    let status: String
    let resetType: String?
    let grantedAt: Date?
    let expiresAt: Date?
    let redeemStartedAt: Date?
    let redeemedAt: Date?
    let title: String?
    let descriptionText: String?
    let profileUserID: String?
    let profileImageURL: String?

    var isAvailable: Bool {
        status == "available" && redeemedAt == nil
    }

    var statusText: String {
        if redeemedAt != nil {
            return "已使用"
        }
        switch status {
        case "available":
            return "可用"
        case "redeemed":
            return "已使用"
        case "expired":
            return "已过期"
        default:
            return status.isEmpty ? "未知" : status
        }
    }

    var detailedStatusText: String {
        statusText
    }

    var resetTypeText: String {
        guard let resetType, !resetType.isEmpty else { return "类型未知" }
        switch resetType {
        case "codex_rate_limits":
            return "Codex 额度重置"
        default:
            return resetType
        }
    }

    var detailedResetTypeText: String {
        resetTypeText
    }

    var compactExpiryText: String {
        guard let expiresAt else { return "到期未知" }
        return "\(Self.shortDate(expiresAt))到期"
    }

    var detailedExpiryText: String {
        guard let expiresAt else { return "到期未知" }
        return Self.dateTime(expiresAt)
    }

    var detailedGrantedText: String {
        guard let grantedAt else { return "发放未知" }
        return Self.dateTime(grantedAt)
    }

    var detailedRedeemedText: String? {
        guard let redeemedAt else { return nil }
        return Self.dateTime(redeemedAt)
    }

    var detailedRedeemStartedText: String {
        guard let redeemStartedAt else { return "未开始" }
        return Self.dateTime(redeemStartedAt)
    }

    var titleText: String {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "未提供标题"
        }
        switch title {
        case "One free rate limit reset":
            return "一次免费额度重置"
        default:
            return title
        }
    }

    var descriptionSummaryText: String {
        guard let descriptionText,
              !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "未提供说明"
        }
        let prefix = "You've been awarded one free rate limit reset for inviting "
        if descriptionText.hasPrefix(prefix) {
            let invitee = descriptionText.dropFirst(prefix.count)
            return "邀请 \(invitee) 获得的一次免费额度重置"
        }
        return descriptionText
    }

    var profileImageSummaryText: String {
        guard let profileImageURL,
              !profileImageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "未提供头像"
        }
        return "已显示头像"
    }

    var profileImageDisplayURL: URL? {
        guard let profileImageURL,
              let url = URL(string: profileImageURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return url
    }

    var cardIdentifierText: String {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return "未提供编号" }
        return trimmedID
    }

    var profileUserText: String {
        guard let profileUserID,
              !profileUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "未提供关联用户"
        }
        return profileUserID
    }

    var redeemStateText: String {
        if let detailedRedeemedText {
            return "已使用，完成时间 \(detailedRedeemedText)"
        }
        if redeemStartedAt != nil {
            return "已开始兑换，尚未完成"
        } else {
            return "未开始兑换"
        }
    }

    var remainingTimeText: String {
        remainingTimeText(relativeTo: Date())
    }

    var compactRemainingTimeText: String {
        compactRemainingTimeText(relativeTo: Date())
    }

    var compactExpiryCountdownText: String {
        compactExpiryCountdownText(relativeTo: Date())
    }

    func remainingTimeText(relativeTo now: Date) -> String {
        guard let expiresAt else { return "到期时间未知" }
        let interval = expiresAt.timeIntervalSince(now)
        if interval <= 0 {
            return "已经到期"
        }
        let totalMinutes = Int(interval / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        if days > 0 {
            return "约 \(days) 天 \(hours) 小时后到期"
        }
        if hours > 0 {
            return "约 \(hours) 小时后到期"
        }
        return "不到 1 小时后到期"
    }

    func compactRemainingTimeText(relativeTo now: Date) -> String {
        guard let expiresAt else { return "剩余未知" }
        let interval = expiresAt.timeIntervalSince(now)
        if interval <= 0 {
            return "已到期"
        }
        let totalMinutes = max(0, Int(interval / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "剩 \(days)天\(hours)h" : "剩 \(days)天"
        }
        if hours > 0 {
            return minutes > 0 ? "剩 \(hours)h\(minutes)m" : "剩 \(hours)h"
        }
        return "剩 <1h"
    }

    func compactExpiryCountdownText(relativeTo now: Date) -> String {
        guard let expiresAt else { return "未知" }
        let interval = expiresAt.timeIntervalSince(now)
        if interval <= 0 {
            return "已到期"
        }
        if interval >= 24 * 60 * 60 {
            let exactDays = interval / (24 * 60 * 60)
            let text = String(
                format: "%.1f",
                locale: Locale(identifier: "en_US_POSIX"),
                exactDays
            )
            return "\(text)天"
        }
        if interval < 60 * 60 {
            let minutes = max(1, Int(ceil(interval / 60)))
            return "\(minutes)m"
        }
        let hours = max(1, Int(ceil(interval / (60 * 60))))
        return "\(hours)h"
    }

    func remainingProgress(relativeTo now: Date) -> Double? {
        guard let grantedAt, let expiresAt else { return nil }
        let total = expiresAt.timeIntervalSince(grantedAt)
        guard total > 0 else { return nil }
        return min(1, max(0, expiresAt.timeIntervalSince(now) / total))
    }

    static func displaySortPrecedes(_ lhs: AccountQuotaResetCredit, _ rhs: AccountQuotaResetCredit) -> Bool {
        if lhs.isAvailable != rhs.isAvailable {
            return lhs.isAvailable && !rhs.isAvailable
        }
        switch (lhs.expiresAt, rhs.expiresAt) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }

    private static func shortDate(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.month, .day], from: date)
        guard let month = components.month, let day = components.day else { return "--/--" }
        return "\(month)/\(day)"
    }

    private static func dateTime(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let hour = components.hour,
              let minute = components.minute else {
            return "--"
        }
        return String(format: "%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute)
    }
}
