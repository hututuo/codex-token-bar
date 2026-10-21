import SwiftUI

struct ObservedSpeedView: View {
    @ObservedObject var monitor: LiveRateMonitor
    @State private var visibleCount = 30
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("真实测速", systemImage: "waveform.path.ecg").font(.headline)
                Spacer()
                Text("最近 \(monitor.speedWindowMinutes) 分钟 · 正文计时速度").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach([15, 30], id: \.self) { minutes in
                    Button("\(minutes) 分钟") { monitor.setSpeedWindowMinutes(minutes) }
                        .buttonStyle(.bordered).tint(monitor.speedWindowMinutes == minutes ? .blue : .gray)
                }
            }.font(.caption)
            Text(monitor.measurementStatus).font(.caption).foregroundStyle(.secondary)
            if monitor.modelSpeeds.isEmpty {
                Text(monitor.speedSummaryEmptyLabel).font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(monitor.modelSpeeds) { item in
                    HStack {
                        Text(item.model).font(.system(.subheadline, design: .monospaced))
                        Spacer()
                        Text("\(item.tokensPerSecond, specifier: "%.1f") tok/s").bold().monospacedDigit()
                        Text(item.activeSampleCount > 0 ? "接收中" : "参考均速").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(item.sampleCount) 段 · \(item.outputTokens) token（估） / \(item.durationSeconds, specifier: "%.2f") 秒 · 单段达标 \(item.qualifiedSampleCount) 段 · 汇总质量\(item.confidence == "high" ? "较高" : item.confidence == "medium" ? "中等" : "较低")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(monitor.speedSummaryExplanation).font(.caption).foregroundStyle(.secondary)
            Text("参考均速 = 同模型完整正文的 o200k token 总量 ÷ 正文起止时长总和。包括中间说明与最终回复，每秒检查，正文完成后更新；不混入思考、工具执行结果和请求等待。历史流式采样保留在明细，不重复计入均速。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("采样明细（\(monitor.speedSamples.count) 段，按轮次追溯）") {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if monitor.speedSamples.isEmpty {
                        Text("等待带开始和结束时间的正文记录。")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ForEach(monitor.speedSamples.prefix(visibleCount)) { sample in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(sample.model).bold()
                                Spacer()
                                Text("\(sample.tokensPerSecond, specifier: "%.1f") tok/s").monospacedDigit()
                                Text(sample.confidence == "high" ? "较高" : sample.confidence == "medium" ? "中等" : "较低")
                                    .foregroundStyle(sample.confidence == "low" ? Color.orange : Color.secondary)
                            }
                            Text("会话：\(monitor.threadOptions.first { $0.id == sample.threadID }?.displayTitle ?? sample.threadID)")
                            Text("会话 ID：\(sample.threadID)\n轮次 ID：\(sample.turnID)\n输出项：\(sample.itemID)")
                                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            Text(sample.measurementKind == "completed_body" ? "正文计时 · 离线 o200k_base 分词" : "历史实时增量采样 · 原分词口径")
                            Text("采样 \(sample.outputTokens) token（估） · \(sample.outputCharacters) 字符 / \(sample.outputBytes) 字节 · \(sample.durationSeconds, specifier: "%.2f") 秒")
                            if sample.measurementKind != "completed_body" { Text("\(sample.chunkCount) 次更新") }
                            Text(Date(timeIntervalSince1970: sample.endedAt).formatted(date: .abbreviated, time: .standard))
                                .foregroundStyle(.secondary)
                            Text(sample.measurementKind == "completed_body" ? "只有正文起止计时，无法判断中途的网络或服务端停顿；短文本误差较大。" : (sample.networkWarning ?? "未发现明显接收停顿；仍无法排除网络缓冲或服务端批量发送。"))
                                .foregroundStyle(sample.networkWarning == nil ? Color.secondary : Color.orange)
                            Text(sample.source).foregroundStyle(.secondary)
                        }.font(.caption).padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if monitor.speedSamples.count > visibleCount {
                        Button("再显示 30 段") { visibleCount += 30 }.buttonStyle(.plain)
                    }
                }.padding(.top, 8)
            }.font(.subheadline)
            Text("正文计时使用本地 item_completed 的 started_at_ms / completed_at_ms，与同一会话、轮次、输出 ID 的完整文字配对。≥500 token 且≥5秒评为较高，≥100 token 且≥2秒评为中等，其余较低；评级反映样本长度，不证明没有网络干扰。o200k 分词不等于服务端计费量。历史增量采样仍按首次至末次更新计时并扣除首段。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 10)
        .accessibilityIdentifier("observed-speed-details")
    }
}
