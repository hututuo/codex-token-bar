import Foundation
import Darwin

struct LiveAccountQuotaReader: QuotaReading {
    func readQuota(dataSource: CodexDataSource?) async -> Result<AccountQuotaSnapshot, Error> {
        await AccountQuotaReader.read(dataSource: dataSource)
    }
}

struct AccountQuotaReaderDependencies: Sendable {
    let transport: any AccountQuotaProcessTransport
    let locateCodexBinary: @Sendable () throws -> String
    let timeout: TimeInterval
    let retryDelayNanoseconds: UInt64
    let maxAttempts: Int
    let shouldReadResetCredits: Bool

    static let live = AccountQuotaReaderDependencies(
        transport: FoundationAccountQuotaProcessTransport(),
        locateCodexBinary: { try CodexBinaryLocator.findExecutable() },
        timeout: 12,
        retryDelayNanoseconds: 350_000_000,
        maxAttempts: 3,
        shouldReadResetCredits: true
    )

    static func testing(
        transport: any AccountQuotaProcessTransport,
        timeout: TimeInterval,
        maxAttempts: Int = 1
    ) -> AccountQuotaReaderDependencies {
        AccountQuotaReaderDependencies(
            transport: transport,
            locateCodexBinary: { "/fake/codex" },
            timeout: timeout,
            retryDelayNanoseconds: 0,
            maxAttempts: maxAttempts,
            shouldReadResetCredits: false
        )
    }
}

protocol AccountQuotaProcessTransport: Sendable {
    func start(codexPath: String, dataSource: CodexDataSource?) throws -> any AccountQuotaProcessSession
}

enum AccountQuotaStdoutEvent: Equatable, Sendable {
    case line(Data)
    case idle
    case endOfFile
}

struct AccountQuotaProcessExit: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case exit
        case uncaughtSignal
    }

    let status: Int32
    let reason: Reason
}

enum AccountQuotaProcessShutdownError: LocalizedError, Equatable, Sendable {
    case forceKillFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .forceKillFailed(let value):
            return "Unable to stop Codex app-server after graceful shutdown (errno \(value))."
        }
    }
}

protocol AccountQuotaProcessSession: AnyObject, Sendable {
    func writeStdin(_ data: Data) throws
    func nextStdoutEvent(timeout: TimeInterval) throws -> AccountQuotaStdoutEvent
    func stderrTailText() -> String?
    func requestTermination()
    func shutdown() throws -> AccountQuotaProcessExit
}

enum AccountQuotaProcessLifecycleError: LocalizedError, Equatable, Sendable {
    case writeAfterTermination

    var errorDescription: String? {
        switch self {
        case .writeAfterTermination:
            return "Codex app-server stdin is already closed."
        }
    }
}

final class AccountQuotaProcessLifecycle: @unchecked Sendable {
    private enum State {
        case running
        case terminating
    }

    private let condition = NSCondition()
    private let writeAction: (Data) throws -> Void
    private let closeInputAction: () -> Void
    private let requestGracefulTerminationAction: () -> Void
    private var state = State.running
    private var writeInProgress = false

    init(
        write: @escaping (Data) throws -> Void,
        closeInput: @escaping () -> Void,
        requestGracefulTermination: @escaping () -> Void
    ) {
        writeAction = write
        closeInputAction = closeInput
        requestGracefulTerminationAction = requestGracefulTermination
    }

    var isTerminationRequested: Bool {
        condition.withLock { state == .terminating }
    }

    func write(_ data: Data) throws {
        condition.lock()
        while writeInProgress && state == .running {
            condition.wait()
        }
        guard state == .running else {
            condition.unlock()
            throw AccountQuotaProcessLifecycleError.writeAfterTermination
        }
        writeInProgress = true
        condition.unlock()

        do {
            try writeAction(data)
            finishWrite()
        } catch {
            finishWrite()
            throw error
        }
    }

    func requestTermination() {
        condition.lock()
        guard state == .running else {
            condition.unlock()
            return
        }
        state = .terminating
        while writeInProgress {
            condition.wait()
        }
        closeInputAction()
        requestGracefulTerminationAction()
        condition.broadcast()
        condition.unlock()
    }

    private func finishWrite() {
        condition.withLock {
            writeInProgress = false
            condition.broadcast()
        }
    }
}

struct FoundationAccountQuotaProcessTransport: AccountQuotaProcessTransport, Sendable {
    private let stderrTailLimit: Int
    private let gracefulShutdownTimeout: TimeInterval
    private let forcedShutdownTimeout: TimeInterval

    init(
        stderrTailLimit: Int = 16_384,
        gracefulShutdownTimeout: TimeInterval = 0.25,
        forcedShutdownTimeout: TimeInterval = 1
    ) {
        self.stderrTailLimit = max(0, stderrTailLimit)
        self.gracefulShutdownTimeout = max(0, gracefulShutdownTimeout)
        self.forcedShutdownTimeout = max(0, forcedShutdownTimeout)
    }

    func start(codexPath: String, dataSource: CodexDataSource?) throws -> any AccountQuotaProcessSession {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server", "--listen", "stdio://"]
        if let dataSource {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = dataSource.codexHome.path
            process.environment = environment
        }

        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe

        let exitObserver = AccountQuotaProcessExitObserver()
        process.terminationHandler = { process in
            exitObserver.record(process: process)
        }
        let stdoutReader = AccountQuotaLineReader(handle: output.fileHandleForReading)
        let stderrTail = AccountQuotaStderrTail(maxBytes: stderrTailLimit)
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrTail.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        return FoundationAccountQuotaProcessSession(
            process: process,
            input: input.fileHandleForWriting,
            output: output.fileHandleForReading,
            error: errorPipe.fileHandleForReading,
            stdoutReader: stdoutReader,
            stderrTail: stderrTail,
            exitObserver: exitObserver,
            gracefulShutdownTimeout: gracefulShutdownTimeout,
            forcedShutdownTimeout: forcedShutdownTimeout
        )
    }
}

final class AccountQuotaStderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private var buffer = Data()

    init(maxBytes: Int) {
        self.maxBytes = max(0, maxBytes)
    }

    func append(_ data: Data) {
        guard !data.isEmpty, maxBytes > 0 else { return }
        lock.withLock {
            if data.count >= maxBytes {
                buffer = Data(data.suffix(maxBytes))
                return
            }
            buffer.append(data)
            if buffer.count > maxBytes {
                buffer.removeFirst(buffer.count - maxBytes)
            }
        }
    }

    var text: String? {
        lock.withLock {
            guard !buffer.isEmpty else { return nil }
            let value = String(decoding: buffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }
}

private final class AccountQuotaProcessExitObserver: @unchecked Sendable {
    private let condition = NSCondition()
    private var observedExit: AccountQuotaProcessExit?

    func record(process: Process) {
        let reason: AccountQuotaProcessExit.Reason = process.terminationReason == .exit
            ? .exit
            : .uncaughtSignal
        record(AccountQuotaProcessExit(status: process.terminationStatus, reason: reason))
    }

    func record(_ exit: AccountQuotaProcessExit) {
        condition.withLock {
            guard observedExit == nil else { return }
            observedExit = exit
            condition.broadcast()
        }
    }

    func wait(timeout: TimeInterval) -> AccountQuotaProcessExit? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        condition.lock()
        defer { condition.unlock() }
        while observedExit == nil {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            condition.wait(until: Date().addingTimeInterval(remaining))
        }
        return observedExit
    }
}

struct AccountQuotaAppServerClient: Sendable {
    private enum ReadOutcome {
        case result(Result<AccountQuotaSnapshot, Error>)
        case earlyExit(awaiting: String)
    }

    private let transport: any AccountQuotaProcessTransport
    private let timeout: TimeInterval

    init(transport: any AccountQuotaProcessTransport, timeout: TimeInterval) {
        self.transport = transport
        self.timeout = timeout
    }

    func read(
        codexPath: String,
        dataSource: CodexDataSource?
    ) async -> Result<AccountQuotaSnapshot, Error> {
        do {
            try Task.checkCancellation()
            let session = try transport.start(codexPath: codexPath, dataSource: dataSource)
            let outcome = await withTaskCancellationHandler {
                return read(session: session, dataSource: dataSource)
            } onCancel: {
                session.requestTermination()
            }
            let exit: AccountQuotaProcessExit
            do {
                exit = try session.shutdown()
            } catch {
                return .failure(error)
            }
            if Task.isCancelled {
                return .failure(CancellationError())
            }
            switch outcome {
            case .result(let result):
                return result
            case .earlyExit(let awaitedResponse):
                let reason = exit.reason == .exit ? "exit" : "signal"
                return .failure(AccountQuotaReaderError.serverError(
                    "Codex app-server exited before \(awaitedResponse) (\(reason) status \(exit.status))."
                ))
            }
        } catch {
            return .failure(error)
        }
    }

    private func read(
        session: any AccountQuotaProcessSession,
        dataSource: CodexDataSource?
    ) -> ReadOutcome {
        do {
            try session.writeStdin(try Self.jsonLine([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-token-bar",
                        "title": "Codex Token Bar",
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                    ],
                    "capabilities": [
                        "experimentalApi": false,
                        "requestAttestation": false
                    ]
                ]
            ]))

            let deadline = Date().addingTimeInterval(timeout)
            var stateMachine = AccountQuotaJSONRPCReaderStateMachine()
            while Date() < deadline {
                if Task.isCancelled {
                    return .result(.failure(CancellationError()))
                }
                let remaining = max(0, deadline.timeIntervalSinceNow)
                switch try session.nextStdoutEvent(timeout: min(0.05, remaining)) {
                case .idle:
                    continue
                case .endOfFile:
                    return .earlyExit(awaiting: stateMachine.awaitedResponseDescription)
                case .line(let line):
                    switch stateMachine.consume(line) {
                    case .ignore:
                        continue
                    case .sendRateLimitRead:
                        try session.writeStdin(try Self.jsonLine([
                            "jsonrpc": "2.0",
                            "method": "initialized"
                        ]))
                        try session.writeStdin(try Self.jsonLine([
                            "jsonrpc": "2.0",
                            "id": 2,
                            "method": "account/rateLimits/read"
                        ]))
                    case .complete(let result):
                        return .result(.success(AccountQuotaReader.parse(result, dataSource: dataSource)))
                    case .fail(let error):
                        return .result(.failure(error))
                    }
                }
            }
            if Task.isCancelled {
                return .result(.failure(CancellationError()))
            }
            return .result(.failure(AccountQuotaReaderError.timeout(stderrText: session.stderrTailText())))
        } catch {
            return .result(.failure(error))
        }
    }

    private static func jsonLine(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }
}

private struct AccountQuotaJSONRPCReaderStateMachine {
    private enum State {
        case awaitingInitialize
        case awaitingRateLimits
        case complete
    }

    enum Action {
        case ignore
        case sendRateLimitRead
        case complete([String: Any])
        case fail(AccountQuotaReaderError)
    }

    private var state = State.awaitingInitialize

    var awaitedResponseDescription: String {
        switch state {
        case .awaitingInitialize:
            return "initialize response"
        case .awaitingRateLimits:
            return "rate limits response"
        case .complete:
            return "JSON-RPC completion"
        }
    }

    mutating func consume(_ line: Data) -> Action {
        guard state != .complete,
              let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = message["id"] as? Int else {
            return .ignore
        }

        switch (state, id) {
        case (.awaitingInitialize, 1):
            if let error = message["error"] as? [String: Any],
               let message = error["message"] as? String {
                state = .complete
                return .fail(.serverError(message))
            }
            guard message["result"] != nil else { return .ignore }
            state = .awaitingRateLimits
            return .sendRateLimitRead
        case (.awaitingRateLimits, 2):
            state = .complete
            if let error = message["error"] as? [String: Any],
               let message = error["message"] as? String {
                return .fail(.serverError(message))
            }
            guard let result = message["result"] as? [String: Any] else {
                return .fail(.invalidResponse)
            }
            return .complete(result)
        default:
            return .ignore
        }
    }
}

private final class FoundationAccountQuotaProcessSession: AccountQuotaProcessSession, @unchecked Sendable {
    private let process: Process
    private let output: FileHandle
    private let error: FileHandle
    private let stdoutReader: AccountQuotaLineReader
    private let stderrTail: AccountQuotaStderrTail
    private let exitObserver: AccountQuotaProcessExitObserver
    private let gracefulShutdownTimeout: TimeInterval
    private let forcedShutdownTimeout: TimeInterval
    private let lifecycle: AccountQuotaProcessLifecycle

    init(
        process: Process,
        input: FileHandle,
        output: FileHandle,
        error: FileHandle,
        stdoutReader: AccountQuotaLineReader,
        stderrTail: AccountQuotaStderrTail,
        exitObserver: AccountQuotaProcessExitObserver,
        gracefulShutdownTimeout: TimeInterval,
        forcedShutdownTimeout: TimeInterval
    ) {
        self.process = process
        self.output = output
        self.error = error
        self.stdoutReader = stdoutReader
        self.stderrTail = stderrTail
        self.exitObserver = exitObserver
        self.gracefulShutdownTimeout = gracefulShutdownTimeout
        self.forcedShutdownTimeout = forcedShutdownTimeout
        lifecycle = AccountQuotaProcessLifecycle(
            write: { data in try input.write(contentsOf: data) },
            closeInput: { try? input.close() },
            requestGracefulTermination: {
                if process.isRunning {
                    process.terminate()
                }
            }
        )
    }

    deinit {
        output.readabilityHandler = nil
        error.readabilityHandler = nil
    }

    func writeStdin(_ data: Data) throws {
        try lifecycle.write(data)
    }

    func nextStdoutEvent(timeout: TimeInterval) throws -> AccountQuotaStdoutEvent {
        stdoutReader.next(timeout: timeout)
    }

    func stderrTailText() -> String? {
        stderrTail.text
    }

    func requestTermination() {
        lifecycle.requestTermination()
    }

    func shutdown() throws -> AccountQuotaProcessExit {
        lifecycle.requestTermination()
        if let exit = exitObserver.wait(timeout: gracefulShutdownTimeout) {
            return exit
        }

        if process.isRunning {
            errno = 0
            let result = kill(process.processIdentifier, SIGKILL)
            if result != 0 && errno != ESRCH {
                throw AccountQuotaProcessShutdownError.forceKillFailed(errno: errno)
            }
        }
        if let exit = exitObserver.wait(timeout: forcedShutdownTimeout) {
            return exit
        }

        // SIGKILL has already been issued; synchronously reap so a retry can never overlap this child.
        process.waitUntilExit()
        let reason: AccountQuotaProcessExit.Reason = process.terminationReason == .exit
            ? .exit
            : .uncaughtSignal
        let exit = AccountQuotaProcessExit(status: process.terminationStatus, reason: reason)
        exitObserver.record(exit)
        return exit
    }
}

enum AccountQuotaReader {
    static func read(
        dataSource: CodexDataSource?,
        dependencies: AccountQuotaReaderDependencies = .live
    ) async -> Result<AccountQuotaSnapshot, Error> {
        let trace = RefreshPerformanceProbe.begin("accountQuotaReader.read", metadata: [
            "source": dataSource?.displayPath ?? "default"
        ])
        let maxAttempts = max(1, dependencies.maxAttempts)
        var lastError: Error?
        for attempt in 1...maxAttempts {
            if Task.isCancelled {
                trace?.end("cancelled", metadata: ["attempt": String(attempt)])
                return .failure(CancellationError())
            }
            trace?.mark("attempt.begin", metadata: ["attempt": String(attempt)])
            let result: Result<AccountQuotaSnapshot, Error>
            do {
                let codexPath = try dependencies.locateCodexBinary()
                let client = AccountQuotaAppServerClient(
                    transport: dependencies.transport,
                    timeout: dependencies.timeout
                )
                result = await client.read(codexPath: codexPath, dataSource: dataSource)
            } catch {
                result = .failure(error)
            }
            switch result {
            case .success(let snapshot):
                trace?.mark("attempt.success", metadata: [
                    "attempt": String(attempt),
                    "available": snapshot.isAvailable ? "1" : "0"
                ])
                if snapshot.isAvailable || attempt == maxAttempts {
                    let enriched = dependencies.shouldReadResetCredits
                        ? await snapshotByAddingResetCredits(to: snapshot, dataSource: dataSource)
                        : snapshot
                    trace?.end("ok", metadata: [
                        "attempt": String(attempt),
                        "available": enriched.isAvailable ? "1" : "0",
                        "resetCredits": String(enriched.availableResetCreditCount)
                    ])
                    return .success(enriched)
                }
                lastError = AccountQuotaReaderError.emptyRateLimits
            case .failure(let error):
                trace?.mark("attempt.failed", metadata: [
                    "attempt": String(attempt),
                    "error": error.localizedDescription
                ])
                if error is CancellationError || Task.isCancelled {
                    trace?.end("cancelled", metadata: ["attempt": String(attempt)])
                    return .failure(CancellationError())
                }
                if error is AccountQuotaProcessShutdownError {
                    trace?.end("shutdown-failed", metadata: ["attempt": String(attempt)])
                    return .failure(error)
                }
                if attempt == maxAttempts {
                    trace?.end("failed", metadata: [
                        "attempt": String(attempt),
                        "error": error.localizedDescription
                    ])
                    return .failure(error)
                }
                lastError = error
            }
            trace?.mark("attempt.sleep", metadata: ["attempt": String(attempt)])
            do {
                try await Task.sleep(nanoseconds: dependencies.retryDelayNanoseconds)
            } catch {
                trace?.end("cancelled", metadata: ["attempt": String(attempt)])
                return .failure(error)
            }
        }
        trace?.end("failed", metadata: ["error": (lastError ?? AccountQuotaReaderError.invalidResponse).localizedDescription])
        return .failure(lastError ?? AccountQuotaReaderError.invalidResponse)
    }

    private static func snapshotByAddingResetCredits(
        to snapshot: AccountQuotaSnapshot,
        dataSource: CodexDataSource?
    ) async -> AccountQuotaSnapshot {
        let trace = RefreshPerformanceProbe.begin("accountQuotaReader.addResetCredits")
        var enriched = snapshot
        switch await readResetCredits(dataSource: dataSource) {
        case .success(let resetCredits):
            enriched.resetCreditsAvailableCount = resetCredits.availableCount
            enriched.resetCredits = resetCredits.credits
            trace?.end("ok", metadata: [
                "available": String(resetCredits.availableCount),
                "credits": String(resetCredits.credits.count)
            ])
        case .failure(let diagnostic):
            enriched.diagnostics.append(diagnostic)
            trace?.end("unavailable", metadata: [
                "category": diagnostic.category.rawValue,
                "underlying": diagnostic.underlyingCategory?.rawValue ?? "none"
            ])
        }
        return enriched
    }

    static func parse(_ result: [String: Any], dataSource: CodexDataSource?) -> AccountQuotaSnapshot {
        let byLimit = result["rateLimitsByLimitId"] as? [String: Any]
        let fallbackLimit = result["rateLimits"] as? [String: Any]
        let limitCards = parseLimitCards(byLimit: byLimit, fallbackLimit: fallbackLimit)
        let codex = (byLimit?["codex"] as? [String: Any]) ?? fallbackLimit ?? [:]
        let primaryCard = limitCards.first
        let primary = parseWindow(codex["primary"] as? [String: Any], label: "5h") ?? primaryCard?.fiveHour
        let secondary = parseWindow(codex["secondary"] as? [String: Any], label: "7d") ?? primaryCard?.sevenDay
        let planType = (codex["planType"] as? String) ?? primaryCard?.planType
        let limitName = (codex["limitName"] as? String) ?? primaryCard?.limitName
        let accountName = readLocalAccountName(dataSource: dataSource)

        var snapshot = AccountQuotaSnapshot(
            fiveHour: primary,
            sevenDay: secondary,
            planType: planType,
            limitName: limitName,
            accountName: accountName,
            limitCards: limitCards,
            status: "额度已更新",
            updatedAt: Date()
        )
        if primary == nil && secondary == nil {
            snapshot.status = "额度暂无数据"
        }
        return snapshot
    }

    private static func parseLimitCards(byLimit: [String: Any]?, fallbackLimit: [String: Any]?) -> [AccountQuotaLimitCard] {
        var cards: [AccountQuotaLimitCard] = []
        if let byLimit {
            for (id, value) in byLimit {
                guard let raw = value as? [String: Any],
                      let card = parseLimitCard(raw, fallbackID: id)
                else {
                    continue
                }
                cards.append(card)
            }
        } else if let fallbackLimit,
                  let card = parseLimitCard(fallbackLimit, fallbackID: "codex") {
            cards.append(card)
        }

        return cards
            .filter(\.hasQuotaWindows)
            .sorted { lhs, rhs in
                if lhs.id == "codex" { return true }
                if rhs.id == "codex" { return false }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    private static func parseLimitCard(_ raw: [String: Any], fallbackID: String) -> AccountQuotaLimitCard? {
        let id = (raw["limitId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let limitID = id?.isEmpty == false ? id! : fallbackID
        let fiveHour = parseWindow(raw["primary"] as? [String: Any], label: "5h")
        let sevenDay = parseWindow(raw["secondary"] as? [String: Any], label: "7d")
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return AccountQuotaLimitCard(
            id: limitID,
            limitName: raw["limitName"] as? String,
            planType: raw["planType"] as? String,
            fiveHour: fiveHour,
            sevenDay: sevenDay
        )
    }

    private struct ResetCreditsSnapshot: Sendable {
        let availableCount: Int
        let credits: [AccountQuotaResetCredit]
    }

    private static func readResetCredits(dataSource: CodexDataSource?) async -> Result<ResetCreditsSnapshot, AccountQuotaDiagnostic> {
        let trace = RefreshPerformanceProbe.begin("accountQuotaReader.readResetCredits")
        trace?.mark("readAccessToken.begin")
        guard let accessToken = readAccessToken(dataSource: dataSource) else {
            let underlying = AccountQuotaDiagnostic(
                source: .resetCredit,
                category: .authMissing,
                severity: .warning,
                message: "未找到登录 token",
                rawCause: "auth.json missing or access_token empty",
                retryable: false,
                occurredAt: Date()
            )
            trace?.end("missing-access-token")
            return .failure(.resetCreditFailure(underlying: underlying))
        }
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits") else {
            let underlying = AccountQuotaDiagnostic(
                source: .resetCredit,
                category: .parseFailure,
                severity: .error,
                message: "重置卡请求地址异常",
                rawCause: "Invalid reset-credit URL",
                retryable: false,
                occurredAt: Date()
            )
            trace?.end("invalid-url")
            return .failure(.resetCreditFailure(underlying: underlying))
        }
        trace?.mark("readAccessToken.end")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 14
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexTokenBar", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        do {
            trace?.mark("http.begin")
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            trace?.mark("http.end", metadata: [
                "status": String(statusCode),
                "bytes": String(data.count)
            ])
            guard let http = response as? HTTPURLResponse else {
                trace?.end("invalid-response", metadata: ["status": String(statusCode)])
                let underlying = AccountQuotaDiagnostic(
                    source: .resetCredit,
                    category: .parseFailure,
                    severity: .error,
                    message: "重置卡响应格式异常",
                    rawCause: "Missing HTTP response",
                    retryable: false,
                    occurredAt: Date()
                )
                return .failure(.resetCreditFailure(underlying: underlying))
            }
            guard (200..<300).contains(http.statusCode) else {
                trace?.end("http-error", metadata: ["status": String(http.statusCode)])
                let category = AccountQuotaDiagnostic.category(forHTTPStatus: http.statusCode)
                let underlying = AccountQuotaDiagnostic(
                    source: .resetCredit,
                    category: category,
                    severity: .error,
                    message: "重置卡请求失败",
                    rawCause: "HTTP \(http.statusCode)",
                    httpStatus: http.statusCode,
                    retryable: category != .httpAuth,
                    occurredAt: Date()
                )
                return .failure(.resetCreditFailure(underlying: underlying))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                trace?.end("parse-failed", metadata: ["status": String(http.statusCode)])
                let underlying = AccountQuotaDiagnostic(
                    source: .resetCredit,
                    category: .parseFailure,
                    severity: .error,
                    message: "重置卡响应格式异常",
                    rawCause: String(data: data.prefix(512), encoding: .utf8) ?? "Invalid JSON",
                    httpStatus: http.statusCode,
                    retryable: false,
                    occurredAt: Date()
                )
                return .failure(.resetCreditFailure(underlying: underlying))
            }

            trace?.mark("parseResetCredits.begin")
            let credits = parseResetCredits(object["credits"])
            let availableCount = (object["available_count"] as? NSNumber)?.intValue
                ?? (object["available_count"] as? Int)
                ?? credits.filter(\.isAvailable).count
            let snapshot = ResetCreditsSnapshot(
                availableCount: max(0, availableCount),
                credits: credits
            )
            trace?.end("ok", metadata: [
                "available": String(snapshot.availableCount),
                "credits": String(snapshot.credits.count)
            ])
            return .success(snapshot)
        } catch {
            trace?.end("failed", metadata: ["error": error.localizedDescription])
            let underlying = AccountQuotaDiagnostic.classify(
                source: .resetCredit,
                error: error,
                occurredAt: Date()
            )
            return .failure(.resetCreditFailure(underlying: underlying))
        }
    }

    private static func parseResetCredits(_ value: Any?) -> [AccountQuotaResetCredit] {
        let rawCredits = (value as? [[String: Any]])
            ?? (value as? [Any])?.compactMap { $0 as? [String: Any] }
            ?? []

        return rawCredits
            .compactMap(parseResetCredit)
            .sorted { lhs, rhs in
                if lhs.isAvailable != rhs.isAvailable {
                    return lhs.isAvailable && !rhs.isAvailable
                }
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (lhsDate?, rhsDate?):
                    return lhsDate < rhsDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
                }
            }
    }

    private static func parseResetCredit(_ raw: [String: Any]) -> AccountQuotaResetCredit? {
        let id = (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id, !id.isEmpty else { return nil }
        return AccountQuotaResetCredit(
            id: id,
            status: (raw["status"] as? String) ?? "",
            resetType: raw["reset_type"] as? String,
            grantedAt: parseISODate(raw["granted_at"] as? String),
            expiresAt: parseISODate(raw["expires_at"] as? String),
            redeemStartedAt: parseISODate(raw["redeem_started_at"] as? String),
            redeemedAt: parseISODate(raw["redeemed_at"] as? String),
            title: raw["title"] as? String,
            descriptionText: raw["description"] as? String,
            profileUserID: raw["profile_user_id"] as? String,
            profileImageURL: raw["profile_image_url"] as? String
        )
    }

    private static func parseISODate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        return plainFormatter.date(from: value)
    }

    private static func readLocalAccountName(dataSource: CodexDataSource?) -> String? {
        let url = authFileURL(dataSource: dataSource)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let payload = decodeJWTPayload(idToken) else {
            return nil
        }

        for key in ["name", "nickname", "preferred_username", "email"] {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func readAccessToken(dataSource: CodexDataSource?) -> String? {
        let url = authFileURL(dataSource: dataSource)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String else {
            return nil
        }
        let trimmed = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func authFileURL(dataSource: CodexDataSource?) -> URL {
        let codexHome = dataSource?.codexHome
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
        return codexHome.appendingPathComponent("auth.json")
    }

    private static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload
    }

    private static func parseWindow(_ raw: [String: Any]?, label: String) -> AccountQuotaWindow? {
        guard let raw, let usedPercent = raw["usedPercent"] as? NSNumber else { return nil }
        let resetsAtSeconds = raw["resetsAt"] as? NSNumber
        return AccountQuotaWindow(
            label: label,
            usedPercent: usedPercent.intValue,
            resetsAt: resetsAtSeconds.map { Date(timeIntervalSince1970: $0.doubleValue) }
        )
    }
}

private final class AccountQuotaLineReader: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    private var lines: [Data] = []
    private var reachedEOF = false

    init(handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                self?.finish()
            } else {
                self?.append(data)
            }
        }
    }

    func next(timeout: TimeInterval) -> AccountQuotaStdoutEvent {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while lines.isEmpty && !reachedEOF {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .idle }
            condition.wait(until: Date().addingTimeInterval(remaining))
        }

        if !lines.isEmpty {
            return .line(lines.removeFirst())
        }
        return .endOfFile
    }

    private func append(_ data: Data) {
        guard !data.isEmpty else { return }
        condition.lock()
        defer {
            condition.signal()
            condition.unlock()
        }

        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            lines.append(Data(line))
            buffer.removeSubrange(...newline)
        }
    }

    private func finish() {
        condition.withLock {
            guard !reachedEOF else { return }
            if !buffer.isEmpty {
                lines.append(buffer)
                buffer.removeAll(keepingCapacity: false)
            }
            reachedEOF = true
            condition.broadcast()
        }
    }
}
