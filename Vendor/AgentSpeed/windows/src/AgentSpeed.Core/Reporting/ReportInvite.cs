namespace AgentSpeed.Core.Reporting;

/// <summary>The stored answer of the dashboard invitation (<c>report.invite</c>); absent until the user answers.</summary>
public enum ReportInviteAnswer
{
    Accepted,
    Declined,
}

/// <summary>Why a document cannot be confirmed by the invitation alone (REPORTING 3.3).</summary>
public abstract record ReportInviteGap
{
    private ReportInviteGap()
    {
    }

    /// <summary>The API lives on a host the invitation did not name.</summary>
    public sealed record ApiHost : ReportInviteGap;

    /// <summary>The service requires an API key.</summary>
    public sealed record ApiKey : ReportInviteGap;

    /// <summary>The username breaks the service's rules.</summary>
    public sealed record Username(ReportUsernameProblem Problem) : ReportInviteGap;
}

/// <summary>
/// The dashboard invitation (DESIGN 11, Dashboard invitation) and one-click consent (REPORTING 3.3): when the card is
/// shown, and whether a fetched document may be confirmed without the consent sheet.
/// </summary>
public static class ReportInvite
{
    /// <summary>The card is offered while unanswered, off, online, on the preset and with nothing registered anywhere.</summary>
    public static bool IsOffered(ReportInviteAnswer? answer, bool reportingEnabled, bool networkEnabled, bool presetSelected,
        bool hasRegisteredIdentity) =>
        answer is null && !reportingEnabled && networkEnabled && presetSelected && !hasRegisteredIdentity;

    /// <summary>
    /// Null when the invitation covered <paramref name="document"/>: its API is on the service URL's host or a subdomain of it
    /// (or under the domain the built-in preset covers, with the service URL inside it too), it needs no API key and
    /// <paramref name="username"/> fits its rules.
    /// </summary>
    public static ReportInviteGap? Gap(ReportDiscovery document, ReportServiceUrl service, string username, string? presetDomain = null)
    {
        var host = document.Api.Host;
        var covered = Covers(host, service.Host)
            || (presetDomain is not null && Covers(host, presetDomain) && Covers(service.Host, presetDomain));
        if (!covered)
        {
            return new ReportInviteGap.ApiHost();
        }

        if (document.ApiKeyMode == ReportApiKeyMode.Required)
        {
            return new ReportInviteGap.ApiKey();
        }

        return ReportUsername.Validate(username, document.UsernameRules) is { } problem ? new ReportInviteGap.Username(problem) : null;
    }

    /// <summary>The same host, or a subdomain of it (<c>api.example.com</c> under <c>example.com</c>); hosts are lower-case ASCII.</summary>
    public static bool Covers(string apiHost, string serviceHost)
    {
        var api = apiHost.ToLowerInvariant();
        var service = serviceHost.ToLowerInvariant();
        return api == service || (service.Length > 0 && api.EndsWith("." + service, StringComparison.Ordinal) && !IsIpLiteral(service));
    }

    private static bool IsIpLiteral(string host) => host.StartsWith('[') || host.All(c => char.IsAsciiDigit(c) || c == '.');
}
