import Foundation

/// Shared A maintenance, once per interval across all module partitions. Old
/// per-module VACUUM calls cannot independently rewrite the same container.
enum BusinessDatabaseMaintenance {
    private static let lock = NSLock()
    static func run(container: URL, now: Date = Date(),
                    policy: CodexUsageIndexStorageMaintenancePolicy = .standard,
                    availableCapacity: UInt64? = nil) throws -> CodexUsageIndexStorageMaintenanceOutcome {
        guard lock.try() else { return .notDue }
        defer { lock.unlock() }
        let driver = SQLiteDatabaseDriver(url: container, createsFileIfMissing: false,
            busyTimeoutMilliseconds: 3_000, bypassBusinessRoutes: true)
        return try driver.withConnection { db in
            let last = try db.readRows("SELECT value FROM tb_container_meta WHERE key='maintenance_checked_at'") { $0.text(0).flatMap(Double.init) }.first ?? nil
            if let last, now.timeIntervalSince1970 - last < policy.minimumCheckInterval { return .notDue }
            func metric(_ name: String) throws -> UInt64 {
                guard let value = try db.readRows("PRAGMA \(name)", map: { $0.int64(0) }).first ?? nil,
                      value >= 0 else { throw BusinessStoreError.proofMismatch }
                return UInt64(value)
            }
            func record() throws {
                try db.execute("INSERT OR REPLACE INTO tb_container_meta VALUES('maintenance_checked_at',?)", bindings: [.text(String(now.timeIntervalSince1970))])
            }
            guard try metric("auto_vacuum") == 2 else {
                // A legacy container without pointer maps can reuse free pages.
                // Enabling incremental mode with full VACUUM would renumber
                // hidden row IDs, so it requires an explicit future migration.
                try record()
                return .notDue
            }
            let size = try metric("page_size"), pages = try metric("page_count"), free = try metric("freelist_count")
            let bytes = size.multipliedReportingOverflow(by: pages), freeBytes = size.multipliedReportingOverflow(by: free)
            guard !bytes.overflow, !freeBytes.overflow else { throw BusinessStoreError.proofMismatch }
            let ratio = pages > 0 ? Double(free) / Double(pages) * 100 : 0
            guard freeBytes.partialValue >= policy.minimumFreeBytes,
                  ratio >= Double(policy.minimumFreePercent) || freeBytes.partialValue >= policy.absoluteFreeBytes else {
                try record()
                return .belowThreshold(databaseBytes: bytes.partialValue, freeBytes: freeBytes.partialValue)
            }
            let scaled = bytes.partialValue.multipliedReportingOverflow(by: 2)
            let required = scaled.partialValue.addingReportingOverflow(policy.diskReserveBytes)
            guard !scaled.overflow, !required.overflow else { throw BusinessStoreError.proofMismatch }
            let available = try availableCapacity ?? container.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage.map(UInt64.init) ?? 0
            guard available >= required.partialValue else {
                try record()
                return .insufficientSpace(databaseBytes: bytes.partialValue, freeBytes: freeBytes.partialValue,
                    availableBytes: available, requiredBytes: required.partialValue)
            }
            // SQLite serializes this against current transactions. Busy/error
            // leaves every row intact and retries on a later maintenance pass.
            let checkpoints = try db.readRows("PRAGMA wal_checkpoint(TRUNCATE)") { $0.int(0) ?? 1 }
            guard checkpoints.first == 0 else { throw BusinessStoreError.sourceChanged }
            try db.execute("PRAGMA incremental_vacuum")
            _ = try db.readRows("PRAGMA wal_checkpoint(TRUNCATE)") { $0.int(0) }
            try record()
            let after = try metric("page_count") * size
            return .compacted(beforeBytes: bytes.partialValue, afterBytes: after,
                reclaimedBytes: bytes.partialValue > after ? bytes.partialValue - after : 0)
        }
    }
}
