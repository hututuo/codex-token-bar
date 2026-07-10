import Foundation

enum AccountQuotaDiagnosticCategory: String, Equatable, Sendable {
    case authMissing = "auth_missing"
    case appServerUnavailable = "app_server_unavailable"
    case timeout
    case networkSendFetch = "network_send_fetch"
    case httpAuth = "http_auth"
    case httpRateLimited = "http_rate_limited"
    case httpServer = "http_server"
    case httpOther = "http_other"
    case parseFailure = "parse_failure"
    case emptyQuota = "empty_quota"
    case resetCreditFailure = "reset_credit_failure"
    case staleCachedData = "stale_cached_data"
    case sourceMismatch = "source_mismatch"
    case unknown
}

enum AccountQuotaDiagnosticSource: String, Equatable, Sendable {
    case accountQuota = "account_quota"
    case resetCredit = "reset_credit"
    case sourceIntegrity = "source_integrity"
}

enum AccountQuotaDiagnosticSeverity: String, Equatable, Sendable {
    case info
    case warning
    case error
}

struct AccountQuotaDiagnostic: LocalizedError, Equatable, Sendable {
    var source: AccountQuotaDiagnosticSource
    var category: AccountQuotaDiagnosticCategory
    var severity: AccountQuotaDiagnosticSeverity
    var message: String
    var rawCause: String?
    var underlyingCategory: AccountQuotaDiagnosticCategory?
    var attempts: Int?
    var httpStatus: Int?
    var retryable: Bool
    var occurredAt: Date?
    var staleDataDisplayed: Bool

    init(
        source: AccountQuotaDiagnosticSource,
        category: AccountQuotaDiagnosticCategory,
        severity: AccountQuotaDiagnosticSeverity,
        message: String,
        rawCause: String? = nil,
        underlyingCategory: AccountQuotaDiagnosticCategory? = nil,
        attempts: Int? = nil,
        httpStatus: Int? = nil,
        retryable: Bool = false,
        occurredAt: Date? = nil,
        staleDataDisplayed: Bool = false
    ) {
        self.source = source
        self.category = category
        self.severity = severity
        self.message = message
        self.rawCause = rawCause
        self.underlyingCategory = underlyingCategory
        self.attempts = attempts
        self.httpStatus = httpStatus
        self.retryable = retryable
        self.occurredAt = occurredAt
        self.staleDataDisplayed = staleDataDisplayed
    }

    var errorDescription: String? {
        message
    }

    static func category(forHTTPStatus status: Int) -> AccountQuotaDiagnosticCategory {
        switch status {
        case 401, 403:
            return .httpAuth
        case 429:
            return .httpRateLimited
        case 500...599:
            return .httpServer
        default:
            return .httpOther
        }
    }

    static func classify(
        source: AccountQuotaDiagnosticSource,
        error: Error,
        attempts: Int? = nil,
        httpStatus: Int? = nil,
        occurredAt: Date? = nil
    ) -> AccountQuotaDiagnostic {
        let category = category(for: error, httpStatus: httpStatus)
        let isOwnershipFailure = error is AccountQuotaProcessOwnershipFailure
        return AccountQuotaDiagnostic(
            source: source,
            category: category,
            severity: severity(for: category),
            message: message(for: category, fallback: error.localizedDescription),
            rawCause: rawCause(for: error, httpStatus: httpStatus),
            attempts: attempts,
            httpStatus: httpStatus,
            retryable: isOwnershipFailure ? false : retryable(for: category),
            occurredAt: occurredAt
        )
    }

    static func resetCreditFailure(
        underlying: AccountQuotaDiagnostic,
        occurredAt: Date? = nil
    ) -> AccountQuotaDiagnostic {
        AccountQuotaDiagnostic(
            source: .resetCredit,
            category: .resetCreditFailure,
            severity: .warning,
            message: "重置卡读取失败",
            rawCause: underlying.rawCause,
            underlyingCategory: underlying.category,
            httpStatus: underlying.httpStatus,
            retryable: underlying.category == .authMissing ? false : underlying.retryable,
            occurredAt: occurredAt ?? underlying.occurredAt
        )
    }

    static func staleCachedData(
        source: AccountQuotaDiagnosticSource,
        rawCause: String? = nil,
        occurredAt: Date? = nil
    ) -> AccountQuotaDiagnostic {
        AccountQuotaDiagnostic(
            source: source,
            category: .staleCachedData,
            severity: .warning,
            message: "显示上次成功读取的额度",
            rawCause: rawCause,
            retryable: true,
            occurredAt: occurredAt,
            staleDataDisplayed: true
        )
    }

    private static func category(for error: Error, httpStatus: Int?) -> AccountQuotaDiagnosticCategory {
        if let httpStatus {
            return category(forHTTPStatus: httpStatus)
        }
        if error is AccountQuotaProcessOwnershipFailure {
            return .appServerUnavailable
        }
        if let readerError = error as? AccountQuotaReaderError {
            switch readerError {
            case .codexBinaryNotFound:
                return .appServerUnavailable
            case .timeout, .timeoutWithOutput, .emptyResponse:
                return .timeout
            case .invalidResponse, .parseFailure:
                return .parseFailure
            case .emptyRateLimits:
                return .emptyQuota
            case .serverError:
                return .appServerUnavailable
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
                    .dataNotAllowed, .internationalRoamingOff:
                return .networkSendFetch
            default:
                return .networkSendFetch
            }
        }
        return .unknown
    }

    private static func message(for category: AccountQuotaDiagnosticCategory, fallback: String) -> String {
        switch category {
        case .authMissing:
            return "未找到登录信息"
        case .appServerUnavailable:
            return "Codex 本地服务不可用"
        case .timeout:
            return "额度读取超时"
        case .networkSendFetch:
            return "网络请求失败"
        case .httpAuth:
            return "登录授权失效"
        case .httpRateLimited:
            return "请求过于频繁"
        case .httpServer:
            return "服务器暂时不可用"
        case .httpOther:
            return "服务器返回异常"
        case .parseFailure:
            return "响应格式异常"
        case .emptyQuota:
            return "额度暂无数据"
        case .resetCreditFailure:
            return "重置卡读取失败"
        case .staleCachedData:
            return "显示上次成功读取的额度"
        case .sourceMismatch:
            return "额度来源不一致"
        case .unknown:
            return fallback.isEmpty ? "未知原因" : fallback
        }
    }

    private static func severity(for category: AccountQuotaDiagnosticCategory) -> AccountQuotaDiagnosticSeverity {
        switch category {
        case .staleCachedData:
            return .warning
        case .resetCreditFailure:
            return .warning
        default:
            return .error
        }
    }

    private static func retryable(for category: AccountQuotaDiagnosticCategory) -> Bool {
        switch category {
        case .authMissing, .parseFailure, .emptyQuota, .sourceMismatch:
            return false
        default:
            return true
        }
    }

    private static func rawCause(for error: Error, httpStatus: Int?) -> String {
        if let httpStatus {
            return "HTTP \(httpStatus): \(error.localizedDescription)"
        }
        if let readerError = error as? AccountQuotaReaderError {
            return readerError.rawCause
        }
        return error.localizedDescription
    }
}

enum AccountQuotaReaderError: LocalizedError, Equatable, Sendable {
    case codexBinaryNotFound
    case invalidResponse
    case emptyRateLimits
    case serverError(String)
    case timeout
    case timeoutWithOutput(String)
    case parseFailure(String)
    case emptyResponse

    static func timeout(stderrText: String?) -> AccountQuotaReaderError {
        guard let message = stderrText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return .timeout
        }
        return .timeoutWithOutput(message)
    }

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
        case .timeout, .timeoutWithOutput:
            return "额度读取超时"
        case .parseFailure(let message):
            return message.isEmpty ? "响应格式异常" : message
        case .emptyResponse:
            return "响应为空"
        }
    }

    var rawCause: String {
        switch self {
        case .codexBinaryNotFound:
            return "Codex binary was not found in known app or shell locations."
        case .invalidResponse:
            return "Invalid JSON-RPC quota response."
        case .emptyRateLimits:
            return "Quota response did not include usable rate limit windows."
        case .serverError(let message):
            return message
        case .timeoutWithOutput(let message):
            return message
        case .timeout:
            return "Timed out waiting for account/rateLimits/read."
        case .parseFailure(let message):
            return message
        case .emptyResponse:
            return "Empty response body."
        }
    }
}
