import AppKit
import SwiftUI
import AVKit

struct AgentSpeedReportingSettingsView: View {
    @ObservedObject private var controller = AgentSpeedReportingController.shared
    @State private var nickname = ""
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("速蹬排行榜", systemImage: "speedometer").font(.title3.bold())
                Spacer()
                Toggle("参加排行榜", isOn: Binding(get: { controller.enabled }, set: {
                    if $0 { confirming = true } else { controller.setEnabled(false) }
                })).toggleStyle(.switch)
            }
            Text("按 Agent Speed 标准统计各软件的请求速度，与你的正文 TPS 独立。")
            HStack {
                Text("公开昵称")
                TextField("排行榜昵称", text: $nickname).textFieldStyle(.roundedBorder)
                    .disabled(controller.enabled)
            }
            Text("仅上报速度、Token、模型、Harness 和运行统计，以及昵称、设备标识和客户端版本信息；不上传对话、文件路径或账号凭据。关闭后停止这条链路的采集和上报。")
                .font(.callout).foregroundStyle(.secondary)
            Text("同一台电脑的同一数据源，请只在 Agent Speed 或 Token Bar 中开启一处上报，避免重复累计。")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack {
                Circle().fill(controller.enabled ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(controller.message).font(.callout)
                Spacer()
                if controller.enabled && controller.phase == "error" {
                    Button("重试连接") { controller.retry() }
                }
            }
            if controller.enabled && controller.phase == "running" {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(controller.liveOutputTps, format: .number.precision(.fractionLength(1)))
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("Token/s").foregroundStyle(.secondary)
                    Spacer()
                    Text("估算占比 \(Int((controller.estimatedShare * 100).rounded()))%")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(controller.sources) { source in
                    HStack {
                        Text(source.name)
                        Spacer()
                        Text(source.tps, format: .number.precision(.fractionLength(1))).monospacedDigit()
                        Text("Token/s").foregroundStyle(.secondary)
                    }.font(.callout)
                }
                if let date = controller.lastReportAt {
                    Text("最近上报 \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("支持的软件") {
                Text("Codex、Claude Code、Claude Desktop（本地 Code／Agent 会话）、DSH、OpenCode、Gemini CLI、omp、Antigravity、WorkBuddy、WorkBuddy AI、ZCode、Kimi Code、Grok Build。自动发现本地默认目录及环境变量指定的目录；云端未落地的会话无法统计。")
                    .font(.callout).padding(.top, 6)
            }
            HStack(spacing: 16) {
                Link("查看排行榜 ↗", destination: AgentSpeedReportingController.website)
                Link("隐私说明", destination: URL(string: "https://deng.codexradar.com/agent-speed/privacy/")!)
                Link("服务条款", destination: URL(string: "https://deng.codexradar.com/agent-speed/terms/")!)
                if let profile = controller.profileURL { Link("我的资料与设备 ↗", destination: profile) }
            }.font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { nickname = controller.username }
        .alert("参加速蹬排行榜？", isPresented: $confirming) {
            Button("暂不参加", role: .cancel) {}
            Button("同意并开启") { controller.setEnabled(true, username: nickname) }
        } message: {
            Text("开启后将以“\(nickname)”公开参与排行榜，发送各软件的速度、Token、模型和 Harness 等统计。请确认这台电脑没有另一客户端重复上报。你可以随时在这里关闭。")
        }
    }
}

/// Bundled recording, not a remote web view: showing this invitation never contacts the leaderboard.
struct AgentSpeedReportingInvitation: View {
    @ObservedObject private var controller = AgentSpeedReportingController.shared
    @State private var joining = false
    @State private var invitationReady = false
    var body: some View {
        Group {
            if controller.showingInvitation {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Codex 雷达站 · 邀请你一起上榜").font(.headline)
                        Spacer()
                        Button { controller.dismissInvitation() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("暂不参加速蹬排行榜")
                    }
                    SpeedLeaderboardMovie()
                    Text("加入速蹬 Token 排行榜")
                        .font(.title3.bold())
                    Text("加入 Token 排行榜，看看各软件、各模型的速度。")
                        .font(.callout)
                    Toggle("参加速蹬排行榜", isOn: $joining).toggleStyle(.switch)
                    Text("仅上报 Token、速度、模型和软件统计，以及公开昵称、设备标识和客户端版本信息；不上传对话内容、文件路径或账号凭据。可随时在设置中关闭。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if joining {
                        Text("公开昵称：\(controller.username)。同一数据源请勿与 Agent Speed 重复上报。")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Button("设置与说明") {
                            controller.dismissInvitation()
                            AppSettingsRouteRequest.request(.speedReporting)
                        }.buttonStyle(.link)
                        Spacer()
                        Button("暂不参加") { controller.dismissInvitation() }
                        Button("开启并参加") { controller.setEnabled(true) }
                            .buttonStyle(.borderedProminent).disabled(!joining)
                    }
                }
                .padding(20).frame(width: 500)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.18), radius: 20, y: 6)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .task {
            // Startup may intentionally hide the dashboard after 250 ms. Do not consume
            // the one-time invitation while that window is invisible.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            invitationReady = true
            offerWhenVisible()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            offerWhenVisible()
        }
    }
    private func offerWhenVisible() {
        if invitationReady, NSApp.windows.contains(where: { !($0 is NSPanel) && $0.isVisible && $0.contentViewController != nil }) {
            controller.offerInvitation()
        }
    }
}

private struct SpeedLeaderboardMovie: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player = AVPlayer(url: Bundle.module.url(forResource: "leaderboard", withExtension: "mp4", subdirectory: "SpeedLeaderboard")!)
    @State private var playing = false
    var body: some View {
        ZStack(alignment: .bottom) {
            if let url = Bundle.module.url(forResource: "poster", withExtension: "jpg", subdirectory: "SpeedLeaderboard"),
               let poster = NSImage(contentsOf: url) {
                Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
            }
            LeaderboardPlayer(player: player).aspectRatio(1128.0 / 826.0, contentMode: .fit)
            HStack {
                Text("排行榜实录 · 非当前实时数据").font(.caption2)
                Spacer()
                Button {
                    if playing { player.pause(); playing = false }
                    else {
                        if let item = player.currentItem, player.currentTime() >= item.duration { player.seek(to: .zero) }
                        player.play(); playing = true
                    }
                } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                    .buttonStyle(.plain).accessibilityLabel(playing ? "暂停排行榜演示" : "播放排行榜演示")
            }.foregroundStyle(.white).padding(10).background(.black.opacity(0.8))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear {
            player.isMuted = true
            if !reduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled { player.play(); playing = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { event in
            guard let item = event.object as? AVPlayerItem, item === player.currentItem else { return }
            playing = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            player.pause(); playing = false
        }
        .onDisappear { player.pause() }
    }
}

private struct LeaderboardPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}
