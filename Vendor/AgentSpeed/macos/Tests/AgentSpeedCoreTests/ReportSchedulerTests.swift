import Foundation
import Testing
@testable import AgentSpeedCore

/// METRICS 11.5 against report-vectors.json `scheduler`: the same timelines the Python simulator replays, with
/// instant sends and scripted outcomes.
@Suite struct ReportSchedulerTests {
    struct Result: Equatable {
        var delivered: [[String]] = []
        var lost: [Int] = []
    }

    /// Runs one case like `simulate_scheduler`: every 500 ms tick, increments into a ledger, outcomes per seq.
    static func simulate(_ item: [String: Any]) throws -> Result {
        let config = item["config"] as? [String: Int] ?? [:]
        let limits = ReportLimits(intervalSeconds: config["intervalSeconds"] ?? 5, heartbeatSeconds: config["heartbeatSeconds"] ?? 60,
                                  maxAgeSeconds: config["maxAgeSeconds"] ?? 30)
        var scheduler = ReportScheduler(limits: limits, jitter: { 1 })
        var increments: [Int64: Int64] = [:]
        for spec in item["increments"] as? [[String: Int]] ?? [] {
            for t in stride(from: spec["from"]!, through: spec["to"]!, by: spec["step"]!) {
                increments[Int64(t), default: 0] += Int64(spec["output"]!)
            }
        }
        var events: [Int64: [ReportScheduler.Event]] = [:]
        for pair in item["events"] as? [[Any]] ?? [] {
            let t = Int64(pair[0] as! Int)
            let event: ReportScheduler.Event = switch pair[1] as! String {
            case "pause": .pause
            case "resume": .resume
            case "networkOff": .networkOff
            default: .networkOn
            }
            events[t, default: []].append(event)
        }
        let outcomes = (item["outcomes"] as? [String: [String]] ?? [:]).reduce(into: [Int: [String]]()) { $0[Int($1.key)!] = $1.value }
        let activity = (item["activity"] as? [[Int]] ?? []).map { Int64($0[0])...Int64($0[1]) }
        var attempts: [Int: Int] = [:]
        var outputs: [Int: Int64] = [:]
        var ledger: Int64 = 0
        var result = Result()

        func outcome(_ ticket: ReportScheduler.Ticket) -> ReportScheduler.Outcome {
            let queue = outcomes[ticket.seq] ?? []
            let index = attempts[ticket.seq, default: 0]
            attempts[ticket.seq] = index + 1
            let name = index < queue.count ? queue[index] : "ok"
            if name == "ok" { return .delivered(intervalSeconds: nil) }
            if name.hasPrefix("rateLimited:") { return .rateLimited(seconds: Int(name.dropFirst(12))!) }
            return .transient
        }

        func apply(_ actions: [ReportScheduler.Action], at t: Int64) {
            for action in actions {
                switch action {
                case .discard(let before):
                    if !before { ledger = 0 }
                case .build(let ticket):
                    outputs[ticket.seq] = ledger
                    ledger = 0
                case .send(let ticket):
                    apply(scheduler.finish(ticket, outcome(ticket), at: t), at: t)
                case .delivered(let ticket):
                    result.delivered.append([String(ticket.seq), String(ticket.builtAt), String(ticket.windowMs),
                                             ticket.activity.rawValue, String(outputs[ticket.seq] ?? -1)])
                case .lost(let ticket):
                    result.lost.append(ticket.seq)
                }
            }
        }

        for range in try #require(item["ticks"] as? [[Int]]) {
            for t in stride(from: Int64(range[0]), through: Int64(range[1]), by: 500) {
                let active = activity.contains { $0.contains(t) }
                var gapped = false
                let actions = scheduler.tick(at: t, active: active, blocked: false, events: events[t] ?? [])
                if actions.contains(.discard(beforeIncrements: true)) { gapped = true }
                if gapped { ledger = 0 }
                ledger += increments[t] ?? 0
                apply(actions.filter { $0 != .discard(beforeIncrements: true) }, at: t)
            }
        }
        result.lost.sort()
        return result
    }

    @Test func vectorTimelines() throws {
        let vectors = try Fixtures.json("report-vectors.json")
        let cases = try #require(vectors["scheduler"] as? [[String: Any]])
        #expect(cases.count == 11)
        for item in cases {
            let expect = try #require(item["expect"] as? [String: Any])
            let delivered = (expect["delivered"] as? [[Any]] ?? []).map { row in row.map { "\($0)" } }
            let lost = expect["lost"] as? [Int] ?? []
            let got = try Self.simulate(item)
            #expect(got.delivered == delivered, "\(item["name"] ?? "")")
            #expect(got.lost == lost, "\(item["name"] ?? "") lost")
        }
    }

    /// Rate guarantees: consecutive built reports at least `I` apart except leaving; nothing while blocked.
    @Test func blockedSendsNothing() {
        var scheduler = ReportScheduler(limits: .standard, jitter: { 1 })
        var sends = 0
        for t in stride(from: Int64(0), through: 60_000, by: 500) {
            for action in scheduler.tick(at: t, active: true, blocked: true) {
                if case .send = action { sends += 1 }
            }
        }
        #expect(sends == 0)
        #expect(scheduler.seq == 0)
    }

    /// An attempt still on the wire is never doubled: the next due report waits and replaces older waiting ones.
    @Test func oneRequestInFlight() {
        var scheduler = ReportScheduler(limits: .standard, jitter: { 1 })
        var inFlight: [ReportScheduler.Ticket] = []
        var lost: [Int] = []
        for t in stride(from: Int64(0), through: 19_500, by: 500) {
            for action in scheduler.tick(at: t, active: true, blocked: false) {
                switch action {
                case .send(let ticket): inFlight.append(ticket)
                case .lost(let ticket): lost.append(ticket.seq)
                default: break
                }
            }
        }
        #expect(inFlight.map(\.seq) == [1])
        #expect(lost == [2])
        let actions = scheduler.finish(inFlight[0], .delivered(intervalSeconds: 10), at: 19_500)
        #expect(actions.contains(.delivered(inFlight[0])))
        #expect(actions.contains { if case .send(let ticket) = $0 { ticket.seq == 3 } else { false } })
        #expect(scheduler.intervalMs == 10_000)
    }

    /// A user's pause sends one leaving report with a single attempt; turning off does the same.
    @Test func leavingIsSingleAttempt() {
        var scheduler = ReportScheduler(limits: .standard, jitter: { 1 })
        var sent: [ReportScheduler.Ticket] = []
        for t in stride(from: Int64(0), through: 6_000, by: 500) {
            for case .send(let ticket) in scheduler.tick(at: t, active: true, blocked: false) {
                sent.append(ticket)
                _ = scheduler.finish(ticket, .delivered(intervalSeconds: nil), at: t)
            }
        }
        let actions = scheduler.tick(at: 6_500, active: true, blocked: false, events: [.stop])
        guard let leaving = actions.compactMap({ if case .send(let ticket) = $0 { ticket } else { nil } }).first else {
            Issue.record("no leaving attempt")
            return
        }
        #expect(leaving.activity == .leaving && leaving.single)
        let after = scheduler.finish(leaving, .transient, at: 6_500)
        #expect(after == [.lost(leaving)])
        #expect(scheduler.tick(at: 7_000, active: true, blocked: false).allSatisfy { $0 == .discard(beforeIncrements: false) })
    }

    @Test func nonceReplayedIsAttemptedAgainOnce() {
        var scheduler = ReportScheduler(limits: .standard, jitter: { 1 })
        var ticket: ReportScheduler.Ticket?
        for t in stride(from: Int64(0), through: 5_000, by: 500) {
            for case .send(let sent) in scheduler.tick(at: t, active: true, blocked: false) { ticket = sent }
        }
        guard let ticket else {
            Issue.record("no attempt")
            return
        }
        #expect(scheduler.finish(ticket, .again, at: 5_000) == [.send(ticket)])
        #expect(scheduler.finish(ticket, .again, at: 5_000) == [.lost(ticket)])
    }

    @Test func outcomesFollowTheReactionTable() {
        func classify(_ status: Int, _ code: String?, headers: [String: String] = [:], pending: Bool = false)
            -> (ReportScheduler.Outcome, ReportReaction) {
            var body = Data()
            if let code { body = Data("{\"error\":{\"code\":\"\(code)\",\"serverTime\":1792656931}}".utf8) }
            return ReportOutcome.classify(.success(ReportReply.parse(status: status, headers: headers, body: body)),
                                          hasPendingKey: pending)
        }
        #expect(classify(200, nil).0 == .delivered(intervalSeconds: nil))
        #expect(classify(503, nil).0 == .transient)
        #expect(classify(503, nil, headers: ["Retry-After": "2"]).0 == .rateLimited(seconds: 5))
        #expect(classify(429, "rate_limited").0 == .rateLimited(seconds: 60))
        #expect(classify(429, "rate_limited", headers: ["retry-after": "7200"]).0 == .rateLimited(seconds: 3600))
        #expect(classify(302, nil).0 == .transient)
        #expect(classify(401, "timestamp_out_of_window").1 == .correctClock(serverTime: 1_792_656_931))
        #expect(classify(401, "nonce_replayed").0 == .again)
        #expect(classify(401, "signature_invalid").1 == .recheckRegistration)
        #expect(classify(401, "signature_invalid", pending: true) == (.again, .usePendingKey))
        #expect(classify(401, "api_key_required").1 == .needsUser(.apiKey))
        #expect(classify(404, "unknown_device").1 == .reRegister)
        #expect(classify(404, nil).1 == .strike(misconfigured: true))
        #expect(classify(409, "seq_conflict").1 == .newRun)
        #expect(classify(409, "device_conflict").1 == .needsUser(.keyMismatch))
        #expect(classify(410, nil).1 == .needsUser(.gone))
        #expect(classify(400, "version_unsupported").1 == .refreshDiscovery(upgrade: true))
        #expect(classify(413, nil).1 == .refreshDiscovery(upgrade: false))
        #expect(classify(422, "payload_invalid").1 == .strike(misconfigured: false))
        #expect(classify(418, "teapot_mode").1 == .strike(misconfigured: false))
        #expect(classify(422, "report_stale").1 == .none)
        #expect(ReportOutcome.classify(.failure(.timeout), hasPendingKey: false).0 == .transient)
    }

    @Test func retryAfterAcceptsHTTPDates() {
        let now = Date(timeIntervalSince1970: 1_792_656_931)
        #expect(ReportReply.retryAfter("20", now: now) == 20)
        #expect(ReportReply.retryAfter("Thu, 22 Oct 2026 08:16:31 GMT", now: now) == 60)
        #expect(ReportReply.retryAfter("soon", now: now) == nil)
    }
}
