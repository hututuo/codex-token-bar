import Foundation

/// The same immutable daily model rows are used by the floating card, its
/// accessibility label, pagination and sidebar. Rate ticks do not change them.
/// Keep only four exact-input projections, never an unbounded per-source map.
final class FloatingModelUsageCache: @unchecked Sendable {
    struct Key: Equatable {
        let rows: [ModelTokenBreakdown]
        let fallbackModel: OfficialAPIPriceModel
        let showPlaceholders: Bool
        let mergeAutoReview: Bool
        var paletteVersion: Int = SpeedColorOverrides.shared.version
    }
    private struct Entry {
        let key: Key
        let items: [FloatingTodayModelUsageItem]
    }
    private let lock = NSLock()
    private let capacity: Int
    private var entries: [Entry] = []

    init(capacity: Int = 4) { self.capacity = max(1, capacity) }

    func value(for key: Key, make: () -> [FloatingTodayModelUsageItem]) -> [FloatingTodayModelUsageItem] {
        lock.lock()
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            lock.unlock()
            return entry.items
        }
        lock.unlock()
        // Do not make the UI wait on another caller's cost calculation.
        // Concurrent misses may compute twice; either exact result is valid.
        let items = make()
        lock.lock()
        entries.removeAll { $0.key == key }
        entries.append(Entry(key: key, items: items))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        lock.unlock()
        return items
    }
}
