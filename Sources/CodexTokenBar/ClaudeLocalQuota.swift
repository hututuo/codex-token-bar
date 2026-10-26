import Foundation

/// Reads app-owned statusline capture first, then a pre-existing monitor cache.
/// Does not install a hook, launch Claude, read credentials or perform network requests.
struct ClaudeLocalQuota: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        let usedPercent: Double
        let resetsAt: Date
    }
    let state: String
    let capturedAt: Date?
    let fiveHour: Window?
    let sevenDay: Window?
    static let missing = Self(state: "missing", capturedAt: nil, fiveHour: nil, sevenDay: nil)
    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> Self {
        let candidates = [home.appendingPathComponent("Library/Application Support/CodexTokenBar/claude-local-statusline/latest.json"),
                          home.appendingPathComponent(".claude-monitor/statusline/latest.json")]
        for url in candidates {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= 65_536,
                  let data = try? Data(contentsOf: url) else { return Self(state: "invalid", capturedAt: nil, fiveHour: nil, sevenDay: nil) }
            // A stale/invalid app capture must not silently display an older
            // account's legacy cache as if it were current.
            return decode(data, now: now)
        }
        return .missing
    }

    static func decode(_ data: Data, now: Date) -> Self {
        func empty(_ state: String, captured: Date? = nil) -> Self { Self(state: state, capturedAt: captured, fiveHour: nil, sevenDay: nil) }
        guard data.count <= 65_536, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let epoch = root["captured_at_epoch"] as? Double, epoch.isFinite else { return empty("invalid") }
        let captured = Date(timeIntervalSince1970: epoch)
        guard captured <= now.addingTimeInterval(60) else { return empty("invalid") }
        guard now.timeIntervalSince(captured) <= 600 else { return empty("stale", captured: captured) }
        guard let limits = root["rate_limits"] as? [String: Any] else { return empty("missing", captured: captured) }
        func window(_ key: String) -> Window? {
            guard let value = limits[key] as? [String: Any], let used = value["used_percentage"] as? Double,
                  used.isFinite, (0...100).contains(used), let reset = value["resets_at"] as? Double,
                  reset.isFinite, reset > now.timeIntervalSince1970 else { return nil }
            return Window(usedPercent: used, resetsAt: Date(timeIntervalSince1970: reset))
        }
        let five = window("five_hour"), seven = window("seven_day")
        return Self(state: five == nil && seven == nil ? "missing" : "available", capturedAt: captured, fiveHour: five, sevenDay: seven)
    }
}
