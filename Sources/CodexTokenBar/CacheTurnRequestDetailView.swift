import SwiftUI

/// Request rows come from the retained canonical index only when opened.
/// They never trigger rollout scans or become part of the ticking dashboard payload.
struct CacheTurnRequestDetailView: View {
    let turn: TurnCacheUsage
    let codexHome: URL
    @Environment(\.dismiss) private var dismiss
    @State private var requests: [CacheRequestUsage] = []
    @State private var loading = false
    @State private var hasMore = false
    @State private var errorMessage: String?
    @State private var readGeneration = UUID()
    private let pageSize = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本轮请求明细").font(.title3.bold())
                    Text("\(turn.sessionTitle) · 第 \(turn.turnIndexInSession) 轮")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("刷新") { Task { await load(reset: true) } }.disabled(loading)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 20) {
                Text("整轮加权 \(String(format: "%.2f%%", turn.breakdown.cacheHitRate * 100))").font(.headline)
                Text("\(turn.requestCount) 次请求 · 低命中 \(turn.lowHitCount) 次 · 零命中 \(turn.zeroHitCount) 次")
                    .font(.callout)
            }
            Text("低命中：输入 ≥ 2 万且命中率 < 30%。零命中：有输入且缓存命中为 0；符合低命中条件的零命中也计入低命中次数。输出已含思考，不重复相加。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 8) {
                Text("时间 / 模型").frame(maxWidth: .infinity, alignment: .leading)
                column("输入"); column("缓存命中"); column("未命中")
                column("输出"); column("总量"); column("命中率")
            }
            .font(.caption.bold()).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(requests) { request in
                        requestRow(request)
                        Divider()
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if requests.isEmpty && !loading {
                Text("暂未找到可用的请求记录；请等待精确索引更新后重试。")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("已显示 \(requests.count) 次请求").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                if hasMore {
                    Button("继续加载") { Task { await load(reset: false) } }.disabled(loading)
                }
            }
        }
        .padding(20)
        .frame(width: 940, height: 560)
        .background(AppTheme.panelBackground)
        .task(id: "\(codexHome.path):\(turn.id):\(turn.requestCount)") {
            await load(reset: true)
        }
    }

    private func column(_ text: String) -> some View {
        Text(text).frame(width: 84, alignment: .trailing)
    }

    private func requestRow(_ request: CacheRequestUsage) -> some View {
        let usage = request.breakdown
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(request.timestamp, format: .dateTime.month().day().hour().minute().second())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                HStack(spacing: 6) {
                    Text(request.model ?? "未知模型")
                        .foregroundStyle(ModelUsagePresentation.color(for: request.model))
                    if request.isZeroHit { Text("零命中").foregroundStyle(.red) }
                    else if request.isLowHit { Text("低命中").foregroundStyle(.orange) }
                }.font(.caption2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            column(usage.inputTokens.formatted())
            column(usage.cachedInputTokens.formatted())
            column(usage.uncachedInputTokens.formatted())
            column(usage.outputTokens.formatted())
            column(usage.totalTokens.formatted())
            column(usage.inputTokens > 0 ? String(format: "%.2f%%", usage.cacheHitRate * 100) : "—")
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 8)
        .textSelection(.enabled)
    }

    @MainActor private func load(reset: Bool) async {
        guard reset || !loading else { return }
        let generation = UUID()
        readGeneration = generation
        loading = true
        errorMessage = nil
        let offset = reset ? 0 : requests.count
        if reset { requests = []; hasMore = false }
        do {
            let home = codexHome
            let turnID = turn.id
            let result = try await Task.detached(priority: .utility) {
                try CodexUsageHistoryIndex.readCacheRequests(
                    codexHome: home, turnID: turnID, offset: offset, limit: 101
                )
            }.value
            guard generation == readGeneration else { return }
            guard !Task.isCancelled else { loading = false; return }
            let page = Array(result.prefix(pageSize))
            requests = reset ? page : requests + page
            hasMore = result.count > pageSize
        } catch {
            guard generation == readGeneration else { return }
            if !Task.isCancelled { errorMessage = "请求明细读取失败：\(error.localizedDescription)" }
        }
        loading = false
    }
}
