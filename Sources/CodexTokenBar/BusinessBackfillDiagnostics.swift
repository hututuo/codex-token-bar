import CryptoKit
import Foundation

/// A runtime backfill outlives startup. Keep its own durable attempt and carry
/// that same context through parser workers rather than using a global logger.
/// Ordinary refreshes create no files. Logging failure never changes accounting.
final class BusinessBackfillDiagnostics: @unchecked Sendable {
    private let root: URL
    private let storeIdentity: String
    private let lock = NSLock()
    private var journal: BusinessMigrationDiagnostics?
    private var previousProgress: String?

    init(database: URL) {
        root = database.deletingLastPathComponent().appendingPathComponent("migration-diagnostics", isDirectory: true)
        storeIdentity = Self.identity(database)
    }
    private static func identity(_ url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func active() -> BusinessMigrationDiagnostics? {
        lock.lock(); defer { lock.unlock() }; return journal
    }
    func progress(_ completed: Int, _ total: Int, _ phase: PreciseIndexProgressPhase) {
        lock.lock(); defer { lock.unlock() }
        if journal == nil, phase == .backfillingModel {
            journal = BusinessMigrationDiagnostics(root: root, operation: "exact-runtime-backfill")
            journal?.record("backfill-plan", "started", ["storeIdentity": storeIdentity, "total": String(total)])
        }
        let key = "\(phase.rawValue):\(completed):\(total)"
        guard let journal, key != previousProgress else { return }
        previousProgress = key
        journal.record("backfill-progress", "running", ["phase": phase.rawValue,
            "completed": String(completed), "total": String(total)])
    }
    func source<T>(_ file: URL, work: () throws -> T) throws -> T {
        guard let journal = active() else { return try work() }
        return try journal.perform("parse-source", subject: Self.identity(file), work)
    }
    func finish(generation: Int64, complete: Bool) {
        guard let journal = active() else { return }
        journal.record("backfill-publication", complete ? "succeeded" : "pending", [
            "generation": String(generation), "enrichmentComplete": String(complete)])
        journal.finish()
    }
    func fail(_ error: Error) {
        active()?.finish(error)
    }
}
