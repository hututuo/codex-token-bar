import CryptoKit
import Foundation

struct LegacyClaudeSpeedMigrationReceipt: Equatable, Sendable {
    let rowCount: Int64
    let digest: String
    let sourceIdentity: String
    let committedAt: Double?
    let backupURL: URL?
    let didImport: Bool
}
enum LegacyClaudeSpeedMigration {
    private static let module = "legacy-claude-speed-v1"

    private struct Layout: Equatable { let hasMethod: Bool }
    private struct Fingerprint: Equatable { let rowCount: Int64; let digest: String }
    private struct ExistingReceipt { let rowCount: Int64; let digest: String; let committedAt: Double }
    private struct Row { let id: String; let ended: Double; let payload: Data; let model: String; let tokens: Int64; let duration: Double; let method: String? }

    enum MigrationError: Error {
        case invalidSource
        case invalidTarget
        case sourceChanged
    }

    /// Imports legacy rows as raw evidence; source is read-only and target must exist.
    static func migrate(source: URL, target: URL) throws -> LegacyClaudeSpeedMigrationReceipt {
        let identity = Self.sourceIdentity(for: source)
        guard FileManager.default.fileExists(atPath: source.path) else {
            return LegacyClaudeSpeedMigrationReceipt(
                rowCount: 0, digest: "", sourceIdentity: identity,
                committedAt: nil, backupURL: nil, didImport: false
            )
        }

        let reader = SQLiteDatabaseDriver(url: source, readOnly: true, createsFileIfMissing: false, busyTimeoutMilliseconds: 5_000)
        return try reader.withConnection { sourceDB in
            try sourceDB.execute("PRAGMA query_only=ON;")
            let (layout, fingerprint) = try sourceDB.readTransaction { snapshot in
                let layout = try Self.sourceLayout(in: snapshot)
                return (layout, try Self.scan(snapshot, layout: layout) { _ in })
            }

            let targetReader = SQLiteDatabaseDriver(url: target, readOnly: true, createsFileIfMissing: false, busyTimeoutMilliseconds: 5_000)
            let targetState = try Self.inspectTarget(targetReader, sourceIdentity: identity)
            if let previous = targetState.receipt {
                guard previous.rowCount == fingerprint.rowCount, previous.digest == fingerprint.digest else {
                    throw MigrationError.sourceChanged
                }
                return LegacyClaudeSpeedMigrationReceipt(
                    rowCount: previous.rowCount, digest: previous.digest,
                    sourceIdentity: identity, committedAt: previous.committedAt,
                    backupURL: nil, didImport: false
                )
            }

            let backup = try Self.backupTarget(target, expectedUserVersion: targetState.userVersion)
            let writer = SQLiteDatabaseDriver(url: target, createsFileIfMissing: false, busyTimeoutMilliseconds: 5_000)
            let now = Date().timeIntervalSince1970
            let result: (receipt: ExistingReceipt, didImport: Bool)
            do {
                result = try writer.transaction { destination -> (ExistingReceipt, Bool) in
                    try Self.installTables(in: destination)
                    if let previous = try Self.existingReceipt(in: destination, sourceIdentity: identity) {
                        guard previous.rowCount == fingerprint.rowCount, previous.digest == fingerprint.digest else {
                            throw MigrationError.sourceChanged
                        }
                        return (previous, false)
                    }

                    let verified = try sourceDB.readTransaction { snapshot -> Fingerprint in
                        let currentLayout = try Self.sourceLayout(in: snapshot)
                        guard currentLayout == layout else { throw MigrationError.sourceChanged }
                        return try Self.scan(snapshot, layout: layout) { row in
                            try destination.execute(
                                """
                                INSERT INTO legacy_claude_speed
                                    (source_identity,id,ended,payload,model,tokens,duration,method)
                                VALUES (?,?,?,CAST(? AS TEXT),?,?,?,?);
                                """,
                                bindings: [
                                    .text(identity), .text(row.id), .double(row.ended), .blob(row.payload),
                                    .text(row.model), .int64(row.tokens), .double(row.duration), .optionalText(row.method)
                                ]
                            )
                        }
                    }
                    guard verified == fingerprint else { throw MigrationError.sourceChanged }
                    let importedCount = try destination.readRows(
                        "SELECT COUNT(*) FROM legacy_claude_speed WHERE source_identity=?;",
                        bindings: [.text(identity)]
                    ) { $0.int64(0) ?? -1 }.first ?? -1
                    guard importedCount == fingerprint.rowCount else { throw MigrationError.sourceChanged }
                    try destination.execute(
                        """
                        INSERT INTO module_migrations(module,source_identity,row_count,digest,committed_at)
                        VALUES (?,?,?,?,?);
                        """,
                        bindings: [
                            .text(module), .text(identity), .int64(fingerprint.rowCount),
                            .text(fingerprint.digest), .double(now)
                        ]
                    )
                    return (ExistingReceipt(rowCount: fingerprint.rowCount, digest: fingerprint.digest, committedAt: now), true)
                }
            } catch {
                throw error
            }

            if !result.didImport {
                return LegacyClaudeSpeedMigrationReceipt(
                    rowCount: result.receipt.rowCount, digest: result.receipt.digest, sourceIdentity: identity,
                    committedAt: result.receipt.committedAt, backupURL: nil, didImport: false
                )
            }
            return LegacyClaudeSpeedMigrationReceipt(
                rowCount: result.receipt.rowCount, digest: result.receipt.digest, sourceIdentity: identity,
                committedAt: result.receipt.committedAt, backupURL: backup, didImport: true
            )
        }
    }

    private static func sourceLayout(in database: SQLiteDatabaseConnection) throws -> Layout {
        let isTable = try database.readRows(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='api_speed';"
        ) { $0.int(0) }.first != nil
        guard isTable else { throw MigrationError.invalidSource }
        let columns = Set(try database.readRows("PRAGMA table_info(api_speed);") { $0.text(1) ?? "" })
        let required: Set<String> = ["id", "ended", "payload", "model", "tokens", "duration"]
        guard required.isSubset(of: columns) else {
            throw MigrationError.invalidSource
        }
        return Layout(hasMethod: columns.contains("method"))
    }

    private static func scan(
        _ database: SQLiteDatabaseConnection,
        layout: Layout,
        consume: (Row) throws -> Void
    ) throws -> Fingerprint {
        let methodColumn = layout.hasMethod ? "method" : "NULL"
        let methodType = layout.hasMethod ? "typeof(method)" : "'null'"
        let sql = """
        SELECT id,ended,payload,model,tokens,duration,\(methodColumn),
               typeof(id),typeof(ended),typeof(payload),typeof(model),typeof(tokens),typeof(duration),\(methodType)
        FROM api_speed ORDER BY id;
        """
        var hasher = SHA256()
        hasher.update(data: Data("legacy-claude-speed-v1|method=\(layout.hasMethod)\n".utf8))
        var count: Int64 = 0
        try database.forEachRow(sql) { statement in
            let expectedTypes = ["text", nil, "text", "text", "integer", nil]
            for (index, expected) in expectedTypes.enumerated() {
                if let expected {
                    guard statement.text(Int32(7 + index)) == expected else {
                        throw MigrationError.invalidSource
                    }
                } else {
                    guard ["integer", "real"].contains(statement.text(Int32(7 + index)) ?? "") else {
                        throw MigrationError.invalidSource
                    }
                }
            }
            let methodType = statement.text(13) ?? "null"
            guard methodType == "null" || methodType == "text" else {
                throw MigrationError.invalidSource
            }
            guard let idData = statement.data(0), let id = String(data: idData, encoding: .utf8),
                  !id.isEmpty, !id.contains("\0"),
                  let ended = statement.double(1), ended.isFinite,
                  let payload = statement.data(2), String(data: payload, encoding: .utf8) != nil,
                  let modelData = statement.data(3), let model = String(data: modelData, encoding: .utf8),
                  !model.contains("\0"),
                  let tokens = statement.int64(4), tokens >= 0,
                  let duration = statement.double(5), duration.isFinite, duration >= 0 else {
                throw MigrationError.invalidSource
            }
            let method: String?
            if methodType == "null" {
                method = nil
            } else if let bytes = statement.data(6), let value = String(data: bytes, encoding: .utf8),
                      !value.contains("\0") {
                method = value
            } else {
                throw MigrationError.invalidSource
            }
            let row = Row(id: id, ended: ended, payload: payload, model: model,
                          tokens: tokens, duration: duration, method: method)
            hasher.update(data: Data([0x1e]))
            for column in 0..<7 { hasher.update(data: statement.canonicalBytes(Int32(column))) }
            try consume(row)
            let (next, overflow) = count.addingReportingOverflow(1)
            guard !overflow else { throw MigrationError.invalidSource }
            count = next
        }
        var countBits = UInt64(count).bigEndian
        hasher.update(data: withUnsafeBytes(of: &countBits) { Data($0) })
        return Fingerprint(rowCount: count, digest: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func inspectTarget(_ reader: SQLiteDatabaseDriver, sourceIdentity: String) throws -> (userVersion: Int64, receipt: ExistingReceipt?) {
        try reader.withConnection { database in
            try database.execute("PRAGMA query_only=ON;")
            guard try tableExists("client_usage_events", in: database) else { throw MigrationError.invalidTarget }
            try validateDestinationTables(in: database)
            return (try userVersion(in: database), try existingReceipt(in: database, sourceIdentity: sourceIdentity))
        }
    }

    private static func validateDestinationTables(in database: SQLiteDatabaseConnection) throws {
        if try tableExists("legacy_claude_speed", in: database) {
            let columns = try columnInfo("legacy_claude_speed", in: database)
            let expected = ["source_identity", "id", "ended", "payload", "model", "tokens", "duration", "method"]
            guard columns.map(\.name) == expected,
                  columns.filter({ $0.primaryKey > 0 }).sorted(by: { $0.primaryKey < $1.primaryKey }).map(\.name)
                    == ["source_identity", "id"] else {
                throw MigrationError.invalidTarget
            }
        }
        if try tableExists("module_migrations", in: database) {
            let columns = try columnInfo("module_migrations", in: database)
            let expected = ["module", "source_identity", "row_count", "digest", "committed_at"]
            guard columns.map(\.name) == expected,
                  columns.filter({ $0.primaryKey > 0 }).sorted(by: { $0.primaryKey < $1.primaryKey }).map(\.name)
                    == ["module", "source_identity"] else {
                throw MigrationError.invalidTarget
            }
        }
    }

    private static func installTables(in database: SQLiteDatabaseConnection) throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS legacy_claude_speed (
            source_identity TEXT NOT NULL,
            id TEXT NOT NULL,
            ended REAL NOT NULL,
            payload TEXT NOT NULL,
            model TEXT NOT NULL,
            tokens INTEGER NOT NULL,
            duration REAL NOT NULL,
            method TEXT,
            PRIMARY KEY(source_identity,id)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS module_migrations (
            module TEXT NOT NULL,
            source_identity TEXT NOT NULL,
            row_count INTEGER NOT NULL,
            digest TEXT NOT NULL,
            committed_at REAL NOT NULL,
            PRIMARY KEY(module,source_identity)
        ) WITHOUT ROWID;
        """)
        try validateDestinationTables(in: database)
    }

    private static func existingReceipt(
        in database: SQLiteDatabaseConnection,
        sourceIdentity: String
    ) throws -> ExistingReceipt? {
        guard try tableExists("module_migrations", in: database) else { return nil }
        return try database.readRows(
            "SELECT row_count,digest,committed_at FROM module_migrations WHERE module=? AND source_identity=?;",
            bindings: [.text(module), .text(sourceIdentity)]
        ) { row -> ExistingReceipt? in
            guard let rowCount = row.int64(0), rowCount >= 0,
                  let digest = row.text(1), let committedAt = row.double(2), committedAt.isFinite else {
                throw MigrationError.invalidTarget
            }
            return ExistingReceipt(rowCount: rowCount, digest: digest, committedAt: committedAt)
        }.first ?? nil
    }

    private static func tableExists(_ name: String, in database: SQLiteDatabaseConnection) throws -> Bool {
        try database.readRows(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;",
            bindings: [.text(name)]
        ) { $0.int(0) }.first != nil
    }

    private static func columnInfo(_ table: String, in database: SQLiteDatabaseConnection) throws -> [(name: String, primaryKey: Int)] {
        try database.readRows("PRAGMA table_info(\(table));") { ($0.text(1) ?? "", $0.int(5) ?? 0) }
    }

    private static func userVersion(in database: SQLiteDatabaseConnection) throws -> Int64 { try database.readRows("PRAGMA user_version;") { $0.int64(0) ?? -1 }.first ?? -1 }

    private static func backupTarget(_ target: URL, expectedUserVersion: Int64) throws -> URL {
        let folder = target.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let backup = folder.appendingPathComponent(
            "multi-client-usage-legacy-claude-speed-\(UUID().uuidString).sqlite"
        )
        do {
            let writer = SQLiteDatabaseDriver(url: target, createsFileIfMissing: false, busyTimeoutMilliseconds: 5_000)
            try writer.execute("VACUUM INTO ?;", bindings: [.text(backup.path)])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            let reader = SQLiteDatabaseDriver(url: backup, readOnly: true, createsFileIfMissing: false)
            let integrity = try reader.readRows("PRAGMA integrity_check;") { $0.text(0) }.first ?? nil
            let version = try reader.readRows("PRAGMA user_version;") { $0.int64(0) ?? -1 }.first ?? -1
            guard integrity == "ok", version == expectedUserVersion else {
                throw MigrationError.invalidTarget
            }
            return backup
        } catch {
            try? FileManager.default.removeItem(at: backup)
            throw error
        }
    }

    private static func sourceIdentity(for source: URL) -> String {
        SHA256.hash(data: Data(source.standardizedFileURL.resolvingSymlinksInPath().path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
