import Foundation

/// A response of the service (REPORTING 8), validated: only known shapes and clamped numbers are kept, and nothing of
/// it is ever shown to the user except through the app's own strings.
public struct ReportReply: Equatable, Sendable {
    public static let successStatuses: Set<String> = [
        "created", "exists", "updated", "unchanged", "rotated", "deleted", "accepted", "duplicate",
    ]

    public var status: Int
    /// `status` of a success body.
    public var result: String?
    public var deviceId: String?
    public var username: String?
    public var profileURL: URL?
    public var transferred = false
    /// 5–300 when present.
    public var intervalSeconds: Int?
    public var rank: Int?
    /// `error.code` when it is well-formed.
    public var code: String?
    public var reason: String?
    public var field: String?
    public var errorUsername: String?
    public var serverTime: Int64?
    public var supported: [Int] = []
    /// From `Retry-After` (seconds or an HTTP date) or `error.retryAfterSeconds`, unclamped.
    public var retryAfterSeconds: Int?
    /// `error.message` without control characters, at most 200 characters, for the log only.
    public var logMessage: String?

    public var isSuccess: Bool { (200..<300).contains(status) }

    public init(status: Int, result: String? = nil, code: String? = nil) {
        self.status = status
        self.result = result
        self.code = code
    }

    /// Parses a response; header names in any case. A body that is not the expected JSON leaves only `status`.
    public static func parse(status: Int, headers: [String: String], body: Data, now: Date = Date()) -> ReportReply {
        var reply = ReportReply(status: status)
        let lower = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        reply.retryAfterSeconds = lower["retry-after"].flatMap { retryAfter($0, now: now) }
        guard !body.isEmpty, let document = try? JSONParser.parse(body), let members = document.object else { return reply }
        if (200..<300).contains(status) {
            if let result = members["status"]?.string, successStatuses.contains(result) { reply.result = result }
            reply.deviceId = members["deviceId"]?.string.flatMap { ReportCanonical.isDeviceId($0) ? $0 : nil }
            reply.username = members["username"]?.string.flatMap(boundedName)
            reply.profileURL = ReportURLs.httpsLink(members["profileUrl"]?.string)
            reply.transferred = members["transferred"]?.bool ?? false
            reply.intervalSeconds = members["intervalSeconds"]?.int64.map { Int(min(max($0, 5), 300)) }
            reply.rank = members["rank"]?.int64.flatMap { (1...100_000_000).contains($0) ? Int($0) : nil }
        } else if let error = members["error"]?.object {
            reply.code = error["code"]?.string.flatMap { isCode($0) ? $0 : nil }
            reply.reason = error["reason"]?.string.map { String($0.prefix(32)) }
            reply.field = error["field"]?.string.map { sanitized($0, cap: 200) }
            reply.errorUsername = error["username"]?.string.flatMap(boundedName)
            reply.serverTime = error["serverTime"]?.int64.flatMap { $0 >= 0 ? $0 : nil }
            let supported: [JSONValue] = error["supported"]?.array ?? []
            reply.supported = supported.prefix(16).compactMap { (item: JSONValue) -> Int? in item.int64.map { Int($0) } }
            reply.logMessage = error["message"]?.string.map { sanitized($0, cap: 200) }
            if reply.retryAfterSeconds == nil {
                reply.retryAfterSeconds = error["retryAfterSeconds"]?.int64.flatMap { $0 >= 0 ? Int(min($0, 86_400)) : nil }
            }
        }
        return reply
    }

    /// `^[a-z][a-z0-9_]{0,47}$`.
    static func isCode(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1...48).contains(bytes.count), (97...122).contains(bytes[0]) else { return false }
        return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }

    /// Seconds, or an HTTP date relative to `now`.
    static func retryAfter(_ value: String, now: Date) -> Int? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if let seconds = Int(text), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return max(0, Int(date.timeIntervalSince(now).rounded(.up))) }
        }
        return nil
    }

    private static func boundedName(_ text: String) -> String? {
        let count = text.unicodeScalars.count
        return (1...32).contains(count) ? text : nil
    }

    static func sanitized(_ text: String, cap: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !(scalar.properties.generalCategory == .control
            || scalar.properties.generalCategory == .format) {
            scalars.append(scalar)
            if scalars.count >= cap { break }
        }
        return String(scalars)
    }
}

/// How the client reacts to a report's outcome (REPORTING 8.3, METRICS 11.5).
public enum ReportReaction: Equatable, Sendable {
    case none
    /// `timestamp_out_of_window`: keep `serverTime − local time` as the session's correction (METRICS 11.6).
    case correctClock(serverTime: Int64?)
    /// `unknown_device`: register again (at most once per hour).
    case reRegister
    /// `signature_invalid` without a pending key: re-check the registration.
    case recheckRegistration
    /// `signature_invalid` with a pending key: the scheduler attempts again at once, signed with it.
    case usePendingKey
    /// `username_mismatch`: rename to the user's chosen name once.
    case rename(registered: String?)
    /// `seq_conflict`: start a new run.
    case newRun
    /// `version_unsupported`, `payload_too_large`: fetch the discovery document again.
    case refreshDiscovery(upgrade: Bool)
    /// A rejection that stops reporting after three in a row (`bad_request`, `payload_invalid`, `not_found` …).
    case strike(misconfigured: Bool)
    /// Stop until the user acts.
    case needsUser(ReportProblem)
}

/// What needs the user (DESIGN 11, the red statuses).
public enum ReportProblem: String, Equatable, Codable, Sendable {
    case apiKey, usernameTaken, usernameRejected, keyMismatch, rejected, upgrade, gone, forbidden
}

public enum ReportOutcome {
    /// The scheduler's outcome and the reaction for a report attempt (REPORTING 8.3).
    public static func classify(_ result: Result<ReportReply, ReportTransportError>, hasPendingKey: Bool)
        -> (ReportScheduler.Outcome, ReportReaction) {
        let reply: ReportReply
        switch result {
        case .failure:
            return (.transient, .none)
        case .success(let value):
            reply = value
        }
        if reply.isSuccess { return (.delivered(intervalSeconds: reply.intervalSeconds), .none) }
        let retryAfter = reply.retryAfterSeconds.map { min(max($0, 5), 3600) }
        if (300..<400).contains(reply.status) { return (.transient, .none) }
        if reply.status == 429 || reply.code == "rate_limited" { return (.rateLimited(seconds: retryAfter ?? 60), .none) }
        if reply.status >= 500 {
            if reply.status == 503, let retryAfter { return (.rateLimited(seconds: retryAfter), .none) }
            return (.transient, .none)
        }
        switch reply.code ?? statusCode(reply.status) {
        case "timestamp_out_of_window": return (.rejected, .correctClock(serverTime: reply.serverTime))
        case "nonce_replayed": return (.again, .none)
        case "signature_invalid": return hasPendingKey ? (.again, .usePendingKey) : (.rejected, .recheckRegistration)
        case "api_key_required", "api_key_invalid": return (.rejected, .needsUser(.apiKey))
        case "forbidden": return (.rejected, .needsUser(.forbidden))
        case "unknown_device": return (.rejected, .reRegister)
        case "not_found", "method_not_allowed": return (.rejected, .strike(misconfigured: true))
        case "username_taken": return (.rejected, .needsUser(.usernameTaken))
        case "username_mismatch": return (.rejected, .rename(registered: reply.errorUsername))
        case "device_conflict": return (.rejected, .needsUser(.keyMismatch))
        case "seq_conflict": return (.rejected, .newRun)
        case "gone": return (.rejected, .needsUser(.gone))
        case "version_unsupported": return (.rejected, .refreshDiscovery(upgrade: true))
        case "payload_too_large": return (.rejected, .refreshDiscovery(upgrade: false))
        case "report_stale", "length_required": return (.rejected, .none)
        default: return (.rejected, .strike(misconfigured: false))
        }
    }

    /// The code a response without a usable error body stands for (REPORTING 8.3, last paragraph).
    static func statusCode(_ status: Int) -> String {
        switch status {
        case 404, 405: "not_found"
        case 410: "gone"
        case 413: "payload_too_large"
        case 403: "forbidden"
        default: "bad_request"
        }
    }
}
