import SwiftUI
import Charts

/// A different measurement method is displayed alongside, never averaged into
/// Codex's completed-body TPS. This view alone subscribes to live publications.
struct ClaudeLocalSpeedView: View {
    let allowed: Set<String>
    @ObservedObject private var runtime = ClaudeLocalRuntime.shared
    @ObservedObject private var statusline = ClaudeStatuslineStore.shared

    private var local: ClaudeLocalRuntimeSnapshot { runtime.projection(allowed: allowed) }
    private struct Row: Identifiable {
        let id: String; let model: String?; let outputTokens: Int; let duration: Double?; let endedAt: Date
    }
    private var apiRows: [ClaudeAPISpeedSample] { allowed.contains("claudeCode") ? statusline.samples.filter { $0.endedAt >= Date().addingTimeInterval(-1800) } : [] }
    private var rows: [Row] {
        if !apiRows.isEmpty { return apiRows.map { Row(id: $0.id, model: $0.model, outputTokens: $0.outputTokens, duration: $0.duration, endedAt: $0.endedAt) } }
        return local.rows.sorted { $0.endedAt > $1.endedAt }.map { Row(id: $0.id, model: $0.model, outputTokens: $0.outputTokens, duration: $0.duration, endedAt: $0.endedAt) }
    }
    private func rate(_ row: Row) -> Double? {
        guard let duration = row.duration, duration > 0.4 else { return nil }
        let value = Double(row.outputTokens) / duration
        return value.isFinite && value >= 2 && value <= 500 ? value : nil
    }
    private func mean(model: String, minutes: Int) -> String {
        if !apiRows.isEmpty, let summary = statusline.windows.first(where: { $0.model == model }) {
            let value = minutes == 5 ? summary.five : minutes == 15 ? summary.fifteen : summary.thirty
            return value.map(LiveRateSnapshot.rateDisplayText) ?? "—"
        }
        let selected = rows.filter { ($0.model ?? "unknown") == model && $0.endedAt >= Date().addingTimeInterval(-Double(minutes * 60)) && rate($0) != nil }
        let duration = selected.compactMap(\.duration).reduce(0, +)
        guard duration > 0 else { return "—" }
        return LiveRateSnapshot.rateDisplayText(Double(selected.reduce(0) { $0 + $1.outputTokens }) / duration)
    }
    private struct Trend: Identifiable {
        let model: String; let time: Date; let tps: Double; let run: Int
        var id: String { model + String(time.timeIntervalSince1970) }
    }
    private var trend: [Trend] {
        if !apiRows.isEmpty {
            var previous: [String: Int] = [:], runs: [String: Int] = [:]
            return statusline.buckets.map { row in
                if let prior = previous[row.model], row.start - prior > 300 { runs[row.model, default: 0] += 1 }
                previous[row.model] = row.start
                return Trend(model: row.model, time: Date(timeIntervalSince1970: Double(row.start)), tps: row.tps, run: runs[row.model] ?? 0)
            }
        }
        var values: [String: [Int: (Int, Double)]] = [:]
        for row in rows where rate(row) != nil {
            let bucket = Int(row.endedAt.timeIntervalSince1970 / 300) * 300
            let model = row.model ?? "unknown", old = values[model]?[bucket] ?? (0, 0)
            values[model, default: [:]][bucket] = (old.0 + row.outputTokens, old.1 + (row.duration ?? 0))
        }
        return values.keys.sorted().flatMap { model -> [Trend] in
            var previous: Int?, run = 0
            return values[model]!.keys.sorted().compactMap { bucket in
                if let previous, bucket - previous > 300 { run += 1 }
                previous = bucket
                guard let pair = values[model]?[bucket], pair.1 > 0 else { return nil }
                return Trend(model: model, time: Date(timeIntervalSince1970: Double(bucket)), tps: Double(pair.0) / pair.1, run: run)
            }
        }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in content }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(apiRows.isEmpty ? "Claude · 请求区间 TPS" : "Claude · API 耗时 TPS").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(local.enabled ? "本地日志 · 估算" : "读取已关闭").font(.caption).foregroundStyle(.secondary)
            }
            if local.live.output > 0 {
                Text("活动曲线 · 估算占比 \(Int((local.estimatedShare * 100).rounded()))%")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("沿用 Agent Speed 的请求时间线估算分类；不是逐字流式实测。")
            }
            if rows.isEmpty {
                Text(local.sourceAvailable ? "等待新的输出记录" : "暂无本地实时样本").font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    GridRow { Text("模型"); Text("最新"); Text("5分钟"); Text("15分钟"); Text("30分钟") }.foregroundStyle(.secondary)
                    ForEach(!apiRows.isEmpty ? statusline.windows.map(\.model) : Array(Set(rows.compactMap(\.model))).sorted(), id: \.self) { model in
                        GridRow {
                            Text(model).lineLimit(1).foregroundStyle(ModelUsagePresentation.color(for: model))
                            Text((!apiRows.isEmpty ? statusline.windows.first(where: { $0.model == model })?.latest : rows.first(where: { $0.model == model && rate($0) != nil }).flatMap(rate)).map(LiveRateSnapshot.rateDisplayText) ?? "—")
                            Text(mean(model: model, minutes: 5)); Text(mean(model: model, minutes: 15)); Text(mean(model: model, minutes: 30))
                        }
                    }
                }.font(.system(size: 11)).monospacedDigit()
                Chart(trend) { row in
                    LineMark(x: .value("时间", row.time), y: .value("TPS", row.tps), series: .value("连续段", row.model + String(row.run)))
                        .foregroundStyle(ModelUsagePresentation.color(for: row.model))
                    PointMark(x: .value("时间", row.time), y: .value("TPS", row.tps))
                        .foregroundStyle(ModelUsagePresentation.color(for: row.model))
                }.chartXScale(domain: Date().addingTimeInterval(-1800)...Date())
                    .frame(height: 105)
                Text("近半小时 · 每 5 分钟按 Token / 耗时加权").font(.system(size: 9)).foregroundStyle(.secondary)
                ForEach(Array(rows.prefix(6))) { row in
                    HStack(spacing: 8) {
                        Text(row.endedAt, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
                        Text(row.model ?? "未识别模型").lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(row.outputTokens) Token").foregroundStyle(.secondary)
                        Text(row.duration.map { String(format: "%.2fs", $0) } ?? "无时长").foregroundStyle(.secondary)
                        Text(rate(row).map { LiveRateSnapshot.rateDisplayText($0) + " TPS" } ?? "低置信度").monospacedDigit()
                    }.font(.system(size: 10))
                }
            }
            if allowed.contains("claudeCode"), let context = statusline.metrics, let used = context.contextUsed, let size = context.contextSize, size > 0 {
                Text("上下文 \(used) / \(size) Token").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(apiRows.isEmpty ? "请求区间包含等待和工具耗时；不与正文 TPS 混算。" : "输出 Token 增量 ÷ API 累计耗时增量；本地状态栏数据。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ClaudeLocalSpeedCompact: View {
    let allowed: Set<String>
    @ObservedObject private var runtime = ClaudeLocalRuntime.shared
    @ObservedObject private var statusline = ClaudeStatuslineStore.shared
    var body: some View {
        let value = runtime.projection(allowed: allowed)
        let api = allowed.contains("claudeCode") ? statusline.samples.filter { $0.qualified && $0.endedAt >= Date().addingTimeInterval(-1800) } : []
        let models = statusline.windows.map(\.model)
        VStack(spacing: 3) {
            Text(api.isEmpty ? "Claude · 区间 TPS" : "Claude · API TPS").font(.system(size: 9))
            if !api.isEmpty {
                ForEach(models, id: \.self) { model in
                    HStack(spacing: 3) {
                        Text(model.replacingOccurrences(of: "claude-", with: "")).lineLimit(1).minimumScaleFactor(0.6)
                        Spacer(minLength: 0)
                        Text(statusline.windows.first(where: { $0.model == model })?.latest.map(LiveRateSnapshot.rateDisplayText) ?? "—").monospacedDigit()
                    }.font(.system(size: 9))
                }
            } else {
                let latest = value.rows.filter { ($0.duration ?? 0) > 0.4 }.max { $0.endedAt < $1.endedAt }
                Text(latest?.responseIntervalOutputTokensPerSecond.map(LiveRateSnapshot.rateDisplayText) ?? "—")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
        }
    }
}
