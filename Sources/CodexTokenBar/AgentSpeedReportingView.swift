import AppKit
import SwiftUI
import AVKit

struct AgentSpeedReportingSettingsView: View {
    @ObservedObject private var controller = AgentSpeedReportingController.shared
    @State private var nickname = ""
    @State private var confirming = false
    @State private var showNickname = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("速蹬排行榜", systemImage: "speedometer").font(.title3.bold())
                Spacer()
                Toggle("参加排行榜", isOn: Binding(get: { controller.enabled }, set: {
                    if $0 { if controller.username.hasPrefix("TokenBar-") { nickname = "" }; confirming = true } else { controller.setEnabled(false) }
                })).toggleStyle(.switch)
            }
            Text("按 Agent Speed 标准统计各软件的请求速度，与你的正文 TPS 独立。")
            Picker("上报方式", selection: Binding(get: { controller.transport }, set: { controller.setTransport($0) })) {
                Text("HTTP（默认）").tag(AgentSpeedReportingMode.http)
                Text("WebSocket 即时").tag(AgentSpeedReportingMode.websocket)
            }.pickerStyle(.segmented)
            Text("WebSocket 网络连接失败时自动回退 HTTP；手动重试可再尝试 WebSocket。日志写入仍可能延迟。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("公开昵称")
                TextField("排行榜昵称", text: $nickname).textFieldStyle(.roundedBorder)
                    .disabled(controller.enabled)
            }
            Text("仅上报速度、Token、估算费用、模型、Harness 和运行统计，以及昵称、设备标识和客户端版本信息；不上传对话、文件路径或账号凭据。Claude Code／Desktop 始终只在本地读取，不参与上报。关闭后停止榜单上报；本地速度显示由速度算法设置独立控制。")
                .font(.callout).foregroundStyle(.secondary)
            Text("同一台电脑的同一数据源，请只在 Agent Speed 或 Token Bar 中开启一处上报，避免重复累计。")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack {
                Circle().fill(controller.enabled ? (controller.phase == "error" ? Color.red : (controller.phase == "running" && controller.lastReportAt != nil ? Color.green : Color.orange)) : Color.secondary).frame(width: 8, height: 8)
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
                Text("Claude Code／Desktop 只在本机统计，不上报。可上报：Codex、DSH、OpenCode、Gemini CLI、omp、Antigravity、WorkBuddy、WorkBuddy AI、ZCode、Kimi Code、Grok Build。自动发现本地默认目录及环境变量指定的目录；云端未落地的会话无法统计。")
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
            Button("同意参加，下一步") { showNickname = true }
        } message: {
            Text("开启后将以“\(nickname)”公开参与排行榜，发送各软件的速度、Token、估算费用、模型和 Harness 等统计。请确认这台电脑没有另一客户端重复上报。你可以随时在这里关闭。")
        }
        .sheet(isPresented: $showNickname) {
            SpeedReportingNicknameStep(nickname: $nickname, onBack: { showNickname = false }) {
                controller.setEnabled(true, username: nickname)
                if controller.enabled { showNickname = false }
            }.padding(24).frame(width: 440)
        }
    }
}

/// A lightweight status row, independent of local TPS and radar data. Disabled
/// reporting contributes no placeholder or invitation to the dashboard.
struct AgentSpeedReportingDashboardStatus: View {
    @ObservedObject private var controller = AgentSpeedReportingController.shared
    var body: some View {
        if controller.enabled {
            HStack(spacing: 10) {
                Image(systemName: controller.phase == "error" ? "exclamationmark.triangle" : "arrow.up.circle")
                    .foregroundStyle(controller.phase == "error" ? Color.orange : AppTheme.accentBlue)
                Text("速蹬上报").fontWeight(.semibold)
                Text(controller.message).lineLimit(2)
                Spacer(minLength: 8)
                if controller.phase == "running", let date = controller.lastReportAt {
                    Text("最近上报 " + date.formatted(date: .omitted, time: .standard)).monospacedDigit()
                }
                if controller.phase == "error" { Button("重试连接") { controller.retry() } }
                Button("设置") { AppSettingsRouteRequest.request(.speedReporting) }.buttonStyle(.link)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: 980, alignment: .leading)
            .background(controller.phase == "error" ? Color.orange.opacity(0.09) : AppTheme.solidControlBackground,
                in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .contain).accessibilityLabel("速蹬上报状态")
        }
    }
}

/// Bundled recording, not a remote web view: showing this invitation never contacts the leaderboard.
struct AgentSpeedReportingInvitation: View {
    @ObservedObject private var controller = AgentSpeedReportingController.shared
    @State private var joining = false
    @State private var naming = false
    @State private var nickname = ""
    @State private var invitationReady = false
    @ObservedObject private var clients = MultiClientUsageStore.shared
    @AppStorage("product.newFeatures.localClientsSpeed.v1") private var featuresHandled = false
    @State private var showingFeatures = false
    @State private var showDetails = false
    @State private var offeredClient: UsageClient?
    @State private var offeredLeaderboard = false
    @State private var localEnabled = false
    private var localCandidate: UsageClient? { clients.newDetections.first { $0.client == .claudeCode }?.client }
    var body: some View {
        Group {
            if showingFeatures {
                if !showDetails {
                    HarnessNewFeaturesView(offerLeaderboard: offeredLeaderboard,
                        localClient: offeredClient?.displayName, localEnabled: localEnabled,
                        enableLocal: { if let client = offeredClient { clients.enable(client); localEnabled = true } },
                        joinLeaderboard: { showDetails = true }, dismiss: finishFeatures)
                } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Codex 雷达站 · 邀请你一起上榜").font(.headline)
                        Spacer()
                        Button { finishFeatures() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("暂不参加速蹬排行榜")
                    }
                    if !naming {
                    SpeedLeaderboardMovie()
                    Text("加入速蹬 Token 排行榜")
                        .font(.title3.bold())
                    Text("加入 Token 排行榜，看看各软件、各模型的速度。")
                        .font(.callout)
                    Toggle("① 参加速蹬排行榜", isOn: $joining).toggleStyle(.switch)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 9).fill((joining ? Color.green : Color.blue).opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder((joining ? Color.green : Color.blue).opacity(0.45)))
                    Text(joining ? "已选择参加 → 下一步填写您的昵称" : "↑ 先打开上方开关，再点右下角“下一步”")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.blue)
                        .lineLimit(1).minimumScaleFactor(0.8).frame(height: 18, alignment: .leading)
                    Text("仅上报 Token、速度、估算费用、模型和软件统计，以及公开昵称、设备标识和客户端版本信息；不上传对话内容、文件路径或账号凭据。可随时在设置中关闭。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("下一步设置公开昵称。同一数据源请勿与 Agent Speed 重复上报。")
                        .font(.caption).lineLimit(2).frame(height: 32, alignment: .topLeading)
                    HStack(spacing: 12) {
                        Button("设置与说明") {
                            finishFeatures()
                            AppSettingsRouteRequest.request(.speedReporting)
                        }.buttonStyle(.link)
                        Spacer()
                        Button("暂不参加") { finishFeatures() }
                        Button("同意参加，下一步") {
                            nickname = controller.username.hasPrefix("TokenBar-") ? "" : controller.username
                            naming = true
                        }
                            .buttonStyle(.borderedProminent).disabled(!joining)
                            .help(joining ? "确认参加并开始上报" : "先打开上方“参加速蹬排行榜”开关")
                    }
                    } else {
                        SpeedReportingNicknameStep(nickname: $nickname, onBack: { naming = false }) {
                            controller.setEnabled(true, username: nickname)
                            if controller.enabled { finishFeatures() }
                        }.frame(minHeight: 310)
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
        }
        .onChange(of: clients.newDetections.map { $0.client.rawValue }) { _, _ in offerWhenVisible() }
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
    private func finishFeatures() {
        featuresHandled = true
        if let client = offeredClient { clients.acknowledge(client) }
        controller.dismissInvitation()
        showingFeatures = false
        showDetails = false
    }
    private func offerWhenVisible() {
        if invitationReady, NSApp.windows.contains(where: { !($0 is NSPanel) && $0.isVisible && $0.contentViewController != nil }) {
            guard !showingFeatures, (!featuresHandled && !controller.enabled) || localCandidate != nil else { return }
            offeredClient = localCandidate
            offeredLeaderboard = !controller.enabled && !featuresHandled
            localEnabled = false
            showDetails = false
            showingFeatures = true
        }
    }
}

private struct SpeedReportingNicknameStep: View {
    @Binding var nickname: String
    let onBack: () -> Void
    let onJoin: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("② 设置排行榜昵称").font(.callout.weight(.semibold)).foregroundStyle(Color.blue)
            Text("怎么称呼您？").font(.title2.bold())
            Text("这个昵称会公开显示在排行榜上。")
            TextField("请输入您的昵称", text: $nickname).textFieldStyle(.roundedBorder).focused($focused)
            Text("2–32 个字符。上报方式默认 HTTP，可在设置中选择 WebSocket。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("上一步", action: onBack)
                Spacer()
                Button("开启并参加", action: onJoin).buttonStyle(.borderedProminent)
                    .disabled(nickname.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count < 2 || nickname.unicodeScalars.count > 32)
            }
        }.onAppear { focused = true }
    }
}

struct SpeedLeaderboardMovie: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player = AVPlayer(url: Bundle.module.url(forResource: "leaderboard", withExtension: "mp4", subdirectory: "SpeedLeaderboard")!)
    @State private var playing = false
    @State private var playback = LeaderboardMoviePlayback()
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    var body: some View {
        ZStack(alignment: .bottom) {
            if let url = Bundle.module.url(forResource: "poster", withExtension: "jpg", subdirectory: "SpeedLeaderboard"),
               let poster = NSImage(contentsOf: url) {
                Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
            }
            LeaderboardPlayer(player: player).aspectRatio(1684.0 / 1100.0, contentMode: .fit)
            HStack {
                Text("排行榜实录 · 非当前实时数据").font(.caption2)
                Spacer()
                Button {
                    playback.intent = playing ? .pause : .play
                    updatePlayback()
                } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                    .buttonStyle(.plain).accessibilityLabel(playing ? "暂停排行榜演示" : "播放排行榜演示")
            }.foregroundStyle(.white).padding(10).background(.black.opacity(0.8))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .background(AnimationVisibilityProbe { visible in
            playback.visible = visible
            updatePlayback()
        })
        .onAppear {
            player.isMuted = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { event in
            guard let item = event.object as? AVPlayerItem, item === player.currentItem else { return }
            player.seek(to: .zero)
            updatePlayback()
        }
        .onChange(of: reduceMotion) { _, _ in updatePlayback() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            updatePlayback()
        }
        .onDisappear { playback.visible = false; updatePlayback() }
    }
    private func updatePlayback() {
        playing = playback.shouldPlay(reducedMotion: reduceMotion, lowPower: lowPower)
        if playing { player.isMuted = true; player.play() }
        else { player.pause() }
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
