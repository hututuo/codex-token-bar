import Foundation

/// One source's bytes of one day (METRICS 10.8).
struct SourceDayTraffic: Equatable, Sendable {
    var split = TrafficSplit.zero
    /// The part of `split` (own and tools) not attributed to an agent tree.
    var unassigned = TrafficBytes.zero
}

/// Everything counted on one local date (METRICS 10.8).
struct TrafficDayTotals: Equatable, Sendable {
    var machine = TrafficBytes.zero
    var machineSampledMs: Int64 = 0
    var sources: [SourceKind: SourceDayTraffic] = [:]
    var processSampledMs: Int64 = 0
    /// Per agent tree, memory only.
    var agents: [String: TrafficSplit] = [:]

    /// The `day_traffic` rows of this day (METRICS 10.9): `machine`, then every source with bytes, in source order.
    func rows(day: String) -> [TrafficDay] {
        var rows = [TrafficDay(day: day, key: TrafficDay.machineKey, rx: machine.rx, tx: machine.tx, sampledMs: machineSampledMs)]
        for source in SourceKind.allCases {
            guard let traffic = sources[source] else { continue }
            rows.append(TrafficDay(
                day: day, key: source.rawValue, rx: traffic.split.own.rx, tx: traffic.split.own.tx,
                rxTools: traffic.split.tools.rx, txTools: traffic.split.tools.tx, sampledMs: processSampledMs))
        }
        return rows
    }

    /// Today's totals restored from stored rows at launch (METRICS 10.8): machine and sources; restored source bytes
    /// count as unassigned since agent values start at zero.
    init(restoring rows: [TrafficDay]) {
        for row in rows {
            if row.isMachine {
                machine = TrafficBytes(rx: row.rx, tx: row.tx)
                machineSampledMs = row.sampledMs
            } else if let source = row.source {
                let split = TrafficSplit(own: TrafficBytes(rx: row.rx, tx: row.tx), tools: TrafficBytes(rx: row.rxTools, tx: row.txTools))
                sources[source] = SourceDayTraffic(split: split, unassigned: split.own + split.tools)
                processSampledMs = max(processSampledMs, row.sampledMs)
            }
        }
    }

    init() {}
}

/// Day totals by local date, labelled in one time zone (METRICS 10.4.6).
struct TrafficLedger {
    private(set) var days: [String: TrafficDayTotals] = [:]
    private var labeler: DayLabeler

    init(timeZone: TimeZone) {
        labeler = DayLabeler(timeZone: timeZone)
    }

    mutating func label(forMs ms: Int64) -> String {
        labeler.label(forMs: ms)
    }

    /// The local midnight of the day `ms` belongs to.
    func dayStart(forMs ms: Int64) -> Date {
        labeler.calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    mutating func modify(_ day: String, _ body: (inout TrafficDayTotals) -> Void) {
        body(&days[day, default: TrafficDayTotals()])
    }

    func totals(_ day: String) -> TrafficDayTotals? { days[day] }

    mutating func restore(_ day: String, rows: [TrafficDay]) {
        days[day] = TrafficDayTotals(restoring: rows)
    }

    mutating func reset(_ day: String) {
        days[day] = TrafficDayTotals()
    }

    /// Forgets every day except `keep`.
    mutating func drop(except keep: Set<String>) {
        days = days.filter { keep.contains($0.key) }
    }

    /// Every day's rows, oldest first (METRICS 10.9).
    var history: [TrafficDay] {
        days.keys.sorted().flatMap { days[$0]!.rows(day: $0) }
    }
}
