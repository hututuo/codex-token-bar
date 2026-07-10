import Foundation

extension ProviderSyncEngine {
    func readSQLiteProviders(
        homeDirectory: ProviderSyncHomeDirectory
    ) throws -> [ProviderSyncSQLiteProvider] {
        try withBoundDatabase(homeDirectory: homeDirectory, readOnly: true) { database, _ in
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
        } ?? []
    }

    func latestSQLiteProvider(
        homeDirectory: ProviderSyncHomeDirectory
    ) throws -> (provider: String?, threadID: String?) {
        try withBoundDatabase(homeDirectory: homeDirectory, readOnly: true) { database, _ in
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
        } ?? (nil, nil)
    }

    func updateSQLite(
        homeDirectory: ProviderSyncHomeDirectory,
        targetProvider: String
    ) throws -> Int {
        let changed = try withBoundDatabase(
            homeDirectory: homeDirectory,
            readOnly: false,
            willOpen: sqliteProviderWillOpen
        ) { database, bound in
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
                try homeDirectory.verifyBoundFile(bound)
                changed = try executeBoundUpdate(
                    database: database,
                    sql: "UPDATE threads SET \(setClause) WHERE \(whereClause);",
                    values: values
                )
                try homeDirectory.verifyBoundFile(bound)
                try execute(database: database, sql: "COMMIT;")
            } catch {
                try? execute(database: database, sql: "ROLLBACK;")
                throw error
            }
            try homeDirectory.verifyBoundFile(bound)
            try execute(database: database, sql: "PRAGMA wal_checkpoint(FULL);")
            try homeDirectory.verifyBoundFile(bound)
            return changed
        }
        return changed ?? 0
    }

    func countSQLiteRowsToRepair(
        homeDirectory: ProviderSyncHomeDirectory,
        targetProvider: String
    ) throws -> Int {
        try withBoundDatabase(homeDirectory: homeDirectory, readOnly: true) { database, _ in
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
        } ?? 0
    }

    func repairSQLiteThreadTimestamps(
        sessionMutations: [ProviderSyncPreparedSessionMutation],
        homeDirectory: ProviderSyncHomeDirectory
    ) throws -> Int {
        var timestampsByID: [String: ProviderSyncBoundSessionTimestamp] = [:]
        for mutation in sessionMutations {
            let snapshot = try homeDirectory.readRegularFile(
                mutation.file,
                expectedIdentity: mutation.currentIdentity,
                requireSingleLink: true
            )
            guard providerSyncSHA256Hex(snapshot.data) == providerSyncSHA256Hex(mutation.expectedData) else {
                throw providerSyncDescriptorError(
                    "session 时间戳读取前内容发生变化：\(mutation.file.displayURL.path)"
                )
            }
            guard let timestamp = try readSessionTimestamp(
                data: snapshot.data,
                fileURL: mutation.file.displayURL
            ) else {
                continue
            }
            let boundTimestamp = ProviderSyncBoundSessionTimestamp(
                timestamp: timestamp,
                mutation: mutation
            )
            if let current = timestampsByID[timestamp.id],
               current.timestamp.updatedAtMilliseconds >= timestamp.updatedAtMilliseconds {
                continue
            }
            timestampsByID[timestamp.id] = boundTimestamp
        }
        guard !timestampsByID.isEmpty else { return 0 }

        let changed = try withBoundDatabase(
            homeDirectory: homeDirectory,
            readOnly: false,
            willOpen: sqliteTimestampWillOpen
        ) { database, bound in
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
                    let lhsActual = timestampsByID[lhs.id]?.timestamp.updatedAtMilliseconds ?? lhs.updatedAtMilliseconds
                    let rhsActual = timestampsByID[rhs.id]?.timestamp.updatedAtMilliseconds ?? rhs.updatedAtMilliseconds
                    if lhsActual != rhsActual {
                        return lhsActual > rhsActual
                    }
                    return lhs.id < rhs.id
                }

                for (offset, row) in sorted.enumerated() {
                    guard let boundTimestamp = timestampsByID[row.id] else { continue }
                    let target = (second - Int64(offset)) * 1_000
                    repairTargets.append(ProviderSyncSessionTimestamp(
                        id: row.id,
                        updatedAtMilliseconds: target,
                        fileURL: boundTimestamp.timestamp.fileURL
                    ))
                }
            }

            try execute(database: database, sql: "BEGIN IMMEDIATE TRANSACTION;")
            var changed = 0
            do {
                try homeDirectory.verifyBoundFile(bound)
                for timestamp in repairTargets {
                    changed += try executeTimestampUpdate(database: database, columns: columns, timestamp: timestamp)
                }
                try homeDirectory.verifyBoundFile(bound)
                try execute(database: database, sql: "COMMIT;")
            } catch {
                try? execute(database: database, sql: "ROLLBACK;")
                throw error
            }
            try homeDirectory.verifyBoundFile(bound)
            try execute(database: database, sql: "PRAGMA wal_checkpoint(FULL);")
            try homeDirectory.verifyBoundFile(bound)
            changed += try repairSessionFileModificationDates(
                sessionTimestamps: Array(timestampsByID.values),
                rowsByID: rowsByID,
                repairTargets: repairTargets,
                collisionSeconds: Set(collisionGroups.keys),
                homeDirectory: homeDirectory
            )
            return changed
        }
        return changed ?? 0
    }
}
