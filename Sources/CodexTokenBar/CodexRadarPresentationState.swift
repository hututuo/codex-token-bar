import Foundation

struct CodexRadarStatusBadge: Equatable {
    let title: String
    let accessibilityText: String
}

struct CodexRadarDetailWarning: Equatable {
    let title: String
    let message: String
    let accessibilityText: String
}

struct CodexRadarEmptyState: Equatable {
    let title: String
    let message: String
}

struct CodexRadarPresentationState: Equatable {
    let snapshot: CodexRadarSnapshot?
    let status: String
    let diagnostics: [CodexRadarDiagnostic]
    let staleDataDisplayed: Bool
    let feedStaleDataDisplayed: Bool
    let crowdSnapshot: CodexCrowdRadarSnapshot?

    init(
        snapshot: CodexRadarSnapshot? = nil,
        status: String = "Codex 雷达待读取",
        diagnostics: [CodexRadarDiagnostic] = [],
        staleDataDisplayed: Bool = false,
        feedStaleDataDisplayed: Bool = false,
        crowdSnapshot: CodexCrowdRadarSnapshot? = nil
    ) {
        self.snapshot = snapshot
        self.status = status
        self.diagnostics = diagnostics
        self.staleDataDisplayed = staleDataDisplayed
        self.feedStaleDataDisplayed = feedStaleDataDisplayed
        self.crowdSnapshot = crowdSnapshot
    }

    var stripStatusText: String {
        guard let snapshot else { return status }
        let refreshLabel = snapshot.monitoredAt.isEmpty ? "已读取" : snapshot.monitoredAt
        if staleDataDisplayed {
            return firstDiagnosticMessage ?? "读取失败，显示旧雷达"
        }
        if feedStaleDataDisplayed {
            return "RSS 读取失败 · \(refreshLabel)"
        }
        return "10分钟刷新 · \(refreshLabel)"
    }

    var statusBadge: CodexRadarStatusBadge? {
        if staleDataDisplayed {
            return CodexRadarStatusBadge(title: "旧", accessibilityText: "当前显示上次成功读取的 Codex 雷达")
        }
        if feedStaleDataDisplayed {
            return CodexRadarStatusBadge(title: "RSS", accessibilityText: "RSS 历史读取失败，资讯列表可能是旧数据")
        }
        if snapshot == nil, !diagnostics.isEmpty {
            return CodexRadarStatusBadge(title: "失败", accessibilityText: "Codex 雷达读取失败")
        }
        return nil
    }

    var detailWarning: CodexRadarDetailWarning? {
        if staleDataDisplayed {
            let message = firstDiagnosticMessage ?? "正在显示上次成功读取的雷达数据。"
            return CodexRadarDetailWarning(
                title: "显示上次成功读取的雷达",
                message: message,
                accessibilityText: "Codex 雷达刷新失败，\(message)"
            )
        }
        if feedStaleDataDisplayed {
            let message = firstDiagnosticMessage ?? "RSS 历史读取失败，当前资讯列表可能仍是上次成功读取的内容。"
            return CodexRadarDetailWarning(
                title: "RSS 历史暂未更新",
                message: message,
                accessibilityText: "Codex 雷达 RSS 读取失败，\(message)"
            )
        }
        return nil
    }

    var emptyState: CodexRadarEmptyState? {
        guard snapshot == nil, !diagnostics.isEmpty else { return nil }
        return CodexRadarEmptyState(
            title: "Codex 雷达读取失败",
            message: firstDiagnosticMessage ?? status
        )
    }

    var compactMarkerText: String? {
        statusBadge?.title
    }

    var compactAccessibilityText: String? {
        if let statusBadge {
            return statusBadge.accessibilityText
        }
        return nil
    }

    private var firstDiagnosticMessage: String? {
        diagnostics.first(where: { $0.category != .staleCachedData })?.message
            ?? diagnostics.first?.message
    }
}
