import Foundation
import CryptoKit

/// Identity belongs to the ChatGPT account, not to the rotating access token.
struct QuotaAccountCredential: Codable, Sendable {
    var accountID: String
    var userID: String
    var label: String
    var accessToken: String

    var id: String {
        SHA256.hash(data: Data(("quota-account-v1\0" + userID + "\0" + accountID).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    var expiresAt: Double { (Self.jwt(accessToken)["exp"] as? NSNumber)?.doubleValue ?? 0 }

    static func freshest(_ values: [Self], accountID: String) -> Self? {
        values.filter { $0.id == accountID }.enumerated().max { a, b in
            a.element.expiresAt == b.element.expiresAt ? a.offset > b.offset : a.element.expiresAt < b.element.expiresAt
        }?.element
    }

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DirectQuotaError.credentials
        }
        let tokens = root["tokens"] as? [String: Any] ?? root
        func text(_ object: [String: Any], _ key: String) -> String? {
            guard let value = object[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let access = text(tokens, "access_token"), access.count < 65_536,
              access.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              !access.hasPrefix("sk-") else { throw DirectQuotaError.credentials }
        let accessClaims = jwt(access)
        let idClaims = jwt(text(tokens, "id_token") ?? "")
        let accessAuth = accessClaims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let idAuth = idClaims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        if let accessAccount = text(accessAuth, "chatgpt_account_id"),
           let idAccount = text(idAuth, "chatgpt_account_id"), accessAccount != idAccount {
            throw DirectQuotaError.identityChanged
        }
        let explicitAccount = text(tokens, "account_id") ?? text(root, "account_id")
        let claimAccount = text(accessAuth, "chatgpt_account_id") ?? text(idAuth, "chatgpt_account_id")
        if let explicitAccount, let claimAccount, explicitAccount != claimAccount {
            throw DirectQuotaError.identityChanged
        }
        guard let account = explicitAccount ?? claimAccount,
              account.count < 256, account.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw DirectQuotaError.credentials
        }
        let user = text(accessAuth, "chatgpt_user_id") ?? text(idAuth, "chatgpt_user_id")
            ?? text(idClaims, "sub") ?? text(accessClaims, "sub") ?? ""
        guard !user.isEmpty else { throw DirectQuotaError.credentials }
        let profile = accessClaims["https://api.openai.com/profile"] as? [String: Any] ?? [:]
        let label = text(idClaims, "email") ?? text(profile, "email") ?? text(root, "email")
            ?? text(idClaims, "name") ?? "ChatGPT 账号"
        return Self(accountID: account, userID: user, label: label, accessToken: access)
    }

    private static func jwt(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return [:] }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

enum DirectQuotaError: LocalizedError {
    case credentials, identityChanged, http(Int), response, vault, removalRecovery
    var errorDescription: String? {
        switch self {
        case .credentials: "未找到有效的 ChatGPT 登录凭据；请添加或更新额度账号。普通 API Key 不支持订阅额度查询。"
        case .identityChanged: "额度账号已变化，本次结果已丢弃，请刷新。"
        case .http(let status): status == 401 || status == 403
            ? "HTTP \(status)：额度登录已过期或无权限，请在原客户端重新登录后更新账号凭据。"
            : "额度接口返回 HTTP \(status)"
        case .response: "额度接口响应格式异常"
        case .vault: "无法访问系统安全凭据存储"
        case .removalRecovery: "额度账号移除未完成，且凭据恢复失败；请重新导入账号后重试。"
        }
    }
}

private final class QuotaNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum DirectQuotaHTTPReader {
    static func read(dataSource: CodexDataSource?, currentOnly: Bool = false) async -> Result<AccountQuotaSnapshot, Error> {
        do {
            func selectionKey() -> String {
                currentOnly ? ((try? QuotaAccountRegistry.currentCredential(home: dataSource?.codexHome).id) ?? "unavailable")
                    : QuotaAccountRegistry.selectionKey(home: dataSource?.codexHome)
            }
            let key = selectionKey()
            let credential = try currentOnly ? QuotaAccountRegistry.currentCredential(home: dataSource?.codexHome)
                : QuotaAccountRegistry.credential(home: dataSource?.codexHome)
            let data = try await fetch(credential: credential)
            guard key == selectionKey() else {
                throw DirectQuotaError.identityChanged
            }
            guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DirectQuotaError.response
            }
            var snapshot = AccountQuotaReader.parse(normalize(raw), accountName: credential.label)
            let home = (dataSource?.codexHome ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex"))
                .standardizedFileURL.resolvingSymlinksInPath()
            snapshot.historyIdentity = QuotaHistoryIdentity(homeIdentity: home.path,
                stableAccountKey: "quota-account:" + credential.id,
                planType: snapshot.planType, limitID: snapshot.selectedLimitID)
            return .success(snapshot)
        } catch { return .failure(error) }
    }

    static func request(credential: QuotaAccountCredential, resetCredits: Bool = false) -> URLRequest {
        let endpoint = resetCredits ? "rate-limit-reset-credits" : "usage"
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/" + endpoint)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 14
        request.setValue("Bearer " + credential.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "Chatgpt-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexTokenBar", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func fetch(credential: QuotaAccountCredential, resetCredits: Bool = false) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: QuotaNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request(credential: credential, resetCredits: resetCredits))
        guard let response = response as? HTTPURLResponse else { throw DirectQuotaError.response }
        guard (200..<300).contains(response.statusCode) else { throw DirectQuotaError.http(response.statusCode) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw DirectQuotaError.response }
            data.append(byte)
        }
        return data
    }

    /// Adapt WHAM's wire schema to the existing parser, preserving all optional fields.
    static func normalize(_ raw: [String: Any], now: Date = Date()) -> [String: Any] {
        func window(_ value: Any?) -> [String: Any]? {
            guard let value = value as? [String: Any] else { return nil }
            var result: [String: Any] = [:]
            result["usedPercent"] = value["used_percent"]
            if let seconds = value["limit_window_seconds"] as? NSNumber {
                result["windowDurationMins"] = seconds.doubleValue / 60
            } else {
                // WHAM percentages always use the 0...100 scale, including 0 and 1.
                result["windowDurationMins"] = 0
            }
            result["resetsAt"] = value["reset_at"]
            if result["resetsAt"] == nil, let seconds = value["reset_after_seconds"] as? NSNumber {
                result["resetsAt"] = now.timeIntervalSince1970 + seconds.doubleValue
            }
            return result
        }
        func card(_ value: [String: Any], id: String, name: String?) -> [String: Any] {
            var result: [String: Any] = ["limitId": id]
            result["limitName"] = name
            result["planType"] = raw["plan_type"]
            result["primary"] = window(value["primary_window"])
            result["secondary"] = window(value["secondary_window"])
            result["ordinaryUsageAllowed"] = value["allowed"]
            return result
        }
        var limits: [String: Any] = [:]
        if let ordinary = raw["rate_limit"] as? [String: Any] {
            limits["codex"] = card(ordinary, id: "codex", name: nil)
        }
        for entry in raw["additional_rate_limits"] as? [[String: Any]] ?? [] {
            guard let id = entry["metered_feature"] as? String, !id.isEmpty,
                  let rate = entry["rate_limit"] as? [String: Any], limits[id] == nil else { continue }
            limits[id] = card(rate, id: id, name: entry["limit_name"] as? String)
        }
        var result: [String: Any] = ["rateLimitsByLimitId": limits]
        result["planType"] = raw["plan_type"]
        return result
    }
}
