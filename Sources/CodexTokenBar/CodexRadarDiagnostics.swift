import Foundation

enum CodexRadarDiagnosticCategory: String, Equatable, Sendable {
    case networkFetch = "network_fetch"
    case timeout
    case httpAuth = "http_auth"
    case httpRateLimited = "http_rate_limited"
    case httpServer = "http_server"
    case httpOther = "http_other"
    case parseFailure = "parse_failure"
    case emptyRadar = "empty_radar"
    case rssFailure = "rss_failure"
    case staleCachedData = "stale_cached_data"
    case unknown
}

enum CodexRadarDiagnosticSource: String, Equatable, Sendable {
    case current = "current"
    case rss
}

enum CodexRadarDiagnosticSeverity: String, Equatable, Sendable {
    case warning
    case error
}

struct CodexRadarDiagnostic: LocalizedError, Equatable, Sendable {
    var source: CodexRadarDiagnosticSource
    var category: CodexRadarDiagnosticCategory
    var severity: CodexRadarDiagnosticSeverity
    var message: String
    var rawCause: String?
    var underlyingCategory: CodexRadarDiagnosticCategory?
    var httpStatus: Int?
    var retryable: Bool
    var occurredAt: Date?
    var staleDataDisplayed: Bool

    init(
        source: CodexRadarDiagnosticSource,
        category: CodexRadarDiagnosticCategory,
        severity: CodexRadarDiagnosticSeverity,
        message: String,
        rawCause: String? = nil,
        underlyingCategory: CodexRadarDiagnosticCategory? = nil,
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
        self.httpStatus = httpStatus
        self.retryable = retryable
        self.occurredAt = occurredAt
        self.staleDataDisplayed = staleDataDisplayed
    }

    var errorDescription: String? {
        message
    }

    static func classify(
        source: CodexRadarDiagnosticSource,
        error: Error,
        occurredAt: Date? = nil
    ) -> CodexRadarDiagnostic {
        let category = category(for: error)
        return CodexRadarDiagnostic(
            source: source,
            category: category,
            severity: severity(for: category),
            message: message(for: category, fallback: error.localizedDescription),
            rawCause: rawCause(for: error),
            httpStatus: httpStatus(for: error),
            retryable: retryable(for: category),
            occurredAt: occurredAt
        )
    }

    static func rssFailure(
        underlying: CodexRadarDiagnostic,
        occurredAt: Date? = nil
    ) -> CodexRadarDiagnostic {
        CodexRadarDiagnostic(
            source: .rss,
            category: .rssFailure,
            severity: .warning,
            message: "Codex 雷达 RSS 读取失败",
            rawCause: underlying.rawCause,
            underlyingCategory: underlying.category,
            httpStatus: underlying.httpStatus,
            retryable: underlying.retryable,
            occurredAt: occurredAt ?? underlying.occurredAt
        )
    }

    static func staleCachedData(
        source: CodexRadarDiagnosticSource,
        rawCause: String? = nil,
        occurredAt: Date? = nil
    ) -> CodexRadarDiagnostic {
        CodexRadarDiagnostic(
            source: source,
            category: .staleCachedData,
            severity: .warning,
            message: "显示上次成功读取的 Codex 雷达",
            rawCause: rawCause,
            retryable: true,
            occurredAt: occurredAt,
            staleDataDisplayed: true
        )
    }

    private static func category(for error: Error) -> CodexRadarDiagnosticCategory {
        if let readerError = error as? CodexRadarReaderError {
            switch readerError {
            case .invalidResponse:
                return .parseFailure
            case .emptyPayload:
                return .emptyRadar
            case .httpStatus(let status):
                return category(forHTTPStatus: status)
            }
        }
        if error is DecodingError || error is CodexRadarFeedParserError {
            return .parseFailure
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
                    .dataNotAllowed, .internationalRoamingOff:
                return .networkFetch
            default:
                return .networkFetch
            }
        }
        return .unknown
    }

    private static func category(forHTTPStatus status: Int) -> CodexRadarDiagnosticCategory {
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

    private static func severity(for category: CodexRadarDiagnosticCategory) -> CodexRadarDiagnosticSeverity {
        switch category {
        case .rssFailure, .staleCachedData:
            return .warning
        default:
            return .error
        }
    }

    private static func message(for category: CodexRadarDiagnosticCategory, fallback: String) -> String {
        switch category {
        case .networkFetch:
            return "Codex 雷达网络请求失败"
        case .timeout:
            return "Codex 雷达读取超时"
        case .httpAuth:
            return "Codex 雷达授权失败"
        case .httpRateLimited:
            return "Codex 雷达请求过于频繁"
        case .httpServer:
            return "Codex 雷达服务器暂时不可用"
        case .httpOther:
            return "Codex 雷达返回异常"
        case .parseFailure:
            return "Codex 雷达响应格式异常"
        case .emptyRadar:
            return "Codex 雷达暂无数据"
        case .rssFailure:
            return "Codex 雷达 RSS 读取失败"
        case .staleCachedData:
            return "显示上次成功读取的 Codex 雷达"
        case .unknown:
            return fallback.isEmpty ? "Codex 雷达未知错误" : fallback
        }
    }

    private static func retryable(for category: CodexRadarDiagnosticCategory) -> Bool {
        switch category {
        case .parseFailure, .emptyRadar:
            return false
        default:
            return true
        }
    }

    private static func httpStatus(for error: Error) -> Int? {
        guard case .httpStatus(let status) = error as? CodexRadarReaderError else {
            return nil
        }
        return status
    }

    private static func rawCause(for error: Error) -> String {
        if let readerError = error as? CodexRadarReaderError {
            return readerError.errorDescription ?? error.localizedDescription
        }
        return error.localizedDescription
    }
}
