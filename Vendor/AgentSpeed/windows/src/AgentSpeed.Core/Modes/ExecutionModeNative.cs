namespace AgentSpeed.Core;

public static class ExecutionModeNative
{
    public static ExecutionModes ClaudeSpeed(string? speed) => ExecutionModes.Of(
        speed is "fast" or "standard" ? ExecutionModeFact.Create(ExecutionModeKind.ServiceTier, speed,
            ExecutionModeEvidence.Served, "anthropic") : null);

    public static ExecutionModes KimiModel(string? model) => ExecutionModes.Of(
        model is "k3.1-pro-highspeed" or "kimi-for-coding-highspeed"
            ? new(ExecutionModeKind.ModelVariant, "highspeed", model, ExecutionModeEvidence.Selected, "kimi", ExecutionModeScope.Request)
            : null);

    public static ExecutionModes Routing(string? model) => ExecutionModes.Of(
        model is "fast-model" or "balanced-model" or "deep-model" or "auto"
            ? new(ExecutionModeKind.Routing, model == "auto" ? model : model[..^6], model, ExecutionModeEvidence.Selected, Scope: ExecutionModeScope.Request)
            : null);

    public static ExecutionModes OpenAiTier(string? tier, ExecutionModeEvidence evidence = ExecutionModeEvidence.Served,
        ExecutionModeScope scope = ExecutionModeScope.Response, string? provider = "openai") =>
        provider is "openai" or "azure"
            ? ExecutionModes.Of(ExecutionModeFact.Create(ExecutionModeKind.ServiceTier, tier, evidence, "openai", scope))
            : ExecutionModes.Empty;

    public static ExecutionModes Workflow(string? workflow) => ExecutionModes.Of(workflow is "fast" or "planning"
        ? ExecutionModeFact.Create(ExecutionModeKind.Workflow, workflow, ExecutionModeEvidence.Selected, scope: ExecutionModeScope.Turn)
        : null);

    public static ExecutionModes OmpTier(string? tier, string? provider, ExecutionModeEvidence evidence, ExecutionModeScope scope)
    {
        provider = provider is "openai-codex" ? "openai" : provider;
        var fact = ExecutionModeFact.Create(ExecutionModeKind.ServiceTier, tier, evidence, provider, scope);
        if (fact is not null && provider == "anthropic" && tier == "priority") fact = fact with { Value = "fast" };
        if (fact is not null && tier == "none") fact = fact with { Value = "standard" };
        return ExecutionModes.Of(fact);
    }

}
