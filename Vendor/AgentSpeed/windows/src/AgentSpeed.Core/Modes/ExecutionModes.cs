namespace AgentSpeed.Core;

public enum ExecutionModeKind { ServiceTier, Accelerator, ModelVariant, Routing, Workflow }
public enum ExecutionModeEvidence { Configured, Selected, Recorded, Served }
public enum ExecutionModeScope { Configuration, Session, Turn, Request, Response }

public sealed record ExecutionModeFact(
    ExecutionModeKind Kind, string Value, string RawValue, ExecutionModeEvidence Evidence,
    string? Provider = null, ExecutionModeScope Scope = ExecutionModeScope.Response)
{
    public static ExecutionModeFact? Create(ExecutionModeKind kind, string? raw, ExecutionModeEvidence evidence,
        string? provider = null, ExecutionModeScope scope = ExecutionModeScope.Response)
    {
        if (!ExecutionModes.IsIdentifier(raw, 64) || (provider is not null && !ExecutionModes.IsIdentifier(provider, 32))
            || !Enum.IsDefined(kind) || !Enum.IsDefined(evidence) || !Enum.IsDefined(scope)) return null;
        var value = raw!.ToLowerInvariant();
        if (kind == ExecutionModeKind.ServiceTier && provider == "openai")
            value = value switch { "default" => "standard", "priority" => "fast", _ => value };
        return new(kind, value, raw, evidence, provider, scope);
    }
}

public readonly record struct ExecutionModeAttribution(ExecutionModeKind Kind, string Mode, string Evidence, string? Provider)
{
    public static ExecutionModeAttribution Unknown(ExecutionModeKind kind) => new(kind, "unknown", "unknown", null);
}

public sealed class ExecutionModes : IEquatable<ExecutionModes>
{
    public const int MaxFacts = 20;
    private readonly ExecutionModeFact[] _facts;
    public static ExecutionModes Empty { get; } = new([]);
    public IReadOnlyList<ExecutionModeFact> Facts { get; }
    public bool IsEmpty => _facts.Length == 0;

    public ExecutionModes(IEnumerable<ExecutionModeFact> facts)
    {
        _facts = facts.Where(f => f is not null && IsIdentifier(f.Value, 64) && IsIdentifier(f.RawValue, 64)
                && (f.Provider is null || IsIdentifier(f.Provider, 32)) && Enum.IsDefined(f.Kind) && Enum.IsDefined(f.Evidence) && Enum.IsDefined(f.Scope))
            .Select(f => f with { Value = f.Value.ToLowerInvariant() })
            .GroupBy(f => (f.Kind, f.Evidence, f.Scope, f.Provider)).Select(g => g.Last())
            .OrderByDescending(f => f.Evidence).ThenByDescending(f => f.Scope).ThenBy(f => f.Kind).ThenBy(f => f.Provider, StringComparer.Ordinal)
            .Take(MaxFacts)
            .OrderBy(f => f.Kind).ThenBy(f => f.Evidence).ThenBy(f => f.Scope).ThenBy(f => f.Provider, StringComparer.Ordinal)
            .ToArray();
        Facts = Array.AsReadOnly(_facts);
    }

    public static ExecutionModes Of(ExecutionModeFact? fact) => fact is null ? Empty : new([fact]);
    public ExecutionModes Merge(ExecutionModes? newer) => newer is null || newer.IsEmpty ? this : new(_facts.Concat(newer._facts));
    public ExecutionModes Without(ExecutionModeEvidence evidence) => new(_facts.Where(f => f.Evidence != evidence));

    public ExecutionModeAttribution Attribute(ExecutionModeKind kind)
    {
        var fact = _facts.Where(f => f.Kind == kind && f.Evidence != ExecutionModeEvidence.Configured)
            .OrderByDescending(f => f.Evidence).ThenByDescending(f => f.Scope).FirstOrDefault();
        return fact is null || fact.Value is "unknown" or "none" or "auto" or "inherit" or "inherited"
            ? ExecutionModeAttribution.Unknown(kind)
            : new(kind, fact.Value, Name(fact.Evidence), fact.Provider);
    }

    public static bool IsIdentifier(string? value, int max) => value is { Length: > 0 } && value.Length <= max
        && char.IsAsciiLetterOrDigit(value[0]) && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or ':' or '-');
    public static string Name(ExecutionModeKind value) => value switch
    {
        ExecutionModeKind.ServiceTier => "serviceTier", ExecutionModeKind.ModelVariant => "modelVariant",
        ExecutionModeKind.Accelerator => "accelerator", ExecutionModeKind.Routing => "routing", _ => "workflow",
    };
    public static string Name(ExecutionModeEvidence value) => value.ToString().ToLowerInvariant();
    public static string Name(ExecutionModeScope value) => value.ToString().ToLowerInvariant();
    public bool Equals(ExecutionModes? other) => other is not null && _facts.SequenceEqual(other._facts);
    public override bool Equals(object? obj) => obj is ExecutionModes modes && Equals(modes);
    public override int GetHashCode() { var hash = new HashCode(); foreach (var fact in _facts) hash.Add(fact); return hash.ToHashCode(); }
}
