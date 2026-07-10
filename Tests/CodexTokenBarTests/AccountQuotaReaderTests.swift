import Foundation
import XCTest
@testable import CodexTokenBar

final class AccountQuotaReaderTests: XCTestCase {
    func testNoisyStderrLargerThanPipeCapacityDoesNotBlockSuccessfulRateLimitResponse() async throws {
        let script = try makeFakeAppServerScript(
            body: """
            head -c 262144 /dev/zero | tr '\\0' 'n' >&2
            printf '\\n' >&2
            IFS= read -r initialize
            printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
            IFS= read -r initialized
            IFS= read -r rate_read
            printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":21},"secondary":{"usedPercent":34}}}}'
            """
        )
        let client = AccountQuotaAppServerClient(
            transport: FoundationAccountQuotaProcessTransport(stderrTailLimit: 4_096),
            timeout: 2
        )

        let result = await client.read(codexPath: script.path, dataSource: nil)

        let snapshot = try result.get()
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 21)
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 34)
    }

    func testCancellationAfterInitializeTerminatesChildAndDoesNotStartSecondAttempt() async throws {
        let transport = ScriptedQuotaProcessTransport(scenarios: [
            .init(stdoutLines: [jsonLine(["jsonrpc": "2.0", "id": 1, "result": [:]])])
        ])
        let dependencies = AccountQuotaReaderDependencies.testing(
            transport: transport,
            timeout: 5,
            maxAttempts: 3
        )
        let task = Task {
            await AccountQuotaReader.read(dataSource: nil, dependencies: dependencies)
        }

        await waitUntil("rate-limit request") {
            transport.rateLimitReadCount == 1
        }
        task.cancel()
        let result = await task.value

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(transport.terminationCount, 1)
    }

    func testTimeoutWithNoisyStderrStaysTimeoutAndRetainsBoundedRawTail() async {
        let noisyPrefix = String(repeating: "plugin-noise-", count: 10_000)
        let suffix = "FINAL STDERR DETAIL"
        let transport = ScriptedQuotaProcessTransport(scenarios: [
            .init(stdoutLines: [], stderr: Data((noisyPrefix + suffix).utf8))
        ], stderrTailLimit: 1_024)
        let client = AccountQuotaAppServerClient(transport: transport, timeout: 0.03)

        let result = await client.read(codexPath: "/fake/codex", dataSource: nil)

        XCTAssertThrowsError(try result.get()) { error in
            guard case .timeoutWithOutput(let detail) = error as? AccountQuotaReaderError else {
                return XCTFail("Expected timeoutWithOutput, got \(error)")
            }
            XCTAssertLessThanOrEqual(detail.utf8.count, 1_024)
            XCTAssertTrue(detail.hasSuffix(suffix))
            XCTAssertFalse(detail.contains(noisyPrefix))
        }
    }

    func testRateLimitJSONRPCErrorRemainsServerErrorEvenWithStderrNoise() async {
        let transport = ScriptedQuotaProcessTransport(scenarios: [
            .init(
                stdoutLines: [
                    jsonLine(["jsonrpc": "2.0", "id": 1, "result": [:]]),
                    jsonLine([
                        "jsonrpc": "2.0",
                        "id": 2,
                        "error": ["code": -32_000, "message": "app-server rejected quota read"]
                    ])
                ],
                stderr: Data(String(repeating: "model warning\n", count: 2_000).utf8)
            )
        ])
        let client = AccountQuotaAppServerClient(transport: transport, timeout: 0.2)

        let result = await client.read(codexPath: "/fake/codex", dataSource: nil)

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(
                error as? AccountQuotaReaderError,
                .serverError("app-server rejected quota read")
            )
        }
    }

    func testUnrelatedStdoutLogsAndJSONMessagesAreIgnoredUntilMatchingResponsesArrive() async throws {
        let transport = ScriptedQuotaProcessTransport(scenarios: [
            .init(stdoutLines: [
                Data("plain plugin log\n".utf8),
                jsonLine(["jsonrpc": "2.0", "method": "thread/started", "params": [:]]),
                jsonLine(["jsonrpc": "2.0", "id": 99, "result": ["ignored": true]]),
                jsonLine(["jsonrpc": "2.0", "id": 1, "result": [:]]),
                Data("another non-json log\n".utf8),
                jsonLine(["jsonrpc": "2.0", "id": 77, "error": ["message": "irrelevant"]]),
                jsonLine(["jsonrpc": "2.0", "id": 2, "result": fallbackRateLimits(usedPercent: 37)])
            ])
        ])
        let client = AccountQuotaAppServerClient(transport: transport, timeout: 0.2)

        let snapshot = try await client.read(codexPath: "/fake/codex", dataSource: nil).get()

        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 37)
        XCTAssertEqual(transport.rateLimitReadCount, 1)
    }

    func testRateLimitsByLimitIDResponseShapeRemainsSupported() async throws {
        let transport = ScriptedQuotaProcessTransport(scenarios: [
            successfulScenario(result: [
                "rateLimitsByLimitId": [
                    "codex": [
                        "limitId": "codex",
                        "limitName": "Codex",
                        "planType": "pro",
                        "primary": ["usedPercent": 41],
                        "secondary": ["usedPercent": 52]
                    ],
                    "review": [
                        "limitId": "review",
                        "limitName": "Code Review",
                        "primary": ["usedPercent": 63]
                    ]
                ]
            ])
        ])
        let client = AccountQuotaAppServerClient(transport: transport, timeout: 0.2)

        let snapshot = try await client.read(codexPath: "/fake/codex", dataSource: nil).get()

        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 41)
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 52)
        XCTAssertEqual(snapshot.limitCards.map(\.id), ["codex", "review"])
    }

    func testFallbackRateLimitsResponseShapeRemainsSupported() async throws {
        let transport = ScriptedQuotaProcessTransport(scenarios: [
            successfulScenario(result: fallbackRateLimits(usedPercent: 48))
        ])
        let client = AccountQuotaAppServerClient(transport: transport, timeout: 0.2)

        let snapshot = try await client.read(codexPath: "/fake/codex", dataSource: nil).get()

        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 48)
        XCTAssertEqual(snapshot.limitCards.map(\.id), ["codex"])
    }
}

private final class ScriptedQuotaProcessTransport: AccountQuotaProcessTransport, @unchecked Sendable {
    struct Scenario {
        var stdoutLines: [Data]
        var stderr: Data = Data()
    }

    private let lock = NSLock()
    private var scenarios: [Scenario]
    private var sessions: [ScriptedQuotaProcessSession] = []
    private let stderrTailLimit: Int

    init(scenarios: [Scenario], stderrTailLimit: Int = 16_384) {
        self.scenarios = scenarios
        self.stderrTailLimit = stderrTailLimit
    }

    var startCount: Int {
        lock.withLock { sessions.count }
    }

    var terminationCount: Int {
        lock.withLock { sessions.filter(\.isTerminated).count }
    }

    var rateLimitReadCount: Int {
        lock.withLock { sessions.reduce(0) { $0 + $1.rateLimitReadCount } }
    }

    func start(codexPath: String, dataSource: CodexDataSource?) throws -> any AccountQuotaProcessSession {
        try lock.withLock {
            guard !scenarios.isEmpty else {
                throw QuotaReaderTestError.noScenario
            }
            let session = ScriptedQuotaProcessSession(
                scenario: scenarios.removeFirst(),
                stderrTailLimit: stderrTailLimit
            )
            sessions.append(session)
            return session
        }
    }
}

private final class ScriptedQuotaProcessSession: AccountQuotaProcessSession, @unchecked Sendable {
    private let condition = NSCondition()
    private var stdoutLines: [Data]
    private var writes: [Data] = []
    private var terminated = false
    private let stderr: AccountQuotaStderrTail

    init(scenario: ScriptedQuotaProcessTransport.Scenario, stderrTailLimit: Int) {
        stdoutLines = scenario.stdoutLines
        stderr = AccountQuotaStderrTail(maxBytes: stderrTailLimit)
        stderr.append(scenario.stderr)
    }

    var isTerminated: Bool {
        condition.withLock { terminated }
    }

    var rateLimitReadCount: Int {
        condition.withLock {
            writes.filter { data in
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return false
                }
                return object["id"] as? Int == 2
            }.count
        }
    }

    func writeStdin(_ data: Data) throws {
        condition.withLock {
            writes.append(data)
            condition.broadcast()
        }
    }

    func nextStdoutLine(timeout: TimeInterval) throws -> Data? {
        condition.lock()
        defer { condition.unlock() }
        if !stdoutLines.isEmpty {
            return stdoutLines.removeFirst()
        }
        guard !terminated else { return nil }
        _ = condition.wait(until: Date().addingTimeInterval(timeout))
        return stdoutLines.isEmpty ? nil : stdoutLines.removeFirst()
    }

    func stderrTailText() -> String? {
        stderr.text
    }

    func terminate() {
        condition.withLock {
            terminated = true
            condition.broadcast()
        }
    }
}

private enum QuotaReaderTestError: Error {
    case noScenario
}

private func successfulScenario(result: [String: Any]) -> ScriptedQuotaProcessTransport.Scenario {
    .init(stdoutLines: [
        jsonLine(["jsonrpc": "2.0", "id": 1, "result": [:]]),
        jsonLine(["jsonrpc": "2.0", "id": 2, "result": result])
    ])
}

private func fallbackRateLimits(usedPercent: Int) -> [String: Any] {
    [
        "rateLimits": [
            "limitId": "codex",
            "limitName": "Codex",
            "planType": "pro",
            "primary": ["usedPercent": usedPercent],
            "secondary": ["usedPercent": usedPercent + 10]
        ]
    ]
}

private func jsonLine(_ object: [String: Any]) -> Data {
    var data = try! JSONSerialization.data(withJSONObject: object)
    data.append(0x0A)
    return data
}

private func makeFakeAppServerScript(body: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuotaReaderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("fake-codex")
    try ("#!/bin/sh\nset -eu\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 1,
    condition: @escaping () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Timed out waiting for \(description)")
}
