import Foundation

/// Shared with Tauri. Unknown data stays visible as a state, never a zero balance.
enum ClientQuotaPresentation {
    static let automaticCacheAge: TimeInterval = 3 * 24 * 60 * 60
    static func shouldAutomaticallyShow(_ reading: ClientQuotaReading, now: Date = Date()) -> Bool {
        guard reading.source != "unsupported", ["available", "stale", "cached"].contains(reading.state),
              let captured = reading.capturedAt, captured <= now.addingTimeInterval(60),
              now.timeIntervalSince(captured) <= automaticCacheAge else { return false }
        return ["claudeCode", "claudeDesktop", "antigravity"].contains(reading.client)
    }
    static func percentNumber(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        return text.replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
    }
    private struct State: Decodable { let label: String; let compact: String }
    private struct Policy: Decodable { let schema: Int; let states: [String: State] }
    private static let states: [String: State] = {
        guard let url = AppResources.url(forResource: "client-quota-presentation", withExtension: "json"),
              let data = try? Data(contentsOf: url), let policy = try? JSONDecoder().decode(Policy.self, from: data),
              policy.schema == 1 else { return [:] }
        return policy.states
    }()
    static func status(_ state: String) -> String { states[state]?.label ?? "额度不可用" }
    static func compact(_ state: String?) -> String { state.flatMap { states[$0]?.compact } ?? "—" }
    static func isPresent(_ reading: ClientQuotaReading, detected: Bool = false) -> Bool {
        reading.source != "unsupported" && (detected || reading.state == "api" || !reading.windows.isEmpty || reading.capturedAt != nil)
    }
}
