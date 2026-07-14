import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ExporterFormat: Equatable {
    case csv
    case png
}

enum ExporterDestinationSelection {
    case cancelled
    case selected(URL)
    case unavailable(debugDescription: String)
}

enum DashboardExportFailureStage: Equatable {
    case destination
    case csvWrite
    case pngRender
    case pngTIFF
    case pngBitmap
    case pngEncode
    case pngWrite

    var userMessage: String {
        switch self {
        case .destination:
            "未能取得导出位置，请重新选择。"
        case .csvWrite:
            "无法写入 CSV 文件，请检查所选位置是否可写。"
        case .pngRender:
            "无法生成导出图像，请稍后重试。"
        case .pngTIFF:
            "无法读取导出图像数据，请稍后重试。"
        case .pngBitmap:
            "无法转换导出图像，请稍后重试。"
        case .pngEncode:
            "无法编码 PNG 文件，请稍后重试。"
        case .pngWrite:
            "无法写入 PNG 文件，请检查所选位置是否可写。"
        }
    }
}

struct DashboardExportFailure {
    let stage: DashboardExportFailureStage
    let debugDescription: String
}

enum DashboardExportResult {
    case cancelled
    case success
    case failure(DashboardExportFailure)
}

enum ExporterPNGRenderResult {
    case success(Data)
    case failure(DashboardExportFailureStage)
}

@MainActor
struct ExporterDependencies {
    let selectDestination: @MainActor (ExporterFormat) -> ExporterDestinationSelection
    let writeCSV: @MainActor (String, URL) throws -> Void
    let renderPNG: @MainActor (DashboardSnapshot) -> ExporterPNGRenderResult
    let writePNG: @MainActor (Data, URL) throws -> Void

    static var live: ExporterDependencies {
        ExporterDependencies(
            selectDestination: Exporter.selectDestination,
            writeCSV: { payload, url in
                try payload.write(to: url, atomically: true, encoding: .utf8)
            },
            renderPNG: Exporter.renderPNG,
            writePNG: { payload, url in
                try payload.write(to: url)
            }
        )
    }
}

struct DashboardExportAlertPresentation: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init?(result: DashboardExportResult) {
        guard case let .failure(failure) = result else { return nil }
        title = "导出失败"
        message = failure.stage.userMessage
    }
}

enum Exporter {
    @MainActor
    static func exportCSV(snapshot: DashboardSnapshot) -> DashboardExportResult {
        exportCSV(snapshot: snapshot, dependencies: .live)
    }

    @MainActor
    static func exportCSV(
        snapshot: DashboardSnapshot,
        dependencies: ExporterDependencies
    ) -> DashboardExportResult {
        let destination: URL
        switch dependencies.selectDestination(.csv) {
        case .cancelled:
            return .cancelled
        case let .selected(url):
            destination = url
        case let .unavailable(debugDescription):
            return .failure(
                DashboardExportFailure(stage: .destination, debugDescription: debugDescription)
            )
        }

        var lines = ["date,tokens,calls"]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        for day in snapshot.dailyUsage {
            lines.append("\(formatter.string(from: day.date)),\(day.tokens),\(day.calls)")
        }

        do {
            try dependencies.writeCSV(lines.joined(separator: "\n"), destination)
            return .success
        } catch {
            return .failure(
                DashboardExportFailure(
                    stage: .csvWrite,
                    debugDescription: String(reflecting: error)
                )
            )
        }
    }

    @MainActor
    static func exportPNG(snapshot: DashboardSnapshot) -> DashboardExportResult {
        exportPNG(snapshot: snapshot, dependencies: .live)
    }

    @MainActor
    static func exportPNG(
        snapshot: DashboardSnapshot,
        dependencies: ExporterDependencies
    ) -> DashboardExportResult {
        let destination: URL
        switch dependencies.selectDestination(.png) {
        case .cancelled:
            return .cancelled
        case let .selected(url):
            destination = url
        case let .unavailable(debugDescription):
            return .failure(
                DashboardExportFailure(stage: .destination, debugDescription: debugDescription)
            )
        }

        let png: Data
        switch dependencies.renderPNG(snapshot) {
        case let .success(data):
            png = data
        case let .failure(stage):
            return .failure(
                DashboardExportFailure(
                    stage: stage,
                    debugDescription: "PNG rendering failed at \(stage)"
                )
            )
        }

        do {
            try dependencies.writePNG(png, destination)
            return .success
        } catch {
            return .failure(
                DashboardExportFailure(
                    stage: .pngWrite,
                    debugDescription: String(reflecting: error)
                )
            )
        }
    }

    @MainActor
    fileprivate static func selectDestination(
        for format: ExporterFormat
    ) -> ExporterDestinationSelection {
        let panel = NSSavePanel()
        switch format {
        case .csv:
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "codex-token-usage.csv"
        case .png:
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "codex-token-bar.png"
        }

        let response = panel.runModal()
        if response == .cancel { return .cancelled }
        guard response == .OK else {
            return .unavailable(
                debugDescription: "NSSavePanel ended with response \(response.rawValue)"
            )
        }
        guard let url = panel.url else {
            return .unavailable(debugDescription: "NSSavePanel returned OK without a destination URL")
        }
        return .selected(url)
    }

    @MainActor
    fileprivate static func renderPNG(snapshot: DashboardSnapshot) -> ExporterPNGRenderResult {
        let view = ExportSnapshotView(snapshot: snapshot)
            .frame(width: 1320, height: 860)

        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 1320, height: 860)
        renderer.scale = 2

        guard let image = renderer.nsImage else { return .failure(.pngRender) }
        guard let tiff = image.tiffRepresentation else { return .failure(.pngTIFF) }
        guard let bitmap = NSBitmapImageRep(data: tiff) else { return .failure(.pngBitmap) }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return .failure(.pngEncode)
        }
        return .success(png)
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
                    status: "导出于 \(DateFormatter.statusString(from: Date()))",
                    dataSourceLabel: "本地数据",
                    dataSourceOrigin: "导出",
                    isRefreshing: false,
                    unreadThreadCount: 0,
                    presentationMode: .export,
                    onRefresh: {},
                    onMarkAllRead: {},
                    onChangeDirectory: {},
                    onOpenProviderSync: {},
                    threadDeleteStatus: .idle,
                    onThreadDeleteConnectionAction: {},
                    showingInterfaceScaleMenu: .constant(false),
                    interfaceScaleAutoEnabled: .constant(InterfaceScaleSettings.defaultAutoEnabled),
                    interfaceScaleManualMultiplier: .constant(InterfaceScaleSettings.defaultManualMultiplier),
                    showingResetCreditDetails: .constant(false)
                )
                StatStrip(snapshot: snapshot)
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
