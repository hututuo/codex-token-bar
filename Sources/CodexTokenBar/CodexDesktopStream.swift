import Foundation
import Darwin

/// Local Desktop IPC is a versioned follower protocol, not an app-server JSON-RPC endpoint.
/// The observer sends initialize/follow only. It never takes ownership, resumes, or changes a turn.
struct DesktopStreamEvent: Sendable {
    enum Kind: Sendable, Equatable { case start, delta, finish, interrupted, reset }
    var kind: Kind
    var thread: String
    var turn = ""
    var item = ""
    var model = "unknown"
    var text = ""
    var at: Double
}

struct DesktopStreamDecoder {
    struct Item {
        var id: String
        var type: String
        var length: Int?
        var completed: Bool
        var observedCreation = false
        var startEmitted = false
    }
    struct Turn {
        var id: String
        var model: String
        var status = "inProgress"
        var items: [Int: Item] = [:]
    }
    struct Thread {
        var owner: String
        var revision: Int
        var turns: [String: Turn] = [:]
    }
    var threads: [String: Thread] = [:]
    var resubscribe: String?

    mutating func consume(_ message: [String: Any], at: Double, interests: Set<String>) -> [DesktopStreamEvent] {
        resubscribe = nil
        guard message["type"] as? String == "broadcast",
              message["method"] as? String == "thread-stream-state-changed",
              message["version"] as? Int == 11,
              let params = message["params"] as? [String: Any], params["hostId"] as? String == "local",
              let threadID = params["conversationId"] as? String, interests.contains(threadID),
              let owner = message["sourceClientId"] as? String,
              let change = params["change"] as? [String: Any], let revision = change["revision"] as? Int else { return [] }
        if change["type"] as? String == "snapshot" {
            guard let state = change["conversationState"] as? [String: Any], state["id"] as? String == threadID else { return [] }
            var thread = Thread(owner: owner, revision: revision)
            let history = (state["turnHistory"] as? [String: Any])?["history"] as? [String: Any]
            let entities = history?["entitiesByKey"] as? [String: [String: Any]] ?? [:]
            // Only retain identities/lengths of running turns; never retain or replay historical text.
            for (key, value) in entities where Self.isLive(value) {
                if let turn = Self.turn(value), thread.turns.count < 8 { thread.turns[key] = turn }
            }
            if let turns = state["turns"] as? [[String: Any]] {
                for (index, value) in turns.enumerated() where Self.isLive(value) {
                    if let turn = Self.turn(value), thread.turns.count < 8 { thread.turns["legacy:\(index)"] = turn }
                }
            }
            let previous = threads.updateValue(thread, forKey: threadID)
            return previous == nil ? [] : [.init(kind: .reset, thread: threadID, at: at)]
        }
        guard change["type"] as? String == "patches", var thread = threads[threadID] else { return [] }
        if owner == thread.owner, revision <= thread.revision { return [] } // duplicate/replayed frame
        guard owner == thread.owner, change["baseRevision"] as? Int == thread.revision, revision > thread.revision else {
            threads.removeValue(forKey: threadID); resubscribe = threadID
            return [.init(kind: .reset, thread: threadID, at: at)]
        }
        var events: [DesktopStreamEvent] = [], endings: [DesktopStreamEvent] = []
        for patch in change["patches"] as? [[String: Any]] ?? [] {
            guard let path = patch["path"] as? [Any], let location = Self.location(path) else { continue }
            let key = location.key, tail = location.tail
            if ["move", "copy"].contains(patch["op"] as? String ?? "") {
                threads.removeValue(forKey: threadID); resubscribe = threadID
                return [.init(kind: .reset, thread: threadID, at: at)]
            }
            if tail.isEmpty {
                if patch["op"] as? String == "remove" {
                    if let removed = thread.turns.removeValue(forKey: key), !removed.id.isEmpty {
                        endings.append(.init(kind: .reset, thread: threadID, turn: removed.id, at: at))
                    }
                    continue
                }
                if let old = thread.turns.removeValue(forKey: key), !old.id.isEmpty {
                    endings.append(.init(kind: .reset, thread: threadID, turn: old.id, at: at))
                }
                if let value = patch["value"] as? [String: Any], Self.isLive(value), let turn = Self.turn(value) {
                    // Full replacements are baselines, not output packets.
                    thread.turns[key] = turn
                }
                continue
            }
            guard var turn = thread.turns[key] else { continue }
            if tail.count == 1, tail[0] as? String == "turnId", let id = patch["value"] as? String {
                if !turn.id.isEmpty, turn.id != id { endings.append(.init(kind: .reset, thread: threadID, turn: turn.id, at: at)) }
                turn.id = id
            }
            if tail.count == 1, tail[0] as? String == "status", let status = patch["value"] as? String { turn.status = status }
            if tail.count == 2, tail[0] as? String == "params", tail[1] as? String == "model", let model = patch["value"] as? String { turn.model = model }
            if tail.count == 2, tail[0] as? String == "items", let index = tail[1] as? Int {
                if patch["op"] as? String == "remove" {
                    endings.append(.init(kind: .reset, thread: threadID, turn: turn.id, at: at)); turn.items.removeAll()
                } else if let value = patch["value"] as? [String: Any], let item = Self.item(value, completed: false) {
                    let fresh = turn.items[index] == nil
                    var added = item
                    added.observedCreation = fresh && item.length == 0
                    turn.items[index] = added
                    if turn.items.count > 512 {
                        let keep = Set(turn.items.keys.sorted().suffix(512))
                        turn.items = turn.items.filter { keep.contains($0.key) }
                    }
                }
            }
            if tail.count == 2, tail[0] as? String == "completedItemIds", let itemID = tail[1] as? String, patch["value"] as? Bool == true {
                for index in Array(turn.items.keys) where turn.items[index]?.id == itemID { turn.items[index]?.completed = true }
                if !turn.id.isEmpty { endings.append(.init(kind: .finish, thread: threadID, turn: turn.id, item: itemID, model: turn.model, at: at)) }
            }
            if tail.count == 1, tail[0] as? String == "status", let status = patch["value"] as? String, ["completed", "interrupted", "failed"].contains(status), !turn.id.isEmpty {
                endings.append(.init(kind: status == "completed" ? .finish : .interrupted, thread: threadID, turn: turn.id, at: at))
            }
            thread.turns[key] = turn
        }
        // A placeholder may receive its empty item before the real turn ID/status.
        // Emit a start only for an empty item whose creation we actually observed.
        for key in Array(thread.turns.keys) {
            guard var turn = thread.turns[key], !turn.id.isEmpty, turn.status == "inProgress" else { continue }
            for index in Array(turn.items.keys) {
                guard var item = turn.items[index], item.observedCreation, !item.startEmitted,
                      item.type == "agentMessage" else { continue }
                events.append(.init(kind: .start, thread: threadID, turn: turn.id, item: item.id, model: turn.model, at: at))
                item.startEmitted = true; turn.items[index] = item
            }
            thread.turns[key] = turn
        }
        for textChange in change["acceptedTextChanges"] as? [[String: Any]] ?? [] {
            guard textChange["type"] as? String == "text", let key = textChange["key"] as? [String: Any],
                  key["hostId"] as? String == "local", key["threadId"] as? String == threadID,
                  let entity = key["entityKey"] as? String, let itemID = key["itemId"] as? String,
                  let target = textChange["target"] as? [String: Any], target["field"] as? String == "text",
                  let edits = textChange["edits"] as? [[String: Any]] else { continue }
            guard var turn = thread.turns[entity], !turn.id.isEmpty,
                  turn.status == "inProgress" || endings.contains(where: { $0.turn == turn.id && $0.item.isEmpty && ($0.kind == .finish || $0.kind == .interrupted) }),
                  let index = turn.items.first(where: { $0.value.id == itemID })?.key else {
                threads.removeValue(forKey: threadID); resubscribe = threadID
                return events.filter { $0.kind != .delta } + [.init(kind: .reset, thread: threadID, at: at)]
            }
            guard var item = turn.items[index], item.type == "agentMessage",
                  (!item.completed || endings.contains { $0.item == itemID && $0.kind == .finish }) else { continue }
            var delta = "", valid = true
            for edit in edits {
                guard let offset = edit["at"] as? Int, offset >= 0,
                      item.length == nil || offset == item.length, edit["deleteCount"] as? Int == 0, let insert = edit["insert"] as? String,
                      insert.utf8.count <= 1_048_576 else { valid = false; break }
                item.length = offset + insert.utf16.count; delta += insert
            }
            if valid, !delta.isEmpty {
                events.append(.init(kind: .delta, thread: threadID, turn: turn.id, item: item.id, model: turn.model, text: delta, at: at))
            } else if !valid {
                // A replacement, missed append, or unsupported shape invalidates the partial sample.
                endings.append(.init(kind: .reset, thread: threadID, turn: turn.id, item: item.id, at: at))
                threads.removeValue(forKey: threadID); resubscribe = threadID
                return events.filter { $0.kind != .delta } + endings
            }
            turn.items[index] = item; thread.turns[entity] = turn
        }
        for ending in endings where ending.item.isEmpty && ending.kind != .reset {
            thread.turns = thread.turns.filter { $0.value.id != ending.turn }
        }
        thread.revision = revision
        if thread.turns.count > 8 { thread.turns = [:]; endings.append(.init(kind: .reset, thread: threadID, at: at)) }
        threads[threadID] = thread
        return events + endings
    }
    private static func turn(_ value: [String: Any]) -> Turn? {
        let id = value["turnId"] as? String ?? ""
        let params = value["params"] as? [String: Any]
        var result = Turn(id: id, model: params?["model"] as? String ?? "unknown")
        result.status = value["status"] as? String ?? "pending"
        let completed = value["completedItemIds"] as? [String: Bool] ?? [:]
        for (index, value) in (value["items"] as? [[String: Any]] ?? []).enumerated().suffix(512) {
            if let item = item(value, completed: completed[value["id"] as? String ?? ""] == true) { result.items[index] = item }
        }
        return result
    }
    private static func item(_ value: [String: Any], completed: Bool) -> Item? {
        guard let id = value["id"] as? String, let type = value["type"] as? String else { return nil }
        return Item(id: id, type: type, length: value["_tokenbarUnknownTextLength"] as? Bool == true ? nil : (value["text"] as? String ?? "").utf16.count, completed: completed)
    }
    private static func isLive(_ value: [String: Any]) -> Bool {
        ["inProgress", "pending", "queued", "starting", "waiting"].contains(value["status"] as? String ?? "pending")
    }
    private static func location(_ path: [Any]) -> (key: String, tail: [Any])? {
        if path.count >= 4, path[0] as? String == "turnHistory", path[1] as? String == "history", path[2] as? String == "entitiesByKey", let key = path[3] as? String {
            return (key, Array(path.dropFirst(4)))
        }
        if path.count >= 2, path[0] as? String == "turns", let index = path[1] as? Int { return ("legacy:\(index)", Array(path.dropFirst(2))) }
        return nil
    }
}

/// One bounded background reader. It connects to an existing, owner-only socket; never creates a router.
final class CodexDesktopStreamClient: @unchecked Sendable {
    private let lock = NSLock()
    private var wanted: Set<String> = []
    private var stopped = false
    private var descriptor: Int32 = -1
    private let queue = DispatchQueue(label: "TokenBar.DesktopStream", qos: .utility)
    private let endpoint: String
    private let onEvent: @Sendable (DesktopStreamEvent) -> Void
    private let onStatus: @Sendable (String) -> Void
    init(home: URL, onEvent: @escaping @Sendable (DesktopStreamEvent) -> Void, onStatus: @escaping @Sendable (String) -> Void) {
        endpoint = home.appendingPathComponent("ipc/ipc.sock").path
        self.onEvent = onEvent; self.onStatus = onStatus
    }
    func start() { queue.async { [self] in run() } }
    func update(threads: Set<String>) { lock.lock(); wanted = Set(threads.sorted().prefix(4)); lock.unlock() }
    func stop() {
        lock.lock(); stopped = true
        if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
        lock.unlock()
    }
    private func configuration() -> (stop: Bool, threads: Set<String>) {
        lock.lock(); defer { lock.unlock() }; return (stopped, wanted)
    }
    private func run() {
        while !configuration().stop {
            autoreleasepool { connectAndRead() }
            for _ in 0..<40 { if configuration().stop { return }; usleep(250_000) }
        }
    }
    private func connectAndRead() {
        var info = stat(), parent = stat()
        let directory = (endpoint as NSString).deletingLastPathComponent
        guard lstat(endpoint, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK,
              lstat(directory, &parent) == 0, parent.st_uid == getuid(), (parent.st_mode & 0o022) == 0,
              (parent.st_mode & S_IFMT) == S_IFDIR else { onStatus("Desktop 流式接口未就绪，继续监听本地日志"); return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        lock.lock(); descriptor = fd; let cancelled = stopped; lock.unlock()
        defer {
            lock.lock(); descriptor = -1; lock.unlock(); Darwin.close(fd)
            onEvent(.init(kind: .reset, thread: "", at: Date().timeIntervalSince1970))
        }
        guard !cancelled else { return }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(endpoint.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { onStatus("Desktop 流式接口连接失败，继续监听本地日志"); return }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        // Bound write stalls and poll reads so stop/source changes take effect promptly.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var client = "initializing-client", subscribed = Set<String>(), decoder = DesktopStreamDecoder()
        guard write(["type": "request", "requestId": UUID().uuidString, "sourceClientId": client, "version": 0,
                     "method": "initialize", "params": ["clientType": "tokenbar-readonly-observer"]], fd: fd) else { return }
        var buffer = Data(), initialized = false
        let connectedAt = ProcessInfo.processInfo.systemUptime
        let wallAnchor = Date().timeIntervalSince1970 - connectedAt
        var readBuffer = [UInt8](repeating: 0, count: 65_536)
        while !configuration().stop {
            let config = configuration()
            if initialized, config.threads != subscribed {
                for thread in subscribed.subtracting(config.threads) {
                    guard follow(thread, following: false, client: client, fd: fd) else { return }
                    decoder.threads.removeValue(forKey: thread)
                    onEvent(.init(kind: .reset, thread: thread, at: Date().timeIntervalSince1970))
                }
                for thread in config.threads.subtracting(subscribed) { guard follow(thread, following: true, client: client, fd: fd) else { return } }
                subscribed = config.threads
            }
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&pollFD, 1, 250)
            if ready < 0 { if errno == EINTR { continue }; return }
            if ready == 0 { if !initialized, ProcessInfo.processInfo.systemUptime - connectedAt > 5 { return }; continue }
            let count = Darwin.read(fd, &readBuffer, readBuffer.count)
            guard count > 0 else { if !configuration().stop { onStatus("Desktop 流式连接断开，等待重连") }; return }
            buffer.append(contentsOf: readBuffer.prefix(count))
            while buffer.count >= 4 {
                let length = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
                guard length > 0, length <= 268_435_456 else { onStatus("Desktop 流式协议不兼容，已停止本次采样"); return }
                guard buffer.count >= length + 4 else { break }
                let frame = Data(buffer.dropFirst(4).prefix(length)); buffer.removeFirst(length + 4)
                let keepReading = autoreleasepool { () -> Bool in
                    guard let message = length > 67_108_864
                        ? DesktopSnapshotProjection.project(frame)
                        : (try? JSONSerialization.jsonObject(with: frame) as? [String: Any]) else {
                        onStatus("Desktop 状态帧无法安全解析，重新建立采样基线")
                        return false
                    }
                if message["type"] as? String == "response", message["method"] as? String == "initialize",
                   message["resultType"] as? String == "success", let result = message["result"] as? [String: Any], let id = result["clientId"] as? String {
                    client = id; initialized = true; onStatus("已连接 Codex Desktop 流式事件，等待正文输出")
                } else if message["type"] as? String == "client-discovery-request", let requestID = message["requestId"] as? String {
                    guard write(["type": "client-discovery-response", "requestId": requestID, "response": ["canHandle": false]], fd: fd) else { return false }
                } else {
                    let at = wallAnchor + ProcessInfo.processInfo.systemUptime
                    for event in decoder.consume(message, at: at, interests: subscribed) { onEvent(event) }
                    if let thread = decoder.resubscribe {
                        guard follow(thread, following: false, client: client, fd: fd), follow(thread, following: true, client: client, fd: fd) else { return false }
                    }
                }
                    return true
                }
                guard keepReading else { return }
            }
        }
        for thread in subscribed { _ = follow(thread, following: false, client: client, fd: fd) }
    }
    private func follow(_ thread: String, following: Bool, client: String, fd: Int32) -> Bool {
        write(["type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": client, "version": 1,
               "params": ["conversationId": thread, "hostId": "local", "following": following]], fd: fd)
    }
    private func write(_ message: [String: Any], fd: Int32) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        var size = UInt32(data.count).littleEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }; frame.append(data)
        return frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }; offset += count
            }
            return true
        }
    }
}
