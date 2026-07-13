import Foundation

struct CodexThreadDeleteBridgeStatus: Equatable, Sendable {
    let connected: Bool
    let debugPort: Int?
    let message: String

    static let idle = CodexThreadDeleteBridgeStatus(
        connected: false,
        debugPort: nil,
        message: "等待 Codex 调试连接（需以调试模式启动 Codex）"
    )
}

@MainActor
final class CodexThreadDeleteBridgeController: ObservableObject {
    @Published private(set) var status: CodexThreadDeleteBridgeStatus = .idle

    private let service: CodexThreadDeleteBridgeService
    private var task: Task<Void, Never>?

    init(service: CodexThreadDeleteBridgeService = CodexThreadDeleteBridgeService()) {
        self.service = service
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self, service] in
            await service.run { status in
                await MainActor.run {
                    self?.status = status
                }
            }
        }
    }

    func reconnect() {
        task?.cancel()
        status = .idle
        task = Task { [weak self, service] in
            await service.cancelActiveSession()
            await service.run { status in
                await MainActor.run {
                    self?.status = status
                }
            }
        }
    }
}

actor CodexThreadDeleteBridgeService {
    private let ports: [Int]
    private let executor: any CodexThreadDeleteExecuting
    private let session: URLSession
    private var activeSocket: URLSessionWebSocketTask?
    private var lifecycleGeneration = 0

    init(
        ports: [Int] = [9229, 9222],
        executor: any CodexThreadDeleteExecuting = FoundationCodexThreadDeleteExecutor(),
        session: URLSession = .shared
    ) {
        self.ports = ports
        self.executor = executor
        self.session = session
    }

    func run(
        statusChanged: @escaping @Sendable (CodexThreadDeleteBridgeStatus) async -> Void
    ) async {
        let generation = lifecycleGeneration
        while !Task.isCancelled, generation == lifecycleGeneration {
            guard let target = await findTarget() else {
                guard generation == lifecycleGeneration else { return }
                await statusChanged(.idle)
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            do {
                try await runSession(
                    target: target,
                    generation: generation,
                    statusChanged: statusChanged
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generation == lifecycleGeneration else { return }
                await statusChanged(CodexThreadDeleteBridgeStatus(
                    connected: false,
                    debugPort: target.port,
                    message: "Codex 删除按钮连接中断：\(error.localizedDescription)"
                ))
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func cancelActiveSession() {
        lifecycleGeneration &+= 1
        activeSocket?.cancel(with: .goingAway, reason: nil)
        activeSocket = nil
    }

    private func findTarget() async -> CodexThreadDeleteTarget? {
        for port in ports {
            guard !Task.isCancelled,
                  let url = URL(string: "http://127.0.0.1:\(port)/json/list")
            else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let targets = try? JSONDecoder().decode([CodexThreadDeleteTargetPayload].self, from: data)
            else { continue }
            if let target = targets.compactMap({ $0.target(port: port) }).first {
                return target
            }
        }
        return nil
    }

    private func runSession(
        target: CodexThreadDeleteTarget,
        generation: Int,
        statusChanged: @escaping @Sendable (CodexThreadDeleteBridgeStatus) async -> Void
    ) async throws {
        var request = URLRequest(url: target.webSocketURL)
        request.setValue("http://127.0.0.1:\(target.port)", forHTTPHeaderField: "Origin")
        let socket = session.webSocketTask(with: request)
        activeSocket = socket
        socket.resume()
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            if activeSocket === socket {
                activeSocket = nil
            }
        }

        try await installBridge(on: socket)
        guard generation == lifecycleGeneration else { throw CancellationError() }
        await statusChanged(CodexThreadDeleteBridgeStatus(
            connected: true,
            debugPort: target.port,
            message: "Codex 会话删除按钮已连接"
        ))

        while !Task.isCancelled, generation == lifecycleGeneration {
            let message = try await socket.receive()
            guard generation == lifecycleGeneration else { throw CancellationError() }
            guard case let .string(text) = message else { continue }
            try await handleMessage(text, socket: socket)
        }
        throw CancellationError()
    }

    private func installBridge(on socket: URLSessionWebSocketTask) async throws {
        let script = try CodexThreadDeleteInjectionScript.render(
            owner: "swift",
            bindingName: "codexTokenBarDeleteSwift"
        )
        try await send(method: "Runtime.enable", params: [:], socket: socket)
        try await send(
            method: "Runtime.removeBinding",
            params: ["name": "codexTokenBarDeleteSwift"],
            socket: socket
        )
        try await send(
            method: "Runtime.addBinding",
            params: ["name": "codexTokenBarDeleteSwift"],
            socket: socket
        )
        try await send(
            method: "Page.addScriptToEvaluateOnNewDocument",
            params: ["source": script],
            socket: socket
        )
        try await send(method: "Runtime.evaluate", params: ["expression": script], socket: socket)
    }

    private func handleMessage(
        _ text: String,
        socket: URLSessionWebSocketTask
    ) async throws {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["method"] as? String == "Runtime.bindingCalled",
              let params = message["params"] as? [String: Any],
              let payloadText = params["payload"] as? String,
              let payloadData = payloadText.data(using: .utf8),
              let request = try? JSONDecoder().decode(CodexThreadDeleteBindingRequest.self, from: payloadData),
              request.owner == "swift"
        else { return }

        let result: CodexThreadDeleteBindingResult
        do {
            try CodexThreadID.validate(request.threadID)
            let message = try await executor.delete(threadID: request.threadID)
            result = CodexThreadDeleteBindingResult(status: "deleted", message: message)
        } catch {
            result = CodexThreadDeleteBindingResult(
                status: "failed",
                message: error.localizedDescription
            )
        }
        let expression = try CodexThreadDeleteInjectionScript.resolveExpression(
            owner: request.owner,
            requestID: request.id,
            result: result
        )
        try await send(
            method: "Runtime.evaluate",
            params: ["expression": expression],
            socket: socket
        )
    }

    private func send(
        method: String,
        params: [String: Any],
        socket: URLSessionWebSocketTask
    ) async throws {
        let payload: [String: Any] = [
            "id": CodexThreadDeleteMessageID.next(),
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
}

private enum CodexThreadDeleteMessageID {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var value = 100
    }

    private static let storage = Storage()

    static func next() -> Int {
        storage.lock.withLock {
            storage.value += 1
            return storage.value
        }
    }
}

struct CodexThreadDeleteTarget: Equatable, Sendable {
    let port: Int
    let webSocketURL: URL
}

private struct CodexThreadDeleteTargetPayload: Decodable {
    let type: String
    let title: String?
    let url: String?
    let webSocketDebuggerUrl: URL?

    func target(port: Int) -> CodexThreadDeleteTarget? {
        let title = (title ?? "").lowercased()
        let pageURL = (url ?? "").lowercased()
        guard type == "page",
              !pageURL.hasPrefix("devtools://"),
              pageURL.hasPrefix("app://") || title.contains("codex") || title.contains("chatgpt"),
              let webSocketDebuggerUrl,
              CodexThreadDeleteInjectionScript.isLoopback(webSocketDebuggerUrl)
        else { return nil }
        return CodexThreadDeleteTarget(port: port, webSocketURL: webSocketDebuggerUrl)
    }
}

struct CodexThreadDeleteBindingRequest: Decodable, Equatable, Sendable {
    let id: String
    let owner: String
    let threadID: String
    let title: String
}

struct CodexThreadDeleteBindingResult: Encodable, Equatable, Sendable {
    let status: String
    let message: String
}

enum CodexThreadDeleteInjectionScript {
    static func render(owner: String, bindingName: String) throws -> String {
        let template = try loadTemplate()
        return template
            .replacingOccurrences(of: "__CTB_OWNER_JSON__", with: try jsonString(owner))
            .replacingOccurrences(of: "__CTB_BINDING_JSON__", with: try jsonString(bindingName))
    }

    static func resolveExpression(
        owner: String,
        requestID: String,
        result: CodexThreadDeleteBindingResult
    ) throws -> String {
        let data = try JSONEncoder().encode(result)
        return "window.__codexTokenBarThreadDeleteResolve(\(try jsonString(owner)), \(try jsonString(requestID)), \(String(decoding: data, as: UTF8.self)))"
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme == "ws", let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "::1" || host == "localhost"
    }

    private static func loadTemplate() throws -> String {
        if let url = Bundle.main.url(
            forResource: "CodexThreadDeleteInjection",
            withExtension: "js"
        ) {
            return try String(contentsOf: url, encoding: .utf8)
        }
#if DEBUG
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/CodexThreadDeleteInjection.js")
        return try String(contentsOf: source, encoding: .utf8)
#else
        throw CodexThreadDeleteError.injectionResourceMissing
#endif
    }

    private static func jsonString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        return String(decoding: data, as: UTF8.self)
    }
}

enum CodexThreadID {
    static func validate(_ value: String) throws {
        guard UUID(uuidString: value) != nil, value.count == 36 else {
            throw CodexThreadDeleteError.invalidThreadID
        }
    }
}

protocol CodexThreadDeleteExecuting: Sendable {
    func delete(threadID: String) async throws -> String
}

final class FoundationCodexThreadDeleteExecutor: CodexThreadDeleteExecuting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodexTokenBar.ThreadDelete")
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    func delete(threadID: String) async throws -> String {
        try CodexThreadID.validate(threadID)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [timeout] in
                continuation.resume(with: Result {
                    try Self.run(threadID: threadID, timeout: timeout)
                })
            }
        }
    }

    static func commandArguments(threadID: String) -> [String] {
        ["delete", "--force", threadID]
    }

    private static func run(threadID: String, timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try CodexBinaryLocator.findExecutable())
        process.arguments = commandArguments(threadID: threadID)
        var environment = ProcessInfo.processInfo.environment
        if let dataSource = CodexDataSourceResolver().resolve() {
            environment["CODEX_HOME"] = dataSource.codexHome.path
        }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning {
            process.terminate()
            throw CodexThreadDeleteError.timeout
        }
        let output = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let error = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw CodexThreadDeleteError.commandFailed(error.isEmpty ? output : error)
        }
        return output.isEmpty ? "会话已永久删除" : output
    }
}

enum CodexThreadDeleteError: LocalizedError {
    case commandFailed(String)
    case injectionResourceMissing
    case invalidThreadID
    case timeout

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message):
            return "Codex 删除失败：\(message)"
        case .injectionResourceMissing:
            return "缺少 Codex 删除按钮脚本"
        case .invalidThreadID:
            return "会话 ID 不是有效 UUID"
        case .timeout:
            return "Codex 删除命令超时"
        }
    }
}
