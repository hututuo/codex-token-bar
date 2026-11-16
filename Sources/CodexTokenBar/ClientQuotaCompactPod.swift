import SwiftUI

/// Pairs periods within a pool, independently of discovery order. A missing
/// period keeps its own empty column; it must never borrow another pool's value.
enum ClientQuotaPodLayout {
    struct Row: Identifiable, Equatable {
        let id: String
        var fiveHour: ClientQuotaItem?
        var weekly: ClientQuotaItem?
        var single: ClientQuotaItem?
    }

    static func rows(_ items: [ClientQuotaItem]) -> [Row] {
        var rows: [Row] = []
        for item in items {
            let id = item.id.lowercased()
            let label = item.window.lowercased()
            let five = id.hasSuffix(":5h") || id.hasSuffix("-5h") || label == "5h" || label.contains("5小时") || label.contains("储备5h")
            let weekly = id.hasSuffix(":7d") || id.hasSuffix("-weekly") || label == "7d" || label.contains("7天") || label.contains("储备7d")
            guard five || weekly else {
                rows.append(Row(id: item.id, single: item))
                continue
            }
            let pool = id.contains("gemini-") ? "gemini" : id.contains("3p-") ? "3p"
                : label.contains("储备") || label.contains("reserve") ? "reserve" : "main"
            let key = item.client + ":" + pool
            if let index = rows.firstIndex(where: { $0.id == key }),
               five ? rows[index].fiveHour == nil : rows[index].weekly == nil {
                if five { rows[index].fiveHour = item } else { rows[index].weekly = item }
            } else if !rows.contains(where: { $0.id == key }) {
                rows.append(Row(id: key, fiveHour: five ? item : nil, weekly: weekly ? item : nil))
            } else {
                // Unrecognized extra windows remain visible instead of replacing
                // an observation that happens to have the same period label.
                rows.append(Row(id: item.id, single: item))
            }
        }
        func rank(_ row: Row) -> Int {
            if row.id.hasSuffix(":gemini") { return 0 }
            if row.id.hasSuffix(":3p") { return 1 }
            return 2
        }
        return rows.enumerated().sorted {
            rank($0.element) == rank($1.element) ? $0.offset < $1.offset : rank($0.element) < rank($1.element)
        }.map(\.element)
    }

    static func height(_ items: [ClientQuotaItem]) -> Double {
        let count = rows(items).count
        guard count > 0 else { return 0 }
        return count == 1 ? 36 : 16 + Double(count) * 16 + Double(count - 1) * 4
    }

    static func visibleItems(_ items: [QuotaSidebarItem], quotas: [ClientQuotaItem]) -> [QuotaSidebarItem] {
        items.filter {
            guard $0.hasCompactRepresentation else { return false }
            if case let .quota(client) = $0 { return quotas.contains { $0.client == client } }
            return true
        }
    }

    static func railLayout(items: [QuotaSidebarItem], quotas: [ClientQuotaItem], availableHeight: Double) -> ClientRailLayout {
        let visible = visibleItems(items, quotas: quotas)
        let content = visible.reduce(0.0) { result, item in
            if case let .quota(client) = item { return result + height(quotas.filter { $0.client == client }) }
            return result + 46
        }
        let height = content + Double(max(0, visible.count - 1)) * 12 + 30
        return ClientRailLayout(barHeight: 46, gap: 12,
            height: min(max(30, availableHeight.isFinite ? availableHeight : 900), height))
    }
}

/// The small client marks from the selected A demo. These are local vector
/// shapes, so displaying a client never depends on its app being installed.
struct ClientQuotaPodIcon: View {
    let client: String
    private var color: Color {
        Color(nsColor: NSColor(clientHex: client == "codex" ? "#8A94FF"
            : client.hasPrefix("claude") ? "#EE9474" : client == "antigravity" ? "#74B8FF" : ClientBrand.hex(client)))
    }
    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2, cy = size.height / 2
            var path = Path()
            if client == "codex" {
                path.move(to: CGPoint(x: cx - 3.2, y: cy - 2.2))
                path.addLine(to: CGPoint(x: cx - 0.4, y: cy))
                path.addLine(to: CGPoint(x: cx - 3.2, y: cy + 2.2))
                path.move(to: CGPoint(x: cx + 0.5, y: cy + 2.2))
                path.addLine(to: CGPoint(x: cx + 3.3, y: cy + 2.2))
            } else if client.hasPrefix("claude") {
                for angle in [0.0, Double.pi / 3, 2 * Double.pi / 3] {
                    let dx = cos(angle) * 3.3, dy = sin(angle) * 3.3
                    path.move(to: CGPoint(x: cx - dx, y: cy - dy))
                    path.addLine(to: CGPoint(x: cx + dx, y: cy + dy))
                }
            } else if client == "antigravity" || client == "gemini" {
                let points = [(0.0, -3.7), (0.95, -0.95), (3.2, 0), (0.95, 0.95),
                              (0, 3.7), (-0.95, 0.95), (-3.2, 0), (-0.95, -0.95)]
                path.addLines(points.map { CGPoint(x: cx + $0.0, y: cy + $0.1) })
                path.closeSubpath()
                context.fill(path, with: .color(color))
                return
            } else {
                path.addRoundedRect(in: CGRect(x: cx - 3, y: cy - 3, width: 6, height: 6), cornerSize: CGSize(width: 1, height: 1))
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }.frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

struct ClientQuotaCompactPod: View {
    let client: String
    let items: [ClientQuotaItem]
    var colors: [String: String] = [:]
    var usesMorphAnchors = false
    private var rows: [ClientQuotaPodLayout.Row] { ClientQuotaPodLayout.rows(items) }
    private var alert: Bool { items.contains { $0.remaining.map { $0 <= 10 } ?? false } }

    var body: some View {
        VStack(spacing: 0) {
            ClientQuotaPodIcon(client: client).padding(.top, 2.5).padding(.bottom, 2)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle().fill(.white.opacity(0.16)).frame(width: 4, height: 0.6)
                        .frame(height: 4)
                }
                HStack(spacing: 3) {
                    if let single = row.single {
                        if single.window == "API" {
                            Text("API").font(.system(size: 6, weight: .medium)).foregroundStyle(.gray)
                                .frame(height: rows.count > 1 ? 16 : 20)
                        } else { track(single) }
                    } else {
                        track(row.fiveHour)
                        track(row.weekly)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 16, height: ClientQuotaPodLayout.height(items))
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(alert ? Color(red: 1, green: 0.43, blue: 0.42).opacity(0.58) : .white.opacity(0.13), lineWidth: 0.8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(items.map { $0.title + " " + $0.accessibleValue }.joined(separator: "，"))
        .accessibilityIdentifier("quota-sidebar-pod-" + client)
        .help(items.map { $0.title + " · " + $0.accessibleValue + "\n" + $0.source }.joined(separator: "\n"))
    }

    @ViewBuilder private func track(_ item: ClientQuotaItem?) -> some View {
        let height = rows.count > 1 ? 16.0 : 20.0
        if let item {
            let low = item.remaining.map { $0 <= 10 } ?? false
            let color = low ? Color(red: 1, green: 0.43, blue: 0.42)
                : Color(nsColor: NSColor(clientHex: colors[item.id] ?? item.fill))
            MatchedStrokeMorphParticipant(ids: [item.id], size: CGSize(width: 4, height: height)) {
                SidebarValueBar(fraction: item.remaining.map { $0 / 100 }, color: color, vertical: true, expected: item.expected)
            }
            .anchorPreference(key: ClientQuotaMorphAnchors.self, value: .bounds) { usesMorphAnchors ? ["track:" + item.id: $0] : [:] }
        } else {
            Color.clear.frame(width: 4, height: height).accessibilityHidden(true)
        }
    }
}
