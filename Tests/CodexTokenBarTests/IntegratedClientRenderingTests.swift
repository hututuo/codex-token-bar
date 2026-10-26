import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class IntegratedClientRenderingTests: XCTestCase {
    @MainActor func testQuotaComponentsRenderWithMatchedSidebarMetricsAndDisplayOnlyMockQuota() throws {
        let fixtures = ClientQuotaProjection.previewItems(includeClaude: true)
        let codex = fixtures[0], claude = fixtures[1], claudeSeven = fixtures[2]
        let suite = "IntegratedQuotaRender-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let candidate = VStack(alignment: .leading, spacing: 14) {
            Text("候选原生组件渲染 · 额度均为模拟数据").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 12) {
                    ForEach(fixtures) { item in
                        ClientQuotaRailTrack(item: item, height: 46, fillHex: item.fill)
                    }
                }.padding(.vertical, 15).frame(width: 16).background(Color.black, in: Capsule())
                VStack(spacing: 14) {
                    Image(systemName: "pin").font(.caption).foregroundStyle(.secondary)
                    ZStack {
                        Circle().stroke(.white.opacity(0.15), lineWidth: 3)
                        Circle().trim(from: 0, to: 0.62).stroke(Color(red: 120.0/255, green: 183.0/255, blue: 1), style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                        Text("速率").font(.system(size: 11))
                    }.frame(width: ClientSidebarMetrics.ringSize, height: ClientSidebarMetrics.ringSize)
                    ClientPairedQuotaRing(left: codex, right: nil)
                    ClientPairedQuotaRing(left: claude, right: claudeSeven)
                    ZStack {
                        Circle().stroke(Color.orange.opacity(0.5), lineWidth: 2)
                        Text("2").font(.system(size: 18, weight: .medium, design: .rounded)).foregroundStyle(.orange)
                    }.frame(width: ClientSidebarMetrics.ringSize, height: ClientSidebarMetrics.ringSize)
                    Text("运行主任务").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(.vertical, 20).frame(width: 88).background(Color.black, in: RoundedRectangle(cornerRadius: 22))
                VStack(alignment: .leading, spacing: 14) {
                    Text("额度概览").font(.title3.bold())
                    Divider()
                    ClientQuotaRings(items: [codex, claude, claudeSeven])
                }.padding(20).frame(width: 380).background(Color.black, in: RoundedRectangle(cornerRadius: 24))
            }
        }.padding(24).frame(width: 620, height: 580, alignment: .topLeading)
            .background(Color(white: 0.07)).foregroundStyle(.white)
            .environment(\.colorScheme, .dark).defaultAppStorage(defaults)
        let host = NSHostingView(rootView: candidate)
        host.frame = CGRect(x: 0, y: 0, width: 620, height: 580)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let output = ProcessInfo.processInfo.environment["TOKENBAR_QUOTA_RENDER_OUTPUT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }
    @MainActor func testQuotaSettingsExposeSelectionColorOrderAndLength() throws {
        let suite = "QuotaSettingsRender-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = VStack(alignment: .leading, spacing: 14) {
            Text("侧栏设置 · 候选组件渲染，模拟额度").font(.system(size: 12)).foregroundStyle(.secondary)
            ClientQuotaSettingsView(codex: .empty, quotaItems: ClientQuotaProjection.previewItems(includeClaude: true))
        }.padding(20).frame(width: 390, height: 420, alignment: .topLeading)
            .background(Color(white: 0.04)).foregroundStyle(.white)
            .environment(\.colorScheme, .dark).defaultAppStorage(defaults)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 420)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let output = ProcessInfo.processInfo.environment["TOKENBAR_QUOTA_SETTINGS_RENDER_OUTPUT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }

}
