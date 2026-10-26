import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class IntegratedClientRenderingTests: XCTestCase {
    @MainActor func testQuotaValuesRemainVisibleWhileMorphOwnsTheStrokes() throws {
        let fixtures = ClientQuotaProjection.previewItems(includeClaude: true)
        let suite = "QuotaValueHandoff-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for paired in [false, true] {
            let registry = MatchedStrokeMorphRegistry(), owner = UUID()
            let left = fixtures[paired ? 1 : 0], right = paired ? fixtures[2] : nil
            let root = ClientPairedQuotaRing(left: left, right: right)
                .frame(width: 74, height: 100, alignment: .top)
                .background(.black).foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
                .environment(\.matchedStrokeMorphRegistry, registry)
                .defaultAppStorage(defaults)
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(x: 0, y: 0, width: 74, height: 100)
            host.layoutSubtreeIfNeeded()
            func whitePixels() throws -> Int {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                var count = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        if color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9 { count += 1 }
                    }
                }
                return count
            }
            let original = try whitePixels()
            XCTAssertGreaterThan(original, 10, "The fixture must contain rendered percentage text")
            XCTAssertEqual(registry.registeredViewCount, 1)
            registry.cover(Set([left.id] + (right.map { [$0.id] } ?? [])), owner: owner)
            XCTAssertEqual(registry.coveredViewCount, 1)
            XCTAssertGreaterThanOrEqual(try whitePixels(), original * 9 / 10,
                "Morph handoff may hide ring strokes, but must keep percentage text visible")
            registry.cover([], owner: owner)
        }
    }

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
            .environment(\.matchedStrokeMorphRegistry, ProcessInfo.processInfo.environment["TOKENBAR_USE_NATIVE_MORPH_HOST"] == "1" ? MatchedStrokeMorphRegistry() : nil)
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
    @MainActor func testQuotaColorSettingsRenderWithoutSeparateOrderingOrLengthControls() throws {
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

    @MainActor func testUnifiedSettingsRenderInsideActualDetailWithActualExpandedRail() throws {
        let suite = "LinkedSidebarNativeRender-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("all", forKey: ClientDisplayScope.key)
        let controller = QuotaSidebarController(settings: defaults)
        let monitor = LiveRateMonitor(preciseTokenCountingEnabled: false, monitoringEnabled: false)
        let store = CodexUsageStore(autoStart: false, continuityDefaults: defaults)
        let quota = AccountQuotaStore(userDefaults: defaults, observesUserDefaults: false)
        let tasks = TaskCompletionMonitor(defaults: defaults)
        let radar = CodexRadarStore(detailRefreshDefaults: defaults)
        let history = QuotaHistoryStore()
        let fixtures = ClientQuotaProjection.previewItems(includeClaude: true)
        controller.select(.settings)
        controller.highlightSidebarItem(.quota("claudeCode"))
        let root = VStack(alignment: .leading, spacing: 14) {
            Text("候选原生组件渲染 · 模拟额度 · 设置时一二级同时对照").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    QuotaSidebarSettingsRailPreview(controller: controller, store: store, quota: quota, tasks: tasks, monitor: monitor, quotaItemsOverride: fixtures)
                        .frame(width: 16, height: 366)
                    QuotaSidebarRail(controller: controller, store: store, quota: quota, tasks: tasks, radar: radar, monitor: monitor, quotaItemsOverride: fixtures)
                        .frame(width: 88, height: 640)
                }
                QuotaSidebarDetailView(controller: controller, store: store, monitor: monitor, quota: quota, tasks: tasks, radar: radar, history: history, quotaItemsOverride: fixtures)
                    .frame(width: 420, height: 620)
            }
        }.padding(20).frame(width: 584, height: 710, alignment: .topLeading)
            .background(Color(white: 0.08)).foregroundStyle(.white)
            .environment(\.colorScheme, .dark).defaultAppStorage(defaults)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 584, height: 710)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertEqual(controller.interaction.detail, .settings)
        XCTAssertEqual(controller.settingsHighlightedItem, .quota("claudeCode"))
        if let output = ProcessInfo.processInfo.environment["TOKENBAR_LINKED_SETTINGS_RENDER_OUTPUT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }

}
