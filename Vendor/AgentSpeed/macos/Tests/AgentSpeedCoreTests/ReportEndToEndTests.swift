import Darwin
import Foundation
import Testing
@testable import AgentSpeedCore

/// The client against spec/tools/report_server.py on loopback (REPORTING 12.1): the real URLSession transport, signing,
/// bodies and reply handling. Never reaches beyond 127.0.0.1.
@Suite(.serialized, .enabled(if: ReferencePython.available))
struct ReportEndToEndTests {
    static let userAgent = "AgentSpeed/1.3.0 (macOS)"
    static let client = ReportClientInfo(version: "1.3.0", osMajor: 27)

    /// One device talking to one server.
    struct Device {
        let api: ReportAPI
        let document: ReportDiscovery
        var signer: any ReportSigner = SoftwareReportSigner()
        let deviceId = ReportCanonical.newUUID()
        var apiKey: String?
        let runId = ReportCanonical.newUUID()
        var seq = 0

        func send(_ method: String, _ endpoint: String, _ body: Data, signer: (any ReportSigner)? = nil,
                  newKey: (any ReportSigner)? = nil, skew: Int64 = 0) async throws -> ReportReply {
            let builder = ReportRequestBuilder(userAgent: ReportEndToEndTests.userAgent, deviceId: deviceId, apiKey: apiKey)
            let request = try builder.make(method: method, url: document.api.appending(endpoint: endpoint), body: body,
                                           signer: signer ?? self.signer,
                                           timestamp: Int64(Date().timeIntervalSince1970) + skew, newKey: newKey)
            return try await api.call(request).get()
        }

        func register(_ username: String, transfer: Bool = false) async throws -> ReportReply {
            try await send("POST", ReportEndpoint.devices, ReportDocuments.registration(
                deviceId: deviceId, username: username, publicKey: signer.publicKey, client: ReportEndToEndTests.client,
                transfer: transfer))
        }

        mutating func report(_ username: String, activity: ReportScheduler.Activity = .active, signer: (any ReportSigner)? = nil)
            async throws -> (ReportReply, Data) {
            seq += 1
            let body = Self.body(deviceId: deviceId, username: username, runId: runId, seq: seq, activity: activity,
                                 sections: document.sections)
            return (try await send("POST", ReportEndpoint.reports, body, signer: signer), body)
        }

        static func body(deviceId: String, username: String, runId: String, seq: Int, activity: ReportScheduler.Activity,
                         sections: Set<ReportSection>) -> Data {
            var counters = ReportCounters()
            counters.add(ReportUsage(requests: 2, output: 640, input: 90_000, cachedInput: 80_000, measuredOutput: 600,
                                     measuredMs: 1500, costMicroUsd: 4200), to: ReportModelKey(modelId: "gpt-5.5", source: .codex))
            let facts = ReportLiveFacts(agents: [.codex: ReportAgentCounts(generating: 1, active: 1)],
                                        generatingModels: [ReportModelKey(modelId: "gpt-5.5", source: .codex): 1],
                                        counters: counters)
            let sample = ReportSample(live: Rate(output: 128.4, total: 18_000), estimatedShare: 0.4,
                                      liveCost: LiveCost(microUsdPerSecond: 900, knownOutput: 128.4),
                                      sources: [.codex: .init(live: Rate(output: 128.4, total: 18_000))], facts: facts,
                                      traffic: ReportTrafficSample(status: .unavailable))
            let envelope = ReportEnvelope(client: ReportEndToEndTests.client, deviceId: deviceId, username: username,
                                          runId: runId, seq: seq, sentAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                                          windowMs: 5000, activity: activity, titleLevel: 6)
            let window = ReportWindow(ReportSample())
            return ReportBody.data(envelope, window.content(sample), sample, ReportOptions(sections: sections))
        }
    }

    static func device(on server: ReferenceServer, apiKey: String? = nil) async throws -> Device {
        let api = ReportAPI(transport: URLSessionReportTransport(), userAgent: userAgent)
        guard case .document(let document, _) = await api.discover(server.service) else {
            throw ReferenceServer.Failure.discovery
        }
        return Device(api: api, document: document, apiKey: apiKey)
    }

    @Test func lifecycle() async throws {
        let server = try ReferenceServer()
        defer { server.stop() }
        var device = try await Self.device(on: server)
        #expect(device.document.supportsThisClient)
        #expect(device.document.api.isLoopbackHTTP)
        #expect(device.document.sections == Set(ReportSection.allCases))

        #expect(try await device.register("小明的 Mac").result == "created")
        #expect(try await device.register("小明的 Mac").result == "exists")
        for _ in 0..<2 {
            let (reply, _) = try await device.report("小明的 Mac")
            #expect(reply.result == "accepted")
        }
        let (third, body) = try await device.report("小明的 Mac")
        #expect(third.result == "accepted")
        let duplicate = try await device.send("POST", ReportEndpoint.reports, body)
        #expect(duplicate.result == "duplicate", "a retry with a new nonce is answered as a duplicate")

        let (limited, _) = try await device.report("小明的 Mac")
        #expect(limited.status == 429)
        let classified = ReportOutcome.classify(.success(limited), hasPendingKey: false)
        guard case .rateLimited(let seconds) = classified.0 else {
            Issue.record("429 is not rate limited: \(classified)")
            return
        }
        #expect((5...3600).contains(seconds))

        let renamed = try await device.send("PATCH", ReportEndpoint.device(device.deviceId),
                                            ReportDocuments.rename(username: "zoe-studio"))
        #expect(renamed.result == "updated" && renamed.username == "zoe-studio")
        try await Task.sleep(for: .seconds(4.2))
        let (mismatch, _) = try await device.report("小明的 Mac")
        #expect(mismatch.code == "username_mismatch" && mismatch.errorUsername == "zoe-studio")
        #expect(ReportOutcome.classify(.success(mismatch), hasPendingKey: false).1 == .rename(registered: "zoe-studio"))

        let rotated = SoftwareReportSigner()
        let rotation = try await device.send("PUT", ReportEndpoint.key(device.deviceId),
                                             ReportDocuments.rotation(publicKey: rotated.publicKey), newKey: rotated)
        #expect(rotation.result == "rotated")
        try await Task.sleep(for: .seconds(4.2))
        let (stale, _) = try await device.report("zoe-studio")
        #expect(stale.code == "signature_invalid")
        #expect(ReportOutcome.classify(.success(stale), hasPendingKey: true) == (.again, .usePendingKey))
        device.signer = rotated
        let (fresh, _) = try await device.report("zoe-studio")
        #expect(fresh.result == "accepted")

        let skewed = try await device.send("POST", ReportEndpoint.reports,
                                           Device.body(deviceId: device.deviceId, username: "zoe-studio", runId: device.runId,
                                                       seq: 99, activity: .active, sections: []), skew: -400)
        #expect(skewed.code == "timestamp_out_of_window")
        if case .correctClock(let serverTime?) = ReportOutcome.classify(.success(skewed), hasPendingKey: false).1 {
            #expect(abs(serverTime - Int64(Date().timeIntervalSince1970)) < 5)
        } else {
            Issue.record("no clock correction")
        }

        let deleted = try await device.send("DELETE", ReportEndpoint.device(device.deviceId), Data())
        #expect(deleted.result == "deleted")
        let (gone, _) = try await device.report("zoe-studio")
        #expect(gone.code == "unknown_device")
        #expect(ReportOutcome.classify(.success(gone), hasPendingKey: false).1 == .reRegister)
        #expect(server.log.contains("forget"))
    }

    @Test func apiKeysAndLeaving() async throws {
        let server = try ReferenceServer(arguments: ["--api-key-mode", "required", "--api-key", "secret-12345",
                                                     "--charset", "ascii", "--no-spaces", "--max-length", "16"])
        defer { server.stop() }
        var device = try await Self.device(on: server)
        #expect(device.document.apiKeyMode == .required)
        #expect(device.document.usernameRules == ReportUsernameRules(minLength: 2, maxLength: 16, charset: .ascii, spaces: false))
        let missing = try await device.register("Zoes-MacBook")
        #expect(missing.code == "api_key_required")
        #expect(ReportOutcome.classify(.success(missing), hasPendingKey: false).1 == .needsUser(.apiKey))
        device.apiKey = "secret-12345"
        let invalid = try await device.register("Zoe MBP")
        #expect(invalid.code == "username_invalid" && invalid.reason == "spaces")
        #expect(ReportUsername.validate("Zoe MBP", rules: device.document.usernameRules) == .spaces)
        #expect(try await device.register("Zoes-MacBook").result == "created")
        let (leaving, _) = try await device.report("Zoes-MacBook", activity: .leaving)
        #expect(leaving.result == "accepted")
        device.apiKey = "wrong-key-000"
        let (wrong, _) = try await device.report("Zoes-MacBook")
        #expect(wrong.code == "api_key_invalid")
        #expect(server.log.contains("leaving"))
    }
}

/// `python3 spec/tools/report_server.py` on a free loopback port, stopped by `stop()`.
final class ReferenceServer: @unchecked Sendable {
    enum Failure: Error { case port, start, discovery }

    /// The upstream schema names its own client. Keep that source schema and its vectors intact, while making this
    /// product's end-to-end client identity valid only in the in-process reference server used by these tests.
    private static let compatibilityRunner = #"""
        import runpy, sys
        tools, server = sys.argv[1:3]
        sys.path.insert(0, tools)
        import report_reference as reference
        upstream_load_schema = reference.load_schema
        def tokenbar_schema():
            schema = upstream_load_schema()
            schema["$defs"]["client"]["properties"]["app"] = {"enum": ["AgentSpeed", "CodexTokenBar"]}
            return schema
        reference.load_schema = tokenbar_schema
        sys.argv = [server, *sys.argv[3:]]
        runpy.run_path(server, run_name="__main__")
        """#

    let port: Int
    let service: ReportServiceURL
    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private let stopped = DispatchSemaphore(value: 0)

    init(arguments: [String] = []) throws {
        port = try Self.freePort()
        service = try ReportServiceURL.parse("http://127.0.0.1:\(port)").get()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let server = ReferencePython.tools.appendingPathComponent("report_server.py").path
        process.arguments = ["-I", "-c", Self.compatibilityRunner, ReferencePython.tools.path, server,
                             "--port", String(port)] + arguments
        process.standardOutput = output
        process.standardError = output
        let stopped = self.stopped
        process.terminationHandler = { _ in stopped.signal() }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.lock.lock()
            self.buffer.append(data)
            self.lock.unlock()
        }
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while !log.contains("listening") {
            guard Date() < deadline, process.isRunning else { throw Failure.start }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    var log: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        guard stopped.wait(timeout: .now() + 3) == .timedOut else { return }
        var status: Int32 = 0
        if waitpid(process.processIdentifier, &status, WNOHANG) == 0 {
            kill(process.processIdentifier, SIGKILL)
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline, waitpid(process.processIdentifier, &status, WNOHANG) == 0 {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.port }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        guard bound else { throw Failure.port }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
