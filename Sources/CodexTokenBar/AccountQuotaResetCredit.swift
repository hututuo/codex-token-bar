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
        guard let expiresAt else { return "到期时间未知" }
        let interval = expiresAt.timeIntervalSinceNow
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
