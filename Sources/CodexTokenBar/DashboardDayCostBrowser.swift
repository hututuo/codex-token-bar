import SwiftUI

struct ModelCostDay: Hashable, Sendable {
    let start: Date
    let end: Date
    let timeZone: String
    init(_ date: Date, calendar: Calendar = .current) {
        start = calendar.startOfDay(for: date)
        end = calendar.date(byAdding: .day, value: 1, to: start)!
        timeZone = calendar.timeZone.identifier
    }
    var label: String { start.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) }
}

struct DayModelCostResult: Sendable {
    var codexRows: [ModelTokenBreakdown] = []
    var clientRows: [ClientUsageSummary] = []
    var issues: [String] = []
    var availableClients: Set<String> = []

    static func read(day: ModelCostDay, home: URL?, clients: Set<String>, database: URL) -> Self {
        var result = Self()
        if clients.contains("codex") {
            if let home {
                do {
                    let read = try CodexUsageHistoryIndex.dayExactUsage(codexHome: home, from: day.start, before: day.end)
                    result.codexRows = ModelUsagePresentation.rows(from: read.events)
                    result.availableClients.insert("codex")
                    if read.hasMissingCompaction { result.issues.append("Codex：该日有压缩用量缺失，显示已记录小计") }
                } catch { result.issues.append("Codex 单日记录暂不可读：\(error.localizedDescription)") }
            } else { result.issues.append("Codex 数据源待读取") }
        }
        let external = clients.subtracting(["codex"])
        if !external.isEmpty {
            do {
                let ledger = try MultiClientUsageLedger(url: database, readOnly: true)
                result.clientRows = try ledger.summaries(since: day.start, before: day.end).filter { external.contains($0.client.rawValue) }
                result.availableClients.formUnion(external)
            } catch { result.issues.append("其他客户端单日记录暂不可读：\(error.localizedDescription)") }
        }
        return result
    }
}

/// Day reads are local ledger queries, independent of subscription periods.
struct DashboardDayCostBrowser: View {
    let day: ModelCostDay
    let home: URL?
    let clients: Set<String>
    let refreshKey: String
    @ObservedObject private var palette = SpeedDisplayPreferences.shared
    @State private var result: DayModelCostResult?
    @State private var resultKey: String?
    @State private var resultRequestKey: String?
    @State private var retry = 0
    private var selectionKey: String { "\(day.start.timeIntervalSince1970)|\(day.end.timeIntervalSince1970)|\(day.timeZone)|\(home?.path ?? "")|\(clients.sorted().joined(separator: ","))" }
    private var key: String { "\(selectionKey)|\(refreshKey)|\(retry)" }
    private var visible: DayModelCostResult? { resultKey == selectionKey ? result : nil }
    var body: some View {
        let rows = visible.map { ClientModelCostPeriods.modelItems($0.clientRows, $0.codexRows, allowed: clients) } ?? []
        VStack(alignment: .leading, spacing: 6) {
            DashboardModelCostRow(scope: .constant(.today), todayRows: [], lifetimeRows: [], sevenDayRows: [],
                todayTokens: rows.reduce(0) { $0 + $1.tokens }, lifetimeTokens: 0, sevenDayTokens: 0, sevenDayBoundaryTokens: 0,
                fallbackModel: .gpt56Sol, dataAvailable: visible?.availableClients.isEmpty == false,
                todayModelDisplayState: visible == nil ? .pending : resultRequestKey == key ? .current : .stale, sevenDayDataAvailable: false,
                sevenDayModelDisplayState: .pending, sevenDayEstimateSource: nil,
                clientCosts: .init(lifetime: [], today: rows, sevenDay: []), dayLabel: day.label,
                dayIncomplete: visible?.issues.isEmpty == false)
            if let visible {
                Text("\(day.timeZone) · 所选日期的已记录参考费用").font(.caption).foregroundStyle(.secondary)
                ForEach(visible.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if !visible.issues.isEmpty { Button("重新读取单日") { retry += 1 }.font(.caption) }
                if !visible.availableClients.isEmpty && rows.isEmpty && visible.issues.isEmpty {
                    Text("该日暂无已记录用量 · $0.00").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: key) {
            let requested = key, selection = selectionKey, selectedDay = day, selectedHome = home, selectedClients = clients
            let database = MultiClientUsageStore.defaultDatabaseURL
            let value = await Task.detached(priority: .utility) {
                DayModelCostResult.read(day: selectedDay, home: selectedHome, clients: selectedClients, database: database)
            }.value
            guard !Task.isCancelled, key == requested else { return }
            result = value; resultKey = selection; resultRequestKey = requested
        }
    }
}

struct ModelCostDayCalendar: View {
    @Binding var selection: Date?
    @State private var month = Date()
    private var calendar: Calendar { Calendar.current }
    private var first: Date { calendar.date(from: calendar.dateComponents([.year, .month], from: month))! }
    private var offset: Int { (calendar.component(.weekday, from: first) + 5) % 7 }
    private var count: Int { ((offset + calendar.range(of: .day, in: .month, for: first)!.count + 6) / 7) * 7 }
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button { month = calendar.date(byAdding: .month, value: -1, to: first)! } label: { Image(systemName: "chevron.left") }.accessibilityLabel("单日日历上个月")
                Spacer()
                Text(first.formatted(.dateTime.year().month(.wide))).fontWeight(.medium)
                Spacer()
                Button { month = calendar.date(byAdding: .month, value: 1, to: first)! } label: { Image(systemName: "chevron.right") }
                    .disabled(calendar.isDate(first, equalTo: Date(), toGranularity: .month)).accessibilityLabel("单日日历下个月")
                Button("今天") { month = Date(); selection = calendar.startOfDay(for: Date()) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).foregroundStyle(.secondary) }
                ForEach(0..<count, id: \.self) { index in
                    let date = calendar.date(byAdding: .day, value: index - offset, to: first)!
                    let selected = selection.map { calendar.isDate(date, inSameDayAs: $0) } ?? false
                    Button { selection = date } label: {
                        Text("\(calendar.component(.day, from: date))").frame(maxWidth: .infinity, minHeight: 28)
                            .foregroundStyle(selected ? AppTheme.accentBlue : .primary)
                            .background(selected ? AppTheme.selectedControlBackground : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .opacity(calendar.isDate(date, equalTo: first, toGranularity: .month) ? 1 : 0.4)
                    .disabled(date > calendar.startOfDay(for: Date()))
                    .accessibilityLabel(ModelCostDay(date).label + "的模型金额")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            DatePicker("跳转日期", selection: Binding(get: { selection ?? Date() }, set: { selection = calendar.startOfDay(for: $0); month = $0 }),
                in: ...Date(), displayedComponents: [.date]).datePickerStyle(.field).font(.system(size: 11))
        }.font(.system(size: 11)).buttonStyle(.plain).padding(10)
            .frame(maxWidth: 350).background(AppTheme.solidControlBackground, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain).accessibilityLabel("单日金额日历")
            .onAppear { month = selection ?? Date() }
    }
}
