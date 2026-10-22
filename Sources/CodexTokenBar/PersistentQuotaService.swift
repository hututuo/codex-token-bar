import Foundation

/// One owned, serialized app-server connection. Quota and card refreshes share
/// the same short-lived snapshot; the Codex process survives between polls.
final class PersistentQuotaService: @unchecked Sendable {
    static let shared = PersistentQuotaService()

    private let lock = NSLock()
    private let sessionLock = NSLock()
    private let transport: any AccountQuotaProcessTransport
    private let locate: @Sendable () throws -> String
    private let clock: @Sendable () -> TimeInterval
    private let timeout: TimeInterval
    private let cacheDuration: TimeInterval
    private var session: (any AccountQuotaProcessSession)?
    private var scope: [String]?
    private var nextID = 1
    private var cached: Result<AccountQuotaSnapshot, Error>?
    private var cachedAt: TimeInterval = 0
    private var retryAt: TimeInterval = 0
    private var failures = 0
    private var stopped = false
    private var stopRequested = false // Protected by sessionLock, including during startup.

    init(
        transport: any AccountQuotaProcessTransport = FoundationAccountQuotaProcessTransport(launchLeasePool: AccountQuotaProcessLaunchLeasePool()),
        locate: @escaping @Sendable () throws -> String = { try CodexBinaryLocator.findExecutable() },
        timeout: TimeInterval = 12,
        cacheDuration: TimeInterval = 5,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.transport = transport
        self.locate = locate
        self.timeout = timeout
        self.cacheDuration = cacheDuration
        self.clock = clock
    }

    func read(dataSource: CodexDataSource?) -> Result<AccountQuotaSnapshot, Error> {
        lock.withLock {
            do {
                try Task.checkCancellation()
                guard !stopped, !sessionLock.withLock({ stopRequested }) else { throw CancellationError() }
                let binary = try locate()
                let currentScope = Self.scope(binary: binary, dataSource: dataSource)
                if scope != currentScope {
                    try closeSession()
                    scope = currentScope
                    cached = nil
                    failures = 0
                    retryAt = 0
                }
                if let cached, clock() - cachedAt < cacheDuration { return cached }
                guard clock() >= retryAt else {
                    return .failure(AccountQuotaReaderError.serverError("Codex 本地额度服务正在等待重连"))
                }
                if session == nil {
                    let opened = try transport.start(codexPath: binary, dataSource: dataSource)
                    sessionLock.withLock { session = opened }
                    nextID = 1
                    _ = try rpc("initialize", params: [
                        "clientInfo": ["name": "codex-token-bar", "version": "1"],
                        "capabilities": ["experimentalApi": false, "requestAttestation": false]
                    ])
                    try write(["method": "initialized"])
                }
                let result = try rpc("account/rateLimits/read")
                guard currentScope == Self.scope(binary: binary, dataSource: dataSource) else {
                    try closeSession()
                    cached = nil
                    throw DirectQuotaError.identityChanged
                }
                var snapshot = AccountQuotaReader.parse(result, accountName: AccountQuotaReader.readLocalAccountName(dataSource: dataSource))
                snapshot.historyIdentity = AccountQuotaReader.readHistoryIdentity(
                    dataSource: dataSource, planType: snapshot.planType, limitID: snapshot.selectedLimitID
                )
                cached = .success(snapshot)
                cachedAt = clock()
                failures = 0
                return .success(snapshot)
            } catch let error as RPCFailure {
                // A completed network/auth error does not break the local pipe.
                // Keep the initialized process for the next scheduled refresh.
                return .failure(AccountQuotaReaderError.serverError(error.message))
            } catch {
                cached = nil
                do { try closeSession() } catch {
                    return .failure(AccountQuotaProcessOwnershipError(underlyingError: error))
                }
                if !(error is CancellationError) {
                    failures = min(failures + 1, 6)
                    retryAt = clock() + min(30, pow(2, Double(failures - 1)))
                }
                return .failure(error)
            }
        }
    }

    func shutdown() {
        // Interrupt an in-flight read before waiting for the serialized owner.
        sessionLock.withLock {
            stopRequested = true
            session?.requestTermination()
        }
        lock.withLock {
            stopped = true
            cached = nil
            try? closeSession()
        }
    }

    private func closeSession() throws {
        guard let owned = sessionLock.withLock({ session }) else { return }
        owned.requestTermination()
        _ = try owned.shutdown()
        sessionLock.withLock { session = nil }
    }

    private func write(_ message: [String: Any]) throws {
        guard let session else { throw AccountQuotaReaderError.invalidResponse }
        var bytes = try JSONSerialization.data(withJSONObject: message)
        bytes.append(10)
        try session.writeStdin(bytes)
    }

    private struct RPCFailure: Error { let message: String }

    private func rpc(_ method: String, params: [String: Any]? = nil) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        var request: [String: Any] = ["id": id, "method": method]
        if let params { request["params"] = params }
        try write(request)
        let deadline = clock() + timeout
        while clock() < deadline {
            try Task.checkCancellation()
            guard !sessionLock.withLock({ stopRequested }) else { throw CancellationError() }
            guard let session else { throw AccountQuotaReaderError.invalidResponse }
            switch try session.nextStdoutEvent(timeout: min(0.05, max(0, deadline - clock()))) {
            case .idle: continue
            case .endOfFile: throw AccountQuotaReaderError.serverError("Codex app-server 管道已关闭")
            case .line(let line):
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      message["id"] as? Int == id else { continue }
                if let error = message["error"] as? [String: Any] {
                    // Initialization failure cannot leave a usable session.
                    if method == "initialize" { throw AccountQuotaReaderError.invalidResponse }
                    throw RPCFailure(message: error["message"] as? String ?? "Codex 请求失败")
                }
                guard let result = message["result"] as? [String: Any] else {
                    throw AccountQuotaReaderError.invalidResponse
                }
                return result
            }
        }
        throw AccountQuotaReaderError.timeout(stderrText: session?.stderrTailText())
    }

    private static func scope(binary: String, dataSource: CodexDataSource?) -> [String] {
        let home = (dataSource?.codexHome ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex"))
            .standardizedFileURL.resolvingSymlinksInPath()
        let account = (try? CurrentCodexCredentialReader.currentCredential(home: home).id)
            ?? stamp(home.appendingPathComponent("auth.json"))
        return [home.path, binary, stamp(URL(fileURLWithPath: binary)), account,
                stamp(home.appendingPathComponent("config.toml")), stamp(home.appendingPathComponent(".env"))]
    }

    private static func stamp(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(modified):\(attrs?[.size] as? NSNumber ?? 0)"
    }
}
