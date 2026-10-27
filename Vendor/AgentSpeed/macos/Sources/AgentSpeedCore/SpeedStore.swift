import Foundation
import Observation

/// Single observable hub the UI reads from. Live data and the effects preview both publish here.
@MainActor
@Observable
public final class SpeedStore {
    public private(set) var snapshot: SpeedSnapshot = .empty
    public private(set) var isPreviewing = false

    @ObservationIgnored private var latestLive: SpeedSnapshot = .empty
    @ObservationIgnored private var listeners: [UUID: @MainActor (SpeedEvent) -> Void] = [:]
    @ObservationIgnored private var liveListeners: [UUID: @MainActor (SpeedSnapshot) -> Void] = [:]

    public init() {}

    /// The latest snapshot from `LiveMonitor`, also while a preview is displayed.
    public var liveSnapshot: SpeedSnapshot { latestLive }

    /// Called by `LiveMonitor`. Ignored for display while a preview runs, but always remembered.
    public func publishLive(_ snapshot: SpeedSnapshot, events: [SpeedEvent] = []) {
        latestLive = snapshot
        for handler in liveListeners.values { handler(snapshot) }
        guard !isPreviewing else { return }
        self.snapshot = snapshot
        dispatch(events)
    }

    public func beginPreview() {
        isPreviewing = true
    }

    public func publishPreview(_ snapshot: SpeedSnapshot, events: [SpeedEvent] = []) {
        guard isPreviewing else { return }
        self.snapshot = snapshot
        dispatch(events)
    }

    public func endPreview() {
        guard isPreviewing else { return }
        isPreviewing = false
        snapshot = latestLive
    }

    @discardableResult
    public func addEventListener(_ handler: @escaping @MainActor (SpeedEvent) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = handler
        return token
    }

    public func removeEventListener(_ token: UUID) {
        listeners[token] = nil
    }

    /// Called with every live snapshot (one per engine tick), also while a preview is displayed.
    @discardableResult
    public func addLiveListener(_ handler: @escaping @MainActor (SpeedSnapshot) -> Void) -> UUID {
        let token = UUID()
        liveListeners[token] = handler
        return token
    }

    public func removeLiveListener(_ token: UUID) {
        liveListeners[token] = nil
    }

    private func dispatch(_ events: [SpeedEvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            for handler in listeners.values {
                handler(event)
            }
        }
    }
}
