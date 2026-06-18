import Foundation

enum CodexUnreadThreadReader {
    private static let stateDatabaseCache = StateDatabaseCache()

    static func readUnreadThreadIDs(codexHome: URL) -> CodexUnreadThreadReadResult {
        let url = codexHome.appendingPathComponent(".codex-global-state.json")
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unavailable
        }
        guard let unreadState = unreadStateValue(in: object) else {
            return .available([])
        }
        let threadIDs = collectThreadIDs(from: unreadState)
        return .available(visibleUserThreadIDs(from: threadIDs, codexHome: codexHome))
    }

    private static func unreadStateValue(in object: [String: Any]) -> Any? {
        if let persistedState = object["electron-persisted-atom-state"] as? [String: Any],
           let value = persistedState["unread-thread-ids-by-host-v1"] {
            return value
        }
        return object["unread-thread-ids-by-host-v1"]
    }

    private static func collectThreadIDs(from value: Any) -> Set<String> {
        var threadIDs = Set<String>()
        if let string = value as? String {
            if looksLikeThreadID(string) {
                threadIDs.insert(string)
            }
            return threadIDs
        }
        if let strings = value as? [String] {
            threadIDs.formUnion(strings.filter(looksLikeThreadID))
            return threadIDs
        }
        if let array = value as? [Any] {
            for item in array {
                threadIDs.formUnion(collectThreadIDs(from: item))
            }
            return threadIDs
        }
        if let dictionary = value as? [String: Any] {
            for item in dictionary.values {
                threadIDs.formUnion(collectThreadIDs(from: item))
            }
        }
        return threadIDs
    }

    private static func looksLikeThreadID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 24 && trimmed.contains("-")
    }

    private static func visibleUserThreadIDs(from threadIDs: Set<String>, codexHome: URL) -> Set<String> {
        guard !threadIDs.isEmpty else { return [] }
        let databaseURL = codexHome.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return visibleOrUnresolvedThreadIDs(from: threadIDs, codexHome: codexHome)
        }

        do {
            return try stateDatabaseCache.read(databaseURL: databaseURL) { database, columns in
                try visibleUserThreadIDs(
                    from: threadIDs,
                    database: database,
                    columns: columns,
                    codexHome: codexHome
                )
            }
        } catch {
            return sessionVisibleThreadIDs(from: threadIDs, codexHome: codexHome).visibleIDs
        }
    }

    private static func visibleUserThreadIDs(
        from threadIDs: Set<String>,
        database: SQLiteDatabaseConnection,
        columns: Set<String>,
        codexHome: URL
    ) throws -> Set<String> {
        let archivedExpression = columns.contains("archived") ? "COALESCE(archived, 0)" : "0"
        let threadSourceExpression = columns.contains("thread_source") ? "COALESCE(thread_source, 'user')" : "'user'"
        let sourceExpression = columns.contains("source") ? "COALESCE(source, '')" : "''"
        let previewExpression = columns.contains("preview") ? "COALESCE(preview, '')" : "'legacy'"
        let sortedThreadIDs = threadIDs.sorted()
        let placeholders = Array(repeating: "?", count: sortedThreadIDs.count).joined(separator: ",")
        let sql = """
        SELECT id, \(archivedExpression), \(threadSourceExpression), \(sourceExpression), \(previewExpression)
        FROM threads
        WHERE id IN (\(placeholders))
        """

        let rows = try database.readRows(sql, bindings: sortedThreadIDs.map(SQLiteBinding.text)) { statement in
            (
                id: statement.text(0) ?? "",
                archived: (statement.int(1) ?? 0) != 0,
                threadSource: statement.text(2) ?? "user",
                source: statement.text(3) ?? "",
                preview: statement.text(4) ?? ""
            )
        }
        var visibleIDs = Set<String>()
        var matchedIDs = Set<String>()

        for row in rows where !row.id.isEmpty {
            matchedIDs.insert(row.id)
            if !row.archived,
               !row.preview.isEmpty,
               !row.threadSource.localizedCaseInsensitiveContains("subagent"),
               !row.source.localizedCaseInsensitiveContains("subagent") {
                visibleIDs.insert(row.id)
            }
        }

        let unresolvedIDs = threadIDs.subtracting(matchedIDs)
        if !unresolvedIDs.isEmpty {
            let sessionVisibility = sessionVisibleThreadIDs(from: unresolvedIDs, codexHome: codexHome)
            visibleIDs.formUnion(sessionVisibility.visibleIDs)
            visibleIDs.formUnion(unresolvedIDs.subtracting(sessionVisibility.foundIDs))
        }
        return visibleIDs
    }

    private struct SessionVisibility {
        var visibleIDs = Set<String>()
        var foundIDs = Set<String>()
    }

    private final class StateDatabaseCache: @unchecked Sendable {
        private struct Entry {
            let signature: DatabaseSignature
            let reader: SQLitePersistentDatabaseReader
            var columns: Set<String>?
        }

        private struct DatabaseSignature: Equatable {
            let size: UInt64
            let modifiedAt: TimeInterval

            init(url: URL) {
                let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
                size = attributes[.size] as? UInt64 ?? 0
                modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            }
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func read<T>(
            databaseURL: URL,
            body: (SQLiteDatabaseConnection, Set<String>) throws -> T
        ) throws -> T {
            let reader = reader(for: databaseURL)
            return try reader.withConnection { database in
                let columns = try columns(for: databaseURL, database: database)
                return try body(database, columns)
            }
        }

        private func reader(for databaseURL: URL) -> SQLitePersistentDatabaseReader {
            let path = databaseURL.path
            let signature = DatabaseSignature(url: databaseURL)

            lock.lock()
            defer { lock.unlock() }

            if let entry = entries[path], entry.signature == signature {
                return entry.reader
            }

            let reader = SQLitePersistentDatabaseReader(
                url: databaseURL,
                busyTimeoutMilliseconds: 3_000
            )
            entries[path] = Entry(signature: signature, reader: reader, columns: nil)
            return reader
        }

        private func columns(for databaseURL: URL, database: SQLiteDatabaseConnection) throws -> Set<String> {
            let path = databaseURL.path
            let signature = DatabaseSignature(url: databaseURL)

            lock.lock()
            if let entry = entries[path], entry.signature == signature, let columns = entry.columns {
                lock.unlock()
                return columns
            }
            lock.unlock()

            let columnNames = try database.readRows("PRAGMA table_info(threads)") { statement in
                statement.text(1) ?? ""
            }
            let columns = Set(columnNames.filter { !$0.isEmpty })

            lock.lock()
            if var entry = entries[path], entry.signature == signature {
                entry.columns = columns
                entries[path] = entry
            }
            lock.unlock()

            return columns
        }
    }

    private static func sessionVisibleThreadIDs(from threadIDs: Set<String>, codexHome: URL) -> SessionVisibility {
        var visibility = SessionVisibility()
        guard !threadIDs.isEmpty else { return visibility }

        let liveSessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        scanSessionMetas(under: liveSessions, archived: false, threadIDs: threadIDs, visibility: &visibility)

        let archivedSessions = codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        scanSessionMetas(under: archivedSessions, archived: true, threadIDs: threadIDs, visibility: &visibility)
        return visibility
    }

    private static func visibleOrUnresolvedThreadIDs(from threadIDs: Set<String>, codexHome: URL) -> Set<String> {
        let sessionVisibility = sessionVisibleThreadIDs(from: threadIDs, codexHome: codexHome)
        return sessionVisibility.visibleIDs.union(threadIDs.subtracting(sessionVisibility.foundIDs))
    }

    private static func scanSessionMetas(
        under root: URL,
        archived: Bool,
        threadIDs: Set<String>,
        visibility: inout SessionVisibility
    ) {
        guard visibility.foundIDs.count < threadIDs.count,
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        for item in enumerator {
            guard visibility.foundIDs.count < threadIDs.count,
                  let file = item as? URL,
                  file.pathExtension == "jsonl",
                  let payload = sessionMetaPayload(in: file),
                  let id = payload["id"] as? String,
                  threadIDs.contains(id) else {
                continue
            }

            visibility.foundIDs.insert(id)
            let threadSource = payload["thread_source"] as? String ?? ""
            let isSubagent = threadSource.localizedCaseInsensitiveContains("subagent")
                || valueContainsSubagent(payload["source"])
            if !archived && !isSubagent {
                visibility.visibleIDs.insert(id)
            }
        }
    }

    private static func sessionMetaPayload(in file: URL) -> [String: Any]? {
        guard let firstLine = firstLine(in: file),
              let data = firstLine.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["type"] as? String == "session_meta" else {
            return nil
        }
        return object["payload"] as? [String: Any]
    }

    private static func firstLine(in file: URL, maxBytes: Int = 262_144) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var data = Data()
        let newline = UInt8(ascii: "\n")
        while data.count < maxBytes {
            let chunk = handle.readData(ofLength: min(16_384, maxBytes - data.count))
            if chunk.isEmpty { break }
            if let newlineIndex = chunk.firstIndex(of: newline) {
                data.append(chunk[..<newlineIndex])
                break
            }
            data.append(chunk)
        }
        guard !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func valueContainsSubagent(_ value: Any?) -> Bool {
        if let string = value as? String {
            return string.localizedCaseInsensitiveContains("subagent")
        }
        if let array = value as? [Any] {
            return array.contains(where: valueContainsSubagent)
        }
        if let dictionary = value as? [String: Any] {
            if dictionary.keys.contains(where: { $0.localizedCaseInsensitiveContains("subagent") }) {
                return true
            }
            return dictionary.values.contains(where: valueContainsSubagent)
        }
        return false
    }
}
