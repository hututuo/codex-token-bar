import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Selection changes quota only. Local usage is an unpartitioned local ledger.
struct QuotaAccountMenu: View {
    var compact = false
    @State private var registry = QuotaAccountRegistryState()
    @State private var error: String?

    var body: some View {
        Menu {
            Button { perform { try QuotaAccountRegistry.select(nil) } } label: {
                Label("跟随当前登录", systemImage: registry.selectedID == nil ? "checkmark" : "person")
            }
            ForEach(registry.accounts) { account in
                Button { perform { try QuotaAccountRegistry.select(account.id) } } label: {
                    Label("\(account.label) · \(account.id.prefix(6))",
                          systemImage: registry.selectedID == account.id ? "checkmark" : "person")
                }
            }
            Divider()
            Button("添加 / 更新当前登录账号") { perform { try QuotaAccountRegistry.saveCurrent() } }
            Button("导入 Codex / CPA 登录文件…") { importAccount() }
            if let selected = registry.selectedID {
                Button("移除选中的已保存账号", role: .destructive) {
                    perform { try QuotaAccountRegistry.remove(selected) }
                }
            }
            Divider()
            Text("仅切换额度；本地 token 仍为全部本地用量")
            Text("登录过期时，请在原客户端登录后更新账号")
        } label: {
            Label(compact ? "" : "额度账号", systemImage: "person.crop.circle")
                .font(.system(size: compact ? 12 : 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("切换额度账号，不切换 Codex 登录或本地 token 统计")
        .accessibilityLabel("切换额度账号")
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: QuotaAccountRegistry.changed)) { _ in reload() }
        .alert("额度账号", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func reload() {
        do { registry = try QuotaAccountRegistry.state() }
        catch { self.error = "无法读取额度账号设置，请检查本地设置文件。" }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); reload() }
        catch { self.error = (error as? DirectQuotaError)?.localizedDescription ?? "无法更新额度账号，请检查登录文件或系统凭据存储。" }
    }
    private func importAccount() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择 Codex auth.json 或 CPA 导出的 OAuth 登录文件。不会修改原文件。"
        if panel.runModal() == .OK, let url = panel.url {
            perform { try QuotaAccountRegistry.importFile(url) }
        }
    }
}
