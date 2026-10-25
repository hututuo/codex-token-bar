import SwiftUI

struct QuotaSidebarModuleSettingsView: View {
    @ObservedObject var controller: QuotaSidebarController
    var quotaSnapshot: AccountQuotaSnapshot = .empty

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("侧栏设置").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("恢复默认顺序") { controller.resetModuleOrder() }
                    .font(.system(size: 11)).disabled(controller.moduleOrder == QuotaSidebarDetail.defaultModuleOrder)
            }
            Text("勾选显示，点箭头调整从上到下的顺序。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(Array(controller.moduleOrder.enumerated()), id: \.element) { index, module in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 12)
                        Toggle(module.moduleTitle, isOn: Binding(
                            get: { controller.isModuleVisible(module) },
                            set: { controller.setModuleVisible(module, visible: $0) }))
                            .toggleStyle(.checkbox).font(.system(size: 12))
                        Spacer(minLength: 0)
                        moveButton(module, by: -1, disabled: index == 0)
                        moveButton(module, by: 1, disabled: index == controller.moduleOrder.count - 1)
                    }.padding(.horizontal, 10).padding(.vertical, 8)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            ClientQuotaSettingsView(codex: quotaSnapshot)
            Button("各客户端用量与额度显示…") { AppSettingsRouteRequest.request(.multiClientUsage) }
            Text("设置入口固定在底部，隐藏的项目会保留顺序。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func moveButton(_ module: QuotaSidebarDetail, by offset: Int, disabled: Bool) -> some View {
        Button { controller.moveModule(module, by: offset) } label: {
            Image(systemName: offset < 0 ? "arrow.up" : "arrow.down")
                .font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(SidebarPulseButtonStyle()).disabled(disabled).opacity(disabled ? 0.3 : 1)
            .help(offset < 0 ? "上移" : "下移")
            .accessibilityLabel("\(offset < 0 ? "上移" : "下移")\(module.moduleTitle)")
    }
}
