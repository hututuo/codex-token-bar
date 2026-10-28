import Foundation
import os

/// Hands snapshots from the background reader to the main actor, coalescing bursts.
///
/// Only the newest snapshot is delivered; events accumulate until the main actor drains them.
final class SnapshotMailbox: Sendable {
    typealias Delivery = @MainActor @Sendable (SpeedSnapshot, [SpeedEvent]) -> Void

    private struct State: Sendable {
        var snapshot: SpeedSnapshot?
        var events: [SpeedEvent] = []
        var scheduled = false
        var closed = false
    }

    private static let maxQueuedEvents = 256

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let delivery: Delivery

    init(delivery: @escaping Delivery) {
        self.delivery = delivery
    }

    func post(_ snapshot: SpeedSnapshot, events: [SpeedEvent] = []) {
        let shouldSchedule = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            var latestSnapshot = snapshot
            if let pendingObservation = state.snapshot?.readObservation {
                latestSnapshot.readObservation = latestSnapshot.readObservation.map {
                    pendingObservation.merged(with: $0)
                } ?? pendingObservation
            }
            state.snapshot = latestSnapshot
            state.events.append(contentsOf: events)
            if state.events.count > Self.maxQueuedEvents {
                state.events.removeFirst(state.events.count - Self.maxQueuedEvents)
            }
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { drain() }
        }
    }

    /// Drops everything posted from now on.
    func close() {
        state.withLock { state in
            state.closed = true
            state.snapshot = nil
            state.events.removeAll()
        }
    }

    @MainActor
    private func drain() {
        let pending = state.withLock { state -> (SpeedSnapshot?, [SpeedEvent]) in
            defer {
                state.snapshot = nil
                state.events.removeAll()
                state.scheduled = false
            }
            return state.closed ? (nil, []) : (state.snapshot, state.events)
        }
        guard let snapshot = pending.0 else { return }
        delivery(snapshot, pending.1)
    }
}
