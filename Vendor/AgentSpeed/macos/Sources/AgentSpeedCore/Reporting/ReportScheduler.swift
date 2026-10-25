import Foundation

/// The report scheduler of METRICS 11.5 on a monotonic millisecond clock. It decides when a window is discarded,
/// when a report is built and when an attempt is sent; the owner builds the bodies, performs the requests and reports
/// each outcome back with `finish`. At most one request is in flight and the outbox holds one report.
public struct ReportScheduler: Sendable {
    public static let holdMs: Int64 = 15_000
    public static let quietMs: Int64 = 600_000
    public static let gapMs: Int64 = 15_000
    public static let retryMs: Int64 = 2_000
    public static let maxBackoffMs: Int64 = 300_000

    public enum Mode: String, Equatable, Sendable { case active, idle, quiet }

    public enum Activity: String, Equatable, Sendable { case active, idle, leaving }

    /// User events of a tick (step 1). `stop` turns reporting off or quits: like `pause`, it sends a leaving report.
    public enum Event: Equatable, Sendable { case pause, resume, networkOff, networkOn, stop }

    public struct Ticket: Equatable, Hashable, Sendable {
        public let seq: Int
        public let activity: Activity
        public let builtAt: Int64
        public let windowMs: Int64
        /// The leaving report of a user action: one attempt, no retry.
        public let single: Bool
    }

    public enum Outcome: Equatable, Sendable {
        /// `2xx`, adopting the `intervalSeconds` of the response when present.
        case delivered(intervalSeconds: Int?)
        /// A network error, a timeout, `3xx`, or `5xx` without `Retry-After`: retried once.
        case transient
        /// `429`, or `503` with `Retry-After` (already clamped to 5 s – 1 h).
        case rateLimited(seconds: Int)
        /// `nonce_replayed`, or `signature_invalid` with a pending key: attempted again at once, once.
        case again
        /// Any other error: lost (the owner applies the reaction of REPORTING 8.3).
        case rejected
    }

    public enum Action: Equatable, Sendable {
        /// Empty the ledger without a report; `beforeIncrements` for the gap rule (METRICS 11.1).
        case discard(beforeIncrements: Bool)
        /// Take the ledger and the instantaneous values into a report body.
        case build(Ticket)
        /// Sign and send the ticket's body (a fresh timestamp and nonce).
        case send(Ticket)
        case delivered(Ticket)
        case lost(Ticket)
    }

    private struct Slot: Sendable {
        var ticket: Ticket
        var attempts = 0
        var nextAt: Int64
        var sending = false
        var againUsed = false
    }

    /// `I`: the discovery interval, or the `intervalSeconds` of the latest success (until the next launch).
    public var intervalMs: Int64 { adoptedIntervalMs ?? limitsIntervalMs }
    /// `H`, never below `I`.
    public var heartbeatMs: Int64 { max(limitsHeartbeatMs, intervalMs) }
    public private(set) var maxAgeMs: Int64
    private var limitsIntervalMs: Int64
    private var limitsHeartbeatMs: Int64
    private var adoptedIntervalMs: Int64?
    public private(set) var seq = 0
    public private(set) var windowStart: Int64?
    public private(set) var mode: Mode = .quiet
    public private(set) var failures = 0
    public private(set) var paused: Bool
    public private(set) var networkOff: Bool
    public private(set) var stopped = false
    /// Nothing is sent before this (backoff).
    public private(set) var backoffUntil: Int64 = .min
    /// Nothing is sent before this (`Retry-After`).
    public private(set) var rateLimitedUntil: Int64 = .min
    private var lastActive: Int64?
    private var previousTick: Int64?
    private var blocked = false
    private var inflight: Slot?
    private var waiting: Ticket?
    /// The random backoff factor in [0.8, 1.2]; the fixtures use 1.
    private let jitter: @Sendable () -> Double

    public init(
        limits: ReportLimits,
        paused: Bool = false,
        networkOff: Bool = false,
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) }
    ) {
        limitsIntervalMs = Int64(limits.intervalSeconds) * 1000
        limitsHeartbeatMs = Int64(limits.heartbeatSeconds) * 1000
        maxAgeMs = Int64(limits.maxAgeSeconds) * 1000
        self.paused = paused
        self.networkOff = networkOff
        self.jitter = jitter
    }

    /// True while a request is in flight or a report waits for it.
    public var isBusy: Bool { inflight != nil || waiting != nil }

    /// The moment the next report is due in the current mode (for the preview's countdown); nil while quiet.
    public var nextDueAt: Int64? {
        guard let windowStart, mode != .quiet else { return nil }
        return windowStart + (mode == .active ? intervalMs : heartbeatMs)
    }

    /// New limits from a refreshed discovery document; a success's `intervalSeconds` still applies on top.
    public mutating func update(limits: ReportLimits) {
        limitsIntervalMs = Int64(limits.intervalSeconds) * 1000
        limitsHeartbeatMs = Int64(limits.heartbeatSeconds) * 1000
        maxAgeMs = Int64(limits.maxAgeSeconds) * 1000
    }

    /// A new run (METRICS 11.5, Run): `seq` restarts and the outbox is emptied; backoff and pauses stay.
    public mutating func startRun() -> [Action] {
        var actions: [Action] = []
        dropOutbox(&actions)
        seq = 0
        windowStart = nil
        lastActive = nil
        mode = .quiet
        stopped = false
        return actions
    }

    /// One engine tick at `t`. `active` is the activity rule of METRICS 11.5; `blocked` covers the readiness the
    /// scheduler does not track (reporting on, confirmed, registered, no error that needs the user).
    public mutating func tick(at t: Int64, active: Bool, blocked: Bool, events: [Event] = []) -> [Action] {
        var actions: [Action] = []
        var leaving = false
        self.blocked = blocked
        for event in events {
            switch event {
            case .pause:
                leaving = leaving || (!paused && !stopped)
                paused = true
            case .resume:
                paused = false
            case .networkOff:
                networkOff = true
                dropOutbox(&actions)
            case .networkOn:
                networkOff = false
            case .stop:
                leaving = leaving || (!paused && !stopped)
                stopped = true
            }
        }
        if let previousTick, t - previousTick > Self.gapMs {
            windowStart = t
            actions.append(.discard(beforeIncrements: true))
        }
        if windowStart == nil { windowStart = t }
        if active { lastActive = t }
        let since = lastActive.map { t - $0 }
        let current: Mode = if let since, since < Self.holdMs { .active } else if let since, since < Self.quietMs { .idle } else { .quiet }
        let previous = mode
        mode = current
        previousTick = t

        if leaving, previous != .quiet, !networkOff, !blocked, t >= rateLimitedUntil {
            if let slot = inflight, !slot.sending {
                fail(slot.ticket, at: t, &actions)
                inflight = nil
            }
            if let waiting {
                actions.append(.lost(waiting))
                self.waiting = nil
            }
            let ticket = build(at: t, .leaving, single: true, &actions)
            if inflight == nil {
                send(Slot(ticket: ticket, nextAt: t), &actions)
            } else {
                waiting = ticket
            }
        }

        guard !paused, !networkOff, !blocked, !stopped, t >= backoffUntil, t >= rateLimitedUntil else {
            windowStart = t
            actions.append(.discard(beforeIncrements: false))
            return actions
        }

        if current == .quiet {
            if previous == .active || previous == .idle {
                let ticket = build(at: t, .leaving, single: false, &actions)
                if let waiting { actions.append(.lost(waiting)) }
                waiting = ticket
            } else {
                windowStart = t
                actions.append(.discard(beforeIncrements: false))
            }
        } else if let windowStart, t - windowStart >= (current == .active ? intervalMs : heartbeatMs) {
            let ticket = build(at: t, current == .active ? .active : .idle, single: false, &actions)
            if let slot = inflight, !slot.sending, slot.nextAt > t {
                fail(slot.ticket, at: t, &actions)
                inflight = nil
            }
            if let waiting { actions.append(.lost(waiting)) }
            waiting = ticket
        }
        deliver(at: t, &actions)
        return actions
    }

    /// The outcome of the attempt of `ticket` that `send` asked for.
    public mutating func finish(_ ticket: Ticket, _ outcome: Outcome, at t: Int64) -> [Action] {
        guard var slot = inflight, slot.ticket == ticket, slot.sending else { return [] }
        var actions: [Action] = []
        slot.sending = false
        slot.attempts += 1
        inflight = nil
        switch outcome {
        case .delivered(let seconds):
            actions.append(.delivered(ticket))
            failures = 0
            if let seconds { adopt(intervalSeconds: seconds) }
        case .rateLimited(let seconds):
            actions.append(.lost(ticket))
            rateLimitedUntil = max(rateLimitedUntil, t + Int64(seconds) * 1000)
        case .again:
            if slot.againUsed {
                fail(ticket, at: t, &actions)
            } else {
                slot.againUsed = true
                slot.attempts -= 1
                send(slot, &actions)
                return actions
            }
        case .transient:
            if !ticket.single, slot.attempts < 2, t + Self.retryMs - ticket.builtAt <= maxAgeMs {
                slot.nextAt = t + Self.retryMs
                inflight = slot
            } else {
                fail(ticket, at: t, &actions)
            }
        case .rejected:
            fail(ticket, at: t, &actions)
        }
        if inflight == nil, waiting != nil, !networkOff, !blocked, t >= backoffUntil, t >= rateLimitedUntil {
            deliver(at: t, &actions)
        }
        return actions
    }

    // MARK: - Steps

    private mutating func build(at t: Int64, _ activity: Activity, single: Bool, _ actions: inout [Action]) -> Ticket {
        seq += 1
        let ticket = Ticket(seq: seq, activity: activity, builtAt: t, windowMs: t - (windowStart ?? t), single: single)
        windowStart = t
        actions.append(.build(ticket))
        return ticket
    }

    private mutating func deliver(at t: Int64, _ actions: inout [Action]) {
        if inflight == nil, let waiting {
            inflight = Slot(ticket: waiting, nextAt: t)
            self.waiting = nil
        }
        guard let slot = inflight, !slot.sending, slot.nextAt <= t else { return }
        if t - slot.ticket.builtAt > maxAgeMs {
            fail(slot.ticket, at: t, &actions)
            inflight = nil
        } else {
            send(slot, &actions)
        }
    }

    private mutating func send(_ slot: Slot, _ actions: inout [Action]) {
        var slot = slot
        slot.sending = true
        inflight = slot
        actions.append(.send(slot.ticket))
    }

    /// A lost report after a failure: counts towards the backoff (METRICS 11.5, Backoff).
    private mutating func fail(_ ticket: Ticket, at t: Int64, _ actions: inout [Action]) {
        actions.append(.lost(ticket))
        failures += 1
        guard failures >= 2 else { return }
        let base = min(Self.maxBackoffMs, 5000 * (Int64(1) << Int64(min(failures - 2, 20))))
        backoffUntil = max(backoffUntil, t + Int64((Double(base) * jitter()).rounded()))
    }

    /// Network off: the waiting and the in-flight report are lost (an attempt already on the wire is abandoned).
    private mutating func dropOutbox(_ actions: inout [Action]) {
        if let slot = inflight { actions.append(.lost(slot.ticket)) }
        if let waiting { actions.append(.lost(waiting)) }
        inflight = nil
        waiting = nil
    }

    private mutating func adopt(intervalSeconds: Int) {
        adoptedIntervalMs = Int64(min(max(intervalSeconds, 5), 300)) * 1000
    }
}
