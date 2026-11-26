import SwiftUI

/// Four independent windows share one outline; their percentages are never added.
struct ClientQuarteredQuotaRing: View {
    @AppStorage(ClientQuotaSelection.key) private var selectionRaw = ""
    let items: [ClientQuotaItem]

    var body: some View {
        if items.count == 4 {
            VStack(spacing: 4) {
                ZStack {
                    MatchedStrokeMorphParticipant(ids: Set(items.map(\.id)),
                        size: CGSize(width: ClientQuotaQuarterLayout.size, height: ClientQuotaQuarterLayout.size)) {
                        ZStack {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                quarter(item, index: index)
                            }
                        }.padding(ClientQuotaQuarterLayout.inset)
                    }
                    // Values remain visible while the compositor owns only the strokes.
                    HStack(spacing: 2) {
                        values(items[0], items[1])
                        values(items[2], items[3])
                    }
                }
                .frame(width: ClientQuotaQuarterLayout.size, height: ClientQuotaQuarterLayout.size)
                .anchorPreference(key: ClientQuotaMorphAnchors.self, value: .bounds) { anchor in
                    Dictionary(uniqueKeysWithValues: items.map { ("ring:" + $0.id, anchor) })
                }
                HStack(spacing: 2) {
                    Text(pool(items[0])).frame(width: 36)
                    Text(pool(items[2])).frame(width: 36)
                }.font(.system(size: 8)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                Text("上 5h · 下 7d").font(.system(size: 8)).foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 3) {
                    MatchedStrokeMorphParticipant(ids: Set(items.map { "marker:" + $0.id }), size: CGSize(width: 5, height: 5)) {
                        Circle().fill(Color(nsColor: NSColor(clientHex: items[0].brand))).frame(width: 5, height: 5)
                    }.anchorPreference(key: ClientQuotaMorphAnchors.self, value: .bounds) { anchor in
                        Dictionary(uniqueKeysWithValues: items.map { ("marker:" + $0.id, anchor) })
                    }
                    Text(items[0].shortClientTitle).font(.system(size: 10)).lineLimit(1)
                }.foregroundStyle(.white.opacity(0.8))
            }
            .frame(width: 74).padding(.vertical, 3).contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(items.map { $0.title + " 剩余 " + $0.accessibleValue }.joined(separator: "；"))
            .help(items.map { $0.title + " · " + $0.accessibleValue + "\n" + $0.source }.joined(separator: "\n"))
        }
    }

    private func color(_ item: ClientQuotaItem) -> Color {
        Color(nsColor: NSColor(clientHex: ClientQuotaSelection.decode(selectionRaw).colors[item.id] ?? item.fill))
    }

    private func quarter(_ item: ClientQuotaItem, index: Int) -> some View {
        ZStack {
            Circle().trim(from: ClientQuotaQuarterLayout.gap, to: 0.25 - ClientQuotaQuarterLayout.gap)
                .stroke(.white.opacity(0.15), lineWidth: 3)
            Circle().trim(from: ClientQuotaQuarterLayout.gap,
                to: ClientQuotaQuarterLayout.gap + ClientQuotaQuarterLayout.sweep * (item.remaining ?? 0) / 100)
                .stroke(color(item), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .clipShape(ClientQuotaQuarterJoinClip())
                .opacity((item.remaining ?? 0) > 0 ? 1 : 0)
        }.rotationEffect(.degrees(ClientQuotaQuarterLayout.rotation(index)))
    }

    private func values(_ top: ClientQuotaItem, _ bottom: ClientQuotaItem) -> some View {
        VStack(spacing: 4) { value(top); value(bottom) }
    }

    private func value(_ item: ClientQuotaItem) -> some View {
        ViewThatFits(in: .horizontal) {
            ForEach([9.0, 8, 7, 6], id: \.self) { size in
                Text(item.compactValue).font(.system(size: size, weight: .medium, design: .rounded))
                    .monospacedDigit().fixedSize(horizontal: true, vertical: true)
            }
        }.frame(width: 21, height: 11).foregroundStyle(color(item))
    }

    private func pool(_ item: ClientQuotaItem) -> String {
        let name = item.window.components(separatedBy: " · ").dropLast().joined(separator: " · ")
        return name == "第三方模型" ? "第三方" : name
    }
}

private struct ClientQuotaQuarterJoinClip: Shape {
    func path(in rect: CGRect) -> Path {
        Circle().trim(from: ClientQuotaQuarterLayout.gap, to: 0.25 - ClientQuotaQuarterLayout.gap)
            .path(in: rect).strokedPath(StrokeStyle(lineWidth: 12, lineCap: .butt))
    }
}
