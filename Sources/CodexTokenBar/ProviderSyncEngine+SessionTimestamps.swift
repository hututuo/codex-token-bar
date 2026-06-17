import Foundation

extension ProviderSyncEngine {
    func readSessionTimestamp(file: URL) throws -> ProviderSyncSessionTimestamp? {
        let text = try String(contentsOf: file, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).makeIterator()
        guard let firstLine = lines.next(),
              let firstData = String(firstLine).data(using: .utf8),
              let firstObject = try? JSONSerialization.jsonObject(with: firstData) as? [String: Any],
              firstObject["type"] as? String == "session_meta",
              let payload = firstObject["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              !id.isEmpty else {
            return nil
        }

        var latest = eventTimestampMilliseconds(firstObject) ?? 0
        for line in lines {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = eventTimestampMilliseconds(object) else {
                continue
            }
            latest = max(latest, timestamp)
        }

        return latest > 0 ? ProviderSyncSessionTimestamp(id: id, updatedAtMilliseconds: latest, fileURL: file) : nil
    }

    func readSQLiteThreadTimestampRows(
        database: SQLiteDatabaseConnection,
        columns: ProviderSyncSQLiteThreadColumns
    ) throws -> [ProviderSyncThreadTimestampRow] {
        let updatedExpression = sqliteUpdatedAtMillisecondsExpression(columns: columns)
        return try queryRows(
            database: database,
            sql: """
            SELECT id, \(updatedExpression)
            FROM threads
            WHERE COALESCE(id, '') <> '';
            """
        ) { statement in
            ProviderSyncThreadTimestampRow(
                id: sqliteText(statement, 0) ?? "",
                updatedAtMilliseconds: sqliteInt64(statement, 1)
            )
        }.filter { !$0.id.isEmpty }
    }

    func repairSessionFileModificationDates(
        sessionTimestamps: [ProviderSyncSessionTimestamp],
        rowsByID: [String: ProviderSyncThreadTimestampRow],
        repairTargets: [ProviderSyncSessionTimestamp],
        collisionSeconds: Set<Int64>
    ) throws -> Int {
        let targetByID = Dictionary(uniqueKeysWithValues: repairTargets.map { ($0.id, $0.updatedAtMilliseconds) })
        var changed = 0
        for timestamp in sessionTimestamps {
            let attributes = try fileManager.attributesOfItem(atPath: timestamp.fileURL.path)
            guard let modificationDate = attributes[.modificationDate] as? Date else { continue }

            let currentMilliseconds = Int64(modificationDate.timeIntervalSince1970 * 1_000)
            let currentSecond = currentMilliseconds / 1_000
            var targetMilliseconds = targetByID[timestamp.id]
            if targetMilliseconds == nil,
               isCollisionSecond(currentSecond, collisionSeconds: collisionSeconds),
               let row = rowsByID[timestamp.id] {
                targetMilliseconds = row.updatedAtMilliseconds
            }

            guard let targetMilliseconds,
                  abs(currentMilliseconds - targetMilliseconds) >= 500 else {
                continue
            }

            try fileManager.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(targetMilliseconds) / 1_000)],
                ofItemAtPath: timestamp.fileURL.path
            )
            changed += 1
        }
        return changed
    }

    func isCollisionSecond(_ second: Int64, collisionSeconds: Set<Int64>) -> Bool {
        collisionSeconds.contains(second)
            || collisionSeconds.contains(second - 1)
            || collisionSeconds.contains(second + 1)
    }

    func eventTimestampMilliseconds(_ object: [String: Any]) -> Int64? {
        let keys = ["timestamp", "time", "created_at", "updated_at", "createdAt", "updatedAt"]
        for key in keys {
            if let milliseconds = timestampMilliseconds(from: object[key]) {
                return milliseconds
            }
        }
        if let payload = object["payload"] as? [String: Any] {
            for key in keys {
                if let milliseconds = timestampMilliseconds(from: payload[key]) {
                    return milliseconds
                }
            }
        }
        return nil
    }

    func timestampMilliseconds(from value: Any?) -> Int64? {
        if let value = value as? String {
            let parsed = parseISO8601Milliseconds(value)
            return parsed > 0 ? parsed : nil
        }
        if let value = value as? Int64 {
            return normalizeTimestampMilliseconds(value)
        }
        if let value = value as? Int {
            return normalizeTimestampMilliseconds(Int64(value))
        }
        if let value = value as? Double, value.isFinite {
            return normalizeTimestampMilliseconds(Int64(value))
        }
        return nil
    }

    func normalizeTimestampMilliseconds(_ value: Int64) -> Int64? {
        guard value > 0 else { return nil }
        if value > 10_000_000_000_000 {
            return value / 1_000
        }
        if value > 10_000_000_000 {
            return value
        }
        return value * 1_000
    }
}
