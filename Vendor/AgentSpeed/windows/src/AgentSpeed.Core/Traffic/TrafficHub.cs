namespace AgentSpeed.Core.Traffic;

/// <summary>
/// The traffic hub the UI reads (METRICS 10): the live snapshot and the stored days. The monitor publishes from its
/// thread; notifications are raised on the synchronization context captured at construction, newest value wins.
/// </summary>
public sealed class TrafficHub
{
    private readonly SynchronizationContext? _context;
    private readonly object _gate = new();
    private TrafficSnapshot? _pendingSnapshot;
    private (IReadOnlyList<TrafficDay> Days, string? Since)? _pendingDays;
    private bool _scheduled;

    public TrafficHub(SynchronizationContext? context = null)
    {
        _context = context ?? SynchronizationContext.Current;
    }

    public TrafficSnapshot Snapshot { get; private set; } = TrafficSnapshot.Off;

    /// <summary>Stored days (METRICS 10.9) with today's unsaved part merged in, oldest first.</summary>
    public IReadOnlyList<TrafficDay> Days { get; private set; } = [];

    /// <summary>The first local date with a stored sample (<c>trafficSince</c>); null before any.</summary>
    public string? Since { get; private set; }

    public event EventHandler? SnapshotChanged;

    public event EventHandler? DaysChanged;

    public void Publish(TrafficSnapshot snapshot)
    {
        lock (_gate)
        {
            _pendingSnapshot = snapshot;
        }

        Schedule();
    }

    public void PublishDays(IReadOnlyList<TrafficDay> days, string? since)
    {
        lock (_gate)
        {
            _pendingDays = (days, since);
        }

        Schedule();
    }

    private void Schedule()
    {
        if (_context is null || SynchronizationContext.Current == _context)
        {
            Drain();
            return;
        }

        lock (_gate)
        {
            if (_scheduled)
            {
                return;
            }

            _scheduled = true;
        }

        _context.Post(static state => ((TrafficHub)state!).Drain(), this);
    }

    private void Drain()
    {
        TrafficSnapshot? snapshot;
        (IReadOnlyList<TrafficDay> Days, string? Since)? days;
        lock (_gate)
        {
            snapshot = _pendingSnapshot;
            days = _pendingDays;
            _pendingSnapshot = null;
            _pendingDays = null;
            _scheduled = false;
        }

        if (days is { } published)
        {
            Days = published.Days;
            Since = published.Since;
            DaysChanged?.Invoke(this, EventArgs.Empty);
        }

        if (snapshot is not null)
        {
            Snapshot = snapshot;
            SnapshotChanged?.Invoke(this, EventArgs.Empty);
        }
    }
}
