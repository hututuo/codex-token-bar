import SwiftUI

/// A single tile per module. All values are supplied by the existing sidebar
/// projection, so hovering never starts a reader, poller or network request.
struct QuotaSidebarCompactRail: View {
    let items: [QuotaSidebarItem]
    let quotas: [ClientQuotaItem]
    let rateFraction: Double?
    let rateText: String
    let tpsText: String
    let summary: RunningThreadSummary
    let shares: [FloatingTodayModelUsageItem]
    let radarActive: Bool
    let colors: [String: String]
    let hovered: QuotaSidebarItem?
    let onHover: (QuotaSidebarItem) -> Void
    let onOpen: (QuotaSidebarItem) -> Void

    static func section(_ item: QuotaSidebarItem) -> Int {
        switch item {
        case .speed, .tps, .tasks: 0
        case .quota: 1
        case .models: 2
        default: 3
        }
    }

    static func height(_ items: [QuotaSidebarItem], available: Double) -> Double {
        let rows = items.filter(\.hasCompactRepresentation)
        let separators = rows.indices.dropFirst().filter { section(rows[$0 - 1]) != section(rows[$0]) }.count
        return min(max(40, available), Double(rows.count * 34 + separators * 11 + 24))
    }

    var body: some View {
        let rows = items.filter(\.hasCompactRepresentation)
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                if index > 0, Self.section(rows[index - 1]) != Self.section(item) {
                    Rectangle().fill(.white.opacity(0.16)).frame(width: 12, height: 1)
                        .padding(.vertical, 5)
                }
                Button { onOpen(item) } label: {
                    glyph(item)
                        .frame(width: 24, height: 30)
                        .background(.white.opacity(hovered == item ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 8))
                        .frame(width: QuotaSidebarLayout.compactWidth, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { onHover(item) } }
                .accessibilityLabel(label(item))
                .accessibilityIdentifier("quota-sidebar-compact-" + item.id)
            }
        }
        .padding(.vertical, 12)
        .frame(width: QuotaSidebarLayout.compactWidth)
    }

    @ViewBuilder private func glyph(_ item: QuotaSidebarItem) -> some View {
        switch item {
        case let .quota(client):
            let values = QuotaSidebarContentOrder.quotaWindows(quotas, client: client)
            ZStack {
                ForEach(Array(values.enumerated()), id: \.element.id) { index, quota in
                    let count = max(1, values.count)
                    let start = Double(index) / Double(count) + 0.025
                    let end = Double(index + 1) / Double(count) - 0.025
                    let fraction = quota.remaining.map { min(1, max(0, $0 / 100)) }
                    Circle().trim(from: start, to: end)
                        .stroke(.white.opacity(0.14), style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
                    if let fraction, fraction > 0 {
                        Circle().trim(from: start, to: start + (end - start) * fraction)
                            .stroke(tint(quota), style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
                    }
                }
                Circle().fill(Color(nsColor: NSColor(clientHex: ClientBrand.hex(client))))
                    .frame(width: 4, height: 4)
            }.rotationEffect(.degrees(-90)).frame(width: 18, height: 18)
        case .speed:
            ZStack {
                Circle().trim(from: 0.10, to: 0.90).stroke(.white.opacity(0.15), lineWidth: 2)
                Circle().trim(from: 0.10, to: 0.10 + 0.80 * min(1, max(0, rateFraction ?? 0)))
                    .stroke(Color(red: 0.47, green: 0.72, blue: 1), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(.blue)
            }.rotationEffect(.degrees(90)).frame(width: 18, height: 18)
        case .tps:
            Text("TPS").font(.system(size: 7, weight: .bold, design: .rounded)).foregroundStyle(.cyan)
        case .tasks:
            VStack(spacing: 1) {
                Text(summary.freshness == .fresh ? "\(summary.main)" : "—")
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.orange)
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 6))
                    Text(summary.freshness == .fresh ? "\(summary.subagents)" : "—").font(.system(size: 8, design: .rounded))
                }.foregroundStyle(Color(red: 0.71, green: 0.67, blue: 1))
            }
        case .models:
            VStack(spacing: 2) {
                ForEach(Array(shares.prefix(4))) { share in
                    Capsule().fill(share.color).frame(width: max(3, min(18, share.share * 18)), height: 2)
                }
                if shares.isEmpty { Image(systemName: "chart.pie").font(.system(size: 13)).foregroundStyle(.gray) }
            }
        case .radar:
            Image(systemName: radarActive ? "bolt.horizontal.circle.fill" : "dot.radiowaves.left.and.right")
                .font(.system(size: 13)).foregroundStyle(radarActive ? .red : .gray)
        default: EmptyView()
        }
    }

    private func tint(_ quota: ClientQuotaItem) -> Color {
        if let remaining = quota.remaining, remaining <= 10 { return .red }
        return Color(nsColor: NSColor(clientHex: colors[quota.id] ?? quota.fill))
    }

    private func label(_ item: QuotaSidebarItem) -> String {
        switch item {
        case let .quota(client):
            return QuotaSidebarContentOrder.quotaWindows(quotas, client: client)
                .map { $0.title + " " + $0.accessibleValue }.joined(separator: "，")
        case .tasks:
            return SidebarTaskMeterPresentation(summary: summary).label
        case .speed: return item.title + " " + rateText
        case .tps: return item.title + " " + tpsText
        default: return item.title
        }
    }
}
