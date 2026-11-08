import SwiftUI

/// One cell is one running main task or subagent. Missing model facts retain
/// their count in gray; missing source observations never become a fresh zero.
struct SidebarTaskMeterPresentation: Equatable {
    static let capacity = 10
    static let separator: CGFloat = 0.6
    let cells: [String?] // Bottom to top; nil is an unoccupied cell.
    let freshness: RunningThreadFreshness
    let label: String

    init(summary: RunningThreadSummary) {
        freshness = summary.freshness
        let hasCounts = summary.freshness == .fresh || summary.freshness == .stale
        let total = hasCounts ? summary.total : 0
        var counts: [String: Int] = [:]
        for row in summary.mainModels + summary.subagentModels where row.count > 0 {
            counts[ModelUsagePresentation.key(for: row.model), default: 0] += row.count
        }
        let keys = counts.keys.sorted { $0 == "unknown" ? false : $1 == "unknown" ? true : $0 < $1 }
        var remaining = total
        var occupied: [String] = []
        var details: [String] = []
        for key in keys {
            let count = min(remaining, counts[key] ?? 0)
            guard count > 0 else { continue }
            remaining -= count
            occupied += Array(repeating: key, count: min(count, Self.capacity - occupied.count))
            details.append("\(ModelUsagePresentation.label(for: key)) ×\(count)")
        }
        if remaining > 0 {
            occupied += Array(repeating: "unknown", count: min(remaining, Self.capacity - occupied.count))
            details.append("模型同步中 ×\(remaining)")
        }
        cells = occupied.map(Optional.some) + Array(repeating: nil, count: Self.capacity - occupied.count)
        if !hasCounts {
            label = summary.freshness == .loading ? "运行任务：正在读取" : "运行任务：状态未知"
        } else {
            let state = summary.freshness == .stale ? "；上次数据，已过期" : ""
            let overflow = total > Self.capacity ? "；超过 10 个，亮条已满" : ""
            label = "运行任务：\(total) 个（主 \(summary.main) · 子 \(summary.subagents)）；每格 1 个"
                + (details.isEmpty ? "" : "；" + details.joined(separator: "、")) + overflow + state
        }
    }

    func color(at index: Int) -> Color {
        guard let model = cells[index] else { return .white.opacity(0.12) }
        if freshness == .stale { return Color(red: 0.48, green: 0.53, blue: 0.59).opacity(0.55) }
        return ModelUsagePresentation.color(for: model)
    }

    var morphSegments: [ClientQuotaMorphColorSegment] {
        cells.indices.map { index in
            .init(id: "cell-\(index)", start: Double(index) / 10, end: Double(index + 1) / 10,
                  color: NSColor(color(at: index)))
        }
    }
}

struct SidebarTaskMeter: View {
    let presentation: SidebarTaskMeterPresentation
    var ring = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(0..<SidebarTaskMeterPresentation.capacity, id: \.self) { index in
                    if ring {
                        Circle().trim(from: Double(index) / 10 + 0.004, to: Double(index + 1) / 10 - 0.004)
                            .stroke(presentation.color(at: index), style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                            .rotationEffect(.degrees(-90))
                    } else {
                        Rectangle().fill(presentation.color(at: index))
                            .frame(height: max(0, proxy.size.height / 10 - SidebarTaskMeterPresentation.separator))
                            .position(x: proxy.size.width / 2, y: proxy.size.height * (1 - (Double(index) + 0.5) / 10))
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: presentation)
        .accessibilityHidden(true)
    }
}
