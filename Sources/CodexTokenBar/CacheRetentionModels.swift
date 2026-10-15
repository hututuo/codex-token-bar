import CryptoKit
import Foundation

/// Diagnostic facts only. These never participate in token billing.
struct CacheRetentionPoint: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let sourceKey: String
    let sessionKey: String
    let model: String
    let gapMicroseconds: Int64
    let startedAtMicroseconds: Int64
    let previousInput: Int64
    let previousCached: Int64
    let input: Int64
    let cached: Int64
    var highReuse: Bool { cached >= input - input / 5 }
    var hitRate: Double { Double(cached) / Double(input) }
}

enum CacheRetentionIdentity {
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct CacheRetentionPair: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let sessionKey: String
    let previousID: String
    let nextID: String
    let stableTurnIDs: Bool
    let evidenceSignature: String
    let point: CacheRetentionPoint?
    var reasons: Set<String>
    var eligible: Bool { point != nil && reasons.isEmpty }
    var stableKey: String? { stableTurnIDs ? "\(sessionKey):\(previousID):\(nextID)" : nil }
}

struct CacheRetentionScope: Equatable, Sendable {
    enum Range: String, CaseIterable, Identifiable { case all = "全部历史", month = "最近 30 天", week = "最近 7 天"; var id: String { rawValue } }
    var range: Range = .all
    var model: String? = nil
    func contains(_ point: CacheRetentionPoint, now: Date) -> Bool {
        guard model == nil || model == point.model else { return false }
        let days = range == .all ? nil : (range == .month ? 30.0 : 7.0)
        return days.map { Double(point.startedAtMicroseconds) / 1_000_000 >= now.timeIntervalSince1970 - $0 * 86400 } ?? true
    }
}

struct CacheRetentionSnapshot: Sendable {
    var points: [CacheRetentionPoint] = []
    var models: [String] = []
    var analysis = CacheRetentionAnalysis.calculate([])
    var sourceCount = 0
    var ownRoundCount = 0
    var updatedAt: Date?
    var revision: Int64 = 0
    var scope = CacheRetentionScope()
    var chartData = CacheRetentionChartData(points: [])
}

enum CacheRetentionCopy {
    static func minutes(_ microseconds: Double) -> String {
        let minutes = microseconds / 60_000_000
        return minutes < 1 ? String(format: "%.0f 秒", microseconds / 1_000_000) : String(format: "%.1f 分钟", (minutes * 10).rounded() / 10)
    }
    static func recommendation(_ analysis: CacheRetentionAnalysis) -> String {
        guard let earlier = analysis.earlierDecline else {
            return analysis.dropMicroseconds == nil ? "暂未找到可靠的续问时间建议" : "暂未找到更早的下降点"
        }
        return "建议尽量在约 \(minutes(earlier.microseconds))内续问"
    }
    static func coverage(_ analysis: CacheRetentionAnalysis) -> String {
        if analysis.p95State == .rangeTooLarge { return "历史记录较多，请在图表中缩小范围" }
        guard let value = analysis.p95Microseconds else { return "正在积累高命中历史" }
        return "过去高命中的续问，95% 在约 \(minutes(Double(value)))内"
    }
    static func risk(_ analysis: CacheRetentionAnalysis) -> String {
        guard let value = analysis.dropMicroseconds else { return "暂未找到明显风险分界" }
        return "超过约 \(minutes(value))后，低命中更常见"
    }
}
