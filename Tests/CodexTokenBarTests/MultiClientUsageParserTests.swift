import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import CodexTokenBar

final class MultiClientUsageParserTests: XCTestCase {
    func testClaudeDiscoveryIncludesOnlyRegisteredAccountProjectsAndKeepsClassification() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-accounts-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let accounts = home.appendingPathComponent(".local/share/claude-adapter/accounts")
        let accountID = String(repeating: "a", count: 32)
        let paths = [
            home.appendingPathComponent(".claude/projects/p/old.jsonl"),
            home.appendingPathComponent(".claude-official-guarded/projects/p/guarded.jsonl"),
            accounts.appendingPathComponent("\(accountID)/code/projects/p/new.jsonl"),
            accounts.appendingPathComponent("\(accountID)/desktop/projects/p/not-a-transcript-root.jsonl"),
            accounts.appendingPathComponent("\(String(repeating: "b", count: 32))/code/projects/p/unregistered.jsonl"),
        ]
        for (index, path) in paths.enumerated() {
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jsonl([claudeLine(session: "s\(index)", entrypoint: index == 2 ? "claude-desktop-3p" : "cli",
                id: "m\(index)", timestamp: "2026-11-26T10:00:00Z", usage: ["input_tokens": 10])]).write(to: path)
        }
        let registry: [String: Any] = ["version": 1, "accounts": [["id": "existing"], ["id": accountID]]]
        try JSONSerialization.data(withJSONObject: registry).write(to: accounts.appendingPathComponent("registry.json"))
        let cli = MultiClientUsageDiscovery.discover(client: .claudeCode, home: home, environment: [:])
        let desktop = MultiClientUsageDiscovery.discover(client: .claudeDesktop, home: home, environment: [:])
        XCTAssertFalse(cli.truncated); XCTAssertFalse(desktop.truncated)
        XCTAssertEqual(Set(cli.files), Set(paths.prefix(2)))
        XCTAssertEqual(desktop.files, [paths[2]])
        let paired = MultiClientUsageDiscovery.discoverClaudePair(home: home, environment: [:])
        XCTAssertEqual(paired.code.files, cli.files)
        XCTAssertEqual(paired.desktop.files, desktop.files)
        XCTAssertFalse(paired.code.truncated); XCTAssertFalse(paired.desktop.truncated)
        XCTAssertEqual(paired.classificationCount, 3)

        // Selecting an account via the environment still produces one physical source,
        // with the selected logical path retained for existing checkpoints.
        let alias = home.appendingPathComponent("selected")
        try fm.createSymbolicLink(at: alias, withDestinationURL: paths[2].deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        let selected = MultiClientUsageDiscovery.discover(client: .claudeDesktop, home: home,
            environment: ["CLAUDE_CONFIG_DIR": alias.path])
        XCTAssertEqual(selected.files, [alias.appendingPathComponent("projects/p/new.jsonl")])
        XCTAssertFalse(selected.truncated)
        let selectedPair = MultiClientUsageDiscovery.discoverClaudePair(home: home,
            environment: ["CLAUDE_CONFIG_DIR": alias.path])
        XCTAssertEqual(selectedPair.desktop.files, selected.files)
        XCTAssertEqual(selectedPair.code.files, [paths[1]])
        XCTAssertEqual(selectedPair.classificationCount, 2)
        XCTAssertFalse(selectedPair.code.truncated); XCTAssertFalse(selectedPair.desktop.truncated)
    }

    func testClaudePairedDiscoveryMatchesIndependentResultsAndReadsEachCandidateOnce() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-paired-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let project = home.appendingPathComponent(".claude/projects/p")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let fixtures: [(String, Data)] = [
            ("01-cli.jsonl", Data("{\"entrypoint\":\"cli\"}\n{\"entrypoint\":\"claude-desktop-3p\"}\n".utf8)),
            ("02-desktop.jsonl", Data("{\"type\":\"system\"}\n{\"entrypoint\":\"claude-desktop-3p\"}\n{\"entrypoint\":\"cli\"}\n".utf8)),
            ("03-metadata.jsonl", Data("{\"type\":\"system\"}\n".utf8)),
            ("04-partial.jsonl", Data("{\"entrypoint\":\"claude-desktop-3p\"}".utf8)),
            ("05-empty.jsonl", Data()),
            ("06-bom.jsonl", Data("\u{FEFF}{\"entrypoint\":\"claude-desktop\"}\r\n".utf8)),
        ]
        let modified = Date(timeIntervalSince1970: 1_793_000_000)
        for (name, data) in fixtures {
            let path = project.appendingPathComponent(name)
            try data.write(to: path)
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
        }

        let code = MultiClientUsageDiscovery.discover(client: .claudeCode, home: home, environment: [:])
        let desktop = MultiClientUsageDiscovery.discover(client: .claudeDesktop, home: home, environment: [:])
        let paired = MultiClientUsageDiscovery.discoverClaudePair(home: home, environment: [:])
        XCTAssertEqual(paired.code.files, code.files)
        XCTAssertEqual(paired.desktop.files, desktop.files)
        XCTAssertEqual(paired.code.truncated, code.truncated)
        XCTAssertEqual(paired.desktop.truncated, desktop.truncated)
        XCTAssertEqual(code.files.map(\.lastPathComponent), ["01-cli.jsonl", "03-metadata.jsonl", "05-empty.jsonl"])
        XCTAssertEqual(desktop.files.map(\.lastPathComponent), ["02-desktop.jsonl", "06-bom.jsonl"])
        XCTAssertTrue(code.truncated); XCTAssertTrue(desktop.truncated)
        // Every fixture fits one classification read and neither independent selection stops
        // early, so the two independent calls open/read exactly twice the paired work.
        XCTAssertEqual(paired.classificationCount, fixtures.count)
        XCTAssertEqual(paired.classificationBytesRead, fixtures.reduce(0) { $0 + $1.1.count })
    }

    func testClaudePairedDiscoveryClassifiesValidFirstRecordBeyond64KiB() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-paired-limit-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let project = home.appendingPathComponent(".claude/projects/p")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let limited = project.appendingPathComponent("limited.jsonl")
        let desktop = project.appendingPathComponent("desktop.jsonl")
        let desktopRecord = Data("{\"entrypoint\":\"claude-desktop-3p\"}\n".utf8)
        var longRecord = Data("{\"content\":\"".utf8)
        longRecord.append(Data(repeating: 0x78, count: 64 * 1_024))
        longRecord.append(Data("\",\"entrypoint\":\"claude-desktop-3p\"}\n".utf8))
        XCTAssertGreaterThan(longRecord.count, 64 * 1_024)
        try longRecord.write(to: limited)
        try desktopRecord.write(to: desktop)

        let paired = MultiClientUsageDiscovery.discoverClaudePair(home: home, environment: [:])
        let independentCode = MultiClientUsageDiscovery.discover(client: .claudeCode, home: home, environment: [:])
        let independentDesktop = MultiClientUsageDiscovery.discover(client: .claudeDesktop, home: home, environment: [:])
        XCTAssertTrue(paired.code.files.isEmpty)
        XCTAssertEqual(Set(paired.desktop.files), Set([limited, desktop]))
        XCTAssertEqual(paired.code.files, independentCode.files)
        XCTAssertEqual(Set(paired.desktop.files), Set(independentDesktop.files))
        XCTAssertFalse(paired.code.truncated); XCTAssertFalse(paired.desktop.truncated)
        XCTAssertEqual(paired.code.truncated, independentCode.truncated)
        XCTAssertEqual(paired.desktop.truncated, independentDesktop.truncated)
        XCTAssertEqual(paired.classificationCount, 2)
        XCTAssertEqual(paired.classificationBytesRead, longRecord.count + desktopRecord.count)
    }

    func testClaudePairedDiscoveryKeepsIndependentTotalClassificationByteBudgets() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-paired-budget-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let project = home.appendingPathComponent(".claude/projects/p")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let modified = Date(timeIntervalSince1970: 1_793_000_000)
        // Sparse, unclassified files reach the existing 64 MiB per-client read budget.
        // The last, otherwise valid Desktop file must remain outside both selections.
        for index in 0...1_024 {
            let path = project.appendingPathComponent(String(format: "%04d.jsonl", index))
            if index == 1_024 {
                try Data("{\"entrypoint\":\"claude-desktop-3p\"}\n".utf8).write(to: path)
            } else {
                XCTAssertTrue(fm.createFile(atPath: path.path, contents: nil))
                let handle = try FileHandle(forWritingTo: path)
                try handle.truncate(atOffset: 64 * 1_024)
                try handle.close()
            }
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
        }

        let paired = MultiClientUsageDiscovery.discoverClaudePair(home: home, environment: [:])
        let code = MultiClientUsageDiscovery.discover(client: .claudeCode, home: home, environment: [:])
        let desktop = MultiClientUsageDiscovery.discover(client: .claudeDesktop, home: home, environment: [:])
        XCTAssertEqual(paired.code.files, code.files)
        XCTAssertEqual(paired.desktop.files, desktop.files)
        XCTAssertTrue(paired.code.files.isEmpty)
        XCTAssertTrue(paired.desktop.files.isEmpty)
        XCTAssertEqual(paired.classificationCount, 1_024)
        XCTAssertEqual(paired.classificationBytesRead, 64 * 1_024 * 1_024)
        XCTAssertTrue(code.truncated); XCTAssertTrue(desktop.truncated)
        XCTAssertEqual(paired.code.truncated, code.truncated)
        XCTAssertEqual(paired.desktop.truncated, desktop.truncated)
        let resumed = MultiClientUsageDiscovery.discoverClaudePair(
            home: home,
            environment: [:],
            resumeAfterSourceKey: paired.nextClaudeSourceKey
        )
        XCTAssertEqual(resumed.desktop.files, [project.appendingPathComponent("1024.jsonl")])
        XCTAssertLessThanOrEqual(resumed.classificationBytesRead, 64 * 1_024 * 1_024)
        XCTAssertTrue(resumed.desktop.truncated)
    }

    func testClaudeScannerRotatesAfterClassificationBudgetExhaustion() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-scan-fairness-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let project = home.appendingPathComponent(".claude/projects/p")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let modified = Date(timeIntervalSince1970: 1_793_000_000)
        let blockerBytes = UInt64(16 * 1_024 * 1_024)
        for index in 0..<4 {
            let path = project.appendingPathComponent(String(format: "%04d-incomplete.jsonl", index))
            XCTAssertTrue(fm.createFile(atPath: path.path, contents: Data()))
            let handle = try FileHandle(forWritingTo: path)
            try handle.truncate(atOffset: blockerBytes)
            try handle.close()
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
        }
        let validDesktop = project.appendingPathComponent("9999-desktop.jsonl")
        try jsonl([claudeLine(
            session: "desktop-session",
            entrypoint: "claude-desktop-3p",
            id: "desktop-event",
            timestamp: "2026-11-26T10:00:00Z",
            usage: ["input_tokens": 123, "output_tokens": 17]
        )]).write(to: validDesktop)
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: validDesktop.path)

        var code = try XCTUnwrap(MultiClientUsagePreference.defaults.first { $0.client == .claudeCode })
        var desktop = try XCTUnwrap(MultiClientUsagePreference.defaults.first { $0.client == .claudeDesktop })
        code.enabled = true
        desktop.enabled = true
        let scanner = MultiClientUsageScanner(
            databaseURL: home.appendingPathComponent("usage.sqlite"),
            home: home,
            environment: [:]
        )

        let first = try await scanner.scan([code, desktop], includesCharts: false)
        XCTAssertTrue(first.summaries.isEmpty)
        XCTAssertTrue(first.diagnostics.contains { $0.contains("自动发现未完整完成") })

        let second = try await scanner.scan([code, desktop], includesCharts: false)
        XCTAssertEqual(second.summaries.first { $0.client == .claudeDesktop }?.inputTokens, 123)
        XCTAssertNil(second.summaries.first { $0.client == .claudeCode })
    }

    func testClaudePairedDiscoveryReclassifiesAppendedAndRewrittenFilesOnEveryCall() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-paired-reclassify-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let file = home.appendingPathComponent(".claude/projects/p/session.jsonl")
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = Data("{\"entrypoint\":\"claude-desktop-3p\"}".utf8)
        let modified = Date(timeIntervalSince1970: 1_793_000_000)
        try record.write(to: file)
        let partial = MultiClientUsageDiscovery.discoverClaudePair(home: home, environment: [:])
        XCTAssertTrue(partial.code.files.isEmpty)
        XCTAssertTrue(partial.desktop.files.isEmpty)
        XCTAssertTrue(partial.code.truncated); XCTAssertTrue(partial.desktop.truncated)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0x0A])); try handle.close()
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let appended = MultiClientUsageDiscovery.discoverClaudePair(home: home, environment: [:])
        XCTAssertTrue(appended.code.files.isEmpty)
        XCTAssertEqual(appended.desktop.files, [file])
        XCTAssertFalse(appended.code.truncated); XCTAssertFalse(appended.desktop.truncated)

        var rewritten = Data("{\"entrypoint\":\"cli\"}".utf8)
        rewritten.append(Data(repeating: 0x20, count: record.count - rewritten.count))
        rewritten.append(0x0A)
        try rewritten.write(to: file)
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let replaced = MultiClientUsageDiscovery.discoverClaudePair(home: home, environment: [:])
        XCTAssertEqual(replaced.code.files, [file])
        XCTAssertTrue(replaced.desktop.files.isEmpty)
        XCTAssertEqual(replaced.classificationCount, 1)
        XCTAssertEqual(replaced.classificationBytesRead, rewritten.count)
    }

    func testClaudeScannerReparsesSameSizeTailRewriteWithStablePrefixAndMtime() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-physical-witness-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let source = home.appendingPathComponent(".claude/projects/p/session.jsonl")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let filler = String(repeating: "x", count: 6_000)
        let text = "{\"entrypoint\":\"cli\",\"sessionId\":\"s\",\"type\":\"assistant\",\"timestamp\":\"2026-11-26T10:00:00Z\",\"message\":{\"id\":\"tail-edit\",\"model\":\"claude-opus\",\"content\":\"\(filler)\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":17}}}\n"
        let original = Data(text.utf8)
        XCTAssertGreaterThan(original.count, 4_096)
        try original.write(to: source)

        var code = try XCTUnwrap(MultiClientUsagePreference.defaults.first { $0.client == .claudeCode })
        code.enabled = true
        let scanner = MultiClientUsageScanner(databaseURL: home.appendingPathComponent("usage.sqlite"), home: home, environment: [:])
        let first = try await scanner.scan([code], includesCharts: false)
        XCTAssertEqual(first.summaries.first?.inputTokens, 1_000)
        let ledger = try MultiClientUsageLedger(url: home.appendingPathComponent("usage.sqlite"))
        let before = try SourceFileObservation.read(at: source)
        let originalDate = try XCTUnwrap(fm.attributesOfItem(atPath: source.path)[.modificationDate] as? Date)
        let oldRevisions = try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int64(0) ?? 0 }.first
        XCTAssertEqual(oldRevisions, 1)

        let oldToken = Data("1000".utf8)
        let newToken = Data("2000".utf8)
        let tokenRange = try XCTUnwrap(original.range(of: oldToken))
        XCTAssertGreaterThan(tokenRange.lowerBound, 4_096)
        let handle = try FileHandle(forWritingTo: source)
        try handle.seek(toOffset: UInt64(tokenRange.lowerBound))
        try handle.write(contentsOf: newToken)
        try handle.close()
        try fm.setAttributes([.modificationDate: originalDate], ofItemAtPath: source.path)
        let afterRewrite = try SourceFileObservation.read(at: source)
        XCTAssertNotEqual(before.physicalStamp, afterRewrite.physicalStamp)
        XCTAssertEqual(before.size, afterRewrite.size)
        XCTAssertEqual(before.modifiedAt, afterRewrite.modifiedAt, accuracy: 0.000001)

        let second = try await scanner.scan([code], includesCharts: false)
        XCTAssertEqual(second.summaries.first?.inputTokens, 2_000)
        let after = try MultiClientUsageLedger(url: home.appendingPathComponent("usage.sqlite"))
        let revised = try after.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int64(0) ?? 0 }.first
        XCTAssertEqual(revised, 2)
        let checkpoint = try XCTUnwrap(after.checkpoint(client: .claudeCode, sourceKey: MultiClientUsageLedger.sourceKey(for: source)))
        XCTAssertTrue(checkpoint.identity.contains("physical-v1:\(afterRewrite.physicalStamp)"))

        _ = try await scanner.scan([code], includesCharts: false)
        let stable = try after.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int64(0) ?? 0 }.first
        XCTAssertEqual(stable, 2)
    }

    func testClaudeScannerReclassifiesLegacyCheckpointBeforeSkippingAndPreservesOnIncompleteEvidence() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-legacy-classifier-gate-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let cases: [(String, Data, String)] = [
            ("other-client", jsonl([claudeLine(
                session: "desktop-session", entrypoint: "claude-desktop-3p", id: "desktop-event",
                timestamp: "2026-11-26T10:00:00Z", usage: ["input_tokens": 90]
            )]), "归属与当前客户端不符"),
            ("incomplete", Data("{\"entrypoint\":\"claude-desktop-3p\"}".utf8), "分类未完成"),
        ]

        for (name, sourceBytes, diagnostic) in cases {
            let source = home.appendingPathComponent(name).appendingPathComponent("session.jsonl")
            try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sourceBytes.write(to: source)
            let attributes = try fm.attributesOfItem(atPath: source.path)
            let size = Int64(sourceBytes.count)
            let modified = try XCTUnwrap((attributes[.modificationDate] as? Date)?.timeIntervalSince1970)
            let width = min(4_096, sourceBytes.count)
            let prefixDigest = SHA256.hash(data: sourceBytes.prefix(width)).map { String(format: "%02x", $0) }.joined()
            let rawIdentity = String(describing: attributes[.systemFileNumber] ?? "") + ":\(width):" + prefixDigest
            // This is the prior scanner's completed checkpoint contract. It would
            // have matched the file metadata and returned before entrypoint classification.
            let legacyCheckpoint = MultiClientFileCheckpoint(
                offset: size,
                size: size,
                modified: modified,
                identity: "claude-cache-lifetimes-v1|" + rawIdentity
            )
            let databaseURL = home.appendingPathComponent("\(name).sqlite")
            let ledger = try MultiClientUsageLedger(url: databaseURL)
            let sourceKey = MultiClientUsageLedger.sourceKey(for: source)
            let priorEvent = try XCTUnwrap(MultiClientUsageParsers.parse(
                data: jsonl([claudeLine(
                    session: "legacy-session", entrypoint: "cli", id: "legacy-\(name)",
                    timestamp: "2026-11-26T09:00:00Z", usage: ["input_tokens": 40]
                )]), client: .claudeCode, sessionHint: "legacy"
            ).first)
            _ = try ledger.ingest([priorEvent], client: .claudeCode, sourceKey: sourceKey, checkpoint: legacyCheckpoint)

            var code = try XCTUnwrap(MultiClientUsagePreference.defaults.first { $0.client == .claudeCode })
            code.enabled = true
            code.path = source.path // Exercise the scanner even when discovery classifies another client.
            let scanner = MultiClientUsageScanner(databaseURL: databaseURL, home: home, environment: [:])
            let result = try await scanner.scan([code], includesCharts: false)

            XCTAssertEqual(result.summaries.first?.inputTokens, 40, name)
            XCTAssertTrue(result.diagnostics.contains { $0.contains(diagnostic) }, name)
            let retained = try XCTUnwrap(ledger.checkpoint(client: .claudeCode, sourceKey: sourceKey), name)
            XCTAssertEqual(retained.offset, legacyCheckpoint.offset, name)
            XCTAssertEqual(retained.size, legacyCheckpoint.size, name)
            XCTAssertEqual(retained.modified, legacyCheckpoint.modified, name)
            XCTAssertEqual(retained.identity, legacyCheckpoint.identity, name)
            XCTAssertNil(try ledger.checkpoint(client: .claudeDesktop, sourceKey: sourceKey), name)
            XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_events") { $0.int64(0) ?? 0 }.first, 1, name)
            XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int64(0) ?? 0 }.first, 1, name)
        }
    }

    func testClaudeScannerKeepsExplicitPathsExclusiveWhenBothClientsAreEnabled() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-paired-explicit-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let paths = [
            home.appendingPathComponent(".claude/projects/p/automatic-code.jsonl"),
            home.appendingPathComponent(".claude/projects/p/automatic-desktop.jsonl"),
            home.appendingPathComponent("manual/desktop.jsonl"),
            home.appendingPathComponent("manual/code.jsonl"),
        ]
        for (index, path) in paths.enumerated() {
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jsonl([claudeLine(session: "s\(index)", entrypoint: [0, 3].contains(index) ? "cli" : "claude-desktop-3p",
                id: "m\(index)", timestamp: "2026-11-26T10:00:00Z", usage: ["input_tokens": (index + 1) * 10])]).write(to: path)
        }
        let cases: [(String, String, Int64, Int64)] = [
            ("", "", 10, 20),
            ("", paths[2].path, 10, 30),
            (paths[3].path, "", 40, 20),
            (paths[3].path, paths[2].path, 40, 30),
        ]
        for (index, scenario) in cases.enumerated() {
            var code = try XCTUnwrap(MultiClientUsagePreference.defaults.first { $0.client == .claudeCode })
            var desktop = try XCTUnwrap(MultiClientUsagePreference.defaults.first { $0.client == .claudeDesktop })
            code.enabled = true; code.path = scenario.0
            desktop.enabled = true; desktop.path = scenario.1
            let scanner = MultiClientUsageScanner(databaseURL: home.appendingPathComponent("case-\(index).sqlite"), home: home, environment: [:])
            let scanned = try await scanner.scan([code, desktop], includesCharts: false)
            XCTAssertEqual(scanned.summaries.first { $0.client == .claudeCode }?.inputTokens, scenario.2)
            XCTAssertEqual(scanned.summaries.first { $0.client == .claudeDesktop }?.inputTokens, scenario.3)
            XCTAssertEqual(scanned.summaries.reduce(0) { $0 + $1.requests }, 2)
        }
    }

    func testClaudeScannerPreservesLegacyCheckpointWhenTranscriptClassifiesAsOtherClient() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-legacy-owner-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let source = home.appendingPathComponent(".claude/projects/p/session.jsonl")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceBytes = jsonl([claudeLine(
            session: "desktop-session", entrypoint: "claude-desktop-3p", id: "desktop-event",
            timestamp: "2026-11-26T10:00:00Z", usage: ["input_tokens": 90]
        )])
        try sourceBytes.write(to: source)

        let ledger = try MultiClientUsageLedger(url: home.appendingPathComponent("usage.sqlite"))
        let sourceKey = MultiClientUsageLedger.sourceKey(for: source)
        let legacyEvent = try XCTUnwrap(MultiClientUsageParsers.parse(
            data: jsonl([claudeLine(
                session: "legacy-session", entrypoint: "cli", id: "legacy-event",
                timestamp: "2026-11-26T09:00:00Z", usage: ["input_tokens": 40]
            )]), client: .claudeCode, sessionHint: "legacy"
        ).first)
        let modified = try XCTUnwrap((try fm.attributesOfItem(atPath: source.path)[.modificationDate] as? Date)?.timeIntervalSince1970)
        let oldCheckpoint = MultiClientFileCheckpoint(
            offset: Int64(sourceBytes.count), size: Int64(sourceBytes.count), modified: modified, identity: "legacy-code"
        )
        _ = try ledger.ingest([legacyEvent], client: .claudeCode, sourceKey: sourceKey, checkpoint: oldCheckpoint)

        var code = try XCTUnwrap(MultiClientUsagePreference.defaults.first { $0.client == .claudeCode })
        var desktop = try XCTUnwrap(MultiClientUsagePreference.defaults.first { $0.client == .claudeDesktop })
        code.enabled = true
        desktop.enabled = true
        let scanner = MultiClientUsageScanner(databaseURL: ledger.url, home: home, environment: [:])
        let result = try await scanner.scan([code, desktop], includesCharts: false)

        XCTAssertEqual(result.summaries.first { $0.client == .claudeCode }?.inputTokens, 40)
        XCTAssertNil(result.summaries.first { $0.client == .claudeDesktop })
        XCTAssertTrue(result.diagnostics.contains { $0.contains("已有另一客户端账本归属") })
        let preserved = try XCTUnwrap(ledger.checkpoint(client: .claudeCode, sourceKey: sourceKey))
        XCTAssertEqual(preserved.offset, oldCheckpoint.offset)
        XCTAssertEqual(preserved.size, oldCheckpoint.size)
        XCTAssertEqual(preserved.modified, oldCheckpoint.modified)
        XCTAssertEqual(preserved.identity, oldCheckpoint.identity)
        XCTAssertNil(try ledger.checkpoint(client: .claudeDesktop, sourceKey: sourceKey))
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_events") { $0.int64(0) ?? 0 }.first, 1)
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int64(0) ?? 0 }.first, 1)
    }

    func testClaudeAccountRegistryRejectsUnsafeIDsDuplicatesOversizeAndLinks() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-registry-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let accounts = home.appendingPathComponent(".local/share/claude-adapter/accounts")
        try fm.createDirectory(at: accounts, withIntermediateDirectories: true)
        let registry = accounts.appendingPathComponent("registry.json")
        let fallback = home.appendingPathComponent(".claude/projects", isDirectory: true)
        for value: [String: Any] in [
            ["version": 1, "accounts": [["id": "existing"], ["id": "../../outside"]]],
            ["version": 1, "accounts": [["id": "existing"], ["id": "existing"]]],
            ["version": true, "accounts": [["id": "existing"]]],
            ["version": 2, "accounts": [["id": "existing"]]],
            ["version": 1, "accounts": Array(repeating: ["id": "existing"], count: 17)],
        ] {
            try JSONSerialization.data(withJSONObject: value).write(to: registry)
            let result = MultiClientUsageDiscovery.claudeProjectRoots(home: home, environment: [:])
            XCTAssertEqual(result.paths, [fallback]); XCTAssertTrue(result.incomplete)
        }
        try Data(repeating: 0x20, count: 32_769).write(to: registry)
        XCTAssertTrue(MultiClientUsageDiscovery.discover(client: .claudeCode, home: home, environment: [:]).truncated)
        let paired = MultiClientUsageDiscovery.discoverClaudePair(home: home, environment: [:])
        XCTAssertTrue(paired.code.truncated); XCTAssertTrue(paired.desktop.truncated)
        try fm.removeItem(at: registry)
        try fm.createSymbolicLink(at: registry, withDestinationURL: home.appendingPathComponent("missing.json"))
        XCTAssertTrue(MultiClientUsageDiscovery.claudeProjectRoots(home: home, environment: [:]).incomplete)
    }

    func testClaudeCacheLifetimeFieldsKeepLegacyIdentityAndDoNotDoubleCountInput() throws {
        for withID in [false, true] {
            var message: [String: Any] = ["model": "claude-opus-5-5", "usage": ["input_tokens": 10, "output_tokens": 40, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 30]]
            if withID { message["id"] = "stable-id" }
            var root: [String: Any] = ["type": "assistant", "timestamp": "2026-11-03T10:00:00Z", "message": message]
            let old = try XCTUnwrap(try MultiClientUsageParsers.parse(data: JSONSerialization.data(withJSONObject: root), client: .claudeDesktop, sessionHint: "s").first)
            var usage = try XCTUnwrap(message["usage"] as? [String: Any])
            usage["cache_creation"] = ["ephemeral_5m_input_tokens": 10, "ephemeral_1h_input_tokens": 20]
            message["usage"] = usage; root["message"] = message
            let enriched = try XCTUnwrap(try MultiClientUsageParsers.parse(data: JSONSerialization.data(withJSONObject: root), client: .claudeDesktop, sessionHint: "s").first)
            XCTAssertEqual(old.eventID, enriched.eventID)
            XCTAssertEqual(enriched.inputTokens, 60); XCTAssertEqual(enriched.totalTokens, 100)
            XCTAssertEqual(enriched.cacheWrite5mTokens, 10); XCTAssertEqual(enriched.cacheWrite1hTokens, 20)
        }
        let raw = "inode:4096:hash"
        let revised = MultiClientUsageParsers.checkpointIdentity(raw, client: .claudeDesktop)
        XCTAssertNotEqual(raw, revised)
        XCTAssertEqual(MultiClientUsageParsers.checkpointIdentity(revised, client: .claudeDesktop), revised)
        XCTAssertEqual(MultiClientUsageParsers.checkpointIdentity(raw, client: .deepseek), raw)
    }
    func testSelectedClaudeRootLinkPreservesLogicalPathsAndDoesNotTraverseChildLinks() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("client-root-link-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let physical = root.appendingPathComponent("physical")
        let external = root.appendingPathComponent("external")
        for directory in [home.appendingPathComponent(".claude"), physical.appendingPathComponent("project"), external.appendingPathComponent("project")] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let line = claudeLine(session: "local", entrypoint: "cli", id: "a",
            timestamp: "2026-10-20T10:00:00Z", usage: ["input_tokens": 3, "output_tokens": 1])
        try jsonl([line]).write(to: physical.appendingPathComponent("project/session.jsonl"))
        try jsonl([line]).write(to: external.appendingPathComponent("project/outside.jsonl"))
        let logical = home.appendingPathComponent(".claude/projects")
        try manager.createSymbolicLink(at: logical, withDestinationURL: physical)
        try manager.createSymbolicLink(at: physical.appendingPathComponent("outside"), withDestinationURL: external)
        let found = MultiClientUsageDiscovery.discover(client: .claudeCode, home: home, environment: [:])
        XCTAssertFalse(found.truncated)
        XCTAssertEqual(found.files.map(\.path), [logical.appendingPathComponent("project/session.jsonl").path])
        let paired = MultiClientUsageDiscovery.discoverClaudePair(home: home, environment: [:])
        XCTAssertEqual(paired.code.files, found.files)
        XCTAssertTrue(paired.desktop.files.isEmpty)
        XCTAssertEqual(paired.classificationCount, 1)
        XCTAssertFalse(paired.code.truncated); XCTAssertFalse(paired.desktop.truncated)
    }

    func testDeepSeekNativeSessionHeaderNamesLaterLines() throws {
        let data = Data((#"{"type":"session","id":"native-session","version":4}"# + "\n" + #"{"type":"assistant/message","seq":2,"time":1797000000000,"data":{"usage":{"inputTokens":10,"outputTokens":2}}}"# + "\n").utf8)
        let events = try MultiClientUsageParsers.parse(data: data, client: .deepseek, sessionHint: "directory")
        XCTAssertEqual(events.first?.sessionID, "native-session")
    }

    func testJSONLLinePoolsKeepHeaderContextAndValuesAcrossMalformedLines() throws {
        let header = #"{"type":"session","id":"native-session","version":4}"#
        let message = #"{"type":"assistant/message","seq":2,"time":1797000000000,"data":{"usage":{"inputTokens":10,"outputTokens":2}}}"#
        let nextHeader = #"{"type":"session","id":"next-session","version":4}"#
        let enriched = #"{"type":"assistant/message","seq":2,"time":1797000000000,"data":{"usage":{"inputTokens":12,"outputTokens":5}}}"#
        let data = Data((["\u{FEFF}" + header, message, "{malformed", "", nextHeader, message, enriched]
            .joined(separator: "\r\n") + "\r\n" + "{partial").utf8)
        let events = try MultiClientUsageParsers.parse(data: data, client: .deepseek, sessionHint: "directory")
        XCTAssertEqual(events.count, 2)
        let first = try XCTUnwrap(events.first { $0.sessionID == "native-session" })
        let next = try XCTUnwrap(events.first { $0.sessionID == "next-session" })
        XCTAssertEqual(first.inputTokens, 10)
        XCTAssertEqual(first.outputTokens, 2)
        XCTAssertEqual(next.inputTokens, 12)
        XCTAssertEqual(next.outputTokens, 5)
        XCTAssertNotEqual(first.eventID, next.eventID)
        XCTAssertEqual(try MultiClientUsageParsers.parse(data: data, client: .deepseek, sessionHint: "directory"), events)
    }

    func testClaudeStreamingUpdatesMergeCountsAndKeepReasoningAsOutputSubset() throws {
        let first = claudeLine(
            session: "claude-session",
            entrypoint: "cli",
            id: "message-1",
            timestamp: "2026-10-20T10:00:00.000Z",
            usage: [
                "input_tokens": 2,
                "cache_creation_input_tokens": 1_000,
                "cache_read_input_tokens": 20_000,
                "output_tokens": 150,
                "output_tokens_details": ["thinking_tokens": 60],
            ]
        )
        let update = claudeLine(
            session: "claude-session",
            entrypoint: "cli",
            id: "message-1",
            timestamp: "2026-10-20T10:00:02.000Z",
            usage: [
                "input_tokens": 2,
                "cache_creation_input_tokens": 1_000,
                "cache_read_input_tokens": 20_000,
                "output_tokens": 300,
                "output_tokens_details": ["thinking_tokens": 60],
            ]
        )

        let events = try MultiClientUsageParsers.parse(
            data: jsonl([first, update]), client: .claudeCode, sessionHint: "claude-file"
        )

        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.sessionID, "claude-session")
        XCTAssertEqual(event.model, "claude-opus")
        XCTAssertEqual(event.inputTokens, 21_002)
        XCTAssertEqual(event.outputTokens, 300)
        XCTAssertEqual(event.reasoningTokens, 60)
        XCTAssertEqual(event.cacheReadTokens, 20_000)
        XCTAssertEqual(event.cacheWriteTokens, 1_000)
        XCTAssertEqual(event.quality, "recorded")
    }

    func testClaudeDesktopLocalTranscriptIsClassifiedByItsEntryPoint() throws {
        let desktopLine = claudeLine(
            session: "desktop-session",
            entrypoint: "claude-desktop-3p",
            id: "desktop-message",
            timestamp: "2026-10-20T10:00:00Z",
            usage: ["input_tokens": 11, "output_tokens": 7]
        )
        let data = jsonl([desktopLine])

        XCTAssertTrue(try MultiClientUsageParsers.parse(data: data, client: .claudeCode, sessionHint: "file").isEmpty)
        let desktop = try XCTUnwrap(
            MultiClientUsageParsers.parse(data: data, client: .claudeDesktop, sessionHint: "file").first
        )
        XCTAssertEqual(desktop.client, .claudeDesktop)
        XCTAssertEqual(desktop.inputTokens, 11)
        XCTAssertEqual(desktop.outputTokens, 7)
    }

    func testClaudeClassificationFromEarlierEntryPointAppliesToLaterRecordsWithoutIt() throws {
        let desktopHeader = claudeLine(
            session: "desktop-session",
            entrypoint: "claude-desktop-3p",
            id: "desktop-first",
            timestamp: "2026-10-20T10:00:00Z",
            usage: ["input_tokens": 1, "output_tokens": 1]
        )
        var laterDesktop = claudeLine(
            session: "desktop-session",
            entrypoint: "claude-desktop-3p",
            id: "desktop-later",
            timestamp: "2026-10-20T10:00:01Z",
            usage: ["input_tokens": 7, "output_tokens": 4]
        )
        laterDesktop.removeValue(forKey: "entrypoint")

        let desktopEvents = try MultiClientUsageParsers.parse(
            data: jsonl([desktopHeader, laterDesktop]), client: .claudeDesktop, sessionHint: "desktop-file"
        )
        XCTAssertEqual(desktopEvents.count, 2)
        XCTAssertEqual(desktopEvents.last?.inputTokens, 7)

        let codeEvents = try MultiClientUsageParsers.parse(
            data: jsonl([laterDesktop]), client: .claudeCode, sessionHint: "code-file"
        )
        XCTAssertEqual(codeEvents.count, 1)
    }

    func testSyntheticClaudeAssistantDoesNotCountAsProviderUsage() throws {
        let line = #"{"type":"assistant","timestamp":"2026-10-25T01:00:00Z","sessionId":"s","message":{"id":"local-status","model":"<synthetic>","usage":{"input_tokens":100,"output_tokens":20}}}"# + "\n"
        XCTAssertTrue(try MultiClientUsageParsers.parse(data: Data(line.utf8), client: .claudeCode, sessionHint: "s").isEmpty)
    }

    func testDeepSeekHarnessUnwrapsEventsAndAddsCacheFieldsToTotalInput() throws {
        let first = deepSeekRecord(sequence: 9, output: 5, cacheRead: 4, cacheWrite: 2, timestamp: 1_797_000_000_000)
        let update = deepSeekRecord(sequence: 9, output: 12, cacheRead: 4, cacheWrite: 2, timestamp: 1_797_000_001_000)

        let events = try MultiClientUsageParsers.parse(
            data: jsonl([first, update]), client: .deepseek, sessionHint: "dsh-session"
        )

        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.sessionID, "dsh-session")
        XCTAssertEqual(event.model, "deepseek-v4")
        XCTAssertEqual(event.inputTokens, 106)
        XCTAssertEqual(event.outputTokens, 12)
        XCTAssertEqual(event.cacheReadTokens, 4)
        XCTAssertEqual(event.cacheWriteTokens, 2)
        XCTAssertNil(event.reasoningTokens)
    }

    func testGeminiDocumentUsesInputAndToolCountsAndAddsThoughtsOnce() throws {
        let document: [String: Any] = [
            "sessionId": "gemini-native-session",
            "messages": [
                geminiMessage(id: "gemini-message", timestamp: "2026-10-20T10:00:00Z", input: 10, output: 5, cached: 4, thoughts: 2, tool: 3),
                geminiMessage(id: "gemini-message", timestamp: "2026-10-20T10:00:02Z", input: 10, output: 9, cached: 5, thoughts: 1, tool: 3),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])

        let event = try XCTUnwrap(
            MultiClientUsageParsers.parse(data: data, client: .gemini, sessionHint: "gemini-file").first
        )

        XCTAssertEqual(event.sessionID, "gemini-native-session")
        XCTAssertEqual(event.inputTokens, 13)
        XCTAssertEqual(event.cacheReadTokens, 5)
        XCTAssertEqual(event.outputTokens, 10)
        XCTAssertEqual(event.reasoningTokens, 2)
    }

    func testOpenCodeJSONAddsCacheAndReasoningFieldsAndMergesStreamingRows() throws {
        let first = openCodeMessage(id: "opencode-message", session: "opencode-session", streamed: 1_797_000_000_000, input: 10, output: 20, reasoning: 5, cacheRead: 4, cacheWrite: 2)
        let update = openCodeMessage(id: "opencode-message", session: "opencode-session", streamed: 1_797_000_001_000, input: 10, output: 25, reasoning: 6, cacheRead: 4, cacheWrite: 2)
        let data = try JSONSerialization.data(withJSONObject: [first, update], options: [.sortedKeys])

        let events = try MultiClientUsageParsers.parse(data: data, client: .opencode, sessionHint: "file")
        let event = try XCTUnwrap(events.first)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.sessionID, "opencode-session")
        XCTAssertEqual(event.model, "gpt-test")
        XCTAssertEqual(event.inputTokens, 16)
        XCTAssertEqual(event.outputTokens, 31)
        XCTAssertEqual(event.reasoningTokens, 6)
        XCTAssertEqual(event.cacheReadTokens, 4)
        XCTAssertEqual(event.cacheWriteTokens, 2)
    }

    func testOpenCodeSQLitePagesThroughCompletedRowsAndNormalizesUsage() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try createOpenCodeFixture(at: databaseURL)

        let first = try MultiClientUsageParsers.readOpenCodeDatabase(url: databaseURL, limit: 1)
        let firstCursor = try XCTUnwrap(first.nextCursor)
        let second = try MultiClientUsageParsers.readOpenCodeDatabase(
            url: databaseURL, after: firstCursor, limit: 1
        )
        let event = try XCTUnwrap(first.events.first)

        XCTAssertFalse(first.isComplete)
        XCTAssertTrue(second.isComplete)
        XCTAssertEqual(second.events.count, 0) // The next database row is still in flight.
        XCTAssertEqual(first.events.count, 1)
        XCTAssertEqual(event.client, .opencode)
        XCTAssertEqual(event.sessionID, "session-a")
        XCTAssertEqual(event.inputTokens, 20)
        XCTAssertEqual(event.outputTokens, 13)
        XCTAssertEqual(event.reasoningTokens, 3)
        XCTAssertEqual(
            first.events,
            try MultiClientUsageParsers.readOpenCodeDatabase(url: databaseURL, limit: 1).events
        )
    }

    func testOpenCodeSQLiteOneMiBRowBoundaryAndOversizedCursorPreserveLaterRows() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-row-limit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let database = home.appendingPathComponent("opencode.db")
        let rowBytes = 1_024 * 1_024
        try createOpenCodeSizedFixture(at: database, rows: [
            ("message-0-65k", 65 * 1_024),
            ("message-1-boundary", rowBytes),
            ("message-2-oversized", rowBytes + 1),
            ("message-3-later", 512),
        ])
        let first = try MultiClientUsageParsers.readOpenCodeDatabase(url: database, limit: 1)
        let boundary = try MultiClientUsageParsers.readOpenCodeDatabase(url: database,
            after: XCTUnwrap(first.nextCursor), limit: 1)
        let oversized = try MultiClientUsageParsers.readOpenCodeDatabase(url: database,
            after: XCTUnwrap(boundary.nextCursor), limit: 1)
        let later = try MultiClientUsageParsers.readOpenCodeDatabase(url: database,
            after: XCTUnwrap(oversized.nextCursor), limit: 1)

        XCTAssertEqual(first.events.count, 1)
        XCTAssertEqual(boundary.events.count, 1)
        XCTAssertTrue(oversized.events.isEmpty)
        XCTAssertEqual(oversized.skippedOversizedRows, 1)
        XCTAssertEqual(oversized.skippedMalformedRows, 0)
        XCTAssertEqual(oversized.nextCursor?.messageID, "message-2-oversized")
        XCTAssertEqual(later.events.count, 1)
        XCTAssertFalse(first.isComplete); XCTAssertFalse(boundary.isComplete); XCTAssertFalse(oversized.isComplete)
        XCTAssertTrue(later.isComplete)
        let all = try MultiClientUsageParsers.readOpenCodeDatabase(url: database)
        XCTAssertEqual(Set(all.events.map(\.eventID)), Set((first.events + boundary.events + later.events).map(\.eventID)))
        XCTAssertEqual(all.skippedOversizedRows, 1)
        XCTAssertEqual(all.skippedMalformedRows, 0)
        XCTAssertTrue(all.isComplete)
    }

    func testOpenCodeCheckpointRevisionAppliesOnlyToSQLiteAndIsIdempotent() {
        let raw = "inode:4096:hash"
        let revised = MultiClientUsageParsers.checkpointIdentity(raw, client: .opencode, isDatabase: true)
        XCTAssertEqual(revised, "opencode-sqlite-1m-v1|" + raw)
        XCTAssertEqual(MultiClientUsageParsers.checkpointIdentity(revised, client: .opencode, isDatabase: true), revised)
        XCTAssertEqual(MultiClientUsageParsers.checkpointIdentity(raw, client: .opencode), raw)
        XCTAssertEqual(MultiClientUsageParsers.checkpointIdentity(raw, client: .gemini, isDatabase: true), raw)
        XCTAssertEqual(MultiClientUsageParsers.checkpointIdentity(raw, client: .claudeCode), "claude-entrypoint-v3|claude-cache-lifetimes-v1|" + raw)
        let physical = MultiClientUsageParsers.checkpointIdentity(raw + "|physical-v1:dev:inode:ctime", client: .claudeCode)
        XCTAssertEqual(MultiClientUsageParsers.checkpointBaseIdentity(physical), "claude-entrypoint-v3|claude-cache-lifetimes-v1|" + raw)
        XCTAssertEqual(MultiClientUsageParsers.checkpointBaseIdentity(raw), raw)
    }

    func testOpenCodeSQLiteLegacyCompletedCheckpointReplaysOnceWithoutDuplicatingCachedEvents() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-complete-replay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent("opencode.db")
        try createOpenCodeSizedFixture(at: source, rows: [("cached", 512), ("large", 65 * 1_024)])
        let cached = try MultiClientUsageParsers.readOpenCodeDatabase(url: source, limit: 1).events
        let expected = try MultiClientUsageParsers.readOpenCodeDatabase(url: source).events
        XCTAssertEqual(cached.count, 1); XCTAssertEqual(expected.count, 2)
        let stamp = try openCodeSourceCheckpoint(at: source)
        let ledger = try MultiClientUsageLedger(url: home.appendingPathComponent("usage.sqlite"))
        _ = try ledger.ingest(cached, client: .opencode, sourceKey: stamp.key, checkpoint: stamp.checkpoint)
        try observeOpenCodeCheckpointWrites(in: ledger)
        var preference = try XCTUnwrap(MultiClientUsagePreference.defaults.first { $0.client == .opencode })
        preference.enabled = true; preference.path = source.path
        let scanner = MultiClientUsageScanner(databaseURL: ledger.url, home: home, environment: [:])

        let replayed = try await scanner.scan([preference], includesCharts: false)
        XCTAssertEqual(replayed.summaries.first?.requests, 2)
        let checkpoint = try XCTUnwrap(ledger.checkpoint(client: .opencode, sourceKey: stamp.key))
        XCTAssertEqual(checkpoint.offset, stamp.checkpoint.size)
        XCTAssertEqual(checkpoint.identity, "opencode-sqlite-1m-v1|" + stamp.checkpoint.identity)
        let storedIDs = try ledger.database.readRows("SELECT event_id FROM client_usage_events") { $0.text(0) ?? "" }
        XCTAssertEqual(Set(storedIDs), Set(expected.map(\.eventID)))
        func count(_ table: String) throws -> Int64 {
            try ledger.database.readRows("SELECT COUNT(*) FROM \(table)") { $0.int64(0) ?? 0 }.first ?? 0
        }
        XCTAssertEqual(try count("client_usage_revisions"), 2)
        XCTAssertEqual(try count("test_opencode_checkpoint_writes"), 1)
        let repeated = try await scanner.scan([preference], includesCharts: false)
        XCTAssertEqual(repeated.summaries, replayed.summaries)
        XCTAssertEqual(try count("client_usage_revisions"), 2)
        // Even the checkpoint write is skipped once the revised source identity matches.
        XCTAssertEqual(try count("test_opencode_checkpoint_writes"), 1)
    }

    func testOpenCodeSQLiteLegacyPagedCheckpointRestartsThenResumesAtFiveHundredRows() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-page-replay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent("opencode.db")
        let rows = (0...500).map { (String(format: "message-%04d", $0), $0 == 0 ? 65 * 1_024 : 512) }
        try createOpenCodeSizedFixture(at: source, rows: rows)
        let stamp = try openCodeSourceCheckpoint(at: source)
        let oldCursor = OpenCodeDatabaseCursor(updatedAtMilliseconds: 1_797_000_001_000, messageID: "message-0499")
        let capped = try MultiClientUsageParsers.readOpenCodeDatabase(url: source, limit: .max)
        XCTAssertEqual(capped.events.count, 500)
        XCTAssertEqual(capped.nextCursor, oldCursor)
        XCTAssertFalse(capped.isComplete)
        let oldIdentity = stamp.checkpoint.identity + "|" + (try JSONEncoder().encode(oldCursor)).base64EncodedString()
        let ledger = try MultiClientUsageLedger(url: home.appendingPathComponent("usage.sqlite"))
        _ = try ledger.ingest([], client: .opencode, sourceKey: stamp.key,
            checkpoint: .init(offset: -1, size: stamp.checkpoint.size, modified: stamp.checkpoint.modified, identity: oldIdentity))
        try observeOpenCodeCheckpointWrites(in: ledger)
        var preference = try XCTUnwrap(MultiClientUsagePreference.defaults.first { $0.client == .opencode })
        preference.enabled = true; preference.path = source.path
        let scanner = MultiClientUsageScanner(databaseURL: ledger.url, home: home, environment: [:])

        let first = try await scanner.scan([preference], includesCharts: false)
        XCTAssertEqual(first.summaries.first?.requests, 500)
        let firstCheckpoint = try XCTUnwrap(ledger.checkpoint(client: .opencode, sourceKey: stamp.key))
        let prefix = "opencode-sqlite-1m-v1|" + stamp.checkpoint.identity + "|"
        XCTAssertEqual(firstCheckpoint.offset, -1)
        XCTAssertTrue(firstCheckpoint.identity.hasPrefix(prefix))
        let cursorBytes = try XCTUnwrap(Data(base64Encoded: String(firstCheckpoint.identity.dropFirst(prefix.count))))
        XCTAssertEqual(try JSONDecoder().decode(OpenCodeDatabaseCursor.self, from: cursorBytes), oldCursor)
        let second = try await scanner.scan([preference], includesCharts: false)
        XCTAssertEqual(second.summaries.first?.requests, 501)
        let completed = try XCTUnwrap(ledger.checkpoint(client: .opencode, sourceKey: stamp.key))
        XCTAssertEqual(completed.offset, stamp.checkpoint.size)
        XCTAssertEqual(completed.identity, "opencode-sqlite-1m-v1|" + stamp.checkpoint.identity)
        let repeated = try await scanner.scan([preference], includesCharts: false)
        XCTAssertEqual(repeated.summaries, second.summaries)
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int64(0) ?? 0 }.first, 501)
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM test_opencode_checkpoint_writes") { $0.int64(0) ?? 0 }.first, 2)
    }

    func testOpenCodeJSONRetainsSixteenMiBDocumentLimit() throws {
        let record = openCodeMessage(id: "json-document", session: "session", streamed: 1_797_000_001_000,
            input: 10, output: 20, reasoning: 0, cacheRead: 0, cacheWrite: 0)
        let source = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let expected = try MultiClientUsageParsers.parse(data: source, client: .opencode, sessionHint: "file")
        XCTAssertEqual(expected.count, 1)
        var boundary = source
        boundary.append(Data(repeating: 0x20, count: 16 * 1_024 * 1_024 - source.count))
        XCTAssertEqual(try MultiClientUsageParsers.parse(data: boundary, client: .opencode, sessionHint: "file"), expected)
        boundary.append(0x20)
        XCTAssertThrowsError(try MultiClientUsageParsers.parse(data: boundary, client: .opencode, sessionHint: "file")) {
            XCTAssertEqual($0 as? MultiClientUsageParserError, .inputTooLarge)
        }
    }

    func testOpenCodeLegacyStorageMessageJSONUsesCompletedUsage() throws {
        let record: [String: Any] = [
            "id": "legacy-message",
            "sessionID": "legacy-session",
            "role": "assistant",
            "time": ["created": 1_797_000_000_000, "completed": 1_797_000_001_000],
            "modelID": "legacy-model",
            "tokens": [
                "input": 10,
                "output": 20,
                "reasoning": 5,
                "cache": ["read": 4, "write": 2],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])

        let event = try XCTUnwrap(
            MultiClientUsageParsers.parse(data: data, client: .opencode, sessionHint: "legacy-file").first
        )
        XCTAssertEqual(event.sessionID, "legacy-session")
        XCTAssertEqual(event.model, "legacy-model")
        XCTAssertEqual(event.inputTokens, 16)
        XCTAssertEqual(event.outputTokens, 25)
    }

    func testInvalidCountsAreSkippedButMissingAndNullCountsStayUnknownOrZero() throws {
        let invalid = claudeLine(
            session: "session",
            entrypoint: "cli",
            id: "invalid",
            timestamp: "2026-10-20T10:00:00Z",
            usage: ["input_tokens": "4", "output_tokens": 2]
        )
        let partial = claudeLine(
            session: "session",
            entrypoint: "cli",
            id: "partial",
            timestamp: "2026-10-20T10:00:01Z",
            usage: ["input_tokens": 4, "output_tokens": NSNull(), "cache_read_input_tokens": NSNull()]
        )

        let events = try MultiClientUsageParsers.parse(
            data: jsonl([invalid, partial]), client: .claudeCode, sessionHint: "file"
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].inputTokens, 4)
        XCTAssertEqual(events[0].outputTokens, 0)
        XCTAssertNil(events[0].cacheReadTokens)
    }

    func testPartialJSONLTailIsIgnoredAndMetadataFallbackIsMarked() throws {
        let valid = claudeLine(
            session: "session",
            entrypoint: "cli",
            id: nil,
            timestamp: "2026-10-20T10:00:00Z",
            usage: ["input_tokens": 2, "output_tokens": 3]
        )
        var data = jsonl([valid])
        data.append(Data("{\"type\":\"assistant\",\"message\":{\"usage\":".utf8))

        let events = try MultiClientUsageParsers.parse(data: data, client: .claudeCode, sessionHint: "session-file")
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.quality, "fallback_identity")
        XCTAssertFalse(event.eventID.contains("session-file"))
    }

    func testDiscoveryUsesClientSpecificLocalRootsAndFileShapes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clients-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let claude = home.appendingPathComponent(".claude/projects/project/session.jsonl")
        let claudeDesktop = home.appendingPathComponent(".claude/projects/project/desktop-session.jsonl")
        let dsh = home.appendingPathComponent(".dsh/sessions/session/session.v4.jsonl")
        let invalidDsh = home.appendingPathComponent(".dsh/sessions/session/session.jsonl")
        let gemini = home.appendingPathComponent(".gemini/tmp/project/chats/session.json")
        let geminiSubagent = home.appendingPathComponent(".gemini/tmp/project/chats/agent/session.jsonl")
        let invalidGemini = home.appendingPathComponent(".gemini/tmp/project/logs/session.jsonl")
        let opencode = home.appendingPathComponent(".local/share/opencode/opencode.db")
        let opencodeLegacy = home.appendingPathComponent(
            ".local/share/opencode/storage/message/session-a/message-a.json"
        )
        for file in [
            claude, claudeDesktop, dsh, invalidDsh, gemini, geminiSubagent, invalidGemini, opencode, opencodeLegacy,
        ] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data().write(to: file)
        }
        try jsonl([claudeLine(
            session: "code-session",
            entrypoint: "cli",
            id: "code-message",
            timestamp: "2026-10-20T10:00:00Z",
            usage: ["input_tokens": 3, "output_tokens": 1]
        )]).write(to: claude)
        var desktopEntrypoint = claudeLine(
            session: "desktop-session",
            entrypoint: "claude-desktop-3p",
            id: nil,
            timestamp: "2026-10-20T10:00:00Z",
            usage: [:]
        )
        desktopEntrypoint["type"] = "user"
        var desktopMessage = claudeLine(
            session: "desktop-session",
            entrypoint: "claude-desktop-3p",
            id: "desktop-message",
            timestamp: "2026-10-20T10:00:01Z",
            usage: ["input_tokens": 5, "output_tokens": 2]
        )
        desktopMessage.removeValue(forKey: "entrypoint")
        try jsonl([desktopEntrypoint, desktopMessage]).write(to: claudeDesktop)

        XCTAssertEqual(
            Set(MultiClientUsageDiscovery.files(client: .claudeCode, home: home, environment: [:])),
            Set([claude])
        )
        XCTAssertEqual(
            Set(MultiClientUsageDiscovery.files(client: .claudeDesktop, home: home, environment: [:])),
            Set([claudeDesktop])
        )
        let desktopEvents = try MultiClientUsageParsers.parse(
            data: Data(contentsOf: claudeDesktop), client: .claudeDesktop, sessionHint: "desktop-file"
        )
        XCTAssertEqual(desktopEvents.count, 1)
        XCTAssertEqual(desktopEvents[0].outputTokens, 2)
        XCTAssertEqual(
            MultiClientUsageDiscovery.files(client: .deepseek, home: home, environment: [:]), [dsh]
        )
        XCTAssertEqual(
            Set(MultiClientUsageDiscovery.files(client: .gemini, home: home, environment: [:])),
            Set([gemini, geminiSubagent])
        )
        XCTAssertEqual(
            MultiClientUsageDiscovery.files(client: .opencode, home: home, environment: [:]),
            [opencode, opencodeLegacy]
        )
    }

    private func claudeLine(
        session: String,
        entrypoint: String,
        id: String?,
        timestamp: String,
        usage: [String: Any]
    ) -> [String: Any] {
        var message: [String: Any] = ["model": "claude-opus", "usage": usage]
        if let id { message["id"] = id }
        var object: [String: Any] = [
            "type": "assistant",
            "entrypoint": entrypoint,
            "sessionId": session,
            "timestamp": timestamp,
            "message": message,
        ]
        if let id { object["requestId"] = "request-\(id)" }
        return object
    }

    private func deepSeekRecord(
        sequence: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        timestamp: Int64
    ) -> [String: Any] {
        [
            "type": "event",
            "event": [
                "type": "assistant/message",
                "time": timestamp,
                "seq": sequence,
                "data": [
                    "message": ["id": "deepseek-message", "source": ["model": "deepseek-v4"]],
                    "usage": [
                        "inputTokens": 100,
                        "outputTokens": output,
                        "cacheReadTokens": cacheRead,
                        "cacheWriteTokens": cacheWrite,
                    ],
                ],
            ],
        ]
    }

    private func geminiMessage(
        id: String,
        timestamp: String,
        input: Int,
        output: Int,
        cached: Int,
        thoughts: Int,
        tool: Int
    ) -> [String: Any] {
        [
            "id": id,
            "type": "gemini",
            "timestamp": timestamp,
            "model": "gemini-3-pro",
            "tokens": [
                "input": input,
                "output": output,
                "cached": cached,
                "thoughts": thoughts,
                "tool": tool,
                "total": input + output + tool,
            ],
        ]
    }

    private func openCodeMessage(
        id: String,
        session: String,
        streamed: Int64,
        input: Int,
        output: Int,
        reasoning: Int,
        cacheRead: Int,
        cacheWrite: Int
    ) -> [String: Any] {
        [
            "id": id,
            "session_id": session,
            "type": "assistant",
            "data": [
                "time": ["created": streamed - 1_000, "streamed": streamed],
                "model": ["id": "gpt-test", "providerID": "openai"],
                "tokens": [
                    "input": input,
                    "output": output,
                    "reasoning": reasoning,
                    "cache": ["read": cacheRead, "write": cacheWrite],
                ],
            ],
        ]
    }

    private func jsonl(_ objects: [[String: Any]]) -> Data {
        var result = Data()
        for object in objects {
            result.append(try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            result.append(0x0A)
        }
        return result
    }

    private func createOpenCodeFixture(at url: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let row = #"{"time":{"created":1797000000000,"streamed":1797000001000},"model":{"id":"gpt-test"},"tokens":{"input":10,"output":10,"reasoning":3,"cache":{"read":7,"write":3}}}"#
        let sql = """
            CREATE TABLE session_v2 (id TEXT PRIMARY KEY, time_created INTEGER NOT NULL);
            CREATE TABLE session_message (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL,
                time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
            );
            INSERT INTO session_v2 VALUES ('session-a', 1796999999000);
            INSERT INTO session_message VALUES (
                'message-a', 'session-a', 'assistant', 1, 1797000000000, 1797000001000, '\(row)'
            );
            INSERT INTO session_message VALUES (
                'message-inflight', 'session-a', 'assistant', 2, 1797000001000, 1797000002000,
                '{"time":{"created":1797000001000},"tokens":{"input":999,"output":999}}'
            );
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }

    private func createOpenCodeSizedFixture(at url: URL, rows: [(String, Int)]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = SQLiteDatabaseDriver(url: url)
        let payload = #"{"time":{"created":1797000000000,"streamed":1797000001000},"model":{"id":"gpt-test"},"tokens":{"input":10,"output":20}}"#
        try database.transaction { connection in
            try connection.execute("CREATE TABLE session_v2 (id TEXT PRIMARY KEY, time_created INTEGER NOT NULL)")
            try connection.execute("CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)")
            try connection.execute("INSERT INTO session_v2 VALUES ('session-a', 1796999999000)")
            for (id, byteCount) in rows {
                XCTAssertGreaterThanOrEqual(byteCount, payload.utf8.count)
                let padded = payload + String(repeating: " ", count: max(0, byteCount - payload.utf8.count))
                try connection.execute("INSERT INTO session_message VALUES (?, 'session-a', 'assistant', 1797000000000, 1797000001000, ?)",
                    bindings: [.text(id), .text(padded)])
            }
        }
    }

    private func openCodeSourceCheckpoint(at url: URL) throws -> (key: String, checkpoint: MultiClientFileCheckpoint) {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = try XCTUnwrap(attrs[.size] as? NSNumber).int64Value
        let modified = try XCTUnwrap(attrs[.modificationDate] as? Date).timeIntervalSince1970
        let key = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let identity = String(describing: attrs[.systemFileNumber] ?? "")
        return (key, .init(offset: size, size: size, modified: modified, identity: identity))
    }

    private func observeOpenCodeCheckpointWrites(in ledger: MultiClientUsageLedger) throws {
        try ledger.database.execute("CREATE TABLE test_opencode_checkpoint_writes (identity TEXT NOT NULL)")
        try ledger.database.execute("""
            CREATE TRIGGER test_opencode_checkpoint_update AFTER UPDATE ON client_file_checkpoints
            WHEN NEW.client='opencode' BEGIN
                INSERT INTO test_opencode_checkpoint_writes VALUES (NEW.identity);
            END
            """)
    }
}
