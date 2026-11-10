import Foundation

/// Shared with Tauri. Unknown data stays visible as a state, never a zero balance.
enum ClientQuotaPresentation {
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
