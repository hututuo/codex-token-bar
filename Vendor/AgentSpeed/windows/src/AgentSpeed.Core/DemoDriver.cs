namespace AgentSpeed.Core;

/// <summary>Drives <see cref="SpeedHub"/> with a scripted sweep through every tier to preview the effects.</summary>
public sealed class DemoDriver : IDisposable
{
    private const double EstimatedShare = 0.15;

    private static readonly (double At, double Value)[] Keys =
    [
        (0, 0), (0.08, 0), (0.2, 0.12), (0.35, 0.3), (0.5, 0.6), (0.68, 1.3), (0.86, 1.05), (0.97, 0), (1, 0),
    ];

    private static readonly FakeAgent[] Agents =
    [
        new("demo-rocket", SourceKind.Codex, "rocket", "gpt-6.1-sol", false, 0.34),
        new("demo-nova", SourceKind.ClaudeCode, "nova", "claude-opus-5-5", false, 0.3),
        new("demo-nova-sub", SourceKind.ClaudeCode, "nova", "claude-sonnet-5-5", true, 0.16),
        new("demo-halo", SourceKind.Antigravity, "halo", "gemini-3.1-pro", false, 0.22),
        new("demo-quasar", SourceKind.DeepSeek, "quasar", "deepseek-flash", false, 0.24),
        new("demo-meridian", SourceKind.Omp, "meridian", "claude-opus-5-5", false, 0.18),
        new("demo-orbit", SourceKind.ClaudeDesktop, "orbit", "claude-fable-5-1", false, 0.2),
        new("demo-lumen", SourceKind.WorkBuddy, "lumen", "glm-5.3", false, 0.16),
    ];

    private static readonly SourceKind[] Sources = Enum.GetValues<SourceKind>();

    private readonly SpeedHub _hub;
    private readonly object _gate = new();
    private readonly Random _random = new();
    private Timer? _timer;
    private DateTimeOffset _startedAt;
    private TimeSpan _duration;
    private double _redline = 400;
    private List<HistoryPoint> _history = [];
    private long _lastHistorySecond;
    private double _nextPulseAt;
    private double _peak;
    private bool _peakAnnounced;
    private TokenTotals _today;
    private ResponseSummary? _lastResponse;

    public DemoDriver(SpeedHub hub)
    {
        _hub = hub;
    }

    public bool IsRunning { get; private set; }

    public event EventHandler? Finished;

    public void Start(double redline, TimeSpan? duration = null)
    {
        Stop();
        lock (_gate)
        {
            _redline = Math.Max(redline, 1);
            _duration = duration ?? TimeSpan.FromSeconds(20);
            _startedAt = DateTimeOffset.UtcNow;
            _peak = 0;
            _peakAnnounced = false;
            _nextPulseAt = 1.6;
            _today = TokenTotals.Zero;
            _lastResponse = null;
            _lastHistorySecond = _startedAt.ToUnixTimeSeconds();
            _history = Enumerable.Range(0, 300)
                .Select(i => new HistoryPoint(
                    DateTimeOffset.FromUnixTimeSeconds(_lastHistorySecond - 300 + i), Rate.Zero, Rate.Zero))
                .ToList();
            IsRunning = true;
        }

        _hub.BeginPreview();
        _timer = new Timer(_ => Tick(), null, TimeSpan.Zero, TimeSpan.FromMilliseconds(50));
    }

    public void Stop()
    {
        _timer?.Dispose();
        _timer = null;
        lock (_gate)
        {
            if (!IsRunning)
            {
                return;
            }

            IsRunning = false;
        }

        _hub.EndPreview();
        Finished?.Invoke(this, EventArgs.Empty);
    }

    public void Dispose() => Stop();

    private void Tick()
    {
        SpeedSnapshot snapshot;
        List<SpeedEvent> events = [];
        lock (_gate)
        {
            if (!IsRunning)
            {
                return;
            }

            var now = DateTimeOffset.UtcNow;
            var t = (now - _startedAt).TotalSeconds;
            if (t >= _duration.TotalSeconds)
            {
                ThreadPool.QueueUserWorkItem(_ => Stop());
                return;
            }

            var speed = SpeedCurve(t);
            if (speed > _peak + 1)
            {
                _peak = speed;
            }

            if (!_peakAnnounced && t > _duration.TotalSeconds * 0.62 && speed >= _peak - 1 && speed > _redline)
            {
                _peakAnnounced = true;
                events.Add(new SpeedEvent.NewPeak(speed));
            }

            if (speed > 0.5 && t >= _nextPulseAt)
            {
                var agent = Agents[(int)(t * 7) % Agents.Length];
                var output = (long)Math.Max(40, speed * (1.4 + _random.NextDouble() * 1.8));
                var agentSpeed = speed * agent.Weight * 2;
                _lastResponse = new ResponseSummary(
                    agent.Source, agent.Project, agent.Model, output, output * 24,
                    TimeSpan.FromSeconds(output / Math.Max(agentSpeed, 1)), agentSpeed, now);
                _today = _today with
                {
                    Requests = _today.Requests + 1,
                    Output = _today.Output + output,
                    Input = _today.Input + output * 23,
                    CachedInput = _today.CachedInput + output * 20,
                };
                events.Add(new SpeedEvent.ResponseCompleted(_lastResponse));
                var heat = Math.Min(1, speed / _redline);
                _nextPulseAt = t + 1.2 - 0.95 * heat + _random.NextDouble() * 0.15;
            }

            var second = now.ToUnixTimeSeconds();
            while (_lastHistorySecond < second)
            {
                _lastHistorySecond++;
                _history.RemoveAt(0);
                _history.Add(new HistoryPoint(
                    DateTimeOffset.FromUnixTimeSeconds(_lastHistorySecond),
                    new Rate(speed * 0.85, speed * 0.85 * 24),
                    new Rate(speed * 0.15, speed * 0.15 * 24)));
            }

            snapshot = BuildSnapshot(now, speed);
        }

        _hub.PublishPreview(snapshot, events);
    }

    private double SpeedCurve(double t)
    {
        var p = t / _duration.TotalSeconds;
        var value = 0.0;
        for (var i = 1; i < Keys.Length; i++)
        {
            if (p > Keys[i].At)
            {
                continue;
            }

            var (p0, v0) = Keys[i - 1];
            var (p1, v1) = Keys[i];
            var x = (p - p0) / Math.Max(p1 - p0, 0.0001);
            value = v0 + (v1 - v0) * (x * x * (3 - 2 * x));
            break;
        }

        var wobble = 1 + 0.05 * Math.Sin(t * 7.3) + 0.03 * Math.Sin(t * 17.1);
        return Math.Max(0, value * _redline * wobble);
    }

    private SpeedSnapshot BuildSnapshot(DateTimeOffset now, double speed)
    {
        var generating = speed < 0.5 ? 0 : Math.Min(Agents.Length, 1 + (int)(speed / (_redline * 0.3)));
        var activeWeight = Math.Max(Agents.Take(generating).Sum(a => a.Weight), 0.0001);
        var agents = Agents.Select((agent, index) =>
        {
            var active = index < generating;
            var share = active ? speed * agent.Weight / activeWeight : 0;
            var phase = active ? AgentPhase.Generating : speed > 0.5 ? AgentPhase.Tools : AgentPhase.Idle;
            return new AgentStatus(agent.Id, agent.Source, agent.Project, agent.Model, phase, agent.IsSubagent,
                new Rate(share, share * 24), active ? share : null, now, agent.IsSubagent ? "demo-nova" : null);
        }).ToList();

        var n = Sources.Length;
        var sources = Sources.Select(kind =>
        {
            var live = agents.Where(a => a.Source == kind).Sum(a => a.Live.Output);
            return new SourceStatus(kind, true, string.Empty, true, 12, new Rate(live, live * 24),
                new TokenTotals(_today.Requests / n, _today.Input / n, _today.CachedInput / n, 0, _today.Output / n),
                agents.Count(a => a.Source == kind && a.Phase == AgentPhase.Generating),
                new Rate(live * EstimatedShare, live * 24 * EstimatedShare));
        }).ToList();

        return new SpeedSnapshot(
            now,
            MonitorState.Running,
            new Rate(speed, speed * 24),
            EstimatedShare,
            new Rate(_peak, _peak * 24),
            _peak > 0 ? now : null,
            _peak > 0 ? _peak * 0.4 : null,
            _today,
            sources,
            agents,
            generating,
            speed > 0.5 ? Agents.Length - generating : 0,
            _history.ToList(),
            _lastResponse,
            []);
    }

    private sealed record FakeAgent(
        string Id, SourceKind Source, string Project, string Model, bool IsSubagent, double Weight);
}
