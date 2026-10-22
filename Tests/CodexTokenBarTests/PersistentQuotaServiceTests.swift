import Foundation
import XCTest
@testable import CodexTokenBar

final class PersistentQuotaServiceTests: XCTestCase {
    func testQuotaAndCardsShareCachedSnapshotAndInitializedProcessPastCacheExpiry() throws {
        let clock = PersistentQuotaTestClock(now: 100)
        let homes = try PersistentQuotaTemporaryHomes()
        let home = try homes.makeHome()
        let source = CodexDataSource(codexHome: home, origin: .userSelected)
        let transport = PersistentQuotaScriptedTransport(
            clock: clock,
            scripts: [PersistentQuotaSessionScript(reads: [
                .result(quotaResult(usedPercent: 21, resetCreditCount: 3)),
                .result(quotaResult(usedPercent: 27, resetCreditCount: 4)),
            ])]
        )
        let service = makeService(transport: transport, clock: clock)
        defer { service.shutdown() }

        let first = try service.read(dataSource: source).get()
        let cached = try service.read(dataSource: source).get()

        XCTAssertEqual(cached, first)
        XCTAssertEqual(first.fiveHour?.usedPercent, 21)
        XCTAssertEqual(first.resetCreditsAvailableCount, 3)
        XCTAssertEqual(first.resetCredits.first?.id, "card-3")
        XCTAssertEqual(transport.rateLimitReadCount, 1)

        clock.advance(by: 5.1)
        let refreshed = try service.read(dataSource: source).get()

        XCTAssertEqual(refreshed.fiveHour?.usedPercent, 27)
        XCTAssertEqual(refreshed.resetCreditsAvailableCount, 4)
        XCTAssertEqual(refreshed.resetCredits.first?.id, "card-4")
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(transport.initializeCount, 1)
        XCTAssertEqual(transport.rateLimitReadCount, 2)
    }

    func testCompletedRemoteRPCErrorKeepsInitializedProcessForNextRead() throws {
        let clock = PersistentQuotaTestClock(now: 100)
        let homes = try PersistentQuotaTemporaryHomes()
        let home = try homes.makeHome()
        let source = CodexDataSource(codexHome: home, origin: .userSelected)
        let transport = PersistentQuotaScriptedTransport(
            clock: clock,
            scripts: [PersistentQuotaSessionScript(reads: [
                .rpcError("temporary account service error"),
                .result(quotaResult(usedPercent: 35, resetCreditCount: 2)),
            ])]
        )
        let service = makeService(transport: transport, clock: clock)
        defer { service.shutdown() }

        XCTAssertThrowsError(try service.read(dataSource: source).get())
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(transport.initializeCount, 1)
        XCTAssertEqual(transport.sessions[0].shutdownCount, 0)

        let recovered = try service.read(dataSource: source).get()

        XCTAssertEqual(recovered.fiveHour?.usedPercent, 35)
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(transport.initializeCount, 1)
        XCTAssertEqual(transport.rateLimitReadCount, 2)
    }

    func testEOFClosesSessionBacksOffAndReconnects() throws {
        let clock = PersistentQuotaTestClock(now: 100)
        let homes = try PersistentQuotaTemporaryHomes()
        let home = try homes.makeHome()
        let source = CodexDataSource(codexHome: home, origin: .userSelected)
        let transport = PersistentQuotaScriptedTransport(
            clock: clock,
            scripts: [
                PersistentQuotaSessionScript(reads: [.eof]),
                PersistentQuotaSessionScript(reads: [.result(quotaResult(usedPercent: 44, resetCreditCount: 1))]),
            ]
        )
        let service = makeService(transport: transport, clock: clock)
        defer { service.shutdown() }

        XCTAssertThrowsError(try service.read(dataSource: source).get())
        XCTAssertTrue(transport.sessions[0].isTerminated)
        XCTAssertEqual(transport.sessions[0].shutdownCount, 1)
        XCTAssertEqual(transport.startCount, 1)

        XCTAssertThrowsError(try service.read(dataSource: source).get())
        XCTAssertEqual(transport.startCount, 1, "A retry inside the backoff window must not launch another child.")

        clock.advance(by: 1.1)
        let reconnected = try service.read(dataSource: source).get()

        XCTAssertEqual(reconnected.fiveHour?.usedPercent, 44)
        XCTAssertEqual(transport.startCount, 2)
        XCTAssertEqual(transport.sessions[1].initializeCount, 1)
    }

    func testTimeoutClosesSessionBacksOffAndReconnects() throws {
        let clock = PersistentQuotaTestClock(now: 100)
        let homes = try PersistentQuotaTemporaryHomes()
        let home = try homes.makeHome()
        let source = CodexDataSource(codexHome: home, origin: .userSelected)
        let transport = PersistentQuotaScriptedTransport(
            clock: clock,
            scripts: [
                PersistentQuotaSessionScript(reads: [.timeout]),
                PersistentQuotaSessionScript(reads: [.result(quotaResult(usedPercent: 52, resetCreditCount: 1))]),
            ]
        )
        let service = makeService(transport: transport, clock: clock, timeout: 0.1)
        defer { service.shutdown() }

        XCTAssertThrowsError(try service.read(dataSource: source).get())
        XCTAssertTrue(transport.sessions[0].isTerminated)
        XCTAssertEqual(transport.sessions[0].shutdownCount, 1)
        XCTAssertEqual(transport.startCount, 1)

        XCTAssertThrowsError(try service.read(dataSource: source).get())
        XCTAssertEqual(transport.startCount, 1, "Timeout recovery must respect the retry backoff.")

        clock.advance(by: 1.1)
        let reconnected = try service.read(dataSource: source).get()

        XCTAssertEqual(reconnected.fiveHour?.usedPercent, 52)
        XCTAssertEqual(transport.startCount, 2)
        XCTAssertEqual(transport.sessions[1].initializeCount, 1)
    }

    func testChangingCodexHomeShutsDownOldSessionBeforeStartingNewOne() throws {
        let clock = PersistentQuotaTestClock(now: 100)
        let homes = try PersistentQuotaTemporaryHomes()
        let firstHome = try homes.makeHome()
        let secondHome = try homes.makeHome()
        let firstSource = CodexDataSource(codexHome: firstHome, origin: .userSelected)
        let secondSource = CodexDataSource(codexHome: secondHome, origin: .userSelected)
        let transport = PersistentQuotaScriptedTransport(
            clock: clock,
            scripts: [
                PersistentQuotaSessionScript(reads: [.result(quotaResult(usedPercent: 18, resetCreditCount: 1))]),
                PersistentQuotaSessionScript(reads: [.result(quotaResult(usedPercent: 63, resetCreditCount: 2))]),
            ]
        )
        let service = makeService(transport: transport, clock: clock)
        defer { service.shutdown() }

        _ = try service.read(dataSource: firstSource).get()
        XCTAssertEqual(transport.sessions[0].shutdownCount, 0)

        let second = try service.read(dataSource: secondSource).get()

        XCTAssertEqual(second.fiveHour?.usedPercent, 63)
        XCTAssertEqual(transport.startCount, 2)
        XCTAssertEqual(transport.startedHomePaths, [firstSource.codexHome.path, secondSource.codexHome.path])
        XCTAssertTrue(transport.sessions[0].isTerminated)
        XCTAssertEqual(transport.sessions[0].shutdownCount, 1)
    }

    func testShutdownCleansOwnedSessionAndRejectsFutureReads() throws {
        let clock = PersistentQuotaTestClock(now: 100)
        let homes = try PersistentQuotaTemporaryHomes()
        let home = try homes.makeHome()
        let source = CodexDataSource(codexHome: home, origin: .userSelected)
        let transport = PersistentQuotaScriptedTransport(
            clock: clock,
            scripts: [PersistentQuotaSessionScript(reads: [.result(quotaResult(usedPercent: 30, resetCreditCount: 1))])]
        )
        let locateCounter = PersistentQuotaTestCounter()
        let service = PersistentQuotaService(
            transport: transport,
            locate: {
                locateCounter.increment()
                return "/fake/codex"
            },
            timeout: 1,
            cacheDuration: 5,
            clock: { clock.now }
        )

        _ = try service.read(dataSource: source).get()
        service.shutdown()

        XCTAssertTrue(transport.sessions[0].isTerminated)
        XCTAssertEqual(transport.sessions[0].shutdownCount, 1)
        XCTAssertThrowsError(try service.read(dataSource: source).get())
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(locateCounter.value, 1, "A stopped service must reject reads before locating or launching another child.")
    }

    private func makeService(
        transport: PersistentQuotaScriptedTransport,
        clock: PersistentQuotaTestClock,
        timeout: TimeInterval = 1
    ) -> PersistentQuotaService {
        PersistentQuotaService(
            transport: transport,
            locate: { "/fake/codex" },
            timeout: timeout,
            cacheDuration: 5,
            clock: { clock.now }
        )
    }

    private func quotaResult(usedPercent: Int, resetCreditCount: Int) -> [String: Any] {
        [
            "rateLimits": [
                "limitId": "codex",
                "primary": ["usedPercent": usedPercent],
                "secondary": ["usedPercent": 34],
            ],
            "rateLimitResetCredits": [
                "availableCount": resetCreditCount,
                "credits": [[
                    "id": "card-\(resetCreditCount)",
                    "status": "available",
                    "resetType": "codexRateLimits",
                    "title": "Reset card",
                    "grantedAt": 1_780_000_000,
                    "expiresAt": 1_790_000_000,
                ]],
            ],
        ]
    }
}

private final class PersistentQuotaTemporaryHomes {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersistentQuotaServiceTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeHome() throws -> URL {
        let home = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class PersistentQuotaTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(now: TimeInterval) {
        value = now
    }

    var now: TimeInterval {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value += interval }
    }
}

private final class PersistentQuotaTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private struct PersistentQuotaSessionScript {
    let reads: [PersistentQuotaReadOutcome]
}

private enum PersistentQuotaReadOutcome {
    case result([String: Any])
    case rpcError(String)
    case eof
    case timeout
}

private enum PersistentQuotaTestError: Error {
    case missingReadOutcome
    case unexpectedRequest
}

private final class PersistentQuotaScriptedTransport: AccountQuotaProcessTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: PersistentQuotaTestClock
    private var scripts: [PersistentQuotaSessionScript]
    private var createdSessions: [PersistentQuotaScriptedSession] = []
    private var homePaths: [String?] = []

    init(clock: PersistentQuotaTestClock, scripts: [PersistentQuotaSessionScript]) {
        self.clock = clock
        self.scripts = scripts
    }

    var sessions: [PersistentQuotaScriptedSession] {
        lock.withLock { createdSessions }
    }

    var startCount: Int {
        lock.withLock { createdSessions.count }
    }

    var startedHomePaths: [String?] {
        lock.withLock { homePaths }
    }

    var initializeCount: Int {
        sessions.reduce(0) { $0 + $1.initializeCount }
    }

    var rateLimitReadCount: Int {
        sessions.reduce(0) { $0 + $1.rateLimitReadCount }
    }

    func start(codexPath: String, dataSource: CodexDataSource?) throws -> any AccountQuotaProcessSession {
        try lock.withLock {
            guard !scripts.isEmpty else { throw PersistentQuotaTestError.missingReadOutcome }
            let session = PersistentQuotaScriptedSession(script: scripts.removeFirst(), clock: clock)
            createdSessions.append(session)
            homePaths.append(dataSource?.codexHome.path)
            return session
        }
    }
}

private final class PersistentQuotaScriptedSession: AccountQuotaProcessSession, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: PersistentQuotaTestClock
    private var reads: [PersistentQuotaReadOutcome]
    private var stdoutLines: [Data] = []
    private var timedOutReadPending = false
    private var terminated = false
    private var initializeRequests = 0
    private var rateLimitRequests = 0
    private var shutdownCalls = 0

    init(script: PersistentQuotaSessionScript, clock: PersistentQuotaTestClock) {
        reads = script.reads
        self.clock = clock
    }

    var initializeCount: Int {
        lock.withLock { initializeRequests }
    }

    var rateLimitReadCount: Int {
        lock.withLock { rateLimitRequests }
    }

    var shutdownCount: Int {
        lock.withLock { shutdownCalls }
    }

    var isTerminated: Bool {
        lock.withLock { terminated }
    }

    func writeStdin(_ data: Data) throws {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PersistentQuotaTestError.unexpectedRequest
        }
        guard let method = message["method"] as? String else { return }
        guard let id = message["id"] as? Int else { return }

        try lock.withLock {
            switch method {
            case "initialize":
                initializeRequests += 1
                try enqueue(["id": id, "result": [String: Any]()])
            case "account/rateLimits/read":
                rateLimitRequests += 1
                guard !reads.isEmpty else { throw PersistentQuotaTestError.missingReadOutcome }
                switch reads.removeFirst() {
                case .result(let result):
                    try enqueue(["id": id, "result": result])
                case .rpcError(let message):
                    try enqueue(["id": id, "error": ["message": message]])
                case .eof:
                    terminated = true
                case .timeout:
                    timedOutReadPending = true
                }
            default:
                throw PersistentQuotaTestError.unexpectedRequest
            }
        }
    }

    func nextStdoutEvent(timeout: TimeInterval) throws -> AccountQuotaStdoutEvent {
        enum Next {
            case line(Data)
            case eof
            case idle
            case timeout
        }
        let next = lock.withLock { () -> Next in
            if !stdoutLines.isEmpty { return .line(stdoutLines.removeFirst()) }
            if terminated { return .eof }
            if timedOutReadPending { return .timeout }
            return .idle
        }

        switch next {
        case .line(let line): return .line(line)
        case .eof: return .endOfFile
        case .idle: return .idle
        case .timeout:
            clock.advance(by: max(timeout, 0.001))
            return .idle
        }
    }

    func stderrTailText() -> String? { nil }

    func requestTermination() {
        lock.withLock { terminated = true }
    }

    func shutdown() throws -> AccountQuotaProcessExit {
        lock.withLock {
            shutdownCalls += 1
            terminated = true
        }
        return AccountQuotaProcessExit(status: 0, reason: .exit)
    }

    private func enqueue(_ message: [String: Any]) throws {
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(10)
        stdoutLines.append(line)
    }
}
