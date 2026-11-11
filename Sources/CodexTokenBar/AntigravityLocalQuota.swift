import CoreFoundation
import Foundation
import SQLite3

/// Active Hub uses its authorized loopback RPC; otherwise retain the offline cache path.
enum AntigravityLocalQuota {
    static let maximumBytes = 512 * 1_024
    static let statusKey = "antigravityUnifiedStateSync.userStatus"
    static let freshness: TimeInterval = 20 * 60

    static func empty(_ state: String = "notConnected", source: String = "local-antigravity-state") -> ClientQuotaReading {
        .init(client: "antigravity", state: state, source: source, windows: [],
              notice: "未读到可用的 Antigravity 本地额度缓存。只读已有文件，不启动客户端、不发网络请求。")
    }

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> ClientQuotaReading {
        if home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL,
           let live = AntigravityLocalRPCQuota.read(home: home, now: now) { return live }
        // Tools has an explicit selected-account pointer and a quota capture time. Do not scan
        // every account or recover old .bak files after the selected record becomes invalid.
        let tools = home.appendingPathComponent(".antigravity_tools")
        let index = tools.appendingPathComponent("accounts.json")
        if FileManager.default.fileExists(atPath: index.path) { return readTools(directory: tools, now: now) }
        return readState(at: home.appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb"), now: now)
    }

    static func readTools(directory: URL, now: Date) -> ClientQuotaReading {
        let source = "local-antigravity-tools"
        guard let bytes = LocalQuotaCacheFile.read(directory.appendingPathComponent("accounts.json"), limit: maximumBytes),
              let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let id = root["current_account_id"] as? String,
              id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
              let accounts = root["accounts"] as? [[String: Any]], accounts.count <= 1_024,
              accounts.contains(where: { $0["id"] as? String == id }),
              let account = LocalQuotaCacheFile.read(directory.appendingPathComponent("accounts/" + id + ".json"), limit: maximumBytes) else { return empty("unavailable", source: source) }
        return decodeTools(account, selectedID: id, now: now)
    }

    static func decodeTools(_ data: Data, selectedID: String, now: Date) -> ClientQuotaReading {
        let source = "local-antigravity-tools"
        guard data.count <= maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["id"] as? String == selectedID, root["disabled"] as? Bool != true,
              let quota = root["quota"] as? [String: Any], quota["is_forbidden"] as? Bool != true,
              let epoch = number(quota["last_updated"]), epoch > 0, epoch <= now.timeIntervalSince1970 + 60,
              let models = quota["models"] as? [[String: Any]], models.count <= 128 else { return empty("unavailable", source: source) }
        let captured = Date(timeIntervalSince1970: epoch)
        var seen = Set<String>()
        let windows = models.compactMap { model -> ClientQuotaReading.Window? in
            guard let id = model["name"] as? String, validLabel(id), seen.insert(id).inserted,
                  let remaining = number(model["percentage"]), (0...100).contains(remaining) else { return nil }
            let label = (model["display_name"] as? String).flatMap { validLabel($0) ? $0 : nil } ?? id
            let reset = (model["reset_time"] as? String).flatMap(LocalQuotaCacheFile.isoDate)
            return .init(label: label, usedPercent: 100 - remaining, resetsAt: reset, id: id)
        }
        let stale = now.timeIntervalSince(captured) > freshness || windows.contains { $0.resetsAt.map { $0 <= now } ?? true }
        return .init(client: "antigravity", state: windows.isEmpty ? "unavailable" : stale ? "stale" : "available",
            source: source, windows: windows,
            notice: "Antigravity Tools 所选账号的本地采样；未验证与当前 Antigravity 账号一致。逐模型展示，不合计余额。" + (stale ? "采样已过期，不作为当前余额。" : ""), capturedAt: captured)
    }

    static func readState(at url: URL, now: Date) -> ClientQuotaReading {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return empty() }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return empty("unavailable") }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return empty("unavailable")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'antigravityUnifiedStateSync.userStatus' AND length(CAST(value AS BLOB)) <= 524288 LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return empty("unavailable") }
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else { return empty(code == SQLITE_DONE ? "notConnected" : "unavailable") }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count <= maximumBytes, let raw = sqlite3_column_blob(statement, 0) else { return empty("unavailable") }
        return decodeState(Data(bytes: raw, count: count), now: now)
    }

    static func decodeState(_ data: Data, now: Date) -> ClientQuotaReading {
        guard data.count <= maximumBytes, let outer = Data(base64Encoded: data), let envelope = try? fields(outer),
              let entryData = envelope.first(where: { $0.tag == 1 })?.bytes,
              let entry = try? fields(entryData), let value = entry.first(where: { $0.tag == 2 })?.bytes,
              let wrapped = try? fields(value), let encoded = wrapped.first(where: { $0.tag == 1 })?.bytes,
              let status = Data(base64Encoded: encoded), let user = try? fields(status),
              let config = user.first(where: { $0.tag == 33 })?.bytes, let configs = try? fields(config) else { return empty("unavailable") }
        var windows: [ClientQuotaReading.Window] = [], seen = Set<String>()
        for field in configs where field.tag == 1 {
            guard windows.count < 128, let bytes = field.bytes, let model = try? fields(bytes),
                  let labelBytes = model.first(where: { $0.tag == 1 })?.bytes, let label = String(data: labelBytes, encoding: .utf8), validLabel(label),
                  let idBytes = model.first(where: { $0.tag == 2 })?.bytes, let ids = try? fields(idBytes),
                  let id = ids.first(where: { $0.tag == 1 })?.integer,
                  let quotaBytes = model.first(where: { $0.tag == 15 })?.bytes, let quota = try? fields(quotaBytes),
                  let fraction = quota.first(where: { $0.tag == 1 }).map({ $0.float }) ?? Float(0), fraction.isFinite, (0...1).contains(fraction),
                  seen.insert(String(id)).inserted else { continue }
            let reset = quota.first(where: { $0.tag == 2 })?.bytes.flatMap { try? fields($0) }?
                .first(where: { $0.tag == 1 })?.integer.map { Date(timeIntervalSince1970: Double($0)) }
            windows.append(.init(label: label, usedPercent: (1 - Double(fraction)) * 100, resetsAt: reset, id: "model-\(id)"))
        }
        let stale = windows.contains { $0.resetsAt.map { $0 <= now } ?? false }
        return .init(client: "antigravity", state: windows.isEmpty ? "unavailable" : stale ? "stale" : "cached",
            source: "local-antigravity-state", windows: windows,
            notice: "Antigravity IDE 本地模型额度缓存；未验证当前账号。此格式没有采样时间，数据库修改时间不代表额度刷新，不能作为实时余额。")
    }

    private static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private struct Field { let tag: Int; var bytes: Data? = nil; var integer: UInt64? = nil; var float: Float? = nil }
    private enum Invalid: Error { case wire }
    private static func fields(_ data: Data) throws -> [Field] {
        guard data.count <= maximumBytes else { throw Invalid.wire }
        var offset = 0, result: [Field] = []
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < data.count else { throw Invalid.wire }
                let byte = data[offset]; offset += 1
                guard shift != 63 || byte <= 1 else { throw Invalid.wire }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw Invalid.wire
        }
        while offset < data.count {
            let tag = try varint()
            guard tag >> 3 > 0, tag >> 3 <= 0x1fffffff, result.count < 2_048 else { throw Invalid.wire }
            var field = Field(tag: Int(tag >> 3))
            switch tag & 7 {
            case 0: field.integer = try varint()
            case 2:
                let count = try varint()
                guard count <= UInt64(data.count - offset) else { throw Invalid.wire }
                field.bytes = data.subdata(in: offset..<offset + Int(count)); offset += Int(count)
            case 5:
                guard offset + 4 <= data.count else { throw Invalid.wire }
                let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
                field.float = Float(bitPattern: bits); offset += 4
            case 1:
                guard offset + 8 <= data.count else { throw Invalid.wire }; offset += 8
            default: throw Invalid.wire
            }
            result.append(field)
        }
        return result
    }
}
