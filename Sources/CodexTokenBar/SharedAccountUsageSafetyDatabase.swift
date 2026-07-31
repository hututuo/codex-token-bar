import Darwin
import Foundation
import SQLite3

/// Crash-durable storage for shared-account safety state. UserDefaults remains
/// available only for migration/tests; production uses this WAL database with
/// FULL synchronous commits so a successful write is not merely a
/// CFPreferences cache readback.
final class SharedAccountUsageSafetyDatabase: @unchecked Sendable {
    static let shared = SharedAccountUsageSafetyDatabase(
        claimsObserverOwnership: true
    )
    let processInstanceID = UUID()
    static let didChangeNotification = Notification.Name(
        "com.codextokenbar.shared-account-safety-did-change"
    )

    enum RecordKind: String, CaseIterable {
        case highWatermarks = "high-watermarks-v06"
        case segments = "segments-v08"
        case preciseContinuity = "precise-continuity-v03"
    }

    struct RecoveryResult: Equatable, Sendable {
        let quarantineDirectory: URL
    }

    private let databaseURL: URL
    private let sentinelURL: URL
    private let lockURL: URL
    private let observerOwnerLockURL: URL
    private let recoveryLockURL: URL
    private let recoveryMarkerURL: URL
    private let fileManager: FileManager
    private let observerOwnershipRequired: Bool
    private let stateLock = NSLock()
    private var driver: SQLiteDatabaseDriver?
    private var observerOwnerLock: CodexCrossProcessFileLock?
    private var observerTakeoverInProgress = false
    private var healthy = true

    var persistenceHealthy: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return healthy
    }

    var recoveryRequired: Bool { !persistenceHealthy }

    /// Typed stores call this when a syntactically valid JSON object cannot be
    /// decoded as the schema for its initialized record kind. Treating that as
    /// ordinary emptiness would resurrect a false baseline, so the entire
    /// generation remains failed closed until explicit quarantine recovery.
    func reportCorruptPayload(_ kind: RecordKind) {
        _ = kind
        markUnhealthy()
    }

    /// Migration evidence that cannot be decoded or durably retired is just
    /// as unsafe as a corrupt SQLite record. Expose the same explicit recovery
    /// path instead of leaving typed stores unavailable while the database
    /// itself still advertises a healthy generation.
    func reportRecoveryRequired() {
        markUnhealthy()
    }

    var isObserverOwner: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !observerOwnershipRequired || observerOwnerLock != nil
    }

    init(
        url: URL? = nil,
        fileManager: FileManager = .default,
        claimsObserverOwnership: Bool = false
    ) {
        let resolvedDatabaseURL: URL
        if let url {
            resolvedDatabaseURL = url
        } else if let support = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            let directory = support.appendingPathComponent(
                "CodexTokenBar",
                isDirectory: true
            )
            try? fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            resolvedDatabaseURL = directory.appendingPathComponent(
                "shared-account-usage-safety.sqlite"
            )
        } else {
            // Keep a deterministic unusable URL so a failed Application Support
            // lookup stays fail-closed and can never fall back to UserDefaults.
            resolvedDatabaseURL = URL(fileURLWithPath: "/dev/null/codex-token-bar-safety.sqlite")
        }
        databaseURL = resolvedDatabaseURL
        sentinelURL = resolvedDatabaseURL.appendingPathExtension("initialized")
        lockURL = resolvedDatabaseURL.appendingPathExtension("lock")
        observerOwnerLockURL = resolvedDatabaseURL.appendingPathExtension("observer-owner.lock")
        recoveryLockURL = resolvedDatabaseURL.appendingPathExtension("recovery.lock")
        recoveryMarkerURL = resolvedDatabaseURL.appendingPathExtension("recovery-required")
        self.fileManager = fileManager
        observerOwnershipRequired = claimsObserverOwnership

        var resolvedDriver: SQLiteDatabaseDriver?
        var resolvedObserverOwnerLock: CodexCrossProcessFileLock?
        var initializationSucceeded = false
        do {
            if fileManager.fileExists(atPath: recoveryMarkerURL.path) {
                // A previous quarantine/replacement did not reach its durable
                // commit point. Even if a database file happens to be present,
                // its generation is not proven complete and must not be opened
                // as a healthy empty baseline.
                throw SharedAccountUsageSafetyDatabaseError.incompleteRecovery
            }
            let databaseExisted = fileManager.fileExists(atPath: databaseURL.path)
            if !databaseExisted,
               fileManager.fileExists(atPath: sentinelURL.path) {
                // A separately fsynced sentinel with no database means durable
                // attribution state was lost. Recreating an empty ready
                // baseline could falsely assign the missing local amount to
                // another user, so fail closed instead.
                throw SharedAccountUsageSafetyDatabaseError.missingDatabaseAfterInitialization
            }
            let setupDriver = SQLiteDatabaseDriver(
                url: databaseURL,
                createsFileIfMissing: true,
                busyTimeoutMilliseconds: 5_000,
                fileManager: fileManager
            )
            try Self.prepareSchema(using: setupDriver)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: databaseURL.path
            )
            if !fileManager.fileExists(atPath: sentinelURL.path) {
                try Data("codex-token-bar-shared-account-safety-v1\n".utf8)
                    .write(to: sentinelURL, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: sentinelURL.path
                )
                let handle = try FileHandle(forWritingTo: sentinelURL)
                try handle.synchronize()
                try handle.close()
                try Self.synchronizeDirectory(at: databaseURL.deletingLastPathComponent())
            }
            resolvedDriver = SQLiteDatabaseDriver(
                url: databaseURL,
                createsFileIfMissing: false,
                busyTimeoutMilliseconds: 5_000,
                fileManager: fileManager
            )
            if claimsObserverOwnership {
                resolvedObserverOwnerLock = try? CodexCrossProcessFileLock(
                    url: observerOwnerLockURL,
                    label: "共享账号观察者"
                )
            }
            initializationSucceeded = true
        } catch {
            resolvedDriver = nil
            resolvedObserverOwnerLock = nil
            initializationSucceeded = false
        }
        driver = resolvedDriver
        observerOwnerLock = resolvedObserverOwnerLock
        healthy = initializationSucceeded
    }

    func load(_ kind: RecordKind) -> Data? {
        guard let recoveryGate = acquireRecoveryGate(waitingUpTo: 2) else {
            markUnhealthy()
            return nil
        }
        defer { recoveryGate.release() }
        guard let driver = healthyDriver(), backingStoreExists() else {
            markUnhealthy()
            return nil
        }
        do {
            let value = try driver.withConnection { connection -> Data? in
                let payload = try connection.readRows(
                    "SELECT payload FROM safety_records WHERE kind = ? LIMIT 1;",
                    bindings: [.text(kind.rawValue)]
                ) { row in row.data(0) }.first ?? nil
                let initialized = try connection.readRows(
                    "SELECT 1 FROM safety_record_state WHERE kind = ? LIMIT 1;",
                    bindings: [.text(kind.rawValue)]
                ) { row in row.int(0) }.first != nil
                if payload == nil, initialized {
                    throw SharedAccountUsageSafetyDatabaseError.missingInitializedRecord
                }
                if let payload {
                    try Self.validatePayload(payload)
                }
                return payload
            }
            return value
        } catch {
            markUnhealthy()
            return nil
        }
    }

    @discardableResult
    func store(_ data: Data, as kind: RecordKind) -> Bool {
        guard (try? Self.validatePayload(data)) != nil else {
            markUnhealthy()
            return false
        }
        return mutate(kind) { _ in (data, true) } ?? false
    }

    /// Serializes cross-process read-modify-write through SQLite's immediate
    /// transaction and commits the transformed payload with synchronous=FULL.
    func mutate<Result>(
        _ kind: RecordKind,
        _ body: (Data?) throws -> (Data?, Result)
    ) -> Result? {
        guard let recoveryGate = acquireRecoveryGate(waitingUpTo: 2) else {
            markUnhealthy()
            return nil
        }
        defer { recoveryGate.release() }
        guard let driver = healthyDriver(), backingStoreExists() else {
            markUnhealthy()
            return nil
        }
        do {
            let (result, didChange) = try driver.withConnection { connection in
                try connection.execute("PRAGMA synchronous=FULL;")
                return try connection.transaction { transaction in
                    let existing = try transaction.readRows(
                        "SELECT payload FROM safety_records WHERE kind = ? LIMIT 1;",
                        bindings: [.text(kind.rawValue)]
                    ) { row in row.data(0) }.first ?? nil
                    let initialized = try transaction.readRows(
                        "SELECT 1 FROM safety_record_state WHERE kind = ? LIMIT 1;",
                        bindings: [.text(kind.rawValue)]
                    ) { row in row.int(0) }.first != nil
                    if existing == nil, initialized {
                        throw SharedAccountUsageSafetyDatabaseError.missingInitializedRecord
                    }
                    if let existing {
                        try Self.validatePayload(existing)
                    }
                    let (next, result) = try body(existing)
                    if let next {
                        try Self.validatePayload(next)
                    }
                    let didChange = next != existing
                    if let next, next != existing {
                        try transaction.execute(
                            """
                            INSERT INTO safety_records(kind, payload, committed_at)
                            VALUES (?, ?, ?)
                            ON CONFLICT(kind) DO UPDATE SET
                                payload = excluded.payload,
                                committed_at = excluded.committed_at;
                            """,
                            bindings: [
                                .text(kind.rawValue),
                                .blob(next),
                                .double(Date().timeIntervalSince1970),
                            ]
                        )
                        try transaction.execute(
                            """
                            INSERT OR IGNORE INTO safety_record_state(kind, initialized_at)
                            VALUES (?, ?);
                            """,
                            bindings: [
                                .text(kind.rawValue),
                                .double(Date().timeIntervalSince1970),
                            ]
                        )
                    } else if next == nil, existing != nil {
                        try transaction.execute(
                            "DELETE FROM safety_records WHERE kind = ?;",
                            bindings: [.text(kind.rawValue)]
                        )
                    }
                    return (result, didChange)
                }
            }
            if didChange {
                // Publish only after the generation gate is open. Same-process
                // observers immediately reload this record; retaining the gate
                // across notification delivery would make that safe reload
                // look like storage contention.
                recoveryGate.release()
                DistributedNotificationCenter.default().post(
                    name: Self.didChangeNotification,
                    object: kind.rawValue,
                    userInfo: nil
                )
            }
            return result
        } catch {
            markUnhealthy()
            return nil
        }
    }

    /// A non-owner instance may outlive the previous owner. Retry the advisory
    /// owner lock on normal refresh/foreground recovery instead of freezing the
    /// process in fast-only mode until it is relaunched.
    ///
    /// - Returns: `true` only when this call newly acquired ownership.
    @discardableResult
    func attemptObserverTakeover() -> Bool {
        attemptObserverTakeover(allowUnhealthyStorage: false)
    }

    private func attemptObserverTakeover(
        allowUnhealthyStorage: Bool
    ) -> Bool {
        guard observerOwnershipRequired,
              allowUnhealthyStorage || persistenceHealthy else { return false }
        stateLock.lock()
        if observerOwnerLock != nil || observerTakeoverInProgress {
            stateLock.unlock()
            return false
        }
        observerTakeoverInProgress = true
        stateLock.unlock()

        let candidate = try? CodexCrossProcessFileLock(
            url: observerOwnerLockURL,
            label: "共享账号观察者"
        )

        stateLock.lock()
        observerTakeoverInProgress = false
        guard observerOwnerLock == nil, let candidate else {
            stateLock.unlock()
            candidate?.release()
            return false
        }
        observerOwnerLock = candidate
        stateLock.unlock()
        return true
    }

    /// Explicit technical recovery for a safety ledger that has already failed
    /// closed. The damaged SQLite family is preserved in a quarantine folder;
    /// a fully initialized empty generation is assembled off to the side and
    /// atomically renamed into place. Every record kind is seeded, so removed
    /// UserDefaults migration payloads can never be imported back as ready
    /// attribution state.
    func rebuildEmptySafetyBaseline(
        preciseContinuityPayload: Data,
        defaults: UserDefaults = .standard,
        retiredUserDefaultsKeys: [String]
    ) -> RecoveryResult? {
        guard (try? Self.validatePayload(preciseContinuityPayload)) != nil else {
            markUnhealthy()
            return nil
        }
        if observerOwnershipRequired,
           !isObserverOwner,
           !attemptObserverTakeover(allowUnhealthyStorage: true) {
            return nil
        }

        let safetyLock: CodexCrossProcessFileLock
        guard let acquiredSafetyLock = acquireCrossProcessLock(waitingUpTo: 2) else {
            return nil
        }
        safetyLock = acquiredSafetyLock
        guard let recoveryLock = acquireRecoveryGate(waitingUpTo: 2) else {
            safetyLock.release()
            return nil
        }
        defer {
            recoveryLock.release()
            safetyLock.release()
        }

        markUnhealthy(clearDriver: true)
        let parent = databaseURL.deletingLastPathComponent()
        let quarantine = parent.appendingPathComponent(
            "shared-account-usage-safety-quarantine-\(Self.quarantineTimestamp())-\(UUID().uuidString)",
            isDirectory: true
        )
        let staging = parent.appendingPathComponent(
            ".shared-account-usage-safety-rebuilding-\(UUID().uuidString).sqlite"
        )
        do {
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.createDirectory(
                at: quarantine,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            // Build and fsync the complete replacement before touching the
            // damaged generation. The later rename publishes one complete
            // file rather than exposing a half-initialized database.
            let stagingDriver = SQLiteDatabaseDriver(
                url: staging,
                createsFileIfMissing: true,
                busyTimeoutMilliseconds: 5_000,
                fileManager: fileManager
            )
            try Self.prepareSchema(using: stagingDriver, journalMode: "DELETE")
            let emptyObject = Data("{}".utf8)
            try stagingDriver.withConnection { connection in
                try connection.execute("PRAGMA synchronous=FULL;")
                try connection.transaction { transaction in
                    let committedAt = Date().timeIntervalSince1970
                    for kind in RecordKind.allCases {
                        let payload = kind == .preciseContinuity
                            ? preciseContinuityPayload
                            : emptyObject
                        try transaction.execute(
                            """
                            INSERT INTO safety_records(kind, payload, committed_at)
                            VALUES (?, ?, ?);
                            """,
                            bindings: [
                                .text(kind.rawValue),
                                .blob(payload),
                                .double(committedAt),
                            ]
                        )
                        try transaction.execute(
                            """
                            INSERT INTO safety_record_state(kind, initialized_at)
                            VALUES (?, ?);
                            """,
                            bindings: [
                                .text(kind.rawValue),
                                .double(committedAt),
                            ]
                        )
                    }
                }
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: staging.path
            )
            try Self.synchronizeFile(at: staging)

            // This marker is the crash boundary for the exchange. It remains
            // beside the active database until replacement verification and
            // UserDefaults retirement both complete. A restart anywhere in
            // between therefore stays failed closed instead of silently
            // constructing a fresh healthy database.
            try writeRecoveryMarker()
            try Self.synchronizeDirectory(at: parent)

            if fileManager.fileExists(atPath: sentinelURL.path) {
                try fileManager.copyItem(
                    at: sentinelURL,
                    to: quarantine.appendingPathComponent(sentinelURL.lastPathComponent)
                )
            }
            for source in databaseFamilyExcludingSentinel()
            where fileManager.fileExists(atPath: source.path) {
                try fileManager.moveItem(
                    at: source,
                    to: quarantine.appendingPathComponent(source.lastPathComponent)
                )
            }
            try fileManager.moveItem(at: staging, to: databaseURL)
            try Self.synchronizeDirectory(at: parent)
            try writeSentinel()

            let recoveredDriver = SQLiteDatabaseDriver(
                url: databaseURL,
                createsFileIfMissing: false,
                busyTimeoutMilliseconds: 5_000,
                fileManager: fileManager
            )
            try Self.prepareSchema(using: recoveredDriver)
            try Self.verifyInitializedGeneration(
                using: recoveredDriver,
                preciseContinuityPayload: preciseContinuityPayload
            )
            guard retireUserDefaults(
                defaults,
                keys: retiredUserDefaultsKeys
            ) else {
                throw SharedAccountUsageSafetyDatabaseError.userDefaultsRetirementFailed
            }
            try fileManager.removeItem(at: recoveryMarkerURL)
            try Self.synchronizeDirectory(at: parent)
            stateLock.lock()
            driver = recoveredDriver
            healthy = true
            stateLock.unlock()
            // Observers reload the newly published generation. Let them enter
            // before sending invalidations; the deferred releases remain safe
            // because CodexCrossProcessFileLock.release is idempotent.
            recoveryLock.release()
            safetyLock.release()
            for kind in RecordKind.allCases {
                DistributedNotificationCenter.default().post(
                    name: Self.didChangeNotification,
                    object: kind.rawValue,
                    userInfo: nil
                )
            }
            return RecoveryResult(quarantineDirectory: quarantine)
        } catch {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: URL(fileURLWithPath: staging.path + "-journal"))
            // Deliberately keep a published recovery marker. If the failure
            // happened before the marker was created there is no exchange to
            // recover from; an empty quarantine directory can be removed.
            if !fileManager.fileExists(atPath: recoveryMarkerURL.path),
               (try? fileManager.contentsOfDirectory(atPath: quarantine.path).isEmpty) == true {
                try? fileManager.removeItem(at: quarantine)
            }
            markUnhealthy(clearDriver: true)
            return nil
        }
    }

    func acquireCrossProcessLock(
        waitingUpTo timeout: TimeInterval = 0
    ) -> CodexCrossProcessFileLock? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            do {
                let lock = try CodexCrossProcessFileLock(
                    url: lockURL,
                    label: "共享账号安全账本"
                )
                return lock
            } catch {
                guard CodexCrossProcessFileLock.isContention(error),
                      Date() < deadline else {
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    private func acquireRecoveryGate(
        waitingUpTo timeout: TimeInterval
    ) -> CodexCrossProcessFileLock? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            do {
                return try CodexCrossProcessFileLock(
                    url: recoveryLockURL,
                    label: "共享账号记录换代"
                )
            } catch {
                guard CodexCrossProcessFileLock.isContention(error),
                      Date() < deadline else {
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    private func healthyDriver() -> SQLiteDatabaseDriver? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return healthy ? driver : nil
    }

    private func markUnhealthy(clearDriver: Bool = false) {
        stateLock.lock()
        healthy = false
        if clearDriver {
            driver = nil
        }
        stateLock.unlock()
    }

    private func backingStoreExists() -> Bool {
        fileManager.fileExists(atPath: databaseURL.path)
            && fileManager.fileExists(atPath: sentinelURL.path)
            && !fileManager.fileExists(atPath: recoveryMarkerURL.path)
    }

    private func databaseFamilyExcludingSentinel() -> [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
            URL(fileURLWithPath: databaseURL.path + "-journal"),
        ]
    }

    private func retireUserDefaults(_ defaults: UserDefaults, keys: [String]) -> Bool {
        for key in Set(keys) where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            guard defaults.object(forKey: key) == nil else { return false }
        }
        return true
    }

    private func writeSentinel() throws {
        try Data("codex-token-bar-shared-account-safety-v1\n".utf8)
            .write(to: sentinelURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sentinelURL.path
        )
        try Self.synchronizeFile(at: sentinelURL)
    }

    private func writeRecoveryMarker() throws {
        try Data("codex-token-bar-shared-account-safety-recovery-v1\n".utf8)
            .write(to: recoveryMarkerURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: recoveryMarkerURL.path
        )
        try Self.synchronizeFile(at: recoveryMarkerURL)
    }

    private static func prepareSchema(
        using driver: SQLiteDatabaseDriver,
        journalMode: String = "WAL"
    ) throws {
        try driver.withConnection { connection in
            try connection.execute("PRAGMA journal_mode=\(journalMode);")
            try connection.execute("PRAGMA synchronous=FULL;")
            try connection.execute("PRAGMA foreign_keys=ON;")
            try connection.execute(
                """
                CREATE TABLE IF NOT EXISTS safety_records (
                    kind TEXT PRIMARY KEY,
                    payload BLOB NOT NULL,
                    committed_at REAL NOT NULL
                ) WITHOUT ROWID;
                """
            )
            try connection.execute(
                """
                CREATE TABLE IF NOT EXISTS safety_record_state (
                    kind TEXT PRIMARY KEY,
                    initialized_at REAL NOT NULL
                ) WITHOUT ROWID;
                """
            )
            try connection.execute(
                """
                INSERT OR IGNORE INTO safety_record_state(kind, initialized_at)
                SELECT kind, committed_at FROM safety_records;
                """
            )
        }
    }

    private static func validatePayload(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard object is [String: Any] else {
            throw SharedAccountUsageSafetyDatabaseError.corruptPayload
        }
    }

    private static func verifyInitializedGeneration(
        using driver: SQLiteDatabaseDriver,
        preciseContinuityPayload: Data
    ) throws {
        try driver.withConnection { connection in
            for kind in RecordKind.allCases {
                let payload = try connection.readRows(
                    "SELECT payload FROM safety_records WHERE kind = ? LIMIT 1;",
                    bindings: [.text(kind.rawValue)]
                ) { $0.data(0) }.first ?? nil
                guard let payload else {
                    throw SharedAccountUsageSafetyDatabaseError.missingInitializedRecord
                }
                try validatePayload(payload)
                if kind == .preciseContinuity,
                   payload != preciseContinuityPayload {
                    throw SharedAccountUsageSafetyDatabaseError.recoveryVerificationFailed
                }
                let initialized = try connection.readRows(
                    "SELECT 1 FROM safety_record_state WHERE kind = ? LIMIT 1;",
                    bindings: [.text(kind.rawValue)]
                ) { $0.int(0) }.first != nil
                guard initialized else {
                    throw SharedAccountUsageSafetyDatabaseError.missingInitializedRecord
                }
            }
        }
    }

    private static func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw SharedAccountUsageSafetyDatabaseError.directorySynchronizationFailed
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw SharedAccountUsageSafetyDatabaseError.directorySynchronizationFailed
        }
    }

    private static func quarantineTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private enum SharedAccountUsageSafetyDatabaseError: Error {
    case incompleteRecovery
    case missingDatabaseAfterInitialization
    case missingInitializedRecord
    case corruptPayload
    case userDefaultsRetirementFailed
    case recoveryVerificationFailed
    case directorySynchronizationFailed
}
