import AppKit
import QuartzCore

/// Opt-in candidate-only timing. No sampling timer, network or user contents.
@MainActor enum SidebarMotionProbe {
#if DEBUG
    private static let output: String? = Bundle.main.bundleIdentifier == "local.codex.token-bar.multiclient-preview"
        ? ProcessInfo.processInfo.environment["TOKENBAR_PREVIEW_PERF_LOG"] : nil
    private struct Pass {
        let kind: String
        let started: Double
        let duration: Double
        var first: Double?
        var previous: Double?
        var gaps: [Double] = []
        var ticks: [Double] = []
        var budget = 0.0
        var work: [String: [Double]] = [:]
    }
    private static var pass: Pass?
    static func begin(_ kind: String, duration: Double) {
        guard output != nil else { return }
        finish()
        pass = Pass(kind: kind, started: CACurrentMediaTime(), duration: duration)
    }
    static func stamp() -> Double? { pass == nil ? nil : CACurrentMediaTime() }
    static func elapsed(_ stamp: Double?, _ category: String) {
        guard let stamp, pass != nil else { return }
        pass?.work[category, default: []].append((CACurrentMediaTime() - stamp) * 1000)
    }
    static func tick(_ now: Double, work: Double, budget: Double) {
        guard pass != nil else { return }
        if pass?.first == nil { pass?.first = now }
        if let previous = pass?.previous { pass?.gaps.append((now - previous) * 1000) }
        pass?.previous = now; pass?.ticks.append(work); pass?.budget = budget * 1000
    }
    static func finish() {
        guard let current = pass, let output else { return }
        pass = nil
        func summary(_ values: [Double]) -> [String: Any] {
            let sorted = values.sorted()
            return ["count": sorted.count, "totalMs": sorted.reduce(0, +), "maxMs": sorted.last ?? 0,
                    "p95Ms": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]]
        }
        let result: [String: Any] = ["kind": current.kind, "durationMs": current.duration * 1000,
            "elapsedMs": (CACurrentMediaTime() - current.started) * 1000,
            "firstTickDelayMs": ((current.first ?? current.started) - current.started) * 1000,
            "frameBudgetMs": current.budget, "frameGaps": summary(current.gaps), "tickWork": summary(current.ticks),
            "lateGaps": current.gaps.filter { $0 > current.budget * 1.8 }.count,
            "work": current.work.mapValues(summary)]
        guard var data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return }
        data.append(10)
        if let file = FileHandle(forWritingAtPath: output) {
            defer { try? file.close() }
            _ = try? file.seekToEnd(); try? file.write(contentsOf: data)
        } else { try? data.write(to: URL(fileURLWithPath: output)) }
    }
#else
    static func begin(_ kind: String, duration: Double) {}
    static func stamp() -> Double? { nil }
    static func elapsed(_ stamp: Double?, _ category: String) {}
    static func tick(_ now: Double, work: Double, budget: Double) {}
    static func finish() {}
#endif
}
