import SwiftUI

// Reuses the dashboard's snapshots and ranking policy; this surface owns no
// reader, refresh timer, API client or independent cache.
enum QuotaSidebarRadarPresentation {
    static func windowText(_ snapshot: CodexRadarSnapshot?) -> String {
        guard let open = snapshot?.window.open ?? snapshot?.windowOpen else { return "雷达待读取" }
        return open && CodexRadarPresentationText.isSpeedWindow(snapshot: snapshot) ? "速登窗口" : "等待"
    }

    static func isActiveWindow(_ snapshot: CodexRadarSnapshot?, stale: Bool,
                               updatedAt: Date?, now: Date = Date()) -> Bool {
        guard !stale, let snapshot, CodexRadarPresentationText.isSpeedWindow(snapshot: snapshot, now: now),
              snapshot.windowOpen != false, let updatedAt else { return false }
        let age = now.timeIntervalSince(updatedAt)
        return age >= 0 && age <= 15 * 60
    }

    static func rankedModels(_ crowd: CodexCrowdRadarSnapshot?) -> [CodexCrowdRadarModel] {
        guard let crowd, crowd.realtimeAvailable else { return [] }
        return Array(crowd.rankedModels(for: .realtime).filter { $0.iq.isFinite }.prefix(8))
    }

    static func timeText(_ raw: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        return date?.formatted(date: .omitted, time: .shortened) ?? (raw.isEmpty ? "时间未知" : raw)
    }
}

struct QuotaSidebarRadarContent: View {
    let snapshot: CodexRadarSnapshot?
    let crowd: CodexCrowdRadarSnapshot?
    let officialStale: Bool
    let crowdStale: Bool
    let status: String
    let updatedAt: Date?

    var body: some View {
        let point = snapshot?.modelIQ.primaryModelPoint
        let rankings = QuotaSidebarRadarPresentation.rankedModels(crowd)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.cyan)
                Text("Codex 雷达").font(.system(size: 13, weight: .semibold))
                Spacer()
                if officialStale { staleBadge }
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("速登状态").font(.system(size: 9)).foregroundStyle(.gray)
                    Text(QuotaSidebarRadarPresentation.windowText(snapshot))
                        .font(.system(size: 19, weight: .medium)).foregroundStyle(.cyan)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 7) {
                    Text("雷达测评 IQ").font(.system(size: 9)).foregroundStyle(.gray)
                    Text(point.map { $0.score.isFinite ? CodexRadarModelIQPoint.display($0.score) : "未知" } ?? "未知")
                        .font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
                    Text(point?.modelDisplayName ?? "暂无测评").font(.system(size: 9)).foregroundStyle(.gray)
                        .lineLimit(2).help(point?.modelDisplayName ?? "暂无测评")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(14).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 7) {
                Text(officialStale ? "上次建议动作 · 旧数据" : "建议动作")
                    .font(.system(size: 9)).foregroundStyle(officialStale ? .orange : .gray)
                let action = CodexRadarPresentationText.effectiveAction(snapshot: snapshot)
                Text(action == "--" ? "暂未提供建议" : action)
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.cyan)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(Color.cyan.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            Text("来源：Codex 雷达 · \(updatedAt?.formatted(date: .omitted, time: .shortened) ?? QuotaSidebarRadarPresentation.timeText(snapshot?.monitoredAt ?? ""))")
                .font(.system(size: 9)).foregroundStyle(.gray).lineLimit(1)
            if snapshot == nil {
                Text(status).font(.system(size: 10)).foregroundStyle(.gray).lineLimit(2).help(status)
            }

            Divider().overlay(.white.opacity(0.12))
            HStack {
                Text("众测实时模型排行").font(.system(size: 12, weight: .semibold))
                Spacer()
                if crowdStale { staleBadge }
            }
            Text("每格最新一次 · ≥\(CodexCrowdRadarSnapshot.minimumRankedSampleCount) 样本 · \(QuotaSidebarRadarPresentation.timeText(crowd?.generatedAt ?? ""))")
                .font(.system(size: 9)).foregroundStyle(.gray).lineLimit(1)
            if rankings.isEmpty {
                Text(crowd?.realtimeAvailable == false ? "实时排行暂不可用" : "暂无达到样本门槛的实时模型结果")
                    .font(.system(size: 11)).foregroundStyle(.gray).padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rankings.enumerated()), id: \.element.id) { index, model in
                        rankingRow(index + 1, model: model)
                        if index < rankings.count - 1 { Divider().overlay(.white.opacity(0.06)) }
                    }
                }.padding(.horizontal, 12).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                Text("按众测通过率降序 · 沿用雷达并列排序 · 与上方测评 IQ 分开")
                    .font(.system(size: 9)).foregroundStyle(.gray).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
    }

    private var staleBadge: some View {
        Text("旧数据").font(.system(size: 9)).foregroundStyle(.orange)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.orange.opacity(0.1), in: Capsule())
    }

    private func rankingRow(_ rank: Int, model: CodexCrowdRadarModel) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(rank)").font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(rank <= 3 ? Color.cyan : .gray).frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.model).font(.system(size: 11, weight: .medium)).lineLimit(2).help(model.model)
                Text(model.effort.isEmpty ? "推理强度未提供" : "推理 \(model.effort)")
                    .font(.system(size: 9)).foregroundStyle(.gray)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 5) {
                Text(String(format: "IQ %.1f", model.iq)).font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                Text("\(model.scorePassed)/\(model.scoreSamples) 通过").font(.system(size: 9)).foregroundStyle(.gray)
            }
        }.padding(.vertical, 11)
    }
}


struct QuotaSidebarRadarOutline: View {
    let edge: QuotaSidebarEdge
    let expanded: Bool
    let snapshot: CodexRadarSnapshot?
    let stale: Bool
    let updatedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var outline: UnevenRoundedRectangle {
        let radius: CGFloat = expanded ? 22 : 8
        return UnevenRoundedRectangle(topLeadingRadius: edge == .right ? radius : 0,
            bottomLeadingRadius: edge == .right ? radius : 0,
            bottomTrailingRadius: edge == .left ? radius : 0,
            topTrailingRadius: edge == .left ? radius : 0)
    }

    var body: some View {
        // Recheck local freshness even when no store publishes. The idle
        // sidebar wakes only every 30 seconds, with no additional network work.
        TimelineView(.periodic(from: .now, by: 30)) { tick in
            if QuotaSidebarRadarPresentation.isActiveWindow(snapshot, stale: stale,
                                                            updatedAt: updatedAt, now: tick.date) {
                if reduceMotion {
                    glow(opacity: 0.9)
                } else {
                    TimelineView(.animation(minimumInterval: 0.06)) { context in
                        let wave = (sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.6) + 1) / 2
                        // The active animation also checks on every tick, so
                        // the light turns off at expiry without a frozen glow.
                        if QuotaSidebarRadarPresentation.isActiveWindow(snapshot, stale: stale,
                                                                        updatedAt: updatedAt, now: context.date) {
                            glow(opacity: 0.7 + wave * 0.3, phase: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3 * 360)
                        }
                    }
                }
            }
        }
    }

    private func glow(opacity: Double, phase: Double = 0) -> some View {
        outline.strokeBorder(AngularGradient(colors: [.red.opacity(0.15), .red.opacity(opacity), .red.opacity(0.15)], center: .center, angle: .degrees(phase)), lineWidth: 1.5)
            .shadow(color: Color.red.opacity(opacity * 0.7), radius: 3)
            // Clip the glow inside the exact rail bounds. This needs no larger
            // native window and never changes the pointer interception area.
            .clipShape(outline)
    }
}
