// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum CodexLegacySessionDeletePolicy {
    static let migrationMessage =
        "旧 Codex 侧栏直接删除已停用；请在 Codex Token Bar 的“会话管理”中核对完整影响范围并创建恢复包后删除。"
}

struct CodexSessionEnhancementSettings: Codable, Equatable, Sendable {
    static let storageKey = "CodexTokenBar.sessionEnhancements.v1"

    var sessionDelete: Bool
    var markdownExport: Bool
    var pasteFix: Bool
    var projectMove: Bool
    var threadIDBadge: Bool
    var conversationView: Bool
    var conversationViewMaxWidth: Int
    var threadScrollRestore: Bool

    static let `default` = CodexSessionEnhancementSettings(
        sessionDelete: false,
        markdownExport: true,
        pasteFix: false,
        projectMove: true,
        threadIDBadge: false,
        conversationView: false,
        conversationViewMaxWidth: 900,
        threadScrollRestore: true
    )

    var normalized: CodexSessionEnhancementSettings {
        var value = self
        // 保留字段只为解码旧设置；侧栏 direct-delete 已永久退役，旧值 true
        // 也必须在进入注入脚本和桥接服务前迁移为 false。
        value.sessionDelete = false
        value.conversationViewMaxWidth = min(max(conversationViewMaxWidth, 320), 4_000)
        return value
    }

    var enabledFeatureCount: Int {
        [
            markdownExport,
            pasteFix,
            projectMove,
            threadIDBadge,
            conversationView,
            threadScrollRestore,
        ].filter { $0 }.count
    }

    static func load(defaults: UserDefaults = .standard) -> CodexSessionEnhancementSettings {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return .default
        }
        let migrated = decoded.normalized
        if migrated != decoded {
            migrated.save(defaults: defaults)
        }
        return migrated
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(normalized),
              defaults.data(forKey: Self.storageKey) != data else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
