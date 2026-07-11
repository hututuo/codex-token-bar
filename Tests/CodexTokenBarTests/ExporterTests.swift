import Foundation
import XCTest
@testable import CodexTokenBar

@MainActor
final class ExporterTests: XCTestCase {
    func testCSVWriteFailureReturnsVisibleFailureWithoutExposingDestination() {
        let destination = URL(fileURLWithPath: "/Users/example/private/codex-token-usage.csv")
        let dependencies = ExporterDependencies(
            selectDestination: { format in
                XCTAssertEqual(format, .csv)
                return .selected(destination)
            },
            writeCSV: { _, _ in throw StubError.writeFailed },
            renderPNG: { _ in .failure(.pngRender) },
            writePNG: { _, _ in XCTFail("PNG writer should not run for CSV export") }
        )

        let result = Exporter.exportCSV(snapshot: testSnapshot, dependencies: dependencies)

        assertFailure(result, stage: .csvWrite)
        let alert = DashboardExportAlertPresentation(result: result)
        XCTAssertEqual(alert?.title, "导出失败")
        XCTAssertEqual(alert?.message, "无法写入 CSV 文件，请检查所选位置是否可写。")
        XCTAssertFalse(alert?.message.contains(destination.path) ?? true)
    }

    func testPNGRenderFailureDoesNotAttemptWrite() {
        var writes = 0
        let dependencies = pngDependencies(
            renderResult: .failure(.pngRender),
            writePNG: { _, _ in writes += 1 }
        )

        let result = Exporter.exportPNG(snapshot: testSnapshot, dependencies: dependencies)

        assertFailure(result, stage: .pngRender)
        XCTAssertEqual(writes, 0)
    }

    func testPNGEncodeFailureDoesNotAttemptWrite() {
        var writes = 0
        let dependencies = pngDependencies(
            renderResult: .failure(.pngEncode),
            writePNG: { _, _ in writes += 1 }
        )

        let result = Exporter.exportPNG(snapshot: testSnapshot, dependencies: dependencies)

        assertFailure(result, stage: .pngEncode)
        XCTAssertEqual(writes, 0)
    }

    func testPNGWriteFailureReturnsVisibleFailureWithoutExposingDestination() {
        let destination = URL(fileURLWithPath: "/Users/example/private/codex-token-bar.png")
        let dependencies = ExporterDependencies(
            selectDestination: { _ in .selected(destination) },
            writeCSV: { _, _ in XCTFail("CSV writer should not run for PNG export") },
            renderPNG: { _ in .success(Data([0x89, 0x50, 0x4E, 0x47])) },
            writePNG: { _, _ in throw StubError.writeFailed }
        )

        let result = Exporter.exportPNG(snapshot: testSnapshot, dependencies: dependencies)

        assertFailure(result, stage: .pngWrite)
        let alert = DashboardExportAlertPresentation(result: result)
        XCTAssertEqual(alert?.message, "无法写入 PNG 文件，请检查所选位置是否可写。")
        XCTAssertFalse(alert?.message.contains(destination.path) ?? true)
    }

    func testCancellationReturnsCancelledWithoutRenderingOrWriting() {
        var csvWrites = 0
        var renders = 0
        var pngWrites = 0
        let dependencies = ExporterDependencies(
            selectDestination: { _ in .cancelled },
            writeCSV: { _, _ in csvWrites += 1 },
            renderPNG: { _ in
                renders += 1
                return .success(Data())
            },
            writePNG: { _, _ in pngWrites += 1 }
        )

        let csvResult = Exporter.exportCSV(snapshot: testSnapshot, dependencies: dependencies)
        let pngResult = Exporter.exportPNG(snapshot: testSnapshot, dependencies: dependencies)

        assertCancelled(csvResult)
        assertCancelled(pngResult)
        XCTAssertNil(DashboardExportAlertPresentation(result: csvResult))
        XCTAssertNil(DashboardExportAlertPresentation(result: pngResult))
        XCTAssertEqual(csvWrites, 0)
        XCTAssertEqual(renders, 0)
        XCTAssertEqual(pngWrites, 0)
    }

    func testUnavailableDestinationReturnsFailureInsteadOfCancellation() {
        var writes = 0
        let dependencies = ExporterDependencies(
            selectDestination: { _ in
                .unavailable(debugDescription: "save panel returned no URL")
            },
            writeCSV: { _, _ in writes += 1 },
            renderPNG: { _ in .success(Data()) },
            writePNG: { _, _ in writes += 1 }
        )

        let result = Exporter.exportCSV(snapshot: testSnapshot, dependencies: dependencies)

        assertFailure(result, stage: .destination)
        XCTAssertEqual(
            DashboardExportAlertPresentation(result: result)?.message,
            "未能取得导出位置，请重新选择。"
        )
        XCTAssertEqual(writes, 0)
    }

    func testSuccessfulExportsReturnSuccessAndPreservePayloads() {
        var csvPayload: String?
        var pngPayload: Data?
        let pngData = Data([0x89, 0x50, 0x4E, 0x47])
        let dependencies = ExporterDependencies(
            selectDestination: { format in
                switch format {
                case .csv:
                    return .selected(URL(fileURLWithPath: "/unused/export.csv"))
                case .png:
                    return .selected(URL(fileURLWithPath: "/unused/export.png"))
                }
            },
            writeCSV: { payload, _ in csvPayload = payload },
            renderPNG: { _ in .success(pngData) },
            writePNG: { payload, _ in pngPayload = payload }
        )

        let csvResult = Exporter.exportCSV(snapshot: testSnapshot, dependencies: dependencies)
        let pngResult = Exporter.exportPNG(snapshot: testSnapshot, dependencies: dependencies)

        assertSuccess(csvResult)
        assertSuccess(pngResult)
        XCTAssertEqual(csvPayload, expectedCSV)
        XCTAssertEqual(pngPayload, pngData)
        XCTAssertNil(DashboardExportAlertPresentation(result: csvResult))
        XCTAssertNil(DashboardExportAlertPresentation(result: pngResult))
    }

    func testEveryFailureStageHasAConciseUserMessage() {
        let expectedMessages: [(DashboardExportFailureStage, String)] = [
            (.destination, "未能取得导出位置，请重新选择。"),
            (.csvWrite, "无法写入 CSV 文件，请检查所选位置是否可写。"),
            (.pngRender, "无法生成导出图像，请稍后重试。"),
            (.pngTIFF, "无法读取导出图像数据，请稍后重试。"),
            (.pngBitmap, "无法转换导出图像，请稍后重试。"),
            (.pngEncode, "无法编码 PNG 文件，请稍后重试。"),
            (.pngWrite, "无法写入 PNG 文件，请检查所选位置是否可写。")
        ]

        for (stage, message) in expectedMessages {
            XCTAssertEqual(stage.userMessage, message)
            XCTAssertLessThan(message.count, 32)
        }
    }

    private var testSnapshot: DashboardSnapshot {
        DashboardSnapshot(
            stats: .emptyForExportTests,
            dailyUsage: [
                DayUsage(date: Date(timeIntervalSince1970: 1_700_000_000), tokens: 42, calls: 3)
            ],
            recentBins: [],
            hourlyUsage: [],
            pluginUsage: [],
            cacheUsage: .empty,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    private var expectedCSV: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000))
        return "date,tokens,calls\n\(day),42,3"
    }

    private func pngDependencies(
        renderResult: ExporterPNGRenderResult,
        writePNG: @MainActor @escaping (Data, URL) throws -> Void
    ) -> ExporterDependencies {
        ExporterDependencies(
            selectDestination: { format in
                XCTAssertEqual(format, .png)
                return .selected(URL(fileURLWithPath: "/unused/export.png"))
            },
            writeCSV: { _, _ in XCTFail("CSV writer should not run for PNG export") },
            renderPNG: { _ in renderResult },
            writePNG: writePNG
        )
    }

    private func assertCancelled(
        _ result: DashboardExportResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .cancelled = result else {
            return XCTFail("Expected cancelled export result", file: file, line: line)
        }
    }

    private func assertSuccess(
        _ result: DashboardExportResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .success = result else {
            return XCTFail("Expected successful export result", file: file, line: line)
        }
    }

    private func assertFailure(
        _ result: DashboardExportResult,
        stage: DashboardExportFailureStage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failure(failure) = result else {
            return XCTFail("Expected failed export result", file: file, line: line)
        }
        XCTAssertEqual(failure.stage, stage, file: file, line: line)
        XCTAssertFalse(failure.debugDescription.isEmpty, file: file, line: line)
    }
}

private enum StubError: Error {
    case writeFailed
}

private extension DashboardStats {
    static let emptyForExportTests = DashboardStats(
        totalTokens: 0,
        peakDayTokens: 0,
        peakThreadTokens: 0,
        currentStreakDays: 0,
        longestStreakDays: 0,
        totalCalls: 0,
        totalThreads: 0,
        mostUsedReasoning: "未知",
        skillsExplored: 0,
        totalSkillsUsed: 0
    )
}
