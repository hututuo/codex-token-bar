import AgentSpeedCore
import Foundation
import XCTest
@testable import CodexTokenBar

/// Public traffic is gated and has zero usage. Does not touch production consent,
/// device identity or monitor; each probe owns and removes its own registration.
@MainActor
final class AgentSpeedLatencyProbeTests: XCTestCase {
    func testExplicitProductionLatencyBreakdown() async throws {
        guard let output = ProcessInfo.processInfo.environment["CODEX_SPEED_LATENCY_OUTPUT"] else {
            throw XCTSkip("Explicit opt-in required for public zero-usage latency measurements")
        }
        let service = try ReportServiceURL.parse(AgentSpeedReportingController.serviceURL).get()
        let api = ReportAPI(transport: URLSessionReportTransport(), userAgent: AgentSpeedReportingController.userAgent)
        guard case .document(let document, _) = await api.discover(service),
              AgentSpeedReportingController.accepts(document), let config = document.websocket else {
            return XCTFail("Approved production discovery unavailable")
        }
        let id = ReportCanonical.newUUID(), name = "TokenBar-Latency-" + UUID().uuidString.prefix(6)
        let signer = try AgentSpeedReportingIdentity.signer(deviceID: id)
        let builder = ReportRequestBuilder(userAgent: AgentSpeedReportingController.userAgent, deviceId: id, apiKey: nil)
        let registration = ReportDocuments.registration(deviceId: id, username: name, publicKey: signer.publicKey,
                                                       client: AgentSpeedReportingController.client)
        let registrationRequest = try builder.make(method: "POST", url: document.api.appending(endpoint: ReportEndpoint.devices),
            body: registration, signer: signer, timestamp: AgentSpeedReportingController.nowMS / 1000)
        guard case .success(let registered) = await api.call(registrationRequest), registered.isSuccess,
              registered.deviceId == id, registered.username == name else { return XCTFail("Probe registration rejected") }
        let socket = AgentSpeedWebSocket(api: document.api, config: config) { method, url, body in
            try builder.make(method: method, url: url, body: body, signer: signer,
                             timestamp: Int64(Date().timeIntervalSince1970))
        }
        defer { socket.stop() }
        var timings: [SpeedSocketTiming] = [], pings: [Int64] = [], terminal = "", status = ""
        socket.onTerminal = { terminal = $0 }; socket.onStatus = { status = $0 }
        socket.onAccepted = { if let timing = socket.ledger.lastTiming { timings.append(timing) } }
        socket.start()
        for _ in 0..<1500 where !socket.ready && terminal.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let connectionReady = socket.ready
        var error = "", attempted = 0, previousBuild: Int64?
        if connectionReady {
            for seq in 1...31 {
                guard socket.ready, terminal.isEmpty else { break }
                do {
                    if seq % 3 == 1 { pings.append(try await socket.pingRoundTripMs()) }
                    if let previousBuild {
                        let remaining = Int64(config.minIntervalMs) - (AgentSpeedWebSocket.tick - previousBuild)
                        if remaining > 0 { try await Task.sleep(for: .milliseconds(remaining)) }
                    }
                    let sample = ReportSample()
                    var window = ReportWindow(sample)
                    let envelope = ReportEnvelope(client: AgentSpeedReportingController.client, deviceId: id, username: name,
                        runId: socket.runID, seq: seq, sentAtMs: AgentSpeedReportingController.nowMS,
                        windowMs: max(Int64(config.minIntervalMs), previousBuild.map { AgentSpeedWebSocket.tick - $0 } ?? 50),
                        activity: .idle, titleLevel: 0)
                    let fitted = ReportBody.fitted(envelope, window.take(sample), sample, .init(sections: []))
                    guard case .object(var fields) = fitted.json else { throw ProbeError.encoding }
                    fields.append(.init("realtime", .object(["sourceMode": .string("unknown"), "observedAt": .null,
                        "observationAgeMs": .null, "sourceResolutionMs": .null])))
                    previousBuild = AgentSpeedWebSocket.tick
                    attempted += 1
                    socket.submit(body: ReportJSON.object(fields).compactData, seq: seq)
                    let deadline = AgentSpeedWebSocket.tick + Int64(config.ackTimeoutMs) + 1000
                    while timings.last?.sequence != seq && socket.ready && terminal.isEmpty && AgentSpeedWebSocket.tick < deadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    if timings.last?.sequence != seq { error = "ACK missing for sequence \(seq)"; break }
                } catch let failure { error = String(describing: failure); break }
            }
        }
        let counters = socket.ledger.counters
        socket.stop()
        let cleanup = try builder.make(method: "DELETE", url: document.api.appending(endpoint: ReportEndpoint.device(id)),
            body: Data(), signer: signer, timestamp: AgentSpeedReportingController.nowMS / 1000)
        let cleanupResult = await api.call(cleanup)
        let cleanupStatus: Int
        if case .success(let reply) = cleanupResult { cleanupStatus = reply.status } else { cleanupStatus = 0 }
        func summary(_ values: [Int64]) -> [String: Any] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return ["count": 0] }
            func p(_ q: Double) -> Int64 { sorted[max(0, Int(ceil(q * Double(sorted.count))) - 1)] }
            return ["count": sorted.count, "minMs": sorted[0], "p50Ms": p(0.5), "p95Ms": p(0.95), "maxMs": sorted.last!]
        }
        let warm = Array(timings.dropFirst())
        let record: [String: Any] = [
            "measuredAt": ISO8601DateFormatter().string(from: Date()), "platform": "macOS", "clientApp": "CodexTokenBar",
            "registration": true, "connectionReady": connectionReady, "attemptedReports": attempted,
            "acceptedReports": timings.count, "zeroUsage": true, "productionPreferencesChanged": false,
            "socketCounters": ["built": counters.built, "accepted": counters.accepted, "duplicate": counters.duplicate,
                "dropped": counters.dropped, "timedOut": counters.timedOut, "rejected": counters.rejected, "unknown": counters.unknown],
            "productionDeviceReused": false, "cleanupHTTPStatus": cleanupStatus, "error": error, "terminal": terminal,
            "lastStatus": status, "pingRoundTrip": summary(pings), "pingSamplesMs": pings,
            "warmBuildToAck": summary(warm.map(\.buildToAckMs)),
            "warmSigningAndScheduling": summary(warm.map(\.signingAndSchedulingMs)),
            "warmPacking": summary(warm.map(\.packingMs)), "warmSendToAck": summary(warm.map(\.sendToAckMs)),
            "warmServerProcessing": summary(warm.map(\.serverProcessingMs)),
            "samples": timings.map { ["sequence": $0.sequence, "buildToAckMs": $0.buildToAckMs,
                "signingAndSchedulingMs": $0.signingAndSchedulingMs, "packingMs": $0.packingMs,
                "sendToAckMs": $0.sendToAckMs, "serverProcessingMs": $0.serverProcessingMs] },
            "limits": ["smallSample": true, "sourceObservationNotMeasured": true, "browserNotMeasured": true,
                       "crossMachineClocksNotCalibrated": true, "formalTenMinuteBenchmark": false]
        ]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
        XCTAssertTrue(connectionReady, terminal.isEmpty ? status : terminal)
        XCTAssertEqual(timings.count, 31, error)
        XCTAssertTrue([200,202,204,404].contains(cleanupStatus), "Probe device cleanup not confirmed")
    }
    private enum ProbeError: Error { case encoding }
}
