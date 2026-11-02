import Foundation

/// A late import is an operation, not a second bootstrap. Its durable record
/// names the already-published owners; newly imported partitions stay hidden
/// until the original migration verification commits. No facts are copied or
/// replaced by this admission record.
enum PublishedBusinessAdmission {
    static let key = "published_ledger_admission_v1"
    private struct Owner: Codable {
        let path: String
        let module: String
        let source: String
        let id: String
        init(_ store: BusinessSQLiteStore) {
            path = store.logicalURL.path; module = store.module
            source = store.sourceIdentity; id = store.id
        }
        func store(in container: URL) throws -> BusinessSQLiteStore {
            let value = BusinessSQLiteStore(containerURL: container, logicalURL: URL(fileURLWithPath: path), module: module, sourceIdentity: source)
            guard value.id == id else { throw BusinessStoreError.invalidStore }
            return value
        }
    }
    private struct Record: Codable {
        let version: Int
        let initializedMarker: String
        let published: [Owner]
        let pending: [String: String]
        let allWritersPaused: Bool?
    }
    struct Deferred: LocalizedError {
        let message: String
        var canRetryAutomatically = false
        var errorDescription: String? { message }
    }

    static func install(configuration: BusinessDatabaseMigration.Configuration,
                        database: CodexBusinessDatabase, pending: [String: String],
                        activation: String?, blocksAllWriters: Bool = false) throws -> Bool {
        try database.driver.withOperationConnection {
            try installOnCurrentConnection(configuration: configuration, database: database,
                pending: pending, activation: activation, blocksAllWriters: blocksAllWriters)
        }
    }

    private static func installOnCurrentConnection(configuration: BusinessDatabaseMigration.Configuration,
                        database: CodexBusinessDatabase, pending: [String: String],
                        activation: String?, blocksAllWriters: Bool) throws -> Bool {
        let marker = configuration.container.appendingPathExtension("initialized")
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        guard try FileManager.default.attributesOfItem(atPath: marker.path)[.type] as? FileAttributeType == .typeRegular,
              try Data(contentsOf: marker) == Data("tokenbar-codex-ledger-v1\n".utf8) else {
            throw BusinessDatabaseMigration.Failure.unsafeInput(marker.path)
        }
        guard activation == "ready" || (activation == "importing" && !pending.isEmpty) else { return false }
        let current = try database.driver.readRows("SELECT logical_path,module,source_identity FROM tb_stores WHERE state IN ('ready','sealed')") {
            BusinessSQLiteStore(containerURL: configuration.container,
                logicalURL: URL(fileURLWithPath: $0.text(0) ?? ""), module: $0.text(1) ?? "", sourceIdentity: $0.text(2) ?? "")
        }
        let raw = try database.driver.readRows("SELECT value FROM tb_container_meta WHERE key=?", bindings: [.text(key)]) { $0.text(0) }.first ?? nil
        let previous: Record?
        if let raw {
            let value = try JSONDecoder().decode(Record.self, from: Data(raw.utf8))
            guard value.version == 1, value.initializedMarker == "tokenbar-codex-ledger-v1" else { throw BusinessStoreError.invalidStore }
            for owner in value.published { _ = try owner.store(in: configuration.container) }
            previous = value
        } else { previous = nil }
        // A released older importer had a global importing flag plus a batch
        // journal. With its completed initialized marker, owners outside that
        // batch are the prior committed partitions; pending ones remain closed.
        let pendingIDs = Set(pending.values)
        let oldIDs = previous.map { Set($0.published.map(\.id)) }
            ?? Set(current.filter { activation == "ready" || !pendingIDs.contains($0.id) }.map(\.id))
        let published = current.filter { oldIDs.contains($0.id) || !pendingIDs.contains($0.id) }
        guard !published.isEmpty else { return false }
        for old in previous?.published ?? [] {
            if let actual = current.first(where: { $0.id == old.id }) {
                guard actual == (try old.store(in: configuration.container)) else { throw BusinessStoreError.invalidStore }
            }
        }
        let record = Record(version: 1, initializedMarker: "tokenbar-codex-ledger-v1",
            published: published.map(Owner.init), pending: pending, allWritersPaused: blocksAllWriters)
        let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        let batch = String(decoding: try JSONEncoder().encode(pending), as: UTF8.self)
        try database.driver.transaction { tx in
            try tx.execute("INSERT OR REPLACE INTO tb_container_meta VALUES (?,?)", bindings: [.text(key), .text(encoded)])
            if !pending.isEmpty { try tx.execute("INSERT OR REPLACE INTO tb_container_meta VALUES ('migration_pending_sources_v1',?)", bindings: [.text(batch)]) }
            try tx.execute("INSERT OR REPLACE INTO tb_container_meta VALUES ('activation_state','ready')")
        }
        try BusinessDatabaseMigration.activateRoutes(configuration, database: database,
            blockedReads: pendingIDs.subtracting(published.map(\.id)), blockedWrites: pendingIDs,
            publishedAdmission: true, blocksAllWriters: blocksAllWriters)
        return true
    }
}
