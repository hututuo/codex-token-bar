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

    func testLaunchLeaseBlocksSeparateReadUntilAdoptedOwnerExits() async throws {
        let leasePool = AccountQuotaProcessLaunchLeasePool()
        let adoption = HeldLaunchLeaseAdoption()
        defer { adoption.release() }
        let transport = LeaseAwareQuotaProcessTransport(
            leasePool: leasePool,
            adoption: adoption,
            scenarios: [
                .init(
                    result: fallbackRateLimits(usedPercent: 31),
                    shutdown: .adoptAndFail
                ),
                .init(
                    result: fallbackRateLimits(usedPercent: 47),
                    shutdown: .releaseNormally
                )
            ]
        )
        let dependencies = AccountQuotaReaderDependencies.testing(
            transport: transport,
            timeout: 0.2,
            maxAttempts: 3
        )

        let first = await AccountQuotaReader.read(dataSource: nil, dependencies: dependencies)
        XCTAssertThrowsError(try first.get()) { error in
            XCTAssertTrue(error is AccountQuotaProcessOwnershipFailure)
        }
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(transport.startAttemptCount, 1)
        XCTAssertTrue(leasePool.isHeld)
        XCTAssertTrue(adoption.isHoldingLease)

        let second = await AccountQuotaReader.read(dataSource: nil, dependencies: dependencies)
        XCTAssertThrowsError(try second.get()) { error in
            XCTAssertEqual(error as? AccountQuotaProcessLaunchLeaseError, .inFlight)
        }
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(transport.startAttemptCount, 2)

        adoption.release()
        XCTAssertFalse(leasePool.isHeld)
        let third = await AccountQuotaReader.read(dataSource: nil, dependencies: dependencies)

        XCTAssertEqual(try third.get().fiveHour?.usedPercent, 47)
        XCTAssertEqual(transport.startCount, 2)
        XCTAssertEqual(transport.startAttemptCount, 3)
        XCTAssertFalse(leasePool.isHeld)
    }

    func testFoundationRunFailureReleasesLaunchLease() throws {
        let leasePool = AccountQuotaProcessLaunchLeasePool()
        let transport = FoundationAccountQuotaProcessTransport(launchLeasePool: leasePool)
        let missingExecutable = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaReaderTests-missing-\(UUID().uuidString)")

        XCTAssertThrowsError(try transport.start(
            codexPath: missingExecutable.path,
            dataSource: nil
        ))
        XCTAssertFalse(leasePool.isHeld)

        let lease = try leasePool.acquire()
        XCTAssertTrue(leasePool.isHeld)
        lease.release()
        XCTAssertFalse(leasePool.isHeld)
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
        let leasePool = AccountQuotaProcessLaunchLeasePool()
        let client = makeTestAppServerClient(
            transport: FoundationAccountQuotaProcessTransport(launchLeasePool: leasePool),
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
        XCTAssertFalse(leasePool.isHeld)
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
        let leasePool = AccountQuotaProcessLaunchLeasePool()
        let dependencies = AccountQuotaReaderDependencies(
            transport: FoundationAccountQuotaProcessTransport(launchLeasePool: leasePool),
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
        XCTAssertFalse(leasePool.isHeld)
    }

    func testProcessLifecycleRejectsWritesAfterTerminationDeterministically() {
        let writer = CancellationIntrinsicStdinWriter(mode: .succeed)
        let termination = LockedTerminationProbe()
        let lifecycle = AccountQuotaProcessLifecycle(
            writer: writer,
            requestGracefulTermination: termination.request
        )

        lifecycle.requestTermination()

        XCTAssertThrowsError(try lifecycle.write(Data("late write".utf8))) { error in
            XCTAssertEqual(error as? AccountQuotaProcessLifecycleError, .writeAfterTermination)
        }
        XCTAssertEqual(writer.writeCount, 0)
        XCTAssertEqual(writer.closeCount, 1)
        XCTAssertEqual(termination.requestCount, 1)
    }

    func testCancellationAloneStopsForeverWouldBlockWriterAndReleasesResources() async {
        var writer: CancellationIntrinsicStdinWriter? = .init(mode: .wouldBlockOnSecondWrite)
        weak var releasedWriter = writer

        let evidence = await runCancellationIntrinsicRead(writer: writer!)

        XCTAssertLessThan(evidence.cancellationDuration, 0.3)
        XCTAssertThrowsError(try evidence.result.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(writer?.writeCount, 2)
        XCTAssertEqual(writer?.closeCount, 1)
        XCTAssertFalse(writer?.observedCloseDuringWrite ?? true)
        XCTAssertEqual(evidence.terminationRequestCount, 1)

        writer = nil
        XCTAssertNil(releasedWriter, "No queue worker or descriptor owner may retain stdin")
    }

    func testPhysicalWriteFailureWinsOverOwnedEOF() async {
        let writer = CancellationIntrinsicStdinWriter(mode: .failOnSecondWrite)
        let transport = CancellationIntrinsicTransport(
            writer: writer,
            eventAfterInitialize: .endOfFile
        )
        let client = makeTestAppServerClient(transport: transport, timeout: 0.2)

        let result = await client.read(codexPath: "/fake/codex", dataSource: nil)

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? QuotaReaderTestError, .stdinWriteFailed)
        }
        XCTAssertEqual(transport.stdoutEventCount, 1)
        XCTAssertEqual(writer.writeCount, 2)
        XCTAssertEqual(writer.closeCount, 1)
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

private enum QuotaReaderTestError: LocalizedError, Equatable {
    case noScenario
    case shutdownFailed
    case stdinWriteFailed
    case writerSafetyTimeout

    var errorDescription: String? {
        switch self {
        case .noScenario:
            return "No scripted quota process scenario remains."
        case .shutdownFailed:
            return "Synthetic shutdown failure."
        case .stdinWriteFailed:
            return "Synthetic stdin write failure."
        case .writerSafetyTimeout:
            return "Cancellation-aware writer safety timeout."
        }
    }
}

private final class HeldLaunchLeaseAdoption: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: AccountQuotaProcessLaunchLease?

    var isHoldingLease: Bool { lock.withLock { lease != nil } }

    func adopt(_ lease: AccountQuotaProcessLaunchLease) {
        lock.withLock { self.lease = lease }
    }

    func release() {
        let lease = lock.withLock {
            defer { self.lease = nil }
            return self.lease
        }
        lease?.release()
    }
}

private final class LeaseAwareQuotaProcessTransport: AccountQuotaProcessTransport, @unchecked Sendable {
    struct Scenario {
        enum Shutdown {
            case adoptAndFail
            case releaseNormally
        }

        let result: [String: Any]
        let shutdown: Shutdown
    }

    private let lock = NSLock()
    private let leasePool: AccountQuotaProcessLaunchLeasePool
    private let adoption: HeldLaunchLeaseAdoption
    private var scenarios: [Scenario]
    private var starts = 0
    private var startAttempts = 0

    init(
        leasePool: AccountQuotaProcessLaunchLeasePool,
        adoption: HeldLaunchLeaseAdoption,
        scenarios: [Scenario]
    ) {
        self.leasePool = leasePool
        self.adoption = adoption
        self.scenarios = scenarios
    }

    var startCount: Int { lock.withLock { starts } }
    var startAttemptCount: Int { lock.withLock { startAttempts } }

    func start(codexPath: String, dataSource: CodexDataSource?) throws -> any AccountQuotaProcessSession {
        lock.withLock { startAttempts += 1 }
        let lease = try leasePool.acquire()
        do {
            let scenario = try lock.withLock {
                guard !scenarios.isEmpty else { throw QuotaReaderTestError.noScenario }
                starts += 1
                return scenarios.removeFirst()
            }
            return LeaseAwareQuotaProcessSession(
                scenario: scenario,
                lease: lease,
                adoption: adoption
            )
        } catch {
            lease.release()
            throw error
        }
    }
}

private final class LeaseAwareQuotaProcessSession: AccountQuotaProcessSession, @unchecked Sendable {
    private let session: ScriptedQuotaProcessSession
    private let scenario: LeaseAwareQuotaProcessTransport.Scenario
    private let lease: AccountQuotaProcessLaunchLease
    private let adoption: HeldLaunchLeaseAdoption

    init(
        scenario: LeaseAwareQuotaProcessTransport.Scenario,
        lease: AccountQuotaProcessLaunchLease,
        adoption: HeldLaunchLeaseAdoption
    ) {
        self.scenario = scenario
        self.lease = lease
        self.adoption = adoption
        session = ScriptedQuotaProcessSession(
            scenario: successfulScenario(result: scenario.result),
            stderrTailLimit: 16_384
        )
    }

    func writeStdin(_ data: Data) throws { try session.writeStdin(data) }
    func nextStdoutEvent(timeout: TimeInterval) throws -> AccountQuotaStdoutEvent {
        try session.nextStdoutEvent(timeout: timeout)
    }
    func stderrTailText() -> String? { session.stderrTailText() }
    func requestTermination() { session.requestTermination() }

    func shutdown() throws -> AccountQuotaProcessExit {
        let exit = try session.shutdown()
        switch scenario.shutdown {
        case .adoptAndFail:
            adoption.adopt(lease)
            throw QuotaReaderTestError.shutdownFailed
        case .releaseNormally:
            lease.release()
            return exit
        }
    }
}

private final class CancellationIntrinsicTransport: AccountQuotaProcessTransport, @unchecked Sendable {
    private let session: CancellationIntrinsicSession

    init(writer: CancellationIntrinsicStdinWriter, eventAfterInitialize: AccountQuotaStdoutEvent) {
        session = CancellationIntrinsicSession(
            writer: writer,
            eventAfterInitialize: eventAfterInitialize
        )
    }

    var stdoutEventCount: Int { session.stdoutEventCount }
    var terminationRequestCount: Int { session.terminationRequestCount }

    func start(codexPath: String, dataSource: CodexDataSource?) throws -> any AccountQuotaProcessSession {
        return session
    }
}

private final class CancellationIntrinsicSession: AccountQuotaProcessSession, @unchecked Sendable {
    private let lock = NSLock()
    private let lifecycle: AccountQuotaProcessLifecycle
    private let termination = LockedTerminationProbe()
    private let eventAfterInitialize: AccountQuotaStdoutEvent
    private var events = 0

    init(writer: CancellationIntrinsicStdinWriter, eventAfterInitialize: AccountQuotaStdoutEvent) {
        self.eventAfterInitialize = eventAfterInitialize
        lifecycle = AccountQuotaProcessLifecycle(
            writer: writer,
            requestGracefulTermination: termination.request
        )
    }

    var stdoutEventCount: Int { lock.withLock { events } }
    var terminationRequestCount: Int { termination.requestCount }

    func writeStdin(_ data: Data) throws { try lifecycle.write(data) }

    func nextStdoutEvent(timeout: TimeInterval) throws -> AccountQuotaStdoutEvent {
        lock.withLock {
            events += 1
            if events == 1 {
                return .line(jsonLine(["jsonrpc": "2.0", "id": 1, "result": [:]]))
            }
            return eventAfterInitialize
        }
    }

    func stderrTailText() -> String? { nil }
    func requestTermination() { lifecycle.requestTermination() }

    func shutdown() throws -> AccountQuotaProcessExit {
        lifecycle.requestTermination()
        return AccountQuotaProcessExit(status: 0, reason: .exit)
    }
}

private final class CancellationIntrinsicStdinWriter: AccountQuotaStdinWriting, @unchecked Sendable {
    enum Mode {
        case succeed
        case wouldBlockOnSecondWrite
        case failOnSecondWrite
    }

    let secondWriteStarted = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let mode: Mode
    private var writes = 0
    private var closes = 0
    private var writing = false
    private var closeDuringWrite = false

    init(mode: Mode) {
        self.mode = mode
    }

    var writeCount: Int { lock.withLock { writes } }
    var closeCount: Int { lock.withLock { closes } }
    var observedCloseDuringWrite: Bool { lock.withLock { closeDuringWrite } }

    func write(
        _ data: Data,
        cancellationRequested: @escaping @Sendable () -> Bool
    ) throws {
        let count = lock.withLock {
            writes += 1
            writing = true
            return writes
        }
        defer { lock.withLock { writing = false } }
        guard count == 2 else { return }

        switch mode {
        case .succeed:
            return
        case .failOnSecondWrite:
            throw QuotaReaderTestError.stdinWriteFailed
        case .wouldBlockOnSecondWrite:
            secondWriteStarted.signal()
            let safetyDeadline = Date().addingTimeInterval(1)
            while !cancellationRequested() {
                if Date() >= safetyDeadline {
                    throw QuotaReaderTestError.writerSafetyTimeout
                }
                usleep(1_000)
            }
            throw CancellationError()
        }
    }

    func close() {
        lock.withLock {
            closeDuringWrite = closeDuringWrite || writing
            closes += 1
        }
    }
}

private final class LockedTerminationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int { lock.withLock { requests } }

    func request() {
        lock.withLock { requests += 1 }
    }
}

private struct CancellationIntrinsicEvidence {
    let result: Result<AccountQuotaSnapshot, Error>
    let cancellationDuration: TimeInterval
    let terminationRequestCount: Int
}

private func runCancellationIntrinsicRead(
    writer: CancellationIntrinsicStdinWriter
) async -> CancellationIntrinsicEvidence {
    let transport = CancellationIntrinsicTransport(
        writer: writer,
        eventAfterInitialize: .idle
    )
    let client = makeTestAppServerClient(transport: transport, timeout: 2)
    let task = Task {
        await client.read(codexPath: "/fake/codex", dataSource: nil)
    }

    XCTAssertEqual(writer.secondWriteStarted.wait(timeout: .now() + 1), .success)
    let cancelledAt = Date()
    let cancellation = Task.detached { task.cancel() }
    let result = await task.value
    _ = await cancellation.result
    return CancellationIntrinsicEvidence(
        result: result,
        cancellationDuration: Date().timeIntervalSince(cancelledAt),
        terminationRequestCount: transport.terminationRequestCount
    )
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
