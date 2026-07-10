import Darwin
import Foundation
import XCTest
@testable import CodexTokenBar

final class ProviderSyncEngineTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testCodexApplicationMatcherPrefersStableBundleIdentifier() {
        XCTAssertTrue(CodexDesktopApplicationMatcher.matches(
            bundleIdentifier: "com.openai.codex",
            localizedName: "Renamed Desktop"
        ))
    }

    func testCodexApplicationMatcherKeepsLegacyAndCurrentNameFallbacks() {
        XCTAssertTrue(CodexDesktopApplicationMatcher.matches(
            bundleIdentifier: nil,
            localizedName: "Codex"
        ))
        XCTAssertTrue(CodexDesktopApplicationMatcher.matches(
            bundleIdentifier: nil,
            localizedName: "ChatGPT"
        ))
    }

    func testCodexApplicationMatcherRejectsUnrelatedApplications() {
        XCTAssertFalse(CodexDesktopApplicationMatcher.matches(
            bundleIdentifier: "com.example.codex-helper",
            localizedName: "Other App"
        ))
        XCTAssertFalse(CodexDesktopApplicationMatcher.matches(
            bundleIdentifier: nil,
            localizedName: nil
        ))
        XCTAssertFalse(CodexDesktopApplicationMatcher.matches(
            bundleIdentifier: "com.example.other",
            localizedName: "ChatGPT"
        ))
    }

    func testSyncCreatesDisposableBackupAndOnlyMutatesIntendedFiles() throws {
        let fixture = try makeFixture()
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )

        let snapshot = try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )

        let backupPath = try XCTUnwrap(snapshot.lastBackupPath)
        let backup = URL(fileURLWithPath: backupPath)
        XCTAssertTrue(backup.path.hasPrefix(fixture.backupRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("session-jsonl.before.tar").path))
        XCTAssertEqual(try readSQLiteProviders(inDatabase: backup.appendingPathComponent("state_5.sqlite.before")), ["anthropic"])
        XCTAssertEqual(try readSessionProvider(at: fixture.activeSession), "openai")
        XCTAssertEqual(try readSQLiteProviders(at: fixture.codexHome), ["openai"])
        XCTAssertEqual(try String(contentsOf: fixture.unrelatedSessionFile, encoding: .utf8), fixture.unrelatedSessionText)
        XCTAssertEqual(try readSessionProvider(at: fixture.archivedSession), "anthropic")
        XCTAssertEqual(
            snapshot.backupRecords.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path },
            [backup.standardizedFileURL.path]
        )
    }

    func testScanAndVerifyRemainAvailableWhileCodexIsRunning() throws {
        let fixture = try makeFixture()
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { true }
        )
        let stateBeforeReadOnlyOperations = try disposableState(for: fixture)

        let scan = try engine.scan(codexHome: fixture.codexHome, includeArchivedSessions: false)
        XCTAssertTrue(scan.codexRunning)
        XCTAssertTrue(scan.status.contains("建议退出 Codex"))

        let verify = try engine.verify(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai"
        )
        XCTAssertTrue(verify.codexRunning)
        XCTAssertTrue(verify.status.contains("建议退出 Codex"))
        XCTAssertEqual(try disposableState(for: fixture), stateBeforeReadOnlyOperations)
    }

    func testSyncRejectsMutationWhileCodexIsRunning() throws {
        let fixture = try makeFixture()
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { true }
        )

        XCTAssertThrowsError(try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )) { error in
            XCTAssertEqual(
                error as? ProviderSyncMutationError,
                .codexRunning(operation: "同步")
            )
            XCTAssertTrue(error.localizedDescription.contains("Codex 正在运行"))
        }
        XCTAssertEqual(try readSessionProvider(at: fixture.activeSession), "anthropic")
        XCTAssertEqual(try readSQLiteProviders(at: fixture.codexHome), ["anthropic"])
        XCTAssertTrue(engine.backupRecords(for: fixture.codexHome).isEmpty)
    }

    func testRollbackRestoresSelectedBackupAndRejectsInvalidTargets() throws {
        let fixture = try makeFixture()
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )

        let synced = try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )
        let backupPath = try XCTUnwrap(synced.lastBackupPath)

        XCTAssertEqual(try readSessionProvider(at: fixture.activeSession), "openai")
        XCTAssertEqual(try readSQLiteProviders(at: fixture.codexHome), ["openai"])

        let rolledBack = try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)

        XCTAssertEqual(rolledBack.lastBackupPath, backupPath)
        XCTAssertEqual(try readSessionProvider(at: fixture.activeSession), "anthropic")
        XCTAssertEqual(try readSQLiteProviders(at: fixture.codexHome), ["anthropic"])
        XCTAssertEqual(try String(contentsOf: fixture.sessionIndex, encoding: .utf8), fixture.originalSessionIndexText)

        let invalidBackup = fixture.backupRoot.appendingPathComponent("invalid-backup", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidBackup, withIntermediateDirectories: true)
        try writeJSON(
            [
                "created_at": ISO8601DateFormatter().string(from: Date()),
                "codex_home": fixture.codexHome.deletingLastPathComponent().path,
                "target_provider": "openai",
                "session_file_count": 1
            ],
            to: invalidBackup.appendingPathComponent("manifest.json")
        )

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: invalidBackup.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("备份不属于当前 Codex Home"))
        }
        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: fixture.backupRoot.appendingPathComponent("missing").path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("备份不属于当前 Codex Home"))
        }
    }

    func testRollbackRejectsMutationWhileCodexIsRunning() throws {
        let fixture = try makeFixture()
        let setupEngine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )
        let synced = try setupEngine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )
        let backupPath = try XCTUnwrap(synced.lastBackupPath)
        let guardedEngine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { true }
        )

        XCTAssertThrowsError(try guardedEngine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)) { error in
            XCTAssertEqual(
                error as? ProviderSyncMutationError,
                .codexRunning(operation: "回滚")
            )
            XCTAssertTrue(error.localizedDescription.contains("Codex 正在运行"))
        }
        XCTAssertThrowsError(try guardedEngine.rollbackLatest(codexHome: fixture.codexHome)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Codex 正在运行"))
        }
        XCTAssertEqual(try readSessionProvider(at: fixture.activeSession), "openai")
        XCTAssertEqual(try readSQLiteProviders(at: fixture.codexHome), ["openai"])
    }

    func testConcurrentSyncBlocksRollbackThroughSymlinkAliasAndAllowsRollbackAfterRelease() throws {
        let fixture = try makeFixture()
        let symlinkAlias = fixture.codexHome
            .deletingLastPathComponent()
            .appendingPathComponent("codex-home-symlink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkAlias, withDestinationURL: fixture.codexHome)
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstCompleted = expectation(description: "first mutation completes")
        let firstQueue = DispatchQueue(label: "ProviderSyncEngineTests.firstMutation")
        let firstResult = SynchronizedProviderSyncResult()

        firstQueue.async {
            let engine = ProviderSyncEngine(
                backupRoot: fixture.backupRoot,
                applicationRunningProbe: { false },
                mutationLeaseDidAcquire: {
                    firstStarted.signal()
                    releaseFirst.wait()
                }
            )
            firstResult.set(Result {
                try engine.sync(
                    codexHome: fixture.codexHome,
                    includeArchivedSessions: false,
                    targetProviderOverride: "openai",
                    dryRunOnly: false
                )
            })
            firstCompleted.fulfill()
        }

        XCTAssertEqual(firstStarted.wait(timeout: .now() + 2), .success)
        let secondEngine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )

        XCTAssertThrowsError(try secondEngine.rollbackLatest(codexHome: symlinkAlias)) { error in
            XCTAssertTrue(error.localizedDescription.contains("已有 Provider 修复操作进行中"))
        }

        releaseFirst.signal()
        wait(for: [firstCompleted], timeout: 3)
        let completedResult = try XCTUnwrap(firstResult.get())
        XCTAssertNoThrow(try completedResult.get())

        let afterRelease = try secondEngine.rollbackLatest(codexHome: fixture.codexHome)
        XCTAssertTrue(afterRelease.status.contains("已从最近备份回滚"))
        XCTAssertEqual(try readSessionProvider(at: fixture.activeSession), "anthropic")
        XCTAssertEqual(try readSQLiteProviders(at: fixture.codexHome), ["anthropic"])
    }

    func testMutationLeaseReleasesAfterThrowingRollbackAndAllowsRetry() throws {
        let fixture = try makeFixture()
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )
        let missingBackup = fixture.backupRoot.appendingPathComponent("missing", isDirectory: true)

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: missingBackup.path))

        let retry = try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )
        XCTAssertEqual(retry.detectedProvider, "openai")
    }

    func testSyncPinsCanonicalHomeBeforeLeaseHookRetargetsAlias() throws {
        let first = try makeFixture()
        let second = try makeFixture()
        let alias = first.codexHome.deletingLastPathComponent()
            .appendingPathComponent("retargetable-home", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first.codexHome)
        let engine = ProviderSyncEngine(
            backupRoot: first.backupRoot,
            applicationRunningProbe: { false },
            mutationLeaseDidAcquire: {
                do {
                    try FileManager.default.removeItem(at: alias)
                    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second.codexHome)
                } catch {
                    XCTFail("failed to retarget alias: \(error)")
                }
            }
        )

        _ = try engine.sync(
            codexHome: alias,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )

        XCTAssertEqual(try readSessionProvider(at: first.activeSession), "openai")
        XCTAssertEqual(try readSQLiteProviders(at: first.codexHome), ["openai"])
        XCTAssertEqual(try readSessionProvider(at: second.activeSession), "anthropic")
        XCTAssertEqual(try readSQLiteProviders(at: second.codexHome), ["anthropic"])
    }

    func testSyncPinsCanonicalHomeWhenAliasRetargetsDuringBackupCreation() throws {
        let first = try makeFixture()
        let second = try makeFixture()
        let alias = first.codexHome.deletingLastPathComponent()
            .appendingPathComponent("backup-retargetable-home", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first.codexHome)
        let engine = ProviderSyncEngine(
            backupRoot: first.backupRoot,
            applicationRunningProbe: { false },
            sessionTarWillRun: {
                try FileManager.default.removeItem(at: alias)
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second.codexHome)
            }
        )

        let result = try engine.sync(
            codexHome: alias,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )

        XCTAssertEqual(try readSessionProvider(at: first.activeSession), "openai")
        XCTAssertEqual(try readSQLiteProviders(at: first.codexHome), ["openai"])
        XCTAssertEqual(try readSessionProvider(at: second.activeSession), "anthropic")
        XCTAssertEqual(try readSQLiteProviders(at: second.codexHome), ["anthropic"])
        let backupPath = try XCTUnwrap(result.lastBackupPath)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: backupPath).appendingPathComponent("manifest.json"))
            ) as? [String: Any]
        )
        XCTAssertEqual(manifest["canonical_codex_home"] as? String, first.codexHome.path)
    }

    func testVerifyReportsCoherentStatusAfterSyncAndRollback() throws {
        let fixture = try makeFixture()
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )

        let initial = try engine.verify(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai"
        )
        XCTAssertTrue(initial.status.contains("仍有历史或前端工作区状态未同步"))

        let synced = try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )
        XCTAssertTrue(synced.status.contains("同步完成并已验证"))

        let backupPath = try XCTUnwrap(synced.lastBackupPath)
        _ = try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)

        let restored = try engine.verify(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "anthropic"
        )
        XCTAssertTrue(restored.status.contains("验证通过"))
    }

    func testSyncRollsBackWhenPostWriteReportThrows() throws {
        let fixture = try makeFixture()
        var reportCalls = 0
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            reportWillBuild: {
                reportCalls += 1
                if reportCalls == 2 {
                    throw NSError(
                        domain: "ProviderSyncEngineTests",
                        code: 901,
                        userInfo: [NSLocalizedDescriptionKey: "injected post-write report failure"]
                    )
                }
            }
        )

        XCTAssertThrowsError(try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("injected post-write report failure"))
            XCTAssertTrue(error.localizedDescription.contains("已自动回滚"))
        }
        XCTAssertEqual(try readSessionProvider(at: fixture.activeSession), "anthropic")
        XCTAssertEqual(try readSQLiteProviders(at: fixture.codexHome), ["anthropic"])
    }

    func testSyncRollsBackWhenPostWriteReportFindsInvalidSessionFile() throws {
        let fixture = try makeFixture()
        var reportCalls = 0
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            reportWillBuild: {
                reportCalls += 1
                if reportCalls == 2 {
                    try #"{"payload":{},"type":"event_msg"}"#.appending("\n")
                        .write(to: fixture.activeSession, atomically: true, encoding: .utf8)
                }
            }
        )

        XCTAssertThrowsError(try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("无效会话文件"))
            XCTAssertTrue(error.localizedDescription.contains("已自动回滚"))
        }
        XCTAssertEqual(try readSessionProvider(at: fixture.activeSession), "anthropic")
        XCTAssertEqual(try readSQLiteProviders(at: fixture.codexHome), ["anthropic"])
    }

    func testSyncRollsBackWhenPostWriteProviderSetBecomesVacuous() throws {
        let fixture = try makeFixture()
        var reportCalls = 0
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            reportWillBuild: {
                reportCalls += 1
                if reportCalls == 2 {
                    try FileManager.default.removeItem(at: fixture.activeSession)
                }
            }
        )

        XCTAssertThrowsError(try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("会话校验为空"))
            XCTAssertTrue(error.localizedDescription.contains("已自动回滚"))
        }
        XCTAssertEqual(try readSessionProvider(at: fixture.activeSession), "anthropic")
        XCTAssertEqual(try readSQLiteProviders(at: fixture.codexHome), ["anthropic"])
    }

    func testRollbackRejectsOutOfRootArchiveMemberBeforeDestinationMutation() throws {
        let fixture = try makeFixture()
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )
        let synced = try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )
        let backupPath = try XCTUnwrap(synced.lastBackupPath)
        let backup = URL(fileURLWithPath: backupPath)
        let outside = fixture.codexHome.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try "archived-outside\n".write(to: outside, atomically: true, encoding: .utf8)
        try appendToTar(
            file: outside,
            archive: backup.appendingPathComponent("session-jsonl.before.tar")
        )
        try "destination-must-not-change\n".write(to: outside, atomically: true, encoding: .utf8)
        let destinationBeforeRollback = try disposableState(for: fixture)

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)) { error in
            XCTAssertTrue(error.localizedDescription.contains("归档成员"))
        }
        XCTAssertEqual(try disposableState(for: fixture), destinationBeforeRollback)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "destination-must-not-change\n")
    }

    func testAppCreatedArchiveRoundTripsScopedSessionMembers() throws {
        let fixture = try makeFixture()
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )
        let synced = try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: true,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )
        let backupPath = try XCTUnwrap(synced.lastBackupPath)
        let archive = URL(fileURLWithPath: backupPath).appendingPathComponent("session-jsonl.before.tar")

        XCTAssertEqual(
            try tarMembers(archive: archive),
            [
                "archived_sessions/2026/thread-archived.jsonl",
                "sessions/2026/07/06/thread-a.jsonl"
            ]
        )
        _ = try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)
        XCTAssertEqual(try readSessionProvider(at: fixture.activeSession), "anthropic")
        XCTAssertEqual(try readSessionProvider(at: fixture.archivedSession), "anthropic")
        XCTAssertEqual(try readSQLiteProviders(at: fixture.codexHome), ["anthropic"])
    }

    func testAppCreatedManifestPersistsExactSessionMembersAndDigests() throws {
        let fixture = try makeFixture()
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )
        let synced = try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: true,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )
        let backupPath = try XCTUnwrap(synced.lastBackupPath)
        let manifestURL = URL(fileURLWithPath: backupPath).appendingPathComponent("manifest.json")
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        let members = try XCTUnwrap(manifest["session_members"] as? [[String: String]])

        XCTAssertEqual(
            members.compactMap { $0["path"] }.sorted(),
            [
                "archived_sessions/2026/thread-archived.jsonl",
                "sessions/2026/07/06/thread-a.jsonl"
            ]
        )
        XCTAssertTrue(members.allSatisfy { member in
            member["sha256"]?.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        })
    }

    func testRollbackRejectsArchiveSubsetThatDoesNotMatchManifestCount() throws {
        let fixture = try makeFixture()
        let backup = try makeLegacyBackup(
            fixture: fixture,
            entries: [
                TestTarEntry(
                    name: "sessions/2026/07/06/thread-a.jsonl",
                    data: try Data(contentsOf: fixture.activeSession)
                )
            ],
            declaredCount: 2
        )
        let before = try rollbackDestinationState(for: fixture)
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backup.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("session_file_count"))
        }
        XCTAssertEqual(try rollbackDestinationState(for: fixture), before)
    }

    func testRollbackRejectsAmbiguousAndUnsafeArchiveMemberMatrixWithoutMutation() throws {
        let fixture = try makeFixture()
        let rawHomePrefix = String(fixture.codexHome.path.dropFirst())
        let cases: [(String, [TestTarEntry])] = [
            ("absolute", [TestTarEntry(name: "/sessions/absolute.jsonl")]),
            ("dot-prefix", [TestTarEntry(name: "./sessions/dot.jsonl")]),
            ("dot-component", [TestTarEntry(name: "sessions/./dot.jsonl")]),
            ("dotdot-component", [TestTarEntry(name: "sessions/../escape.jsonl")]),
            ("duplicate-archive", [
                TestTarEntry(name: "sessions/duplicate.jsonl"),
                TestTarEntry(name: "sessions/duplicate.jsonl")
            ]),
            ("duplicate-target", [
                TestTarEntry(name: "sessions/duplicate-target.jsonl"),
                TestTarEntry(name: "\(rawHomePrefix)/sessions/duplicate-target.jsonl")
            ]),
            ("backslash", [TestTarEntry(name: #"sessions/ambiguous\name.jsonl"#)]),
            ("carriage-return", [TestTarEntry(name: "sessions/carriage\rreturn.jsonl")]),
            ("line-feed", [TestTarEntry(name: "sessions/line\nfeed.jsonl")]),
            ("tab-control", [TestTarEntry(name: "sessions/tab\tcontrol.jsonl")]),
            ("next-line-control", [TestTarEntry(name: "sessions/next\u{0085}line.jsonl")]),
            ("line-separator", [TestTarEntry(name: "sessions/line\u{2028}separator.jsonl")]),
            ("paragraph-separator", [TestTarEntry(name: "sessions/paragraph\u{2029}separator.jsonl")]),
            ("format-character", [TestTarEntry(name: "sessions/zero\u{200D}joiner.jsonl")]),
            ("symlink", [TestTarEntry(name: "sessions/link.jsonl", type: .symbolicLink, linkName: "target.jsonl")]),
            ("hardlink", [
                TestTarEntry(name: "sessions/source.jsonl"),
                TestTarEntry(name: "sessions/hard.jsonl", type: .hardLink, linkName: "sessions/source.jsonl")
            ]),
            ("character-device", [TestTarEntry(name: "sessions/character.jsonl", type: .characterDevice)]),
            ("block-device", [TestTarEntry(name: "sessions/block.jsonl", type: .blockDevice)]),
            ("fifo", [TestTarEntry(name: "sessions/fifo.jsonl", type: .fifo)]),
            ("directory", [TestTarEntry(name: "sessions/directory.jsonl", type: .directory)])
        ]
        let before = try rollbackDestinationState(for: fixture)
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )

        for (name, entries) in cases {
            let backup = try makeLegacyBackup(
                fixture: fixture,
                entries: entries,
                declaredCount: entries.count
            )
            XCTAssertThrowsError(
                try engine.rollback(codexHome: fixture.codexHome, backupPath: backup.path),
                "case: \(name)"
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("归档成员"),
                    "case: \(name), error: \(error.localizedDescription)"
                )
            }
            XCTAssertEqual(try rollbackDestinationState(for: fixture), before, "case: \(name)")
        }
    }

    func testRollbackRejectsLexicalMembersWithOneCanonicalDestination() throws {
        let fixture = try makeFixture()
        let realDirectory = fixture.codexHome
            .appendingPathComponent("sessions/canonical-target", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        let aliasDirectory = fixture.codexHome
            .appendingPathComponent("sessions/canonical-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: realDirectory)
        let destination = realDirectory.appendingPathComponent("thread.jsonl")
        try Data("destination-before\n".utf8).write(to: destination)
        let backup = try makeLegacyBackup(
            fixture: fixture,
            entries: [
                TestTarEntry(name: "sessions/canonical-target/thread.jsonl"),
                TestTarEntry(name: "sessions/canonical-alias/thread.jsonl")
            ],
            declaredCount: 2
        )
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backup.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("重复"))
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "destination-before\n")
    }

    func testRollbackSupportsLegacyArchiveCreatedThroughCanonicalizingHomeAlias() throws {
        let fixture = try makeFixture()
        let alias = fixture.codexHome.deletingLastPathComponent()
            .appendingPathComponent("legacy-codex-home-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.codexHome)
        let legacyMember = String(alias.path.dropFirst()) + "/sessions/2026/07/06/thread-a.jsonl"
        let archivedData = try Data(contentsOf: fixture.activeSession)
        let backup = try makeLegacyBackup(
            fixture: fixture,
            entries: [TestTarEntry(name: legacyMember, data: archivedData)],
            declaredCount: 1,
            rawCodexHome: alias.path
        )
        try writeSession(id: "thread-a", provider: "openai", to: fixture.activeSession)
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )

        _ = try engine.rollback(codexHome: fixture.codexHome, backupPath: backup.path)

        XCTAssertEqual(try Data(contentsOf: fixture.activeSession), archivedData)
    }

    func testRollbackRejectsLegacyAliasThatCanonicalizesToDifferentHome() throws {
        let fixture = try makeFixture()
        let otherHome = fixture.codexHome.deletingLastPathComponent()
            .appendingPathComponent("other-codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: otherHome, withIntermediateDirectories: true)
        let alias = fixture.codexHome.deletingLastPathComponent()
            .appendingPathComponent("mismatched-codex-home-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: otherHome)
        let legacyMember = String(alias.path.dropFirst()) + "/sessions/thread.jsonl"
        let backup = try makeLegacyBackup(
            fixture: fixture,
            entries: [TestTarEntry(name: legacyMember)],
            declaredCount: 1,
            rawCodexHome: alias.path
        )
        let before = try rollbackDestinationState(for: fixture)
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backup.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("备份不属于当前 Codex Home"))
        }
        XCTAssertEqual(try rollbackDestinationState(for: fixture), before)
    }

    func testRollbackRejectsMissingAndEmptyArchiveAgainstManifestCount() throws {
        let fixture = try makeFixture()
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )
        let before = try rollbackDestinationState(for: fixture)
        let missingArchiveBackup = fixture.backupRoot
            .appendingPathComponent("missing-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: missingArchiveBackup, withIntermediateDirectories: true)
        try writeJSON(
            [
                "created_at": ISO8601DateFormatter().string(from: Date()),
                "codex_home": fixture.codexHome.path,
                "target_provider": "openai",
                "session_file_count": 1
            ],
            to: missingArchiveBackup.appendingPathComponent("manifest.json")
        )
        let emptyArchiveBackup = try makeLegacyBackup(
            fixture: fixture,
            entries: [],
            declaredCount: 1
        )

        XCTAssertThrowsError(try engine.rollback(
            codexHome: fixture.codexHome,
            backupPath: missingArchiveBackup.path
        ))
        XCTAssertThrowsError(try engine.rollback(
            codexHome: fixture.codexHome,
            backupPath: emptyArchiveBackup.path
        ))
        XCTAssertEqual(try rollbackDestinationState(for: fixture), before)
    }

    func testRollbackRejectsNewManifestMemberSetAndDigestMismatchWithoutMutation() throws {
        for mismatch in ["path", "digest"] {
            let fixture = try makeFixture()
            let setupEngine = ProviderSyncEngine(
                backupRoot: fixture.backupRoot,
                applicationRunningProbe: { false }
            )
            let synced = try setupEngine.sync(
                codexHome: fixture.codexHome,
                includeArchivedSessions: true,
                targetProviderOverride: "openai",
                dryRunOnly: false
            )
            let backupPath = try XCTUnwrap(synced.lastBackupPath)
            let backup = URL(fileURLWithPath: backupPath)
            let manifestURL = backup.appendingPathComponent("manifest.json")
            var manifest = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
            )
            var members = try XCTUnwrap(manifest["session_members"] as? [[String: Any]])
            if mismatch == "path" {
                members[0]["path"] = "sessions/manifest-only.jsonl"
            } else {
                members[0]["sha256"] = String(repeating: "0", count: 64)
            }
            manifest["session_members"] = members
            try writeJSON(manifest, to: manifestURL)
            let before = try rollbackDestinationState(for: fixture)

            XCTAssertThrowsError(try setupEngine.rollback(
                codexHome: fixture.codexHome,
                backupPath: backup.path
            ), "mismatch: \(mismatch)")
            XCTAssertEqual(try rollbackDestinationState(for: fixture), before, "mismatch: \(mismatch)")
        }
    }

    func testBackupCreationDrainsHighVolumeTarDiagnosticsBeforeWaiting() throws {
        let fixture = try makeFixture()
        let diagnosticRoot = fixture.codexHome
            .appendingPathComponent("sessions/high-volume", isDirectory: true)
        try FileManager.default.createDirectory(at: diagnosticRoot, withIntermediateDirectories: true)
        let files = try (0..<1_500).map { index -> URL in
            let file = diagnosticRoot.appendingPathComponent("missing-\(index).jsonl")
            try Data("session \(index)\n".utf8).write(to: file)
            return file
        }
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            sessionTarStageWillRun: { stageRoot in
                try FileManager.default.removeItem(
                    at: stageRoot.appendingPathComponent("sessions/high-volume", isDirectory: true)
                )
            }
        )

        XCTAssertThrowsError(try engine.createBackup(
            codexHome: fixture.codexHome,
            sessionFiles: files,
            targetProvider: "openai"
        )) { error in
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testBackupRejectsSourceTypeChangesBeforeSyncMutation() throws {
        let cases: [(String, (ProviderSyncFixture) throws -> Void)] = [
            ("symlink", { fixture in
                let target = fixture.codexHome.appendingPathComponent("symlink-target.jsonl")
                try Data("symlink target\n".utf8).write(to: target)
                try FileManager.default.removeItem(at: fixture.activeSession)
                try FileManager.default.createSymbolicLink(at: fixture.activeSession, withDestinationURL: target)
            }),
            ("hardlink", { fixture in
                let target = fixture.codexHome.appendingPathComponent("hardlink-target.jsonl")
                try Data("hardlink target\n".utf8).write(to: target)
                try FileManager.default.removeItem(at: fixture.activeSession)
                try FileManager.default.linkItem(at: target, to: fixture.activeSession)
            }),
            ("directory", { fixture in
                try FileManager.default.removeItem(at: fixture.activeSession)
                try FileManager.default.createDirectory(at: fixture.activeSession, withIntermediateDirectories: false)
            }),
            ("fifo", { fixture in
                try FileManager.default.removeItem(at: fixture.activeSession)
                guard mkfifo(fixture.activeSession.path, 0o600) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            })
        ]

        for (name, mutateSource) in cases {
            let fixture = try makeFixture()
            let engine = ProviderSyncEngine(
                backupRoot: fixture.backupRoot,
                applicationRunningProbe: { false },
                sessionTarWillRun: {
                    try mutateSource(fixture)
                }
            )

            XCTAssertThrowsError(try engine.sync(
                codexHome: fixture.codexHome,
                includeArchivedSessions: false,
                targetProviderOverride: "openai",
                dryRunOnly: false
            ), "case: \(name)")
            XCTAssertEqual(try readSQLiteProviders(at: fixture.codexHome), ["anthropic"], "case: \(name)")
            XCTAssertTrue(try manifestFiles(in: fixture.backupRoot).isEmpty, "case: \(name)")
        }
    }

    func testBackupRejectsCompletedTarThatRestoreValidatorWouldReject() throws {
        let fixture = try makeFixture()
        let relativePath = "sessions/2026/07/06/thread-a.jsonl"
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            sessionTarDidRun: { archive in
                try self.writeUSTAR(entries: [
                    TestTarEntry(name: "sessions/source.jsonl"),
                    TestTarEntry(name: relativePath, type: .hardLink, linkName: "sessions/source.jsonl")
                ], to: archive)
            }
        )

        XCTAssertThrowsError(try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        ))
        XCTAssertEqual(try readSessionProvider(at: fixture.activeSession), "anthropic")
        XCTAssertEqual(try readSQLiteProviders(at: fixture.codexHome), ["anthropic"])
        XCTAssertTrue(try manifestFiles(in: fixture.backupRoot).isEmpty)
    }

    func testRestoreUsesImmutableArchiveSnapshotWhenOriginalSwapsAfterListing() throws {
        let fixture = try makeFixture()
        let archivedData = try Data(contentsOf: fixture.activeSession)
        let backup = try makeLegacyBackup(
            fixture: fixture,
            entries: [TestTarEntry(name: "sessions/2026/07/06/thread-a.jsonl", data: archivedData)],
            declaredCount: 1
        )
        try writeSession(id: "thread-a", provider: "current", to: fixture.activeSession)
        let sentinel = fixture.backupRoot.appendingPathComponent("escape-sentinel.jsonl")
        try Data("sentinel-before\n".utf8).write(to: sentinel)
        let maliciousArchive = fixture.backupRoot.appendingPathComponent("swapped-malicious.tar")
        try writeUSTAR(
            entries: [TestTarEntry(name: "../escape-sentinel.jsonl", data: Data("mutated\n".utf8))],
            to: maliciousArchive
        )
        let archive = backup.appendingPathComponent("session-jsonl.before.tar")
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            sessionArchiveDidList: {
                try FileManager.default.removeItem(at: archive)
                try FileManager.default.copyItem(at: maliciousArchive, to: archive)
            }
        )

        _ = try engine.rollback(codexHome: fixture.codexHome, backupPath: backup.path)

        XCTAssertEqual(try Data(contentsOf: fixture.activeSession), archivedData)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "sentinel-before\n")
    }

    func testCurrentManifestRejectsRegularArchiveSwapBetweenLstatAndOpen() throws {
        let fixture = try makeFixture()
        let setupEngine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )
        let synced = try setupEngine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )
        let backup = URL(fileURLWithPath: try XCTUnwrap(synced.lastBackupPath))
        let archive = backup.appendingPathComponent("session-jsonl.before.tar")
        let swappedArchive = fixture.backupRoot.appendingPathComponent("current-swapped.tar")
        try writeUSTAR(entries: [
            TestTarEntry(
                name: "sessions/2026/07/06/thread-a.jsonl",
                data: Data("current manifest swapped bytes\n".utf8)
            )
        ], to: swappedArchive)
        let destinationBefore = try Data(contentsOf: fixture.activeSession)
        var didSwap = false
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            regularFileWillOpen: { source in
                guard !didSwap, source.standardizedFileURL.path == archive.standardizedFileURL.path else { return }
                didSwap = true
                try FileManager.default.removeItem(at: archive)
                try FileManager.default.copyItem(at: swappedArchive, to: archive)
            }
        )

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backup.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("身份变化"))
        }
        XCTAssertTrue(didSwap)
        XCTAssertEqual(try Data(contentsOf: fixture.activeSession), destinationBefore)
    }

    func testLegacyManifestRejectsRegularArchiveSwapBetweenLstatAndOpen() throws {
        let fixture = try makeFixture()
        let archivedData = try Data(contentsOf: fixture.activeSession)
        let backup = try makeLegacyBackup(
            fixture: fixture,
            entries: [TestTarEntry(name: "sessions/2026/07/06/thread-a.jsonl", data: archivedData)],
            declaredCount: 1
        )
        try writeSession(id: "thread-a", provider: "current", to: fixture.activeSession)
        let destinationBefore = try Data(contentsOf: fixture.activeSession)
        let archive = backup.appendingPathComponent("session-jsonl.before.tar")
        let swappedArchive = fixture.backupRoot.appendingPathComponent("legacy-swapped.tar")
        let swappedData = try sessionData(id: "thread-a", provider: "swapped-legacy")
        try writeUSTAR(entries: [
            TestTarEntry(name: "sessions/2026/07/06/thread-a.jsonl", data: swappedData)
        ], to: swappedArchive)
        var didSwap = false
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            regularFileWillOpen: { source in
                guard !didSwap, source.standardizedFileURL.path == archive.standardizedFileURL.path else { return }
                didSwap = true
                try FileManager.default.removeItem(at: archive)
                try FileManager.default.copyItem(at: swappedArchive, to: archive)
            }
        )

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backup.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("身份变化"))
        }
        XCTAssertTrue(didSwap)
        XCTAssertEqual(try Data(contentsOf: fixture.activeSession), destinationBefore)
    }

    func testSyncRejectsPostManifestSessionAncestorRetargetWithoutOutsideMutation() throws {
        let fixture = try makeFixture()
        let outsideBefore = try sessionData(id: "thread-a", provider: "outside-before")
        var retarget: ProviderSyncAncestorRetarget?
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            sessionMutationsWillBegin: {
                retarget = try self.retargetActiveSessionAncestor(
                    fixture,
                    outsideDestinationData: outsideBefore
                )
            }
        )

        XCTAssertThrowsError(try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        ))
        let changedTree = try XCTUnwrap(retarget)
        XCTAssertEqual(try Data(contentsOf: changedTree.outsideDestination), outsideBefore)
        XCTAssertEqual(try String(contentsOf: changedTree.outsideSentinel, encoding: .utf8), "outside-sentinel-before\n")
        XCTAssertEqual(try manifestFiles(in: fixture.backupRoot).count, 1)
    }

    func testSyncRejectsPostManifestRegularSessionReplacementWithoutMutation() throws {
        let fixture = try makeFixture()
        let replacementData = try Data(contentsOf: fixture.activeSession)
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            sessionMutationsWillBegin: {
                let replacement = fixture.activeSession.deletingLastPathComponent()
                    .appendingPathComponent("replacement-\(UUID().uuidString).jsonl")
                try replacementData.write(to: replacement)
                try FileManager.default.removeItem(at: fixture.activeSession)
                try FileManager.default.moveItem(at: replacement, to: fixture.activeSession)
            }
        )

        XCTAssertThrowsError(try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        ))
        XCTAssertEqual(try Data(contentsOf: fixture.activeSession), replacementData)
        XCTAssertEqual(try manifestFiles(in: fixture.backupRoot).count, 1)
    }

    func testPostRewriteAncestorRetargetDoesNotMutateOutsideDuringTimestampRepair() throws {
        let fixture = try makeFixture()
        let sessionParent = fixture.activeSession.deletingLastPathComponent()
        let additionalIDs = ["thread-b", "thread-c", "thread-d"]
        for id in additionalIDs {
            try writeSession(
                id: id,
                provider: "anthropic",
                to: sessionParent.appendingPathComponent("\(id).jsonl")
            )
        }
        try seedTimestampCollisionRows(at: fixture.codexHome, ids: additionalIDs)

        let outsideBefore = try sessionData(id: "thread-a", provider: "outside-before")
        let outsideModificationDate = Date(timeIntervalSince1970: 946_684_800.125)
        var retarget: ProviderSyncAncestorRetarget?
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            sessionMutationsDidApply: {
                let changedTree = try self.retargetActiveSessionAncestor(
                    fixture,
                    outsideDestinationData: outsideBefore
                )
                let outsideParent = changedTree.outsideDestination.deletingLastPathComponent()
                for id in additionalIDs {
                    try self.writeSession(
                        id: id,
                        provider: "outside-before",
                        to: outsideParent.appendingPathComponent("\(id).jsonl")
                    )
                }
                try FileManager.default.setAttributes(
                    [.modificationDate: outsideModificationDate],
                    ofItemAtPath: changedTree.outsideDestination.path
                )
                retarget = changedTree
            }
        )

        XCTAssertThrowsError(try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        ))
        let changedTree = try XCTUnwrap(retarget)
        XCTAssertEqual(try Data(contentsOf: changedTree.outsideDestination), outsideBefore)
        let attributes = try FileManager.default.attributesOfItem(atPath: changedTree.outsideDestination.path)
        let actualModificationDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertEqual(
            actualModificationDate.timeIntervalSince1970,
            outsideModificationDate.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testDescriptorBoundTimestampRepairPreservesNormalCollisionRepair() throws {
        let fixture = try makeFixture()
        let sessionParent = fixture.activeSession.deletingLastPathComponent()
        let additionalIDs = ["thread-b", "thread-c", "thread-d"]
        for id in additionalIDs {
            try writeSession(
                id: id,
                provider: "anthropic",
                to: sessionParent.appendingPathComponent("\(id).jsonl")
            )
        }
        try seedTimestampCollisionRows(at: fixture.codexHome, ids: additionalIDs)
        for id in ["thread-a"] + additionalIDs {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 946_684_800.125)],
                ofItemAtPath: sessionParent.appendingPathComponent("\(id).jsonl").path
            )
        }
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )

        _ = try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.activeSession.path)
        let modificationDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertEqual(modificationDate.timeIntervalSince1970, 1_783_468_800, accuracy: 0.001)
        XCTAssertEqual(try readSessionProvider(at: fixture.activeSession), "openai")
    }

    func testRestoreApplyAncestorRetargetKeepsOutsideAndJournalOriginal() throws {
        let fixture = try makeFixture()
        let backupPath = try createSyncedBackupAndSeedRollbackDestination(fixture)
        let outsideBefore = try sessionData(id: "thread-a", provider: "outside-apply")
        var retarget: ProviderSyncAncestorRetarget?
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            restoreWillApply: { _, destination in
                guard retarget == nil, self.isActiveSessionDestination(destination) else { return }
                retarget = try self.retargetActiveSessionAncestor(
                    fixture,
                    outsideDestinationData: outsideBefore
                )
            }
        )

        try assertRetargetedRestorePreservesOutsideAndJournal(
            fixture: fixture,
            backupPath: backupPath,
            outsideBefore: outsideBefore,
            retarget: { retarget }
        ) {
            try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)
        }
    }

    func testRestoreAppliedVerificationAncestorRetargetKeepsOutsideAndJournalOriginal() throws {
        let fixture = try makeFixture()
        let backupSessionData = try Data(contentsOf: fixture.activeSession)
        let backupPath = try createSyncedBackupAndSeedRollbackDestination(fixture)
        var retarget: ProviderSyncAncestorRetarget?
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            restoreWillVerifyApplied: { _, destination in
                guard retarget == nil, self.isActiveSessionDestination(destination) else { return }
                retarget = try self.retargetActiveSessionAncestor(
                    fixture,
                    outsideDestinationData: backupSessionData
                )
            }
        )

        try assertRetargetedRestorePreservesOutsideAndJournal(
            fixture: fixture,
            backupPath: backupPath,
            outsideBefore: backupSessionData,
            retarget: { retarget }
        ) {
            try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)
        }
    }

    func testRestoreCompensationAncestorRetargetKeepsOutsideAndJournalOriginal() throws {
        let fixture = try makeFixture()
        let backupPath = try createSyncedBackupAndSeedRollbackDestination(fixture)
        let outsideBefore = try sessionData(id: "thread-a", provider: "outside-compensate")
        var retarget: ProviderSyncAncestorRetarget?
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            reportWillBuild: {
                throw NSError(
                    domain: "ProviderSyncEngineTests",
                    code: 913,
                    userInfo: [NSLocalizedDescriptionKey: "injected report failure before compensation"]
                )
            },
            restoreWillCompensate: { _, destination in
                guard retarget == nil, self.isActiveSessionDestination(destination) else { return }
                retarget = try self.retargetActiveSessionAncestor(
                    fixture,
                    outsideDestinationData: outsideBefore
                )
            }
        )

        try assertRetargetedRestorePreservesOutsideAndJournal(
            fixture: fixture,
            backupPath: backupPath,
            outsideBefore: outsideBefore,
            retarget: { retarget }
        ) {
            try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)
        }
    }

    func testRestoreCompensatedVerificationAncestorRetargetKeepsOutsideAndJournalOriginal() throws {
        let fixture = try makeFixture()
        let backupPath = try createSyncedBackupAndSeedRollbackDestination(fixture)
        let preRollbackData = try Data(contentsOf: fixture.activeSession)
        var retarget: ProviderSyncAncestorRetarget?
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            reportWillBuild: {
                throw NSError(
                    domain: "ProviderSyncEngineTests",
                    code: 914,
                    userInfo: [NSLocalizedDescriptionKey: "injected report failure before compensated verification"]
                )
            },
            restoreWillVerifyCompensated: { _, destination in
                guard retarget == nil, self.isActiveSessionDestination(destination) else { return }
                retarget = try self.retargetActiveSessionAncestor(
                    fixture,
                    outsideDestinationData: preRollbackData
                )
            }
        )

        try assertRetargetedRestorePreservesOutsideAndJournal(
            fixture: fixture,
            backupPath: backupPath,
            outsideBefore: preRollbackData,
            retarget: { retarget }
        ) {
            try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)
        }
    }

    func testRollbackPostRestoreReportFailurePreservesPreRollbackDestinationBytesAndAbsence() throws {
        let fixture = try makeFixture()
        let setupEngine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )
        let synced = try setupEngine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: true,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )
        let backupPath = try XCTUnwrap(synced.lastBackupPath)
        try seedPreRollbackDestination(fixture)
        let before = try rollbackDestinationState(for: fixture)
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            reportWillBuild: {
                throw NSError(
                    domain: "ProviderSyncEngineTests",
                    code: 902,
                    userInfo: [NSLocalizedDescriptionKey: "injected post-restore report failure"]
                )
            }
        )

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)) { error in
            XCTAssertTrue(error.localizedDescription.contains("injected post-restore report failure"))
        }
        XCTAssertEqual(try rollbackDestinationState(for: fixture), before)
    }

    func testRollbackFirstReplacementFailurePreservesPreRollbackDestinationBytesAndAbsence() throws {
        try assertInjectedRestoreFailurePreservesDestination { index, _ in
            if index == 0 {
                throw NSError(
                    domain: "ProviderSyncEngineTests",
                    code: 905,
                    userInfo: [NSLocalizedDescriptionKey: "injected first replacement failure"]
                )
            }
        }
    }

    func testRollbackLaterReplacementFailureCompensatesAllAppliedSwaps() throws {
        try assertInjectedRestoreFailurePreservesDestination { _, destination in
            if destination.path.hasSuffix("/sessions/2026/07/06/thread-a.jsonl") {
                throw NSError(
                    domain: "ProviderSyncEngineTests",
                    code: 906,
                    userInfo: [NSLocalizedDescriptionKey: "injected later replacement failure"]
                )
            }
        }
    }

    func testCurrentOperationRecoveryFailureIsRetriedByGeneralCompensation() throws {
        let fixture = try makeFixture()
        let backupPath = try createSyncedBackupAndSeedRollbackDestination(fixture)
        let before = try rollbackDestinationState(for: fixture)
        var compensationAttempts = 0
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            restoreWillApply: { index, _ in
                if index == 0 {
                    throw NSError(
                        domain: "ProviderSyncEngineTests",
                        code: 907,
                        userInfo: [NSLocalizedDescriptionKey: "injected current replacement failure"]
                    )
                }
            },
            restoreWillCompensate: { index, _ in
                guard index == 0 else { return }
                compensationAttempts += 1
                if compensationAttempts == 1 {
                    throw NSError(
                        domain: "ProviderSyncEngineTests",
                        code: 908,
                        userInfo: [NSLocalizedDescriptionKey: "injected current recovery failure"]
                    )
                }
            }
        )

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath))
        XCTAssertEqual(compensationAttempts, 2)
        XCTAssertEqual(try rollbackDestinationState(for: fixture), before)
        XCTAssertTrue(try transactionRoots(in: fixture.codexHome).isEmpty)
    }

    func testIncompleteCurrentCompensationKeepsJournalAndReportsPath() throws {
        let fixture = try makeFixture()
        let backupPath = try createSyncedBackupAndSeedRollbackDestination(fixture)
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            restoreWillApply: { index, _ in
                if index == 0 {
                    throw NSError(
                        domain: "ProviderSyncEngineTests",
                        code: 909,
                        userInfo: [NSLocalizedDescriptionKey: "injected current replacement failure"]
                    )
                }
            },
            restoreWillCompensate: { index, _ in
                if index == 0 {
                    throw NSError(
                        domain: "ProviderSyncEngineTests",
                        code: 910,
                        userInfo: [NSLocalizedDescriptionKey: "persistent current compensation failure"]
                    )
                }
            }
        )
        var message = ""

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)) { error in
            message = error.localizedDescription
        }
        let journal = try XCTUnwrap(transactionRoots(in: fixture.codexHome).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.appendingPathComponent("originals/0").path))
        XCTAssertTrue(message.contains(journal.path))
    }

    func testLaterReverseCompensationFailureKeepsNeededJournalAndReportsPath() throws {
        let fixture = try makeFixture()
        let backupPath = try createSyncedBackupAndSeedRollbackDestination(fixture)
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            reportWillBuild: {
                throw NSError(
                    domain: "ProviderSyncEngineTests",
                    code: 911,
                    userInfo: [NSLocalizedDescriptionKey: "injected post-restore failure"]
                )
            },
            restoreWillCompensate: { _, destination in
                if destination.lastPathComponent == "state_5.sqlite" {
                    throw NSError(
                        domain: "ProviderSyncEngineTests",
                        code: 912,
                        userInfo: [NSLocalizedDescriptionKey: "injected later reverse compensation failure"]
                    )
                }
            }
        )
        var message = ""

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)) { error in
            message = error.localizedDescription
        }
        let journal = try XCTUnwrap(transactionRoots(in: fixture.codexHome).first)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: journal.path).isEmpty)
        XCTAssertTrue(message.contains(journal.path))
    }

    func testReviewFix4BackupRootRetargetDoesNotPublishReplacementHomeBackup() throws {
        let fixture = try makeFixture()
        var retarget: ProviderSyncRootRetarget?
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            backupWillReadHome: {
                retarget = try self.retargetHomeRoot(fixture) { replacement, detached in
                    try self.copyDirectoryContents(from: detached, to: replacement)
                }
            }
        )

        XCTAssertThrowsError(try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        ))
        let changedTree = try XCTUnwrap(retarget)
        XCTAssertEqual(try readSQLiteProviders(at: changedTree.replacementHome), ["anthropic"])
        XCTAssertEqual(try String(contentsOf: changedTree.sentinel, encoding: .utf8), "replacement-sentinel-before\n")
        XCTAssertTrue(try manifestFiles(in: fixture.backupRoot).isEmpty)
    }

    func testReviewFix4TimestampSQLiteRootRetargetDoesNotMutateReplacementDatabase() throws {
        let fixture = try makeFixture()
        let sessionParent = fixture.activeSession.deletingLastPathComponent()
        let additionalIDs = ["thread-b", "thread-c", "thread-d"]
        for id in additionalIDs {
            try writeSession(
                id: id,
                provider: "anthropic",
                to: sessionParent.appendingPathComponent("\(id).jsonl")
            )
        }
        try seedTimestampCollisionRows(at: fixture.codexHome, ids: additionalIDs)
        var retarget: ProviderSyncRootRetarget?
        var replacementTimestampsBefore: [String: Int64] = [:]
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            sqliteTimestampWillOpen: {
                retarget = try self.retargetHomeRoot(fixture) { replacement, _ in
                    try self.seedStateDatabase(at: replacement)
                    try self.seedTimestampCollisionRows(at: replacement, ids: additionalIDs)
                    replacementTimestampsBefore = try self.readSQLiteTimestampMilliseconds(at: replacement)
                }
            }
        )

        XCTAssertThrowsError(try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        ))
        let changedTree = try XCTUnwrap(retarget)
        XCTAssertEqual(
            try readSQLiteTimestampMilliseconds(at: changedTree.replacementHome),
            replacementTimestampsBefore
        )
        XCTAssertEqual(try String(contentsOf: changedTree.sentinel, encoding: .utf8), "replacement-sentinel-before\n")
    }

    func testReviewFix4ProviderSQLiteRootRetargetDoesNotMutateReplacementDatabase() throws {
        let fixture = try makeFixture()
        var retarget: ProviderSyncRootRetarget?
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            sqliteProviderWillOpen: {
                retarget = try self.retargetHomeRoot(fixture) { replacement, _ in
                    try self.seedStateDatabase(at: replacement)
                }
            }
        )

        XCTAssertThrowsError(try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        ))
        let changedTree = try XCTUnwrap(retarget)
        XCTAssertEqual(try readSQLiteProviders(at: changedTree.replacementHome), ["anthropic"])
        XCTAssertEqual(try String(contentsOf: changedTree.sentinel, encoding: .utf8), "replacement-sentinel-before\n")
    }

    func testReviewFix4SessionIndexRootRetargetDoesNotMutateReplacementIndex() throws {
        let fixture = try makeFixture()
        let replacementIndexBefore = Data("replacement-index-before\n".utf8)
        var retarget: ProviderSyncRootRetarget?
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            sessionIndexWillReplace: { _ in
                retarget = try self.retargetHomeRoot(fixture) { replacement, _ in
                    try self.seedStateDatabase(at: replacement)
                    try replacementIndexBefore.write(
                        to: replacement.appendingPathComponent("session_index.jsonl")
                    )
                }
            }
        )

        XCTAssertThrowsError(try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        ))
        let changedTree = try XCTUnwrap(retarget)
        XCTAssertEqual(
            try Data(contentsOf: changedTree.replacementHome.appendingPathComponent("session_index.jsonl")),
            replacementIndexBefore
        )
    }

    func testReviewFix4GlobalStateRootRetargetDoesNotMutateReplacementState() throws {
        let fixture = try makeFixture()
        try writeGlobalStateFixture(
            projectOrder: [],
            savedRoots: ["/tmp/workspace"],
            to: fixture.codexHome.appendingPathComponent(".codex-global-state.json")
        )
        let replacementState = fixture.codexHome.deletingLastPathComponent()
            .appendingPathComponent("replacement-state.json")
        try writeGlobalStateFixture(
            projectOrder: ["/replacement-only"],
            savedRoots: [],
            to: replacementState
        )
        let replacementStateBefore = try Data(contentsOf: replacementState)
        var retarget: ProviderSyncRootRetarget?
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            globalStateWillReplace: { _ in
                retarget = try self.retargetHomeRoot(fixture) { replacement, _ in
                    try self.seedStateDatabase(at: replacement)
                    try FileManager.default.copyItem(
                        at: replacementState,
                        to: replacement.appendingPathComponent(".codex-global-state.json")
                    )
                }
            }
        )

        XCTAssertThrowsError(try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        ))
        let changedTree = try XCTUnwrap(retarget)
        XCTAssertEqual(
            try Data(contentsOf: changedTree.replacementHome.appendingPathComponent(".codex-global-state.json")),
            replacementStateBefore
        )
    }

    func testReviewFix4ZeroSessionRootRetargetDoesNotMutateReplacementHome() throws {
        let fixture = try makeFixture()
        try FileManager.default.removeItem(at: fixture.activeSession)
        var retarget: ProviderSyncRootRetarget?
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            sessionMutationsWillBegin: {
                retarget = try self.retargetHomeRoot(fixture) { replacement, _ in
                    try self.seedStateDatabase(at: replacement)
                }
            }
        )

        XCTAssertThrowsError(try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        ))
        let changedTree = try XCTUnwrap(retarget)
        XCTAssertEqual(try readSQLiteProviders(at: changedTree.replacementHome), ["anthropic"])
        XCTAssertEqual(try String(contentsOf: changedTree.sentinel, encoding: .utf8), "replacement-sentinel-before\n")
    }

    func testReviewFix4PostReportRootRetargetCannotCommit() throws {
        let fixture = try makeFixture()
        let backupPath = try createSyncedBackupAndSeedRollbackDestination(fixture)
        var retarget: ProviderSyncRootRetarget?
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            reportWillBuild: {
                guard retarget == nil else { return }
                retarget = try self.retargetHomeRoot(fixture) { replacement, _ in
                    try self.seedStateDatabase(at: replacement)
                }
            }
        )
        var message = ""

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)) { error in
            message = error.localizedDescription
        }
        let changedTree = try XCTUnwrap(retarget)
        let journal = try XCTUnwrap(transactionRoots(in: changedTree.detachedHome).first)
        XCTAssertTrue(message.contains(".provider-restore-transaction-"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: journal.path).isEmpty)
        XCTAssertEqual(try String(contentsOf: changedTree.sentinel, encoding: .utf8), "replacement-sentinel-before\n")
    }

    func testReviewFix4PostReportAncestorRetargetCannotCommit() throws {
        let fixture = try makeFixture()
        let backupPath = try createSyncedBackupAndSeedRollbackDestination(fixture)
        try removePreRollbackGlobalStateFiles(fixture)
        let outsideBefore = try sessionData(id: "thread-a", provider: "outside-post-report")
        var retarget: ProviderSyncAncestorRetarget?
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            reportWillBuild: {
                guard retarget == nil else { return }
                retarget = try self.retargetActiveSessionAncestor(
                    fixture,
                    outsideDestinationData: outsideBefore
                )
            }
        )
        var message = ""

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)) { error in
            message = error.localizedDescription
        }
        let changedTree = try XCTUnwrap(retarget)
        XCTAssertEqual(try Data(contentsOf: changedTree.outsideDestination), outsideBefore)
        let journal = try XCTUnwrap(transactionRoots(in: fixture.codexHome).first)
        XCTAssertTrue(message.contains(journal.path))
        XCTAssertFalse(try journalOriginalFiles(in: journal).isEmpty)
    }

    func testReviewFix4DestinationSwapBeforeJournalIsRevertedWithoutSuccess() throws {
        let fixture = try makeFixture()
        let backupPath = try createSyncedBackupAndSeedRollbackDestination(fixture)
        try removePreRollbackGlobalStateFiles(fixture)
        let injectedData = try sessionData(id: "thread-a", provider: "destination-race")
        var didSwap = false
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            restoreDestinationWillJournal: { _, destination in
                guard !didSwap, self.isActiveSessionDestination(destination) else { return }
                didSwap = true
                try self.replaceSameNameEntry(at: destination, with: injectedData)
            }
        )

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath))
        XCTAssertTrue(didSwap)
        XCTAssertEqual(try Data(contentsOf: fixture.activeSession), injectedData)
    }

    func testReviewFix4JournalSwapBeforeOpenFailsBeforeDestinationMutation() throws {
        let fixture = try makeFixture()
        let backupSessionData = try Data(contentsOf: fixture.activeSession)
        let backupPath = try createSyncedBackupAndSeedRollbackDestination(fixture)
        let preRollbackData = try Data(contentsOf: fixture.activeSession)
        let injectedData = try sessionData(id: "thread-a", provider: "journal-preopen-race")
        var activeIndex: Int?
        var journalEntry: URL?
        var swappedAside: URL?
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            reportWillBuild: {
                throw NSError(
                    domain: "ProviderSyncEngineTests",
                    code: 920,
                    userInfo: [NSLocalizedDescriptionKey: "injected report failure for journal preopen race"]
                )
            },
            restoreWillApply: { index, destination in
                if self.isActiveSessionDestination(destination) {
                    activeIndex = index
                }
            },
            restoreJournalWillOpen: { index, journal in
                guard index == activeIndex, swappedAside == nil else { return }
                journalEntry = journal
                swappedAside = try self.exchangeJournalEntry(journal, with: injectedData)
            }
        )

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath))
        let journal = try XCTUnwrap(journalEntry)
        let aside = try XCTUnwrap(swappedAside)
        XCTAssertEqual(try Data(contentsOf: journal), injectedData)
        XCTAssertEqual(try Data(contentsOf: aside), preRollbackData)
        XCTAssertEqual(try Data(contentsOf: fixture.activeSession), backupSessionData)
    }

    func testReviewFix4JournalSwapAfterReadFailsBeforeDestinationMutation() throws {
        let fixture = try makeFixture()
        let backupSessionData = try Data(contentsOf: fixture.activeSession)
        let backupPath = try createSyncedBackupAndSeedRollbackDestination(fixture)
        let preRollbackData = try Data(contentsOf: fixture.activeSession)
        let injectedData = try sessionData(id: "thread-a", provider: "journal-postread-race")
        var activeIndex: Int?
        var journalEntry: URL?
        var swappedAside: URL?
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            reportWillBuild: {
                throw NSError(
                    domain: "ProviderSyncEngineTests",
                    code: 921,
                    userInfo: [NSLocalizedDescriptionKey: "injected report failure for journal postread race"]
                )
            },
            restoreWillApply: { index, destination in
                if self.isActiveSessionDestination(destination) {
                    activeIndex = index
                }
            },
            restoreJournalDidRead: { index, journal in
                guard index == activeIndex, swappedAside == nil else { return }
                journalEntry = journal
                swappedAside = try self.exchangeJournalEntry(journal, with: injectedData)
            }
        )

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath))
        let journal = try XCTUnwrap(journalEntry)
        let aside = try XCTUnwrap(swappedAside)
        XCTAssertEqual(try Data(contentsOf: journal), injectedData)
        XCTAssertEqual(try Data(contentsOf: aside), preRollbackData)
        XCTAssertEqual(try Data(contentsOf: fixture.activeSession), backupSessionData)
    }

    func testReviewFix4SessionSwapBeforeReplacementIsRevertedWithoutMutation() throws {
        let fixture = try makeFixture()
        let injectedData = try sessionData(id: "thread-a", provider: "session-final-race")
        var didSwap = false
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            sessionReplacementWillExchange: { destination in
                guard !didSwap, self.isActiveSessionDestination(destination) else { return }
                didSwap = true
                try self.replaceSameNameEntry(at: destination, with: injectedData)
            }
        )

        XCTAssertThrowsError(try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        ))
        XCTAssertTrue(didSwap)
        XCTAssertEqual(try Data(contentsOf: fixture.activeSession), injectedData)
    }

    func testReviewFix4CleanupFailureBeforeFirstUnlinkIsReportedAndRetained() throws {
        let fixture = try makeFixture()
        let backupPath = try createSyncedBackupAndSeedRollbackDestination(fixture)
        try removePreRollbackGlobalStateFiles(fixture)
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            restoreCleanupWillBegin: { journal in
                throw NSError(
                    domain: "ProviderSyncEngineTests",
                    code: 922,
                    userInfo: [NSLocalizedDescriptionKey: "cleanup before first unlink: \(journal.path)"]
                )
            }
        )

        try assertCleanupFailureIsReportedAndRetained(
            fixture: fixture,
            backupPath: backupPath,
            engine: engine,
            expectsRetainedMaterial: true
        )
    }

    func testReviewFix4CleanupFailureAfterPartialUnlinkIsReportedAndRetained() throws {
        let fixture = try makeFixture()
        let backupPath = try createSyncedBackupAndSeedRollbackDestination(fixture)
        try removePreRollbackGlobalStateFiles(fixture)
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            restoreCleanupDidRemoveEntry: { journal in
                throw NSError(
                    domain: "ProviderSyncEngineTests",
                    code: 923,
                    userInfo: [NSLocalizedDescriptionKey: "cleanup after partial unlink: \(journal.path)"]
                )
            }
        )

        try assertCleanupFailureIsReportedAndRetained(
            fixture: fixture,
            backupPath: backupPath,
            engine: engine,
            expectsRetainedMaterial: true
        )
    }

    func testReviewFix4CleanupFailureBeforeRootRemovalIsReportedAndRetained() throws {
        let fixture = try makeFixture()
        let backupPath = try createSyncedBackupAndSeedRollbackDestination(fixture)
        try removePreRollbackGlobalStateFiles(fixture)
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            restoreCleanupWillRemoveRoot: { journal in
                throw NSError(
                    domain: "ProviderSyncEngineTests",
                    code: 924,
                    userInfo: [NSLocalizedDescriptionKey: "cleanup before root removal: \(journal.path)"]
                )
            }
        )

        try assertCleanupFailureIsReportedAndRetained(
            fixture: fixture,
            backupPath: backupPath,
            engine: engine,
            expectsRetainedMaterial: false
        )
    }

    private func retargetHomeRoot(
        _ fixture: ProviderSyncFixture,
        populateReplacement: (URL, URL) throws -> Void
    ) throws -> ProviderSyncRootRetarget {
        let detachedHome = fixture.codexHome.deletingLastPathComponent()
            .appendingPathComponent("codex-home-detached-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.codexHome, to: detachedHome)
        try FileManager.default.createDirectory(at: fixture.codexHome, withIntermediateDirectories: false)
        try populateReplacement(fixture.codexHome, detachedHome)
        let sentinel = fixture.codexHome.appendingPathComponent("replacement-sentinel.txt")
        try "replacement-sentinel-before\n".write(
            to: sentinel,
            atomically: true,
            encoding: .utf8
        )
        return ProviderSyncRootRetarget(
            detachedHome: detachedHome,
            replacementHome: fixture.codexHome,
            sentinel: sentinel
        )
    }

    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        for item in try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            try FileManager.default.copyItem(
                at: item,
                to: destination.appendingPathComponent(item.lastPathComponent)
            )
        }
    }

    private func readSQLiteTimestampMilliseconds(at codexHome: URL) throws -> [String: Int64] {
        let driver = SQLiteDatabaseDriver(
            url: codexHome.appendingPathComponent("state_5.sqlite"),
            readOnly: true
        )
        let rows = try driver.readRows(
            "SELECT id, COALESCE(updated_at_ms, 0) FROM threads ORDER BY id ASC;"
        ) { statement in
            (statement.text(0) ?? "", statement.int64(1) ?? 0)
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    private func writeGlobalStateFixture(
        projectOrder: [String],
        savedRoots: [String],
        to file: URL
    ) throws {
        try writeJSON(
            [
                "project-order": projectOrder,
                "electron-saved-workspace-roots": savedRoots,
                "active-workspace-roots": savedRoots
            ],
            to: file
        )
    }

    private func replaceSameNameEntry(at destination: URL, with data: Data) throws {
        let replacement = destination.deletingLastPathComponent()
            .appendingPathComponent("same-name-race-\(UUID().uuidString)")
        try data.write(to: replacement)
        guard Darwin.rename(replacement.path, destination.path) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "same-name race rename failed"]
            )
        }
    }

    private func exchangeJournalEntry(_ journal: URL, with data: Data) throws -> URL {
        let aside = journal.deletingLastPathComponent()
            .appendingPathComponent("journal-race-aside-\(UUID().uuidString)")
        try data.write(to: aside)
        guard renameatx_np(
            AT_FDCWD,
            journal.path,
            AT_FDCWD,
            aside.path,
            UInt32(RENAME_SWAP)
        ) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "journal race exchange failed"]
            )
        }
        return aside
    }

    private func assertCleanupFailureIsReportedAndRetained(
        fixture: ProviderSyncFixture,
        backupPath: String,
        engine: ProviderSyncEngine,
        expectsRetainedMaterial: Bool
    ) throws {
        var message = ""
        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)) { error in
            message = error.localizedDescription
        }
        let journal = try XCTUnwrap(transactionRoots(in: fixture.codexHome).first)
        XCTAssertTrue(message.contains(journal.path))
        let contents = try FileManager.default.contentsOfDirectory(atPath: journal.path)
        if expectsRetainedMaterial {
            XCTAssertFalse(contents.isEmpty)
        } else {
            XCTAssertTrue(contents.isEmpty)
        }
    }

    private func removePreRollbackGlobalStateFiles(_ fixture: ProviderSyncFixture) throws {
        for name in [".codex-global-state.json", ".codex-global-state.json.bak"] {
            let file = fixture.codexHome.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    private func assertRetargetedRestorePreservesOutsideAndJournal(
        fixture: ProviderSyncFixture,
        backupPath: String,
        outsideBefore: Data,
        retarget: () -> ProviderSyncAncestorRetarget?,
        operation: () throws -> ProviderSyncSnapshot
    ) throws {
        var message = ""
        XCTAssertThrowsError(try operation()) { error in
            message = error.localizedDescription
        }
        let changedTree = try XCTUnwrap(retarget(), "backup: \(backupPath)")
        XCTAssertEqual(try Data(contentsOf: changedTree.outsideDestination), outsideBefore)
        XCTAssertEqual(
            try String(contentsOf: changedTree.outsideSentinel, encoding: .utf8),
            "outside-sentinel-before\n"
        )
        let journal = try XCTUnwrap(transactionRoots(in: fixture.codexHome).first)
        XCTAssertTrue(message.contains(journal.path))
        XCTAssertFalse(try journalOriginalFiles(in: journal).isEmpty)
    }

    private func retargetActiveSessionAncestor(
        _ fixture: ProviderSyncFixture,
        outsideDestinationData: Data
    ) throws -> ProviderSyncAncestorRetarget {
        let ancestor = fixture.activeSession
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let detachedAncestor = ancestor.deletingLastPathComponent()
            .appendingPathComponent("07-detached-\(UUID().uuidString)", isDirectory: true)
        let outsideRoot = fixture.codexHome.deletingLastPathComponent()
            .appendingPathComponent("outside-session-\(UUID().uuidString)", isDirectory: true)
        let outsideParent = outsideRoot.appendingPathComponent("06", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideParent, withIntermediateDirectories: true)
        let outsideDestination = outsideParent.appendingPathComponent("thread-a.jsonl")
        try outsideDestinationData.write(to: outsideDestination)
        let outsideSentinel = outsideRoot.appendingPathComponent("sentinel.txt")
        try "outside-sentinel-before\n".write(to: outsideSentinel, atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: ancestor, to: detachedAncestor)
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: outsideRoot)
        return ProviderSyncAncestorRetarget(
            ancestor: ancestor,
            detachedAncestor: detachedAncestor,
            outsideDestination: outsideDestination,
            outsideSentinel: outsideSentinel
        )
    }

    private func isActiveSessionDestination(_ destination: URL) -> Bool {
        destination.path.hasSuffix("/sessions/2026/07/06/thread-a.jsonl")
    }

    private func journalOriginalFiles(in journal: URL) throws -> [URL] {
        let originals = journal.appendingPathComponent("originals", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: originals,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private func createSyncedBackupAndSeedRollbackDestination(_ fixture: ProviderSyncFixture) throws -> String {
        let setupEngine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )
        let synced = try setupEngine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: true,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )
        try seedPreRollbackDestination(fixture)
        return try XCTUnwrap(synced.lastBackupPath)
    }

    private func transactionRoots(in codexHome: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: codexHome,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ).filter { $0.lastPathComponent.hasPrefix(".provider-restore-transaction-") }
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    private func manifestFiles(in backupRoot: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: backupRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.lastPathComponent == "manifest.json" else { return nil }
            return url
        }
    }

    private func makeFixture() throws -> ProviderSyncFixture {
        let root = try makeTemporaryDirectory(named: "ProviderSyncEngine")
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let sessions = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("07", isDirectory: true)
            .appendingPathComponent("06", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let activeSession = sessions.appendingPathComponent("thread-a.jsonl")
        try writeSession(id: "thread-a", provider: "anthropic", to: activeSession)

        let unrelatedSessionFile = sessions.appendingPathComponent("keep-me.txt")
        let unrelatedSessionText = "do not touch this session neighbor\n"
        try unrelatedSessionText.write(to: unrelatedSessionFile, atomically: true, encoding: .utf8)

        let archivedSessions = codexHome
            .appendingPathComponent("archived_sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
        try FileManager.default.createDirectory(at: archivedSessions, withIntermediateDirectories: true)
        let archivedSession = archivedSessions.appendingPathComponent("thread-archived.jsonl")
        try writeSession(id: "thread-archived", provider: "anthropic", to: archivedSession)

        let sessionIndex = codexHome.appendingPathComponent("session_index.jsonl")
        let originalSessionIndexText = #"{"id":"old-thread","thread_name":"Old","updated_at":"2026-07-01T00:00:00.000Z"}"# + "\n"
        try originalSessionIndexText.write(to: sessionIndex, atomically: true, encoding: .utf8)

        try seedStateDatabase(at: codexHome)

        return ProviderSyncFixture(
            codexHome: codexHome,
            backupRoot: backupRoot,
            activeSession: activeSession,
            archivedSession: archivedSession,
            unrelatedSessionFile: unrelatedSessionFile,
            unrelatedSessionText: unrelatedSessionText,
            sessionIndex: sessionIndex,
            originalSessionIndexText: originalSessionIndexText
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
    }

    private func makeLegacyBackup(
        fixture: ProviderSyncFixture,
        entries: [TestTarEntry],
        declaredCount: Int,
        rawCodexHome: String? = nil
    ) throws -> URL {
        let backup = fixture.backupRoot
            .appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try writeJSON(
            [
                "created_at": ISO8601DateFormatter().string(from: Date()),
                "codex_home": rawCodexHome ?? fixture.codexHome.path,
                "target_provider": "openai",
                "session_file_count": declaredCount
            ],
            to: backup.appendingPathComponent("manifest.json")
        )
        try writeUSTAR(entries: entries, to: backup.appendingPathComponent("session-jsonl.before.tar"))
        return backup
    }

    private func seedPreRollbackDestination(_ fixture: ProviderSyncFixture) throws {
        try "pre-rollback config\n".write(
            to: fixture.codexHome.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try "pre-rollback wal\n".write(
            to: URL(fileURLWithPath: fixture.codexHome.appendingPathComponent("state_5.sqlite").path + "-wal"),
            atomically: true,
            encoding: .utf8
        )
        try "pre-rollback shm\n".write(
            to: URL(fileURLWithPath: fixture.codexHome.appendingPathComponent("state_5.sqlite").path + "-shm"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.removeItem(at: fixture.sessionIndex)
        try "pre-rollback global state\n".write(
            to: fixture.codexHome.appendingPathComponent(".codex-global-state.json"),
            atomically: true,
            encoding: .utf8
        )
        try "pre-rollback global backup\n".write(
            to: fixture.codexHome.appendingPathComponent(".codex-global-state.json.bak"),
            atomically: true,
            encoding: .utf8
        )
        try writeSession(id: "thread-a", provider: "pre-rollback", to: fixture.activeSession)
        try writeSession(id: "thread-archived", provider: "pre-rollback", to: fixture.archivedSession)
    }

    private func assertInjectedRestoreFailurePreservesDestination(
        injector: @escaping (Int, URL) throws -> Void
    ) throws {
        let fixture = try makeFixture()
        let setupEngine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false }
        )
        let synced = try setupEngine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: true,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )
        let backupPath = try XCTUnwrap(synced.lastBackupPath)
        try seedPreRollbackDestination(fixture)
        let before = try rollbackDestinationState(for: fixture)
        let engine = ProviderSyncEngine(
            backupRoot: fixture.backupRoot,
            applicationRunningProbe: { false },
            restoreWillApply: injector
        )

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath))
        XCTAssertEqual(try rollbackDestinationState(for: fixture), before)
    }

    private func rollbackDestinationState(for fixture: ProviderSyncFixture) throws -> [String: CapturedFileState] {
        let relativePaths = [
            "config.toml",
            "state_5.sqlite",
            "state_5.sqlite-wal",
            "state_5.sqlite-shm",
            "session_index.jsonl",
            ".codex-global-state.json",
            ".codex-global-state.json.bak",
            "sessions/2026/07/06/thread-a.jsonl",
            "archived_sessions/2026/thread-archived.jsonl"
        ]
        return try Dictionary(uniqueKeysWithValues: relativePaths.map { relativePath in
            let url = fixture.codexHome.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                return (relativePath, .bytes(try Data(contentsOf: url)))
            }
            return (relativePath, .absent)
        })
    }

    private func writeUSTAR(entries: [TestTarEntry], to archive: URL) throws {
        var output = Data()
        for entry in entries {
            var header = Data(repeating: 0, count: 512)
            let path = try splitUSTARPath(entry.name)
            writeASCII(path.name, to: &header, offset: 0, length: 100)
            writeOctal(0o644, to: &header, offset: 100, length: 8)
            writeOctal(0, to: &header, offset: 108, length: 8)
            writeOctal(0, to: &header, offset: 116, length: 8)
            writeOctal(entry.type == .regular ? entry.data.count : 0, to: &header, offset: 124, length: 12)
            writeOctal(0, to: &header, offset: 136, length: 12)
            header.replaceSubrange(148..<156, with: Data(repeating: 0x20, count: 8))
            header[156] = entry.type.rawValue
            writeASCII(entry.linkName, to: &header, offset: 157, length: 100)
            writeASCII("ustar", to: &header, offset: 257, length: 6)
            writeASCII("00", to: &header, offset: 263, length: 2)
            writeASCII(path.prefix, to: &header, offset: 345, length: 155)
            let checksum = header.reduce(0) { $0 + Int($1) }
            let checksumText = String(format: "%06o\0 ", checksum)
            writeASCII(checksumText, to: &header, offset: 148, length: 8)
            output.append(header)
            if entry.type == .regular {
                output.append(entry.data)
                let padding = (512 - (entry.data.count % 512)) % 512
                output.append(Data(repeating: 0, count: padding))
            }
        }
        output.append(Data(repeating: 0, count: 1024))
        try output.write(to: archive, options: .atomic)
    }

    private func splitUSTARPath(_ path: String) throws -> (name: String, prefix: String) {
        guard path.utf8.count <= 255 else {
            throw NSError(domain: "ProviderSyncEngineTests", code: 903)
        }
        if path.utf8.count <= 100 {
            return (path, "")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for splitIndex in stride(from: components.count - 1, through: 1, by: -1) {
            let prefix = components[..<splitIndex].joined(separator: "/")
            let name = components[splitIndex...].joined(separator: "/")
            if prefix.utf8.count <= 155, name.utf8.count <= 100 {
                return (name, prefix)
            }
        }
        throw NSError(domain: "ProviderSyncEngineTests", code: 904)
    }

    private func writeASCII(_ string: String, to data: inout Data, offset: Int, length: Int) {
        let bytes = Array(string.utf8.prefix(length))
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    private func writeOctal(_ value: Int, to data: inout Data, offset: Int, length: Int) {
        let text = String(format: "%0*o", length - 1, value) + "\0"
        writeASCII(text, to: &data, offset: offset, length: length)
    }

    private func disposableState(for fixture: ProviderSyncFixture) throws -> ProviderSyncDisposableState {
        ProviderSyncDisposableState(
            activeSession: try Data(contentsOf: fixture.activeSession),
            archivedSession: try Data(contentsOf: fixture.archivedSession),
            sqlite: try Data(contentsOf: fixture.codexHome.appendingPathComponent("state_5.sqlite")),
            sessionIndex: try Data(contentsOf: fixture.sessionIndex),
            backupEntries: try FileManager.default.contentsOfDirectory(atPath: fixture.backupRoot.path).sorted()
        )
    }

    private func sessionData(id: String, provider: String) throws -> Data {
        let lines = [
            encodeLine([
                "timestamp": "2026-07-06T01:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": id,
                    "model_provider": provider
                ]
            ]),
            encodeLine([
                "timestamp": "2026-07-06T01:01:00.000Z",
                "type": "event_msg",
                "payload": [
                    "type": "agent_message",
                    "message": "hello"
                ]
            ])
        ]
        return Data(lines.joined(separator: "\n").appending("\n").utf8)
    }

    private func writeSession(id: String, provider: String, to file: URL) throws {
        try sessionData(id: id, provider: provider).write(to: file, options: .atomic)
    }

    private func seedStateDatabase(at codexHome: URL) throws {
        let driver = SQLiteDatabaseDriver(url: codexHome.appendingPathComponent("state_5.sqlite"))
        try driver.execute("""
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            title TEXT,
            first_user_message TEXT,
            preview TEXT,
            source TEXT,
            cwd TEXT,
            archived INTEGER,
            thread_source TEXT,
            model_provider TEXT,
            updated_at INTEGER,
            updated_at_ms INTEGER
        );
        """)
        try driver.execute(
            """
            INSERT INTO threads (
                id, title, first_user_message, preview, source, cwd, archived,
                thread_source, model_provider, updated_at, updated_at_ms
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text("thread-a"),
                .text("Thread A"),
                .text("first"),
                .text("preview"),
                .text("vscode"),
                .text("/tmp/workspace"),
                .int(0),
                .text("user"),
                .text("anthropic"),
                .int64(1_783_468_800),
                .int64(1_783_468_800_000)
            ]
        )
    }

    private func seedTimestampCollisionRows(at codexHome: URL, ids: [String]) throws {
        let driver = SQLiteDatabaseDriver(url: codexHome.appendingPathComponent("state_5.sqlite"))
        for id in ids {
            try driver.execute(
                """
                INSERT INTO threads (
                    id, title, first_user_message, preview, source, cwd, archived,
                    thread_source, model_provider, updated_at, updated_at_ms
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(id),
                    .text(id),
                    .text("first"),
                    .text("preview"),
                    .text("vscode"),
                    .text("/tmp/workspace"),
                    .int(0),
                    .text("user"),
                    .text("anthropic"),
                    .int64(1_783_468_800),
                    .int64(1_783_468_800_000)
                ]
            )
        }
    }

    private func readSessionProvider(at file: URL) throws -> String? {
        let line = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)
        let data = try XCTUnwrap(line?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        return payload["model_provider"] as? String
    }

    private func readSQLiteProviders(at codexHome: URL) throws -> [String] {
        try readSQLiteProviders(inDatabase: codexHome.appendingPathComponent("state_5.sqlite"))
    }

    private func readSQLiteProviders(inDatabase database: URL) throws -> [String] {
        let driver = SQLiteDatabaseDriver(url: database, readOnly: true)
        return try driver.readRows("SELECT model_provider FROM threads ORDER BY id ASC;") { statement in
            statement.text(0) ?? ""
        }
    }

    private func encodeLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func writeJSON(_ object: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: [.atomic])
    }

    private func appendToTar(file: URL, archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-rf", archive.path, "-C", "/", String(file.path.dropFirst())]
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "tar append failed"
            throw NSError(domain: "ProviderSyncEngineTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func tarMembers(archive: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tf", archive.path]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "tar list failed"
            throw NSError(domain: "ProviderSyncEngineTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init).sorted()
    }
}

private final class SynchronizedProviderSyncResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<ProviderSyncSnapshot, Error>?

    func set(_ result: Result<ProviderSyncSnapshot, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func get() -> Result<ProviderSyncSnapshot, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct ProviderSyncFixture {
    let codexHome: URL
    let backupRoot: URL
    let activeSession: URL
    let archivedSession: URL
    let unrelatedSessionFile: URL
    let unrelatedSessionText: String
    let sessionIndex: URL
    let originalSessionIndexText: String
}

private struct ProviderSyncAncestorRetarget {
    let ancestor: URL
    let detachedAncestor: URL
    let outsideDestination: URL
    let outsideSentinel: URL
}

private struct ProviderSyncRootRetarget {
    let detachedHome: URL
    let replacementHome: URL
    let sentinel: URL
}

private struct ProviderSyncDisposableState: Equatable {
    let activeSession: Data
    let archivedSession: Data
    let sqlite: Data
    let sessionIndex: Data
    let backupEntries: [String]
}

private enum CapturedFileState: Equatable {
    case absent
    case bytes(Data)
}

private struct TestTarEntry {
    enum EntryType: UInt8 {
        case regular = 48
        case hardLink = 49
        case symbolicLink = 50
        case characterDevice = 51
        case blockDevice = 52
        case directory = 53
        case fifo = 54
    }

    let name: String
    let type: EntryType
    let data: Data
    let linkName: String

    init(
        name: String,
        type: EntryType = .regular,
        data: Data = Data("archived session\n".utf8),
        linkName: String = ""
    ) {
        self.name = name
        self.type = type
        self.data = data
        self.linkName = linkName
    }
}
