import Foundation

enum UsageRefreshCadenceRecoveryScheduler {
    typealias Sleep = @Sendable (_ nanoseconds: UInt64) async throws -> Void

    static func schedule(
        replacing task: inout Task<Void, Never>?,
        after delay: TimeInterval?,
        sleep: @escaping Sleep = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        cancel(&task)
        guard let delay else { return }

        let nanoseconds = sleepNanoseconds(for: delay)
        task = Task { @MainActor in
            do {
                try await sleep(nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    static func cancel(_ task: inout Task<Void, Never>?) {
        task?.cancel()
        task = nil
    }

    private static func sleepNanoseconds(for delay: TimeInterval) -> UInt64 {
        UInt64(max(0.1, delay) * 1_000_000_000)
    }
}
