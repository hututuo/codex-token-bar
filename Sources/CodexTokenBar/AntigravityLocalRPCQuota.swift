import Foundation
import CoreFoundation
import Darwin

/// Queries only an already-running, installed standalone Hub. No OAuth, remote URL,
/// client launch or forceRefresh. The language server may itself contact its provider.
enum AntigravityLocalRPCQuota {
    static let source = "local-antigravity-rpc"
    static let maximumBytes = 512 * 1_024
    struct Endpoint: Equatable {
        let pid: Int32
        let executable: String
        let port: Int
        let csrf: String
    }

    static func unavailable() -> ClientQuotaReading {
        .init(client: "antigravity", state: "unavailable", source: source, windows: [],
              notice: "当前 Antigravity 本机语言服务额度不可用；不改用其他账号的旧缓存，不启动客户端。")
    }

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> ClientQuotaReading? {
        guard let listing = command("/bin/ps", ["-U", String(getuid()), "-o", "pid=,comm="]) else { return unavailable() }
        let servers = runningServers(listing, home: home)
        guard !servers.isEmpty else { return nil }
        guard servers.count == 1, let server = servers.first,
              let endpoint = discover(pid: server.0, executable: server.1, home: home),
              let request = request(endpoint), let bytes = fetch(request, endpoint: endpoint),
              // A restarted server / reused port must not publish the previous process's result.
              discover(pid: server.0, executable: server.1, home: home) == endpoint else { return unavailable() }
        return decode(bytes, now: now)
    }

    static func runningServers(_ listing: String, home: URL) -> [(Int32, String)] {
        let paths = ["/Applications/Antigravity.app/Contents/Resources/bin/language_server",
                     home.appendingPathComponent("Applications/Antigravity.app/Contents/Resources/bin/language_server").path]
        return listing.split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, let pid = Int32(parts[0]), pid > 1 else { return nil }
            let path = String(parts[1]).trimmingCharacters(in: .whitespaces)
            return paths.contains(path) ? (pid, path) : nil
        }
    }

    private static func discover(pid: Int32, executable: String, home: URL) -> Endpoint? {
        var path = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              String(cString: path) == executable,
              let args = command("/bin/ps", ["-p", String(pid), "-o", "command="]),
              let listeners = command("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]) else { return nil }
        let log = home.appendingPathComponent("Library/Logs/Antigravity/language_server.log")
        var prefix = ""
        if (try? FileManager.default.attributesOfItem(atPath: log.path)[.type]) as? FileAttributeType == .typeRegular,
           let handle = try? FileHandle(forReadingFrom: log) {
            defer { try? handle.close() }
            prefix = (try? handle.read(upToCount: 131_072)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        return endpoint(pid: pid, executable: executable, commandLine: args, listeners: listeners, logPrefix: prefix)
    }

    static func endpoint(pid: Int32, executable: String, commandLine: String, listeners: String, logPrefix: String) -> Endpoint? {
        guard commandLine.hasPrefix(executable + " "),
              commandLine.dropFirst(executable.count).split(whereSeparator: { $0.isWhitespace }).contains("--standalone"),
              listeners.split(separator: "\n").contains(Substring("p\(pid)")) else { return nil }
        func flag(_ name: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: "(?:^|\\s)" + name + "(?:=|\\s+)([^\\s]+)"),
                  let match = regex.firstMatch(in: commandLine, range: NSRange(commandLine.startIndex..., in: commandLine)),
                  let range = Range(match.range(at: 1), in: commandLine) else { return nil }
            return String(commandLine[range])
        }
        guard let csrf = flag("--csrf_token"), UUID(uuidString: csrf) != nil,
              let requested = flag("--https_server_port"), let requestedPort = Int(requested), (0...65_535).contains(requestedPort) else { return nil }
        let owned = Set(listeners.split(separator: "\n").compactMap { line -> Int? in
            guard line.hasPrefix("n127.0.0.1:") || line.hasPrefix("n[::1]:"),
                  let port = Int(line.split(separator: ":").last ?? ""), (1_024...65_535).contains(port) else { return nil }
            return port
        })
        var port = requestedPort
        if port == 0 {
            let pattern = "Language server listening on random port at ([0-9]{1,5}) for HTTPS \\(gRPC\\)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            port = regex.matches(in: logPrefix, range: NSRange(logPrefix.startIndex..., in: logPrefix)).compactMap { match in
                Range(match.range(at: 1), in: logPrefix).flatMap { Int(logPrefix[$0]) }
            }.last ?? 0
        }
        guard owned.contains(port) else { return nil }
        return Endpoint(pid: pid, executable: executable, port: port, csrf: csrf)
    }

    static func request(_ endpoint: Endpoint) -> URLRequest? {
        guard (1_024...65_535).contains(endpoint.port), UUID(uuidString: endpoint.csrf) != nil,
              let url = URL(string: "https://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(endpoint.csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = Data("{\"metadata\":{\"ideName\":\"antigravity\",\"extensionName\":\"antigravity\",\"locale\":\"en\"}}".utf8)
        return request
    }

    static func decode(_ bytes: Data, now: Date) -> ClientQuotaReading {
        guard bytes.count <= maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return unavailable() }
        if let code = root["code"], !["0", "OK", "ok"].contains(String(describing: code)) { return unavailable() }
        let payload = root["response"] as? [String: Any] ?? root["summary"] as? [String: Any] ?? root
        guard let groups = payload["groups"] as? [[String: Any]], groups.count <= 16 else { return unavailable() }
        let labels = ["gemini-5h": "Gemini · 5h", "gemini-weekly": "Gemini · 7d",
                      "3p-5h": "第三方模型 · 5h", "3p-weekly": "第三方模型 · 7d"]
        var seen = Set<String>()
        var windows: [ClientQuotaReading.Window] = []
        for group in groups {
            guard let buckets = group["buckets"] as? [[String: Any]], buckets.count <= 32 else { return unavailable() }
            for bucket in buckets {
                guard let id = bucket["bucketId"] as? String ?? bucket["id"] as? String,
                      let label = labels[id], bucket["disabled"] as? Bool != true else { continue }
                guard seen.insert(id).inserted else { return unavailable() }
                let remaining = bucket["remaining"] as? [String: Any]
                let raw = bucket["remainingFraction"] ?? remaining?["remainingFraction"]
                    ?? (remaining?["case"] as? String == "remainingFraction" ? remaining?["value"] : nil)
                guard let fraction = raw as? NSNumber, CFGetTypeID(fraction) != CFBooleanGetTypeID(),
                      fraction.doubleValue.isFinite, (0...1).contains(fraction.doubleValue) else { continue }
                let reset = (bucket["resetTime"] as? String ?? bucket["resetTimeUtc"] as? String).flatMap(LocalQuotaCacheFile.isoDate)
                windows.append(.init(label: label, usedPercent: (1 - fraction.doubleValue) * 100, resetsAt: reset, id: id))
            }
        }
        guard !windows.isEmpty else { return unavailable() }
        let order = ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"]
        windows.sort { order.firstIndex(of: $0.id ?? "")! < order.firstIndex(of: $1.id ?? "")! }
        let stale = windows.contains { $0.resetsAt.map { $0 <= now } ?? true }
        return .init(client: "antigravity", state: stale ? "stale" : "available", source: source, windows: windows,
                     notice: "Antigravity 本机语言服务的分池额度，Gemini 与第三方模型各有 5h / 7d 窗口。未强制刷新；读取时间不代表上游采样时间。", capturedAt: now)
    }

    private static func fetch(_ request: URLRequest, endpoint: Endpoint) -> Data? {
        let transfer = AntigravityRPCTransfer(port: endpoint.port)
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config, delegate: transfer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request).resume()
        guard transfer.finished.wait(timeout: .now() + 6) == .success else { return nil }
        return transfer.result()
    }

    /// Fixed system executables only; bounded pipe and deadline, no shell or provider launch.
    private static func command(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let handle = pipe.fileHandleForReading
        defer { try? handle.close() }
        guard fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK) != -1 else { return nil }
        do { try process.run() } catch { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            if data.count > 1_048_576 || ProcessInfo.processInfo.systemUptime > deadline {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return nil
            }
            if count == 0 {
                if !process.isRunning { break }
                usleep(5_000)
            }
            if count < 0 {
                if errno != EAGAIN && errno != EINTR { break }
                usleep(5_000)
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private final class AntigravityRPCTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let port: Int
    private let lock = NSLock()
    private var bytes = Data()
    private var valid = false
    init(port: Int) { self.port = port }
    func result() -> Data? { lock.withLock { valid ? bytes : nil } }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1", challenge.protectionSpace.port == port,
              let trust = challenge.protectionSpace.serverTrust else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let accept = (response as? HTTPURLResponse)?.statusCode == 200 && response.expectedContentLength <= Int64(AntigravityLocalRPCQuota.maximumBytes)
        lock.withLock { valid = accept }
        completionHandler(accept ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock {
            guard bytes.count + data.count <= AntigravityLocalRPCQuota.maximumBytes else { valid = false; return true }
            bytes.append(data); return false
        }
        if overflow { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { lock.withLock { valid = false } }
        finished.signal()
    }
}
