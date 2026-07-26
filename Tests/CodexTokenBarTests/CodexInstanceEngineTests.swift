import Foundation
import XCTest
@testable import CodexTokenBar

final class CodexInstanceEngineTests: XCTestCase {
    func testPrefixSyncCommitsAndRollbackRestoresOriginalBytes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.importInstance(name: "一", home: fixture.firstHome)
        let second = try fixture.importInstance(name: "二", home: fixture.secondHome)
        let firstURL = try fixture.writeRollout(
            home: fixture.firstHome,
            threadID: "thread-prefix",
            events: ["{\"type\":\"event_msg\",\"payload\":{\"n\":1}}"]
        )
        let original = try Data(contentsOf: firstURL)
        let secondURL = try fixture.writeRollout(
            home: fixture.secondHome,
            threadID: "thread-prefix",
            events: [
                "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}",
                "{\"type\":\"event_msg\",\"payload\":{\"n\":2}}"
            ]
        )

        let preview = try fixture.engine.previewSync(instanceIDs: [first.id, second.id])
        XCTAssertEqual(preview.operations.count, 1)
        XCTAssertEqual(preview.operations.first?.kind, "fastForward")
        XCTAssertTrue(preview.conflicts.isEmpty)

        let result = try fixture.engine.syncInstances(instanceIDs: [first.id, second.id])
        XCTAssertEqual(result.operationsApplied, 1)
        XCTAssertEqual(try Data(contentsOf: firstURL), try Data(contentsOf: secondURL))
        let transactionID = try XCTUnwrap(result.transactionId)
        XCTAssertEqual(try fixture.engine.listSyncTransactions().first?.state, "committed")

        _ = try fixture.engine.rollbackSync(transactionID: transactionID)
        XCTAssertEqual(try Data(contentsOf: firstURL), original)
        XCTAssertEqual(try fixture.engine.listSyncTransactions().first?.state, "rolledBack")
    }

    private static func spawnFileHolder(path: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec 3>>\"$0\"; echo ready; exec sleep 300", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let ready = pipe.fileHandleForReading.readData(ofLength: 6)
        guard String(data: ready, encoding: .utf8) == "ready\n" else {
            process.terminate()
            throw NSError(
                domain: "CodexInstanceEngineTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "文件持有进程未就绪"]
            )
        }
        return process
    }

    func testProcessesHoldingFileOpenDetectsOtherProcessAndIgnoresSelf() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-open-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("held.jsonl")
        try "line\n".write(to: file, atomically: true, encoding: .utf8)

        let holder = try Self.spawnFileHolder(path: file.path)
        defer { holder.terminate() }
        let pids = try CodexInstanceEngine.processesHoldingFileOpen(atPath: file.path)
        XCTAssertTrue(pids.contains(holder.processIdentifier), "\(pids)")
        holder.terminate()
        holder.waitUntilExit()

        let ownHandle = try FileHandle(forReadingFrom: file)
        defer { try? ownHandle.close() }
        let after = try CodexInstanceEngine.processesHoldingFileOpen(atPath: file.path)
        XCTAssertTrue(after.isEmpty, "自身句柄或已退出进程被误报：\(after)")

        let missing = root.appendingPathComponent("missing.jsonl")
        XCTAssertEqual(try CodexInstanceEngine.processesHoldingFileOpen(atPath: missing.path), [])
    }

    func testSyncRefusesWhileCandidateFileIsOpenInAnotherProcess() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.importInstance(name: "一", home: fixture.firstHome)
        let second = try fixture.importInstance(name: "二", home: fixture.secondHome)
        _ = try fixture.writeRollout(
            home: fixture.firstHome,
            threadID: "held",
            events: ["{\"type\":\"event_msg\",\"payload\":{\"n\":1}}"]
        )
        let source = try fixture.writeRollout(
            home: fixture.secondHome,
            threadID: "held",
            events: [
                "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}",
                "{\"type\":\"event_msg\",\"payload\":{\"n\":2}}"
            ]
        )

        let holder = try Self.spawnFileHolder(path: source.path)
        defer { holder.terminate() }
        XCTAssertThrowsError(
            try fixture.engine.syncInstances(instanceIDs: [first.id, second.id])
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("候选会话文件"), message)
            XCTAssertTrue(message.contains("\(holder.processIdentifier)"), message)
        }
        holder.terminate()
        holder.waitUntilExit()

        let result = try fixture.engine.syncInstances(instanceIDs: [first.id, second.id])
        XCTAssertEqual(result.operationsApplied, 1)
    }

    func testInstanceFileLockHoldsUntilExplicitReleaseAndReleaseIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-instance-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("locks/engine.lock")

        let first = try CodexInstanceFileLock(url: url, label: "测试")
        XCTAssertThrowsError(try CodexInstanceFileLock(url: url, label: "测试"))

        first.release()
        let second = try CodexInstanceFileLock(url: url, label: "测试")

        // 重复 release 必须是空操作：不得误关系统已复用的文件描述符。
        first.release()
        XCTAssertThrowsError(try CodexInstanceFileLock(url: url, label: "测试"))

        second.release()
        let third = try CodexInstanceFileLock(url: url, label: "测试")
        third.release()
    }

    func testRollbackRetryAfterPartialRollbackIsIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.importInstance(name: "一", home: fixture.firstHome)
        let second = try fixture.importInstance(name: "二", home: fixture.secondHome)
        let firstURL = try fixture.writeRollout(
            home: fixture.firstHome,
            threadID: "thread-existing",
            events: ["{\"type\":\"event_msg\",\"payload\":{\"n\":1}}"]
        )
        let original = try Data(contentsOf: firstURL)
        _ = try fixture.writeRollout(
            home: fixture.secondHome,
            threadID: "thread-existing",
            events: [
                "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}",
                "{\"type\":\"event_msg\",\"payload\":{\"n\":2}}"
            ]
        )
        _ = try fixture.writeRollout(
            home: fixture.secondHome,
            threadID: "thread-new",
            events: ["{\"type\":\"event_msg\",\"payload\":{\"n\":3}}"]
        )

        let result = try fixture.engine.syncInstances(instanceIDs: [first.id, second.id])
        XCTAssertEqual(result.operationsApplied, 2)
        let transactionID = try XCTUnwrap(result.transactionId)

        // 模拟"回滚已把文件恢复但进度/状态未持久化"后的重试现场：
        // 既有文件已回到同步前内容，新增文件已被删除，manifest 仍记录 installedHash。
        try original.write(to: firstURL)
        let newFile = try XCTUnwrap(
            FileManager.default
                .enumerator(at: fixture.firstHome, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .first { $0.lastPathComponent.contains("thread-new") }
        )
        try FileManager.default.removeItem(at: newFile)

        // 旧实现在此报"已在同步后被修改，拒绝覆盖 / 已被删除，拒绝猜测性恢复"，
        // 事务永久卡死；幂等回滚应把两条操作都判定为已回滚并正常收尾。
        _ = try fixture.engine.rollbackSync(transactionID: transactionID)
        XCTAssertEqual(try Data(contentsOf: firstURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newFile.path))
        XCTAssertEqual(try fixture.engine.listSyncTransactions().first?.state, "rolledBack")
    }

    func testDivergentRolloutsStaySeparateAndAreRecordedAsConflict() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.importInstance(name: "一", home: fixture.firstHome)
        let second = try fixture.importInstance(name: "二", home: fixture.secondHome)
        let firstURL = try fixture.writeRollout(
            home: fixture.firstHome,
            threadID: "thread-fork",
            events: ["{\"type\":\"event_msg\",\"payload\":{\"side\":\"a\"}}"]
        )
        let secondURL = try fixture.writeRollout(
            home: fixture.secondHome,
            threadID: "thread-fork",
            events: ["{\"type\":\"event_msg\",\"payload\":{\"side\":\"b\"}}"]
        )
        let beforeFirst = try Data(contentsOf: firstURL)
        let beforeSecond = try Data(contentsOf: secondURL)

        let preview = try fixture.engine.previewSync(instanceIDs: [first.id, second.id])
        XCTAssertTrue(preview.operations.isEmpty)
        XCTAssertEqual(preview.conflicts.count, 1)

        let result = try fixture.engine.syncInstances(instanceIDs: [first.id, second.id])
        XCTAssertEqual(result.operationsApplied, 0)
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertEqual(try Data(contentsOf: firstURL), beforeFirst)
        XCTAssertEqual(try Data(contentsOf: secondURL), beforeSecond)
        XCTAssertEqual(try fixture.engine.listInstances().conflicts.count, 1)
        _ = try fixture.engine.syncInstances(instanceIDs: [first.id, second.id])
        XCTAssertEqual(
            try fixture.engine.listInstances().conflicts.count,
            1,
            "repeated observation of the same divergence must update, not accumulate"
        )
    }

    func testActiveAndArchivedVersionsStaySeparate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.importInstance(name: "一", home: fixture.firstHome)
        let second = try fixture.importInstance(name: "二", home: fixture.secondHome)
        _ = try fixture.writeRollout(
            home: fixture.firstHome,
            threadID: "thread-archive-state",
            events: ["{\"type\":\"event_msg\",\"payload\":{\"n\":1}}"]
        )
        _ = try fixture.writeRollout(
            home: fixture.secondHome,
            threadID: "thread-archive-state",
            events: ["{\"type\":\"event_msg\",\"payload\":{\"n\":1}}"],
            directoryName: "archived_sessions"
        )

        let preview = try fixture.engine.previewSync(instanceIDs: [first.id, second.id])
        XCTAssertTrue(preview.operations.isEmpty)
        XCTAssertEqual(preview.conflicts.count, 1)
        XCTAssertTrue(preview.conflicts[0].reason.contains("活动/归档"))
    }

    func testRegistryUsesSharedCamelCaseSchemaAndDoesNotPersistDefaultInstance() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.importInstance(name: "外部", home: fixture.firstHome)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.paths.registry))
                as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let instances = try XCTUnwrap(object["instances"] as? [[String: Any]])
        XCTAssertEqual(instances.count, 1)
        XCTAssertNil(instances.first(where: { $0["id"] as? String == "default" }))
        XCTAssertNotNil(instances[0]["electronDataDirectory"])
        XCTAssertNotNil(instances[0]["autoSyncEnabled"])
        XCTAssertEqual(try fixture.engine.listInstances().instances.first?.id, "default")
    }

    func testAutomaticSyncAlwaysIncludesDefaultInstance() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var instance = try fixture.importInstance(name: "自动", home: fixture.firstHome)
        instance.autoSyncEnabled = true
        XCTAssertEqual(codexAutomaticSyncInstanceIDs([instance]), ["default", instance.id])
    }

    func testProcessMarkerMatchingRequiresArgumentBoundaries() {
        let marker = "--user-data-dir=/tmp/Codex Home"
        XCTAssertTrue(codexProcessCommandContainsArgument(
            "/Applications/Codex.app/Contents/MacOS/Codex \(marker) --flag",
            marker
        ))
        XCTAssertTrue(codexProcessCommandContainsArgument(
            "/Applications/Codex.app/Contents/MacOS/Codex \"\(marker)\"",
            marker
        ))
        XCTAssertFalse(codexProcessCommandContainsArgument(
            "/Applications/Codex.app/Contents/MacOS/Codex \(marker)-copy",
            marker
        ))
        XCTAssertFalse(codexProcessCommandContainsArgument(
            "/Applications/Codex.app/Contents/MacOS/Codex --other=\(marker)",
            marker
        ))
    }

    func testUnregisteringExternalHomeRemovesOnlyTokenBarOwnedElectronData() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let instance = try fixture.importInstance(name: "外部", home: fixture.firstHome)
        let electron = URL(fileURLWithPath: instance.electronDataDirectory, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: electron.path))

        _ = try fixture.engine.deleteInstance(id: instance.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.firstHome.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: electron.path))
    }

    func testNestedCodexHomesAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.importInstance(name: "父目录", home: fixture.firstHome)
        let nested = fixture.firstHome.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertThrowsError(try fixture.importInstance(name: "子目录", home: nested)) { error in
            XCTAssertTrue(error.localizedDescription.contains("相互嵌套"))
        }
    }

    func testRolloutRootSymlinkCannotEscapeCodexHome() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.importInstance(name: "一", home: fixture.firstHome)
        let second = try fixture.importInstance(name: "二", home: fixture.secondHome)
        let outsideHome = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideHome, withIntermediateDirectories: true)
        _ = try fixture.writeRollout(
            home: outsideHome,
            threadID: "thread-outside",
            events: ["{\"type\":\"event_msg\",\"payload\":{\"n\":1}}"]
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.firstHome.appendingPathComponent("sessions"),
            withDestinationURL: outsideHome.appendingPathComponent("sessions")
        )

        XCTAssertThrowsError(
            try fixture.engine.previewSync(instanceIDs: [first.id, second.id])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("真实目录"))
        }
    }

    func testPreparedTransactionBlocksRelatedSyncAndCanBeRecovered() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.importInstance(name: "一", home: fixture.firstHome)
        let second = try fixture.importInstance(name: "二", home: fixture.secondHome)
        let firstURL = try fixture.writeRollout(
            home: fixture.firstHome,
            threadID: "thread-prepared",
            events: ["{\"type\":\"event_msg\",\"payload\":{\"n\":1}}"]
        )
        let original = try Data(contentsOf: firstURL)
        _ = try fixture.writeRollout(
            home: fixture.secondHome,
            threadID: "thread-prepared",
            events: [
                "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}",
                "{\"type\":\"event_msg\",\"payload\":{\"n\":2}}"
            ]
        )

        let result = try fixture.engine.syncInstances(instanceIDs: [first.id, second.id])
        let transactionID = try XCTUnwrap(result.transactionId)
        try fixture.setTransactionState(
            transactionID,
            state: "prepared",
            clearInstalledHashes: true
        )

        XCTAssertThrowsError(
            try fixture.engine.previewSync(instanceIDs: [first.id, second.id])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("尚未完成"))
        }

        _ = try fixture.engine.rollbackSync(transactionID: transactionID)
        XCTAssertEqual(try Data(contentsOf: firstURL), original)
    }

    func testOverlappingTransactionsMustRollbackNewestFirst() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.importInstance(name: "一", home: fixture.firstHome)
        let second = try fixture.importInstance(name: "二", home: fixture.secondHome)
        _ = try fixture.writeRollout(
            home: fixture.secondHome,
            threadID: "thread-older",
            events: ["{\"type\":\"event_msg\",\"payload\":{\"n\":1}}"]
        )
        let olderPreview = try fixture.engine.previewSync(instanceIDs: [first.id, second.id])
        XCTAssertEqual(olderPreview.operations.count, 1)
        let olderOperation = try XCTUnwrap(olderPreview.operations.first)
        XCTAssertNotEqual(olderOperation.sourcePath, olderOperation.destinationPath)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: olderOperation.destinationPath),
            "\(olderOperation.sourcePath) -> \(olderOperation.destinationPath)"
        )
        let older = try XCTUnwrap(
            fixture.engine.syncInstances(instanceIDs: [first.id, second.id]).transactionId
        )
        _ = try fixture.writeRollout(
            home: fixture.secondHome,
            threadID: "thread-newer",
            events: ["{\"type\":\"event_msg\",\"payload\":{\"n\":2}}"]
        )
        let newer = try XCTUnwrap(
            fixture.engine.syncInstances(instanceIDs: [first.id, second.id]).transactionId
        )

        XCTAssertThrowsError(try fixture.engine.rollbackSync(transactionID: older)) { error in
            XCTAssertTrue(error.localizedDescription.contains(newer))
        }
        _ = try fixture.engine.rollbackSync(transactionID: newer)
        _ = try fixture.engine.rollbackSync(transactionID: older)
    }
}

private final class Fixture {
    let root: URL
    let paths: CodexInstancePaths
    let defaultHome: URL
    let firstHome: URL
    let secondHome: URL
    let engine: CodexInstanceEngine

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-instance-tests-\(UUID().uuidString)", isDirectory: true)
        paths = CodexInstancePaths(
            registry: root.appendingPathComponent("support/codex-instances.json"),
            managedRoot: root.appendingPathComponent("support/instances/codex", isDirectory: true),
            syncRoot: root.appendingPathComponent("support/instance-sync", isDirectory: true)
        )
        defaultHome = root.appendingPathComponent("default", isDirectory: true)
        firstHome = root.appendingPathComponent("first", isDirectory: true)
        secondHome = root.appendingPathComponent("second", isDirectory: true)
        for home in [defaultHome, firstHome, secondHome] {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        engine = try CodexInstanceEngine(
            paths: paths,
            defaultCodexHome: defaultHome,
            visibilityRebuilder: { _ in },
            globalCodexRunningProbe: { false }
        )
    }

    func importInstance(name: String, home: URL) throws -> CodexInstance {
        let result = try engine.importInstance(CodexInstanceImportRequest(
            name: name,
            codexHome: home.path,
            workingDirectory: nil,
            arguments: [],
            autoSyncEnabled: false
        ))
        guard let instance = result.instance else {
            throw NSError(
                domain: "CodexInstanceEngineTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "导入实例没有返回实例对象"]
            )
        }
        return instance
    }

    func writeRollout(
        home: URL,
        threadID: String,
        events: [String],
        directoryName: String = "sessions"
    ) throws -> URL {
        let directory = home.appendingPathComponent(
            "\(directoryName)/2026/07/26",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rollout-\(threadID).jsonl")
        let lines = [
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(threadID)\"}}"
        ] + events
        try (lines.joined(separator: "\n") + "\n").write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        return url
    }

    func setTransactionState(
        _ transactionID: String,
        state: String,
        clearInstalledHashes: Bool = false
    ) throws {
        let manifest = paths.syncRoot
            .appendingPathComponent("transactions/\(transactionID)/manifest.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
                as? [String: Any]
        )
        object["state"] = state
        if clearInstalledHashes, var operations = object["operations"] as? [[String: Any]] {
            for index in operations.indices {
                operations[index]["installedHash"] = NSNull()
            }
            object["operations"] = operations
        }
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifest, options: .atomic)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
