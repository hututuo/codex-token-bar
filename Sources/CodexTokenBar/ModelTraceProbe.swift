import Foundation

final class ModelTraceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

struct ModelTraceOutput {
    var finalText: String?
    var unphased: [String] = []
    var usage: [String: Int]?
    mutating func accept(_ message: [String: Any], thread: String, turn: String, expected: Int) throws -> ModelTrace.Sample? {
        guard let p = message["params"] as? [String: Any], p["threadId"] as? String == thread else { return nil }
        if let id = p["turnId"] as? String, id != turn { throw ModelTrace.fail("探针出现未请求的轮次") }
        let method = message["method"] as? String ?? ""
        if ["item/started", "item/updated", "item/completed"].contains(method), let item = p["item"] as? [String: Any],
           !["userMessage", "agentMessage", "reasoning"].contains(item["type"] as? String ?? "") { throw ModelTrace.fail("探针调用了工具，样本无效") }
        if method == "item/completed", let item = p["item"] as? [String: Any], item["type"] as? String == "agentMessage", let text = item["text"] as? String {
            guard text.utf8.count <= 5_000 else { throw ModelTrace.fail("探针回答过长") }
            if ["final_answer", "final"].contains(item["phase"] as? String ?? "") {
                guard finalText == nil else { throw ModelTrace.fail("探针出现多个最终回答") }
                finalText = text
            } else if item["phase"] == nil || item["phase"] is NSNull {
                guard unphased.count < 2 else { throw ModelTrace.fail("探针回答阶段不明确") }
                unphased.append(text)
            }
        }
        if method == "thread/tokenUsage/updated", let tokenUsage = p["tokenUsage"] as? [String: Any] { usage = tokenUsage["last"] as? [String: Int] }
        if method == "error", p["willRetry"] as? Bool != true { throw ModelTrace.fail("Codex 推理失败，请检查额度与连接") }
        if method == "turn/completed" {
            guard let value = p["turn"] as? [String: Any], value["id"] as? String == turn, value["status"] as? String == "completed",
                  let text = finalText ?? (unphased.count == 1 ? unphased.first : nil) else { throw ModelTrace.fail("探针未返回完整回答") }
            var sample = try ModelTrace.parse(text, expected: expected); sample.usage = usage
            return sample
        }
        return nil
    }
}

/// One owned transport per manual run; keeps notifications as well as RPC replies.
struct ModelTraceProbe {
    let transport: any AccountQuotaProcessTransport
    init(transport: any AccountQuotaProcessTransport = FoundationAccountQuotaProcessTransport(launchLeasePool: AccountQuotaProcessLaunchLeasePool(), retainedNotificationMethods: ["item/started", "item/updated", "item/completed", "turn/started", "turn/completed", "thread/tokenUsage/updated", "error"])) { self.transport = transport }
    func run(source: CodexDataSource, model: String, cancel: ModelTraceCancellation,
             validate: @escaping @Sendable () throws -> Void,
             progress: @Sendable (Int, ModelTrace.Sample?) throws -> Void) throws -> ModelTrace.Attribution {
        let session = try transport.start(codexPath: CodexBinaryLocator.findExecutable(), dataSource: source)
        do {
            var channel = Channel(session: session, cancel: cancel, validate: validate)
            _ = try channel.request("initialize", ["clientInfo": ["name": "codex_token_bar_modeltrace", "version": "0.9.7"], "capabilities": ["experimentalApi": true]])
            try channel.write(["jsonrpc": "2.0", "method": "initialized"])
            struct Active { let turn: String; let expected: Int; let index: Int; var output = ModelTraceOutput() }
            var active: [String: Active] = [:]
            var samples: [Int: ModelTrace.Sample] = [:]
            let work = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexTokenBar/modeltrace/work")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            do {
            for (index, expected) in ModelTrace.counts.enumerated() {
                try validate(); try channel.check(); try progress(index + 1, nil)
                let started = try channel.request("thread/start", ["model": model, "allowProviderModelFallback": false, "cwd": work.path, "ephemeral": true, "approvalPolicy": "never", "config": ["model_reasoning_effort": ModelTrace.effort]])
                guard started["model"] as? String == model, started["reasoningEffort"] as? String == ModelTrace.effort,
                      let thread = started["thread"] as? [String: Any], thread["ephemeral"] as? Bool == true,
                      thread["path"] == nil || thread["path"] is NSNull, let threadID = thread["id"] as? String else { throw ModelTrace.fail("Codex 返回的模型、思考强度或临时会话与请求不符") }
                let prompt = "这是一次独立的无语义数值选择记录。为 \(expected) 个位置分别凭第一反应选择一个 1 到 355（含端点）的整数。每个位置都要单独选择；不要从 1 开始计数，不要连续递增或递减，也不要采用等差、循环、重复区块或其他规则化模式。允许重复；每项写出后不要排序、重排、去重、替换或修正。本任务必须由当前语言模型直接完成，禁止调用任何工具、读取文件、运行代码、计算器、搜索、API、外部随机数生成器或其他模型。只返回一个完整 JSON 整数数组，不要解释。"
                let response = try channel.request("turn/start", ["threadId": threadID, "input": [["type": "text", "text": prompt]], "effort": ModelTrace.effort])
                guard let turn = response["turn"] as? [String: Any], let turnID = turn["id"] as? String else { throw ModelTrace.fail("Codex 未返回轮次 ID") }
                active[threadID] = Active(turn: turnID, expected: expected, index: index)
            }
            let deadline = Date().addingTimeInterval(240)
                while !active.isEmpty {
                    let message = try channel.next(deadline: deadline)
                    guard let params = message["params"] as? [String: Any], let threadID = params["threadId"] as? String,
                          var current = active[threadID] else { continue }
                    if let sample = try current.output.accept(message, thread: threadID, turn: current.turn, expected: current.expected) {
                        try validate(); try channel.check(); samples[current.index] = sample
                        active.removeValue(forKey: threadID); try progress(3, sample)
                    } else { active[threadID] = current }
                }
            } catch {
                for (threadID, current) in active {
                    try? channel.write(["jsonrpc": "2.0", "id": 999_999, "method": "turn/interrupt", "params": ["threadId": threadID, "turnId": current.turn]])
                }
                throw error
            }
            try validate(); try channel.check()
            let attribution = try ModelTrace.analyze(ModelTrace.counts.indices.compactMap { samples[$0] })
            _ = try session.shutdown()
            return attribution
        } catch {
            session.requestTermination()
            do { _ = try session.shutdown() } catch { throw AccountQuotaProcessOwnershipError(underlyingError: error) }
            throw error
        }
    }
    private struct Channel {
        let session: any AccountQuotaProcessSession
        let cancel: ModelTraceCancellation
        let validate: @Sendable () throws -> Void
        var id = 0
        var pending: [[String: Any]] = []
        var lastValidation = Date.distantPast
        mutating func check() throws {
            if cancel.isCancelled { throw ModelTrace.fail("检测已取消") }
            if Date().timeIntervalSince(lastValidation) >= 1 { try validate(); lastValidation = Date() }
        }
        func write(_ message: [String: Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject: message); bytes.append(10); try session.writeStdin(bytes)
        }
        mutating func receive(deadline: Date) throws -> [String: Any] {
            while Date() < deadline {
                try check()
                switch try session.nextStdoutEvent(timeout: 0.1) {
                case .idle: continue
                case .endOfFile: throw ModelTrace.fail("Codex 检测进程已退出")
                case .line(let line):
                    guard line.count <= 2 * 1024 * 1024, let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw ModelTrace.fail("Codex 协议消息无效") }
                    if value["method"] != nil, let requestID = value["id"] {
                        try write(["jsonrpc": "2.0", "id": requestID, "error": ["code": -32601, "message": "ModelTrace does not grant permissions"]])
                        throw ModelTrace.fail("探针请求额外权限，已终止")
                    }
                    return value
                }
            }
            throw ModelTrace.fail("检测请求超时")
        }
        mutating func next(deadline: Date) throws -> [String: Any] {
            try check()
            if !pending.isEmpty { return pending.removeFirst() }
            return try receive(deadline: deadline)
        }
        mutating func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try check(); id += 1
            try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            let deadline = Date().addingTimeInterval(30)
            while true {
                let message = try receive(deadline: deadline)
                if message["id"] as? Int == id {
                    guard message["error"] == nil, let result = message["result"] as? [String: Any] else { throw ModelTrace.fail("Codex \(method) 请求失败，请检查模型权限、连接及本机版本") }
                    return result
                }
                guard pending.count < 256 else { throw ModelTrace.fail("探针事件队列超过上限") }
                let kind = message["method"] as? String ?? ""
                if ["item/started", "item/updated", "item/completed", "turn/started", "turn/completed", "thread/tokenUsage/updated", "error"].contains(kind) { pending.append(message) }
            }
        }
    }
}
