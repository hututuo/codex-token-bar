import Foundation

/// What the views show of traffic (METRICS 10.5, DESIGN 10): a disabled source is still measured and stored, but every
/// view leaves it out, so it shows no traffic anywhere. This computer's values are never filtered.
public enum TrafficVisibility {
    /// `snapshot` without the sources outside `enabled`: their rates, today's bytes and sparklines, and with them every
    /// sum over sources. The machine series, the sampler state, agents and live reporting's totals are unchanged.
    public static func snapshot(_ snapshot: TrafficSnapshot, enabled: SourceSet) -> TrafficSnapshot {
        let hidden = snapshot.sources.keys.contains { !enabled.contains($0) }
            || snapshot.sourceHistory.keys.contains { !enabled.contains($0) }
        guard hidden else { return snapshot }
        var visible = snapshot
        visible.sources = snapshot.sources.filter { enabled.contains($0.key) }
        visible.sourceHistory = snapshot.sourceHistory.filter { enabled.contains($0.key) }
        return visible
    }

    /// Stored days without the rows of sources outside `enabled`; `machine` rows and unknown keys are kept.
    public static func days(_ days: [TrafficDay], enabled: SourceSet) -> [TrafficDay] {
        guard days.contains(where: { $0.source.map { !enabled.contains($0) } ?? false }) else { return days }
        return days.filter { $0.source.map(enabled.contains) ?? true }
    }
}
