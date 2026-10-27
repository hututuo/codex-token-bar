using System.Globalization;
using System.Text.Json;
using AgentSpeed.Core.Money;

namespace AgentSpeed.Core.Network;

/// <summary>One exchange-rate source of NETWORK 4, in fallback order.</summary>
public sealed record ExchangeRateProvider(ExchangeRates.Shape Shape, Uri Url)
{
    public string Host => Url.IdnHost;
}

/// <summary>
/// <c>&lt;app data&gt;/rates.json</c> (NETWORK 4): <c>{provider, url, date, fetchedMs, etags, rates}</c>; <c>date</c> is the
/// rates' own date in Unix ms and rates are decimal strings, so nothing is rounded on the way to disk.
/// </summary>
public sealed record StoredRates(
    string Provider,
    string Url,
    long Date,
    long FetchedMs,
    IReadOnlyDictionary<string, string> ETags,
    IReadOnlyDictionary<string, string> Rates)
{
    public static StoredRates From(ExchangeRateSet set, IReadOnlyDictionary<string, string> etags)
    {
        ArgumentNullException.ThrowIfNull(set);
        var rates = set.Rates.ToDictionary(pair => pair.Key, pair => pair.Value.ToString(CultureInfo.InvariantCulture), StringComparer.Ordinal);
        return new StoredRates(set.Provider, set.Url, set.DateMs, set.FetchedMs, new Dictionary<string, string>(etags, StringComparer.Ordinal), rates);
    }

    public ExchangeRateSet ToRateSet()
    {
        var decoded = new Dictionary<string, decimal>(StringComparer.Ordinal);
        foreach (var (code, text) in Rates)
        {
            if (decimal.TryParse(text, NumberStyles.AllowDecimalPoint | NumberStyles.AllowExponent, CultureInfo.InvariantCulture, out var value)
                && value > 0)
            {
                decoded[code] = value;
            }
        }

        return new ExchangeRateSet(Provider, Url, Date, FetchedMs, decoded);
    }

    internal byte[] ToJson() => StoreJson.Write(writer =>
    {
        writer.WriteNumber("date", Date);
        StoreJson.WriteMap(writer, "etags", ETags);
        writer.WriteNumber("fetchedMs", FetchedMs);
        writer.WriteString("provider", Provider);
        StoreJson.WriteMap(writer, "rates", Rates);
        writer.WriteString("url", Url);
    });

    /// <summary>Every field present with its type, as the macOS decoder requires; null otherwise.</summary>
    internal static StoredRates? FromJson(ReadOnlySpan<byte> utf8)
    {
        try
        {
            using var document = JsonDocument.Parse(utf8.ToArray());
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || StoreJson.String(root, "provider") is not { } provider || StoreJson.String(root, "url") is not { } url
                || StoreJson.Int64(root, "date") is not { } date || StoreJson.Int64(root, "fetchedMs") is not { } fetchedMs
                || StoreJson.Map(root, "etags") is not { } etags || StoreJson.Map(root, "rates") is not { } rates)
            {
                return null;
            }

            return new StoredRates(provider, url, date, fetchedMs, etags, rates);
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException)
        {
            return null;
        }
    }
}

/// <summary>The accepted exchange rates on disk, written atomically.</summary>
public sealed class ExchangeRateStore
{
    public const string FileName = "rates.json";

    private const int MaxFileBytes = 1 << 20;

    private readonly Action<string>? _log;

    /// <param name="appDataDirectory"><c>%LOCALAPPDATA%\AgentSpeed</c> in the app; any folder in tests and the probe.</param>
    public ExchangeRateStore(string appDataDirectory, Action<string>? log = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(appDataDirectory);
        FilePath = Path.Combine(appDataDirectory, FileName);
        _log = log;
    }

    public string FilePath { get; }

    /// <summary>The stored rates; an unreadable file is deleted (logged).</summary>
    public StoredRates? Load()
    {
        byte[] data;
        try
        {
            var info = new FileInfo(FilePath);
            if (!info.Exists)
            {
                return null;
            }

            data = info.Length <= MaxFileBytes ? File.ReadAllBytes(FilePath) : [];
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }

        if (StoredRates.FromJson(data) is { } stored && stored.Rates.ContainsKey(Currency.UsdCode))
        {
            return stored;
        }

        _log?.Invoke("Stored exchange rates are unreadable; deleted");
        AtomicFile.TryDelete(FilePath);
        return null;
    }

    /// <exception cref="IOException">The file could not be written.</exception>
    /// <exception cref="UnauthorizedAccessException">The folder is not writable.</exception>
    public void Save(StoredRates stored)
    {
        ArgumentNullException.ThrowIfNull(stored);
        AtomicFile.Write(FilePath, stored.ToJson());
    }
}

/// <summary>The rates every displayed amount uses (METRICS 9.8): the last accepted rates, else the bundled fallback.</summary>
public sealed class RatesInUse
{
    public const long StaleAfterMs = 7 * ExchangeRates.DayMs;

    private readonly IReadOnlyDictionary<string, decimal> _fallback;

    public RatesInUse(ExchangeRateSet? stored, FallbackRates fallback)
    {
        ArgumentNullException.ThrowIfNull(fallback);
        _fallback = fallback.Rates;
        if (stored is not null)
        {
            Rates = stored.Rates;
            DateMs = stored.DateMs;
            Provider = stored.Provider;
            FetchedMs = stored.FetchedMs;
        }
        else
        {
            Rates = fallback.Rates;
            DateMs = fallback.DateMs;
        }
    }

    public IReadOnlyDictionary<string, decimal> Rates { get; }

    /// <summary>The rates' own date (Unix ms).</summary>
    public long DateMs { get; }

    /// <summary>The provider's host; null for the bundled fallback.</summary>
    public string? Provider { get; }

    public long? FetchedMs { get; }

    public bool IsFallback => Provider is null;

    public bool NeedsAttribution => Provider == ExchangeRates.ErApiHost;

    /// <summary>Units of <paramref name="code"/> per 1 USD (USD = 1); a currency the accepted list lacks takes its bundled rate.</summary>
    public decimal Rate(string code)
    {
        if (code == Currency.UsdCode)
        {
            return 1;
        }

        return Rates.TryGetValue(code, out var rate) ? rate : _fallback.TryGetValue(code, out var bundled) ? bundled : 1;
    }

    /// <summary>Older than 7 days by the rates' date (<c>rates.stale</c>); conversion continues with them.</summary>
    public bool IsStale(long nowMs) => nowMs - DateMs > StaleAfterMs;
}

/// <summary>What one exchange-rate round found.</summary>
public abstract record ExchangeRateOutcome
{
    private ExchangeRateOutcome()
    {
    }

    public sealed record Updated(ExchangeRateSet Set) : ExchangeRateOutcome;

    /// <summary>A <c>304</c> confirmed the stored rates.</summary>
    public sealed record Unchanged(ExchangeRateSet Set) : ExchangeRateOutcome;

    public sealed record Failed(string Reason) : ExchangeRateOutcome;
}

/// <summary>
/// One round of NETWORK 4: 1 → 2a → (2b when 2a failed) → 3, stopping at the first response that passes checks 1–5.
/// Every request asks for the complete USD-based list, never for the selected currency.
/// </summary>
public sealed class ExchangeRateSync
{
    public const int MaxBytes = 256 << 10;

    public static readonly TimeSpan LaunchDelay = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan Interval = TimeSpan.FromHours(24);
    public static readonly TimeSpan RetryDelay = TimeSpan.FromHours(1);

    /// <summary>The schedule is re-checked at least this often (and on wake).</summary>
    public static readonly TimeSpan CheckInterval = TimeSpan.FromHours(1);

    /// <summary>1 → 2a → 2b → 3. 2b (the project's Cloudflare Pages mirror) is only asked when 2a fails.</summary>
    public static readonly IReadOnlyList<ExchangeRateProvider> Providers =
    [
        new(ExchangeRates.Shape.ErApi, new Uri("https://open.er-api.com/v6/latest/USD")),
        new(ExchangeRates.Shape.Fawaz, new Uri("https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.min.json")),
        new(ExchangeRates.Shape.Fawaz, new Uri("https://latest.currency-api.pages.dev/v1/currencies/usd.min.json")),
        new(ExchangeRates.Shape.Frankfurter, new Uri("https://api.frankfurter.dev/v1/latest?base=USD")),
    ];

    public static readonly IReadOnlySet<string> AllowedHosts = Providers.Select(p => p.Host).ToHashSet(StringComparer.Ordinal);

    /// <summary>ExchangeRate-API's attribution link (its terms require it while its rates are in use).</summary>
    public static readonly Uri AttributionUrl = new("https://www.exchangerate-api.com");

    private readonly ExchangeRateStore _store;
    private readonly IHttpTransport _transport;
    private readonly string _userAgent;
    private readonly CurrencyTable _currencies;
    private readonly IReadOnlyList<ExchangeRateProvider> _providers;
    private readonly Func<DateTimeOffset> _now;
    private readonly Action<string>? _log;

    /// <param name="userAgent"><see cref="HttpFetchRequest.UserAgentFor"/> of the app's version.</param>
    /// <param name="log">Receives one line per request outcome: host, status, size and reason, nothing personal.</param>
    public ExchangeRateSync(
        ExchangeRateStore store,
        IHttpTransport transport,
        string userAgent,
        CurrencyTable? currencies = null,
        IReadOnlyList<ExchangeRateProvider>? providers = null,
        Func<DateTimeOffset>? now = null,
        Action<string>? log = null)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(transport);
        ArgumentNullException.ThrowIfNull(userAgent);
        _store = store;
        _transport = transport;
        _userAgent = userAgent;
        _currencies = currencies ?? CurrencyTable.Bundled;
        _providers = providers ?? Providers;
        _now = now ?? (() => DateTimeOffset.UtcNow);
        _log = log;
    }

    /// <summary>
    /// The next automatic round while a non-USD currency is selected: 30 s after launch, then 24 h after the last accepted
    /// fetch, and never sooner than 1 h after a failed round. Stamps in the future count as now.
    /// </summary>
    public static DateTimeOffset NextAttempt(DateTimeOffset launchedAt, DateTimeOffset? fetchedAt, DateTimeOffset? lastFailure, DateTimeOffset now)
    {
        var due = launchedAt + LaunchDelay;
        if (fetchedAt is { } fetched)
        {
            due = Later(due, Earlier(fetched, now) + Interval);
        }

        if (lastFailure is { } failure)
        {
            due = Later(due, Earlier(failure, now) + RetryDelay);
        }

        return due;
    }

    /// <summary>
    /// Selecting a non-USD currency fetches at once when the stored rates are missing or older than 24 h, unless a round
    /// failed within the last hour.
    /// </summary>
    public static bool FetchesOnSelection(DateTimeOffset? fetchedAt, DateTimeOffset? lastFailure, DateTimeOffset now)
    {
        if (lastFailure is { } failure && now - failure < RetryDelay)
        {
            return false;
        }

        return fetchedAt is not { } fetched || now - fetched >= Interval;
    }

    /// <summary>One round for the selected currency; never throws for network or data problems.</summary>
    /// <exception cref="OperationCanceledException">The caller cancelled.</exception>
    public async Task<ExchangeRateOutcome> RunAsync(string selected, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(selected);
        var previous = _store.Load();
        var previousSet = previous?.ToRateSet();
        var nowMs = _now().ToUnixTimeMilliseconds();
        var supported = _currencies.Codes;
        var fallback = _currencies.FallbackRates.Rates;
        var last = previousSet is null ? null : new ExchangeRates.Reference(previousSet.DateMs, previousSet.FetchedMs, previousSet.Rates);
        Candidate? pending = null;
        var failure = "no response";
        var fawazAnswered = false;
        foreach (var provider in _providers)
        {
            if (provider.Shape == ExchangeRates.Shape.Fawaz && fawazAnswered)
            {
                continue;
            }

            var url = provider.Url.AbsoluteUri;
            var etag = previous is not null && previous.Url == url ? previous.ETags.GetValueOrDefault(url) : null;
            var request = new HttpFetchRequest(provider.Url, _userAgent, MaxBytes, AllowedHosts) { IfNoneMatch = etag };
            HttpFetchResponse response;
            try
            {
                response = await _transport.GetAsync(request, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                failure = ex is HttpFetchException fetch ? fetch.Reason : "transport error";
                Log(provider, failure);
                continue;
            }

            if (response.Status == 304 && previous is not null && previousSet is not null && previous.Url == url)
            {
                var confirmed = previousSet with { FetchedMs = nowMs };
                TrySave(StoredRates.From(confirmed, previous.ETags));
                Log(provider, "304, unchanged");
                return new ExchangeRateOutcome.Unchanged(confirmed);
            }

            if (!response.IsSuccess)
            {
                failure = "HTTP " + response.Status.ToString(CultureInfo.InvariantCulture);
                Log(provider, failure);
                continue;
            }

            ParsedRates parsed;
            try
            {
                parsed = ExchangeRates.Parse(provider.Shape, response.Body, supported);
            }
            catch (FormatException ex)
            {
                failure = "invalid response";
                Log(provider, $"{response.Body.Length} bytes rejected ({ex.Message})");
                continue;
            }

            if (provider.Shape == ExchangeRates.Shape.Fawaz)
            {
                fawazAnswered = true;
            }

            IReadOnlyDictionary<string, decimal> rates = parsed.Rates;
            if (provider.Shape == ExchangeRates.Shape.Frankfurter)
            {
                // Check 5: only with the selected currency; its missing currencies keep their previous rates.
                if (!rates.ContainsKey(selected))
                {
                    failure = "selected currency missing";
                    Log(provider, failure);
                    continue;
                }

                var merged = new Dictionary<string, decimal>(previousSet?.Rates ?? fallback, StringComparer.Ordinal);
                foreach (var (code, rate) in rates)
                {
                    merged[code] = rate;
                }

                rates = merged;
            }

            var candidate = new Candidate(provider, parsed.DateMs, rates, response.ETag);
            if (pending is { } first)
            {
                var confirmation = ExchangeRates.Check(first.DateMs, first.Rates, selected, nowMs, last, fallback, candidate.Rates);
                if (confirmation.IsAccepted)
                {
                    Log(first.Provider, "confirmed by " + provider.Host);
                    return Accept(first, previous, nowMs);
                }

                Log(first.Provider, "not confirmed by " + provider.Host);
                pending = null;
            }

            var verdict = ExchangeRates.Check(candidate.DateMs, candidate.Rates, selected, nowMs, last, fallback);
            switch (verdict.Kind)
            {
                case ExchangeRates.VerdictKind.Accepted:
                    return Accept(candidate, previous, nowMs);
                case ExchangeRates.VerdictKind.NeedsSecondProvider:
                    Log(provider, "needs a second provider (the last rates are older than 30 days)");
                    pending = candidate;
                    break;
                default:
                    failure = verdict.Reason ?? "rejected";
                    Log(provider, "rejected: " + failure);
                    break;
            }
        }

        if (pending is not null)
        {
            failure = "needs a second provider";
        }

        _log?.Invoke($"Exchange rates: every provider failed ({failure})");
        return new ExchangeRateOutcome.Failed(failure);
    }

    private static DateTimeOffset Earlier(DateTimeOffset lhs, DateTimeOffset rhs) => lhs < rhs ? lhs : rhs;

    private static DateTimeOffset Later(DateTimeOffset lhs, DateTimeOffset rhs) => lhs > rhs ? lhs : rhs;

    private ExchangeRateOutcome.Updated Accept(Candidate candidate, StoredRates? previous, long nowMs)
    {
        var set = new ExchangeRateSet(candidate.Provider.Host, candidate.Provider.Url.AbsoluteUri, candidate.DateMs, nowMs, candidate.Rates);
        var etags = new Dictionary<string, string>(previous?.ETags ?? new Dictionary<string, string>(), StringComparer.Ordinal);
        if (candidate.ETag is { } etag)
        {
            etags[set.Url] = etag;
        }
        else
        {
            etags.Remove(set.Url);
        }

        TrySave(StoredRates.From(set, etags));
        Log(candidate.Provider, $"accepted, {set.Rates.Count} currencies");
        return new ExchangeRateOutcome.Updated(set);
    }

    private void TrySave(StoredRates stored)
    {
        try
        {
            _store.Save(stored);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _log?.Invoke("Exchange rates could not be saved");
        }
    }

    private void Log(ExchangeRateProvider provider, string message) => _log?.Invoke($"Exchange rates {provider.Host}: {message}");

    private sealed record Candidate(ExchangeRateProvider Provider, long DateMs, IReadOnlyDictionary<string, decimal> Rates, string? ETag);
}
