using AgentSpeed.Core.History;
using AgentSpeed.Core.Parsing;
using AgentSpeed.Core.Pricing;
using AgentSpeed.Core.Reporting;

namespace AgentSpeed.Core.Engine;

/// <summary>
/// Pure, deterministic speed engine (METRICS 6). Every computation takes an explicit <c>nowMs</c> and
/// <c>todayStartMs</c>. Not thread-safe: the monitor owns it on a single thread.
/// </summary>
internal sealed class SpeedEngine
{
    public const long WindowMs = 3000;
    public const long RetentionMs = 30 * 60_000;
    public const long RecentWindowMs = 10 * 60_000;
    public const long FallbackWindowMs = 30 * 60_000;
    public const long StaleMs = 300_000;
    public const long AgentListWindowMs = 600_000;
    public const int HistorySeconds = 300;
    public const int RecentCount = 3;
    public const int FallbackCount = 10;
    public const double PeakMinimum = 20;
    public const double PeakMargin = 1;
    public const long PeakCooldownMs = 60_000;
    public const int MaxEventsPerFrame = 50;

    /// <summary>Older responses that appear while running update totals silently (METRICS 6.4).</summary>
    public const long CompletionEventWindowMs = 120_000;

    private static readonly int SourceCount = Enum.GetValues<SourceKind>().Length;

    private readonly Dictionary<string, Stored> _responses = new(StringComparer.Ordinal);
    private readonly Dictionary<string, AgentInfo> _agents = new(StringComparer.Ordinal);
    private readonly List<ParsedResponse> _completions = [];
    private readonly TodayLedger _today;

    /// <summary>Prices responses as they arrive (METRICS 9.3, 9.7); without it, responses keep the cost they carry.</summary>
    private readonly PriceBook? _pricing;
    private readonly DayLabeler _dayLabeler;

    /// <summary>The current table version the stored responses were last priced with.</summary>
    private int? _pricedVersion;
    private ParsedResponse? _last;
    private double _liveMaxOutput;
    private double _liveMaxTotal;
    private long? _liveMaxOutputAtMs;
    private double? _previousPeakOutput;
    private long? _lastPeakEventMs;
    private static long _epochs;

    /// <summary>What live reporting counts (METRICS 11.4); fed whatever reporting does, so nothing depends on its settings.</summary>
    private readonly ReportLedger _reportLedger = new();

    /// <summary>The provider of each agent's latest response, for the model id of a generating agent (METRICS 11.2).</summary>
    private readonly Dictionary<string, string> _agentProviders = new(StringComparer.Ordinal);
    private ReportCounters _reportCounters = ReportCounters.Zero;
    private long _reportCountersVersion = -1;

    public SpeedEngine(long todayStartMs, PriceBook? pricing = null, TimeZoneInfo? zone = null)
    {
        _today = new TodayLedger(todayStartMs);
        _pricing = pricing;
        _pricedVersion = pricing?.CurrentVersion;
        _dayLabeler = new DayLabeler(zone ?? TimeZoneInfo.Local);
    }

    public long TodayStartMs => _today.StartMs;

    /// <summary>This engine's identity for live reporting's differences: a new session counts from zero.</summary>
    public long ReportEpoch { get; } = Interlocked.Increment(ref _epochs);

    /// <summary>Sources with measured output today.</summary>
    public SourceSet MeasuredSourcesToday => _today.MeasuredSources;

    public void UpdateAgent(in AgentInfo agent) => _agents[agent.Id] = agent;

    public void RemoveAgent(string id) => _agents.Remove(id);

    public void SetParent(string id, string? parentId)
    {
        if (_agents.TryGetValue(id, out var agent) && !string.Equals(agent.ParentId, parentId, StringComparison.Ordinal))
        {
            _agents[id] = agent with { ParentId = parentId };
        }
    }

    /// <summary>Adds or replaces a response (METRICS 4.3). Seeded responses never produce events.</summary>
    /// <param name="liveNowMs">The live clock at the upsert; null (seeding, tests) never counts the response for reporting.</param>
    public void Upsert(ParsedResponse response, bool isCompletion, bool seeded, long? liveNowMs = null)
    {
        if (_pricing is not null)
        {
            response = response with { CostMicroUsd = Price(response) };
        }

        _responses[response.Key] = new Stored(response);
        if (response.Provider is { } provider)
        {
            _agentProviders[response.AgentId] = provider;
        }

        if (isCompletion && !seeded && liveNowMs is { } now && response.EndMs >= now - CompletionEventWindowMs)
        {
            _reportLedger.Count(response, ReportModelId(response.Model, response.Provider));
        }
        else if (_reportLedger.IsCounted(response.Key))
        {
            _reportLedger.Grow(response, ReportModelId(response.Model, response.Provider));
        }

        _today.Upsert(response);
        if (isCompletion && !seeded)
        {
            if (_completions.Count >= MaxEventsPerFrame * 4)
            {
                _completions.RemoveRange(0, MaxEventsPerFrame * 2);
            }

            _completions.Add(response);
        }

        if (_last is null || response.EndMs >= _last.EndMs || string.Equals(_last.Key, response.Key, StringComparison.Ordinal))
        {
            _last = response;
        }
    }

    public EngineFrame Compute(long nowMs, long todayStartMs, bool observeLive)
    {
        if (todayStartMs != _today.StartMs)
        {
            RollDay(todayStartMs);
        }

        Evict(nowMs - RetentionMs);
        RepriceIfNeeded();

        var windowStart = nowMs - WindowMs;
        var measured = new Accumulator(SourceCount);
        var costs = new CostAccumulator(SourceCount);
        var valid = new List<Stored>(_responses.Count);
        var unmeasured = new List<Stored>();
        var latestEnd = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var stored in _responses.Values)
        {
            var agentId = stored.Response.AgentId;
            if (!latestEnd.TryGetValue(agentId, out var end) || stored.Response.EndMs > end)
            {
                latestEnd[agentId] = stored.Response.EndMs;
            }

            if (!stored.Valid)
            {
                continue;
            }

            if (!stored.Response.Final)
            {
                unmeasured.Add(stored);
                continue;
            }

            valid.Add(stored);
            var overlap = SpeedMath.Overlap(windowStart, nowMs, stored.Interval.StartMs, stored.Interval.EndMs);
            if (overlap > 0)
            {
                var fraction = (double)overlap / stored.Interval.DurationMs;
                var output = stored.Response.Tokens.Output * fraction;
                measured.Add(stored.Response.Source, stored.Response.AgentId, output, stored.Response.Tokens.Total * fraction);
                if (stored.Response.CostMicroUsd is { } cost)
                {
                    costs.Add(stored.Response.Source, stored.Response.AgentId, new LiveCost(cost * fraction, output));
                }
            }
        }

        valid.Sort(static (a, b) => b.Response.EndMs != a.Response.EndMs
            ? b.Response.EndMs.CompareTo(a.Response.EndMs)
            : string.CompareOrdinal(a.Response.Key, b.Response.Key));

        var recent = RecentSpeeds(valid, nowMs);
        var estimated = new Accumulator(SourceCount);
        var estimates = new List<(long StartMs, long EndMs, SpeedPair Speed)>();

        void AddEstimate(SourceKind source, string agentId, SpeedPair reference, long overlap)
        {
            var output = reference.Output * overlap / 1000.0;
            estimated.Add(source, agentId, output, reference.Total * overlap / 1000.0);
            if (reference.CostRate is { } rate)
            {
                costs.Add(source, agentId, new LiveCost(rate * overlap / 1000.0, output));
            }
        }

        // Unfinalized usage: the time is real, the token count is not, so it is estimated (METRICS 6.3).
        foreach (var stored in unmeasured)
        {
            var response = stored.Response;
            var owner = _agents.TryGetValue(response.AgentId, out var known)
                ? known
                : new AgentInfo(response.AgentId, response.Source, null, response.Model, false, AgentPhase.Idle, null, null);
            SpeedPair? speed = recent.TryGetValue(owner.Id, out var ownSpeed) ? ownSpeed : Fallback(valid, nowMs, owner);
            if (speed is not { } reference)
            {
                continue;
            }

            estimates.Add((stored.Interval.StartMs, stored.Interval.EndMs, reference));
            var overlap = SpeedMath.Overlap(windowStart, nowMs, stored.Interval.StartMs, stored.Interval.EndMs);
            AddEstimate(response.Source, response.AgentId, reference, overlap);
        }

        foreach (var agent in _agents.Values)
        {
            if (agent.Phase != AgentPhase.Generating || agent.InFlightStartMs is not { } start
                || agent.LastLineMs is not { } last || nowMs - last > StaleMs)
            {
                continue;
            }

            SpeedPair? speed = recent.TryGetValue(agent.Id, out var own) ? own : Fallback(valid, nowMs, agent);
            if (speed is not { } estimate)
            {
                continue;
            }

            // Never estimate over the agent's own (possibly still streaming) responses.
            var estimateStart = latestEnd.TryGetValue(agent.Id, out var ownEnd) ? Math.Max(start, ownEnd) : start;
            estimates.Add((estimateStart, nowMs, estimate));
            var overlap = SpeedMath.Overlap(windowStart, nowMs, estimateStart, nowMs);
            AddEstimate(agent.Source, agent.Id, estimate, overlap);
        }

        var seconds = WindowMs / 1000.0;
        var live = new Rate((measured.Output + estimated.Output) / seconds, (measured.Total + estimated.Total) / seconds);
        var liveSum = measured.Output + estimated.Output;
        var share = liveSum > 0 ? estimated.Output / liveSum : 0;
        var sourceLive = new Rate[SourceCount];
        var sourceEstimated = new Rate[SourceCount];
        for (var i = 0; i < SourceCount; i++)
        {
            sourceLive[i] = new Rate(
                (measured.SourceOutput[i] + estimated.SourceOutput[i]) / seconds,
                (measured.SourceTotal[i] + estimated.SourceTotal[i]) / seconds);
            sourceEstimated[i] = new Rate(estimated.SourceOutput[i] / seconds, estimated.SourceTotal[i] / seconds);
        }

        var sourceLiveCost = new LiveCost[SourceCount];
        var liveCost = LiveCost.Zero;
        for (var i = 0; i < SourceCount; i++)
        {
            sourceLiveCost[i] = PerSecond(costs.Source[i], seconds);
            liveCost += costs.Source[i];
        }

        liveCost = PerSecond(liveCost, seconds);
        var agents = BuildAgents(nowMs, measured, estimated, costs, recent, seconds, out var generating, out var tools);
        var history = BuildHistory(nowMs, valid, estimates);
        var events = DrainCompletions(nowMs);
        var peak = UpdatePeak(nowMs, live, observeLive, events);

        var sourceToday = new TokenTotals[SourceCount];
        var sourceTodayCost = new CostTally[SourceCount];
        var sourceUnpriced = new IReadOnlyList<string>[SourceCount];
        for (var i = 0; i < SourceCount; i++)
        {
            sourceToday[i] = _today.ForSource((SourceKind)i);
            sourceTodayCost[i] = _today.CostForSource((SourceKind)i);
            sourceUnpriced[i] = sourceTodayCost[i].UnpricedRequests > 0 ? _today.UnpricedModels((SourceKind)i) : [];
        }

        return new EngineFrame(
            nowMs,
            live,
            share,
            sourceLive,
            sourceEstimated,
            peak.Rate,
            peak.AtMs,
            _today.AverageOutputSpeed,
            _today.Totals,
            sourceToday,
            agents,
            generating,
            tools,
            history,
            _last is null ? null : Summarize(_last),
            events,
            _today.UnfinalizedCount)
        {
            LiveCost = liveCost,
            SourceLiveCost = sourceLiveCost,
            TodayCost = _today.Cost,
            TodayModes = _today.Modes,
            SourceTodayCost = sourceTodayCost,
            SourceUnpricedModels = sourceUnpriced,
            Report = ReportFacts(nowMs),
        };
    }

    /// <summary>The table that names models for live reporting: the current one (METRICS 11.3).</summary>
    private string ReportModelId(string? model, string? provider) =>
        (_pricing?.Current ?? PriceBook.Bundled).ReportModelId(model, provider);

    /// <summary>Agents of the 6.7 base set per source, generating agents per model, and the report ledger (METRICS 11.2).</summary>
    private ReportLiveFacts ReportFacts(long nowMs)
    {
        var agents = new Dictionary<SourceKind, ReportAgentCounts>();
        var generating = new Dictionary<ReportModelKey, int>();
        foreach (var agent in _agents.Values)
        {
            var phase = AgentList.PhaseAt(agent, nowMs);
            var recent = agent.LastLineMs is { } last && nowMs - last <= AgentListWindowMs;
            if (!recent && phase != AgentPhase.Generating)
            {
                continue;
            }

            var counts = agents.GetValueOrDefault(agent.Source);
            counts = counts with { Active = counts.Active + 1 };
            if (phase == AgentPhase.Generating)
            {
                counts = counts with { Generating = counts.Generating + 1 };
                var key = new ReportModelKey(ReportModelId(agent.Model, _agentProviders.GetValueOrDefault(agent.Id)), agent.Source);
                generating[key] = generating.GetValueOrDefault(key) + 1;
            }
            else if (phase == AgentPhase.Tools)
            {
                counts = counts with { Tools = counts.Tools + 1 };
            }

            agents[agent.Source] = counts;
        }

        if (_reportLedger.Counters.Version != _reportCountersVersion)
        {
            _reportCounters = _reportLedger.Counters.Copy();
            _reportCountersVersion = _reportLedger.Counters.Version;
        }

        return new ReportLiveFacts(agents, generating, _reportCounters, ReportEpoch);
    }

    /// <summary>
    /// Today's measured output peak of a source set as of the last <see cref="Compute"/> (METRICS 6.8): the maximum
    /// 3-bucket trailing average of the members' summed measured buckets, without the observed live part. Cached per
    /// set; recomputed only where a member's buckets changed.
    /// </summary>
    public double MeasuredPeakOutput(SourceSet sources) => _today.MeasuredPeakOutput(sources);

    private long? Price(ParsedResponse response) =>
        _dayLabeler.Label(response.EndMs) is { } day ? _pricing!.Cost(response, day) : null;

    /// <summary>
    /// A new current price table prices the responses no table could price before (METRICS 9.7); a day's bound table,
    /// and so every known cost, stays as it was.
    /// </summary>
    private void RepriceIfNeeded()
    {
        if (_pricing is null || _pricing.CurrentVersion == _pricedVersion)
        {
            return;
        }

        _pricedVersion = _pricing.CurrentVersion;
        var pending = new Dictionary<string, ParsedResponse>(StringComparer.Ordinal);
        foreach (var response in _today.UnpricedResponses)
        {
            pending[response.Key] = response;
        }

        foreach (var (key, stored) in _responses)
        {
            if (stored.Response.CostMicroUsd is null)
            {
                pending[key] = stored.Response;
            }
        }

        foreach (var response in pending.Values)
        {
            if (Price(response) is not { } cost)
            {
                continue;
            }

            var priced = response with { CostMicroUsd = cost };
            if (_responses.ContainsKey(priced.Key))
            {
                _responses[priced.Key] = new Stored(priced);
            }

            if (_reportLedger.IsCounted(priced.Key))
            {
                _reportLedger.Grow(priced, ReportModelId(priced.Model, priced.Provider));
            }

            _today.Upsert(priced);
            if (_last is not null && string.Equals(_last.Key, priced.Key, StringComparison.Ordinal))
            {
                _last = priced;
            }
        }
    }

    private static LiveCost PerSecond(LiveCost value, double seconds) =>
        new(value.MicroUsdPerSecond / seconds, value.KnownOutput / seconds);

    private void RollDay(long todayStartMs)
    {
        _today.Reset(todayStartMs);
        foreach (var stored in _responses.Values)
        {
            if (stored.Response.EndMs >= todayStartMs)
            {
                _today.Upsert(stored.Response);
            }
        }

        _liveMaxOutput = 0;
        _liveMaxTotal = 0;
        _liveMaxOutputAtMs = null;
        _previousPeakOutput = null;
    }

    private void Evict(long cutoffMs)
    {
        List<string>? expired = null;
        foreach (var (key, stored) in _responses)
        {
            if (stored.Response.EndMs < cutoffMs)
            {
                (expired ??= []).Add(key);
            }
        }

        if (expired is null)
        {
            return;
        }

        foreach (var key in expired)
        {
            _responses.Remove(key);
        }

        _reportLedger.Prune(cutoffMs);
        foreach (var agentId in _agentProviders.Keys.Where(id => !_agents.ContainsKey(id)).ToArray())
        {
            _agentProviders.Remove(agentId);
        }
    }

    private static Dictionary<string, SpeedPair> RecentSpeeds(List<Stored> validNewestFirst, long nowMs)
    {
        var sums = new Dictionary<string, ReferenceSums>(StringComparer.Ordinal);
        var cutoff = nowMs - RecentWindowMs;
        foreach (var stored in validNewestFirst)
        {
            if (stored.Response.EndMs < cutoff)
            {
                break;
            }

            sums.TryGetValue(stored.Response.AgentId, out var sum);
            if (sum.Count >= RecentCount)
            {
                continue;
            }

            sums[stored.Response.AgentId] = sum.Add(stored);
        }

        var result = new Dictionary<string, SpeedPair>(sums.Count, StringComparer.Ordinal);
        foreach (var (agentId, sum) in sums)
        {
            if (sum.Estimate() is { } estimate)
            {
                result[agentId] = estimate;
            }
        }

        return result;
    }

    private static SpeedPair? Fallback(List<Stored> validNewestFirst, long nowMs, in AgentInfo agent)
    {
        var cutoff = nowMs - FallbackWindowMs;
        if (agent.Model is { } model)
        {
            var byModel = Sum(validNewestFirst, cutoff, r => string.Equals(r.Model, model, StringComparison.Ordinal));
            if (byModel is not null)
            {
                return byModel;
            }
        }

        var source = agent.Source;
        return Sum(validNewestFirst, cutoff, r => r.Source == source);

        static SpeedPair? Sum(List<Stored> responses, long cutoffMs, Func<ParsedResponse, bool> match)
        {
            var sum = default(ReferenceSums);
            foreach (var stored in responses)
            {
                if (stored.Response.EndMs < cutoffMs)
                {
                    break;
                }

                if (!match(stored.Response))
                {
                    continue;
                }

                sum = sum.Add(stored);
                if (sum.Count >= FallbackCount)
                {
                    break;
                }
            }

            return sum.Count > 0 ? sum.Estimate() : null;
        }
    }

    private List<AgentFrame> BuildAgents(
        long nowMs,
        Accumulator measured,
        Accumulator estimated,
        CostAccumulator costs,
        Dictionary<string, SpeedPair> recent,
        double seconds,
        out int generating,
        out int tools)
    {
        var list = AgentList.Build(_agents, nowMs, (agent, phase) =>
        {
            measured.AgentTotals.TryGetValue(agent.Id, out var m);
            estimated.AgentTotals.TryGetValue(agent.Id, out var e);
            var live = new Rate((m.Output + e.Output) / seconds, (m.Total + e.Total) / seconds);
            double? recentSpeed = recent.TryGetValue(agent.Id, out var own) ? own.Output : null;
            return new AgentFrame(agent, phase, live, recentSpeed)
            {
                LiveCost = costs.Agent.TryGetValue(agent.Id, out var cost) ? PerSecond(cost, seconds) : LiveCost.Zero,
            };
        });

        generating = list.Count(a => a.Phase == AgentPhase.Generating);
        tools = list.Count(a => a.Phase == AgentPhase.Tools);
        return list;
    }

    private static List<HistoryPoint> BuildHistory(
        long nowMs, List<Stored> measured, List<(long StartMs, long EndMs, SpeedPair Speed)> estimates)
    {
        var lastSecond = SpeedMath.FloorDiv(nowMs, 1000);
        var firstSecond = lastSecond - HistorySeconds + 1;
        var measuredOutput = new double[HistorySeconds];
        var measuredTotal = new double[HistorySeconds];
        var estimatedOutput = new double[HistorySeconds];
        var estimatedTotal = new double[HistorySeconds];

        foreach (var stored in measured)
        {
            var interval = stored.Interval;
            var duration = (double)interval.DurationMs;
            var from = Math.Max(firstSecond, SpeedMath.FloorDiv(interval.StartMs, 1000));
            var to = Math.Min(lastSecond, SpeedMath.FloorDiv(interval.EndMs, 1000));
            for (var second = from; second <= to; second++)
            {
                var overlap = SpeedMath.Overlap(interval.StartMs, interval.EndMs, second * 1000, second * 1000 + 1000);
                if (overlap <= 0)
                {
                    continue;
                }

                var index = (int)(second - firstSecond);
                measuredOutput[index] += stored.Response.Tokens.Output * overlap / duration;
                measuredTotal[index] += stored.Response.Tokens.Total * overlap / duration;
            }
        }

        foreach (var (start, end, speed) in estimates)
        {
            var from = Math.Max(firstSecond, SpeedMath.FloorDiv(start, 1000));
            var to = Math.Min(lastSecond, SpeedMath.FloorDiv(end, 1000));
            for (var second = from; second <= to; second++)
            {
                var overlap = SpeedMath.Overlap(start, end, second * 1000, second * 1000 + 1000);
                if (overlap <= 0)
                {
                    continue;
                }

                var index = (int)(second - firstSecond);
                estimatedOutput[index] += speed.Output * overlap / 1000.0;
                estimatedTotal[index] += speed.Total * overlap / 1000.0;
            }
        }

        var points = new List<HistoryPoint>(HistorySeconds);
        for (var i = 0; i < HistorySeconds; i++)
        {
            points.Add(new HistoryPoint(
                DateTimeOffset.FromUnixTimeMilliseconds((firstSecond + i) * 1000),
                new Rate(measuredOutput[i], measuredTotal[i]),
                new Rate(estimatedOutput[i], estimatedTotal[i])));
        }

        return points;
    }

    private List<SpeedEvent> DrainCompletions(long nowMs)
    {
        var events = new List<SpeedEvent>();
        _completions.RemoveAll(r => r.EndMs < nowMs - CompletionEventWindowMs);
        var skip = Math.Max(0, _completions.Count - MaxEventsPerFrame);
        for (var i = skip; i < _completions.Count; i++)
        {
            events.Add(new SpeedEvent.ResponseCompleted(Summarize(_completions[i])));
        }

        _completions.Clear();
        return events;
    }

    private (Rate Rate, long? AtMs) UpdatePeak(long nowMs, Rate live, bool observeLive, List<SpeedEvent> events)
    {
        var (bucketOutput, bucketAt, bucketTotal) = _today.Peak();
        _previousPeakOutput ??= Math.Max(bucketOutput, _liveMaxOutput);
        if (observeLive)
        {
            if (live.Output >= PeakMinimum
                && live.Output - _previousPeakOutput.Value >= PeakMargin
                && (_lastPeakEventMs is not { } lastEvent || nowMs - lastEvent >= PeakCooldownMs))
            {
                events.Add(new SpeedEvent.NewPeak(live.Output));
                _lastPeakEventMs = nowMs;
            }

            if (live.Output > _liveMaxOutput)
            {
                _liveMaxOutput = live.Output;
                _liveMaxOutputAtMs = nowMs;
            }

            _liveMaxTotal = Math.Max(_liveMaxTotal, live.Total);
        }

        var output = Math.Max(bucketOutput, _liveMaxOutput);
        long? at = output <= 0 ? null : _liveMaxOutput > bucketOutput ? _liveMaxOutputAtMs : bucketAt;
        _previousPeakOutput = output;
        return (new Rate(output, Math.Max(bucketTotal, _liveMaxTotal)), at);
    }

    private ResponseSummary Summarize(ParsedResponse response)
    {
        var project = _agents.TryGetValue(response.AgentId, out var agent) ? agent.Project ?? string.Empty : string.Empty;
        TimeSpan? duration = null;
        double? speed = null;
        if (SpeedMath.TryGetSpeedInterval(response, out var interval))
        {
            duration = TimeSpan.FromMilliseconds(interval.DurationMs);
            speed = response.Final ? response.Tokens.Output / (interval.DurationMs / 1000.0) : null;
        }
        else if (response.StartMs is { } start && response.EndMs >= start)
        {
            duration = TimeSpan.FromMilliseconds(response.EndMs - start);
        }

        return new ResponseSummary(
            response.Source,
            project,
            response.Model,
            response.Tokens.Output,
            response.Tokens.Total,
            duration,
            speed,
            UnixTime.FromMs(response.EndMs));
    }

    /// <param name="CostRate">micro-USD per second of the same reference responses (METRICS 9.5); null when none has a known cost.</param>
    private readonly record struct SpeedPair(double Output, double Total, double? CostRate = null);

    /// <summary>Sums over a reference set (METRICS 6.2) and the cost of its priced members (9.5).</summary>
    private readonly record struct ReferenceSums(
        int Count, double Output, double Total, double Seconds, long CostMicroUsd, double CostSeconds, bool HasCost)
    {
        public ReferenceSums Add(Stored stored)
        {
            var seconds = stored.Interval.DurationMs / 1000.0;
            var cost = stored.Response.CostMicroUsd;
            return new ReferenceSums(
                Count + 1,
                Output + stored.Response.Tokens.Output,
                Total + stored.Response.Tokens.Total,
                Seconds + seconds,
                CostMicroUsd + (cost ?? 0),
                CostSeconds + (cost is null ? 0 : seconds),
                HasCost || cost is not null);
        }

        public SpeedPair? Estimate() => Seconds > 0
            ? new SpeedPair(Output / Seconds, Total / Seconds, HasCost && CostSeconds > 0 ? CostMicroUsd / CostSeconds : null)
            : null;
    }

    private sealed class CostAccumulator(int sourceCount)
    {
        public LiveCost[] Source { get; } = new LiveCost[sourceCount];

        public Dictionary<string, LiveCost> Agent { get; } = new(StringComparer.Ordinal);

        public void Add(SourceKind source, string agentId, LiveCost cost)
        {
            Source[(int)source] += cost;
            Agent[agentId] = Agent.GetValueOrDefault(agentId) + cost;
        }
    }

    private sealed class Stored
    {
        public Stored(ParsedResponse response)
        {
            Response = response;
            Valid = SpeedMath.TryGetSpeedInterval(response, out var interval);
            Interval = interval;
        }

        public ParsedResponse Response { get; }

        public bool Valid { get; }

        public Interval Interval { get; }
    }

    private sealed class Accumulator(int sourceCount)
    {
        public double Output { get; private set; }

        public double Total { get; private set; }

        public double[] SourceOutput { get; } = new double[sourceCount];

        public double[] SourceTotal { get; } = new double[sourceCount];

        public Dictionary<string, (double Output, double Total)> AgentTotals { get; } = new(StringComparer.Ordinal);

        public void Add(SourceKind source, string agentId, double output, double total)
        {
            if (output == 0 && total == 0)
            {
                return;
            }

            Output += output;
            Total += total;
            SourceOutput[(int)source] += output;
            SourceTotal[(int)source] += total;
            AgentTotals.TryGetValue(agentId, out var sum);
            AgentTotals[agentId] = (sum.Output + output, sum.Total + total);
        }
    }
}
