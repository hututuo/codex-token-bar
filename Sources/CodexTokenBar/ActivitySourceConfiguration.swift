import AgentSpeedCore
import Foundation

/// Explicit local source selection. No default-enabled upstream sources or provider clients.
struct ActivitySourceConfiguration: Equatable, Sendable {
    var sources: Set<SourceKind>
    var codexRoot: URL
    var deepseekRoot: URL
    var geminiRoot: URL
    var opencodeRoot: URL
    var useDefaultGeminiRoots = true
    var antigravityRoot: URL? = nil

    static func make(codexEnabled: Bool, codexHome: URL?, preferences: [MultiClientUsagePreference],
                     home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        func local(_ path: String?, fallback: URL) -> URL {
            guard let value = path?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return fallback }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
        }
        var value = Self(sources: codexEnabled ? [.codex] : [],
            codexRoot: codexHome?.appendingPathComponent("sessions", isDirectory: true) ?? LiveMonitor.defaultCodexRoot,
            deepseekRoot: local(environment["DSH_HOME"], fallback: home.appendingPathComponent(".dsh")).appendingPathComponent("sessions"),
            geminiRoot: local(environment["GEMINI_CLI_HOME"], fallback: home).appendingPathComponent(".gemini/tmp"),
            opencodeRoot: local(environment["OPENCODE_DATA_DIR"], fallback:
                local(environment["XDG_DATA_HOME"], fallback: home.appendingPathComponent(".local/share")).appendingPathComponent("opencode")))
        if value.opencodeRoot.lastPathComponent == "opencode.db" { value.opencodeRoot.deleteLastPathComponent() }
        for preference in preferences where preference.enabled {
            guard let source = source(for: preference.client.rawValue), source != .codex else { continue }
            value.sources.insert(source)
            guard !preference.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var root = local(preference.path, fallback: home)
            if source == .opencode && root.lastPathComponent == "opencode.db" { root.deleteLastPathComponent() }
            switch source {
            case .deepseek: value.deepseekRoot = root
            case .gemini: value.geminiRoot = root; value.useDefaultGeminiRoots = false
            case .opencode: value.opencodeRoot = root
            case .antigravity: value.antigravityRoot = root
            default: break
            }
        }
        return value
    }
    static func source(for client: String) -> SourceKind? {
        switch client {
        case "codex": .codex
        case "deepseek": .deepseek
        case "gemini": .gemini
        case "opencode": .opencode
        case "antigravity": .antigravity
        default: nil // Claude remains in the separately constrained local runtime.
        }
    }
    static func client(for source: SourceKind) -> String? {
        switch source {
        case .codex: "codex"
        case .deepseek: "deepseek"
        case .gemini: "gemini"
        case .opencode: "opencode"
        case .antigravity: "antigravity"
        default: nil
        }
    }
    var monitorConfiguration: MonitorConfiguration {
        .init(enabledSources: sources, codexRoot: codexRoot, dshRoot: deepseekRoot,
              opencodeRoot: opencodeRoot, geminiRoot: useDefaultGeminiRoots ? nil : geminiRoot, antigravityRoot: antigravityRoot)
    }
    func identity(for source: SourceKind) -> String? {
        let root: URL
        switch source {
        case .codex: root = codexRoot.deletingLastPathComponent()
        case .deepseek: root = deepseekRoot
        case .gemini: root = geminiRoot
        case .opencode: root = opencodeRoot
        case .antigravity: root = antigravityRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
        default: return nil
        }
        return ActivitySpeedSourceIdentity.root(root)
    }
}
