import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Exporter {
    @MainActor
    static func exportCSV(snapshot: DashboardSnapshot) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "codex-token-usage.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines = ["date,tokens,calls"]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        for day in snapshot.dailyUsage {
            lines.append("\(formatter.string(from: day.date)),\(day.tokens),\(day.calls)")
        }

        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor
    static func exportPNG(snapshot: DashboardSnapshot) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "codex-token-bar.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let view = ExportSnapshotView(snapshot: snapshot)
            .frame(width: 1320, height: 860)

        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 1320, height: 860)
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return
        }

        try? png.write(to: url)
    }
}

struct ExportSnapshotView: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        ZStack {
            Color.white
            VStack(spacing: 24) {
                HeaderView(
                    snapshot: snapshot,
                    quotaSnapshot: .empty,
                    status: "Exported \(DateFormatter.status.string(from: Date()))",
                    dataSourceLabel: "本地数据",
                    dataSourceOrigin: "导出",
                    isRefreshing: false,
                    onRefresh: {},
                    onChangeDirectory: {},
                    onOpenProviderSync: {}
                )
                StatStrip(stats: snapshot.stats)
                ActivitySection(
                    dailyUsage: snapshot.dailyUsage,
                    cacheDaily: snapshot.cacheUsage.daily,
                    quotaDaily: [],
                    selectedMode: .constant(.daily)
                )
                RecentUsageChart(
                    bins: snapshot.recentBins,
                    hourlyBins: snapshot.hourlyUsage,
                    cacheRecentBins: snapshot.cacheUsage.recentBins,
                    cacheHourlyBins: snapshot.cacheUsage.hourly,
                    quotaRecentBins: [],
                    quotaHourlyBins: []
                )
            }
            .padding(54)
        }
    }
}
