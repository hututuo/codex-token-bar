import SwiftUI

struct HarnessNewFeaturesView: View {
    let offerLeaderboard: Bool
    let localClient: String?
    let localEnabled: Bool
    let enableLocal: () -> Void
    let joinLeaderboard: () -> Void
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本次更新").font(.title2.bold())
                    Text("新特性，由你选择开启").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("稍后了解新特性")
            }
            if offerLeaderboard {
                SpeedLeaderboardMovie().frame(maxHeight: 180).clipped()
                feature(title: "参加速蹬排行榜", icon: "chart.bar.xaxis", detail: "可选择上报速度、Token、模型等统计。不上传对话、文件路径或账号凭据，可随时关闭。") {
                    Button("了解并参加", action: joinLeaderboard).buttonStyle(.borderedProminent)
                }
            }
            if let localClient {
                feature(title: "识别到 \(localClient) 客户端", icon: "externaldrive", detail: "是否启用本地 Token 用量统计？仅读取本地，不产生任何网络请求。不会自动参加排行榜，可随时关闭。") {
                    Button(localEnabled ? "已启用" : "启用本地统计", action: enableLocal)
                        .buttonStyle(.borderedProminent).disabled(localEnabled)
                }
            }
            HStack { Text((offerLeaderboard && localClient != nil ? "两个选项独立，" : "") + "稍后也可在设置中调整。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("知道了", action: dismiss) }
        }.padding(22).frame(width: 510)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.18), radius: 20, y: 6)
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            .onExitCommand(perform: dismiss)
    }
    private func feature<Actions: View>(title: String, icon: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(AppTheme.accentBlue).frame(width: 28).padding(.top, 2)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                actions().padding(.top, 2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(AppTheme.insetBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}
