namespace AgentSpeed.Core.Reporting;

public enum ReportMode
{
    Active,
    Idle,
    Quiet,
}

public enum ReportActivity
{
    Active,
    Idle,
    Leaving,
}

/// <summary>User events of a tick (METRICS 11.5 step 1). <see cref="Stop"/> turns reporting off or quits: like a pause, it sends a leaving report.</summary>
public enum ReportEvent
{
    Pause,
    Resume,
    NetworkOff,
    NetworkOn,
    Stop,
}

/// <param name="Single">The leaving report of a user action: one attempt, no retry.</param>
public readonly record struct ReportTicket(int Seq, ReportActivity Activity, long BuiltAt, long WindowMs, bool Single);

/// <summary>The outcome of one attempt (METRICS 11.5, Deliver).</summary>
public abstract record ReportAttemptOutcome
{
    private ReportAttemptOutcome()
    {
    }

    /// <summary><c>2xx</c>, adopting the <c>intervalSeconds</c> of the response when present.</summary>
    public sealed record Delivered(int? IntervalSeconds) : ReportAttemptOutcome;

    /// <summary>A network error, a timeout, <c>3xx</c>, or <c>5xx</c> without <c>Retry-After</c>: retried once.</summary>
    public sealed record Transient : ReportAttemptOutcome;

    /// <summary><c>429</c>, or <c>503</c> with <c>Retry-After</c> (already clamped to 5 s – 1 h).</summary>
    public sealed record RateLimited(int Seconds) : ReportAttemptOutcome;

    /// <summary><c>nonce_replayed</c>, or <c>signature_invalid</c> with a pending key: attempted again at once, once.</summary>
    public sealed record Again : ReportAttemptOutcome;

    /// <summary>Any other error: lost (the owner applies the reaction of REPORTING 8.3).</summary>
    public sealed record Rejected : ReportAttemptOutcome;
}

/// <summary>What the scheduler asks its owner to do.</summary>
public abstract record ReportAction
{
    private ReportAction()
    {
    }

    /// <summary>Empty the window without a report; <see cref="KeepingTick"/> for the gap rule (METRICS 11.1).</summary>
    public sealed record Discard(bool KeepingTick) : ReportAction;

    /// <summary>Take the window and the instantaneous values into a report body.</summary>
    public sealed record Build(ReportTicket Ticket) : ReportAction;

    /// <summary>Sign and send the ticket's body (a fresh timestamp and nonce).</summary>
    public sealed record Send(ReportTicket Ticket) : ReportAction;

    public sealed record Delivered(ReportTicket Ticket) : ReportAction;

    public sealed record Lost(ReportTicket Ticket) : ReportAction;
}

/// <summary>
/// The report scheduler of METRICS 11.5 on a monotonic millisecond clock. It decides when a window is discarded, when a
/// report is built and when an attempt is sent; the owner builds the bodies, performs the requests and reports each
/// outcome back with <see cref="Finish"/>. At most one request is in flight and the outbox holds one report.
/// </summary>
public sealed class ReportScheduler
{
    public const long HoldMs = 15_000;
    public const long QuietMs = 600_000;
    public const long GapMs = 15_000;
    public const long RetryMs = 2_000;
    public const long MaxBackoffMs = 300_000;

    private readonly Func<double> _jitter;
    private long _limitsIntervalMs;
    private long _limitsHeartbeatMs;
    private long? _adoptedIntervalMs;
    private long? _lastActive;
    private long? _previousTick;
    private bool _blocked;
    private Slot? _inflight;
    private ReportTicket? _waiting;

    /// <param name="jitter">The random backoff factor in [0.8, 1.2]; the fixtures use 1.</param>
    public ReportScheduler(ReportLimits limits, bool paused = false, bool networkOff = false, Func<double>? jitter = null)
    {
        Update(limits);
        Paused = paused;
        NetworkOff = networkOff;
        _jitter = jitter ?? (() => 0.8 + Random.Shared.NextDouble() * 0.4);
    }

    /// <summary><c>I</c>: the discovery interval, or the <c>intervalSeconds</c> of the latest success (until the next launch).</summary>
    public long IntervalMs => _adoptedIntervalMs ?? _limitsIntervalMs;

    /// <summary><c>H</c>, never below <c>I</c>.</summary>
    public long HeartbeatMs => Math.Max(_limitsHeartbeatMs, IntervalMs);

    public long MaxAgeMs { get; private set; }

    public int Seq { get; private set; }

    public long? WindowStart { get; private set; }

    public ReportMode Mode { get; private set; } = ReportMode.Quiet;

    public int Failures { get; private set; }

    public bool Paused { get; private set; }

    public bool NetworkOff { get; private set; }

    public bool Stopped { get; private set; }

    /// <summary>Nothing is sent before this (backoff).</summary>
    public long BackoffUntil { get; private set; } = long.MinValue;

    /// <summary>Nothing is sent before this (<c>Retry-After</c>).</summary>
    public long RateLimitedUntil { get; private set; } = long.MinValue;

    /// <summary>True while a request is in flight or a report waits for it.</summary>
    public bool IsBusy => _inflight is not null || _waiting is not null;

    /// <summary>The moment the next report is due in the current mode (the preview's countdown); null while quiet.</summary>
    public long? NextDueAt => WindowStart is { } start && Mode != ReportMode.Quiet
        ? start + (Mode == ReportMode.Active ? IntervalMs : HeartbeatMs)
        : null;

    /// <summary>New limits from a refreshed discovery document; a success's <c>intervalSeconds</c> still applies on top.</summary>
    public void Update(ReportLimits limits)
    {
        _limitsIntervalMs = limits.IntervalSeconds * 1000L;
        _limitsHeartbeatMs = limits.HeartbeatSeconds * 1000L;
        MaxAgeMs = limits.MaxAgeSeconds * 1000L;
    }

    /// <summary>A new run (METRICS 11.5, Run): <c>seq</c> restarts and the outbox is emptied; backoff and pauses stay.</summary>
    public List<ReportAction> StartRun()
    {
        var actions = new List<ReportAction>();
        DropOutbox(actions);
        Seq = 0;
        WindowStart = null;
        _lastActive = null;
        Mode = ReportMode.Quiet;
        Stopped = false;
        return actions;
    }

    /// <summary>
    /// One engine tick at <paramref name="t"/>. <paramref name="active"/> is the activity rule of METRICS 11.5;
    /// <paramref name="blocked"/> covers the readiness the scheduler does not track (on, confirmed, registered, no error that needs the user).
    /// </summary>
    public List<ReportAction> Tick(long t, bool active, bool blocked, IReadOnlyList<ReportEvent>? events = null)
    {
        var actions = new List<ReportAction>();
        var leaving = false;
        _blocked = blocked;
        foreach (var e in events ?? [])
        {
            switch (e)
            {
                case ReportEvent.Pause:
                    leaving |= !Paused && !Stopped;
                    Paused = true;
                    break;
                case ReportEvent.Resume:
                    Paused = false;
                    break;
                case ReportEvent.NetworkOff:
                    NetworkOff = true;
                    DropOutbox(actions);
                    break;
                case ReportEvent.NetworkOn:
                    NetworkOff = false;
                    break;
                case ReportEvent.Stop:
                    leaving |= !Paused && !Stopped;
                    Stopped = true;
                    break;
            }
        }

        if (_previousTick is { } previousTick && t - previousTick > GapMs)
        {
            WindowStart = t;
            actions.Add(new ReportAction.Discard(KeepingTick: true));
        }

        WindowStart ??= t;
        if (active)
        {
            _lastActive = t;
        }

        var since = _lastActive is { } last ? t - last : (long?)null;
        var current = since is { } s && s < HoldMs ? ReportMode.Active : since is { } q && q < QuietMs ? ReportMode.Idle : ReportMode.Quiet;
        var previous = Mode;
        Mode = current;
        _previousTick = t;

        if (leaving && previous != ReportMode.Quiet && !NetworkOff && !blocked && t >= RateLimitedUntil)
        {
            if (_inflight is { Sending: false } slot)
            {
                Fail(slot.Ticket, t, actions);
                _inflight = null;
            }

            if (_waiting is { } waiting)
            {
                actions.Add(new ReportAction.Lost(waiting));
                _waiting = null;
            }

            var ticket = BuildTicket(t, ReportActivity.Leaving, single: true, actions);
            if (_inflight is null)
            {
                Send(new Slot(ticket, t), actions);
            }
            else
            {
                _waiting = ticket;
            }
        }

        if (Paused || NetworkOff || blocked || Stopped || t < BackoffUntil || t < RateLimitedUntil)
        {
            WindowStart = t;
            actions.Add(new ReportAction.Discard(KeepingTick: false));
            return actions;
        }

        if (current == ReportMode.Quiet)
        {
            if (previous is ReportMode.Active or ReportMode.Idle)
            {
                var ticket = BuildTicket(t, ReportActivity.Leaving, single: false, actions);
                if (_waiting is { } replaced)
                {
                    actions.Add(new ReportAction.Lost(replaced));
                }

                _waiting = ticket;
            }
            else
            {
                WindowStart = t;
                actions.Add(new ReportAction.Discard(KeepingTick: false));
            }
        }
        else if (WindowStart is { } start && t - start >= (current == ReportMode.Active ? IntervalMs : HeartbeatMs))
        {
            var ticket = BuildTicket(t, current == ReportMode.Active ? ReportActivity.Active : ReportActivity.Idle, single: false, actions);
            if (_inflight is { Sending: false } retrying && retrying.NextAt > t)
            {
                Fail(retrying.Ticket, t, actions);
                _inflight = null;
            }

            if (_waiting is { } replaced)
            {
                actions.Add(new ReportAction.Lost(replaced));
            }

            _waiting = ticket;
        }

        Deliver(t, actions);
        return actions;
    }

    /// <summary>The outcome of the attempt of <paramref name="ticket"/> that a <see cref="ReportAction.Send"/> asked for.</summary>
    public List<ReportAction> Finish(ReportTicket ticket, ReportAttemptOutcome outcome, long t)
    {
        var actions = new List<ReportAction>();
        if (_inflight is not { } slot || slot.Ticket != ticket || !slot.Sending)
        {
            return actions;
        }

        slot = slot with { Sending = false, Attempts = slot.Attempts + 1 };
        _inflight = null;
        switch (outcome)
        {
            case ReportAttemptOutcome.Delivered delivered:
                actions.Add(new ReportAction.Delivered(ticket));
                Failures = 0;
                if (delivered.IntervalSeconds is { } seconds)
                {
                    _adoptedIntervalMs = Math.Clamp(seconds, 5, 300) * 1000L;
                }

                break;
            case ReportAttemptOutcome.RateLimited limited:
                actions.Add(new ReportAction.Lost(ticket));
                RateLimitedUntil = Math.Max(RateLimitedUntil, t + limited.Seconds * 1000L);
                break;
            case ReportAttemptOutcome.Again:
                if (slot.AgainUsed)
                {
                    Fail(ticket, t, actions);
                }
                else
                {
                    Send(slot with { AgainUsed = true, Attempts = slot.Attempts - 1 }, actions);
                    return actions;
                }

                break;
            case ReportAttemptOutcome.Transient:
                if (!ticket.Single && slot.Attempts < 2 && t + RetryMs - ticket.BuiltAt <= MaxAgeMs)
                {
                    _inflight = slot with { NextAt = t + RetryMs };
                }
                else
                {
                    Fail(ticket, t, actions);
                }

                break;
            default:
                Fail(ticket, t, actions);
                break;
        }

        if (_inflight is null && _waiting is not null && !NetworkOff && !_blocked && t >= BackoffUntil && t >= RateLimitedUntil)
        {
            Deliver(t, actions);
        }

        return actions;
    }

    private ReportTicket BuildTicket(long t, ReportActivity activity, bool single, List<ReportAction> actions)
    {
        Seq++;
        var ticket = new ReportTicket(Seq, activity, t, t - (WindowStart ?? t), single);
        WindowStart = t;
        actions.Add(new ReportAction.Build(ticket));
        return ticket;
    }

    private void Deliver(long t, List<ReportAction> actions)
    {
        if (_inflight is null && _waiting is { } waiting)
        {
            _inflight = new Slot(waiting, t);
            _waiting = null;
        }

        if (_inflight is not { Sending: false } slot || slot.NextAt > t)
        {
            return;
        }

        if (t - slot.Ticket.BuiltAt > MaxAgeMs)
        {
            Fail(slot.Ticket, t, actions);
            _inflight = null;
        }
        else
        {
            Send(slot, actions);
        }
    }

    private void Send(Slot slot, List<ReportAction> actions)
    {
        _inflight = slot with { Sending = true };
        actions.Add(new ReportAction.Send(slot.Ticket));
    }

    /// <summary>A lost report after a failure: counts towards the backoff (METRICS 11.5, Backoff).</summary>
    private void Fail(ReportTicket ticket, long t, List<ReportAction> actions)
    {
        actions.Add(new ReportAction.Lost(ticket));
        Failures++;
        if (Failures < 2)
        {
            return;
        }

        var baseMs = Math.Min(MaxBackoffMs, 5000L << Math.Min(Failures - 2, 20));
        BackoffUntil = Math.Max(BackoffUntil, t + (long)Math.Round(baseMs * _jitter()));
    }

    /// <summary>Network off: the waiting and the in-flight report are lost (an attempt already on the wire is abandoned).</summary>
    private void DropOutbox(List<ReportAction> actions)
    {
        if (_inflight is { } slot)
        {
            actions.Add(new ReportAction.Lost(slot.Ticket));
        }

        if (_waiting is { } waiting)
        {
            actions.Add(new ReportAction.Lost(waiting));
        }

        _inflight = null;
        _waiting = null;
    }

    private readonly record struct Slot(ReportTicket Ticket, long NextAt, int Attempts = 0, bool Sending = false, bool AgainUsed = false);
}
