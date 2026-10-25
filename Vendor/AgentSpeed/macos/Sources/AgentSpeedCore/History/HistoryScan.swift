import Foundation

/// Result of a one-shot daily-history analysis.
public struct HistoryScanReport: Sendable {
    public var days: [DailyUsage]
    public var filesDiscovered: Int
    public var filesAnalyzed: Int
    public var bytesAnalyzed: Int64
    public var sessionsAnalyzed: Int
    public var durationMs: Double
}

/// One-shot daily history (METRICS 8) without scheduling, used by diagnostics such as the probe.
public enum HistoryScan {
    /// Analyses every log of the enabled sources. Without `storePath` everything stays in memory (a full analysis);
    /// with it, the store is reused and updated like the app does.
    /// Costs use `pricing` (default: the bundled table, METRICS 9.7).
    public static func run(
        configuration: MonitorConfiguration = MonitorConfiguration(),
        timeZone: TimeZone = .current,
        storePath: String? = nil,
        pricing: PriceBook = PriceBook()
    ) throws -> HistoryScanReport {
        let database = try storePath.map { try HistoryDatabase(path: $0) } ?? HistoryDatabase.inMemory()
        let analyzer = try HistoryAnalyzer(database: database, pricing: pricing)
        let report = try analyzer.run(configuration: configuration, options: HistoryAnalyzer.Options(timeZone: timeZone))
        return HistoryScanReport(
            days: analyzer.days(sources: configuration.enabledSources),
            filesDiscovered: report.filesDiscovered,
            filesAnalyzed: report.filesAnalyzed,
            bytesAnalyzed: report.bytesAnalyzed,
            sessionsAnalyzed: report.sessionsAnalyzed,
            durationMs: report.durationMs
        )
    }
}
