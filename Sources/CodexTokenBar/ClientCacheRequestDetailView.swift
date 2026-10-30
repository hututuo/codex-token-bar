import SwiftUI

/// Reuses the existing read-only numeric ledger query; no conversation or network access.
struct ClientCacheRequestDetailView: View {
    let session: ClientCacheRankingSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = MultiClientUsageStore.shared
    @State private var projection = ClientCacheRankingProjection.empty
    @State private var limit = 200
    @State private var issue: String?
    var body: some View {
        let requests = projection.requests.filter { $0.sessionID == session.sessionID && $0.client == session.client }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(session.client.displayName + " · 请求用量").font(.title3.bold())
                Spacer(); Button("关闭") { dismiss() }
            }
            Text("会话 \(session.sessionID) · 本批已加载 \(requests.count) 条请求")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("会话加权；本地账本没有可靠的轮次边界，不将请求冒充轮次。")
                .font(.caption).foregroundStyle(.secondary)
            if let issue { Text(issue).foregroundStyle(AppTheme.accentAmber) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(requests) { request in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(request.timestamp, format: .dateTime.month().day().hour().minute().second())
                                Text(request.model)
                                Spacer()
                                Text(request.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "缓存未知").bold()
                            }
                            Text("请求 \(request.eventID)").foregroundStyle(.secondary).textSelection(.enabled)
                            Text("输入 \(request.inputTokens) · 缓存读 \(request.cacheReadTokens.map { String($0) } ?? "未知") · 缓存写 \(request.cacheWriteTokens.map { String($0) } ?? "未知") · 输出 \(request.outputTokens)")
                        }.font(.system(size: 11)).monospacedDigit()
                        Divider()
                    }
                }
            }
            if projection.hasMoreRequests {
                Text("客户端本批 \(projection.requests.count) / \(projection.matchingRequestCount) 条；这里只展示所选会话，未加载记录仍保留在账本。")
                    .font(.caption).foregroundStyle(.secondary)
                if limit < 5000 { Button("加载更多") { limit = min(5000, limit + 500) } }
            }
        }.padding(24).frame(minWidth: 740, minHeight: 460)
            .task(id: "\(session.id)|\(limit)|\(store.updatedAt?.timeIntervalSince1970 ?? 0)") {
                do {
                    let result = try await store.cacheRankingProjection(clients: [session.client], requestLimit: limit)
                    guard !Task.isCancelled else { return }
                    projection = result; issue = nil
                } catch { if !Task.isCancelled { issue = "本地请求明细暂不可用：\(error.localizedDescription)" } }
            }
    }
}
