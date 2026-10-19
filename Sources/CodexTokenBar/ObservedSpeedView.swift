import SwiftUI

struct ObservedSpeedView: View {
    @ObservedObject var monitor: LiveRateMonitor
    @State private var visibleCount = 30
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("真实测速", systemImage: "waveform.path.ecg").font(.headline)
                Spacer()
                Text("最近 \(monitor.speedWindowMinutes) 分钟 · 接收速度").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach([15, 30], id: \.self) { minutes in
                    Button("\(minutes) 分钟") { monitor.setSpeedWindowMinutes(minutes) }
                        .buttonStyle(.bordered).tint(monitor.speedWindowMinutes == minutes ? .blue : .gray)
                }
            }.font(.caption)
            Text(monitor.measurementStatus).font(.caption).foregroundStyle(.secondary)
            if monitor.modelSpeeds.isEmpty {
                Text("模型均速暂无有效样本").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(monitor.modelSpeeds) { item in
                    HStack {
                        Text(item.model).font(.system(.subheadline, design: .monospaced))
                        Spacer()
                        Text("\(item.tokensPerSecond, specifier: "%.1f") tok/s").bold().monospacedDigit()
                        Text("\(item.sampleCount) 段").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("只测文本和模型生成的工具输入流；工具执行结果、隐藏思考和结算均速不混入。按采样 token 总量 ÷ 总时长加权；短样本或有停顿的样本仅列明细。置信度是样本质量评级，不是统计概率。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("采样明细（\(monitor.speedSamples.count) 段，按轮次追溯）") {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if monitor.speedSamples.isEmpty {
                        Text("暂无可追溯的流式样本。不会把历史整段输出伪装成实时流。")
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
                            Text("采样 \(sample.outputTokens) token（估） · \(sample.outputCharacters) 字符 / \(sample.outputBytes) 字节 · \(sample.chunkCount) 包 · \(sample.durationSeconds, specifier: "%.2f") 秒")
                            Text(Date(timeIntervalSince1970: sample.endedAt).formatted(date: .abbreviated, time: .standard))
                                .foregroundStyle(.secondary)
                            Text(sample.networkWarning ?? "未发现明显接收停顿；仍无法排除网络缓冲或服务端批量发送。")
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
            Text("计时从首包到末包，首包 token 不计入分子；分词结果为本地估算。≥500 token、≥5秒、≥10包且无明显停顿评为较高；≥100 token、≥2秒、≥4包评为中等。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 10)
        .accessibilityIdentifier("observed-speed-details")
    }
}
