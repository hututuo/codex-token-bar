import Foundation

struct AccountQuotaWindow: Equatable {
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

struct AccountQuotaLimitCard: Equatable {
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

struct AccountQuotaSnapshot: Equatable {
    var fiveHour: AccountQuotaWindow?
    var sevenDay: AccountQuotaWindow?
    var planType: String?
    var limitName: String?
    var accountName: String?
    var limitCards: [AccountQuotaLimitCard] = []
    var resetCreditsAvailableCount: Int?
    var resetCredits: [AccountQuotaResetCredit] = []
    var status: String = "额度未读取"
    var updatedAt: Date?

    static let empty = AccountQuotaSnapshot()

    var isAvailable: Bool {
        fiveHour != nil || sevenDay != nil
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

    var nearestExpiringResetCredit: AccountQuotaResetCredit? {
        availableResetCredits
            .sorted {
                switch ($0.expiresAt, $1.expiresAt) {
                case let (lhs?, rhs?):
                    return lhs < rhs
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return $0.id.localizedStandardCompare($1.id) == .orderedAscending
                }
            }
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

    var resetCreditDetailSummary: String {
        let countText = compactResetCreditSummary ?? "暂无可用重置卡"
        if let nearestExpiringResetCredit {
            return "\(countText) · 最近 \(nearestExpiringResetCredit.compactExpiryText)"
        }
        return countText
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

@MainActor
final class AccountQuotaStore: ObservableObject {
    @Published private(set) var snapshot = AccountQuotaSnapshot.empty

    private var timer: Timer?
    private weak var historyStore: QuotaHistoryStore?
    private var isRefreshing = false
    private let refreshInterval: TimeInterval = 60

    func setHistoryStore(_ historyStore: QuotaHistoryStore) {
        self.historyStore = historyStore
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        var refreshing = snapshot
        refreshing.status = snapshot.isAvailable ? "正在更新额度" : "正在读取额度"
        snapshot = refreshing

        Task.detached(priority: .utility) {
            let result = await AccountQuotaReader.read()
            await MainActor.run {
                self.isRefreshing = false
                switch result {
                case .success(let quota):
                    self.snapshot = quota
                    self.historyStore?.record(quota)
                case .failure(let error):
                    var failed = self.snapshot
                    failed.status = "额度读取失败：\(error.localizedDescription)"
                    self.snapshot = failed
                }
            }
        }
    }
}

private enum AccountQuotaReader {
    enum ReaderError: LocalizedError {
        case codexBinaryNotFound
        case invalidResponse
        case emptyRateLimits
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .codexBinaryNotFound:
                return "未找到 Codex"
            case .invalidResponse:
                return "响应格式异常"
            case .emptyRateLimits:
                return "额度暂无数据"
            case .serverError(let message):
                return message
            }
        }
    }

    static func read() async -> Result<AccountQuotaSnapshot, Error> {
        var lastError: Error?
        for attempt in 1...3 {
            let result = readOnce()
            switch result {
            case .success(let snapshot):
                if snapshot.isAvailable || attempt == 3 {
                    return .success(snapshot)
                }
                lastError = ReaderError.emptyRateLimits
            case .failure(let error):
                if attempt == 3 {
                    return .failure(error)
                }
                lastError = error
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        return .failure(lastError ?? ReaderError.invalidResponse)
    }

    private static func readOnce() -> Result<AccountQuotaSnapshot, Error> {
        do {
            let codexPath = try findCodexBinary()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: codexPath)
            process.arguments = ["app-server", "--listen", "stdio://"]

            let input = Pipe()
            let output = Pipe()
            let error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error

            let reader = JSONLineReader(handle: output.fileHandleForReading)
            try process.run()
            defer {
                output.fileHandleForReading.readabilityHandler = nil
                if process.isRunning {
                    process.terminate()
                }
            }

            let writer = input.fileHandleForWriting
            try write([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-token-bar",
                        "title": "Codex Token Bar",
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                    ],
                    "capabilities": [
                        "experimentalApi": false,
                        "requestAttestation": false
                    ]
                ]
            ], to: writer)

            let deadline = Date().addingTimeInterval(12)
            var didSendRead = false

            while Date() < deadline {
                if let message = try reader.next(timeout: 0.5) {
                    if let id = message["id"] as? Int, id == 1, message["result"] != nil, !didSendRead {
                        try write(["jsonrpc": "2.0", "method": "initialized"], to: writer)
                        try write(["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"], to: writer)
                        didSendRead = true
                        continue
                    }

                    if let id = message["id"] as? Int, id == 2 {
                        if let error = message["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            return .failure(ReaderError.serverError(message))
                        }
                        guard let result = message["result"] as? [String: Any] else {
                            return .failure(ReaderError.invalidResponse)
                        }
                        return .success(parse(result))
                    }
                }
            }

            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            if let stderr = try? error.fileHandleForReading.readToEnd(),
               let text = String(data: stderr, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failure(ReaderError.serverError(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return .failure(ReaderError.invalidResponse)
        } catch {
            return .failure(error)
        }
    }

    private static func findCodexBinary() throws -> String {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(NSHomeDirectory())/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        throw ReaderError.codexBinaryNotFound
    }

    private static func write(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        handle.write(data)
        handle.write(Data([0x0A]))
    }

    private static func parse(_ result: [String: Any]) -> AccountQuotaSnapshot {
        let byLimit = result["rateLimitsByLimitId"] as? [String: Any]
        let fallbackLimit = result["rateLimits"] as? [String: Any]
        let limitCards = parseLimitCards(byLimit: byLimit, fallbackLimit: fallbackLimit)
        let codex = (byLimit?["codex"] as? [String: Any]) ?? fallbackLimit ?? [:]
        let primaryCard = limitCards.first
        let primary = parseWindow(codex["primary"] as? [String: Any], label: "5h") ?? primaryCard?.fiveHour
        let secondary = parseWindow(codex["secondary"] as? [String: Any], label: "7d") ?? primaryCard?.sevenDay
        let planType = (codex["planType"] as? String) ?? primaryCard?.planType
        let limitName = (codex["limitName"] as? String) ?? primaryCard?.limitName
        let accountName = readLocalAccountName()
        let resetCredits = readResetCredits()

        var snapshot = AccountQuotaSnapshot(
            fiveHour: primary,
            sevenDay: secondary,
            planType: planType,
            limitName: limitName,
            accountName: accountName,
            limitCards: limitCards,
            resetCreditsAvailableCount: resetCredits?.availableCount,
            resetCredits: resetCredits?.credits ?? [],
            status: "额度已更新",
            updatedAt: Date()
        )
        if primary == nil && secondary == nil {
            snapshot.status = "额度暂无数据"
        }
        return snapshot
    }

    private static func parseLimitCards(byLimit: [String: Any]?, fallbackLimit: [String: Any]?) -> [AccountQuotaLimitCard] {
        var cards: [AccountQuotaLimitCard] = []
        if let byLimit {
            for (id, value) in byLimit {
                guard let raw = value as? [String: Any],
                      let card = parseLimitCard(raw, fallbackID: id)
                else {
                    continue
                }
                cards.append(card)
            }
        } else if let fallbackLimit,
                  let card = parseLimitCard(fallbackLimit, fallbackID: "codex") {
            cards.append(card)
        }

        return cards
            .filter(\.hasQuotaWindows)
            .sorted { lhs, rhs in
                if lhs.id == "codex" { return true }
                if rhs.id == "codex" { return false }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    private static func parseLimitCard(_ raw: [String: Any], fallbackID: String) -> AccountQuotaLimitCard? {
        let id = (raw["limitId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let limitID = id?.isEmpty == false ? id! : fallbackID
        let fiveHour = parseWindow(raw["primary"] as? [String: Any], label: "5h")
        let sevenDay = parseWindow(raw["secondary"] as? [String: Any], label: "7d")
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return AccountQuotaLimitCard(
            id: limitID,
            limitName: raw["limitName"] as? String,
            planType: raw["planType"] as? String,
            fiveHour: fiveHour,
            sevenDay: sevenDay
        )
    }

    private struct ResetCreditsSnapshot: Sendable {
        let availableCount: Int
        let credits: [AccountQuotaResetCredit]
    }

    private final class ResetCreditsResponseBox: @unchecked Sendable {
        var output: ResetCreditsSnapshot?
    }

    private static func readResetCredits() -> ResetCreditsSnapshot? {
        guard let accessToken = readAccessToken(),
              let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 14
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexTokenBar", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResetCreditsResponseBox()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer {
            session.finishTasksAndInvalidate()
        }

        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            let credits = parseResetCredits(object["credits"])
            let availableCount = (object["available_count"] as? NSNumber)?.intValue
                ?? (object["available_count"] as? Int)
                ?? credits.filter(\.isAvailable).count
            box.output = ResetCreditsSnapshot(
                availableCount: max(0, availableCount),
                credits: credits
            )
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 14.5) == .timedOut {
            task.cancel()
        }
        return box.output
    }

    private static func parseResetCredits(_ value: Any?) -> [AccountQuotaResetCredit] {
        let rawCredits = (value as? [[String: Any]])
            ?? (value as? [Any])?.compactMap { $0 as? [String: Any] }
            ?? []

        return rawCredits
            .compactMap(parseResetCredit)
            .sorted { lhs, rhs in
                if lhs.isAvailable != rhs.isAvailable {
                    return lhs.isAvailable && !rhs.isAvailable
                }
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (lhsDate?, rhsDate?):
                    return lhsDate < rhsDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
                }
            }
    }

    private static func parseResetCredit(_ raw: [String: Any]) -> AccountQuotaResetCredit? {
        let id = (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id, !id.isEmpty else { return nil }
        return AccountQuotaResetCredit(
            id: id,
            status: (raw["status"] as? String) ?? "",
            resetType: raw["reset_type"] as? String,
            grantedAt: parseISODate(raw["granted_at"] as? String),
            expiresAt: parseISODate(raw["expires_at"] as? String),
            redeemStartedAt: parseISODate(raw["redeem_started_at"] as? String),
            redeemedAt: parseISODate(raw["redeemed_at"] as? String),
            title: raw["title"] as? String,
            descriptionText: raw["description"] as? String,
            profileUserID: raw["profile_user_id"] as? String,
            profileImageURL: raw["profile_image_url"] as? String
        )
    }

    private static func parseISODate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        return plainFormatter.date(from: value)
    }

    private static func readLocalAccountName() -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let payload = decodeJWTPayload(idToken) else {
            return nil
        }

        for key in ["name", "nickname", "preferred_username", "email"] {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func readAccessToken() -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String else {
            return nil
        }
        let trimmed = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload
    }

    private static func parseWindow(_ raw: [String: Any]?, label: String) -> AccountQuotaWindow? {
        guard let raw, let usedPercent = raw["usedPercent"] as? NSNumber else { return nil }
        let resetsAtSeconds = raw["resetsAt"] as? NSNumber
        return AccountQuotaWindow(
            label: label,
            usedPercent: usedPercent.intValue,
            resetsAt: resetsAtSeconds.map { Date(timeIntervalSince1970: $0.doubleValue) }
        )
    }
}

private final class JSONLineReader: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    private var lines: [Data] = []

    init(handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData)
        }
    }

    func next(timeout: TimeInterval) throws -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while lines.isEmpty {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            condition.wait(until: Date().addingTimeInterval(remaining))
        }

        let line = lines.removeFirst()
        guard !line.isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    private func append(_ data: Data) {
        guard !data.isEmpty else { return }
        condition.lock()
        defer {
            condition.signal()
            condition.unlock()
        }

        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            lines.append(Data(line))
            buffer.removeSubrange(...newline)
        }
    }
}
