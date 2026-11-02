import AppKit
import CryptoKit
import Darwin
import Foundation

/// Migration is a startup gate: old engines are never constructed until every
/// discovered input has a verified backup and a committed store partition.
/// Old files remain rollback evidence; they are never a second write target.
final class BusinessDatabaseMigration {
    struct Progress: Equatable, Sendable {
        enum Stage: String, Sendable { case preparing, importing, verifying, activating, ready }
        let stage: Stage
        var completed = 0
        var total = 0
    }
    struct Configuration: Sendable {
        let container: URL
        let support: URL
        let exact: URL
        let legacyExact: URL
        var backups: URL { container.deletingLastPathComponent().appendingPathComponent("ledger-migration-backups", isDirectory: true) }
        static func production(fileManager: FileManager = .default) throws -> Self {
            let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let native = support.appendingPathComponent("CodexTokenBar", isDirectory: true)
            return .init(container: native.appendingPathComponent("codex-ledger.sqlite"), support: native,
                exact: CodexUsageHistoryIndex.businessIndexDirectory(),
                legacyExact: CodexUsageHistoryIndex.businessIndexDirectory(legacyCache: true))
        }
        func specification(for url: URL) -> BusinessSQLiteStore? {
            func relativePath(in root: URL) -> String? {
                let path = url.standardizedFileURL.path
                let logicalRoot = root.standardizedFileURL.path
                if path.hasPrefix(logicalRoot + "/") { return String(path.dropFirst(logicalRoot.count + 1)) }
                // Enumeration uses physical roots, while persisted ownership
                // uses configured logical roots. Resolve the parent, not the
                // database leaf, so deleting a legacy file does not change ID.
                let physicalPath = url.deletingLastPathComponent().resolvingSymlinksInPath()
                    .appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
                let physicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
                guard physicalPath.hasPrefix(physicalRoot + "/") else { return nil }
                return String(physicalPath.dropFirst(physicalRoot.count + 1))
            }
            let relative: String, module: String
            let logicalURL: URL
            if let found = relativePath(in: exact) {
                relative = found
                logicalURL = exact.appendingPathComponent(relative)
                if relative.hasPrefix("staging/") && relative.hasSuffix(".sqlite") && relative.split(separator: "/").count >= 3 { module = "exact.swift.stage" }
                else if !relative.contains("/"), relative.hasSuffix(".sqlite"),
                        relative.dropLast(7).count == 64,
                        relative.dropLast(7).allSatisfy({ $0.isHexDigit }) { module = "exact.swift" }
                else { return nil }
            } else if let found = relativePath(in: support) {
                relative = found
                logicalURL = support.appendingPathComponent(relative)
                switch relative {
                case "quota-history.sqlite": module = "quota.swift"
                case "shared-account-usage-safety.sqlite": module = "safety.swift"
                case "modeltrace/modeltrace.sqlite": module = "modeltrace.swift"
                default:
                    guard !relative.contains("/"), relative.hasPrefix("body-speed-"), relative.hasSuffix(".sqlite") else { return nil }
                    module = "body.swift"
                }
            } else { return nil }
            return BusinessSQLiteStore(containerURL: container, logicalURL: logicalURL, module: module, sourceIdentity: relative)
        }
    }
    struct Receipt: Codable {
        let sourcePath: String, backupPath: String, normalizedPath: String, storeID: String
        let original: BusinessStoreProof, imported: BusinessStoreProof
        /// An unsupported source is retained verbatim, never rebuilt. Opening
        /// that particular Home still enforces its existing version gate.
        let normalizationDeferredReason: String?
        let normalizationRevision: Int?
    }
    enum Failure: LocalizedError {
        case runningWriter, unsafeInput(String), insufficientSpace, incompleteActivation, unmigratedInput(String), untrackedInterruptedImport
        case batchFailures([String])
        case pendingDestinationChanged(String), retryHistoryNotCovered(String)
        var errorDescription: String? {
            switch self {
            case .untrackedInterruptedImport: return "检测到旧版本留下的未完成导入，缺少可恢复批次记录；已保留全部旧账和候选库，请先恢复或核对该批次。"
            case .runningWriter: return "另一个 Token Bar 仍在运行，已保留旧账；请退出另一实例后重试。"
            case .unsafeInput(let path): return "账本迁移发现不安全或未知的输入，已保留原文件：\(path)"
            case .insufficientSpace: return "账本迁移空间不足，未切换旧账。"
            case .incompleteActivation: return "账本迁移尚未完成，已保留备份与候选库。"
            case .unmigratedInput(let path): return "发现尚未验证的旧库，停止建立空库：\(path)"
            case .batchFailures(let errors): return "本次迁移发现 \(errors.count) 个问题，已保留原库、备份和候选库，尚未切换：\n" + errors.joined(separator: "\n")
            case .pendingDestinationChanged(let path): return "待恢复分区与已验证冻结快照不一致，已保留两侧历史并停止覆盖：\(path)"
            case .retryHistoryNotCovered(let path): return "重试输入未能证明覆盖上次冻结的完整历史，已保留新旧快照并停止切换：\(path)"
            }
        }
    }
    @MainActor private static var lifetimeLock: CodexCrossProcessFileLock?

    @MainActor static func startProduction(onProgress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws {
        let configuration = try Configuration.production()
        let diagnostics = BusinessMigrationDiagnostics(root: configuration.container.deletingLastPathComponent()
            .appendingPathComponent("migration-diagnostics", isDirectory: true), operation: "startup-gate")
        do {
            // Legacy versions do not participate in the new lifetime lock.
            // Observe, never terminate, their processes before mutating a DB.
            let lock = try diagnostics.perform("acquire-writer-ownership") {
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let other = NSWorkspace.shared.runningApplications.contains { app in
                    app.processIdentifier != ownPID && (app.executableURL?.lastPathComponent == "CodexTokenBar"
                        || app.localizedName == "Codex Token Bar")
                }
                guard !other else { throw Failure.runningWriter }
                return try CodexCrossProcessFileLock(url: configuration.container.appendingPathExtension("writer.lock"), label: "统一账本")
            }
            try await Task.detached(priority: .utility) {
                try migrateWithDiagnostics(configuration, fileManager: .default, availableBytes: nil,
                    beforeActivation: nil, onProgress: onProgress, diagnostics: diagnostics)
            }.value
            lifetimeLock = lock
            diagnostics.finish()
        } catch { diagnostics.finish(error); throw error }
    }

    /// Isolated configurations are used by tests. No production path discovery
    /// or application process manipulation occurs here.
    static func migrate(_ configuration: Configuration, fileManager: FileManager = .default,
                        availableBytes: UInt64? = nil,
                        beforeActivation: (() throws -> Void)? = nil,
                        onProgress: (@Sendable (Progress) -> Void)? = nil) throws {
        let diagnostics = BusinessMigrationDiagnostics(root: configuration.container.deletingLastPathComponent()
            .appendingPathComponent("migration-diagnostics", isDirectory: true), operation: "bootstrap")
        do {
            try migrateWithDiagnostics(configuration, fileManager: fileManager, availableBytes: availableBytes,
                beforeActivation: beforeActivation, onProgress: onProgress, diagnostics: diagnostics)
            diagnostics.finish()
        } catch { diagnostics.finish(error); throw error }
    }

    private static func migrateWithDiagnostics(_ configuration: Configuration, fileManager: FileManager,
                        availableBytes: UInt64?, beforeActivation: (() throws -> Void)?,
                        onProgress: (@Sendable (Progress) -> Void)?, diagnostics: BusinessMigrationDiagnostics) throws {
        onProgress?(.init(stage: .preparing))
        var inputs = try diagnostics.perform("discover-inputs") { try discover(configuration, fileManager: fileManager, diagnostics: diagnostics) }
        diagnostics.record("input-inventory", "succeeded", ["count": String(inputs.count)])
        var legacyLocks: [CodexCrossProcessFileLock] = []
        defer { for lock in legacyLocks { lock.release() } }
        var lockFailures: [(Error, String)] = []
        for input in inputs where input.store.module == "exact.swift" || input.store.module == "exact.swift.retired" {
            let original = input.source.path.hasSuffix(".schema11-rollback")
                ? URL(fileURLWithPath: String(input.source.path.dropLast(".schema11-rollback".count))) : input.source
            do {
                let lock = try diagnostics.perform("acquire-source-lock", subject: input.store.id) {
                    try CodexCrossProcessFileLock(url: original.appendingPathExtension("operation.lock"), label: "旧索引迁移")
                }
                legacyLocks.append(lock)
            } catch { lockFailures.append((error, "\(input.source.path): \(error.localizedDescription)")) }
        }
        if !lockFailures.isEmpty {
            lockFailures += diagnoseBlockedInputs(inputs, diagnostics: diagnostics, reason: "source-lock-failed")
            if lockFailures.count == 1 { throw lockFailures[0].0 }
            throw Failure.batchFailures(lockFailures.map { $0.1 })
        }
        try fileManager.createDirectory(at: configuration.container.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let exists = fileManager.fileExists(atPath: configuration.container.path)
        let initialized = configuration.container.appendingPathExtension("initialized")
        if !exists, fileManager.fileExists(atPath: initialized.path) { throw Failure.incompleteActivation }
        let working = exists ? configuration.container : configuration.container.deletingLastPathComponent().appendingPathComponent(".codex-ledger-migrating.sqlite")
        // A fixed private candidate is resumable. Atomic import transactions
        // and receipts make replay idempotent; activation is a separate gate.
        let database = try diagnostics.perform("open-container", subject: "A") { try CodexBusinessDatabase(url: working) }
        let recordedInputs = try database.driver.readRows("SELECT source_path,logical_path,store_id,module FROM tb_legacy_inputs") {
            RecordedInput(sourcePath: $0.text(0) ?? "", logicalPath: $0.text(1) ?? "",
                storeID: $0.text(2) ?? "", module: $0.text(3) ?? "")
        }
        let known = Set(recordedInputs.map(\.sourcePath))
        let journalKey = "migration_pending_sources_v1"
        let journalRaw = try database.driver.readRows("SELECT value FROM tb_container_meta WHERE key=?", bindings: [.text(journalKey)]) { $0.text(0) }.first ?? nil
        let journal = try journalRaw.map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
        inputs = try diagnostics.perform("resolve-input-ownership") {
            try reconcileInputAliases(inputs, recorded: recordedInputs, journal: journal,
                database: database, diagnostics: diagnostics)
        }
        let discovered = Dictionary(uniqueKeysWithValues: inputs.map { ($0.source.path, $0.store.id) })
        // A vanished/relocated uncommitted input must not silently disappear
        // from the retry. Committed sources remain independent of old files.
        for (path, storeID) in journal {
            guard discovered[path] == storeID else { throw Failure.unmigratedInput(path) }
        }
        let pending = exists ? inputs.filter { !known.contains($0.source.path) || journal[$0.source.path] != nil } : inputs
        let activation = try database.driver.readRows("SELECT value FROM tb_container_meta WHERE key='activation_state'") { $0.text(0) }.first ?? nil
        if exists, activation == "importing", journalRaw == nil {
            // An older interrupted writer did not persist which partitions
            // were new. Never guess and overwrite previously activated data.
            throw Failure.untrackedInterruptedImport
        }
        for input in pending where exists && journal[input.source.path] == nil {
            let registered = try database.driver.readRows("SELECT 1 FROM tb_stores WHERE store_id=?", bindings: [.text(input.store.id)]) { $0.int(0) }.first != nil
            guard !registered else { throw Failure.unmigratedInput(input.source.path) }
        }
        if exists, fileManager.fileExists(atPath: initialized.path), pending.isEmpty, activation == "ready" {
            // A completed upgrade is not another migration. Keep the catalog,
            // physical-version and source-discovery fences above, but do not
            // scan every data page, rewrite readiness or fsync the whole file
            // before showing the next normal launch. Readers validate pages
            // they touch; storage maintenance retains its independent cadence.
            try activateRoutes(configuration, database: database)
            onProgress?(.init(stage: .ready))
            return
        }
        let batch = Dictionary(uniqueKeysWithValues: pending.map { ($0.source.path, $0.store.id) })
        let batchJSON = String(decoding: try JSONEncoder().encode(batch), as: UTF8.self)
        try database.driver.transaction { tx in
            try tx.execute("INSERT OR REPLACE INTO tb_container_meta VALUES (?,?)", bindings: [.text(journalKey), .text(batchJSON)])
            try tx.execute("INSERT OR REPLACE INTO tb_container_meta VALUES ('activation_state','importing')")
        }
        var needed: UInt64 = 256 * 1024 * 1024
        for input in pending {
            for suffix in ["", "-wal"] {
                let size = ((try? fileManager.attributesOfItem(atPath: input.source.path + suffix)[.size]) as? NSNumber)?.uint64Value ?? 0
                let (scaled, overflow) = size.multipliedReportingOverflow(by: 4)
                let (next, additionOverflow) = needed.addingReportingOverflow(scaled)
                guard !overflow, !additionOverflow else { throw Failure.insufficientSpace }
                needed = next
            }
        }
        let free = try availableBytes ?? configuration.container.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage.map(UInt64.init) ?? 0
        guard pending.isEmpty || free >= needed else { throw Failure.insufficientSpace }
        // Independently inspect every pending input before the first import.
        // These observations never authorize a repair or replace the proof gate.
        for input in pending {
            do {
                let version = try SQLiteDatabaseDriver(url: input.source, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
                    .readRows("PRAGMA user_version") { $0.int(0) ?? 0 }.first ?? 0
                diagnostics.record("input-preflight", "succeeded", ["store": input.store.id, "module": input.store.module, "userVersion": String(version)])
            } catch {
                diagnostics.record("input-preflight", "failed", ["store": input.store.id, "module": input.store.module, "error": String(describing: error)])
            }
        }
        var failures: [(Error, String)] = []
        var importedInputs: [Input] = []
        for (index, input) in pending.enumerated() {
            diagnostics.record("store-import", "started", ["store": input.store.id, "module": input.store.module])
            onProgress?(.init(stage: .importing, completed: index, total: pending.count))
            do {
                let store = BusinessSQLiteStore(containerURL: working, logicalURL: input.store.logicalURL, module: input.store.module, sourceIdentity: input.store.sourceIdentity)
                let folder = configuration.backups.appendingPathComponent(store.id, isDirectory: true)
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let reusable = try reusableAttempt(input: input, folder: folder, fileManager: fileManager)
                let attempt = reusable.map { URL(fileURLWithPath: $0.backupPath).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "original-", with: "") } ?? UUID().uuidString
                // A verified receipt may retain an older spelling of this same
                // physical backup folder. Keep its paths stable as well as its
                // UUID; rewriting only their spelling would invalidate the
                // immutable attempt receipt on the next check.
                let backup = reusable.map { URL(fileURLWithPath: $0.backupPath).standardizedFileURL }
                    ?? folder.appendingPathComponent("original-\(attempt).sqlite")
                if !fileManager.fileExists(atPath: backup.path) {
                    // sqlite3_backup observes a consistent WAL snapshot. No raw
                    // main-file copy, checkpoint, DELETE, or schema write on input.
                    try SQLiteDatabaseDriver(url: backup, bypassBusinessRoutes: true).withConnection { connection in
                        try connection.restoreDatabase(from: input.source)
                        _ = try connection.readRows("PRAGMA wal_checkpoint(TRUNCATE)") { $0.int(0) }
                        _ = try connection.readRows("PRAGMA journal_mode=DELETE") { $0.text(0) }
                    }
                    try synchronize(backup)
                    try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: backup.path)
                }
                let original = try diagnostics.perform("original-proof", subject: store.id) {
                    try SQLiteDatabaseDriver(url: backup, readOnly: true, bypassBusinessRoutes: true).withConnection { try CodexBusinessDatabase.proof($0) }
                }
                diagnostics.record("verified-snapshot", "succeeded", ["store": store.id, "schemaDigest": original.schemaDigest, "rowsDigest": original.rowsDigest])
                let normalized = reusable.map { URL(fileURLWithPath: $0.normalizedPath).standardizedFileURL }
                    ?? folder.appendingPathComponent("normalized-\(attempt).sqlite")
                if !fileManager.fileExists(atPath: normalized.path) {
                    try SQLiteDatabaseDriver(url: normalized, bypassBusinessRoutes: true).withConnection { try $0.restoreDatabase(from: backup) }
                }
                var normalizationDeferredReason = reusable?.normalizationDeferredReason
                if reusable == nil {
                    if store.module == "exact.swift" || store.module == "exact.swift.retired" {
                        do {
                            try diagnostics.perform("normalize-exact-snapshot", subject: store.id) {
                                try CodexUsageHistoryIndex.prepareBusinessSnapshot(at: normalized)
                            }
                        } catch let error as CodexUsageIndexUpgradeRequiredError {
                            // Every old Home is collected, including dormant Homes
                            // from an older/newer app. Their version must not prevent
                            // an unrelated, supported Home from starting. Restore the
                            // untouched snapshot before importing it; do not weaken
                            // the per-Home reader's fail-closed compatibility checks.
                            try SQLiteDatabaseDriver(url: normalized, bypassBusinessRoutes: true)
                                .withConnection { try $0.restoreDatabase(from: backup) }
                            normalizationDeferredReason = error.localizedDescription
                            diagnostics.record("dormant-home-preserved", "deferred", ["store": store.id, "reason": error.localizedDescription])
                        }
                    }
                    if store.module == "exact.swift.stage" {
                        let normalizedDB = SQLiteDatabaseDriver(url: normalized, bypassBusinessRoutes: true)
                        try normalizedDB.withConnection { connection in
                            let tables = try connection.readRows("SELECT name FROM sqlite_master WHERE type='table'") { $0.text(0) ?? "" }
                            if tables.contains("manifest") {
                                let columns = Set(try connection.readRows("PRAGMA table_info(manifest)") { $0.text(1) ?? "" })
                                if columns.isSuperset(of: ["complete", "actual_bytes"]),
                                   try connection.readRows("SELECT complete FROM manifest", map: { $0.int(0) }).first == 1 {
                                    let bytes = try BusinessStoreFiles.footprint(connection)
                                    try connection.execute("UPDATE manifest SET actual_bytes=?", bindings: [.int64(Int64(bytes))])
                                }
                            }
                        }
                    }
                    try SQLiteDatabaseDriver(url: normalized, bypassBusinessRoutes: true).withConnection { connection in
                        _ = try connection.readRows("PRAGMA wal_checkpoint(TRUNCATE)") { $0.int(0) }
                        _ = try connection.readRows("PRAGMA journal_mode=DELETE") { $0.text(0) }
                    }
                    try synchronize(normalized)
                }
                let expectedSource = try SQLiteDatabaseDriver(url: normalized, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
                    .withConnection { db in try db.readTransaction { try CodexBusinessDatabase.proof($0) } }
                let replacesPending = !exists || journal[input.source.path] != nil
                let expectedDestination: BusinessStoreProof?
                if replacesPending {
                    expectedDestination = try diagnostics.perform("verify-pending-history-coverage", subject: store.id) {
                        try verifiedRetryDestination(database: database, store: store, input: input,
                            normalized: normalized, normalizedProof: expectedSource, folder: folder, fileManager: fileManager,
                            diagnostics: diagnostics)
                    }
                } else { expectedDestination = nil }
                let imported = try diagnostics.perform("namespace-import-and-proof", subject: store.id) {
                    try database.importSnapshot(normalized, into: store, backupURL: backup, replaceExisting: replacesPending,
                        expectedDestination: expectedDestination, expectedSource: expectedSource)
                }
                if let reusable, imported != reusable.imported { throw BusinessStoreError.sourceChanged }
                try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: normalized.path)
                if store.module == "exact.swift.stage" {
                    try database.driver.withConnection { connection in
                        try connection.installBusinessStore(store)
                        let columns = Set(try connection.readRows("PRAGMA table_info(manifest)") { $0.text(1) ?? "" })
                        if columns.contains("complete"), try connection.readRows("SELECT complete FROM manifest", map: { $0.int(0) }).first == 1 {
                            try BusinessStoreFiles.seal(at: store.logicalURL, connection: connection)
                        }
                    }
                }
                try database.driver.execute("INSERT OR REPLACE INTO tb_legacy_inputs(source_path,logical_path,store_id,module,source_digest,backup_path,retired) VALUES(?,?,?,?,?,?,0)",
                    bindings: [.text(input.source.path), .text(store.logicalURL.path), .text(store.id), .text(store.module),
                        .text(original.schemaDigest + ":" + original.rowsDigest), .text(backup.path)])
                let receipt = Receipt(sourcePath: input.source.path, backupPath: backup.path, normalizedPath: normalized.path,
                    storeID: store.id, original: original, imported: imported,
                    normalizationDeferredReason: normalizationDeferredReason, normalizationRevision: normalizationRevision)
                let json = try JSONEncoder().encode(receipt)
                // Keep provenance for every completed attempt, not just whichever
                // receipt happened to be the last retry. This is ownership evidence
                // for future cleanup; an untracked file is never deleted by name.
                let attemptReceipt = folder.appendingPathComponent("attempt-\(attempt).json")
                if fileManager.fileExists(atPath: attemptReceipt.path) {
                    let attributes = try fileManager.attributesOfItem(atPath: attemptReceipt.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          let previous = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: attemptReceipt)),
                          previous.sourcePath == receipt.sourcePath, previous.backupPath == receipt.backupPath,
                          previous.normalizedPath == receipt.normalizedPath, previous.storeID == receipt.storeID,
                          previous.original == receipt.original, previous.imported == receipt.imported,
                          previous.normalizationRevision == receipt.normalizationRevision else {
                        throw Failure.unsafeInput(attemptReceipt.path)
                    }
                } else {
                    try json.write(to: attemptReceipt, options: .withoutOverwriting)
                    try synchronize(attemptReceipt)
                }
                try json.write(to: folder.appendingPathComponent("receipt.json"), options: .atomic)
                try synchronize(folder.appendingPathComponent("receipt.json"))
                diagnostics.record("store-import", "succeeded", ["store": store.id, "schemaDigest": imported.schemaDigest, "rowsDigest": imported.rowsDigest])
                importedInputs.append(input)
            } catch {
                failures.append((error, "\(input.store.module) [\(input.store.id)]: \(error.localizedDescription)"))
                diagnostics.record("store-import", "failed", ["store": input.store.id, "module": input.store.module,
                    "error": String(describing: error)])
            }
            onProgress?(.init(stage: .importing, completed: index + 1, total: pending.count))
        }
        // A stale copy must never win over a legacy writer that changed its
        // source while the candidate was being prepared.
        for (index, input) in importedInputs.enumerated() {
            onProgress?(.init(stage: .verifying, completed: index, total: importedInputs.count))
            do {
                let source = SQLiteDatabaseDriver(url: input.source, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
                let current = try diagnostics.perform("verify-original-unchanged", subject: input.store.id) {
                    try source.withConnection { try CodexBusinessDatabase.proof($0) }
                }
                let storeID = input.store.id
                let folder = configuration.backups.appendingPathComponent(storeID)
                let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: folder.appendingPathComponent("receipt.json")))
                guard current == receipt.original else { throw BusinessStoreError.sourceChanged }
            } catch {
                failures.append((error, "\(input.store.module) [\(input.store.id)]: \(error.localizedDescription)"))
                diagnostics.record("verify-original-unchanged", "failed", ["store": input.store.id,
                    "module": input.store.module, "error": String(describing: error)])
            }
        }
        // Independent stores can contribute their complete diagnostic chain in
        // one attempt. Any failed store still withholds global activation and
        // keeps the whole pending journal for a verified retry.
        if failures.count == 1 { throw failures[0].0 }
        if !failures.isEmpty { throw Failure.batchFailures(failures.map { $0.1 }) }
        try beforeActivation?()
        diagnostics.record("activate-container", "started")
        onProgress?(.init(stage: .activating, completed: pending.count, total: pending.count))
        try database.driver.withConnection { db in
            guard try db.readRows("PRAGMA quick_check", map: { $0.text(0) }) == ["ok"] else { throw BusinessStoreError.proofMismatch }
            _ = try db.readRows("PRAGMA wal_checkpoint(TRUNCATE)") { $0.int(0) }
            _ = try db.readRows("PRAGMA journal_mode=DELETE") { $0.text(0) }
        }
        // Completion and removal of the pending batch commit together, only
        // after all sources and the container have passed verification.
        try database.driver.transaction { tx in
            try tx.execute("INSERT OR REPLACE INTO tb_container_meta VALUES ('activation_state','ready')")
            try tx.execute("DELETE FROM tb_container_meta WHERE key=?", bindings: [.text(journalKey)])
        }
        try synchronize(working)
        if !exists {
            guard !fileManager.fileExists(atPath: configuration.container.path) else { throw BusinessStoreError.destinationExists }
            try fileManager.moveItem(at: working, to: configuration.container)
            try synchronize(configuration.container.deletingLastPathComponent())
        }
        if !fileManager.fileExists(atPath: initialized.path) {
            try Data("tokenbar-codex-ledger-v1\n".utf8).write(to: initialized, options: .atomic)
            try synchronize(initialized)
            try synchronize(initialized.deletingLastPathComponent())
        }
        let ready = try CodexBusinessDatabase(url: configuration.container)
        try activateRoutes(configuration, database: ready)
        diagnostics.record("activate-container", "succeeded")
        onProgress?(.init(stage: .ready, completed: pending.count, total: pending.count))
    }

    private static func activateRoutes(_ configuration: Configuration, database ready: CodexBusinessDatabase) throws {
        // Candidate activation uses a single-file image. The live shared
        // container must return to WAL before any module starts writing.
        let mode = try ready.driver.readRows("PRAGMA journal_mode") { $0.text(0) }.first ?? nil
        if mode?.lowercased() != "wal" {
            try ready.driver.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL")
        }
        let stores = try ready.driver.readRows("SELECT logical_path,module,source_identity FROM tb_stores") { row in
            BusinessSQLiteStore(containerURL: configuration.container, logicalURL: URL(fileURLWithPath: row.text(0) ?? ""), module: row.text(1) ?? "", sourceIdentity: row.text(2) ?? "")
        }
        BusinessSQLiteRoutes.activate(configuration, stores: stores)
    }
    // Bump when normalization semantics change. Old/unversioned receipts are
    // preserved, but never reused as if produced by the current normalizer.
    private static let normalizationRevision = 1

    /// A pending journal permits retry, never blind replacement. Match A to a
    /// proof-bound retained normalized image, prove that the new normalized
    /// image covers it, and recheck that exact A proof inside import's write
    /// transaction. The durable import receipt also covers a crash before the
    /// later human-readable attempt JSON was written.
    private static func verifiedRetryDestination(database: CodexBusinessDatabase, store: BusinessSQLiteStore,
        input: Input, normalized: URL, normalizedProof: BusinessStoreProof,
        folder: URL, fileManager: FileManager, diagnostics: BusinessMigrationDiagnostics) throws -> BusinessStoreProof {
        let namespace = SQLiteStoreNamespace(prefix: store.prefix, objectNames: [])
        let (current, objects) = try database.driver.withConnection { db in
            try db.readTransaction { db in
                (try CodexBusinessDatabase.proof(db, namespace: namespace),
                 try db.readRows("SELECT COUNT(*) FROM main.sqlite_master WHERE substr(name,1,?)=?",
                    bindings: [.int(store.prefix.count), .text(store.prefix)]) { $0.int(0) ?? 0 }.first ?? 0)
            }
        }
        if objects == 0 { return current }
        let digest = current.schemaDigest + ":" + current.rowsDigest + ":v" + String(current.moduleUserVersion)
        let backups = try database.driver.readRows("""
            SELECT backup_path FROM tb_store_imports WHERE store_id=? AND source_digest=?
            AND schema_digest=? AND row_count=? AND rows_digest=? ORDER BY imported_at DESC
            """, bindings: [.text(store.id), .text(digest), .text(current.schemaDigest), .int64(current.rowCount), .text(current.rowsDigest)]) { $0.text(0) ?? "" }
        for path in backups {
            let original = URL(fileURLWithPath: path).standardizedFileURL
            let name = original.deletingPathExtension().lastPathComponent
            guard original.pathExtension == "sqlite", name.hasPrefix("original-"),
                  UUID(uuidString: String(name.dropFirst("original-".count))) != nil,
                  BusinessSQLiteRoutes.resolvedDirectoryIdentity(original.deletingLastPathComponent())
                    == BusinessSQLiteRoutes.resolvedDirectoryIdentity(folder) else { continue }
            let retained = folder.appendingPathComponent("normalized-" + String(name.dropFirst("original-".count)) + ".sqlite")
            let owned = [folder, original, retained].allSatisfy { url in
                guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return false }
                return attributes[.type] as? FileAttributeType == (url == folder ? .typeDirectory : .typeRegular)
            }
            guard owned else { continue }
            let retainedProof = try SQLiteDatabaseDriver(url: retained, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
                .withConnection { db in try db.readTransaction { try CodexBusinessDatabase.proof($0) } }
            guard retainedProof == current else { continue }
            guard try CodexBusinessDatabase.snapshot(normalized, covers: retained, module: store.module,
                legacySourceURL: input.source, expectedRetained: current,
                expectedCandidate: normalizedProof, diagnostics: diagnostics) else { throw Failure.retryHistoryNotCovered(input.source.path) }
            return current
        }
        throw Failure.pendingDestinationChanged(input.source.path)
    }

    private static func reusableAttempt(input: Input, folder: URL, fileManager: FileManager) throws -> Receipt? {
        let receiptURL = folder.appendingPathComponent("receipt.json")
        guard let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.normalizationRevision == normalizationRevision,
              receipt.sourcePath == input.source.path, receipt.storeID == input.store.id else { return nil }
        let original = URL(fileURLWithPath: receipt.backupPath).standardizedFileURL
        let normalized = URL(fileURLWithPath: receipt.normalizedPath).standardizedFileURL
        let name = original.deletingPathExtension().lastPathComponent
        guard original.pathExtension == "sqlite", name.hasPrefix("original-"),
              UUID(uuidString: String(name.dropFirst("original-".count))) != nil,
              BusinessSQLiteRoutes.resolvedDirectoryIdentity(original.deletingLastPathComponent())
                == BusinessSQLiteRoutes.resolvedDirectoryIdentity(folder),
              BusinessSQLiteRoutes.resolvedDirectoryIdentity(normalized.deletingLastPathComponent())
                == BusinessSQLiteRoutes.resolvedDirectoryIdentity(folder),
              normalized.lastPathComponent == "normalized-" + String(name.dropFirst("original-".count)) + ".sqlite" else { return nil }
        for url in [folder, receiptURL, original, normalized] {
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == (url == folder ? .typeDirectory : .typeRegular) else { return nil }
        }
        let readProof: (URL) throws -> BusinessStoreProof = { url in
            try SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
                .withConnection { try CodexBusinessDatabase.proof($0) }
        }
        // An invalid or interrupted backup is left intact and a fresh attempt
        // is built. A changed input must never reuse its older snapshot.
        guard let sourceProof = try? readProof(input.source), sourceProof == receipt.original,
              let originalProof = try? readProof(original), originalProof == receipt.original,
              let normalizedProof = try? readProof(normalized), normalizedProof == receipt.imported else { return nil }
        return receipt
    }

    private struct Input { let source: URL; let store: BusinessSQLiteStore }
    private struct RecordedInput {
        let sourcePath: String, logicalPath: String, storeID: String, module: String
    }

    /// An alias spelling is not a new legacy input. Keep the durable journal,
    /// receipt and catalog keys only when both paths still name the same regular
    /// file through the same resolved parent and leaf. Equal contents, a matching
    /// basename, or a hard link at a different path cannot authorize relocation.
    private static func reconcileInputAliases(_ inputs: [Input], recorded: [RecordedInput],
        journal: [String: String], database: CodexBusinessDatabase,
        diagnostics: BusinessMigrationDiagnostics) throws -> [Input] {
        var owners: [String: Set<String>] = [:]
        for item in recorded { owners[item.sourcePath, default: []].insert(item.storeID) }
        for (path, storeID) in journal { owners[path, default: []].insert(storeID) }
        guard !inputs.isEmpty, !owners.isEmpty else { return inputs }
        let catalog = try database.driver.readRows("SELECT store_id,logical_path,module,source_identity FROM tb_stores") {
            ($0.text(0) ?? "", $0.text(1) ?? "", $0.text(2) ?? "", $0.text(3) ?? "")
        }
        let catalogByID = Dictionary(grouping: catalog, by: { $0.0 })
        let recordedByPath = Dictionary(grouping: recorded, by: \.sourcePath)
        func canonical(_ url: URL) -> URL {
            BusinessSQLiteRoutes.resolvedDirectoryIdentity(url.deletingLastPathComponent())
                .appendingPathComponent(url.lastPathComponent).standardizedFileURL
        }
        var aliases: [String: [String]] = [:]
        for path in owners.keys {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard path.hasPrefix("/"), url.path == path else { continue }
            aliases[canonical(url).path, default: []].append(path)
        }
        func sameSource(_ path: String, _ source: URL) -> Bool {
            let previous = URL(fileURLWithPath: path).standardizedFileURL
            guard path.hasPrefix("/"), previous.path == path,
                  canonical(previous) == canonical(source) else { return false }
            var old = stat(), new = stat()
            guard lstat(previous.path, &old) == 0, old.st_mode & S_IFMT == S_IFREG,
                  lstat(source.path, &new) == 0, new.st_mode & S_IFMT == S_IFREG else { return false }
            return old.st_dev == new.st_dev && old.st_ino == new.st_ino
        }
        return try inputs.map { input in
            let matches = (aliases[canonical(input.source).path] ?? []).filter { sameSource($0, input.source) }
            guard matches.count <= 1 else { throw Failure.unsafeInput(input.source.path) }
            guard let previous = matches.first else { return input }
            guard owners[previous] == Set([input.store.id]) else { throw Failure.unsafeInput(input.source.path) }
            let receipts = recordedByPath[previous] ?? []
            guard receipts.allSatisfy({ $0.storeID == input.store.id && $0.module == input.store.module
                && canonical(URL(fileURLWithPath: $0.logicalPath)) == canonical(input.store.logicalURL) }) else {
                throw Failure.unsafeInput(input.source.path)
            }
            let registered = catalogByID[input.store.id] ?? []
            guard registered.count <= 1 else { throw Failure.unsafeInput(input.source.path) }
            let logicalURL: URL
            if let old = registered.first {
                guard old.2 == input.store.module, old.3 == input.store.sourceIdentity else {
                    throw Failure.unsafeInput(input.source.path)
                }
                logicalURL = URL(fileURLWithPath: old.1)
                // A crash can commit the namespace before tb_legacy_inputs.
                // In that case the journal and original catalog path jointly
                // establish ownership. A finished quarantined job can instead
                // retain a later catalog path recorded by its owner.
                if receipts.isEmpty, canonical(logicalURL) != canonical(input.store.logicalURL) {
                    throw Failure.unsafeInput(input.source.path)
                }
            } else {
                logicalURL = receipts.first.map { URL(fileURLWithPath: $0.logicalPath) } ?? input.store.logicalURL
            }
            if previous != input.source.path {
                diagnostics.record("input-alias", "reused", ["store": input.store.id,
                    "discoveredPath": input.source.path, "recordedPath": previous,
                    "logicalPath": logicalURL.path])
            }
            return Input(source: URL(fileURLWithPath: previous),
                store: BusinessSQLiteStore(containerURL: input.store.containerURL, logicalURL: logicalURL,
                    module: input.store.module, sourceIdentity: input.store.sourceIdentity))
        }
    }
    /// fileExists conflates ENOENT with EACCES. Only a genuinely absent root
    /// may be skipped: otherwise activation could silently omit old accounts.
    private static func legacyDirectoryExists(_ root: URL) throws -> Bool {
        var info = stat()
        // Configured roots may be directory aliases; descendant symlinks are
        // still rejected by discovery. A dangling alias is not an absent root.
        if stat(root.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unsafeInput(root.path) }
            return true
        }
        let code = errno
        guard code == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        guard lstat(root.path, &info) != 0 else { throw Failure.unsafeInput(root.path) }
        let linkCode = errno
        guard linkCode == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: linkCode) ?? .EIO) }
        return false
    }
    private static func discover(_ c: Configuration, fileManager: FileManager,
                                 diagnostics: BusinessMigrationDiagnostics) throws -> [Input] {
        var found: [Input] = []
        var failures: [(Error, String)] = []
        func reject(_ error: Error, at url: URL, stage: String = "discover-input") {
            failures.append((error, "\(url.path): \(error.localizedDescription)"))
            diagnostics.record(stage, "failed", ["path": url.path, "error": String(describing: error)])
        }
        for root in [c.support, c.exact] {
            do {
                guard try legacyDirectoryExists(root) else { continue }
                diagnostics.record("discover-root", "started", ["path": root.path])
                let before = failures.count
                let canonicalRoot = root.resolvingSymlinksInPath().path
                guard let enumerator = fileManager.enumerator(at: root.resolvingSymlinksInPath(),
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles],
                    errorHandler: { url, error in
                        reject(error, at: url)
                        return true // inspect other independent branches, never accept a partial inventory
                    }) else { throw Failure.unsafeInput(root.path) }
                while let discovered = enumerator.nextObject() as? URL {
                    do {
                        let discoveredValues = try discovered.resourceValues(forKeys: [.isSymbolicLinkKey])
                        if discoveredValues.isSymbolicLink == true {
                            // The configured Exact root can itself be an alias
                            // inside support. Its separate traversal validates
                            // the real directory; arbitrary descendant links
                            // remain unsafe and are never followed here.
                            if canonicalSibling(discovered) == canonicalSibling(c.exact) {
                                enumerator.skipDescendants()
                                continue
                            }
                            throw Failure.unsafeInput(discovered.path)
                        }
                        let discoveredPath = discovered.resolvingSymlinksInPath().path
                        guard discoveredPath.hasPrefix(canonicalRoot + "/") else { throw Failure.unsafeInput(discovered.path) }
                        let file = root.appendingPathComponent(String(discoveredPath.dropFirst(canonicalRoot.count + 1)))
                        let path = file.standardizedFileURL.path
                        let backups = c.backups.standardizedFileURL.path
                        if path == backups || path.hasPrefix(backups + "/") { enumerator.skipDescendants(); continue }
                        if path.hasPrefix(c.exact.standardizedFileURL.path + "/"), file.lastPathComponent.hasSuffix(".schema11-migration.json") {
                            let main = URL(fileURLWithPath: String(file.path.dropLast(".schema11-migration.json".count)))
                            let source = try recoverableLegacyInput(main: main, manifest: file, fileManager: fileManager)
                            if !fileManager.fileExists(atPath: main.path), let store = c.specification(for: main) {
                                found.append(.init(source: source, store: store))
                            }
                        }
                        if path.hasPrefix(c.exact.standardizedFileURL.path + "/") { try validateOrphanCandidate(file, fileManager: fileManager) }
                        guard let store = c.specification(for: file) else { continue }
                        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.unsafeInput(file.path) }
                        found.append(.init(source: file, store: store))
                    } catch {
                        enumerator.skipDescendants()
                        reject(error, at: discovered)
                    }
                }
                diagnostics.record("discover-root", failures.count == before ? "succeeded" : "failed", ["path": root.path])
            } catch { reject(error, at: root, stage: "discover-root") }
        }
        if BusinessSQLiteRoutes.resolvedDirectoryIdentity(c.legacyExact) != BusinessSQLiteRoutes.resolvedDirectoryIdentity(c.exact) {
            do {
                if try legacyDirectoryExists(c.legacyExact) {
                    let cacheFiles = try fileManager.contentsOfDirectory(at: c.legacyExact, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    for file in cacheFiles {
                        do { try validateOrphanCandidate(file, fileManager: fileManager) }
                        catch { reject(error, at: file) }
                    }
                    for manifest in cacheFiles where manifest.lastPathComponent.hasSuffix(".schema11-migration.json") {
                        do {
                            let main = URL(fileURLWithPath: String(manifest.path.dropLast(".schema11-migration.json".count)))
                            let source = try recoverableLegacyInput(main: main, manifest: manifest, fileManager: fileManager)
                            if !fileManager.fileExists(atPath: main.path) {
                                let destination = c.exact.appendingPathComponent(main.lastPathComponent)
                                let currentExists = found.contains { $0.store.logicalURL == destination }
                                guard let active = c.specification(for: destination) else { throw Failure.unsafeInput(manifest.path) }
                                let store = currentExists
                                    ? BusinessSQLiteStore(containerURL: c.container, logicalURL: main, module: "exact.swift.retired", sourceIdentity: "legacy-cache/" + main.lastPathComponent)
                                    : active
                                found.append(.init(source: source, store: store))
                            }
                        } catch { reject(error, at: manifest) }
                    }
                    for file in cacheFiles where file.pathExtension == "sqlite" && file.deletingPathExtension().lastPathComponent.count == 64 && file.deletingPathExtension().lastPathComponent.allSatisfy({ $0.isHexDigit }) {
                        do {
                            let destination = c.exact.appendingPathComponent(file.lastPathComponent)
                            let currentExists = found.contains { $0.store.logicalURL == destination }
                            let store = currentExists
                                ? BusinessSQLiteStore(containerURL: c.container, logicalURL: file, module: "exact.swift.retired", sourceIdentity: "legacy-cache/" + file.lastPathComponent)
                                : c.specification(for: destination)!
                            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.unsafeInput(file.path) }
                            found.append(.init(source: file, store: store))
                        } catch { reject(error, at: file) }
                    }
                }
            } catch { reject(error, at: c.legacyExact, stage: "discover-root") }
        }

        // Overlapping configured roots can enumerate the same source twice.
        // Deduplicate only identical physical-file/store ownership. A hard link
        // assigned to two stores, or two files assigned to one store, is an
        // unresolved ownership conflict rather than permission to pick a winner.
        var physicalOwners: [String: Input] = [:]
        var storeOwners: [String: String] = [:]
        var inputs: [Input] = []
        for input in found.sorted(by: { $0.source.path < $1.source.path }) {
            do {
                var info = stat()
                guard lstat(input.source.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafeInput(input.source.path) }
                let identity = "\(info.st_dev):\(info.st_ino)"
                if let previous = physicalOwners[identity] {
                    guard previous.store.id == input.store.id else { throw Failure.unsafeInput(input.source.path) }
                    diagnostics.record("duplicate-input", "coalesced", ["store": input.store.id, "path": input.source.path])
                    continue
                }
                guard storeOwners[input.store.id] == nil else { throw Failure.unsafeInput(input.source.path) }
                physicalOwners[identity] = input
                storeOwners[input.store.id] = identity
                inputs.append(input)
            } catch { reject(error, at: input.source, stage: "discover-ownership") }
        }
        if !failures.isEmpty {
            diagnostics.record("discovery-incomplete", "failed", ["failures": String(failures.count), "knownInputs": String(inputs.count)])
            failures += diagnoseBlockedInputs(inputs, diagnostics: diagnostics, reason: "incomplete-discovery")
            if failures.count == 1 { throw failures[0].0 }
            throw Failure.batchFailures(failures.map { $0.1 })
        }
        return inputs.sorted { $0.store.logicalURL.path < $1.store.logicalURL.path }
    }

    /// A global discovery/ownership fence prevents imports, but independent
    /// readable inputs can still report complete read-only integrity failures
    /// in this attempt. These observations never authorize a partial migration.
    private static func diagnoseBlockedInputs(_ inputs: [Input], diagnostics: BusinessMigrationDiagnostics,
                                              reason: String) -> [(Error, String)] {
        var failures: [(Error, String)] = []
        for input in inputs {
            do {
                _ = try diagnostics.perform("blocked-input-readonly-proof", subject: input.store.id) {
                    try SQLiteDatabaseDriver(url: input.source, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
                        .withConnection { db in try db.readTransaction { try CodexBusinessDatabase.proof($0) } }
                }
            } catch { failures.append((error, "\(input.source.path): \(error.localizedDescription)")) }
            diagnostics.record("store-import", "skipped", ["store": input.store.id, "module": input.store.module, "reason": reason])
        }
        return failures
    }
    private static func validateOrphanCandidate(_ file: URL, fileManager: FileManager) throws {
        for suffix in [".schema11-candidate", ".schema11-rollback"] where file.path.hasSuffix(suffix) {
            let main = String(file.path.dropLast(suffix.count))
            guard fileManager.fileExists(atPath: main + ".schema11-migration.json") else { throw Failure.unsafeInput(file.path) }
        }
    }

    private static func canonicalSibling(_ url: URL) -> URL {
        // resolvingSymlinksInPath leaves a missing leaf unchanged on macOS,
        // including /var versus /private/var aliases. Resolve its existing
        // parent instead, then append the validated sibling name literally.
        let path = url.standardizedFileURL
        return path.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(path.lastPathComponent, isDirectory: false)
    }

    /// An interrupted legacy copy is restarted from its last committed active
    /// source (or the pre-exchange rollback). The old manifest/candidate/rollback
    /// stay untouched; all transformations happen on the private normalized
    /// snapshot. We never guess a future manifest or publish an unknown candidate.
    private static func recoverableLegacyInput(main: URL, manifest: URL, fileManager: FileManager) throws -> URL {
        let values = try manifest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
              object["manifestVersion"] as? Int == 1,
              let phase = object["phase"] as? String,
              ["prepared", "copied", "migrated", "validated", "switching", "switched", "retiring", "retained"].contains(phase),
              let source = object["sourcePath"] as? String,
              canonicalSibling(URL(fileURLWithPath: source)) == canonicalSibling(main),
              let candidate = object["candidatePath"] as? String,
              canonicalSibling(URL(fileURLWithPath: candidate)) == canonicalSibling(URL(fileURLWithPath: main.path + ".schema11-candidate")),
              let rollback = object["rollbackPath"] as? String,
              canonicalSibling(URL(fileURLWithPath: rollback)) == canonicalSibling(URL(fileURLWithPath: main.path + ".schema11-rollback")) else {
            throw Failure.unsafeInput(manifest.path)
        }
        if fileManager.fileExists(atPath: main.path) { return main }
        let saved = URL(fileURLWithPath: main.path + ".schema11-rollback")
        guard ["switching", "switched", "retiring"].contains(phase), fileManager.fileExists(atPath: saved.path) else {
            throw Failure.unsafeInput(manifest.path)
        }
        let savedValues = try saved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard savedValues.isRegularFile == true, savedValues.isSymbolicLink != true else { throw Failure.unsafeInput(saved.path) }
        return saved
    }

    static func synchronize(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
