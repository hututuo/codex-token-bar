import Foundation

/// Result of a one-shot read of today's transcripts.
public struct TodayScanReport: Sendable {
    public var todayStartMs: Int64
    /// Responses ending today, sorted by end time then key.
    public var responses: [ResponseRecord]
    public var today: TokenTotals
    public var todayBySource: [SourceKind: TokenTotals]
    /// Today's responses whose final usage was never written.
    public var unfinalized: Int
    public var seed: SeedSummary
    public var malformedLines: Int
    public var unreadableFiles: Int
}

/// One-shot seeding without watching, used by diagnostics such as the probe.
public enum TranscriptScan {
    public static func today(
        configuration: MonitorConfiguration = MonitorConfiguration(),
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TodayScanReport {
        let nowMs = Clock.milliseconds(now)
        let todayStartMs = Clock.milliseconds(calendar.startOfDay(for: now))
        let session = TranscriptSession(configuration: configuration)
        let seed = session.seed(todayStartMs: todayStartMs)
        let responses = session.responses
            .filter { $0.endMs >= todayStartMs }
            .sorted { $0.endMs != $1.endMs ? $0.endMs < $1.endMs : $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
        let output = session.advance(nowMs: nowMs, todayStartMs: todayStartMs, emitsEvents: false).output
        return TodayScanReport(
            todayStartMs: todayStartMs,
            responses: responses,
            today: output.today,
            todayBySource: output.todayBySource,
            unfinalized: output.unfinalizedToday,
            seed: seed,
            malformedLines: session.malformedLines,
            unreadableFiles: session.unreadableFileCount
        )
    }
}

enum Clock {
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}
