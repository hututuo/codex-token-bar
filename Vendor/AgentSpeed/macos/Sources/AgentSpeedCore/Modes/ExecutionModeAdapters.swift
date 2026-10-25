import Foundation

enum ExecutionModeAdapters {
    static func normalize(adapter: String, raw: String?, provider: String?, evidence: ExecutionModeEvidence,
                          scope: ExecutionModeScope) -> ExecutionModeFact? {
        guard provider.map({ ExecutionModeFact.isIdentifier($0, limit: 32) }) ?? true else { return nil }
        switch adapter {
        case "serviceTier":
            guard provider.map({ ["openai", "openai-codex", "azure"].contains($0) }) ?? true else { return nil }
            return fact(kind: .serviceTier, raw: raw, evidence: evidence, provider: provider, scope: scope).facts.first
        case "claudeSpeed":
            return fact(kind: .serviceTier, raw: raw, evidence: evidence, provider: provider, scope: scope).facts.first
        case "kimiModel":
            return kimi(raw).facts.first
        case "routing":
            let value = ["fast-model": "fast", "balanced-model": "balanced", "deep-model": "deep", "auto": "auto"][raw ?? ""]
            guard let value else { return nil }
            return fact(kind: .routing, raw: raw, evidence: evidence, provider: provider, scope: scope).facts.first?.withCanonicalValue(value)
        case "workflow":
            guard ["fast", "planning"].contains(raw ?? "") else { return nil }
            return fact(kind: .workflow, raw: raw, evidence: evidence, provider: provider, scope: scope).facts.first
        default: return nil
        }
    }

    static func claude(_ speed: String?) -> ExecutionModes {
        fact(kind: .serviceTier, raw: speed, evidence: .served, provider: "anthropic", scope: .response)
    }

    static func openAI(_ tier: String?, evidence: ExecutionModeEvidence, scope: ExecutionModeScope) -> ExecutionModes {
        fact(kind: .serviceTier, raw: tier, evidence: evidence, provider: "openai", scope: scope)
    }

    static func kimi(_ model: String?) -> ExecutionModes {
        guard ["k3.1-pro-highspeed", "kimi-for-coding-highspeed"].contains(model ?? "") else { return .empty }
        return canonical(kind: .modelVariant, raw: model, value: "highspeed", provider: "kimi")
    }

    static func routing(_ model: String?) -> ExecutionModes {
        guard let fact = normalize(adapter: "routing", raw: model, provider: nil, evidence: .selected, scope: .request) else { return .empty }
        return ExecutionModes([fact])
    }

    private static func canonical(kind: ExecutionModeKind, raw: String?, value: String, provider: String) -> ExecutionModes {
        guard let first = fact(kind: kind, raw: raw, evidence: .selected, provider: provider, scope: .request).facts.first else { return .empty }
        return ExecutionModes([first.withCanonicalValue(value)])
    }

    static func ompProvider(_ provider: String?) -> String? {
        guard let provider else { return nil }
        if provider == "anthropic" { return "anthropic" }
        if ["openai", "openai-codex", "azure", "azure-openai-responses"].contains(provider) { return "openai" }
        if ["google", "google-gemini-cli", "google-antigravity", "google-vertex"].contains(provider) { return "google" }
        return nil
    }

    static func omp(_ tier: String?, provider: String?, evidence: ExecutionModeEvidence, scope: ExecutionModeScope) -> ExecutionModes {
        guard let provider else { return .empty }
        let family: String
        if provider == "anthropic" { family = "anthropic" }
        else if ["openai", "openai-codex", "azure", "azure-openai-responses"].contains(provider) { family = "openai" }
        else if ["google", "google-gemini-cli", "google-antigravity", "google-vertex"].contains(provider) { family = "google" }
        else { return .empty }
        var result = fact(kind: .serviceTier, raw: tier, evidence: evidence, provider: family, scope: scope)
        if family == "anthropic", tier == "priority", let first = result.facts.first {
            result = ExecutionModes([first.withCanonicalValue("fast")])
        }
        return result
    }

    static func fact(kind: ExecutionModeKind, raw: String?, evidence: ExecutionModeEvidence,
                     provider: String?, scope: ExecutionModeScope) -> ExecutionModes {
        guard let raw, let fact = ExecutionModeFact(kind: kind, rawValue: raw, evidence: evidence,
                                                  provider: provider, scope: scope) else { return .empty }
        return ExecutionModes([fact])
    }
}
