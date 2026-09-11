import SwiftUI

struct QuotaCycleCalendar: View {
    let cycles: [QuotaActualCycle]
    let selectedID: String?
    let select: (String?) -> Void
    @State private var month = Date()
    private let colors: [Color] = [.blue, .purple, .teal, .orange, .pink]
    private var calendar: Calendar { var value = Calendar.current; value.firstWeekday = 2; return value }
    private var first: Date { calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month }
    private var offset: Int { (calendar.component(.weekday, from: first) + 5) % 7 }
    private var weekCount: Int { (offset + (calendar.range(of: .day, in: .month, for: first)?.count ?? 30) + 6) / 7 }
    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: first) ?? first }
    private func representative(_ boundary: QuotaCycleBoundary?, fallback: Date) -> Date {
        guard let boundary else { return fallback }
        return boundary.earliest.addingTimeInterval(boundary.latest.timeIntervalSince(boundary.earliest) / 2)
    }
    private struct Segment: Identifiable {
        let cycle: QuotaActualCycle
        let index: Int
        let left: Double
        let right: Double
        var id: String { cycle.id }
    }
    private func position(_ date: Date, from start: Date) -> Double {
        let day = calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        let index = calendar.dateComponents([.day], from: start, to: day).day ?? 0
        return max(0, min(7, Double(index) + date.timeIntervalSince(day) / next.timeIntervalSince(day)))
    }
    private func segments(week: Int) -> [Segment] {
        let start = day(week * 7 - offset), end = day(week * 7 - offset + 7)
        return Array(cycles.reversed()).enumerated().compactMap { index, cycle in
            let from = representative(cycle.start, fallback: cycle.firstObservedAt)
            let to = cycle.isCurrent ? Date() : representative(cycle.end, fallback: cycle.lastObservedAt)
            guard from < end, to > start else { return nil }
            let left = position(from, from: start)
            let right = position(to, from: start)
            return Segment(cycle: cycle, index: index, left: left, right: right)
        }
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { month = calendar.date(byAdding: .month, value: -1, to: first) ?? first } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("上个月")
                Text(first.formatted(.dateTime.year().month(.wide))).font(.system(size: 12, weight: .semibold))
                Button { month = calendar.date(byAdding: .month, value: 1, to: first) ?? first } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("下个月")
                Spacer()
                Button("回到本期") { month = Date(); select(nil) }
            }.buttonStyle(.borderless)
            HStack(spacing: 0) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).frame(maxWidth: .infinity).foregroundStyle(.secondary) }
            }
            ForEach(0..<weekCount, id: \.self) { week in
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        ForEach(segments(week: week)) { item in
                            let color = colors[item.index % colors.count]
                            let active = item.id == selectedID
                            Button { select(item.id) } label: {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(color.opacity(active ? 0.38 : 0.2))
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(active ? color : .clear, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .frame(width: max(0, geometry.size.width / 7 * (item.right - item.left)), height: 32)
                            .offset(x: geometry.size.width / 7 * item.left)
                            .accessibilityLabel(item.cycle.isCurrent ? "本期" : "第 \(item.index + 1) 期")
                            .help("点击查看这一期的用量与模型明细")
                        }
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { column in
                                let date = day(week * 7 - offset + column)
                                Text("\(calendar.component(.day, from: date))")
                                    .frame(maxWidth: .infinity)
                                    .opacity(calendar.isDate(date, equalTo: first, toGranularity: .month) ? 1 : 0.3)
                            }
                        }.allowsHitTesting(false)
                    }.frame(height: 32)
                }.frame(height: 32)
            }
            if cycles.isEmpty { Text("暂无周期记录").foregroundStyle(.secondary) }
        }
        .font(.system(size: 10)).padding(12)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)))
        .padding(.horizontal, 12)
    }
}
