import Foundation

struct LiveAccountQuotaReader: QuotaReading {
    func readQuota(dataSource: CodexDataSource?) async -> Result<AccountQuotaSnapshot, Error> {
        await AccountQuotaReader.read(dataSource: dataSource)
    }
}

private enum AccountQuotaReader {
    static func read(dataSource: CodexDataSource?) async -> Result<AccountQuotaSnapshot, Error> {
        let trace = RefreshPerformanceProbe.begin("accountQuotaReader.read", metadata: [
            "source": dataSource?.displayPath ?? "default"
        ])
        var lastError: Error?
        for attempt in 1...3 {
            trace?.mark("attempt.begin", metadata: ["attempt": String(attempt)])
            let result = readOnce(dataSource: dataSource)
            switch result {
            case .success(let snapshot):
                trace?.mark("attempt.success", metadata: [
                    "attempt": String(attempt),
                    "available": snapshot.isAvailable ? "1" : "0"
                ])
                if snapshot.isAvailable || attempt == 3 {
                    let enriched = await snapshotByAddingResetCredits(to: snapshot, dataSource: dataSource)
                    trace?.end("ok", metadata: [
                        "attempt": String(attempt),
                        "available": enriched.isAvailable ? "1" : "0",
                        "resetCredits": String(enriched.availableResetCreditCount)
                    ])
                    return .success(enriched)
                }
                lastError = AccountQuotaReaderError.emptyRateLimits
            case .failure(let error):
                trace?.mark("attempt.failed", metadata: [
                    "attempt": String(attempt),
                    "error": error.localizedDescription
                ])
                if attempt == 3 {
                    trace?.end("failed", metadata: [
                        "attempt": String(attempt),
                        "error": error.localizedDescription
                    ])
                    return .failure(error)
                }
                lastError = error
            }
            trace?.mark("attempt.sleep", metadata: ["attempt": String(attempt)])
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        trace?.end("failed", metadata: ["error": (lastError ?? AccountQuotaReaderError.invalidResponse).localizedDescription])
        return .failure(lastError ?? AccountQuotaReaderError.invalidResponse)
    }

    private static func snapshotByAddingResetCredits(
        to snapshot: AccountQuotaSnapshot,
        dataSource: CodexDataSource?
    ) async -> AccountQuotaSnapshot {
        let trace = RefreshPerformanceProbe.begin("accountQuotaReader.addResetCredits")
        var enriched = snapshot
        switch await readResetCredits(dataSource: dataSource) {
        case .success(let resetCredits):
            enriched.resetCreditsAvailableCount = resetCredits.availableCount
            enriched.resetCredits = resetCredits.credits
            trace?.end("ok", metadata: [
                "available": String(resetCredits.availableCount),
                "credits": String(resetCredits.credits.count)
            ])
        case .failure(let diagnostic):
            enriched.diagnostics.append(diagnostic)
            trace?.end("unavailable", metadata: [
                "category": diagnostic.category.rawValue,
                "underlying": diagnostic.underlyingCategory?.rawValue ?? "none"
            ])
        }
        return enriched
    }

    private static func readOnce(dataSource: CodexDataSource?) -> Result<AccountQuotaSnapshot, Error> {
        let trace = RefreshPerformanceProbe.begin("accountQuotaReader.readOnce")
        do {
            trace?.mark("findCodexBinary.begin")
            let codexPath = try findCodexBinary()
            trace?.mark("findCodexBinary.end", metadata: ["path": codexPath])
            let process = Process()
            process.executableURL = URL(fileURLWithPath: codexPath)
            process.arguments = ["app-server", "--listen", "stdio://"]
            if let dataSource {
                var environment = ProcessInfo.processInfo.environment
                environment["CODEX_HOME"] = dataSource.codexHome.path
                process.environment = environment
            }

            let input = Pipe()
            let output = Pipe()
            let error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error

            let reader = JSONLineReader(handle: output.fileHandleForReading)
            trace?.mark("process.run.begin")
            try process.run()
            trace?.mark("process.run.end", metadata: ["pid": String(process.processIdentifier)])
            defer {
                output.fileHandleForReading.readabilityHandler = nil
                if process.isRunning {
                    process.terminate()
                }
            }

            let writer = input.fileHandleForWriting
            trace?.mark("initialize.write.begin")
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
            trace?.mark("initialize.write.end")

            let deadline = Date().addingTimeInterval(12)
            var didSendRead = false
            var waitCount = 0

            while Date() < deadline {
                waitCount += 1
                if let message = try reader.next(timeout: 0.5) {
                    let messageID = (message["id"] as? Int).map(String.init) ?? "none"
                    trace?.mark("message.received", metadata: [
                        "id": messageID,
                        "waitCount": String(waitCount)
                    ])
                    if let id = message["id"] as? Int, id == 1, message["result"] != nil, !didSendRead {
                        trace?.mark("initialized.write.begin")
                        try write(["jsonrpc": "2.0", "method": "initialized"], to: writer)
                        try write(["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"], to: writer)
                        trace?.mark("initialized.write.end")
                        didSendRead = true
                        continue
                    }

                    if let id = message["id"] as? Int, id == 2 {
                        if let error = message["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            trace?.end("server-error", metadata: ["error": message])
                            return .failure(AccountQuotaReaderError.serverError(message))
                        }
                        guard let result = message["result"] as? [String: Any] else {
                            trace?.end("invalid-response")
                            return .failure(AccountQuotaReaderError.invalidResponse)
                        }
                        trace?.mark("parse.begin")
                        let snapshot = parse(result, dataSource: dataSource)
                        trace?.mark("parse.end", metadata: [
                            "available": snapshot.isAvailable ? "1" : "0",
                            "cards": String(snapshot.limitCards.count)
                        ])
                        trace?.end("ok", metadata: [
                            "waitCount": String(waitCount),
                            "available": snapshot.isAvailable ? "1" : "0"
                        ])
                        return .success(snapshot)
                    }
                }
            }

            if process.isRunning {
                trace?.mark("timeout.terminate.begin")
                process.terminate()
                process.waitUntilExit()
                trace?.mark("timeout.terminate.end")
            }
            if let stderr = try? error.fileHandleForReading.readToEnd(),
               let text = String(data: stderr, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
                trace?.end("server-error", metadata: ["error": message])
                return .failure(AccountQuotaReaderError.serverError(message))
            }
            trace?.end("invalid-response-timeout")
            return .failure(AccountQuotaReaderError.timeout)
        } catch {
            trace?.end("failed", metadata: ["error": error.localizedDescription])
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
        throw AccountQuotaReaderError.codexBinaryNotFound
    }

    private static func write(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        handle.write(data)
        handle.write(Data([0x0A]))
    }

    private static func parse(_ result: [String: Any], dataSource: CodexDataSource?) -> AccountQuotaSnapshot {
        let byLimit = result["rateLimitsByLimitId"] as? [String: Any]
        let fallbackLimit = result["rateLimits"] as? [String: Any]
        let limitCards = parseLimitCards(byLimit: byLimit, fallbackLimit: fallbackLimit)
        let codex = (byLimit?["codex"] as? [String: Any]) ?? fallbackLimit ?? [:]
        let primaryCard = limitCards.first
        let primary = parseWindow(codex["primary"] as? [String: Any], label: "5h") ?? primaryCard?.fiveHour
        let secondary = parseWindow(codex["secondary"] as? [String: Any], label: "7d") ?? primaryCard?.sevenDay
        let planType = (codex["planType"] as? String) ?? primaryCard?.planType
        let limitName = (codex["limitName"] as? String) ?? primaryCard?.limitName
        let accountName = readLocalAccountName(dataSource: dataSource)

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

    private struct ResetCreditsSnapshot: Sendable {
        let availableCount: Int
        let credits: [AccountQuotaResetCredit]
    }

    private static func readResetCredits(dataSource: CodexDataSource?) async -> Result<ResetCreditsSnapshot, AccountQuotaDiagnostic> {
        let trace = RefreshPerformanceProbe.begin("accountQuotaReader.readResetCredits")
        trace?.mark("readAccessToken.begin")
        guard let accessToken = readAccessToken(dataSource: dataSource) else {
            let underlying = AccountQuotaDiagnostic(
                source: .resetCredit,
                category: .authMissing,
                severity: .warning,
                message: "未找到登录 token",
                rawCause: "auth.json missing or access_token empty",
                retryable: true,
                occurredAt: Date()
            )
            trace?.end("missing-access-token")
            return .failure(.resetCreditFailure(underlying: underlying))
        }
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits") else {
            let underlying = AccountQuotaDiagnostic(
                source: .resetCredit,
                category: .parseFailure,
                severity: .error,
                message: "重置卡请求地址异常",
                rawCause: "Invalid reset-credit URL",
                retryable: false,
                occurredAt: Date()
            )
            trace?.end("invalid-url")
            return .failure(.resetCreditFailure(underlying: underlying))
        }
        trace?.mark("readAccessToken.end")

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
            trace?.mark("http.begin")
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            trace?.mark("http.end", metadata: [
                "status": String(statusCode),
                "bytes": String(data.count)
            ])
            guard let http = response as? HTTPURLResponse else {
                trace?.end("invalid-response", metadata: ["status": String(statusCode)])
                let underlying = AccountQuotaDiagnostic(
                    source: .resetCredit,
                    category: .parseFailure,
                    severity: .error,
                    message: "重置卡响应格式异常",
                    rawCause: "Missing HTTP response",
                    retryable: false,
                    occurredAt: Date()
                )
                return .failure(.resetCreditFailure(underlying: underlying))
            }
            guard (200..<300).contains(http.statusCode) else {
                trace?.end("http-error", metadata: ["status": String(http.statusCode)])
                let category = AccountQuotaDiagnostic.category(forHTTPStatus: http.statusCode)
                let underlying = AccountQuotaDiagnostic(
                    source: .resetCredit,
                    category: category,
                    severity: .error,
                    message: "重置卡请求失败",
                    rawCause: "HTTP \(http.statusCode)",
                    httpStatus: http.statusCode,
                    retryable: category != .httpAuth,
                    occurredAt: Date()
                )
                return .failure(.resetCreditFailure(underlying: underlying))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                trace?.end("parse-failed", metadata: ["status": String(http.statusCode)])
                let underlying = AccountQuotaDiagnostic(
                    source: .resetCredit,
                    category: .parseFailure,
                    severity: .error,
                    message: "重置卡响应格式异常",
                    rawCause: String(data: data.prefix(512), encoding: .utf8) ?? "Invalid JSON",
                    httpStatus: http.statusCode,
                    retryable: false,
                    occurredAt: Date()
                )
                return .failure(.resetCreditFailure(underlying: underlying))
            }

            trace?.mark("parseResetCredits.begin")
            let credits = parseResetCredits(object["credits"])
            let availableCount = (object["available_count"] as? NSNumber)?.intValue
                ?? (object["available_count"] as? Int)
                ?? credits.filter(\.isAvailable).count
            let snapshot = ResetCreditsSnapshot(
                availableCount: max(0, availableCount),
                credits: credits
            )
            trace?.end("ok", metadata: [
                "available": String(snapshot.availableCount),
                "credits": String(snapshot.credits.count)
            ])
            return .success(snapshot)
        } catch {
            trace?.end("failed", metadata: ["error": error.localizedDescription])
            let underlying = AccountQuotaDiagnostic.classify(
                source: .resetCredit,
                error: error,
                occurredAt: Date()
            )
            return .failure(.resetCreditFailure(underlying: underlying))
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

    private static func readLocalAccountName(dataSource: CodexDataSource?) -> String? {
        let url = authFileURL(dataSource: dataSource)
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

    private static func readAccessToken(dataSource: CodexDataSource?) -> String? {
        let url = authFileURL(dataSource: dataSource)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String else {
            return nil
        }
        let trimmed = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func authFileURL(dataSource: CodexDataSource?) -> URL {
        let codexHome = dataSource?.codexHome
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
        return codexHome.appendingPathComponent("auth.json")
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
