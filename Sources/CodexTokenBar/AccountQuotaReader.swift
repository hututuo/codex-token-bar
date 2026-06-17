import Foundation

struct LiveAccountQuotaReader: QuotaReading {
    func readQuota() async -> Result<AccountQuotaSnapshot, Error> {
        await AccountQuotaReader.read()
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
                    return .success(await snapshotByAddingResetCredits(to: snapshot))
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

    private static func snapshotByAddingResetCredits(to snapshot: AccountQuotaSnapshot) async -> AccountQuotaSnapshot {
        guard let resetCredits = await readResetCredits() else { return snapshot }
        var enriched = snapshot
        enriched.resetCreditsAvailableCount = resetCredits.availableCount
        enriched.resetCredits = resetCredits.credits
        return enriched
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
        let selectedLimitID = selectedRecentLimitID(matching: limitCards) ?? fallbackLimitID(from: fallbackLimit)
        let selectedCard = selectedLimitID.flatMap { id in
            limitCards.first { $0.id == id }
        } ?? limitCards.first
        let selectedRaw = selectedCard.flatMap { byLimit?[$0.id] as? [String: Any] }
            ?? selectedLimitID.flatMap { byLimit?[$0] as? [String: Any] }
            ?? fallbackLimit
            ?? [:]
        let primary = selectedCard?.fiveHour ?? parseWindow(selectedRaw["primary"] as? [String: Any], label: "5h")
        let secondary = selectedCard?.sevenDay ?? parseWindow(selectedRaw["secondary"] as? [String: Any], label: "7d")
        let planType = selectedCard?.planType ?? (selectedRaw["planType"] as? String)
        let limitName = selectedCard?.limitName ?? (selectedRaw["limitName"] as? String)
        let accountName = readLocalAccountName()

        var snapshot = AccountQuotaSnapshot(
            fiveHour: primary,
            sevenDay: secondary,
            planType: planType,
            limitName: limitName,
            activeLimitID: selectedCard?.id ?? selectedLimitID,
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

    private static func selectedRecentLimitID(matching cards: [AccountQuotaLimitCard]) -> String? {
        guard !cards.isEmpty,
              let codexHome = CodexDataSourceResolver().resolve()?.codexHome,
              let recentLimitID = RecentRateLimitDetector.latestLimitID(codexHome: codexHome),
              cards.contains(where: { $0.id == recentLimitID }) else {
            return nil
        }
        return recentLimitID
    }

    private static func fallbackLimitID(from fallbackLimit: [String: Any]?) -> String? {
        let value = (fallbackLimit?["limitId"] as? String) ?? (fallbackLimit?["limit_id"] as? String)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
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

    private static func readResetCredits() async -> ResetCreditsSnapshot? {
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

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            let credits = parseResetCredits(object["credits"])
            let availableCount = (object["available_count"] as? NSNumber)?.intValue
                ?? (object["available_count"] as? Int)
                ?? credits.filter(\.isAvailable).count
            return ResetCreditsSnapshot(
                availableCount: max(0, availableCount),
                credits: credits
            )
        } catch {
            return nil
        }
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
