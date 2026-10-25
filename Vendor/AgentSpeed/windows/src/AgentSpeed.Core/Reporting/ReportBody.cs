using AgentSpeed.Core.Traffic;

namespace AgentSpeed.Core.Reporting;

/// <summary><c>client</c> of every body (REPORTING 6.3).</summary>
public sealed record ReportClientInfo
{
    public ReportClientInfo(string version, string platform, int osMajor)
    {
        Version = IsVersion(version) ? version : "0.0.0";
        Platform = platform;
        OsMajor = Math.Clamp(osMajor, 10, 99);
    }

    public string Version { get; }

    public string Platform { get; }

    public int OsMajor { get; }

    /// <summary>This computer: the app version and Windows 10 or 11 (11 for build 22000 and later).</summary>
    public static ReportClientInfo Windows(string version) =>
        new(version, "Windows", Environment.OSVersion.Version.Build >= 22000 ? 11 : 10);

    /// <summary><c>AgentSpeed/&lt;version&gt; (Windows)</c> (REPORTING 2.3).</summary>
    public string UserAgent => $"AgentSpeed/{Version} ({Platform})";

    public ReportJson Json => ReportJson.Object(
        ("app", ReportJson.Of("CodexTokenBar")), ("version", ReportJson.Of(Version)), ("platform", ReportJson.Of(Platform)),
        ("osMajor", ReportJson.Of(OsMajor)));

    /// <summary><c>MAJOR.MINOR.PATCH[-PRERELEASE]</c>, at most 32 characters.</summary>
    public static bool IsVersion(string text)
    {
        if (text.Length > 32)
        {
            return false;
        }

        var dash = text.IndexOf('-', StringComparison.Ordinal);
        var core = dash < 0 ? text : text[..dash];
        var numbers = core.Split('.');
        if (numbers.Length != 3 || numbers.Any(n => n.Length == 0 || !n.All(char.IsAsciiDigit)))
        {
            return false;
        }

        if (dash < 0)
        {
            return true;
        }

        var pre = text[(dash + 1)..];
        return pre.Length > 0 && pre.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-');
    }
}

/// <summary>Who and when a report is (REPORTING 6.3).</summary>
/// <param name="SentAtMs">Unix ms of the build on the corrected clock (METRICS 11.6).</param>
public sealed record ReportEnvelope(
    ReportClientInfo Client,
    string DeviceId,
    string Username,
    string RunId,
    int Seq,
    long SentAtMs,
    long WindowMs,
    ReportActivity Activity,
    int TitleLevel);

/// <summary>What a report may contain and how large it may be (REPORTING 3.2, 6.1, 6.8).</summary>
/// <param name="Sections">The optional sections both the service lists and the user's switches allow.</param>
public sealed record ReportOptions(
    IReadOnlySet<ReportSection> Sections,
    int MaxModels = 16,
    int BodyLimit = 16_384,
    SpeedMetric Metric = SpeedMetric.Output,
    double Redline = 2000,
    int PriceVersion = 1)
{
    public ReportExtensions Extensions { get; init; } = new();
}

/// <summary>The report body of REPORTING 6 from a window, the tick's values and the options (METRICS 11.2, 11.7).</summary>
public static class ReportBody
{
    public const double MaxTokS = 1e9;
    public const int MaxCount = 100_000;
    public const long MaxWindowMs = 900_000;

    private static readonly SourceKind[] SourceOrder = Enum.GetValues<SourceKind>();

    /// <summary>The body as sent: within the body limit, dropping <c>models</c> and then <c>sources</c> when it would not fit.</summary>
    public static byte[] Data(ReportEnvelope envelope, ReportWindowContent content, ReportSample sample, ReportOptions options) =>
        Fitted(envelope, content, sample, options).Data;

    /// <summary>The document and its bytes after the size rule (REPORTING 6.8).</summary>
    public static (ReportJson Json, byte[] Data) Fitted(ReportEnvelope envelope, ReportWindowContent content, ReportSample sample, ReportOptions options)
    {
        var document = Json(envelope, content, sample, options);
        var data = document.ToCompactBytes();
        if (data.Length > options.BodyLimit && (options.Extensions.ExecutionModes || options.Extensions.ModelHarnessRequests))
        {
            options = options with { Extensions = options.Extensions with { ExecutionModes = false, ModelHarnessRequests = false } };
            document = Json(envelope, content, sample, options);
            data = document.ToCompactBytes();
        }
        foreach (var section in new[] { ReportSection.Models, ReportSection.Sources })
        {
            if (data.Length <= options.BodyLimit)
            {
                break;
            }

            options = options with { Sections = options.Sections.Where(s => s != section).ToHashSet() };
            document = Json(envelope, content, sample, options);
            data = document.ToCompactBytes();
        }

        return (document, data);
    }

    public static ReportJson Json(ReportEnvelope envelope, ReportWindowContent content, ReportSample sample, ReportOptions options)
    {
        var total = content.Usage.Total;
        var agents = default(ReportAgentCounts);
        foreach (var counts in sample.Facts.Agents.Values)
        {
            agents += counts;
        }

        var value = sample.Value(options.Metric);
        var members = new List<(string, ReportJson)>
        {
            ("schema", ReportJson.Of(1)),
            ("client", envelope.Client.Json),
            ("deviceId", ReportJson.Of(envelope.DeviceId)),
            ("username", ReportJson.Of(envelope.Username)),
            ("run", ReportJson.Object(("id", ReportJson.Of(envelope.RunId)), ("seq", ReportJson.Of(envelope.Seq)))),
            ("sentAt", ReportJson.Of(ReportInstant.Format(envelope.SentAtMs))),
            ("windowMs", ReportJson.Of(Math.Clamp(envelope.WindowMs, 0, MaxWindowMs))),
            ("activity", ReportJson.Of(ActivityName(envelope.Activity))),
            ("live", ReportJson.Object(
                ("outputTokS", TokS(sample.Live.Output)), ("totalTokS", TokS(sample.Live.Total)),
                ("estimatedShare", Share(sample.EstimatedShare)), ("agents", Counts(agents)))),
            ("peak", ReportJson.Object(("outputTokS", TokS(content.Peak.Output)), ("totalTokS", TokS(content.Peak.Total)))),
            ("delta", Delta(total)),
            ("title", ReportJson.Object(
                ("level", ReportJson.Of(Math.Clamp(envelope.TitleLevel, 0, ReportTitleTracker.MaxLevel))),
                ("metric", ReportJson.Of(options.Metric == SpeedMetric.Total ? "total" : "output")),
                ("redline", ReportJson.Decimal(options.Redline, 1)),
                ("heat", Share(ReportTitleTracker.Heat(value, options.Redline))))),
        };
        var sections = options.Sections;
        if (sections.Contains(ReportSection.Cost))
        {
            members.Add(("cost", ReportJson.Object(
                ("liveMicroUsdPerSecond", PerSecond(sample.LiveCost.MicroUsdPerSecond)),
                ("peakMicroUsdPerSecond", PerSecond(Math.Max(content.PeakCost, sample.LiveCost.MicroUsdPerSecond))),
                ("knownShare", Share(sample.LiveCost.KnownShare(sample.Live.Output))),
                ("deltaMicroUsd", ReportJson.Of(total.CostMicroUsd)),
                ("unpricedRequests", ReportJson.Of(total.UnpricedRequests)),
                ("priceVersion", ReportJson.Of(Math.Max(1, options.PriceVersion))))));
        }

        if (sections.Contains(ReportSection.Traffic))
        {
            var bytes = TrafficBytes.Zero;
            foreach (var b in content.AgentBytes.Values)
            {
                bytes += b;
            }

            members.Add(("traffic", Traffic(sample.Traffic, content.PeakRate, bytes)));
        }

        if (sections.Contains(ReportSection.Sources))
        {
            members.Add(("sources", ReportJson.Array(SourceEntries(content, sample, sections))));
        }

        if (sections.Contains(ReportSection.Models) && options.MaxModels > 0)
        {
            members.Add(("models", ReportJson.Array(ModelEntries(content, sample, options.MaxModels, sections.Contains(ReportSection.Cost), options.Extensions))));
        }

        return ReportJson.Object(members);
    }

    public static string ActivityName(ReportActivity activity) => activity switch
    {
        ReportActivity.Active => "active",
        ReportActivity.Idle => "idle",
        _ => "leaving",
    };

    public static string SourceId(SourceKind kind) => kind switch
    {
        SourceKind.Codex => "codex",
        SourceKind.ClaudeCode => "claudeCode",
        SourceKind.ClaudeDesktop => "claudeDesktop",
        SourceKind.DeepSeek => "deepseek",
        SourceKind.OpenCode => "opencode",
        SourceKind.Gemini => "gemini",
        SourceKind.Omp => "omp",
        SourceKind.Antigravity => "antigravity",
        SourceKind.WorkBuddy => "workbuddy",
        SourceKind.WorkBuddyAi => "workbuddyAi",
        SourceKind.ZCode => "zcode",
        SourceKind.Kimi => "kimi",
        SourceKind.GrokBuild => "grokBuild",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    private static ReportJson Traffic(ReportTrafficSample traffic, TrafficRate? peak, TrafficBytes bytes)
    {
        if (traffic.Status != ReportTrafficStatus.Ok)
        {
            return ReportJson.Object(("status", ReportJson.Of(traffic.Status == ReportTrafficStatus.Off ? "off" : "unavailable")));
        }

        var rate = traffic.Rate;
        TrafficRate? top = (peak, rate) switch
        {
            ({ } p, { } r) => new TrafficRate(Math.Max(p.Rx, r.Rx), Math.Max(p.Tx, r.Tx)),
            _ => peak ?? rate,
        };
        return ReportJson.Object(
            ("status", ReportJson.Of("ok")),
            ("includesTools", ReportJson.Of(traffic.IncludesTools)),
            ("rxBytesPerSecond", ReportJson.OfOptional(rate is { } r1 ? BytesPerSecond(r1.Rx) : null)),
            ("txBytesPerSecond", ReportJson.OfOptional(rate is { } r2 ? BytesPerSecond(r2.Tx) : null)),
            ("peakRxBytesPerSecond", ReportJson.OfOptional(top is { } t1 ? BytesPerSecond(t1.Rx) : null)),
            ("peakTxBytesPerSecond", ReportJson.OfOptional(top is { } t2 ? BytesPerSecond(t2.Tx) : null)),
            ("rxBytes", ReportJson.Of(Math.Max(0, bytes.Rx))),
            ("txBytes", ReportJson.Of(Math.Max(0, bytes.Tx))));
    }

    /// <summary>One entry per source with activity in the window, in source order (REPORTING 6.6.3, METRICS 11.7).</summary>
    private static List<ReportJson> SourceEntries(ReportWindowContent content, ReportSample sample, IReadOnlySet<ReportSection> sections)
    {
        var usage = new Dictionary<SourceKind, ReportUsage>();
        foreach (var (key, value) in content.Usage.ByModel)
        {
            usage[key.Source] = usage.GetValueOrDefault(key.Source) + value;
        }

        var withCost = sections.Contains(ReportSection.Cost);
        var trafficOk = sections.Contains(ReportSection.Traffic) && sample.Traffic.Status == ReportTrafficStatus.Ok;
        var entries = new List<ReportJson>();
        foreach (var kind in SourceOrder)
        {
            var source = sample.Sources.GetValueOrDefault(kind);
            var agents = sample.Facts.Agents.GetValueOrDefault(kind);
            var delta = usage.GetValueOrDefault(kind);
            var bytes = content.AgentBytes.GetValueOrDefault(kind);
            TrafficRate? rate = trafficOk
                ? sample.Traffic.SourceRates.TryGetValue(kind, out var own) ? own : sample.Traffic.Rate is null ? null : TrafficRate.Zero
                : null;
            var values = new List<double>
            {
                ReportJson.Round(source.Live.Output, 1), ReportJson.Round(source.Live.Total, 1), agents.Generating, agents.Tools,
                delta.Requests, delta.Output, delta.Input, delta.CachedInput, delta.CacheWriteInput, delta.Reasoning,
                delta.MeasuredOutput, delta.MeasuredMs,
            };
            if (withCost)
            {
                values.AddRange([ReportJson.Round(source.LiveCost.MicroUsdPerSecond, 0), delta.CostMicroUsd, delta.UnpricedRequests]);
            }

            if (trafficOk)
            {
                values.AddRange([ReportJson.Round(rate?.Rx ?? 0, 0), ReportJson.Round(rate?.Tx ?? 0, 0), bytes.Rx, bytes.Tx]);
            }

            if (!values.Any(v => v > 0))
            {
                continue;
            }

            var estimated = source.Live.Output > 0 ? source.LiveEstimated.Output / source.Live.Output : 0;
            var members = new List<(string, ReportJson)>
            {
                ("source", ReportJson.Of(SourceId(kind))),
                ("live", ReportJson.Object(
                    ("outputTokS", TokS(source.Live.Output)), ("totalTokS", TokS(source.Live.Total)), ("estimatedShare", Share(estimated)))),
                ("agents", Counts(agents)),
                ("delta", Delta(delta)),
            };
            if (withCost)
            {
                members.Add(("cost", ReportJson.Object(
                    ("liveMicroUsdPerSecond", PerSecond(source.LiveCost.MicroUsdPerSecond)),
                    ("knownShare", Share(source.LiveCost.KnownShare(source.Live.Output))),
                    ("deltaMicroUsd", ReportJson.Of(delta.CostMicroUsd)),
                    ("unpricedRequests", ReportJson.Of(delta.UnpricedRequests)))));
            }

            if (trafficOk)
            {
                members.Add(("traffic", ReportJson.Object(
                    ("rxBytesPerSecond", ReportJson.OfOptional(rate is { } a ? BytesPerSecond(a.Rx) : null)),
                    ("txBytesPerSecond", ReportJson.OfOptional(rate is { } b ? BytesPerSecond(b.Tx) : null)),
                    ("rxBytes", ReportJson.Of(bytes.Rx)), ("txBytes", ReportJson.Of(bytes.Tx)))));
            }

            entries.Add(ReportJson.Object(members));
        }

        return entries;
    }

    /// <summary>
    /// One entry per model with any increment in the window (a late price included) or a generating agent, by output then
    /// id, <c>other</c> last (REPORTING 6.6.4, METRICS 11.3, 11.7).
    /// </summary>
    private static List<ReportJson> ModelEntries(ReportWindowContent content, ReportSample sample, int maxModels, bool withCost, ReportExtensions extensions)
    {
        var byId = new Dictionary<string, ModelEntry>(StringComparer.Ordinal);
        ModelEntry Entry(string id) => byId.TryGetValue(id, out var entry) ? entry : byId[id] = new ModelEntry(id);
        foreach (var (key, value) in content.Usage.ByModel)
        {
            var entry = Entry(key.ModelId);
            entry.Usage += value;
            entry.Sources.Add(key.Source);
            entry.HarnessRequests[key.Source] = entry.HarnessRequests.GetValueOrDefault(key.Source) + value.Requests;
        }

        foreach (var (key, value) in content.Usage.ByMode) Entry(key.ModelId).AddMode(key, value);

        foreach (var (key, count) in sample.Facts.GeneratingModels)
        {
            if (count > 0)
            {
                var entry = Entry(key.ModelId);
                entry.Generating += count;
                entry.Sources.Add(key.Source);
            }
        }

        var entries = byId.Values
            .OrderByDescending(e => e.Usage.Output)
            .ThenBy(e => e.Id, StringComparer.Ordinal)
            .ToList();
        if (entries.Count > maxModels)
        {
            var other = new ModelEntry(ReportModelIds.Other);
            foreach (var entry in entries.Skip(maxModels - 1))
            {
                other.Usage += entry.Usage;
                other.Generating += entry.Generating;
                other.Sources.UnionWith(entry.Sources);
                foreach (var (source, requests) in entry.HarnessRequests)
                    other.HarnessRequests[source] = other.HarnessRequests.GetValueOrDefault(source) + requests;
                foreach (var (mode, usage) in entry.Modes) other.AddMode(mode, usage);
            }

            entries = [.. entries.Take(maxModels - 1), other];
        }

        return entries.Select(entry =>
        {
            var members = new List<(string, ReportJson)>
            {
                ("id", ReportJson.Of(entry.Id)),
                ("sources", ReportJson.Array(SourceOrder.Where(entry.Sources.Contains).Select(s => ReportJson.Of(SourceId(s))))),
                ("requests", ReportJson.Of(entry.Usage.Requests)),
                ("output", ReportJson.Of(entry.Usage.Output)),
                ("measuredOutput", ReportJson.Of(entry.Usage.MeasuredOutput)),
                ("measuredMs", ReportJson.Of(entry.Usage.MeasuredMs)),
                ("generating", ReportJson.Of(Math.Min(entry.Generating, MaxCount))),
            };
            if (withCost)
            {
                members.Add(("deltaMicroUsd", ReportJson.Of(entry.Usage.CostMicroUsd)));
            }

            if (extensions.ModelHarnessRequests && entry.HarnessRequests.Count <= 8
                && entry.HarnessRequests.Values.All(IsSafeCount) && entry.HarnessRequests.Values.Sum() == entry.Usage.Requests)
                members.Add(("harnessRequests", ReportJson.Array(entry.HarnessRequests.OrderBy(p => p.Key)
                    .Where(p => p.Value > 0).Select(p => ReportJson.Object(("source", ReportJson.Of(SourceId(p.Key))), ("requests", ReportJson.Of(p.Value)))))));
            if (extensions.ExecutionModes && ModesJson(entry) is { } modes) members.Add(("modeUsage", modes));

            return ReportJson.Object(members);
        }).ToList();
    }

    private static ReportJson Delta(ReportUsage usage) => ReportJson.Object(
        ("requests", ReportJson.Of(usage.Requests)), ("output", ReportJson.Of(usage.Output)), ("input", ReportJson.Of(usage.Input)),
        ("cachedInput", ReportJson.Of(usage.CachedInput)), ("cacheWriteInput", ReportJson.Of(usage.CacheWriteInput)),
        ("reasoning", ReportJson.Of(usage.Reasoning)), ("measuredOutput", ReportJson.Of(usage.MeasuredOutput)),
        ("measuredMs", ReportJson.Of(usage.MeasuredMs)));

    private static ReportJson Counts(ReportAgentCounts agents) => ReportJson.Object(
        ("generating", ReportJson.Of(Math.Min(agents.Generating, MaxCount))), ("tools", ReportJson.Of(Math.Min(agents.Tools, MaxCount))),
        ("active", ReportJson.Of(Math.Min(agents.Active, MaxCount))));

    private static ReportJson TokS(double value) => ReportJson.Decimal(Math.Clamp(double.IsFinite(value) ? value : 0, 0, MaxTokS), 1);

    private static ReportJson Share(double value) => ReportJson.Decimal(Math.Clamp(double.IsFinite(value) ? value : 0, 0, 1), 3);

    private static ReportJson PerSecond(double value) =>
        ReportJson.Of((long)ReportJson.Round(Math.Clamp(double.IsFinite(value) ? value : 0, 0, 9e15), 0));

    private static long BytesPerSecond(double value) => (long)ReportJson.Round(Math.Clamp(double.IsFinite(value) ? value : 0, 0, 1e12), 0);

    private sealed class ModelEntry(string id)
    {
        public string Id { get; } = id;

        public HashSet<SourceKind> Sources { get; } = [];

        public ReportUsage Usage { get; set; }

        public int Generating { get; set; }
        public Dictionary<SourceKind, long> HarnessRequests { get; } = [];
        public Dictionary<ReportModeKey, ReportUsage> Modes { get; } = [];
        public void AddMode(ReportModeKey key, ReportUsage usage)
        {
            key = key with { ModelId = Id };
            Modes[key] = Modes.GetValueOrDefault(key) + usage;
        }
    }

    private static bool IsSafeCount(long value) => value is >= 0 and <= 9_007_199_254_740_991;

    private static ReportJson? ModesJson(ModelEntry entry)
    {
        if (entry.Modes.Count > 64 || !IsSafeCount(entry.Usage.Requests) || !IsSafeCount(entry.Usage.Output)
            || !IsSafeCount(entry.Usage.MeasuredOutput) || !IsSafeCount(entry.Usage.MeasuredMs)) return null;
        if (entry.Modes.Count == 0 && (entry.Usage.Requests > 0 || entry.Usage.Output > 0 || entry.Usage.MeasuredOutput > 0 || entry.Usage.MeasuredMs > 0)) return null;
        foreach (var group in entry.Modes.GroupBy(p => p.Key.Kind))
        {
            var sum = group.Aggregate(ReportUsage.Zero, (total, p) => total + p.Value);
            if ((sum.Requests, sum.Output, sum.MeasuredOutput, sum.MeasuredMs)
                != (entry.Usage.Requests, entry.Usage.Output, entry.Usage.MeasuredOutput, entry.Usage.MeasuredMs)) return null;
        }
        var rows = new List<ReportJson>();
        foreach (var (key, usage) in entry.Modes.OrderBy(p => p.Key.Source).ThenBy(p => p.Key.Kind)
            .ThenBy(p => p.Key.Mode, StringComparer.Ordinal).ThenBy(p => p.Key.Evidence, StringComparer.Ordinal).ThenBy(p => p.Key.Provider, StringComparer.Ordinal))
        {
            if (!entry.Sources.Contains(key.Source) || !Enum.IsDefined(key.Kind) || !ExecutionModes.IsIdentifier(key.Mode, 64)
                || key.Evidence is not ("served" or "recorded" or "selected" or "unknown")
                || ((key.Mode == "unknown") != (key.Evidence == "unknown"))
                || (key.Provider is not null && !ExecutionModes.IsIdentifier(key.Provider, 32))
                || !IsSafeCount(usage.Requests) || !IsSafeCount(usage.Output) || !IsSafeCount(usage.MeasuredOutput) || !IsSafeCount(usage.MeasuredMs)) return null;
            var members = new List<(string, ReportJson)>
            {
                ("source", ReportJson.Of(SourceId(key.Source))), ("kind", ReportJson.Of(ExecutionModes.Name(key.Kind))),
                ("mode", ReportJson.Of(key.Mode)), ("evidence", ReportJson.Of(key.Evidence)), ("requests", ReportJson.Of(usage.Requests)),
                ("output", ReportJson.Of(usage.Output)), ("measuredOutput", ReportJson.Of(usage.MeasuredOutput)), ("measuredMs", ReportJson.Of(usage.MeasuredMs)),
            };
            if (key.Provider is { } provider) members.Insert(1, ("provider", ReportJson.Of(provider)));
            rows.Add(ReportJson.Object(members));
        }
        return ReportJson.Array(rows);
    }
}
