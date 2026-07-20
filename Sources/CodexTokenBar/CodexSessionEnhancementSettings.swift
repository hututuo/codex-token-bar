// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

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
        sessionDelete: true,
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
        value.conversationViewMaxWidth = min(max(conversationViewMaxWidth, 320), 4_000)
        return value
    }

    var enabledFeatureCount: Int {
        [
            sessionDelete,
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
        return decoded.normalized
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(normalized),
              defaults.data(forKey: Self.storageKey) != data else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
