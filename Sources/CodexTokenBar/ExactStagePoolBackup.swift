import CryptoKit
import Foundation
import SQLite3

/// One verified pre-structure snapshot, not a second writer or an automatic
/// rollback target. Original A is never replaced by this helper.
enum ExactStagePoolBackup {
    private struct Receipt: Codable {
        let format: Int
        let sourceIdentity: String
        let sha256: String
    }

    private static func identity(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { throw ExactStagePool.Failure.invalid }
        return "\(device):\(inode)"
    }
    private static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty { result.update(data: data) }
        return result.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func ensure(container: URL, connection: SQLiteDatabaseConnection) throws {
        let manager = FileManager.default
        let sourceIdentity = try identity(container)
        let directory = container.deletingLastPathComponent()
            .appendingPathComponent("ledger-migration-backups", isDirectory: true)
            .appendingPathComponent("structural-stage-pool-v1", isDirectory: true)
        let image = directory.appendingPathComponent("image", isDirectory: true)
        let snapshot = image.appendingPathComponent("snapshot.sqlite")
        let receiptURL = directory.appendingPathComponent("receipt.json")
        let intent = directory.appendingPathComponent("preparation.json")
        for folder in [directory.deletingLastPathComponent(), directory, image] where manager.fileExists(atPath: folder.path) {
            guard try manager.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw ExactStagePool.Failure.invalid
            }
        }
        for file in [snapshot, receiptURL, intent] where manager.fileExists(atPath: file.path) {
            guard try manager.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else {
                throw ExactStagePool.Failure.invalid
            }
        }
        if manager.fileExists(atPath: receiptURL.path) {
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
            guard receipt.format == 1, receipt.sourceIdentity == sourceIdentity,
                  try hash(snapshot) == receipt.sha256 else { throw ExactStagePool.Failure.invalid }
            for suffix in ["-wal", "-journal"] {
                let path = snapshot.path + suffix
                if manager.fileExists(atPath: path) {
                    let attributes = try manager.attributesOfItem(atPath: path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          (attributes[.size] as? NSNumber)?.uint64Value == 0 else { throw ExactStagePool.Failure.invalid }
                }
            }
            return
        }
        if manager.fileExists(atPath: image.path), !(try manager.contentsOfDirectory(atPath: image.path)).isEmpty {
            // Resume our own recorded preparation, never an unknown file.
            let pending = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: intent))
            guard pending.format == 1, pending.sourceIdentity == sourceIdentity, pending.sha256 == "pending" else {
                throw ExactStagePool.Failure.invalid
            }
            let owned = SQLiteDatabaseDriver(url: snapshot, createsFileIfMissing: false,
                enableWAL: false, bypassBusinessRoutes: true)
            let complete = (try? owned.withConnection { db in
                try db.readRows("PRAGMA quick_check", map: { $0.text(0) }) == ["ok"] &&
                    db.readRows("SELECT value FROM tb_container_meta WHERE key='activation_state'", map: { $0.text(0) }).first == "ready" &&
                    db.readRows("PRAGMA user_version", map: { $0.int(0) }).first == 1
            }) == true
            if complete {
                // SQLite backup commits the destination atomically only on
                // DONE. A valid completed image plus our source-bound intent
                // can finish its receipt after a crash, without copying A again.
                try finish(snapshot: snapshot, receiptURL: receiptURL, directory: directory, sourceIdentity: sourceIdentity)
                return
            }
            // An incomplete image is ours, but is not a fallback ledger. Keep
            // its family together as evidence and retry into a new destination.
            let entries = try manager.contentsOfDirectory(at: image, includingPropertiesForKeys: nil)
            let family = Set(["snapshot.sqlite", "snapshot.sqlite-wal", "snapshot.sqlite-shm", "snapshot.sqlite-journal"])
            for entry in entries {
                guard family.contains(entry.lastPathComponent),
                      try manager.attributesOfItem(atPath: entry.path)[.type] as? FileAttributeType == .typeRegular else { throw ExactStagePool.Failure.invalid }
            }
            let retained = directory.appendingPathComponent("incomplete-\(UUID().uuidString)", isDirectory: true)
            try manager.moveItem(at: image, to: retained)
            try BusinessDatabaseMigration.synchronize(directory)
        }
        let parent = container.deletingLastPathComponent()
        let attributes = try manager.attributesOfItem(atPath: container.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let walSize = ((try? manager.attributesOfItem(atPath: container.path + "-wal")[.size]) as? NSNumber)?.uint64Value ?? 0
        let free = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) } ?? 0
        let (sourceSize, overflow) = size.addingReportingOverflow(walSize)
        guard !overflow, sourceSize <= UInt64.max - 512 * 1_024 * 1_024,
              free >= sourceSize + 512 * 1_024 * 1_024 else { throw BusinessDatabaseMigration.Failure.insufficientSpace }
        // Do not follow an old symlink, overwrite an orphan, or delete evidence.
        try manager.createDirectory(at: image, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard !manager.fileExists(atPath: snapshot.path) else { throw ExactStagePool.Failure.invalid }
        // Persist intent before creating the snapshot. An interrupted/orphaned
        // snapshot remains evidence; it cannot silently become a valid receipt.
        try JSONEncoder().encode(Receipt(format: 1, sourceIdentity: sourceIdentity, sha256: "pending"))
            .write(to: intent, options: .atomic)
        try BusinessDatabaseMigration.synchronize(intent)
        let target = SQLiteDatabaseDriver(url: snapshot, enableWAL: false, bypassBusinessRoutes: true)
        try target.withConnection { destination in
            guard let backup = sqlite3_backup_init(destination.rawDatabase, "main", connection.rawDatabase, "main") else {
                throw ExactStagePool.Failure.unavailable
            }
            var status: Int32
            let deadline = Date().addingTimeInterval(30)
            repeat {
                status = sqlite3_backup_step(backup, 128)
                if status == SQLITE_BUSY || status == SQLITE_LOCKED { Thread.sleep(forTimeInterval: 0.02) }
            } while (status == SQLITE_OK || status == SQLITE_BUSY || status == SQLITE_LOCKED) && Date() < deadline
            let finished = sqlite3_backup_finish(backup)
            guard status == SQLITE_DONE, finished == SQLITE_OK,
                  try destination.readRows("PRAGMA quick_check", map: { $0.text(0) }) == ["ok"],
                  try destination.readRows("SELECT value FROM tb_container_meta WHERE key='activation_state'", map: { $0.text(0) }).first == "ready",
                  try identity(container) == sourceIdentity else { throw ExactStagePool.Failure.invalid }
        }
        try finish(snapshot: snapshot, receiptURL: receiptURL, directory: directory, sourceIdentity: sourceIdentity)
    }

    private static func finish(snapshot: URL, receiptURL: URL, directory: URL, sourceIdentity: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        try BusinessDatabaseMigration.synchronize(snapshot)
        let receipt = Receipt(format: 1, sourceIdentity: sourceIdentity, sha256: try hash(snapshot))
        try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
        try BusinessDatabaseMigration.synchronize(receiptURL)
        try BusinessDatabaseMigration.synchronize(directory)
    }
}
