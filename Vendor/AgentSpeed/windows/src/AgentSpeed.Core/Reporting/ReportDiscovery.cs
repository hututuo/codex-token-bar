using System.Globalization;
using System.Text;
using System.Text.Json;

namespace AgentSpeed.Core.Reporting;

/// <summary>The optional report sections, in the order of REPORTING 6.6.</summary>
public enum ReportSection
{
    Sources,
    Models,
    Cost,
    Traffic,
}

/// <summary><c>apiKey.mode</c> (REPORTING 5.6).</summary>
public enum ReportApiKeyMode
{
    None,
    Optional,
    Required,
}

public static class ReportSections
{
    public static IReadOnlyList<ReportSection> All { get; } = [ReportSection.Sources, ReportSection.Models, ReportSection.Cost, ReportSection.Traffic];

    public static string Name(ReportSection section) => section switch
    {
        ReportSection.Sources => "sources",
        ReportSection.Models => "models",
        ReportSection.Cost => "cost",
        _ => "traffic",
    };

    public static ReportSection? Parse(string? name) => name switch
    {
        "sources" => ReportSection.Sources,
        "models" => ReportSection.Models,
        "cost" => ReportSection.Cost,
        "traffic" => ReportSection.Traffic,
        _ => null,
    };

    public static string Name(ReportApiKeyMode mode) => mode switch
    {
        ReportApiKeyMode.Optional => "optional",
        ReportApiKeyMode.Required => "required",
        _ => "none",
    };

    public static ReportApiKeyMode? ParseMode(string? name) => name switch
    {
        "none" => ReportApiKeyMode.None,
        "optional" => ReportApiKeyMode.Optional,
        "required" => ReportApiKeyMode.Required,
        _ => null,
    };
}

/// <summary>The discovery document's <c>limits</c> (REPORTING 3.2), clamped to the protocol's ranges.</summary>
public sealed record ReportLimits
{
    /// <summary>The client never sends a larger body (REPORTING 3.2, 6.8).</summary>
    public const int ClientMaxBodyBytes = 16_384;

    public ReportLimits(int intervalSeconds = 5, int heartbeatSeconds = 60, int maxAgeSeconds = 30, int maxBodyBytes = 16_384, int maxModels = 16)
    {
        IntervalSeconds = Math.Clamp(intervalSeconds, 5, 300);
        HeartbeatSeconds = Math.Max(Math.Clamp(heartbeatSeconds, 30, 900), IntervalSeconds);
        MaxAgeSeconds = Math.Clamp(maxAgeSeconds, 10, 120);
        MaxBodyBytes = Math.Clamp(maxBodyBytes, 4096, 65_536);
        MaxModels = Math.Clamp(maxModels, 0, 16);
    }

    public static ReportLimits Standard { get; } = new();

    public int IntervalSeconds { get; }

    public int HeartbeatSeconds { get; }

    public int MaxAgeSeconds { get; }

    public int MaxBodyBytes { get; }

    public int MaxModels { get; }

    /// <summary>The largest body the client sends to this service.</summary>
    public int SendLimitBytes => Math.Min(ClientMaxBodyBytes, MaxBodyBytes);
}

/// <summary>Why a fetched discovery document was not accepted; <see cref="Field"/> is for logs only.</summary>
public sealed record ReportDiscoveryProblem(string Kind, string? Field = null)
{
    public static ReportDiscoveryProblem TooLarge { get; } = new("tooLarge");

    public static ReportDiscoveryProblem NotJson { get; } = new("notJSON");

    public static ReportDiscoveryProblem Invalid(string field) => new("invalid", field);

    /// <summary>Not an <c>agent-speed-report</c> document at all (a web page, other JSON), as opposed to one that breaks a rule.</summary>
    public bool IsOtherDocument => Kind is "tooLarge" or "notJSON" || Field == "protocol";

    public override string ToString() => Field is null ? Kind : $"{Kind} {Field}";
}

/// <summary>
/// A validated discovery document (REPORTING 3.2). Text is plain and capped, optional links are kept only when
/// <c>https</c>, numbers are clamped, unknown fields and section names are ignored.
/// </summary>
public sealed class ReportDiscovery
{
    public const int MaxBytes = 65_536;
    public const int SupportedVersion = 1;
    public const string ProtocolName = "agent-speed-report";

    private ReportDiscovery()
    {
    }

    public IReadOnlyList<int> Versions { get; private init; } = [];

    public string Name { get; private init; } = string.Empty;

    /// <summary><c>service.description</c>.</summary>
    public string? Summary { get; private init; }

    public string? Homepage { get; private init; }

    public string Terms { get; private init; } = string.Empty;

    public string Privacy { get; private init; } = string.Empty;

    public string? Leaderboard { get; private init; }

    public string? Contact { get; private init; }

    public int? RetentionDays { get; private init; }

    public ReportServiceUrl Api { get; private init; } = null!;

    public ReportApiKeyMode ApiKeyMode { get; private init; }

    public string? ApiKeyUrl { get; private init; }

    public ReportUsernameRules UsernameRules { get; private init; } = ReportUsernameRules.Standard;

    public ReportLimits Limits { get; private init; } = ReportLimits.Standard;

    public IReadOnlySet<ReportSection> Sections { get; private init; } = new HashSet<ReportSection>();

    public ReportExtensions Extensions { get; private init; } = new();

    /// <summary>False when the service shares no protocol version with this client ("needs a newer Agent Speed").</summary>
    public bool SupportsThisClient => Versions.Contains(SupportedVersion);

    /// <summary>
    /// <paramref name="data"/> is the body fetched from <paramref name="service"/>'s discovery URL; <c>http</c> URLs are accepted
    /// only when that was loopback <c>http</c> (REPORTING 2.2).
    /// </summary>
    public static ReportDiscovery? Parse(ReadOnlySpan<byte> data, ReportServiceUrl service, out ReportDiscoveryProblem? problem)
    {
        problem = null;
        if (data.Length > MaxBytes)
        {
            problem = ReportDiscoveryProblem.TooLarge;
            return null;
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(data.ToArray(), new JsonDocumentOptions { MaxDepth = 64 });
        }
        catch (JsonException)
        {
            problem = ReportDiscoveryProblem.NotJson;
            return null;
        }

        using (document)
        {
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                problem = ReportDiscoveryProblem.NotJson;
                return null;
            }

            try
            {
                return Read(new Fields(document.RootElement, string.Empty), service.IsLoopbackHttp);
            }
            catch (DiscoveryInvalid invalid)
            {
                problem = ReportDiscoveryProblem.Invalid(invalid.Field);
                return null;
            }
        }
    }

    /// <summary>
    /// What the preview assumes before a service's document is known (DESIGN 11, Preview window): the API at the service
    /// URL, every section and the protocol's defaults. Never stored or confirmed.
    /// </summary>
    public static ReportDiscovery? Assumed(ReportServiceUrl service, string name)
    {
        var link = $"https://{service.Host}/";
        var json = ReportJson.Object(
            ("protocol", ReportJson.Of(ProtocolName)),
            ("versions", ReportJson.Array([ReportJson.Of(SupportedVersion)])),
            ("service", ReportJson.Object(("name", ReportJson.Of(name)), ("terms", ReportJson.Of(link)), ("privacy", ReportJson.Of(link)))),
            ("api", ReportJson.Of(service.Text)));
        return Parse(json.ToCompactBytes(), service, out _);
    }

    /// <summary>The document as the client understood it, for storage; it parses back to the same values.</summary>
    public ReportJson ToJson()
    {
        var service = new List<(string, ReportJson)> { ("name", ReportJson.Of(Name)) };
        if (Summary is not null)
        {
            service.Add(("description", ReportJson.Of(Summary)));
        }

        if (Homepage is not null)
        {
            service.Add(("homepage", ReportJson.Of(Homepage)));
        }

        service.Add(("terms", ReportJson.Of(Terms)));
        service.Add(("privacy", ReportJson.Of(Privacy)));
        if (Leaderboard is not null)
        {
            service.Add(("leaderboard", ReportJson.Of(Leaderboard)));
        }

        if (Contact is not null)
        {
            service.Add(("contact", ReportJson.Of(Contact)));
        }

        if (RetentionDays is { } days)
        {
            service.Add(("retentionDays", ReportJson.Of(days)));
        }

        var apiKey = new List<(string, ReportJson)> { ("mode", ReportJson.Of(ReportSections.Name(ApiKeyMode))) };
        if (ApiKeyUrl is not null)
        {
            apiKey.Add(("url", ReportJson.Of(ApiKeyUrl)));
        }

        return ReportJson.Object(
            ("protocol", ReportJson.Of(ProtocolName)),
            ("versions", ReportJson.Array(Versions.Select(v => ReportJson.Of(v)))),
            ("service", ReportJson.Object(service)),
            ("api", ReportJson.Of(Api.Text)),
            ("apiKey", ReportJson.Object(apiKey)),
            ("username", ReportJson.Object(
                ("minLength", ReportJson.Of(UsernameRules.MinLength)),
                ("maxLength", ReportJson.Of(UsernameRules.MaxLength)),
                ("charset", ReportJson.Of(UsernameRules.Charset == ReportUsernameCharset.Ascii ? "ascii" : "unicode")),
                ("spaces", ReportJson.Of(UsernameRules.Spaces)))),
            ("limits", ReportJson.Object(
                ("intervalSeconds", ReportJson.Of(Limits.IntervalSeconds)),
                ("heartbeatSeconds", ReportJson.Of(Limits.HeartbeatSeconds)),
                ("maxAgeSeconds", ReportJson.Of(Limits.MaxAgeSeconds)),
                ("maxBodyBytes", ReportJson.Of(Limits.MaxBodyBytes)),
                ("maxModels", ReportJson.Of(Limits.MaxModels)))),
            ("sections", ReportJson.Array(ReportSections.All.Where(Sections.Contains).Select(s => ReportJson.Of(ReportSections.Name(s))))),
            ("extensions", Extensions.Json));
    }

    private static ReportDiscovery Read(Fields root, bool loopback)
    {
        if (root.String("protocol") != ProtocolName)
        {
            throw new DiscoveryInvalid("protocol");
        }

        var versionItems = root.Required(root.Array("versions"), "versions");
        if (versionItems.Count == 0)
        {
            throw new DiscoveryInvalid("versions");
        }

        var versions = versionItems.Select(item => Fields.IntegerOf(item) is { } value
            ? (int)Math.Clamp(value, int.MinValue, int.MaxValue)
            : throw new DiscoveryInvalid("versions")).ToArray();

        var service = root.Required(root.Object("service"), "service");
        var name = ReportPlainText.Clean(service.Required(service.String("name"), "name"), 40);
        if (name.Length == 0)
        {
            throw new DiscoveryInvalid("service.name");
        }

        var summary = service.String("description") is { } description ? NonEmpty(ReportPlainText.Clean(description, 200)) : null;
        var contact = service.String("contact") is { } contactText ? NonEmpty(ReportPlainText.Clean(contactText, 254)) : null;
        var terms = service.Required(service.Link("terms"), "terms");
        var privacy = service.Required(service.Link("privacy"), "privacy");
        var homepage = service.String("homepage") is { } homepageText ? ReportUrls.HttpsLink(homepageText) : null;
        var leaderboard = service.String("leaderboard") is { } leaderboardText ? ReportUrls.HttpsLink(leaderboardText) : null;
        var retention = service.Integer("retentionDays", 0, 3650);

        var apiText = root.Required(root.String("api"), "api");
        var api = ReportServiceUrl.ParseApi(apiText, loopback) ?? throw new DiscoveryInvalid("api");

        var apiKey = root.Object("apiKey");
        var mode = ReportApiKeyMode.None;
        if (apiKey?.String("mode") is { } modeText)
        {
            mode = ReportSections.ParseMode(modeText) ?? throw new DiscoveryInvalid("apiKey.mode");
        }

        var apiKeyUrl = apiKey?.String("url") is { } keyUrl ? ReportUrls.HttpsLink(keyUrl) : null;

        var username = root.Object("username");
        var charset = ReportUsernameCharset.Unicode;
        if (username?.String("charset") is { } charsetText)
        {
            charset = charsetText switch
            {
                "unicode" => ReportUsernameCharset.Unicode,
                "ascii" => ReportUsernameCharset.Ascii,
                _ => throw new DiscoveryInvalid("username.charset"),
            };
        }

        var rules = new ReportUsernameRules(
            username?.Integer("minLength", 1, 12) ?? 2,
            username?.Integer("maxLength", 12, 32) ?? 32,
            charset,
            username?.Bool("spaces") ?? true);
        var limitFields = root.Object("limits");
        var limits = new ReportLimits(
            limitFields?.Integer("intervalSeconds", 5, 300) ?? 5,
            limitFields?.Integer("heartbeatSeconds", 30, 900) ?? 60,
            limitFields?.Integer("maxAgeSeconds", 10, 120) ?? 30,
            limitFields?.Integer("maxBodyBytes", 4096, 65_536) ?? 16_384,
            limitFields?.Integer("maxModels", 0, 16) ?? 16);
        HashSet<ReportSection> sections;
        if (root.Array("sections") is { } names)
        {
            sections = [];
            foreach (var item in names)
            {
                if (item.ValueKind != JsonValueKind.String)
                {
                    throw new DiscoveryInvalid("sections");
                }

                if (ReportSections.Parse(Fields.StringOf(item, "sections")) is { } section)
                {
                    sections.Add(section);
                }
            }
        }
        else
        {
            sections = [.. ReportSections.All];
        }

        return new ReportDiscovery
        {
            Versions = versions,
            Name = name,
            Summary = summary,
            Homepage = homepage,
            Terms = terms,
            Privacy = privacy,
            Leaderboard = leaderboard,
            Contact = contact,
            RetentionDays = retention,
            Api = api,
            ApiKeyMode = mode,
            ApiKeyUrl = apiKeyUrl,
            UsernameRules = rules,
            Limits = limits,
            Sections = sections,
            Extensions = new(root.Extension("modelHarnessRequests"), root.Extension("executionModes"), root.Extension("profileAvatar"), root.Extension("sharedIdentity")),
        };
    }

    private static string? NonEmpty(string? text) => string.IsNullOrEmpty(text) ? null : text;

    private sealed class DiscoveryInvalid(string field) : Exception(field)
    {
        public string Field { get; } = field;
    }

    /// <summary>One object of the document. A present field of the wrong type is an error, a fraction where an integer is expected included.</summary>
    private sealed class Fields(JsonElement element, string path)
    {
        public bool Extension(string name) => element.TryGetProperty("extensions", out var extensions)
            && extensions.ValueKind == JsonValueKind.Object && extensions.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var version) && version == 1;

        private string Field(string key) => path.Length == 0 ? key : $"{path}.{key}";

        public T Required<T>(T? value, string key)
            where T : class => value ?? throw new DiscoveryInvalid(Field(key));

        private JsonElement? Member(string key) => element.TryGetProperty(key, out var value) ? value : null;

        public Fields? Object(string key) => Member(key) switch
        {
            null => null,
            { ValueKind: JsonValueKind.Object } value => new Fields(value, Field(key)),
            _ => throw new DiscoveryInvalid(Field(key)),
        };

        public List<JsonElement>? Array(string key) => Member(key) switch
        {
            null => null,
            { ValueKind: JsonValueKind.Array } value => [.. value.EnumerateArray()],
            _ => throw new DiscoveryInvalid(Field(key)),
        };

        public string? String(string key) => Member(key) switch
        {
            null => null,
            { ValueKind: JsonValueKind.String } value => StringOf(value, Field(key)),
            _ => throw new DiscoveryInvalid(Field(key)),
        };

        public bool? Bool(string key) => Member(key) switch
        {
            null => null,
            { ValueKind: JsonValueKind.True } => true,
            { ValueKind: JsonValueKind.False } => false,
            _ => throw new DiscoveryInvalid(Field(key)),
        };

        /// <summary>An integer, clamped to its range; a fraction or an exponent is the wrong type (REPORTING 3.2).</summary>
        public int? Integer(string key, int low, int high)
        {
            if (Member(key) is not { } value)
            {
                return null;
            }

            return IntegerOf(value) is { } number ? (int)Math.Clamp(number, low, high) : throw new DiscoveryInvalid(Field(key));
        }

        /// <summary>A required link: always <c>https</c>, also from a loopback test server (REPORTING 2.2).</summary>
        public string? Link(string key) =>
            String(key) is { } text ? ReportUrls.HttpsLink(text) ?? throw new DiscoveryInvalid(Field(key)) : null;

        /// <summary>The integer of a JSON number written without fraction or exponent, saturated at the <c>long</c> limits.</summary>
        public static long? IntegerOf(JsonElement value)
        {
            if (value.ValueKind != JsonValueKind.Number)
            {
                return null;
            }

            var raw = value.GetRawText();
            var digits = raw.StartsWith('-') ? raw[1..] : raw;
            if (digits.Length == 0 || !digits.All(char.IsAsciiDigit))
            {
                return null;
            }

            return long.TryParse(raw, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var parsed)
                ? parsed
                : raw.StartsWith('-') ? long.MinValue : long.MaxValue;
        }

        public static string StringOf(JsonElement value, string field)
        {
            try
            {
                return value.GetString() ?? string.Empty;
            }
            catch (InvalidOperationException)
            {
                throw new DiscoveryInvalid(field);
            }
        }
    }
}

/// <summary>What the user confirmed in the consent sheet (REPORTING 3.3), stored with the identity.</summary>
public sealed record ReportConsentPin(string Name, string Terms, string Privacy, string Api, IReadOnlyList<string> Sections,
    int? RetentionDays, ReportApiKeyMode ApiKeyMode)
{
    public static ReportConsentPin Of(ReportDiscovery discovery) => new(
        discovery.Name, discovery.Terms, discovery.Privacy, discovery.Api.Text,
        discovery.Sections.Select(ReportSections.Name).Order(StringComparer.Ordinal).ToArray(),
        discovery.RetentionDays, discovery.ApiKeyMode);

    /// <summary>
    /// REPORTING 3.3: true when <paramref name="current"/> changes name, terms, privacy or api (after normalization, path
    /// included), adds a section, raises or removes retentionDays, or switches apiKey.mode to required without a key.
    /// </summary>
    public bool NeedsReview(ReportDiscovery current, bool hasApiKey)
    {
        var now = Of(current);
        if (!string.Equals(now.Name, Name, StringComparison.Ordinal) || now.Terms != Terms || now.Privacy != Privacy || now.Api != Api)
        {
            return true;
        }

        if (!now.Sections.All(Sections.Contains))
        {
            return true;
        }

        if (RetentionDays is { } confirmed && (now.RetentionDays ?? int.MaxValue) > confirmed)
        {
            return true;
        }

        return now.ApiKeyMode == ReportApiKeyMode.Required && ApiKeyMode != ReportApiKeyMode.Required && !hasApiKey;
    }

    public bool Equals(ReportConsentPin? other) =>
        other is not null && Name == other.Name && Terms == other.Terms && Privacy == other.Privacy && Api == other.Api
        && Sections.SequenceEqual(other.Sections) && RetentionDays == other.RetentionDays && ApiKeyMode == other.ApiKeyMode;

    public override int GetHashCode() => HashCode.Combine(Name, Api);
}

/// <summary>
/// Plain text from a service (REPORTING 2.3): white space runs become one space, control and format characters
/// (bidirectional controls, U+200B …) are removed, the ends are trimmed and the length is capped in code points.
/// </summary>
public static class ReportPlainText
{
    public static string Clean(string text, int limit)
    {
        var output = new List<Rune>(Math.Min(text.Length, limit + 1));
        var pendingSpace = false;
        foreach (var rune in text.EnumerateRunes())
        {
            if (ReportUsername.IsSpace(rune))
            {
                pendingSpace = output.Count > 0;
                continue;
            }

            if (Rune.GetUnicodeCategory(rune) is UnicodeCategory.Control or UnicodeCategory.Format or UnicodeCategory.Surrogate
                || rune == Rune.ReplacementChar)
            {
                continue;
            }

            if (pendingSpace)
            {
                output.Add(new Rune(' '));
                pendingSpace = false;
            }

            output.Add(rune);
            if (output.Count > limit)
            {
                break;
            }
        }

        if (output.Count > limit)
        {
            output.RemoveRange(limit, output.Count - limit);
        }

        while (output.Count > 0 && output[^1].Value == ' ')
        {
            output.RemoveAt(output.Count - 1);
        }

        var builder = new StringBuilder(output.Count);
        foreach (var rune in output)
        {
            builder.Append(rune.ToString());
        }

        return builder.ToString();
    }
}
