import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class SpeedDisplayPreviewTests: XCTestCase {
    @MainActor
    func testIsolatedPreview() throws {
        guard let output = ProcessInfo.processInfo.environment["TOKENBAR_SPEED_DISPLAY_PREVIEW_OUTPUT"] else { throw XCTSkip("Opt-in isolated UI preview") }
        let name = "preview.speed-display." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        let preferences = SpeedDisplayPreferences(defaults: defaults); preferences.setMode(.agentSpeed)
        let models: [ModelRateContribution] = [.init(model: "gpt-6-astra", tokensPerSecond: 40), .init(model: "claude-opus-5", tokensPerSecond: 60), .init(model: "deepseek-v4-flash", tokensPerSecond: 100)]
        let clients: [ModelRateContribution] = [.init(model: "client:codex", tokensPerSecond: 40), .init(model: "client:claudeCode", tokensPerSecond: 60), .init(model: "client:deepseek", tokensPerSecond: 100)]
        let content = VStack(alignment: .leading, spacing: 20) {
            HStack { Text("速度显示与彩条").font(.system(size: 24, weight: .semibold)); Spacer(); Text("演示数据 · 未开启上报").foregroundStyle(.secondary) }
            SpeedDisplayControls(preferences: preferences)
            ForEach([false, true], id: \.self) { byClient in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(byClient ? "按客户端" : "按模型").font(.headline); Spacer(); Text("200.0 tok/s").font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit() }
                    Capsule().fill(LinearGradient(stops: ModelRatePresentation.stops(byClient ? clients : models), startPoint: .leading, endPoint: .trailing)).frame(height: 12)
                    HStack(spacing: 20) {
                        ForEach(ModelRatePresentation.slices(byClient ? clients : models)) { slice in
                            HStack(spacing: 5) { Circle().fill(slice.color).frame(width: 7, height: 7); Text(ModelUsagePresentation.label(for: slice.model)); Text("\(Int(slice.tokensPerSecond)) tok/s").foregroundStyle(.secondary) }.font(.system(size: 12))
                        }
                    }
                }.padding(18).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
            Text("本地：结束／错误即归零；日志 20 秒未更新归零。上报：保持 Agent Speed 标准口径。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Divider()
            HStack { Text("在累计界面双击模型，即可修改该模型颜色"); Spacer(); ClientColorSettings() }.font(.caption)
        }.padding(28).frame(width: 880).background(Color(red: 0.045, green: 0.055, blue: 0.07)).foregroundStyle(.white).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content); renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
}
