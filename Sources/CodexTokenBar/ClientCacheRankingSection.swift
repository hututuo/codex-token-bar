import SwiftUI

/// Numeric local usage only. Requests are never mislabeled as whole turns when
/// the source ledger does not contain a verified user-turn boundary.
struct ClientCacheRankingSection: View {
    let client: UsageClient
    @ObservedObject private var store = MultiClientUsageStore.shared
    @State private var projection = ClientCacheRankingProjection.empty
    @State private var issue: String?
    @State private var showingRequests = false
    @State private var limit = 200
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("缓存命中排行 · " + client.displayName).font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("查看请求明细") { showingRequests = true }
            }
            Text("按会话加权 · 缓存读取 / 总输入 · 缓存写入不算命中")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let issue { Text(issue).foregroundStyle(AppTheme.accentAmber) }
            else if projection.sessions.isEmpty { Text("暂无可比较的本地用量记录").font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(projection.sessions.prefix(10)) { session in
                HStack(spacing: 14) {
                    Text(String(session.sessionID.suffix(12))).font(.system(size: 12, design: .monospaced))
                    Text(session.lastSeen, style: .date).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(session.requests) 请求 · \(session.lowHitRequests) 次低命中 · \(session.zeroHitRequests) 次零命中")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(rate(session.cacheHitRate)).font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(width: 72, alignment: .trailing)
                }
            }
        }
        .padding(20).background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 16))
        .task(id: "\(client.rawValue)|\(store.updatedAt?.timeIntervalSince1970 ?? 0)|\(limit)") {
            do { projection = try await store.cacheRankingProjection(clients: Set([client]), requestLimit: limit); issue = nil }
            catch { issue = "本地缓存排行暂不可用：\(error.localizedDescription)" }
        }
        .sheet(isPresented: $showingRequests) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(client.displayName + " · 请求用量").font(.title3.bold()); Spacer(); Button("关闭") { showingRequests = false } }
                Text("请求级记录；当前账本未保留可靠的整轮边界，因此不冒充单轮排行。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(projection.requests) { request in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(request.timestamp, format: .dateTime.month().day().hour().minute().second())
                                    Text(request.model).foregroundStyle(ModelUsagePresentation.color(for: request.model))
                                    Spacer(); Text(rate(request.cacheHitRate)).bold()
                                }
                                Text("会话 \(request.sessionID) · 请求 \(request.eventID)").textSelection(.enabled).foregroundStyle(.secondary)
                                Text("输入 \(request.inputTokens) · 缓存读 \(request.cacheReadTokens.map { String($0) } ?? "未知") · 缓存写 \(request.cacheWriteTokens.map { String($0) } ?? "未知") · 输出 \(request.outputTokens)")
                            }.font(.system(size: 11)).monospacedDigit()
                            Divider()
                        }
                    }
                }
                if projection.hasMoreRequests {
                    Text("已加载 \(projection.requests.count) / \(projection.matchingRequestCount) 条；未加载的记录仍保留在账本中。")
                        .font(.caption).foregroundStyle(.secondary)
                    if limit < 5000 { Button("加载更多") { limit = min(5000, limit + 500) } }
                }
            }.padding(24).frame(minWidth: 740, minHeight: 460)
        }
    }
    private func rate(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0 * 100) } ?? "缓存未知" }
}
