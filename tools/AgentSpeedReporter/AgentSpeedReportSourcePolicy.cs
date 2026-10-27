using AgentSpeed.Core;
using AgentSpeed.Core.Reporting;

namespace CodexTokenBar.AgentSpeedReporter;

/// <summary>The reporter's source policy; the local dashboard continues to collect every source.</summary>
internal static class AgentSpeedReportSourcePolicy
{
    private static readonly HashSet<SourceKind> DeniedSources = [SourceKind.ClaudeCode, SourceKind.ClaudeDesktop];

    public static IReadOnlySet<SourceKind> ReportableSources { get; } =
        Enum.GetValues<SourceKind>().Where(source => !DeniedSources.Contains(source)).ToHashSet();

    public static IReadOnlySet<string> RequiredDeniedSourceIds { get; } =
        DeniedSources.Select(ReportBody.SourceId).ToHashSet(StringComparer.Ordinal);

    public static bool IsReportable(SourceKind source) => ReportableSources.Contains(source);

    public static bool IsReportableId(string sourceId) => Enum.GetValues<SourceKind>()
        .Any(source => IsReportable(source) && string.Equals(ReportBody.SourceId(source), sourceId, StringComparison.Ordinal));

    public static bool HasRequiredDenyList(IEnumerable<string> sourceIds)
    {
        var supplied = sourceIds.ToHashSet(StringComparer.Ordinal);
        return supplied.Count == RequiredDeniedSourceIds.Count && supplied.SetEquals(RequiredDeniedSourceIds);
    }
}
