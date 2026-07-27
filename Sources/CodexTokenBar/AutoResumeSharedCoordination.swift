import Foundation
import Dispatch

struct AutoResumeThreadLeaseRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let threadID: String
    let ownerID: String
    let acquiredAtUnix: Double
    let expiresAtUnix: Double
}

struct AutoResumeTriggerLedgerEntry: Codable, Equatable, Sendable {
    let threadID: String
    let ownerID: String
    let claimedAtUnix: Double
    var completedAtUnix: Double?
    var outcome: String
    var message: String?
}

struct AutoResumeTriggerLedgerFile: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var entries: [String: AutoResumeTriggerLedgerEntry] = [:]
}

enum AutoResumeCoordinationError: LocalizedError, Equatable, Sendable {
    case unableToCreateRoot(String)
    case ledgerLockTimedOut
    case invalidLedger
    case invalidLease

    var errorDescription: String? {
        switch self {
        case .unableToCreateRoot(let message):
            return "无法创建自动续跑协调目录：\(message)"
        case .ledgerLockTimedOut:
            return "另一个自动续跑进程正在更新触发记录"
        case .invalidLedger:
            return "自动续跑触发记录格式无效"
        case .invalidLease:
            return "自动续跑任务租约格式无效"
        }
    }
}

struct AutoResumeSharedDailyLimit: Equatable, Sendable {
    let dayStart: Date
    let maxRunsPerDay: Int
}

enum AutoResumeTriggerClaimResult: Equatable, Sendable {
    case claimed
    case duplicate
    case cooldown
    case dailyLimit
}

struct AutoResumeSharedCoordinator: Sendable {
    static let schemaVersion = 1
    static let defaultLeaseDuration: TimeInterval = 2 * 60
    static let leaseHeartbeatInterval: TimeInterval = 20

    let codexHome: URL
    let ownerID: String

    init(codexHome: URL, ownerID: String) {
        self.codexHome = codexHome.standardizedFileURL
        self.ownerID = ownerID
    }

    var rootDirectory: URL {
        codexHome
            .appendingPathComponent(".codex-token-bar-auto-resume", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    func acquireThreadLease(
        threadID: String,
        now: Date = Date(),
        duration: TimeInterval = Self.defaultLeaseDuration
    ) throws -> AutoResumeThreadLease? {
        try prepareDirectories()
        let leaseDirectory = leaseDirectoryURL(threadID: threadID)
        let fileManager = FileManager.default
        let leaseDuration = max(60, duration)
        let record = AutoResumeThreadLeaseRecord(
            schemaVersion: Self.schemaVersion,
            threadID: threadID,
            ownerID: ownerID,
            acquiredAtUnix: now.timeIntervalSince1970,
            expiresAtUnix: now.addingTimeInterval(leaseDuration).timeIntervalSince1970
        )

        for _ in 0..<3 {
            do {
                try fileManager.createDirectory(
                    at: leaseDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                do {
                    try writeJSON(record, to: leaseRecordURL(leaseDirectory: leaseDirectory))
                    guard try renew(
                        leaseDirectory: leaseDirectory,
                        record: record,
                        duration: leaseDuration,
                        now: now
                    ) else {
                        throw AutoResumeCoordinationError.invalidLease
                    }
                    return AutoResumeThreadLease(
                        coordinator: self,
                        leaseDirectory: leaseDirectory,
                        record: record,
                        renewalDuration: leaseDuration
                    )
                } catch {
                    try? fileManager.removeItem(at: leaseDirectory)
                    throw error
                }
            } catch {
                guard fileManager.fileExists(atPath: leaseDirectory.path) else {
                    throw error
                }
                guard leaseIsExpired(at: leaseDirectory, now: now) else {
                    return nil
                }
                let tombstone = leaseDirectory
                    .deletingLastPathComponent()
                    .appendingPathComponent(".expired-\(UUID().uuidString)", isDirectory: true)
                do {
                    try fileManager.moveItem(at: leaseDirectory, to: tombstone)
                    try? fileManager.removeItem(at: tombstone)
                } catch {
                    continue
                }
            }
        }
        return nil
    }

    func claimTrigger(
        key: String,
        threadID: String,
        minimumInterval: TimeInterval,
        now: Date = Date()
    ) throws -> Bool {
        try claimTrigger(
            key: key,
            threadID: threadID,
            minimumInterval: minimumInterval,
            dailyLimit: nil,
            now: now
        ) == .claimed
    }

    func claimTrigger(
        key: String,
        threadID: String,
        minimumInterval: TimeInterval,
        dailyLimit: AutoResumeSharedDailyLimit?,
        now: Date = Date()
    ) throws -> AutoResumeTriggerClaimResult {
        try withLedgerLock {
            var ledger = try readLedger()
            let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970
            ledger.entries = ledger.entries.filter { $0.value.claimedAtUnix >= cutoff }
            guard ledger.entries[key] == nil else { return .duplicate }
            let latestClaimForThread = ledger.entries.values
                .filter { $0.threadID == threadID }
                .map { $0.completedAtUnix ?? $0.claimedAtUnix }
                .max()
            if let latestClaimForThread,
               now.timeIntervalSince1970 - latestClaimForThread < max(0, minimumInterval) {
                return .cooldown
            }
            if let dailyLimit {
                let dayStartUnix = dailyLimit.dayStart.timeIntervalSince1970
                let automaticRunsToday = ledger.entries.filter { key, entry in
                    !key.hasPrefix("manual:")
                        && entry.claimedAtUnix >= dayStartUnix
                        && entry.outcome != "skipped"
                        && entry.outcome != "satisfied"
                }.count
                if automaticRunsToday >= max(0, dailyLimit.maxRunsPerDay) {
                    return .dailyLimit
                }
            }
            ledger.entries[key] = AutoResumeTriggerLedgerEntry(
                threadID: threadID,
                ownerID: ownerID,
                claimedAtUnix: now.timeIntervalSince1970,
                completedAtUnix: nil,
                outcome: "claimed",
                message: nil
            )
            try writeJSON(ledger, to: ledgerURL)
            return .claimed
        }
    }

    func completeTrigger(
        key: String,
        outcome: String,
        message: String?,
        now: Date = Date()
    ) throws {
        try withLedgerLock {
            var ledger = try readLedger()
            guard var entry = ledger.entries[key], entry.ownerID == ownerID else { return }
            entry.completedAtUnix = now.timeIntervalSince1970
            entry.outcome = outcome
            entry.message = message
            ledger.entries[key] = entry
            try writeJSON(ledger, to: ledgerURL)
        }
    }

    fileprivate func release(
        leaseDirectory: URL,
        record: AutoResumeThreadLeaseRecord
    ) {
        let fileManager = FileManager.default
        guard let current = try? readJSON(
            AutoResumeThreadLeaseRecord.self,
            from: leaseRecordURL(leaseDirectory: leaseDirectory)
        ), current.ownerID == record.ownerID else {
            return
        }

        let tombstone = leaseDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(".released-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.moveItem(at: leaseDirectory, to: tombstone)
            guard let moved = try? readJSON(
                AutoResumeThreadLeaseRecord.self,
                from: leaseRecordURL(leaseDirectory: tombstone)
            ), moved.ownerID == record.ownerID else {
                if !fileManager.fileExists(atPath: leaseDirectory.path) {
                    try? fileManager.moveItem(at: tombstone, to: leaseDirectory)
                }
                return
            }
            try? fileManager.removeItem(at: tombstone)
        } catch {
            return
        }
    }

    fileprivate func renew(
        leaseDirectory: URL,
        record: AutoResumeThreadLeaseRecord,
        duration: TimeInterval,
        now: Date = Date()
    ) throws -> Bool {
        guard let current = try? readJSON(
            AutoResumeThreadLeaseRecord.self,
            from: leaseRecordURL(leaseDirectory: leaseDirectory)
        ), current.ownerID == record.ownerID else {
            return false
        }
        let renewed = AutoResumeThreadLeaseRecord(
            schemaVersion: current.schemaVersion,
            threadID: current.threadID,
            ownerID: current.ownerID,
            acquiredAtUnix: current.acquiredAtUnix,
            expiresAtUnix: now.addingTimeInterval(max(60, duration)).timeIntervalSince1970
        )
        try writeJSON(
            renewed,
            to: leaseHeartbeatURL(leaseDirectory: leaseDirectory, ownerID: current.ownerID)
        )
        return true
    }

    private var leasesDirectory: URL {
        rootDirectory.appendingPathComponent("leases", isDirectory: true)
    }

    private var ledgerURL: URL {
        rootDirectory.appendingPathComponent("trigger-ledger.json")
    }

    private var ledgerFileLockURL: URL {
        rootDirectory.appendingPathComponent("trigger-ledger.flock")
    }

    private func prepareDirectories() throws {
        do {
            try FileManager.default.createDirectory(
                at: leasesDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw AutoResumeCoordinationError.unableToCreateRoot(error.localizedDescription)
        }
    }

    private func leaseDirectoryURL(threadID: String) -> URL {
        leasesDirectory.appendingPathComponent(
            "thread-\(Self.stableThreadKey(threadID))",
            isDirectory: true
        )
    }

    private func leaseRecordURL(leaseDirectory: URL) -> URL {
        leaseDirectory.appendingPathComponent("lease.json")
    }

    private func leaseHeartbeatURL(leaseDirectory: URL, ownerID: String) -> URL {
        leaseDirectory.appendingPathComponent(
            "heartbeat-\(Self.stableThreadKey(ownerID)).json"
        )
    }

    private func leaseIsExpired(at leaseDirectory: URL, now: Date) -> Bool {
        guard let record = try? readJSON(
            AutoResumeThreadLeaseRecord.self,
            from: leaseRecordURL(leaseDirectory: leaseDirectory)
        ) else {
            return directoryIsStale(leaseDirectory, now: now, threshold: 60)
        }
        let heartbeat = try? readJSON(
            AutoResumeThreadLeaseRecord.self,
            from: leaseHeartbeatURL(leaseDirectory: leaseDirectory, ownerID: record.ownerID)
        )
        let heartbeatExpiry = heartbeat.flatMap { value -> TimeInterval? in
            guard value.ownerID == record.ownerID,
                  value.threadID == record.threadID,
                  value.acquiredAtUnix == record.acquiredAtUnix else {
                return nil
            }
            return value.expiresAtUnix
        }
        return max(record.expiresAtUnix, heartbeatExpiry ?? record.expiresAtUnix)
            <= now.timeIntervalSince1970
    }

    func withLedgerLock<T>(
        waitTimeout: TimeInterval = 2,
        _ body: () throws -> T
    ) throws -> T {
        try prepareDirectories()
        let timeoutNanos = UInt64(max(0, waitTimeout) * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanos
        while true {
            do {
                let lock = try CodexCrossProcessFileLock(
                    url: ledgerFileLockURL,
                    label: "自动续跑触发记录"
                )
                defer { lock.release() }
                return try body()
            } catch {
                guard CodexCrossProcessFileLock.isContention(error) else {
                    throw error
                }
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw AutoResumeCoordinationError.ledgerLockTimedOut
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
    }

    private func readLedger() throws -> AutoResumeTriggerLedgerFile {
        guard FileManager.default.fileExists(atPath: ledgerURL.path) else {
            return AutoResumeTriggerLedgerFile()
        }
        do {
            let ledger = try readJSON(AutoResumeTriggerLedgerFile.self, from: ledgerURL)
            guard ledger.schemaVersion == Self.schemaVersion else {
                throw AutoResumeCoordinationError.invalidLedger
            }
            return ledger
        } catch let error as AutoResumeCoordinationError {
            throw error
        } catch {
            throw AutoResumeCoordinationError.invalidLedger
        }
    }

    private func directoryIsStale(_ url: URL, now: Date, threshold: TimeInterval) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else {
            return false
        }
        return now.timeIntervalSince(modified) >= threshold
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func stableThreadKey(_ threadID: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in threadID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

final class AutoResumeThreadLease: @unchecked Sendable {
    private let lock = NSLock()
    private let coordinator: AutoResumeSharedCoordinator
    private let leaseDirectory: URL
    private let record: AutoResumeThreadLeaseRecord
    private let renewalDuration: TimeInterval
    private var heartbeat: DispatchSourceTimer?
    private var released = false

    fileprivate init(
        coordinator: AutoResumeSharedCoordinator,
        leaseDirectory: URL,
        record: AutoResumeThreadLeaseRecord,
        renewalDuration: TimeInterval
    ) {
        self.coordinator = coordinator
        self.leaseDirectory = leaseDirectory
        self.record = record
        self.renewalDuration = renewalDuration
        startHeartbeat()
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "CodexTokenBar.AutoResumeLeaseHeartbeat")
        )
        timer.schedule(
            deadline: .now() + AutoResumeSharedCoordinator.leaseHeartbeatInterval,
            repeating: AutoResumeSharedCoordinator.leaseHeartbeatInterval,
            leeway: .seconds(2)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                if try !self.performRenew() {
                    self.release()
                }
            } catch {
                // A transient filesystem failure must not voluntarily surrender the lease.
                // The next heartbeat retries; expiry still bounds recovery after a crash.
            }
        }
        lock.withLock {
            heartbeat = timer
        }
        timer.resume()
    }

    @discardableResult
    func renewNow(now: Date = Date()) -> Bool {
        (try? performRenew(now: now)) ?? false
    }

    private func performRenew(now: Date = Date()) throws -> Bool {
        let shouldRenew = lock.withLock { !released }
        guard shouldRenew else { return false }
        return try coordinator.renew(
            leaseDirectory: leaseDirectory,
            record: record,
            duration: renewalDuration,
            now: now
        )
    }

    func release() {
        let (shouldRelease, timer) = lock.withLock {
            guard !released else { return (false, nil as DispatchSourceTimer?) }
            released = true
            let timer = heartbeat
            heartbeat = nil
            return (true, timer)
        }
        timer?.cancel()
        if shouldRelease {
            coordinator.release(leaseDirectory: leaseDirectory, record: record)
        }
    }

    deinit {
        release()
    }
}
