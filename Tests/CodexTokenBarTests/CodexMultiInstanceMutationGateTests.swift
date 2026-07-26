import XCTest
@testable import CodexTokenBar

final class CodexMultiInstanceMutationGateTests: XCTestCase {
    func testEmptyRegistryAllowsMutationEvenWhileDefaultCodexRuns() throws {
        let fixture = try GateFixture(codexRunning: true)
        defer { fixture.cleanup() }

        XCTAssertNoThrow(
            try CodexMultiInstanceMutationGate.ensureNoActiveNonDefaultInstance(
                makeEngine: { fixture.engine }
            )
        )
    }

    func testStoppedImportedInstanceAllowsMutation() throws {
        let fixture = try GateFixture(codexRunning: false)
        defer { fixture.cleanup() }
        try fixture.importInstance(name: "外部实例", home: fixture.instanceHome)

        XCTAssertNoThrow(
            try CodexMultiInstanceMutationGate.ensureNoActiveNonDefaultInstance(
                makeEngine: { fixture.engine }
            )
        )
    }

    func testImportedInstanceWithUnattributedCodexProcessBlocksMutation() throws {
        let fixture = try GateFixture(codexRunning: true)
        defer { fixture.cleanup() }
        try fixture.importInstance(name: "外部实例", home: fixture.instanceHome)

        XCTAssertThrowsError(
            try CodexMultiInstanceMutationGate.ensureNoActiveNonDefaultInstance(
                makeEngine: { fixture.engine }
            )
        ) { error in
            guard case let CodexMultiInstanceMutationGateError.instanceActive(name, _) = error else {
                return XCTFail("应因活动嫌疑实例拒绝，实际错误：\(error)")
            }
            XCTAssertEqual(name, "外部实例")
            XCTAssertTrue(
                error.localizedDescription.contains("删除/移动已暂停"),
                "错误信息应说明删除/移动被暂停：\(error.localizedDescription)"
            )
        }
    }

    func testCorruptRegistryBlocksMutation() throws {
        let fixture = try GateFixture(codexRunning: false)
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.paths.registry.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: fixture.paths.registry)

        XCTAssertThrowsError(
            try CodexMultiInstanceMutationGate.ensureNoActiveNonDefaultInstance(
                makeEngine: { fixture.engine }
            )
        ) { error in
            guard case CodexMultiInstanceMutationGateError.registryUnavailable = error else {
                return XCTFail("应因注册表不可用拒绝，实际错误：\(error)")
            }
        }
    }
}

private final class GateFixture {
    let root: URL
    let paths: CodexInstancePaths
    let instanceHome: URL
    let engine: CodexInstanceEngine

    init(codexRunning: Bool) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-multi-instance-gate-tests-\(UUID().uuidString)", isDirectory: true)
        paths = CodexInstancePaths(
            registry: root.appendingPathComponent("support/codex-instances.json"),
            managedRoot: root.appendingPathComponent("support/instances/codex", isDirectory: true),
            syncRoot: root.appendingPathComponent("support/instance-sync", isDirectory: true)
        )
        let defaultHome = root.appendingPathComponent("default", isDirectory: true)
        instanceHome = root.appendingPathComponent("instance", isDirectory: true)
        for home in [defaultHome, instanceHome] {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        engine = try CodexInstanceEngine(
            paths: paths,
            defaultCodexHome: defaultHome,
            visibilityRebuilder: { _ in },
            globalCodexRunningProbe: { codexRunning }
        )
    }

    func importInstance(name: String, home: URL) throws {
        _ = try engine.importInstance(CodexInstanceImportRequest(
            name: name,
            codexHome: home.path,
            workingDirectory: nil,
            arguments: [],
            autoSyncEnabled: false
        ))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
