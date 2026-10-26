import AppKit
import Combine
import Foundation
import SwiftUI

enum SpeedDisplayMode: String, CaseIterable, Sendable {
    case activity, agentSpeed
    var title: String { self == .activity ? "活动估算" : "榜单口径" }
}

enum SpeedColorGrouping: String, CaseIterable, Sendable {
    case model, client
    var title: String { self == .model ? "按模型" : "按客户端" }
}

/// Presentation preferences never change the report payload or the accounting ledger.
@MainActor
final class SpeedDisplayPreferences: ObservableObject {
    static let shared = SpeedDisplayPreferences()
    static let modeKey = "speedDisplay.mode.v1"
    static let groupingKey = "speedDisplay.grouping.v1"
    static let colorsKey = "speedDisplay.customColors.v1"
    @Published private(set) var mode: SpeedDisplayMode
    @Published private(set) var grouping: SpeedColorGrouping
    @Published private(set) var colors: [String: String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = SpeedDisplayMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .activity
        grouping = SpeedColorGrouping(rawValue: defaults.string(forKey: Self.groupingKey) ?? "") ?? .model
        colors = (defaults.dictionary(forKey: Self.colorsKey) as? [String: String] ?? [:]).filter { SpeedColorOverrides.valid($0.value) }
    }
    func setMode(_ value: SpeedDisplayMode) { defaults.set(value.rawValue, forKey: Self.modeKey); mode = value }
    func setGrouping(_ value: SpeedColorGrouping) { defaults.set(value.rawValue, forKey: Self.groupingKey); grouping = value }
    func setColor(_ value: String?, for key: String) {
        var updated = colors
        if let value, SpeedColorOverrides.valid(value) { updated[key] = value.lowercased() }
        else { updated.removeValue(forKey: key) }
        defaults.set(updated, forKey: Self.colorsKey)
        SpeedColorOverrides.shared.replace(updated)
        colors = updated
    }
}

/// Color lookup is also used from background chart projection; avoid defaults I/O per point.
final class SpeedColorOverrides: @unchecked Sendable {
    static let shared = SpeedColorOverrides()
    private let lock = NSLock()
    private var colors: [String: String]
    private var revision = 0
    var version: Int { lock.lock(); defer { lock.unlock() }; return revision }
    private init() { colors = UserDefaults.standard.dictionary(forKey: "speedDisplay.customColors.v1") as? [String: String] ?? [:] }
    static func valid(_ value: String) -> Bool {
        value.count == 7 && value.first == "#" && value.dropFirst().allSatisfy(\.isHexDigit)
    }
    func replace(_ value: [String: String]) { lock.lock(); colors = value; revision &+= 1; lock.unlock() }
    func color(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return colors[key].flatMap { Self.valid($0) ? $0 : nil }
    }
    static func clientTitle(_ key: String) -> String {
        switch key {
        case "client:codex": "Codex"
        case "client:claudeCode": "Claude Code"
        case "client:claudeDesktop": "Claude Desktop"
        case "client:deepseek": "DSH"
        default: String(key.dropFirst("client:".count))
        }
    }
    static func clientColor(_ key: String) -> String {
        switch key {
        case "client:codex": "#72d6a2"
        case "client:claudeCode", "client:claudeDesktop": "#e99663"
        case "client:deepseek": "#568dff"
        default: "#a694e8"
        }
    }
}

struct SpeedDisplayControls: View {
    @ObservedObject private var preferences: SpeedDisplayPreferences
    init(preferences: SpeedDisplayPreferences = .shared) { self.preferences = preferences }
    var body: some View {
        HStack(spacing: 8) {
            Picker("速度算法", selection: Binding(get: { preferences.mode }, set: preferences.setMode)) {
                ForEach(SpeedDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("彩条分组", selection: Binding(get: { preferences.grouping }, set: preferences.setGrouping)) {
                ForEach(SpeedColorGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }.pickerStyle(.menu).font(.system(size: 11)).fixedSize()
    }
}

struct SpeedColorSettings: View {
    @ObservedObject private var preferences: SpeedDisplayPreferences
    var models: [String]
    @State private var expanded: Bool
    init(models: [String], preferences: SpeedDisplayPreferences = .shared, expanded: Bool = false) {
        self.models = models; self.preferences = preferences; _expanded = State(initialValue: expanded)
    }
    private var keys: [String] {
        let clients = ["client:codex", "client:claudeCode", "client:deepseek"]
        let known = ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna", "claude-opus-5", "claude-sonnet-4-5", "deepseek-v4-flash"]
        return clients + Set((known + models).map { ModelUsagePresentation.key(for: $0) }).sorted()
    }
    var body: some View {
        DisclosureGroup("彩条颜色", isExpanded: $expanded) {
            LazyVGrid(columns: [.init(.adaptive(minimum: 205), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(keys, id: \.self) { key in
                    HStack {
                        SpeedColorSwatch(key: key, preferences: preferences)
                        if preferences.colors[key] != nil {
                            Button { preferences.setColor(nil, for: key) } label: { Image(systemName: "arrow.counterclockwise") }
                                .buttonStyle(.plain).help("恢复默认颜色")
                        }
                    }
                }
            }.padding(.top, 8)
        }.font(.system(size: 11)).padding(.vertical, 4)
    }
}

private struct SpeedColorSwatch: View {
    let key: String
    @ObservedObject var preferences: SpeedDisplayPreferences
    @State private var showingPicker = false
    var body: some View {
        Button { showingPicker = true } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 4).fill(ModelUsagePresentation.color(for: key))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.2))).frame(width: 22, height: 18)
                Text(ModelUsagePresentation.label(for: key)).lineLimit(1)
            }
        }.buttonStyle(.plain).accessibilityLabel("修改" + ModelUsagePresentation.label(for: key) + "颜色")
            .popover(isPresented: $showingPicker) {
                ColorPicker("颜色", selection: Binding(get: { ModelUsagePresentation.color(for: key) }, set: { value in
                    guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                    preferences.setColor(String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded())), for: key)
                }), supportsOpacity: false).padding(16)
            }
    }
}
