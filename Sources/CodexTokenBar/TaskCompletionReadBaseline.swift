import Foundation

struct TaskCompletionReadBaseline: Codable, Equatable, Sendable {
    private var acknowledgedUnreadThreadIDs: Set<String> = []
    private var acknowledgedCompletedEventIDs: Set<String> = []

    mutating func activeUnreadThreadIDs(
        from threadIDs: Set<String>,
        reactivatedBy completedThreadIDs: Set<String> = []
    ) -> Set<String> {
        acknowledgedUnreadThreadIDs.formIntersection(threadIDs)
        acknowledgedUnreadThreadIDs.subtract(completedThreadIDs)
        return threadIDs.subtracting(acknowledgedUnreadThreadIDs)
    }

    func activeCompletedTaskThreadIDs(from completedTaskThreadIDs: [String: String]) -> [String: String] {
        completedTaskThreadIDs.filter { eventID, _ in
            !acknowledgedCompletedEventIDs.contains(eventID)
        }
    }

    mutating func markAllRead(unreadThreadIDs: Set<String>, completedEventIDs: Set<String>) {
        acknowledgedUnreadThreadIDs.formUnion(unreadThreadIDs)
        acknowledgedCompletedEventIDs.formUnion(completedEventIDs)
    }
}

enum TaskCompletionReadBaselineStore {
    private static let key = "TaskCompletionMonitor.readBaselineByCodexHome.v1"

    static func load(
        codexHomePath: String?,
        defaults: UserDefaults = .standard
    ) -> TaskCompletionReadBaseline {
        guard let codexHomePath, !codexHomePath.isEmpty else {
            return TaskCompletionReadBaseline()
        }
        return allBaselines(defaults: defaults)[codexHomePath] ?? TaskCompletionReadBaseline()
    }

    static func save(
        _ baseline: TaskCompletionReadBaseline,
        codexHomePath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let codexHomePath, !codexHomePath.isEmpty else { return }
        var baselines = allBaselines(defaults: defaults)
        baselines[codexHomePath] = baseline
        guard let data = try? JSONEncoder().encode(baselines) else { return }
        defaults.set(data, forKey: key)
    }

    private static func allBaselines(defaults: UserDefaults) -> [String: TaskCompletionReadBaseline] {
        guard let data = defaults.data(forKey: key),
              let baselines = try? JSONDecoder().decode([String: TaskCompletionReadBaseline].self, from: data) else {
            return [:]
        }
        return baselines
    }
}
