import Foundation
import CoreFoundation

/// Reads app-owned statusline capture first, then a pre-existing monitor cache.
/// Does not install a hook, launch Claude, read credentials or perform network requests.
struct ClaudeLocalQuota: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        let usedPercent: Double
        let resetsAt: Date?
    }
    let state: String
    let capturedAt: Date?
    let fiveHour: Window?
    let sevenDay: Window?
    var source: String? = nil
    static let missing = Self(state: "missing", capturedAt: nil, fiveHour: nil, sevenDay: nil)
    static let desktopHistoryMaximumBytes = 4 * 1_024 * 1_024

    static func readDesktop(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> Self {
        let history = readDesktopHistory(home: home, now: now)
        let cache = ClaudeDesktopHTTPCache.read(directory: home.appendingPathComponent("Library/Application Support/Claude/Cache/Cache_Data"), now: now)
        return desktopObservation(history: history, cache: cache)
    }

    /// Select one complete observation. Never fill one account's missing window from another.
    static func desktopObservation(history: Self, cache: Self?) -> Self {
        guard let cache else { return history }
        return (history.capturedAt ?? .distantPast) > (cache.capturedAt ?? .distantPast) ? history : cache
    }

    /// Separate from CLI captures: neither source proves which account the other uses.
    static func readDesktopHistory(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> Self {
        let url = home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            let error = error as NSError
            let missing = error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
            return .init(state: missing ? "missing" : "invalid", capturedAt: nil, fiveHour: nil, sevenDay: nil)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue >= 0,
              size.intValue <= desktopHistoryMaximumBytes else { return .init(state: "invalid", capturedAt: nil, fiveHour: nil, sevenDay: nil) }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: desktopHistoryMaximumBytes + 1) ?? Data()
            return decodeDesktopHistory(data, now: now)
        } catch { return .init(state: "invalid", capturedAt: nil, fiveHour: nil, sevenDay: nil) }
    }

    static func decodeDesktopHistory(_ data: Data, now: Date) -> Self {
        func empty(_ state: String, _ captured: Date? = nil) -> Self { .init(state: state, capturedAt: captured, fiveHour: nil, sevenDay: nil) }
        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        guard data.count <= desktopHistoryMaximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = number(root["version"]), version == 1 || version == 2,
              let samples = root["samples"] as? [Any], samples.count <= 50_000 else { return empty("invalid") }
        var latest: (time: Double, row: [String: Any])?
        for element in samples {
            guard let row = element as? [String: Any] else { continue }
            guard let time = number(row["t"]), time >= 0 else { continue }
            if latest == nil || time >= latest!.time { latest = (time, row) }
        }
        guard let latest else { return empty(samples.isEmpty ? "missing" : "invalid") }
        let captured = Date(timeIntervalSince1970: latest.time / 1_000)
        guard captured <= now.addingTimeInterval(60) else { return empty("invalid") }
        // Idle Desktop clients may not sample again until Usage is opened.
        // Keep the last observation; display selection owns the three-day gate.
        // Never complete a new organization's partial sample from another row or source.
        guard let values = version == 1 ? latest.row : latest.row["u"] as? [String: Any] else { return empty("missing", captured) }
        func window(_ key: String) -> Window? {
            guard let used = number(values[key]), (0...100).contains(used) else { return nil }
            return Window(usedPercent: used, resetsAt: nil)
        }
        let five = window("fh"), seven = window("sd")
        return .init(state: five == nil && seven == nil ? "missing" : "available", capturedAt: captured, fiveHour: five, sevenDay: seven)
    }
    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date(),
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        if usesAPI(home: home, environment: environment) {
            return Self(state: "api", capturedAt: nil, fiveHour: nil, sevenDay: nil)
        }
        let candidates = [home.appendingPathComponent("Library/Application Support/CodexTokenBar/claude-local-statusline/latest.json"),
                          home.appendingPathComponent(".claude-monitor/statusline/latest.json")]
        for url in candidates {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue >= 0,
                  size.intValue <= 65_536 else { return Self(state: "invalid", capturedAt: nil, fiveHour: nil, sevenDay: nil) }
            let data: Data
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                data = try handle.read(upToCount: 65_537) ?? Data()
            } catch {
                return Self(state: "invalid", capturedAt: nil, fiveHour: nil, sevenDay: nil)
            }
            guard data.count <= 65_536 else { return Self(state: "invalid", capturedAt: nil, fiveHour: nil, sevenDay: nil) }
            // A stale/invalid app capture must not silently display an older
            // account's legacy cache as if it were current.
            return decode(data, now: now)
        }
        return .missing
    }

    static func usesAPI(home: URL, environment: [String: String]) -> Bool {
        let directory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        var env = environment
        if let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent("settings.json")) {
            defer { try? handle.close() }
            if let bytes = try? handle.read(upToCount: 65_537), bytes.count <= 65_536,
               let settings = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                if let helper = settings["apiKeyHelper"] as? String, !helper.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
                if let configured = settings["env"] as? [String: String] { env.merge(configured) { _, value in value } }
            }
        }
        if ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"].contains(where: {
            !(env[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) { return true }
        return ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"].contains {
            ["1", "true"].contains((env[$0] ?? "").lowercased())
        }
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
