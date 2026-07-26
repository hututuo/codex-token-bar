import Foundation

protocol CodexAutoResumeAppServerServing: Sendable {
    func listThreads(
        codexPath: String,
        dataSource: CodexDataSource?
    ) async throws -> [AutoResumeThreadDescriptor]

    func readThreadFreshness(
        codexPath: String,
        dataSource: CodexDataSource?,
        threadID: String
    ) async throws -> AutoResumeThreadFreshness

    func readLatestTurnObservation(
        codexPath: String,
        dataSource: CodexDataSource?,
        threadID: String
    ) async throws -> AutoResumeLatestTurnObservation?

    func resumeThread(
        codexPath: String,
        dataSource: CodexDataSource?,
        target: AutoResumeThreadDescriptor,
        prompt: String,
        clientMessageID: String,
        expectedFreshness: AutoResumeThreadFreshness?,
        startAuthorization: AutoResumeStartAuthorization?
    ) async throws -> AutoResumeRunResult
}

extension CodexAutoResumeAppServerServing {
    func resumeThread(
        codexPath: String,
        dataSource: CodexDataSource?,
        target: AutoResumeThreadDescriptor,
        prompt: String,
        clientMessageID: String
    ) async throws -> AutoResumeRunResult {
        try await resumeThread(
            codexPath: codexPath,
            dataSource: dataSource,
            target: target,
            prompt: prompt,
            clientMessageID: clientMessageID,
            expectedFreshness: nil,
            startAuthorization: nil
        )
    }

    func resumeThread(
        codexPath: String,
        dataSource: CodexDataSource?,
        target: AutoResumeThreadDescriptor,
        prompt: String,
        clientMessageID: String,
        expectedFreshness: AutoResumeThreadFreshness?
    ) async throws -> AutoResumeRunResult {
        try await resumeThread(
            codexPath: codexPath,
            dataSource: dataSource,
            target: target,
            prompt: prompt,
            clientMessageID: clientMessageID,
            expectedFreshness: expectedFreshness,
            startAuthorization: nil
        )
    }
}

enum CodexAutoResumeAppServerError: LocalizedError, Equatable, Sendable {
    case invalidResponse(String)
    case serverError(String)
    case timeout(String)
    case processExited(String)
    case activeTurn(String)
    case threadProgressed
    case quotaLimited(String)
    case requiresHuman(String)
    case interrupted

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail):
            return "Codex App Server 返回无效：\(detail)"
        case .serverError(let message):
            return "Codex App Server 错误：\(message)"
        case .timeout(let stage):
            return "等待 Codex \(stage) 超时"
        case .processExited(let stage):
            return "Codex App Server 在等待\(stage)时退出"
        case .activeTurn(let turnID):
            return "目标任务仍在运行（turn \(turnID)）"
        case .threadProgressed:
            return "目标任务在等待期间已有新进展"
        case .quotaLimited(let message):
            return "Codex 额度暂不可用：\(message)"
        case .requiresHuman(let method):
            return "需要人工处理：\(method)"
        case .interrupted:
            return "自动续跑已停止"
        }
    }
}

struct CodexAppServerClient: CodexAutoResumeAppServerServing, Sendable {
    static let defaultTurnTimeout: TimeInterval = 6 * 60 * 60
    // 可见性重建的失控保护：seen-cursor 只能挡"重复"游标，服务端若返回
    // 无限多的唯一游标，分页永不终止。页数上限 + 总时限保证后台自行退出，
    // 不再依赖前端超时（那只是客户端放弃，后台会继续占用进程与锁）。
    static let defaultVisibilityRebuildMaxPages = 100_000
    static let defaultVisibilityRebuildTimeBudget: TimeInterval = 30 * 60

    private let transport: any AccountQuotaProcessTransport
    private let requestTimeout: TimeInterval
    private let turnTimeout: TimeInterval
    private let visibilityRebuildMaxPages: Int
    private let visibilityRebuildTimeBudget: TimeInterval

    init(
        transport: (any AccountQuotaProcessTransport)? = nil,
        requestTimeout: TimeInterval = 15,
        turnTimeout: TimeInterval = Self.defaultTurnTimeout,
        visibilityRebuildMaxPages: Int = Self.defaultVisibilityRebuildMaxPages,
        visibilityRebuildTimeBudget: TimeInterval =
            Self.defaultVisibilityRebuildTimeBudget
    ) {
        self.transport = transport ?? FoundationAccountQuotaProcessTransport(
            launchLeasePool: AccountQuotaProcessLaunchLeasePool()
        )
        self.requestTimeout = max(1, requestTimeout)
        self.turnTimeout = max(5, turnTimeout)
        self.visibilityRebuildMaxPages = max(1, visibilityRebuildMaxPages)
        self.visibilityRebuildTimeBudget = visibilityRebuildTimeBudget
    }

    func listThreads(
        codexPath: String,
        dataSource: CodexDataSource?
    ) async throws -> [AutoResumeThreadDescriptor] {
        try await withSession(codexPath: codexPath, dataSource: dataSource) { session in
            var channel = CodexAutoResumeRPCChannel(session: session)
            try channel.initialize(timeout: requestTimeout)

            var threads: [AutoResumeThreadDescriptor] = []
            var cursor: String?
            var pageCount = 0
            repeat {
                var params: [String: Any] = [
                    "archived": false,
                    "limit": 100,
                    "sortKey": "updated_at",
                    "sortDirection": "desc",
                    "sourceKinds": ["cli", "vscode", "exec", "appServer", "unknown"],
                ]
                if let cursor { params["cursor"] = cursor }
                let result = try channel.request(
                    method: "thread/list",
                    params: params,
                    timeout: requestTimeout
                )
                guard let data = result["data"] as? [[String: Any]] else {
                    throw CodexAutoResumeAppServerError.invalidResponse("thread/list 缺少 data")
                }
                threads.append(contentsOf: data.compactMap(Self.parseThread))
                cursor = Self.nonemptyString(result["nextCursor"])
                pageCount += 1
            } while cursor != nil && pageCount < 20

            return threads.sorted {
                ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
        }
    }

    func rebuildConversationVisibilityMetadata(
        codexPath: String,
        dataSource: CodexDataSource?,
        beforePage: () throws -> Void = {}
    ) throws -> ConversationVisibilityRebuildResult {
        let session = try transport.start(codexPath: codexPath, dataSource: dataSource)
        let startedAt = Date()
        let outcome: Result<ConversationVisibilityRebuildResult, Error>
        do {
            var channel = CodexAutoResumeRPCChannel(session: session)
            try channel.initialize(timeout: requestTimeout)
            var activeThreads = 0
            var archivedThreads = 0
            var pagesScanned = 0
            for archived in [false, true] {
                var cursor: String?
                var seenCursors = Set<String>()
                repeat {
                    try Task.checkCancellation()
                    guard pagesScanned < visibilityRebuildMaxPages else {
                        throw CodexAutoResumeAppServerError.invalidResponse(
                            "thread/list 分页超过 \(visibilityRebuildMaxPages) 页上限仍未终止，已停止官方会话索引重建"
                        )
                    }
                    guard Date().timeIntervalSince(startedAt)
                        < visibilityRebuildTimeBudget else {
                        throw CodexAutoResumeAppServerError.invalidResponse(
                            "官方会话索引重建超过 \(Int(visibilityRebuildTimeBudget)) 秒总时限，已停止"
                        )
                    }
                    try beforePage()
                    var params: [String: Any] = [
                        "archived": archived,
                        "limit": 100,
                        "useStateDbOnly": false,
                        "sortKey": "updated_at",
                        "sortDirection": "desc",
                        "sourceKinds": [
                            "cli",
                            "vscode",
                            "exec",
                            "appServer",
                            "subAgent",
                            "unknown",
                        ],
                    ]
                    if let cursor {
                        params["cursor"] = cursor
                    }
                    let result = try channel.request(
                        method: "thread/list",
                        params: params,
                        timeout: requestTimeout
                    )
                    guard let rows = result["data"] as? [[String: Any]] else {
                        throw CodexAutoResumeAppServerError.invalidResponse(
                            "thread/list 缺少 data"
                        )
                    }
                    if archived {
                        archivedThreads = try Self.checkedVisibilityCount(
                            archivedThreads,
                            adding: rows.count
                        )
                    } else {
                        activeThreads = try Self.checkedVisibilityCount(
                            activeThreads,
                            adding: rows.count
                        )
                    }
                    pagesScanned = try Self.checkedVisibilityCount(
                        pagesScanned,
                        adding: 1
                    )
                    let nextCursor = Self.nonemptyString(result["nextCursor"])
                    if let nextCursor {
                        guard nextCursor != cursor,
                              seenCursors.insert(nextCursor).inserted else {
                            throw CodexAutoResumeAppServerError.invalidResponse(
                                "thread/list 返回重复游标：\(nextCursor)"
                            )
                        }
                    }
                    cursor = nextCursor
                } while cursor != nil
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            outcome = .success(ConversationVisibilityRebuildResult(
                activeThreads: activeThreads,
                archivedThreads: archivedThreads,
                pagesScanned: pagesScanned,
                status: String(
                    format: "官方会话索引重建完成：活动 %d，归档 %d，共 %d 页，耗时 %.1f 秒。Token Bar 未改写 JSONL 或 session_index。",
                    activeThreads,
                    archivedThreads,
                    pagesScanned,
                    elapsed
                )
            ))
        } catch {
            outcome = .failure(error)
        }

        do {
            _ = try session.shutdown()
        } catch {
            throw AccountQuotaProcessOwnershipError(underlyingError: error)
        }
        return try outcome.get()
    }

    func readThreadFreshness(
        codexPath: String,
        dataSource: CodexDataSource?,
        threadID: String
    ) async throws -> AutoResumeThreadFreshness {
        try await withSession(codexPath: codexPath, dataSource: dataSource) { session in
            var channel = CodexAutoResumeRPCChannel(session: session)
            try channel.initialize(timeout: requestTimeout)
            let read = try channel.request(
                method: "thread/read",
                params: ["threadId": threadID, "includeTurns": true],
                timeout: requestTimeout
            )
            guard let thread = read["thread"] as? [String: Any],
                  Self.nonemptyString(thread["id"]) == threadID else {
                throw CodexAutoResumeAppServerError.invalidResponse("thread/read 未返回目标 thread")
            }
            return Self.threadFreshness(in: thread)
        }
    }

    func readLatestTurnObservation(
        codexPath: String,
        dataSource: CodexDataSource?,
        threadID: String
    ) async throws -> AutoResumeLatestTurnObservation? {
        try await withSession(codexPath: codexPath, dataSource: dataSource) { session in
            var channel = CodexAutoResumeRPCChannel(session: session)
            try channel.initialize(timeout: requestTimeout, experimentalAPI: true)
            let result = try channel.request(
                method: "thread/turns/list",
                params: [
                    "threadId": threadID,
                    "limit": 1,
                    "sortDirection": "desc",
                    "itemsView": "summary",
                ],
                timeout: requestTimeout
            )
            guard let turns = result["data"] as? [[String: Any]] else {
                throw CodexAutoResumeAppServerError.invalidResponse(
                    "thread/turns/list 缺少 data"
                )
            }
            guard let turn = turns.first else { return nil }
            var observation = try Self.parseLatestTurnObservation(turn)
            if observation.isServerCapacityFailure,
               observation.clientUserMessageID == nil {
                let fullResult = try channel.request(
                    method: "thread/turns/list",
                    params: [
                        "threadId": threadID,
                        "limit": 1,
                        "sortDirection": "desc",
                        "itemsView": "full",
                    ],
                    timeout: requestTimeout
                )
                if let fullTurn = (fullResult["data"] as? [[String: Any]])?.first,
                   Self.nonemptyString(fullTurn["id"]) == observation.turnID {
                    observation = try Self.parseLatestTurnObservation(fullTurn)
                }
            }
            return observation
        }
    }

    func resumeThread(
        codexPath: String,
        dataSource: CodexDataSource?,
        target: AutoResumeThreadDescriptor,
        prompt: String,
        clientMessageID: String,
        expectedFreshness: AutoResumeThreadFreshness?,
        startAuthorization: AutoResumeStartAuthorization?
    ) async throws -> AutoResumeRunResult {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw CodexAutoResumeAppServerError.invalidResponse("续跑提示词为空")
        }
        let clientMessageID = clientMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientMessageID.isEmpty else {
            throw CodexAutoResumeAppServerError.invalidResponse("续跑触发 ID 为空")
        }

        return try await withSession(codexPath: codexPath, dataSource: dataSource) { session in
            var channel = CodexAutoResumeRPCChannel(session: session)
            try channel.initialize(timeout: requestTimeout)
            if let expectedFreshness {
                let preflight = try channel.request(
                    method: "thread/read",
                    params: ["threadId": target.id, "includeTurns": true],
                    timeout: requestTimeout
                )
                guard let thread = preflight["thread"] as? [String: Any],
                      Self.nonemptyString(thread["id"]) == target.id else {
                    throw CodexAutoResumeAppServerError.invalidResponse(
                        "thread/read 未返回目标 thread"
                    )
                }
                if Self.threadFreshness(in: thread).hasProgressed(since: expectedFreshness) {
                    throw CodexAutoResumeAppServerError.threadProgressed
                }
            }
            let resumed = try channel.request(
                method: "thread/resume",
                params: ["threadId": target.id],
                timeout: requestTimeout
            )
            guard let resumedThread = resumed["thread"] as? [String: Any],
                  let resumedThreadID = Self.nonemptyString(resumedThread["id"]),
                  resumedThreadID == target.id else {
                throw CodexAutoResumeAppServerError.invalidResponse("thread/resume 未返回目标 thread")
            }
            channel.bind(threadID: resumedThreadID)

            let read = try channel.request(
                method: "thread/read",
                params: ["threadId": target.id, "includeTurns": true],
                timeout: requestTimeout
            )
            guard let thread = read["thread"] as? [String: Any] else {
                throw CodexAutoResumeAppServerError.invalidResponse("thread/read 缺少 thread")
            }
            if let expectedFreshness,
               Self.threadFreshness(in: thread).hasProgressed(since: expectedFreshness) {
                throw CodexAutoResumeAppServerError.threadProgressed
            }
            if let activeTurnID = Self.activeLastTurnID(in: thread) {
                throw CodexAutoResumeAppServerError.activeTurn(activeTurnID)
            }

            let started = try channel.request(
                method: "turn/start",
                params: [
                    "clientUserMessageId": clientMessageID,
                    "threadId": target.id,
                    "input": [["type": "text", "text": prompt]],
                ],
                timeout: requestTimeout,
                startAuthorization: startAuthorization
            )
            guard let turn = started["turn"] as? [String: Any],
                  let turnID = Self.nonemptyString(turn["id"]) else {
                throw CodexAutoResumeAppServerError.invalidResponse("turn/start 缺少 turn id")
            }
            channel.bind(turnID: turnID)
            let completed = try channel.waitForTurnCompletion(
                threadID: target.id,
                turnID: turnID,
                timeout: turnTimeout
            )
            let status = Self.nonemptyString(completed["status"]) ?? "completed"
            if Self.normalizedStatus(status) == "failed" {
                let error = completed["error"] as? [String: Any]
                let message = Self.nonemptyString(error?["message"]) ?? "Turn failed"
                let errorCode = Self.codexErrorCode(error?["codexErrorInfo"])
                if Self.normalizedErrorCode(errorCode) == "usagelimitexceeded"
                    || (errorCode == nil && Self.looksLikeQuotaLimit(message)) {
                    throw CodexAutoResumeAppServerError.quotaLimited(message)
                }
                throw CodexAutoResumeAppServerError.serverError(message)
            }
            if Self.normalizedStatus(status) == "interrupted" {
                throw CodexAutoResumeAppServerError.interrupted
            }
            let message = Self.nonemptyString(completed["result"])
                ?? Self.nonemptyString(completed["message"])
            return AutoResumeRunResult(
                threadID: target.id,
                turnID: turnID,
                status: status,
                message: message
            )
        }
    }

    private func withSession<T>(
        codexPath: String,
        dataSource: CodexDataSource?,
        operation: (any AccountQuotaProcessSession) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let session = try transport.start(codexPath: codexPath, dataSource: dataSource)
        let outcome: Result<T, Error> = await withTaskCancellationHandler {
            do {
                return .success(try operation(session))
            } catch {
                return .failure(error)
            }
        } onCancel: {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                session.requestTermination()
            }
        }

        do {
            _ = try session.shutdown()
        } catch {
            throw AccountQuotaProcessOwnershipError(underlyingError: error)
        }
        try Task.checkCancellation()
        return try outcome.get()
    }

    private static func parseThread(_ value: [String: Any]) -> AutoResumeThreadDescriptor? {
        guard let id = nonemptyString(value["id"]),
              let cwd = nonemptyString(value["cwd"]) else {
            return nil
        }
        let title = nonemptyString(value["name"])
            ?? nonemptyString(value["preview"])
            ?? String(id.prefix(12))
        return AutoResumeThreadDescriptor(
            id: id,
            title: title.components(separatedBy: .newlines).first ?? title,
            cwd: cwd,
            updatedAt: threadUpdatedAt(in: value)
        )
    }

    private static func threadFreshness(in thread: [String: Any]) -> AutoResumeThreadFreshness {
        let turns = thread["turns"] as? [[String: Any]]
        return AutoResumeThreadFreshness(
            updatedAt: threadUpdatedAt(in: thread),
            lastTurnID: turns?.last.flatMap { nonemptyString($0["id"]) }
        )
    }

    private static func threadUpdatedAt(in thread: [String: Any]) -> Date? {
        let value = thread["updatedAt"] ?? thread["updated_at"]
        if let seconds = (value as? NSNumber)?.doubleValue {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = nonemptyString(value) else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func activeLastTurnID(in thread: [String: Any]) -> String? {
        guard let turns = thread["turns"] as? [[String: Any]], let last = turns.last else {
            return nil
        }
        let status = normalizedStatus(nonemptyString(last["status"]) ?? "")
        guard ["inprogress", "running", "starting", "pending"].contains(status) else {
            return nil
        }
        return nonemptyString(last["id"]) ?? "unknown"
    }

    private static func parseLatestTurnObservation(
        _ turn: [String: Any]
    ) throws -> AutoResumeLatestTurnObservation {
        guard let turnID = nonemptyString(turn["id"]),
              let status = nonemptyString(turn["status"]) else {
            throw CodexAutoResumeAppServerError.invalidResponse(
                "thread/turns/list 的最新 turn 缺少 id 或 status"
            )
        }
        let error = turn["error"] as? [String: Any]
        let items = turn["items"] as? [[String: Any]] ?? []
        let clientUserMessageID = items.first(where: {
            normalizedStatus(nonemptyString($0["type"]) ?? "") == "usermessage"
        }).flatMap { nonemptyString($0["clientId"]) }
        let startedAt = (turn["startedAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        let completedAt = (turn["completedAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        return AutoResumeLatestTurnObservation(
            turnID: turnID,
            status: status,
            startedAt: startedAt,
            completedAt: completedAt,
            errorMessage: nonemptyString(error?["message"]),
            codexErrorCode: codexErrorCode(error?["codexErrorInfo"]),
            clientUserMessageID: clientUserMessageID
        )
    }

    private static func codexErrorCode(_ value: Any?) -> String? {
        if let value = nonemptyString(value) { return value }
        guard let object = value as? [String: Any] else { return nil }
        return object.keys.sorted().first
    }

    private static func normalizedErrorCode(_ value: String?) -> String? {
        value?.lowercased().filter(\.isLetter)
    }

    fileprivate static func normalizedStatus(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }

    fileprivate static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate static func looksLikeQuotaLimit(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return [
            "usage limit",
            "usage_limit",
            "usage limit exceeded",
            "insufficient_quota",
            "quota exceeded",
            "额度耗尽",
            "额度已用完",
            "使用额度已达上限",
        ].contains { normalized.contains($0) }
    }

    private static func checkedVisibilityCount(
        _ current: Int,
        adding increment: Int
    ) throws -> Int {
        let (value, overflow) = current.addingReportingOverflow(increment)
        guard !overflow else {
            throw CodexAutoResumeAppServerError.invalidResponse("会话数量溢出")
        }
        return value
    }
}

struct CodexAutoResumeRPCChannel {
    // 与 Rust INTERRUPT_GRACE_TIMEOUT 同值：超时发出 turn/interrupt 后
    // 等待 Codex 确认中断的宽限时长。
    static let interruptGraceTimeout: TimeInterval = 5
    private struct CompletedTurnEnvelope {
        let threadID: String
        let turn: [String: Any]
    }

    private let session: any AccountQuotaProcessSession
    private var nextRequestID = 1
    private var boundThreadID: String?
    private var boundTurnID: String?
    private var completedTurns: [CompletedTurnEnvelope] = []

    init(session: any AccountQuotaProcessSession) {
        self.session = session
    }

    mutating func initialize(
        timeout: TimeInterval,
        experimentalAPI: Bool = false
    ) throws {
        _ = try request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex-token-bar-auto-resume",
                    "title": "Codex Token Bar Auto Resume",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                ],
                "capabilities": [
                    "experimentalApi": experimentalAPI,
                    "requestAttestation": false,
                ],
            ],
            timeout: timeout
        )
        try notify(method: "initialized", params: [:])
    }

    mutating func bind(threadID: String) {
        boundThreadID = threadID
    }

    mutating func bind(turnID: String) {
        boundTurnID = turnID
    }

    mutating func request(
        method: String,
        params: [String: Any],
        timeout: TimeInterval,
        startAuthorization: AutoResumeStartAuthorization? = nil
    ) throws -> [String: Any] {
        let id = nextRequestID
        nextRequestID += 1
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        if let startAuthorization {
            try startAuthorization.withValidatedStart {
                try write(message)
            }
        } else {
            try write(message)
        }
        return try waitForResponse(id: id, stage: method, timeout: timeout)
    }

    mutating func waitForTurnCompletion(
        threadID: String,
        turnID: String,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        if let index = completedTurns.firstIndex(where: {
            $0.threadID == threadID && Self.turnID(in: $0.turn) == turnID
        }) {
            return completedTurns.remove(at: index).turn
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled {
                try? interruptBoundTurn()
                throw CancellationError()
            }
            let remaining = max(0, deadline.timeIntervalSinceNow)
            switch try session.nextStdoutEvent(timeout: min(0.1, remaining)) {
            case .idle:
                continue
            case .endOfFile:
                throw CodexAutoResumeAppServerError.processExited(" turn/completed")
            case .line(let line):
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                if try handleServerRequest(message) { continue }
                observeNotification(message)
                if let index = completedTurns.firstIndex(where: {
                    $0.threadID == threadID && Self.turnID(in: $0.turn) == turnID
                }) {
                    return completedTurns.remove(at: index).turn
                }
            }
        }
        if Task.isCancelled {
            try? interruptBoundTurn()
            throw CancellationError()
        }
        // 决策口径（与 Rust 超时分支同语义）：超时不能只 throw 弃管——那样
        // turn 会继续在后台跑满配额。先发 turn/interrupt，再宽限等待确认；
        // 宽限期内拿到完成事件（含 interrupted）按正常完成路径返回。
        try? interruptBoundTurn()
        let graceDeadline = Date().addingTimeInterval(Self.interruptGraceTimeout)
        while Date() < graceDeadline {
            if Task.isCancelled {
                throw CancellationError()
            }
            let remaining = max(0, graceDeadline.timeIntervalSinceNow)
            switch try session.nextStdoutEvent(timeout: min(0.1, remaining)) {
            case .idle:
                continue
            case .endOfFile:
                throw CodexAutoResumeAppServerError.processExited(" turn/completed")
            case .line(let line):
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                if try handleServerRequest(message) { continue }
                observeNotification(message)
                if let index = completedTurns.firstIndex(where: {
                    $0.threadID == threadID && Self.turnID(in: $0.turn) == turnID
                }) {
                    return completedTurns.remove(at: index).turn
                }
            }
        }
        throw CodexAutoResumeAppServerError.timeout("turn/completed")
    }

    private mutating func waitForResponse(
        id: Int,
        stage: String,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var cancellationGraceDeadline: Date?
        while Date() < deadline {
            if Task.isCancelled {
                if stage == "turn/start" {
                    if boundTurnID != nil {
                        try? interruptBoundTurn()
                        throw CancellationError()
                    }
                    if cancellationGraceDeadline == nil {
                        cancellationGraceDeadline = Date().addingTimeInterval(0.75)
                    }
                    if Date() >= cancellationGraceDeadline! {
                        throw CancellationError()
                    }
                } else {
                    throw CancellationError()
                }
            }
            let remaining = max(0, deadline.timeIntervalSinceNow)
            switch try session.nextStdoutEvent(timeout: min(0.1, remaining)) {
            case .idle:
                continue
            case .endOfFile:
                throw CodexAutoResumeAppServerError.processExited(stage)
            case .line(let line):
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                if try handleServerRequest(message) { continue }
                observeNotification(message)
                if Task.isCancelled, boundTurnID != nil {
                    try? interruptBoundTurn()
                    throw CancellationError()
                }
                guard (message["id"] as? NSNumber)?.intValue == id else { continue }
                if let error = message["error"] as? [String: Any] {
                    let detail = CodexAppServerClient.nonemptyString(error["message"])
                        ?? "RPC \(stage) failed"
                    if CodexAppServerClient.looksLikeQuotaLimit(detail) {
                        throw CodexAutoResumeAppServerError.quotaLimited(detail)
                    }
                    throw CodexAutoResumeAppServerError.serverError(detail)
                }
                guard let result = message["result"] as? [String: Any] else {
                    throw CodexAutoResumeAppServerError.invalidResponse("\(stage) 缺少 result")
                }
                return result
            }
        }
        if Task.isCancelled {
            try? interruptBoundTurn()
            throw CancellationError()
        }
        throw CodexAutoResumeAppServerError.timeout(stage)
    }

    private mutating func handleServerRequest(_ message: [String: Any]) throws -> Bool {
        guard let id = message["id"],
              let method = CodexAppServerClient.nonemptyString(message["method"]),
              message["result"] == nil,
              message["error"] == nil else {
            return false
        }

        let normalized = method.lowercased()
        let isNewApproval = normalized.contains("requestapproval")
            && (normalized.contains("commandexecution") || normalized.contains("filechange"))
        let isLegacyApproval = normalized.contains("execcommandapproval")
            || normalized.contains("exec_command_approval")
            || normalized.contains("applypatchapproval")
            || normalized.contains("apply_patch_approval")
        let requiresErrorResponse = normalized.contains("permissions/request")
            || normalized.contains("requestuserinput")
            || normalized.contains("request_user_input")
            || normalized.contains("elicitation")
        guard isNewApproval || isLegacyApproval || requiresErrorResponse || boundTurnID != nil else {
            try write([
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32000, "message": "Auto resume cannot handle server requests"],
            ])
            throw CodexAutoResumeAppServerError.requiresHuman(method)
        }

        if requiresErrorResponse || (!isNewApproval && !isLegacyApproval) {
            try write([
                "jsonrpc": "2.0",
                "id": id,
                "error": [
                    "code": -32000,
                    "message": "Auto resume requires human input",
                ],
            ])
        } else {
            let decision = isLegacyApproval ? "denied" : "decline"
            try write([
                "jsonrpc": "2.0",
                "id": id,
                "result": ["decision": decision],
            ])
        }
        try interruptBoundTurn()
        throw CodexAutoResumeAppServerError.requiresHuman(method)
    }

    private mutating func observeNotification(_ message: [String: Any]) {
        guard let method = CodexAppServerClient.nonemptyString(message["method"]),
              let params = message["params"] as? [String: Any] else {
            return
        }
        if method == "thread/started",
           let thread = params["thread"] as? [String: Any],
           let id = CodexAppServerClient.nonemptyString(thread["id"]) {
            boundThreadID = id
        } else if method == "turn/started",
                  let threadID = CodexAppServerClient.nonemptyString(params["threadId"]),
                  boundThreadID == nil || boundThreadID == threadID,
                  let turn = params["turn"] as? [String: Any],
                  let id = Self.turnID(in: turn) {
            boundThreadID = threadID
            boundTurnID = id
        } else if method == "turn/completed",
                  let threadID = CodexAppServerClient.nonemptyString(params["threadId"]),
                  let turn = params["turn"] as? [String: Any] {
            completedTurns.append(CompletedTurnEnvelope(threadID: threadID, turn: turn))
        }
    }

    private mutating func interruptBoundTurn() throws {
        guard let threadID = boundThreadID, let turnID = boundTurnID else { return }
        let id = nextRequestID
        nextRequestID += 1
        try write([
            "jsonrpc": "2.0",
            "id": id,
            "method": "turn/interrupt",
            "params": ["threadId": threadID, "turnId": turnID],
        ])
    }

    private func notify(method: String, params: [String: Any]) throws {
        try write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        try session.writeStdin(data)
    }

    private static func turnID(in turn: [String: Any]) -> String? {
        CodexAppServerClient.nonemptyString(turn["id"])
    }
}
