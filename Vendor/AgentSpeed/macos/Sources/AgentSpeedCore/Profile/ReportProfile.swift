import Foundation

public struct ReportProfileSnapshot: Equatable, Sendable {
    public struct Avatar: Equatable, Sendable {
        public var url: URL
        public var sha256: String
    }
    public struct Device: Equatable, Sendable, Identifiable {
        public var deviceId: String
        public var platform: String
        public var isCurrent: Bool
        public var online: Bool
        public var id: String { deviceId }
    }
    public var sharedUserId: String?
    public var displayName: String
    public var avatar: Avatar?
    public var devices: [Device]
    public static let maxBytes = 65_536

    public static func parse(_ data: Data, rules: ReportUsernameRules = .init(minLength: 1)) -> ReportProfileSnapshot? {
        guard data.count <= maxBytes, let root = try? JSONParser.parse(data), root.object != nil,
              let name = root["displayName"]?.string,
              ReportUsername.validate(name, rules: rules) == nil,
              root["avatar"] != nil,
              let rawDevices = root["devices"]?.array, rawDevices.count <= 32 else { return nil }
        let shared: String?
        if root["sharedUserId"] == .null { shared = nil }
        else { guard let id = root["sharedUserId"]?.string, ReportCanonical.isDeviceId(id) else { return nil }; shared = id }
        var avatar: Avatar?
        if let value = root["avatar"], value != .null {
            guard let url = ReportURLs.httpsLink(value["url"]?.string),
                  let hash = value["sha256"]?.string, hash.utf8.count == 64, hash.utf8.allSatisfy({ "0123456789abcdef".utf8.contains($0) }),
                  value["contentType"]?.string == "image/png", value["width"]?.int64 == 256, value["height"]?.int64 == 256 else { return nil }
            avatar = Avatar(url: url, sha256: hash)
        }
        var devices: [Device] = []
        for value in rawDevices {
            guard let id = value["deviceId"]?.string, ReportCanonical.isDeviceId(id),
                  !devices.contains(where: { $0.deviceId == id }),
                  let platform = platform(value["platform"]?.string),
                  let current = value["isCurrent"]?.bool, let online = value["online"]?.bool else { return nil }
            devices.append(Device(deviceId: id, platform: platform, isCurrent: current, online: online))
        }
        guard devices.filter(\.isCurrent).count <= 1 else { return nil }
        return ReportProfileSnapshot(sharedUserId: shared, displayName: name, avatar: avatar, devices: devices)
    }

    static func platform(_ raw: String?) -> String? {
        guard let raw, ["macOS", "Windows"].contains(raw) else { return nil }
        return raw
    }
}

public struct ReportPairingSnapshot: Equatable, Sendable {
    public enum State: String, Sendable { case waiting, pending, approved, cancelled, expired }
    public struct Claimant: Equatable, Sendable {
        public var deviceId: String
        public var platform: String
    }
    public var id: String
    public var state: State
    public var expiresAt: Date
    public var claimant: Claimant?
    public var code: String?

    public static func normalizedCode(_ raw: String) -> String? {
        let code = raw.uppercased().replacingOccurrences(of: "-", with: "")
        guard code.utf8.count == 12, code.utf8.allSatisfy({ "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".utf8.contains($0) }) else { return nil }
        return code
    }
    public static func parse(_ data: Data, allowsCode: Bool = false, now: Date = Date()) -> ReportPairingSnapshot? {
        guard data.count <= ReportProfileSnapshot.maxBytes, let root = try? JSONParser.parse(data),
              let id = root["id"]?.string, ReportCanonical.isDeviceId(id),
              let state = root["state"]?.string.flatMap(State.init(rawValue:)),
              let stamp = root["expiresAt"]?.string,
              let date = utcMillisecondDate(stamp),
              date.timeIntervalSince(now) <= 11 * 60 else { return nil }
        var claimant: Claimant?
        if let value = root["claimant"], value != .null {
            guard let device = value["deviceId"]?.string, ReportCanonical.isDeviceId(device),
                  let platform = ReportProfileSnapshot.platform(value["platform"]?.string) else { return nil }
            claimant = Claimant(deviceId: device, platform: platform)
        }
        if state == .pending, claimant == nil { return nil }
        let code = root["code"]?.string
        if let code, !allowsCode || normalizedCode(code) == nil { return nil }
        if allowsCode, state == .waiting, code == nil { return nil }
        return ReportPairingSnapshot(id: id, state: state, expiresAt: date, claimant: claimant, code: code)
    }
    private static func utcMillisecondDate(_ stamp: String) -> Date? {
        let bytes = Array(stamp.utf8)
        guard bytes.count == 24 else { return nil }
        let separators: [Int: UInt8] = [4: 45, 7: 45, 10: 84, 13: 58, 16: 58, 19: 46, 23: 90]
        for (index, byte) in bytes.enumerated() {
            if let expected = separators[index] { guard byte == expected else { return nil } }
            else if !(48...57).contains(byte) { return nil }
        }
        guard let date = ISO8601DateFormatter.fractional.date(from: stamp),
              ReportInstant.format(unixMs: Int64((date.timeIntervalSince1970 * 1000).rounded())) == stamp else { return nil }
        return date
    }

}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
