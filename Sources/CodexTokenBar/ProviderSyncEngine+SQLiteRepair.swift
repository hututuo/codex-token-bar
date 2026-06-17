import Foundation

extension ProviderSyncEngine {
    func readSQLiteProviders(codexHome: URL) throws -> [ProviderSyncSQLiteProvider] {
        let db = codexHome.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: db.path) else { return [] }
        return try withDatabase(path: db.path, readOnly: true) { database in
            guard let columns = try readThreadsTableColumns(database: database),
                  columns.modelProvider else {
                return []
            }
            let archivedExpression = columns.archived ? "archived" : "0"
            return try queryRows(
                database: database,
                sql: """
                SELECT model_provider, \(archivedExpression), COUNT(*)
                FROM threads
                GROUP BY model_provider, \(archivedExpression)
                ORDER BY \(archivedExpression) ASC, COUNT(*) DESC;
                """
            ) { statement in
                ProviderSyncSQLiteProvider(
                    provider: sqliteText(statement, 0) ?? "(missing)",
                    archived: Int(sqliteInt64(statement, 1)),
                    count: Int(sqliteInt64(statement, 2))
                )
            }
        }
    }

    func latestSQLiteProvider(codexHome: URL) throws -> (provider: String?, threadID: String?) {
        let db = codexHome.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: db.path) else { return (nil, nil) }
        return try withDatabase(path: db.path, readOnly: true) { database in
            guard let columns = try readThreadsTableColumns(database: database) else {
                return (nil, nil)
            }
            let providerExpression = columns.modelProvider ? "model_provider" : "NULL"
            let archivedFilter = columns.archived ? "WHERE archived = 0" : ""
            let updatedExpression = sqliteUpdatedAtMillisecondsExpression(columns: columns)
            return try queryRows(
                database: database,
                sql: """
                SELECT \(providerExpression), id
                FROM threads
                \(archivedFilter)
                ORDER BY \(updatedExpression) DESC
                LIMIT 1;
                """
            ) { statement in
                (sqliteText(statement, 0), sqliteText(statement, 1))
            }.first ?? (nil, nil)
        }
    }

    func updateSQLite(codexHome: URL, targetProvider: String) throws -> Int {
        let db = codexHome.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: db.path) else { return 0 }
        return try withDatabase(path: db.path, readOnly: false) { database in
            try execute(database: database, sql: "PRAGMA busy_timeout = 3000;")
            guard let columns = try readThreadsTableColumns(database: database),
                  let whereClause = threadsRepairWhereClause(columns: columns),
                  let setClause = threadsRepairSetClause(columns: columns) else {
                return 0
            }

            let values = columns.modelProvider ? [targetProvider] : []
            try execute(database: database, sql: "BEGIN IMMEDIATE TRANSACTION;")
            let changed: Int
            do {
                changed = try executeBoundUpdate(
                    database: database,
                    sql: "UPDATE threads SET \(setClause) WHERE \(whereClause);",
                    values: values
                )
                try execute(database: database, sql: "COMMIT;")
            } catch {
                try? execute(database: database, sql: "ROLLBACK;")
                throw error
            }
            try execute(database: database, sql: "PRAGMA wal_checkpoint(FULL);")
            return changed
        }
    }

    func countSQLiteRowsToRepair(codexHome: URL, targetProvider: String) throws -> Int {
        let db = codexHome.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: db.path) else { return 0 }
        return try withDatabase(path: db.path, readOnly: true) { database in
            guard let columns = try readThreadsTableColumns(database: database),
                  let whereClause = threadsRepairWhereClause(columns: columns) else {
                return 0
            }
            let values = columns.modelProvider ? [targetProvider] : []
            return try queryBoundRows(
                database: database,
                sql: "SELECT COUNT(*) FROM threads WHERE \(whereClause);",
                values: values
            ) { statement in
                Int(sqliteInt64(statement, 0))
            }.first ?? 0
        }
    }

    func repairSQLiteThreadTimestamps(codexHome: URL, sessionFiles: [URL]) throws -> Int {
        var timestampsByID: [String: ProviderSyncSessionTimestamp] = [:]
        for timestamp in try sessionFiles.compactMap({ try readSessionTimestamp(file: $0) }) {
            if let current = timestampsByID[timestamp.id],
               current.updatedAtMilliseconds >= timestamp.updatedAtMilliseconds {
                continue
            }
            timestampsByID[timestamp.id] = timestamp
        }
        guard !timestampsByID.isEmpty else { return 0 }

        let db = codexHome.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: db.path) else { return 0 }
        return try withDatabase(path: db.path, readOnly: false) { database in
            try execute(database: database, sql: "PRAGMA busy_timeout = 3000;")
            guard let columns = try readThreadsTableColumns(database: database),
                  columns.updatedAt || columns.updatedAtMilliseconds else {
                return 0
            }

            let rows = try readSQLiteThreadTimestampRows(database: database, columns: columns)
            let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let collisionGroups = Dictionary(grouping: rows) { $0.updatedAtMilliseconds / 1_000 }
                .filter { second, rows in second > 0 && rows.count >= 4 }
            guard !collisionGroups.isEmpty else { return 0 }

            var repairTargets: [ProviderSyncSessionTimestamp] = []
            for (second, group) in collisionGroups {
                let sorted = group.sorted { lhs, rhs in
                    let lhsActual = timestampsByID[lhs.id]?.updatedAtMilliseconds ?? lhs.updatedAtMilliseconds
                    let rhsActual = timestampsByID[rhs.id]?.updatedAtMilliseconds ?? rhs.updatedAtMilliseconds
                    if lhsActual != rhsActual {
                        return lhsActual > rhsActual
                    }
                    return lhs.id < rhs.id
                }

                for (offset, row) in sorted.enumerated() {
                    guard let timestamp = timestampsByID[row.id] else { continue }
                    let target = (second - Int64(offset)) * 1_000
                    repairTargets.append(ProviderSyncSessionTimestamp(
                        id: row.id,
                        updatedAtMilliseconds: target,
                        fileURL: timestamp.fileURL
                    ))
                }
            }

            try execute(database: database, sql: "BEGIN IMMEDIATE TRANSACTION;")
            var changed = 0
            do {
                for timestamp in repairTargets {
                    changed += try executeTimestampUpdate(database: database, columns: columns, timestamp: timestamp)
                }
                try execute(database: database, sql: "COMMIT;")
            } catch {
                try? execute(database: database, sql: "ROLLBACK;")
                throw error
            }
            try execute(database: database, sql: "PRAGMA wal_checkpoint(FULL);")
            changed += try repairSessionFileModificationDates(
                sessionTimestamps: Array(timestampsByID.values),
                rowsByID: rowsByID,
                repairTargets: repairTargets,
                collisionSeconds: Set(collisionGroups.keys)
            )
            return changed
        }
    }
}
