import Foundation

/// Drives `SpeedStore` with a scripted sweep through every tier so users can preview the effects.
@MainActor
public final class DemoDriver {
    public private(set) var isRunning = false
    public var onFinish: (() -> Void)?

    private let store: SpeedStore
    private var timer: Timer?
    private var startedAt = Date()
    private var duration: TimeInterval = 20
    private var redline: Double = 400
    private var history: [HistoryPoint] = []
    private var lastHistorySecond = 0
    private var nextPulseAt: TimeInterval = 0
    private var peak: Double = 0
    private var peakAnnounced = false
    private var today = TokenTotals.zero
    private var lastResponse: ResponseSummary?
    private static let estimatedShare = 0.15

    private struct FakeAgent {
        let id: String
        let source: SourceKind
        let project: String
        let model: String
        let isSubagent: Bool
        let weight: Double
    }

    private let agents: [FakeAgent] = [
        FakeAgent(id: "demo-rocket", source: .codex, project: "rocket", model: "gpt-6.1-sol", isSubagent: false, weight: 0.28),
        FakeAgent(id: "demo-nova", source: .claudeCode, project: "nova", model: "claude-opus-5-5", isSubagent: false, weight: 0.26),
        FakeAgent(id: "demo-quasar", source: .deepseek, project: "quasar", model: "deepseek-v4-pro", isSubagent: false, weight: 0.18),
        FakeAgent(id: "demo-nova-sub", source: .claudeCode, project: "nova", model: "claude-sonnet-5-5", isSubagent: true, weight: 0.14),
        FakeAgent(id: "demo-orbit", source: .claudeDesktop, project: "orbit", model: "claude-fable-5-1", isSubagent: false, weight: 0.14),
    ]

    public init(store: SpeedStore) {
        self.store = store
    }

    public func start(redline: Double, duration: TimeInterval = 20) {
        stop()
        self.redline = max(redline, 1)
        self.duration = duration
        startedAt = Date()
        peak = 0
        peakAnnounced = false
        nextPulseAt = 1.6
        today = .zero
        lastResponse = nil
        lastHistorySecond = Int(startedAt.timeIntervalSince1970)
        history = (0..<300).map { offset in
            HistoryPoint(
                time: Date(timeIntervalSince1970: TimeInterval(lastHistorySecond - 300 + offset)),
                measured: .zero,
                estimated: .zero
            )
        }
        isRunning = true
        store.beginPreview()
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        guard isRunning else { return }
        isRunning = false
        store.endPreview()
        onFinish?()
    }

    private func tick() {
        let now = Date()
        let t = now.timeIntervalSince(startedAt)
        guard t < duration else {
            stop()
            return
        }
        let speed = speedCurve(at: t)
        var events: [SpeedEvent] = []

        if speed > peak + 1 {
            peak = speed
        }
        if !peakAnnounced, t > duration * 0.62, speed >= peak - 1, speed > redline {
            peakAnnounced = true
            events.append(.newPeak(speed))
        }
        if speed > 0.5, t >= nextPulseAt {
            let agent = agents[Int(t * 7) % agents.count]
            let output = Int(max(40, speed * Double.random(in: 1.4...3.2)))
            let response = ResponseSummary(
                source: agent.source,
                project: agent.project,
                model: agent.model,
                outputTokens: output,
                totalTokens: output * 24,
                duration: Double(output) / max(speed * agent.weight * 2, 1),
                speed: speed * agent.weight * 2,
                endedAt: now
            )
            lastResponse = response
            today.requests += 1
            today.output += output
            today.input += output * 23
            today.cachedInput += output * 20
            events.append(.responseCompleted(response))
            let heat = min(1, speed / redline)
            nextPulseAt = t + 1.2 - 0.95 * heat + Double.random(in: 0...0.15)
        }

        let second = Int(now.timeIntervalSince1970)
        while lastHistorySecond < second {
            lastHistorySecond += 1
            history.removeFirst()
            history.append(HistoryPoint(
                time: Date(timeIntervalSince1970: TimeInterval(lastHistorySecond)),
                measured: Rate(output: speed * (1 - Self.estimatedShare), total: speed * (1 - Self.estimatedShare) * 24),
                estimated: Rate(output: speed * Self.estimatedShare, total: speed * Self.estimatedShare * 24)
            ))
        }

        store.publishPreview(snapshot(now: now, speed: speed), events: events)
    }

    private func speedCurve(at t: TimeInterval) -> Double {
        let keys: [(TimeInterval, Double)] = [
            (0, 0), (0.08, 0), (0.2, 0.12), (0.35, 0.3), (0.5, 0.6),
            (0.68, 1.3), (0.86, 1.05), (0.97, 0), (1, 0),
        ]
        let p = t / duration
        var value = 0.0
        for index in 1..<keys.count where p <= keys[index].0 {
            let (p0, v0) = keys[index - 1]
            let (p1, v1) = keys[index]
            let x = (p - p0) / max(p1 - p0, 0.0001)
            let eased = x * x * (3 - 2 * x)
            value = v0 + (v1 - v0) * eased
            break
        }
        let wobble = 1 + 0.05 * sin(t * 7.3) + 0.03 * sin(t * 17.1)
        return max(0, value * redline * wobble)
    }

    private func snapshot(now: Date, speed: Double) -> SpeedSnapshot {
        let generating = speed < 0.5 ? 0 : min(agents.count, 1 + Int(speed / (redline * 0.25)))
        let agentStatuses: [AgentStatus] = agents.enumerated().map { index, agent in
            let active = index < generating
            let share = active ? speed * agent.weight / activeWeight(generating) : 0
            return AgentStatus(
                id: agent.id,
                source: agent.source,
                project: agent.project,
                model: agent.model,
                phase: active ? .generating : (speed > 0.5 ? .tools : .idle),
                isSubagent: agent.isSubagent,
                live: Rate(output: share, total: share * 24),
                recentSpeed: active ? share : nil,
                lastActivity: now,
                parentId: agent.isSubagent ? "demo-nova" : nil
            )
        }
        let sourceCount = SourceKind.allCases.count
        let sources: [SourceStatus] = SourceKind.allCases.map { kind in
            let live = agentStatuses.filter { $0.source == kind }.reduce(0) { $0 + $1.live.output }
            return SourceStatus(
                kind: kind,
                enabled: true,
                rootPath: "",
                available: true,
                sessionCount: 12,
                live: Rate(output: live, total: live * 24),
                today: TokenTotals(
                    requests: today.requests / sourceCount,
                    input: today.input / sourceCount,
                    cachedInput: today.cachedInput / sourceCount,
                    output: today.output / sourceCount
                ),
                activeAgents: agentStatuses.filter { $0.source == kind && $0.phase == .generating }.count,
                liveEstimated: Rate(output: live * Self.estimatedShare, total: live * Self.estimatedShare * 24)
            )
        }
        return SpeedSnapshot(
            timestamp: now,
            state: .running,
            live: Rate(output: speed, total: speed * 24),
            liveEstimatedShare: Self.estimatedShare,
            peakToday: Rate(output: peak, total: peak * 24),
            peakTodayAt: peak > 0 ? now : nil,
            averageToday: peak > 0 ? peak * 0.4 : nil,
            today: today,
            sources: sources,
            agents: agentStatuses,
            generatingCount: generating,
            toolsCount: speed > 0.5 ? agents.count - generating : 0,
            history: history,
            lastResponse: lastResponse,
            warnings: [],
            dayStart: Calendar.current.startOfDay(for: now)
        )
    }

    private func activeWeight(_ count: Int) -> Double {
        max(agents.prefix(count).reduce(0) { $0 + $1.weight }, 0.0001)
    }
}
