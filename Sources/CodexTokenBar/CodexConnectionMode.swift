import Foundation
import CryptoKit

enum CodexConnectionMode: String, Equatable, Sendable {
    case api, subscription, unknown

    static func read(dataSource: CodexDataSource?) -> Self {
        let home = dataSource?.codexHome ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
        let config = configuration(at: home)
        // A configured API provider wins over a leftover ChatGPT login.
        if classify(config: config, auth: nil) == .api { return .api }
        let auth = (try? CurrentCodexCredentialReader.currentAuthData(home: home))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return classify(config: config, auth: auth)
    }

    static func configurationIdentity(dataSource: CodexDataSource?) -> String {
        let home = dataSource?.codexHome ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
        return SHA256.hash(data: Data((configuration(at: home) ?? "unreadable-config").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func configuration(at home: URL) -> String? {
        let path = home.appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: path.path) else { return "" }
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func classify(config: String?, auth: [String: Any]?) -> Self {
        guard let config, let values = ConnectionConfigScalars.read(config) else { return .unknown }
        func get(_ path: String...) -> String? { values[path.joined(separator: "\0")] }
        let profile = get("profile")
        func selected(_ key: String) -> String? {
            profile.flatMap { get("profiles", $0, key) } ?? get(key)
        }
        let provider = selected("model_provider") ?? "openai"
        if provider != "openai" || selected("forced_login_method") == "api"
            || get("model_providers", provider, "requires_openai_auth") == "false"
            || get("model_providers", provider, "base_url")?.isEmpty == false
            || get("model_providers", provider, "env_key")?.isEmpty == false
            || get("model_providers", provider, "experimental_bearer_token")?.isEmpty == false {
            return .api
        }
        let mode = (auth?["auth_mode"] as? String)?.lowercased()
        if mode == "apikey" || mode == "api_key" { return .api }
        if mode == "chatgpt" || mode == "chatgptauthtokens" { return .subscription }
        if let key = auth?["OPENAI_API_KEY"] as? String, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .api }
        if let tokens = auth?["tokens"] as? [String: Any],
           let access = tokens["access_token"] as? String, !access.isEmpty, !access.hasPrefix("sk-") { return .subscription }
        return .unknown
    }
}

/// Read only scalar configuration facts, respecting comments, quoted/dotted keys,
/// inline tables and multiline text. Unsupported relevant values remain unknown.
private enum ConnectionConfigScalars {
    static func read(_ text: String) -> [String: String]? {
        var result: [String: String] = [:]
        var table: [String] = []
        var multiline: String?
        for source in text.components(separatedBy: .newlines) {
            if let delimiter = multiline {
                if source.contains(delimiter) { multiline = nil }
                continue
            }
            let line = split(source, separator: "#").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { return nil }
                table = path(String(line.dropFirst().dropLast()))
                continue
            }
            let pair = split(line, separator: "=")
            guard pair.count >= 2 else { continue }
            let keys = table + path(pair[0])
            let value = pair.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
            let relevant = ["model_provider", "profile", "forced_login_method", "requires_openai_auth", "base_url", "env_key", "experimental_bearer_token"].contains(keys.last ?? "")
            if value.hasPrefix("\"\"\"") || value.hasPrefix("'''") {
                if relevant { return nil }
                let delimiter = String(value.prefix(3))
                if !value.dropFirst(3).contains(delimiter) { multiline = delimiter }
                continue
            }
            if !store(value, at: keys, in: &result), relevant || ["model_providers", "profiles"].contains(keys.first ?? "") { return nil }
        }
        return multiline == nil ? result : nil
    }

    private static func store(_ raw: String, at keys: [String], in result: inout [String: String]) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("{"), value.hasSuffix("}") {
            for entry in split(String(value.dropFirst().dropLast()), separator: ",") where !entry.trimmingCharacters(in: .whitespaces).isEmpty {
                let pair = split(entry, separator: "=")
                guard pair.count >= 2, store(pair.dropFirst().joined(separator: "="), at: keys + path(pair[0]), in: &result) else { return false }
            }
            return true
        }
        if keys.last == "requires_openai_auth", !["true", "false"].contains(value) { return false }
        if ["model_provider", "profile", "forced_login_method", "base_url", "env_key", "experimental_bearer_token"].contains(keys.last ?? ""),
           !value.hasPrefix("\"") && !value.hasPrefix("'") { return false }
        let scalar: String?
        if value.hasPrefix("\""), let data = value.data(using: .utf8) {
            scalar = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String
        } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            scalar = String(value.dropFirst().dropLast())
        } else { scalar = ["true", "false"].contains(value) ? value : nil }
        guard let scalar else {
            return !["model_provider", "profile", "forced_login_method", "requires_openai_auth", "base_url", "env_key", "experimental_bearer_token"].contains(keys.last ?? "")
        }
        result[keys.joined(separator: "\0")] = scalar
        return true
    }

    private static func path(_ text: String) -> [String] {
        split(text, separator: ".").map {
            let part = $0.trimmingCharacters(in: .whitespaces)
            if part.hasPrefix("\""), let data = part.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String { return value }
            return part.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        }
    }

    private static func split(_ text: String, separator: Character) -> [String] {
        var pieces = [String](), current = "", quote: Character?, escaped = false, depth = 0
        for char in text {
            if let active = quote {
                current.append(char)
                if escaped { escaped = false }
                else if char == "\\" && active == "\"" { escaped = true }
                else if char == active { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char; current.append(char)
            } else if char == separator && depth == 0 {
                pieces.append(current); current = ""
                if separator == "#" { return pieces }
            } else {
                if char == "{" || char == "[" { depth += 1 }
                if char == "}" || char == "]" { depth -= 1 }
                current.append(char)
            }
        }
        return pieces + [current]
    }
}
