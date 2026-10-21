import Foundation

/// Detail metadata only. Speed history is the retained numeric sample store;
/// opening details never reads, decompresses or replays a Codex rollout.
actor BodySpeedHistoryReader {
    func titles(stateDB: URL) throws -> [String: String] {
        try CodexStateDatabaseReadPool.shared.withConnection(url: stateDB) { connection in
            try connection.readTransaction { snapshot in
                let columns = Set(try snapshot.readRows("PRAGMA table_info(threads)") { $0.text(1) ?? "" })
                let name = columns.contains("name") ? "NULLIF(TRIM(name), '')" : "NULL"
                let rows = try snapshot.readRows("SELECT id, COALESCE(\(name), title, '') FROM threads") { ($0.text(0) ?? "", $0.text(1) ?? "") }
                return Dictionary(rows, uniquingKeysWith: { _, latest in latest })
            }
        }
    }
}
