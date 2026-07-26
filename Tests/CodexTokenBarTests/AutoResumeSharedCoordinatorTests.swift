import Foundation
import XCTest
@testable import CodexTokenBar

final class AutoResumeSharedCoordinatorTests: XCTestCase {
    func testRenewableLeaseUsesShortCrashRecoveryWindow() {
        XCTAssertEqual(CodexAppServerClient.defaultTurnTimeout, 6 * 60 * 60)
        XCTAssertEqual(AutoResumeSharedCoordinator.defaultLeaseDuration, 2 * 60)
        XCTAssertEqual(AutoResumeSharedCoordinator.leaseHeartbeatInterval, 20)
        XCTAssertGreaterThan(
            AutoResumeSharedCoordinator.defaultLeaseDuration,
            AutoResumeSharedCoordinator.leaseHeartbeatInterval * 3
        )
    }

    func testThreadLeaseIsExclusiveAcrossOwnersAndReleaseMakesItAvailable() throws {
        let home = try temporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = AutoResumeSharedCoordinator(codexHome: home, ownerID: "swift")
        let second = AutoResumeSharedCoordinator(codexHome: home, ownerID: "tauri")
        let now = Date(timeIntervalSince1970: 10_000)

        let firstLease = try XCTUnwrap(first.acquireThreadLease(
            threadID: "thread-exclusive",
            now: now
        ))
        XCTAssertNil(try second.acquireThreadLease(
            threadID: "thread-exclusive",
            now: now
        ))

        firstLease.release()
        let secondLease = try XCTUnwrap(second.acquireThreadLease(
            threadID: "thread-exclusive",
            now: now
        ))
        secondLease.release()
    }

    func testExpiredThreadLeaseCanBeRecoveredByAnotherOwner() throws {
        let home = try temporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = AutoResumeSharedCoordinator(codexHome: home, ownerID: "swift")
        let second = AutoResumeSharedCoordinator(codexHome: home, ownerID: "tauri")
        let acquiredAt = Date(timeIntervalSince1970: 20_000)

        let staleLease = try XCTUnwrap(first.acquireThreadLease(
            threadID: "thread-expired",
            now: acquiredAt,
            duration: 60
        ))
        let recoveredLease = try XCTUnwrap(second.acquireThreadLease(
            threadID: "thread-expired",
            now: acquiredAt.addingTimeInterval(61),
            duration: 60
        ))

        staleLease.release()
        XCTAssertNil(try first.acquireThreadLease(
            threadID: "thread-expired",
            now: acquiredAt.addingTimeInterval(62)
        ))
        recoveredLease.release()
    }

    func testHeartbeatRenewalKeepsLeaseExclusiveAndStillAllowsRecoveryAfterExpiry() throws {
        let home = try temporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = AutoResumeSharedCoordinator(codexHome: home, ownerID: "swift")
        let second = AutoResumeSharedCoordinator(codexHome: home, ownerID: "tauri")
        let acquiredAt = Date(timeIntervalSince1970: 25_000)

        let lease = try XCTUnwrap(first.acquireThreadLease(
            threadID: "thread-renewed",
            now: acquiredAt,
            duration: 60
        ))
        XCTAssertTrue(lease.renewNow(now: acquiredAt.addingTimeInterval(50)))
        XCTAssertNil(try second.acquireThreadLease(
            threadID: "thread-renewed",
            now: acquiredAt.addingTimeInterval(61),
            duration: 60
        ))
        let recovered = try XCTUnwrap(second.acquireThreadLease(
            threadID: "thread-renewed",
            now: acquiredAt.addingTimeInterval(111),
            duration: 60
        ))

        lease.release()
        recovered.release()
    }

    func testTriggerKeyIsClaimedAtMostOnceAcrossOwners() throws {
        let home = try temporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let swift = AutoResumeSharedCoordinator(codexHome: home, ownerID: "swift")
        let tauri = AutoResumeSharedCoordinator(codexHome: home, ownerID: "tauri")
        let now = Date(timeIntervalSince1970: 30_000)
        let key = "daily:thread-dedup:2026-07-16:0900"

        XCTAssertTrue(try swift.claimTrigger(
            key: key,
            threadID: "thread-dedup",
            minimumInterval: 0,
            now: now
        ))
        XCTAssertFalse(try tauri.claimTrigger(
            key: key,
            threadID: "thread-dedup",
            minimumInterval: 0,
            now: now.addingTimeInterval(1)
        ))
    }

    func testStolenLedgerLockAbortsWriteBackAndKeepsTheThiefsLock() throws {
        let home = try temporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let coordinator = AutoResumeSharedCoordinator(codexHome: home, ownerID: "victim")
        let fileManager = FileManager.default
        let lockURL = coordinator.rootDirectory
            .appendingPathComponent("trigger-ledger.lock", isDirectory: true)

        let heldAfterTheft: Bool = try coordinator.withLedgerLock { lock in
            XCTAssertTrue(lock.stillHeld())
            // 模拟另一进程 stale-break：把持有中的锁目录搬走清理，再以
            // 自己的 owner 标记重建（与抢占路径同一动作序列）。
            let stale = coordinator.rootDirectory
                .appendingPathComponent(".stale-ledger-lock-test", isDirectory: true)
            try fileManager.moveItem(at: lockURL, to: stale)
            try? fileManager.removeItem(at: stale)
            try fileManager.createDirectory(
                at: lockURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try Data("thief".utf8).write(to: lockURL.appendingPathComponent("owner"))
            return lock.stillHeld()
        }

        // 旧持有者复验必须发现锁已易主（claim/complete 写回前据此中止）。
        XCTAssertFalse(heldAfterTheft)
        // 释放路径不得误删他人的锁目录。
        XCTAssertTrue(fileManager.fileExists(atPath: lockURL.path))
        XCTAssertEqual(
            try String(contentsOf: lockURL.appendingPathComponent("owner"), encoding: .utf8),
            "thief"
        )

        // 抢占者释放后，一切照常可用。
        try fileManager.removeItem(at: lockURL)
        XCTAssertTrue(try coordinator.claimTrigger(
            key: "daily:thread-lock:2026-07-16:0900",
            threadID: "thread-lock",
            minimumInterval: 0,
            now: Date(timeIntervalSince1970: 30_000)
        ))
    }

    func testThreadCooldownSpansDifferentKeysAndOwnersButManualZeroIntervalCanProceed() throws {
        let home = try temporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let swift = AutoResumeSharedCoordinator(codexHome: home, ownerID: "swift")
        let tauri = AutoResumeSharedCoordinator(codexHome: home, ownerID: "tauri")
        let threadID = "thread-cross-runtime-cooldown"
        let now = Date(timeIntervalSince1970: 40_000)

        XCTAssertTrue(try swift.claimTrigger(
            key: "interval:\(threadID):60:1",
            threadID: threadID,
            minimumInterval: 30 * 60,
            now: now
        ))
        XCTAssertFalse(try tauri.claimTrigger(
            key: "quota:\(threadID):fiveHour:cycle:recovered",
            threadID: threadID,
            minimumInterval: 30 * 60,
            now: now.addingTimeInterval(10 * 60)
        ))

        XCTAssertTrue(try tauri.claimTrigger(
            key: "manual:\(threadID):unique",
            threadID: threadID,
            minimumInterval: 0,
            now: now.addingTimeInterval(10 * 60)
        ))
        XCTAssertTrue(try swift.claimTrigger(
            key: "interval:\(threadID):60:2",
            threadID: threadID,
            minimumInterval: 30 * 60,
            now: now.addingTimeInterval(41 * 60)
        ))
    }

    func testThreadCooldownStartsWhenLongTurnCompletes() throws {
        let home = try temporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let swift = AutoResumeSharedCoordinator(codexHome: home, ownerID: "swift")
        let tauri = AutoResumeSharedCoordinator(codexHome: home, ownerID: "tauri")
        let threadID = "thread-long-turn-cooldown"
        let claimedAt = Date(timeIntervalSince1970: 45_000)
        let completedAt = claimedAt.addingTimeInterval(2 * 60 * 60)

        XCTAssertTrue(try swift.claimTrigger(
            key: "interval:\(threadID):60:long-turn",
            threadID: threadID,
            minimumInterval: 30 * 60,
            now: claimedAt
        ))
        try swift.completeTrigger(
            key: "interval:\(threadID):60:long-turn",
            outcome: "succeeded",
            message: nil,
            now: completedAt
        )

        XCTAssertFalse(try tauri.claimTrigger(
            key: "quota:\(threadID):too-soon-after-completion",
            threadID: threadID,
            minimumInterval: 30 * 60,
            now: completedAt.addingTimeInterval(29 * 60)
        ))
        XCTAssertTrue(try tauri.claimTrigger(
            key: "quota:\(threadID):after-completion-cooldown",
            threadID: threadID,
            minimumInterval: 30 * 60,
            now: completedAt.addingTimeInterval(31 * 60)
        ))
    }

    func testSharedDailyLimitIsAtomicOrderedAndExcludesManualSatisfiedAndSkipped() throws {
        let home = try temporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let swift = AutoResumeSharedCoordinator(codexHome: home, ownerID: "swift")
        let tauri = AutoResumeSharedCoordinator(codexHome: home, ownerID: "tauri")
        let dayStart = Date(timeIntervalSince1970: 86_400)
        let dailyLimit = AutoResumeSharedDailyLimit(dayStart: dayStart, maxRunsPerDay: 2)
        let threadID = "thread-shared-daily-limit"

        XCTAssertEqual(try swift.claimTrigger(
            key: "manual:\(threadID):does-not-count",
            threadID: threadID,
            minimumInterval: 0,
            dailyLimit: nil,
            now: dayStart.addingTimeInterval(1)
        ), .claimed)
        XCTAssertEqual(try swift.claimTrigger(
            key: "interval:\(threadID):satisfied",
            threadID: threadID,
            minimumInterval: 0,
            dailyLimit: dailyLimit,
            now: dayStart.addingTimeInterval(2)
        ), .claimed)
        try swift.completeTrigger(
            key: "interval:\(threadID):satisfied",
            outcome: "satisfied",
            message: nil,
            now: dayStart.addingTimeInterval(3)
        )
        XCTAssertEqual(try swift.claimTrigger(
            key: "interval:\(threadID):skipped",
            threadID: threadID,
            minimumInterval: 0,
            dailyLimit: dailyLimit,
            now: dayStart.addingTimeInterval(4)
        ), .claimed)
        try swift.completeTrigger(
            key: "interval:\(threadID):skipped",
            outcome: "skipped",
            message: nil,
            now: dayStart.addingTimeInterval(5)
        )

        let firstCountedKey = "interval:\(threadID):counted"
        XCTAssertEqual(try swift.claimTrigger(
            key: firstCountedKey,
            threadID: threadID,
            minimumInterval: 0,
            dailyLimit: dailyLimit,
            now: dayStart.addingTimeInterval(6)
        ), .claimed)
        XCTAssertEqual(try tauri.claimTrigger(
            key: "quota:other-thread:in-flight-reservation",
            threadID: "other-thread",
            minimumInterval: 0,
            dailyLimit: dailyLimit,
            now: dayStart.addingTimeInterval(7)
        ), .claimed)

        XCTAssertEqual(try tauri.claimTrigger(
            key: firstCountedKey,
            threadID: threadID,
            minimumInterval: 0,
            dailyLimit: dailyLimit,
            now: dayStart.addingTimeInterval(8)
        ), .duplicate, "duplicate must be reported before daily limit")
        XCTAssertEqual(try tauri.claimTrigger(
            key: "quota:\(threadID):cooldown-before-limit",
            threadID: threadID,
            minimumInterval: 60,
            dailyLimit: dailyLimit,
            now: dayStart.addingTimeInterval(8)
        ), .cooldown, "cooldown must be reported before daily limit")
        XCTAssertEqual(try tauri.claimTrigger(
            key: "quota:\(threadID):daily-limit",
            threadID: threadID,
            minimumInterval: 0,
            dailyLimit: dailyLimit,
            now: dayStart.addingTimeInterval(8)
        ), .dailyLimit)

        XCTAssertEqual(try tauri.claimTrigger(
            key: "interval:next-day:new-budget",
            threadID: threadID,
            minimumInterval: 0,
            dailyLimit: AutoResumeSharedDailyLimit(
                dayStart: dayStart.addingTimeInterval(24 * 60 * 60),
                maxRunsPerDay: 2
            ),
            now: dayStart.addingTimeInterval(24 * 60 * 60 + 1)
        ), .claimed)
    }

    func testLedgerJSONHasVersionedCrossRuntimeSchemaAndCompletionFields() throws {
        let home = try temporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let coordinator = AutoResumeSharedCoordinator(codexHome: home, ownerID: "swift-tests")
        let key = "quota:thread-ledger:lowestRemaining:cycle:reset"
        let claimedAt = Date(timeIntervalSince1970: 50_000)
        let completedAt = claimedAt.addingTimeInterval(12)

        XCTAssertTrue(try coordinator.claimTrigger(
            key: key,
            threadID: "thread-ledger",
            minimumInterval: 0,
            now: claimedAt
        ))
        try coordinator.completeTrigger(
            key: key,
            outcome: "succeeded",
            message: "turn-completed",
            now: completedAt
        )

        let ledgerURL = home
            .appendingPathComponent(".codex-token-bar-auto-resume", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("trigger-ledger.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let entries = try XCTUnwrap(object["entries"] as? [String: Any])
        let entry = try XCTUnwrap(entries[key] as? [String: Any])

        XCTAssertEqual(entry["threadID"] as? String, "thread-ledger")
        XCTAssertEqual(entry["ownerID"] as? String, "swift-tests")
        XCTAssertEqual(entry["claimedAtUnix"] as? Double, claimedAt.timeIntervalSince1970)
        XCTAssertEqual(entry["completedAtUnix"] as? Double, completedAt.timeIntervalSince1970)
        XCTAssertEqual(entry["outcome"] as? String, "succeeded")
        XCTAssertEqual(entry["message"] as? String, "turn-completed")
        XCTAssertEqual(Set(entry.keys), Set([
            "threadID",
            "ownerID",
            "claimedAtUnix",
            "completedAtUnix",
            "outcome",
            "message",
        ]))
    }

    private func temporaryCodexHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoResumeSharedCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
