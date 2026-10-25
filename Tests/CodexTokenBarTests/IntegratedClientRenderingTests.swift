import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class IntegratedClientRenderingTests: XCTestCase {
    @MainActor func testQuotaComponentsRenderWithUnknownClaudeAndHistoricalCodexReading() throws {
        // 92% is the existing design's historical screenshot reading, not a live query.
        let codex = ClientQuotaItem(id: "codex:7d", client: "codex", window: "7d", remaining: 92,
            resetsAt: nil, source: "历史截图读数 · 非实时", status: "历史样本")
        let claude = ClientQuotaItem(id: "claudeCode:5h", client: "claudeCode", window: "5h", remaining: nil,
            resetsAt: nil, source: "本地缓存 · 未绑定账号", status: "未接入")
        let claudeSeven = ClientQuotaItem(id: "claudeCode:7d", client: "claudeCode", window: "7d", remaining: nil,
            resetsAt: nil, source: "本地缓存 · 未绑定账号", status: "未接入")
        let suite = "IntegratedQuotaRender-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let candidate = VStack(alignment: .leading, spacing: 14) {
            Text("候选组件真实渲染 · 历史样本，非安装版").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 14) {
                    Image(systemName: "pin").font(.caption).foregroundStyle(.secondary)
                    ClientPairedQuotaRing(left: codex, right: nil)
                    ClientPairedQuotaRing(left: claude, right: claudeSeven)
                    Text("单项整环 · 双项左右半环").font(.system(size: 9))
                }.padding(.vertical, 20).frame(width: 88).background(Color.black, in: RoundedRectangle(cornerRadius: 22))
                VStack(alignment: .leading, spacing: 14) {
                    Text("额度概览").font(.title3.bold())
                    Divider()
                    ClientQuotaRings(items: [codex, claude, claudeSeven])
                }.padding(20).frame(width: 400).background(Color.black, in: RoundedRectangle(cornerRadius: 24))
            }
        }.padding(24).frame(width: 584, height: 580, alignment: .topLeading)
            .background(Color(white: 0.07)).foregroundStyle(.white)
            .environment(\.colorScheme, .dark).defaultAppStorage(defaults)
        let host = NSHostingView(rootView: candidate)
        host.frame = CGRect(x: 0, y: 0, width: 584, height: 580)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let output = ProcessInfo.processInfo.environment["TOKENBAR_QUOTA_RENDER_OUTPUT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }
}
