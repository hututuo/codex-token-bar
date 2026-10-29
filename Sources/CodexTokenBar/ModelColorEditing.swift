import AppKit
import SwiftUI

/// Model colors are edited from lifetime cost cards, without changing their usage or prices.
struct ModelColorEditModifier: ViewModifier {
    let model: String
    let enabled: Bool
    var grayDefault = false
    @State private var showingEditor = false
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.contentShape(Rectangle())
                .onTapGesture(count: 2) { showingEditor = true }
                .accessibilityElement(children: .combine)
                .accessibilityHint("双击修改该模型颜色")
                .accessibilityAction(named: "修改模型颜色") { showingEditor = true }
                .popover(isPresented: $showingEditor) {
                    ModelColorEditor(model: model, grayDefault: grayDefault) { showingEditor = false }
                }
        } else { content }
    }
}

struct ModelColorEditor: View {
    let model: String
    var grayDefault = false
    var onClose: () -> Void
    @ObservedObject private var preferences = SpeedDisplayPreferences.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ModelUsagePresentation.label(for: model)).font(.headline)
            ColorPicker(model.hasPrefix("client:") ? "客户端颜色" : "模型颜色", selection: Binding(
                get: { grayDefault ? ModelUsagePresentation.dashboardColor(for: model, latest: false) : ModelUsagePresentation.color(for: model) },
                set: { value in
                    guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                    preferences.setColor(String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded())), for: model)
                }), supportsOpacity: false)
            HStack {
                Button("恢复默认") { preferences.setColor(nil, for: model) }
                    .disabled(preferences.colors[model] == nil)
                Spacer()
                Button("完成", action: onClose)
            }
        }.padding(16).frame(width: 240)
    }
}

struct ClientColorSettings: View {
    @ObservedObject private var preferences = SpeedDisplayPreferences.shared
    @State private var showing = false
    var body: some View {
        Button("客户端颜色…") { showing = true }
            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("客户端颜色").font(.headline)
                    ForEach(["client:codex", "client:claudeCode", "client:deepseek"], id: \.self) { key in
                        SpeedColorSwatch(key: key, preferences: preferences)
                    }
                }.padding(16)
            }
    }
}
