import Combine
import CryptoKit
import Foundation

enum ActivitySpeedSourceIdentity {
    static func root(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return "root-" + SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Display-only bounded memory. Historic activity tables remain untouched;
/// body TPS and usage accounting keep their independent durable stores.
@MainActor
final class ActivitySpeedHistoryController: ObservableObject {
    static let shared = ActivitySpeedHistoryController()
    @Published private(set) var revision = 0
    private var history = ActivityLiveHistory()
    private var activeSources: [String: String] = [:]
    private var enabled = false
    func start() { enabled = true }
    func reset(client: String) { history.reset(client: client); revision &+= 1 }
    func selectSource(client: String, identity: String?) {
        guard activeSources[client] != identity else { return }
        activeSources[client] = identity
        reset(client: client)
    }
    func record(client: String, sourceIdentity: String, rates: [ModelRateContribution], at time: Double, available: Bool, mode: ActivitySpeedDisplayMode) {
        guard enabled else { return }
        selectSource(client: client, identity: sourceIdentity)
        if history.record(client: client, mode: mode, rates: rates, at: time, available: available) { revision &+= 1 }
    }
    func rows(allowed: Set<String>, mode: ActivitySpeedDisplayMode, now: Double) -> [ActivityLiveSeries] {
        history.snapshot(allowed: allowed, mode: mode, now: now)
    }
    func refresh() { revision &+= 1 }
}
