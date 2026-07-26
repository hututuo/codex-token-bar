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
    let localAccountNameLookup: @Sendable (CodexDataSource?) -> String?
    let historyIdentityLookup: @Sendable (CodexDataSource?, String?, String?) -> QuotaHistoryIdentity?

    init(
        transport: any AccountQuotaProcessTransport,
        locateCodexBinary: @escaping @Sendable () throws -> String,
        timeout: TimeInterval,
        retryDelayNanoseconds: UInt64,
        maxAttempts: Int,
        shouldReadResetCredits: Bool,
        localAccountNameLookup: @escaping @Sendable (CodexDataSource?) -> String?,
        historyIdentityLookup: @escaping @Sendable (
            CodexDataSource?,
            String?,
            String?
        ) -> QuotaHistoryIdentity? = { _, _, _ in nil }
    ) {
        self.transport = transport
        self.locateCodexBinary = locateCodexBinary
        self.timeout = timeout
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.maxAttempts = maxAttempts
        self.shouldReadResetCredits = shouldReadResetCredits
        self.localAccountNameLookup = localAccountNameLookup
        self.historyIdentityLookup = historyIdentityLookup
    }

    static let live = AccountQuotaReaderDependencies(
        transport: FoundationAccountQuotaProcessTransport(),
        locateCodexBinary: { try CodexBinaryLocator.findExecutable() },
        timeout: 12,
        retryDelayNanoseconds: 350_000_000,
        maxAttempts: 3,
        shouldReadResetCredits: true,
        localAccountNameLookup: { AccountQuotaReader.readLocalAccountName(dataSource: $0) },
        historyIdentityLookup: { dataSource, planType, limitID in
            AccountQuotaReader.readHistoryIdentity(
                dataSource: dataSource,
                planType: planType,
                limitID: limitID
            )
        }
    )

    static func testing(
        transport: any AccountQuotaProcessTransport,
        timeout: TimeInterval,
        maxAttempts: Int = 1,
        historyIdentityLookup: @escaping @Sendable (
            CodexDataSource?,
            String?,
            String?
        ) -> QuotaHistoryIdentity? = { _, _, _ in nil }
    ) -> AccountQuotaReaderDependencies {
        AccountQuotaReaderDependencies(
            transport: transport,
            locateCodexBinary: { "/fake/codex" },
            timeout: timeout,
            retryDelayNanoseconds: 0,
            maxAttempts: maxAttempts,
            shouldReadResetCredits: false,
            localAccountNameLookup: { _ in nil },
            historyIdentityLookup: historyIdentityLookup
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

protocol AccountQuotaProcessOwnershipFailure: Error {}

enum AccountQuotaProcessShutdownError: LocalizedError, Equatable, Sendable, AccountQuotaProcessOwnershipFailure {
    case forceKillFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .forceKillFailed(let value):
            return "Unable to stop Codex app-server after graceful shutdown (errno \(value))."
        }
    }
}

struct AccountQuotaProcessOwnershipError: LocalizedError, AccountQuotaProcessOwnershipFailure, @unchecked Sendable {
    let underlyingError: Error

    var errorDescription: String? {
        "Codex app-server process ownership was not settled: \(underlyingError.localizedDescription)"
    }
}

enum AccountQuotaProcessLaunchLeaseError: LocalizedError, Equatable, Sendable, AccountQuotaProcessOwnershipFailure {
    case inFlight

    var errorDescription: String? {
        "A Codex quota app-server process is already owned by another refresh."
    }
}

final class AccountQuotaProcessLaunchLeasePool: @unchecked Sendable {
    static let shared = AccountQuotaProcessLaunchLeasePool()

    private let lock = NSLock()
    private var ownerID: UUID?

    var isHeld: Bool { lock.withLock { ownerID != nil } }

    func acquire() throws -> AccountQuotaProcessLaunchLease {
        try lock.withLock {
            guard ownerID == nil else {
                throw AccountQuotaProcessLaunchLeaseError.inFlight
            }
            let id = UUID()
            ownerID = id
            return AccountQuotaProcessLaunchLease(pool: self, ownerID: id)
        }
    }

    fileprivate func release(ownerID: UUID) {
        lock.withLock {
            guard self.ownerID == ownerID else { return }
            self.ownerID = nil
        }
    }
}

final class AccountQuotaProcessLaunchLease: @unchecked Sendable {
    private let lock = NSLock()
    private let pool: AccountQuotaProcessLaunchLeasePool
    private let ownerID: UUID
    private var released = false

    fileprivate init(pool: AccountQuotaProcessLaunchLeasePool, ownerID: UUID) {
        self.pool = pool
        self.ownerID = ownerID
    }

    // Release stays explicit so a dropped owner cannot reopen the lane while its child may still live.
    func release() {
        let shouldRelease = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        if shouldRelease {
            pool.release(ownerID: ownerID)
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

enum AccountQuotaStdinWriteError: LocalizedError, Equatable, Sendable {
    case setupFailed(errno: Int32)
    case timedOut
    case writeFailed(errno: Int32)
    case closed

    var errorDescription: String? {
        switch self {
        case .setupFailed(let value):
            return "Unable to configure nonblocking Codex app-server stdin (errno \(value))."
        case .timedOut:
            return "Timed out writing to Codex app-server stdin."
        case .writeFailed(let value):
            return "Unable to write Codex app-server stdin (errno \(value))."
        case .closed:
            return "Codex app-server stdin is already closed."
        }
    }
}

protocol AccountQuotaStdinWriting: AnyObject, Sendable {
    func write(
        _ data: Data,
        cancellationRequested: @escaping @Sendable () -> Bool
    ) throws
    func close()
}

private final class AccountQuotaPOSIXStdinWriter: AccountQuotaStdinWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let fileDescriptor: Int32
    private let writeTimeout: TimeInterval
    private let pollIntervalMilliseconds: Int32
    private var closed = false

    init(
        handle: FileHandle,
        writeTimeout: TimeInterval,
        pollIntervalMilliseconds: Int32
    ) throws {
        self.handle = handle
        fileDescriptor = handle.fileDescriptor
        self.writeTimeout = max(0, writeTimeout)
        self.pollIntervalMilliseconds = max(1, pollIntervalMilliseconds)

        errno = 0
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags != -1 else {
            throw AccountQuotaStdinWriteError.setupFailed(errno: errno)
        }
        errno = 0
        guard fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw AccountQuotaStdinWriteError.setupFailed(errno: errno)
        }
        errno = 0
        guard fcntl(fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw AccountQuotaStdinWriteError.setupFailed(errno: errno)
        }
    }

    deinit {
        close()
    }

    func write(
        _ data: Data,
        cancellationRequested: @escaping @Sendable () -> Bool
    ) throws {
        guard !data.isEmpty else { return }
        guard lock.withLock({ !closed }) else {
            throw AccountQuotaStdinWriteError.closed
        }
        let deadline = Date().addingTimeInterval(writeTimeout)

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                if cancellationRequested() {
                    throw CancellationError()
                }
                guard Date() < deadline else {
                    throw AccountQuotaStdinWriteError.timedOut
                }

                errno = 0
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 {
                    throw AccountQuotaStdinWriteError.writeFailed(errno: EIO)
                }

                let writeErrno = errno
                if writeErrno == EINTR {
                    continue
                }
                guard writeErrno == EAGAIN || writeErrno == EWOULDBLOCK else {
                    throw AccountQuotaStdinWriteError.writeFailed(errno: writeErrno)
                }
                try waitUntilWritable(
                    deadline: deadline,
                    cancellationRequested: cancellationRequested
                )
            }
        }
    }

    func close() {
        let shouldClose = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        if shouldClose {
            try? handle.close()
        }
    }

    private func waitUntilWritable(
        deadline: Date,
        cancellationRequested: @escaping @Sendable () -> Bool
    ) throws {
        while true {
            if cancellationRequested() {
                throw CancellationError()
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw AccountQuotaStdinWriteError.timedOut
            }
            let remainingMilliseconds = Int32(min(
                Double(Int32.max),
                ceil(remaining * 1_000)
            ))
            let timeout = max(1, min(pollIntervalMilliseconds, remainingMilliseconds))
            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLOUT | POLLERR | POLLHUP),
                revents: 0
            )

            errno = 0
            let result = Darwin.poll(&descriptor, 1, timeout)
            if result > 0 {
                return
            }
            if result == 0 || errno == EINTR {
                continue
            }
            throw AccountQuotaStdinWriteError.writeFailed(errno: errno)
        }
    }
}

final class AccountQuotaProcessLifecycle: @unchecked Sendable {
    private enum State {
        case running
        case terminating
        case closing
        case closed
    }

    private let condition = NSCondition()
    private let writer: any AccountQuotaStdinWriting
    private let requestGracefulTerminationAction: () -> Void
    private var state = State.running
    private var writeInProgress = false

    init(
        writer: any AccountQuotaStdinWriting,
        requestGracefulTermination: @escaping () -> Void
    ) {
        self.writer = writer
        requestGracefulTerminationAction = requestGracefulTermination
    }

    var isTerminationRequested: Bool {
        condition.withLock { state != .running }
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
            try writer.write(data) { [weak self] in
                self?.isTerminationRequested ?? true
            }
            finishWrite()
        } catch {
            finishWrite()
            throw error
        }
    }

    func requestTermination() {
        let shouldRequestTermination = condition.withLock {
            guard state == .running else { return false }
            state = .terminating
            condition.broadcast()
            return true
        }
        if shouldRequestTermination {
            requestGracefulTerminationAction()
        }
        closeInputAfterWriteOwnershipReturns()
    }

    private func finishWrite() {
        condition.withLock {
            writeInProgress = false
            condition.broadcast()
        }
    }

    private func closeInputAfterWriteOwnershipReturns() {
        var shouldClose = false
        condition.lock()
        while writeInProgress {
            condition.wait()
        }
        switch state {
        case .terminating:
            state = .closing
            shouldClose = true
        case .closing:
            while state == .closing {
                condition.wait()
            }
        case .running, .closed:
            break
        }
        condition.unlock()

        if shouldClose {
            writer.close()
            condition.withLock {
                state = .closed
                condition.broadcast()
            }
        }
    }
}

struct FoundationAccountQuotaProcessTransport: AccountQuotaProcessTransport, Sendable {
    private let stderrTailLimit: Int
    private let gracefulShutdownTimeout: TimeInterval
    private let forcedShutdownTimeout: TimeInterval
    private let launchLeasePool: AccountQuotaProcessLaunchLeasePool
    private let stdinWriteTimeout: TimeInterval
    private let stdinPollIntervalMilliseconds: Int32

    init(
        stderrTailLimit: Int = 16_384,
        gracefulShutdownTimeout: TimeInterval = 0.25,
        forcedShutdownTimeout: TimeInterval = 1,
        launchLeasePool: AccountQuotaProcessLaunchLeasePool = .shared,
        stdinWriteTimeout: TimeInterval = 1,
        stdinPollIntervalMilliseconds: Int32 = 10
    ) {
        self.stderrTailLimit = max(0, stderrTailLimit)
        self.gracefulShutdownTimeout = max(0, gracefulShutdownTimeout)
        self.forcedShutdownTimeout = max(0, forcedShutdownTimeout)
        self.launchLeasePool = launchLeasePool
        self.stdinWriteTimeout = max(0, stdinWriteTimeout)
        self.stdinPollIntervalMilliseconds = max(1, stdinPollIntervalMilliseconds)
    }

    func start(codexPath: String, dataSource: CodexDataSource?) throws -> any AccountQuotaProcessSession {
        let launchLease = try launchLeasePool.acquire()
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

        let stdinWriter: AccountQuotaPOSIXStdinWriter
        do {
            stdinWriter = try AccountQuotaPOSIXStdinWriter(
                handle: input.fileHandleForWriting,
                writeTimeout: stdinWriteTimeout,
                pollIntervalMilliseconds: stdinPollIntervalMilliseconds
            )
        } catch {
            launchLease.release()
            throw error
        }

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
            stdinWriter.close()
            launchLease.release()
            throw error
        }

        return FoundationAccountQuotaProcessSession(
            process: process,
            stdinWriter: stdinWriter,
            output: output.fileHandleForReading,
            error: errorPipe.fileHandleForReading,
            stdoutReader: stdoutReader,
            stderrTail: stderrTail,
            exitObserver: exitObserver,
            gracefulShutdownTimeout: gracefulShutdownTimeout,
            forcedShutdownTimeout: forcedShutdownTimeout,
            launchLease: launchLease
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

private final class AccountQuotaDurableProcessReaper: @unchecked Sendable {
    private struct Adoption {
        let process: Process
        let owner: AnyObject
        let launchLease: AccountQuotaProcessLaunchLease
    }

    static let shared = AccountQuotaDurableProcessReaper()

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "CodexTokenBar.AccountQuotaDurableProcessReaper",
        attributes: .concurrent
    )
    private var adoptions: [UUID: Adoption] = [:]

    func adopt(
        process: Process,
        owner: AnyObject,
        exitObserver: AccountQuotaProcessExitObserver,
        launchLease: AccountQuotaProcessLaunchLease
    ) {
        let id = UUID()
        lock.withLock {
            adoptions[id] = Adoption(
                process: process,
                owner: owner,
                launchLease: launchLease
            )
        }
        queue.async { [self] in
            process.waitUntilExit()
            exitObserver.record(process: process)
            launchLease.release()
            _ = lock.withLock {
                adoptions.removeValue(forKey: id)
            }
        }
    }
}

enum AccountQuotaProcessCleanupDiagnostics {
    struct Entry: Sendable {
        let message: String
        let cancellationWasRequested: Bool
        let occurredAt: Date
    }

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var entries: [Entry] = []
    }

    private static let storage = Storage()

    static var recentEntries: [Entry] {
        storage.lock.withLock { storage.entries }
    }

    static func record(_ error: Error, cancellationWasRequested: Bool) {
        let entry = Entry(
            message: error.localizedDescription,
            cancellationWasRequested: cancellationWasRequested,
            occurredAt: Date()
        )
        storage.lock.withLock {
            storage.entries.append(entry)
            if storage.entries.count > 8 {
                storage.entries.removeFirst(storage.entries.count - 8)
            }
        }
        RefreshPerformanceProbe.event("accountQuotaReader.cleanupFailed", metadata: [
            "cancelled": cancellationWasRequested ? "1" : "0",
            "error": entry.message
        ])
    }
}

struct AccountQuotaAppServerClient: Sendable {
    private enum ReadOutcome {
        case result(Result<AccountQuotaSnapshot, Error>)
        case earlyExit(awaiting: String)
    }

    private let transport: any AccountQuotaProcessTransport
    private let timeout: TimeInterval
    private let localAccountNameLookup: @Sendable (CodexDataSource?) -> String?

    init(
        transport: any AccountQuotaProcessTransport,
        timeout: TimeInterval,
        localAccountNameLookup: @escaping @Sendable (CodexDataSource?) -> String?
    ) {
        self.transport = transport
        self.timeout = timeout
        self.localAccountNameLookup = localAccountNameLookup
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
                let ownershipError = AccountQuotaProcessOwnershipError(underlyingError: error)
                let cancelled = Task.isCancelled
                AccountQuotaProcessCleanupDiagnostics.record(
                    ownershipError,
                    cancellationWasRequested: cancelled
                )
                return cancelled ? .failure(CancellationError()) : .failure(ownershipError)
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
                        return .result(.success(AccountQuotaReader.parse(
                            result,
                            accountName: localAccountNameLookup(dataSource)
                        )))
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
            if message["error"] != nil {
                state = .complete
                guard let error = message["error"] as? [String: Any],
                      let message = error["message"] as? String else {
                    return .fail(.invalidResponse)
                }
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
    private let launchLease: AccountQuotaProcessLaunchLease

    init(
        process: Process,
        stdinWriter: any AccountQuotaStdinWriting,
        output: FileHandle,
        error: FileHandle,
        stdoutReader: AccountQuotaLineReader,
        stderrTail: AccountQuotaStderrTail,
        exitObserver: AccountQuotaProcessExitObserver,
        gracefulShutdownTimeout: TimeInterval,
        forcedShutdownTimeout: TimeInterval,
        launchLease: AccountQuotaProcessLaunchLease
    ) {
        self.process = process
        self.output = output
        self.error = error
        self.stdoutReader = stdoutReader
        self.stderrTail = stderrTail
        self.exitObserver = exitObserver
        self.gracefulShutdownTimeout = gracefulShutdownTimeout
        self.forcedShutdownTimeout = forcedShutdownTimeout
        self.launchLease = launchLease
        lifecycle = AccountQuotaProcessLifecycle(
            writer: stdinWriter,
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
        return stdoutReader.next(timeout: timeout)
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
            return finishShutdown(exit)
        }

        if process.isRunning {
            errno = 0
            let result = kill(process.processIdentifier, SIGKILL)
            if result != 0 && errno != ESRCH {
                AccountQuotaDurableProcessReaper.shared.adopt(
                    process: process,
                    owner: self,
                    exitObserver: exitObserver,
                    launchLease: launchLease
                )
                throw AccountQuotaProcessShutdownError.forceKillFailed(errno: errno)
            }
        }
        if let exit = exitObserver.wait(timeout: forcedShutdownTimeout) {
            return finishShutdown(exit)
        }

        // SIGKILL has already been issued; synchronously reap so a retry can never overlap this child.
        process.waitUntilExit()
        let reason: AccountQuotaProcessExit.Reason = process.terminationReason == .exit
            ? .exit
            : .uncaughtSignal
        let exit = AccountQuotaProcessExit(status: process.terminationStatus, reason: reason)
        exitObserver.record(exit)
        return finishShutdown(exit)
    }

    private func finishShutdown(_ exit: AccountQuotaProcessExit) -> AccountQuotaProcessExit {
        launchLease.release()
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
                    timeout: dependencies.timeout,
                    localAccountNameLookup: dependencies.localAccountNameLookup
                )
                result = await client.read(codexPath: codexPath, dataSource: dataSource)
            } catch {
                result = .failure(error)
            }
            switch result {
            case .success(var snapshot):
                trace?.mark("attempt.success", metadata: [
                    "attempt": String(attempt),
                    "available": snapshot.isAvailable ? "1" : "0"
                ])
                if snapshot.isAvailable || attempt == maxAttempts {
                    snapshot.historyIdentity = dependencies.historyIdentityLookup(
                        dataSource,
                        snapshot.planType,
                        snapshot.selectedLimitID
                    )
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
                if error is AccountQuotaProcessOwnershipFailure {
                    trace?.end("ownership-failed", metadata: ["attempt": String(attempt)])
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

    static func parse(_ result: [String: Any], accountName: String?) -> AccountQuotaSnapshot {
        let byLimit = result["rateLimitsByLimitId"] as? [String: Any]
        let fallbackLimit = result["rateLimits"] as? [String: Any]
        let limitCards = parseLimitCards(byLimit: byLimit, fallbackLimit: fallbackLimit)
        let primaryCard = selectedLimitCard(from: limitCards)
        let primary = primaryCard?.fiveHour
        let secondary = primaryCard?.sevenDay
        let planType = parsePlanType(result: result, selectedCard: primaryCard)
        let limitName = primaryCard?.limitName
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
        snapshot.selectedLimitID = primaryCard?.id
        if primary == nil && secondary == nil {
            snapshot.status = "额度暂无数据"
        }
        return snapshot
    }

    private static func selectedLimitCard(from cards: [AccountQuotaLimitCard]) -> AccountQuotaLimitCard? {
        cards.first { $0.id.caseInsensitiveCompare("codex") == .orderedSame }
            ?? cards.min { $0.id < $1.id }
    }

    private static func parsePlanType(
        result: [String: Any],
        selectedCard: AccountQuotaLimitCard?
    ) -> String? {
        let keys = [
            "planLabel", "plan_label", "planName", "plan_name", "tier",
            "planType", "plan_type", "accountPlan", "account_plan",
            "subscriptionPlan", "subscription_plan"
        ]
        for key in keys {
            if let plan = canonicalPlanLabel(result[key] as? String) {
                return plan
            }
        }
        return canonicalPlanLabel(selectedCard?.planType)
    }

    private static func canonicalPlanLabel(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "plus", "chatgptplus":
            return "Plus"
        case "pro", "chatgptpro":
            return "Pro"
        case "team", "teams", "business":
            return "Team"
        case "enterprise":
            return "Enterprise"
        case "free":
            return "Free"
        case "unknown", "none", "null":
            return nil
        default:
            return trimmed
        }
    }

    private static func parseLimitCards(byLimit: [String: Any]?, fallbackLimit: [String: Any]?) -> [AccountQuotaLimitCard] {
        var cards: [AccountQuotaLimitCard] = []
        if let byLimit {
            for (id, value) in byLimit {
                guard let limitID = normalizedSelectedLimitID(id),
                      let raw = value as? [String: Any],
                      let card = parseLimitCard(raw, limitID: limitID)
                else {
                    continue
                }
                cards.append(card)
            }
        }
        if cards.isEmpty,
           let fallbackLimit,
           let limitID = fallbackSelectedLimitID(fallbackLimit),
           let card = parseLimitCard(fallbackLimit, limitID: limitID) {
            cards.append(card)
        }

        return cards
            .filter(\.hasQuotaWindows)
            .sorted { lhs, rhs in
                let lhsIsCodex = lhs.id.caseInsensitiveCompare("codex") == .orderedSame
                let rhsIsCodex = rhs.id.caseInsensitiveCompare("codex") == .orderedSame
                if lhsIsCodex != rhsIsCodex { return lhsIsCodex }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    private static func parseLimitCard(_ raw: [String: Any], limitID: String) -> AccountQuotaLimitCard? {
        var fiveHour: AccountQuotaWindow?
        var sevenDay: AccountQuotaWindow?
        for window in [
            parseWindow(raw["primary"] as? [String: Any], fallbackLabel: "5h"),
            parseWindow(raw["secondary"] as? [String: Any], fallbackLabel: "7d")
        ].compactMap({ $0 }) {
            if window.label == "7d" {
                if sevenDay == nil { sevenDay = window }
            } else if fiveHour == nil {
                fiveHour = window
            }
        }
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return AccountQuotaLimitCard(
            id: limitID,
            limitName: raw["limitName"] as? String,
            planType: raw["planType"] as? String,
            fiveHour: fiveHour,
            sevenDay: sevenDay
        )
    }

    private static func fallbackSelectedLimitID(_ raw: [String: Any]) -> String? {
        guard raw.keys.contains("limitId") else { return "codex" }
        return normalizedSelectedLimitID(raw["limitId"] as? String)
    }

    private static func normalizedSelectedLimitID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed.caseInsensitiveCompare("codex") == .orderedSame ? "codex" : trimmed
    }

    private struct ResetCreditsSnapshot: Sendable {
        let availableCount: Int
        let credits: [AccountQuotaResetCredit]
    }

    static func makeResetCreditSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        // 同 CodexRadarNetworkSession：请求上的 14 秒 timeoutInterval 只挡空闲；
        // 不设资源总时限时默认 7 天，滴灌响应会把重置卡刷新长期挂死。
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
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

        let session = Self.makeResetCreditSession()
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

    fileprivate static func readLocalAccountName(dataSource: CodexDataSource?) -> String? {
        guard let payload = readLocalIDTokenPayload(dataSource: dataSource) else { return nil }
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

    static func readHistoryIdentity(
        dataSource: CodexDataSource?,
        planType: String?,
        limitID: String?
    ) -> QuotaHistoryIdentity? {
        let codexHome = (dataSource?.codexHome
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex"))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return QuotaHistoryIdentity(
            homeIdentity: codexHome.path,
            stableAccountKey: readLocalStableAccountKey(dataSource: dataSource),
            planType: planType,
            limitID: limitID
        )
    }

    private static func readLocalStableAccountKey(dataSource: CodexDataSource?) -> String? {
        guard let payload = readLocalIDTokenPayload(dataSource: dataSource) else { return nil }
        for (key, prefix) in [("sub", "sub:"), ("account_id", "account:"), ("accountId", "account:")] {
            let trimmed = (payload[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return prefix + trimmed
            }
        }
        return nil
    }

    private static func readLocalIDTokenPayload(dataSource: CodexDataSource?) -> [String: Any]? {
        let url = authFileURL(dataSource: dataSource)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else {
            return nil
        }
        return decodeJWTPayload(idToken)
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

    private static func parseWindow(_ raw: [String: Any]?, fallbackLabel: String) -> AccountQuotaWindow? {
        guard let raw, let usedPercent = raw["usedPercent"] as? NSNumber else { return nil }
        let resetsAtSeconds = raw["resetsAt"] as? NSNumber
        let resetsAt = resetsAtSeconds.map { Date(timeIntervalSince1970: $0.doubleValue) }
        // 与 Tauri 端 rate_limits.rs 的 uses_percent_scale/normalized_percent 同
        // 语义：带 windowDurationMins 字段或原始值 > 1 视为 0-100 百分比，否则
        // 视为 0-1 比例。此前恒按百分比取 intValue 会把比例制 0.25 读成 0%、
        // 1.0 读成 1%，与 Rust 端对同一 JSON 的结论相反并污染各自 history。
        let rawUsed = usedPercent.doubleValue
        let percentScale = raw["windowDurationMins"] != nil || rawUsed > 1.0
        let usedFraction = percentScale ? rawUsed / 100.0 : rawUsed
        let roundedPercent = min(100.0, max(0.0, (usedFraction * 100.0).rounded()))
        return AccountQuotaWindow(
            label: quotaWindowLabel(raw, fallback: fallbackLabel, resetsAt: resetsAt),
            usedPercent: Int(roundedPercent),
            resetsAt: resetsAt
        )
    }

    private static func quotaWindowLabel(_ raw: [String: Any], fallback: String, resetsAt: Date?) -> String {
        if let durationMinutes = (raw["windowDurationMins"] as? NSNumber)?.doubleValue {
            if durationMinutes >= 24 * 60 { return "7d" }
            if durationMinutes <= 6 * 60 { return "5h" }
            return fallback
        }

        if let resetsAt {
            let resetSpan = resetsAt.timeIntervalSince(Date())
            if resetSpan > 6 * 60 * 60 { return "7d" }
            if resetSpan >= 0 { return "5h" }
        }
        return fallback
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
