import Foundation
import Darwin
import XCTest
@testable import CodexTokenBar

final class AccountQuotaReaderTests: XCTestCase {
    func testNoisyStderrLargerThanPipeCapacityDoesNotBlockSuccessfulRateLimitResponse() async throws {
        let fixture = try makeFakeAppServerScript(
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
        defer { fixture.cleanup() }
        let client = makeTestAppServerClient(
            transport: FoundationAccountQuotaProcessTransport(stderrTailLimit: 4_096),
            timeout: 2
        )

        let result = await client.read(codexPath: fixture.executable.path, dataSource: nil)

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
        let client = makeTestAppServerClient(transport: transport, timeout: 0.03)

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
        let client = makeTestAppServerClient(transport: transport, timeout: 0.2)

        let result = await client.read(codexPath: "/fake/codex", dataSource: nil)

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(
                error as? AccountQuotaReaderError,
                .serverError("app-server rejected quota read")
            )
        }
    }

    func testInitializeJSONRPCErrorIsReportedAsServerError() async {
        let transport = ScriptedQuotaProcessTransport(scenarios: [
            .init(stdoutLines: [
                jsonLine([
                    "jsonrpc": "2.0",
                    "id": 1,
                    "error": ["code": -32_000, "message": "initialize rejected"]
                ])
            ])
        ])
        let client = makeTestAppServerClient(transport: transport, timeout: 0.03)

        let result = await client.read(codexPath: "/fake/codex", dataSource: nil)

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? AccountQuotaReaderError, .serverError("initialize rejected"))
        }
    }

    func testMalformedInitializeJSONRPCErrorIsInvalidResponseWithoutTimeout() async {
        let transport = ScriptedQuotaProcessTransport(scenarios: [
            .init(stdoutLines: [
                jsonLine([
                    "jsonrpc": "2.0",
                    "id": 1,
                    "error": ["code": -32_000]
                ])
            ])
        ])
        let client = makeTestAppServerClient(transport: transport, timeout: 0.03)

        let result = await client.read(codexPath: "/fake/codex", dataSource: nil)

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? AccountQuotaReaderError, .invalidResponse)
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
        let client = makeTestAppServerClient(transport: transport, timeout: 0.2)

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
        let client = makeTestAppServerClient(transport: transport, timeout: 0.2)

        let snapshot = try await client.read(codexPath: "/fake/codex", dataSource: nil).get()

        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 41)
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 52)
        XCTAssertEqual(snapshot.limitCards.map(\.id), ["codex", "review"])
    }

    func testFallbackRateLimitsResponseShapeRemainsSupported() async throws {
        let transport = ScriptedQuotaProcessTransport(scenarios: [
            successfulScenario(result: fallbackRateLimits(usedPercent: 48))
        ])
        let client = makeTestAppServerClient(transport: transport, timeout: 0.2)

        let snapshot = try await client.read(codexPath: "/fake/codex", dataSource: nil).get()

        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 48)
        XCTAssertEqual(snapshot.limitCards.map(\.id), ["codex"])
    }

    func testSuccessfulReadUsesInjectedAccountLookupWithoutResolvingDefaultHome() async throws {
        let transport = ScriptedQuotaProcessTransport(scenarios: [
            successfulScenario(result: fallbackRateLimits(usedPercent: 18))
        ])
        let lookup = LocalAccountLookupProbe(accountName: "isolated-auth-sentinel")
        let client = AccountQuotaAppServerClient(
            transport: transport,
            timeout: 0.2,
            localAccountNameLookup: lookup.readAccountName
        )

        let snapshot = try await client.read(codexPath: "/fake/codex", dataSource: nil).get()

        XCTAssertEqual(snapshot.accountName, "isolated-auth-sentinel")
        XCTAssertEqual(lookup.lookupCount, 1)
        XCTAssertEqual(lookup.nilSourceLookupCount, 1)
    }

    func testNonPositiveMaxAttemptsClampToOneAttempt() async throws {
        for maxAttempts in [0, -2] {
            let transport = ScriptedQuotaProcessTransport(scenarios: [
                successfulScenario(result: fallbackRateLimits(usedPercent: 29))
            ])
            let dependencies = AccountQuotaReaderDependencies.testing(
                transport: transport,
                timeout: 0.2,
                maxAttempts: maxAttempts
            )

            let snapshot = try await AccountQuotaReader.read(
                dataSource: nil,
                dependencies: dependencies
            ).get()

            XCTAssertEqual(snapshot.fiveHour?.usedPercent, 29)
            XCTAssertEqual(transport.startCount, 1)
        }
    }

    func testArbitraryShutdownFailureSuppressesRetry() async throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let transport = ScriptedQuotaProcessTransport(scenarios: [
            .init(
                stdoutLines: successfulScenario(
                    result: fallbackRateLimits(usedPercent: 31)
                ).stdoutLines,
                shutdownError: .shutdownFailed
            ),
            successfulScenario(result: fallbackRateLimits(usedPercent: 47))
        ])
        let dependencies = AccountQuotaReaderDependencies.testing(
            transport: transport,
            timeout: 0.2,
            maxAttempts: 2
        )

        let result = await AccountQuotaReader.read(
            dataSource: CodexDataSource(codexHome: codexHome, origin: .userSelected),
            dependencies: dependencies
        )

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is AccountQuotaProcessOwnershipFailure)
        }
        XCTAssertEqual(transport.startCount, 1)
    }

    func testCancellationRemainsPublicOutcomeWhenShutdownFails() async {
        let transport = ScriptedQuotaProcessTransport(scenarios: [
            .init(
                stdoutLines: [jsonLine(["jsonrpc": "2.0", "id": 1, "result": [:]])],
                shutdownError: .shutdownFailed
            )
        ])
        let client = makeTestAppServerClient(transport: transport, timeout: 2)
        let task = Task {
            await client.read(codexPath: "/fake/codex", dataSource: nil)
        }

        await waitUntil("rate-limit request before cancellation") {
            transport.rateLimitReadCount == 1
        }
        task.cancel()
        let result = await task.value

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(
            AccountQuotaProcessCleanupDiagnostics.recentEntries.last?.cancellationWasRequested,
            true
        )
        XCTAssertTrue(
            AccountQuotaProcessCleanupDiagnostics.recentEntries.last?.message
                .contains("Synthetic shutdown failure") == true
        )
    }

    func testFakeAppServerFixtureCleanupRemovesTemporaryDirectory() throws {
        let fixture = try makeFakeAppServerScript(body: "exit 0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.path))

        fixture.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    func testChildExitBeforeInitializeIsReportedWithoutWaitingForTimeout() async throws {
        let fixture = try makeFakeAppServerScript(body: "exit 7")
        defer { fixture.cleanup() }
        let client = makeTestAppServerClient(
            transport: FoundationAccountQuotaProcessTransport(),
            timeout: 1
        )
        let startedAt = Date()

        let result = await client.read(codexPath: fixture.executable.path, dataSource: nil)

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        XCTAssertThrowsError(try result.get()) { error in
            guard case .serverError(let message) = error as? AccountQuotaReaderError else {
                return XCTFail("Expected serverError, got \(error)")
            }
            XCTAssertTrue(message.contains("initialize"))
            XCTAssertTrue(message.contains("7"))
        }
    }

    func testChildExitAfterInitializeIsReportedWithoutWaitingForTimeout() async throws {
        let fixture = try makeFakeAppServerScript(
            body: """
            IFS= read -r initialize
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
            IFS= read -r initialized
            IFS= read -r rate_read
            exit 9
            """
        )
        defer { fixture.cleanup() }
        let client = makeTestAppServerClient(
            transport: FoundationAccountQuotaProcessTransport(),
            timeout: 1
        )
        let startedAt = Date()

        let result = await client.read(codexPath: fixture.executable.path, dataSource: nil)

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        XCTAssertThrowsError(try result.get()) { error in
            guard case .serverError(let message) = error as? AccountQuotaReaderError else {
                return XCTFail("Expected serverError, got \(error)")
            }
            XCTAssertTrue(message.contains("rate limits"))
            XCTAssertTrue(message.contains("9"))
        }
    }

    func testPartialFinalJSONLineIsFlushedAtEOF() async throws {
        let fixture = try makeFakeAppServerScript(
            body: """
            IFS= read -r initialize
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
            IFS= read -r initialized
            IFS= read -r rate_read
            printf '%s' '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":46}}}}'
            """
        )
        defer { fixture.cleanup() }
        let client = makeTestAppServerClient(
            transport: FoundationAccountQuotaProcessTransport(),
            timeout: 1
        )

        let snapshot = try await client.read(
            codexPath: fixture.executable.path,
            dataSource: nil
        ).get()

        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 46)
    }

    func testSuccessfulReadWaitsForRealChildExitBeforeReturning() async throws {
        let fixture = try makeFakeAppServerScript(
            body: """
            dir=${0%/*}
            printf '%s\n' "$$" > "$dir/pids"
            IFS= read -r initialize
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
            IFS= read -r initialized
            IFS= read -r rate_read
            trap '' TERM
            printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":22}}}}'
            exec /bin/sleep 30
            """
        )
        defer { fixture.cleanup() }
        let pidFile = fixture.directory.appendingPathComponent("pids")
        defer { terminateFixtureProcesses(in: pidFile) }
        let client = makeTestAppServerClient(
            transport: FoundationAccountQuotaProcessTransport(),
            timeout: 1
        )

        let snapshot = try await client.read(
            codexPath: fixture.executable.path,
            dataSource: nil
        ).get()

        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 22)
        let pids = fixtureProcessIDs(in: pidFile)
        XCTAssertEqual(pids.count, 1)
        XCTAssertFalse(pids.contains(where: processIsAlive))
    }

    func testRetryWaitsForPreviousRealChildExitAndLeavesNoChildAlive() async throws {
        let fixture = try makeFakeAppServerScript(
            body: """
            dir=${0%/*}
            if [ -f "$dir/last-pid" ]; then
                previous=$(cat "$dir/last-pid")
                if kill -0 "$previous" 2>/dev/null; then
                    printf '%s\n' "$previous" >> "$dir/overlap"
                fi
            fi
            printf '%s\n' "$$" >> "$dir/pids"
            printf '%s\n' "$$" > "$dir/last-pid"
            trap '' TERM
            exec /bin/sleep 30
            """
        )
        defer { fixture.cleanup() }
        let pidFile = fixture.directory.appendingPathComponent("pids")
        defer { terminateFixtureProcesses(in: pidFile) }
        let executablePath = fixture.executable.path
        let dependencies = AccountQuotaReaderDependencies(
            transport: FoundationAccountQuotaProcessTransport(),
            locateCodexBinary: { executablePath },
            timeout: 0.05,
            retryDelayNanoseconds: 0,
            maxAttempts: 2,
            shouldReadResetCredits: false,
            localAccountNameLookup: { _ in nil }
        )

        _ = await AccountQuotaReader.read(dataSource: nil, dependencies: dependencies)

        let pids = fixtureProcessIDs(in: pidFile)
        XCTAssertEqual(pids.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("overlap").path
        ))
        XCTAssertFalse(pids.contains(where: processIsAlive))
    }

    func testProcessLifecycleRejectsWritesAfterTerminationDeterministically() async {
        var writeCount = 0
        var closeCount = 0
        var terminateCount = 0
        let lifecycle = AccountQuotaProcessLifecycle(
            write: { _ in writeCount += 1 },
            closeInput: { closeCount += 1 },
            requestGracefulTermination: { terminateCount += 1 }
        )

        lifecycle.requestTermination()

        XCTAssertThrowsError(try lifecycle.write(Data("late write".utf8))) { error in
            XCTAssertEqual(error as? AccountQuotaProcessLifecycleError, .writeAfterTermination)
        }
        await waitUntil("stdin close after lifecycle termination") {
            closeCount == 1
        }
        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(terminateCount, 1)
    }

    func testCancellationDuringPermanentlyBlockedPostInitializeWriteMakesProgress() async {
        let transport = BlockingPostInitializeTransport()
        let client = makeTestAppServerClient(transport: transport, timeout: 2)
        let task = Task {
            await client.read(codexPath: "/fake/codex", dataSource: nil)
        }
        let completion = CompletionFlag()
        let observer = Task {
            _ = await task.value
            completion.markComplete()
        }

        XCTAssertEqual(
            transport.probe.postInitializeWriteStarted.wait(timeout: .now() + 1),
            .success
        )
        let cancellation = Task.detached {
            task.cancel()
        }
        let completedWithoutExternalRelease = await waitForCondition(timeout: 0.3) {
            completion.isComplete
        }
        if !completedWithoutExternalRelease {
            transport.probe.releaseBlockedWriteForFailureCleanup()
        }
        _ = await cancellation.result
        _ = await observer.value
        let result = await task.value
        await waitUntil("serialized stdin close after blocked write") {
            transport.probe.closeCount == 1
        }

        XCTAssertTrue(
            completedWithoutExternalRelease,
            "Cancellation must terminate the child and unblock stdin without test-side release"
        )
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(transport.probe.writeCount, 2)
        XCTAssertEqual(transport.probe.closeCount, 1)
        XCTAssertEqual(transport.probe.terminateCount, 1)
        XCTAssertFalse(transport.probe.observedInputCloseOverlap)
    }
}

private final class ScriptedQuotaProcessTransport: AccountQuotaProcessTransport, @unchecked Sendable {
    struct Scenario {
        var stdoutLines: [Data]
        var stderr: Data = Data()
        var shutdownError: QuotaReaderTestError?
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
    private let shutdownError: QuotaReaderTestError?

    init(scenario: ScriptedQuotaProcessTransport.Scenario, stderrTailLimit: Int) {
        stdoutLines = scenario.stdoutLines
        shutdownError = scenario.shutdownError
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

    func nextStdoutEvent(timeout: TimeInterval) throws -> AccountQuotaStdoutEvent {
        condition.lock()
        defer { condition.unlock() }
        if !stdoutLines.isEmpty {
            return .line(stdoutLines.removeFirst())
        }
        guard !terminated else { return .endOfFile }
        _ = condition.wait(until: Date().addingTimeInterval(timeout))
        if !stdoutLines.isEmpty {
            return .line(stdoutLines.removeFirst())
        }
        return terminated ? .endOfFile : .idle
    }

    func stderrTailText() -> String? {
        stderr.text
    }

    func requestTermination() {
        condition.withLock {
            terminated = true
            condition.broadcast()
        }
    }

    func shutdown() throws -> AccountQuotaProcessExit {
        requestTermination()
        if let shutdownError {
            throw shutdownError
        }
        return AccountQuotaProcessExit(status: 0, reason: .exit)
    }
}

private enum QuotaReaderTestError: LocalizedError {
    case noScenario
    case shutdownFailed

    var errorDescription: String? {
        switch self {
        case .noScenario:
            return "No scripted quota process scenario remains."
        case .shutdownFailed:
            return "Synthetic shutdown failure."
        }
    }
}

private final class BlockingPostInitializeTransport: AccountQuotaProcessTransport, @unchecked Sendable {
    let probe = BlockingPostInitializeProbe()
    let session: BlockingPostInitializeSession

    init() {
        session = BlockingPostInitializeSession(probe: probe)
    }

    func start(codexPath: String, dataSource: CodexDataSource?) throws -> any AccountQuotaProcessSession {
        session
    }
}

private final class BlockingPostInitializeSession: AccountQuotaProcessSession, @unchecked Sendable {
    let lifecycle: AccountQuotaProcessLifecycle
    private let lock = NSLock()
    private var didSendInitializeResponse = false

    init(probe: BlockingPostInitializeProbe) {
        lifecycle = AccountQuotaProcessLifecycle(
            write: probe.write,
            closeInput: probe.closeInput,
            requestGracefulTermination: probe.requestGracefulTermination
        )
    }

    func writeStdin(_ data: Data) throws {
        try lifecycle.write(data)
    }

    func nextStdoutEvent(timeout: TimeInterval) throws -> AccountQuotaStdoutEvent {
        lock.withLock {
            guard !didSendInitializeResponse else { return .idle }
            didSendInitializeResponse = true
            return .line(jsonLine(["jsonrpc": "2.0", "id": 1, "result": [:]]))
        }
    }

    func stderrTailText() -> String? {
        nil
    }

    func requestTermination() {
        lifecycle.requestTermination()
    }

    func shutdown() throws -> AccountQuotaProcessExit {
        requestTermination()
        return AccountQuotaProcessExit(status: 0, reason: .exit)
    }
}

private final class BlockingPostInitializeProbe: @unchecked Sendable {
    let postInitializeWriteStarted = DispatchSemaphore(value: 0)
    private let blockedWrite = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var writes = 0
    private var closes = 0
    private var terminations = 0
    private var writing = false
    private var inputCloseOverlap = false
    private var didReleaseBlockedWrite = false

    var writeCount: Int { lock.withLock { writes } }
    var closeCount: Int { lock.withLock { closes } }
    var terminateCount: Int { lock.withLock { terminations } }
    var observedInputCloseOverlap: Bool { lock.withLock { inputCloseOverlap } }

    func write(_ data: Data) throws {
        let count = lock.withLock {
            writes += 1
            return writes
        }
        if count == 2 {
            lock.withLock { writing = true }
            postInitializeWriteStarted.signal()
            blockedWrite.wait()
            lock.withLock { writing = false }
        }
    }

    func closeInput() {
        lock.withLock {
            inputCloseOverlap = inputCloseOverlap || writing
            closes += 1
        }
    }

    func requestGracefulTermination() {
        let shouldRelease = lock.withLock {
            terminations += 1
            guard !didReleaseBlockedWrite else { return false }
            didReleaseBlockedWrite = true
            return true
        }
        if shouldRelease {
            blockedWrite.signal()
        }
    }

    func releaseBlockedWriteForFailureCleanup() {
        let shouldRelease = lock.withLock {
            guard !didReleaseBlockedWrite else { return false }
            didReleaseBlockedWrite = true
            return true
        }
        if shouldRelease {
            blockedWrite.signal()
        }
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var complete = false

    var isComplete: Bool { lock.withLock { complete } }

    func markComplete() {
        lock.withLock { complete = true }
    }
}

private final class LocalAccountLookupProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let accountName: String
    private var lookups = 0
    private var nilSourceLookups = 0

    init(accountName: String) {
        self.accountName = accountName
    }

    var lookupCount: Int { lock.withLock { lookups } }
    var nilSourceLookupCount: Int { lock.withLock { nilSourceLookups } }

    func readAccountName(dataSource: CodexDataSource?) -> String? {
        lock.withLock {
            lookups += 1
            if dataSource == nil {
                nilSourceLookups += 1
            }
        }
        return accountName
    }
}

private func makeTestAppServerClient(
    transport: any AccountQuotaProcessTransport,
    timeout: TimeInterval
) -> AccountQuotaAppServerClient {
    AccountQuotaAppServerClient(
        transport: transport,
        timeout: timeout,
        localAccountNameLookup: { _ in nil }
    )
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

private final class FakeAppServerFixture {
    let directory: URL
    let executable: URL
    private let lock = NSLock()
    private var cleaned = false

    init(directory: URL, executable: URL) {
        self.directory = directory
        self.executable = executable
    }

    deinit {
        cleanup()
    }

    func cleanup() {
        let shouldRemove = lock.withLock {
            guard !cleaned else { return false }
            cleaned = true
            return true
        }
        guard shouldRemove else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeFakeAppServerScript(body: String) throws -> FakeAppServerFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuotaReaderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("fake-codex")
    try ("#!/bin/sh\nset -eu\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return FakeAppServerFixture(directory: directory, executable: script)
}

private func fixtureProcessIDs(in file: URL) -> [pid_t] {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
}

private func processIsAlive(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

private func terminateFixtureProcesses(in file: URL) {
    let pids = fixtureProcessIDs(in: file)
    for pid in pids where processIsAlive(pid) {
        _ = kill(pid, SIGKILL)
    }
    for _ in 0..<50 where pids.contains(where: processIsAlive) {
        usleep(10_000)
    }
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

private func waitForCondition(
    timeout: TimeInterval,
    condition: @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}
