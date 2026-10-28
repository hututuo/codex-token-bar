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
    static let modeKey = ActivitySpeedDisplayMode.key
    static let groupingKey = "speedDisplay.grouping.v1"
    static let colorsKey = "speedDisplay.customColors.v1"
    @Published private(set) var mode: SpeedDisplayMode
    @Published private(set) var grouping: SpeedColorGrouping
    @Published private(set) var colors: [String: String]
    private let defaults: UserDefaults
    private var modeSubscription: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.modeKey) == nil, let legacy = defaults.string(forKey: "speedDisplay.mode.v1") {
            defaults.set(legacy == "agentSpeed" ? "agentSpeed" : "bar", forKey: Self.modeKey)
        }
        mode = defaults.string(forKey: Self.modeKey) == "agentSpeed" ? .agentSpeed : .activity
        grouping = SpeedColorGrouping(rawValue: defaults.string(forKey: Self.groupingKey) ?? "") ?? .model
        colors = (defaults.dictionary(forKey: Self.colorsKey) as? [String: String] ?? [:]).filter { SpeedColorOverrides.valid($0.value) }
        modeSubscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let next: SpeedDisplayMode = self.defaults.string(forKey: Self.modeKey) == "agentSpeed" ? .agentSpeed : .activity
                if self.mode != next { self.mode = next }
            }
        }
    }
    func setMode(_ value: SpeedDisplayMode) { defaults.set(value == .agentSpeed ? "agentSpeed" : "bar", forKey: Self.modeKey); mode = value }
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
        case "client:claudeCode": "Claude CLI"
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
            Picker("速度算法", selection: Binding(get: { preferences.mode }, set: { mode in
                preferences.setMode(mode)
                MultiClientUsageStore.shared.syncLocalRuntime()
                ActivitySpeedHistoryController.shared.refresh()
            })) {
                ForEach(SpeedDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("彩条分组", selection: Binding(get: { preferences.grouping }, set: { value in preferences.setGrouping(value) })) {
                ForEach(SpeedColorGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }.pickerStyle(.menu).font(.system(size: 11)).fixedSize()
    }
}

struct SpeedColorSwatch: View {
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
                ModelColorEditor(model: key) { showingPicker = false }
            }
    }
}
