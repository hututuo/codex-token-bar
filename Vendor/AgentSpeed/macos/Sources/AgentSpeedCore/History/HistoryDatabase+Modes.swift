import Foundation

extension HistoryDatabase {
    static let modeTableSQL = """
        CREATE TABLE IF NOT EXISTS contribution_modes (
            file_id INTEGER NOT NULL,
            day TEXT NOT NULL,
            source TEXT NOT NULL,
            body BLOB NOT NULL,
            PRIMARY KEY(file_id, day, source)
        ) WITHOUT ROWID;
        """

    func loadModes(into entries: inout [String: Entry], paths: [Int64: String]) throws {
        let statement = try connection.prepare("SELECT file_id,day,source,body FROM contribution_modes WHERE length(body) <= 4194304")
        try statement.forEachRow { row in
            guard let path = paths[row.int64(0)], let day = row.string(1),
                  let source = row.string(2).flatMap(SourceKind.init(rawValue:)),
                  let modes = row.withBlob(3, { try? JSONDecoder().decode([ExecutionModeUsage].self, from: Data($0)) }),
                  modes.count <= 100_000 else { return }
            let key = UsageKey(day: day, source: source)
            for usage in modes where usage.requests >= 0 && usage.output >= 0 && usage.measuredOutput >= 0 && usage.measuredMs >= 0 {
                let attribution = usage.attribution
                guard ExecutionModeFact.isIdentifier(attribution.mode, limit: 64),
                      ["served", "recorded", "selected"].contains(attribution.evidence),
                      attribution.provider.map({ ExecutionModeFact.isIdentifier($0, limit: 32) }) ?? true else { continue }
                entries[path]?.days[key]?.modes[ExecutionModeUsageKey(model: usage.model, attribution: attribution)] = usage
            }
        }
    }

    func deleteModes(fileId: Int64) throws {
        let statement = try connection.prepare("DELETE FROM contribution_modes WHERE file_id=?1")
        statement.bind(1, fileId)
        try statement.run()
    }

    func saveModes(_ modes: [ExecutionModeUsage], fileId: Int64, day: String, source: SourceKind) throws {
        guard !modes.isEmpty else { return }
        let bytes = try JSONEncoder().encode(modes)
        guard bytes.count <= 4_194_304 else { return }
        let statement = try connection.prepare("INSERT INTO contribution_modes(file_id,day,source,body) VALUES (?1,?2,?3,?4)")
        statement.bind(1, fileId)
        statement.bind(2, day)
        statement.bind(3, source.rawValue)
        bytes.withUnsafeBytes { statement.bind(4, blob: $0) }
        try statement.run()
    }
}
