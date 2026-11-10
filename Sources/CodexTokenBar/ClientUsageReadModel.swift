import Foundation

/// All numeric consumers of the independent multi-client ledger use this
/// response projection. Ingestion, revisions and raw diagnostics keep the
/// physical session-scoped records. Missing resources fail rather than silently
/// reverting to duplicate accounting.
enum ClientUsageReadModel {
    private static let prefix: Result<String, Error> = Result {
        guard let url = AppResources.url(forResource: "client-usage-effective-events", withExtension: "sql") else {
            throw AppResources.Failure.missing("client-usage-effective-events.sql")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func query(_ select: String) throws -> String {
        try prefix.get() + "\n" + select
    }
}
