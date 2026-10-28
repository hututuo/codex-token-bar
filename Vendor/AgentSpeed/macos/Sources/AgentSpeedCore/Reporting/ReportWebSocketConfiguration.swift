import Foundation

/// Draft-1 capability. Invalid optional WS fields disable only WS, never legacy HTTP.
public struct ReportWebSocketConfiguration: Equatable, Sendable, Codable {
    public var minIntervalMs: Int
    public var maxInFlight: Int
    public var ackTimeoutMs: Int
    public var maxMessageBytes: Int
    public var pingIntervalSeconds: Int
    public var pongTimeoutSeconds: Int
    public static let subprotocolName = "agent-speed-report.v1"
    public init?(root: [String: JSONValue]) {
        guard root["extensions"]?.object?["reportWebSocket"]?.literal?.text == "1",
              let fields = root["websocket"]?.object,
              fields["path"]?.string == "/v1/reports/ws",
              fields["subprotocol"]?.string == Self.subprotocolName else { return nil }
        func int(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int? {
            guard let value = fields[key] else { return fallback }
            guard let literal = value.literal, literal.isInteger, let n = literal.int64,
                  n >= range.lowerBound, n <= range.upperBound else { return nil }
            return Int(n)
        }
        guard let min = int("minIntervalMs", 50, 10...1000), let flight = int("maxInFlight", 8, 1...64),
              let ack = int("ackTimeoutMs", 2000, 500...10000), let size = int("maxMessageBytes", 65536, 32768...65536),
              let ping = int("pingIntervalSeconds", 20, 10...60), let pong = int("pongTimeoutSeconds", 10, 5...30), pong < ping else { return nil }
        minIntervalMs = min; maxInFlight = flight; ackTimeoutMs = ack; maxMessageBytes = size
        pingIntervalSeconds = ping; pongTimeoutSeconds = pong
    }
    public static func isTimestamp(_ text: String) -> Bool {
        guard text.utf8.count == 24, text.hasSuffix("Z") else { return false }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) != nil
    }
    public func matchesReady(_ fields: [String: JSONValue]) -> Bool {
        let pairs = [("version",1),("transportVersion",1),("minIntervalMs",minIntervalMs),("maxInFlight",maxInFlight),
                     ("ackTimeoutMs",ackTimeoutMs),("maxMessageBytes",maxMessageBytes),("pingIntervalSeconds",pingIntervalSeconds),
                     ("pongTimeoutSeconds",pongTimeoutSeconds)]
        return fields["type"]?.string == "ready" && fields["protocol"]?.string == "agent-speed-report"
            && pairs.allSatisfy { fields[$0.0]?.literal?.text == String($0.1) }
            && fields["serverTime"]?.string.map(Self.isTimestamp) == true
    }
}
