import Foundation

public enum ExecutionModeCSV {
    public static let columns = ["date", "source", "model", "kind", "mode", "evidence", "provider", "requests",
                                 "output_tokens", "measured_output_tokens", "measured_ms", "avg_speed_tok_s"]

    public static func build(_ days: [DailyUsage], kind: ExecutionModeKind? = nil) -> Data {
        var lines = [columns.joined(separator: ",")]
        for day in days.sorted(by: { $0.id < $1.id }) {
            for usage in day.modeBreakdown where kind == nil || usage.attribution.kind == kind {
                let attribution = usage.attribution
                let speed = usage.averageSpeed.map { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? ""
                let row = [day.day, day.source.rawValue, usage.model, attribution.kind.rawValue, attribution.mode,
                           attribution.evidence, attribution.provider ?? "", String(usage.requests), String(usage.output),
                           String(usage.measuredOutput), String(usage.measuredMs), speed]
                lines.append(row.map(field).joined(separator: ","))
            }
        }
        return Data([0xEF, 0xBB, 0xBF]) + Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    private static func field(_ raw: String) -> String {
        let value = raw.first.map { "=+-@\t\r".contains($0) } == true ? "'" + raw : raw
        guard value.contains(where: { ",\"\r\n".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
