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

        var snapshot = AccountQuotaSnapshot(
            fiveHour: primary,
            sevenDay: secondary,
            planType: planType,
            limitName: limitName,
            accountName: accountName,
            limitCards: limitCards,
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
