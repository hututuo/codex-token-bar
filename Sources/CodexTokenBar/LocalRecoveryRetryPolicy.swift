import Foundation

/// Retry advice never grants access. Every attempt re-enters the same storage
/// gate and writer lease; unknown contracts/proof failures require review.
enum LocalRecoveryRetryPolicy {
    static func delay(_ attempt: Int) -> TimeInterval? {
        let delays: [TimeInterval] = [5, 15, 30, 60, 180, 300]
        return delays.indices.contains(attempt) ? delays[attempt] : nil
    }

    static func canRetry(_ error: Error) -> Bool {
        if let pending = error as? PublishedBusinessAdmission.Deferred { return pending.canRetryAutomatically }
        if let sqlite = error as? SQLiteDatabaseError {
            return [5, 6, 10, 13, 14].contains(Int(sqlite.code & 0xff))
        }
        if case BusinessDatabaseMigration.Failure.insufficientSpace = error { return true }
        if case BusinessDatabaseMigration.Failure.runningWriter = error { return true }
        return false
    }
}
