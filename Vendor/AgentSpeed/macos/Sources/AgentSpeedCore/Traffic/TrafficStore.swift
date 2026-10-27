import Foundation
import Observation

/// The observable traffic hub the UI reads (METRICS 10): the live snapshot and the stored days. Published by
/// `TrafficMonitor` on the main actor; previews publish sample data.
@MainActor
@Observable
public final class TrafficStore {
    public private(set) var snapshot: TrafficSnapshot = .off
    /// Stored days (METRICS 10.9) with today's unsaved part merged in, oldest first.
    public private(set) var days: [TrafficDay] = []
    /// The first local date with a stored sample (`trafficSince`); nil before any.
    public private(set) var since: String?

    public init() {}

    public func publish(_ snapshot: TrafficSnapshot) {
        if self.snapshot != snapshot { self.snapshot = snapshot }
    }

    public func publish(days: [TrafficDay], since: String?) {
        if self.days != days { self.days = days }
        if self.since != since { self.since = since }
    }
}
