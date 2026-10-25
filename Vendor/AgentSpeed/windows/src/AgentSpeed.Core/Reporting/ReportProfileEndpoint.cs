namespace AgentSpeed.Core.Reporting;

public static class ReportProfileEndpoint
{
    public static bool Allows(ReportExtensions extensions, string method, string path)
    {
        if (path == "/v1/profile") return method == "GET" ? extensions.HasProfile : method == "PATCH" && extensions.SharedIdentity;
        if (path == "/v1/profile/avatar") return extensions.ProfileAvatar && method is "GET" or "PUT" or "DELETE";
        if (!extensions.SharedIdentity) return false;
        if (path == "/v1/profile/identity") return method is "POST" or "DELETE";
        if (path is "/v1/profile/pairings" or "/v1/profile/pairings/claim") return method == "POST";
        const string prefix = "/v1/profile/pairings/";
        if (!path.StartsWith(prefix, StringComparison.Ordinal)) return false;
        var rest = path[prefix.Length..];
        if (rest.EndsWith("/approve", StringComparison.Ordinal)) return method == "POST" && ReportCanonical.IsDeviceId(rest[..^8]);
        return method is "GET" or "DELETE" && ReportCanonical.IsDeviceId(rest);
    }
}
