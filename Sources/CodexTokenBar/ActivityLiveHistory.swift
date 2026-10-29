import Foundation

struct ActivityLivePoint: Equatable, Sendable {
    let time: Double
    let rates: [ModelRateContribution]
    var rate: Double { rates.reduce(0) { $0 + $1.tokensPerSecond } }
}
struct ActivityLiveSeries: Identifiable, Equatable, Sendable {
    let client: String
    let points: [ActivityLivePoint]
    var id: String { client }
}
struct ActivityLiveHistory {
    static let window = 180.0
    static let pointLimit = 2048
    private var rows: [String: [ActivityLivePoint]] = [:]
    mutating func reset(client: String) { rows = rows.filter { !$0.key.hasPrefix(client + "|") } }
    @discardableResult mutating func record(client: String, mode: ActivitySpeedDisplayMode, rates: [ModelRateContribution], at time: Double, available: Bool) -> Bool {
        guard time.isFinite, available else { return false }
        let key = client + "|" + mode.rawValue
        let clean = rates.filter { $0.tokensPerSecond.isFinite && $0.tokensPerSecond > 1e-9 }
        let total = clean.reduce(0) { $0 + $1.tokensPerSecond }
        guard total.isFinite, total > 0 || rows[key] != nil else { return false }
        var points = rows[key] ?? []
        guard points.last.map({ time > $0.time }) ?? true else { return false }
        points.removeAll { $0.time < time - Self.window }
        points.append(.init(time: time, rates: clean))
        if points.count > Self.pointLimit { points.removeFirst(points.count - Self.pointLimit) }
        rows[key] = points
        return true
    }
    func snapshot(allowed: Set<String>, mode: ActivitySpeedDisplayMode, now: Double) -> [ActivityLiveSeries] {
        guard now.isFinite else { return [] }
        return allowed.sorted().compactMap { client in
            // Codex follows the user's display choice; other clients use the
            // Agent Speed estimator, never a fabricated body TPS estimate.
            let selected = client == "codex" ? mode : .agentSpeed
            let points = (rows[client + "|" + selected.rawValue] ?? []).filter { $0.time >= now - Self.window && $0.time <= now }
            return points.isEmpty ? nil : .init(client: client, points: points)
        }
    }
}

/// Shape-preserving interpolation between exact receipts, with no smoothing
/// of measured values and no bridging gaps longer than 3.5 seconds.
enum ActivityLiveConnections {
    struct Point: Equatable { let x: Double; let y: Double }
    struct Segment: Equatable { let start: Point; let first: Point; let second: Point; let end: Point }
    static func runs(_ input: [Point]) -> [[Point]] {
        var result: [[Point]] = []
        var disconnected = false
        for p in input {
            guard p.x.isFinite, p.y.isFinite, p.y >= 0 else { disconnected = true; continue }
            if let last = result.last?.last, !disconnected {
                guard p.x > last.x else { continue }
                if p.x - last.x <= 3.5 { result[result.count - 1].append(p); continue }
            }
            result.append([p]); disconnected = false
        }
        return result
    }
    static func segments(_ points: [Point]) -> [Segment] {
        guard points.count > 1 else { return [] }
        let deltas = zip(points, points.dropFirst()).map { ($1.y - $0.y) / ($1.x - $0.x) }
        let slopes = points.indices.map { i -> Double in
            if i == 0 { return deltas[0] }
            if i == points.count - 1 { return deltas[deltas.count - 1] }
            let a = deltas[i-1], b = deltas[i]
            if a*b <= 0 { return 0 }
            let before = points[i].x - points[i-1].x, after = points[i+1].x - points[i].x
            let w1 = 2*after + before, w2 = after + 2*before
            return (w1+w2)/(w1/a+w2/b)
        }
        return (0..<(points.count-1)).map { i in
            let a = points[i], b = points[i+1], dx = (b.x-a.x)/3
            func clamp(_ value: Double) -> Double { min(max(a.y,b.y), max(min(a.y,b.y),value)) }
            return Segment(start:a, first:.init(x:a.x+dx,y:clamp(a.y+slopes[i]*dx)), second:.init(x:b.x-dx,y:clamp(b.y-slopes[i+1]*dx)), end:b)
        }
    }
}
