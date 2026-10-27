namespace AgentSpeed.Core;

/// <summary>
/// Single hub the UI reads from. Live data and the effects preview both publish here. Every notification is
/// raised on the synchronization context captured at construction (the UI thread).
/// </summary>
public sealed class SpeedHub
{
    private readonly SynchronizationContext? _context;
    private readonly object _gate = new();
    private SpeedSnapshot _latestLive = SpeedSnapshot.Empty;

    public SpeedHub(SynchronizationContext? context = null)
    {
        _context = context ?? SynchronizationContext.Current;
    }

    public SpeedSnapshot Snapshot { get; private set; } = SpeedSnapshot.Empty;

    public bool IsPreviewing { get; private set; }

    public event EventHandler<SpeedSnapshot>? SnapshotChanged;

    public event EventHandler<SpeedEvent>? EventRaised;

    public event EventHandler? PreviewChanged;

    /// <summary>Every live snapshot, on the UI context, also while a preview is displayed (live reporting, METRICS 11).</summary>
    public event EventHandler<SpeedSnapshot>? LivePublished;

    /// <summary>Called by <see cref="LiveMonitor"/> from any thread.</summary>
    public void PublishLive(SpeedSnapshot snapshot, IReadOnlyList<SpeedEvent>? events = null)
    {
        lock (_gate)
        {
            _latestLive = snapshot;
        }

        Post(() =>
        {
            LivePublished?.Invoke(this, snapshot);
            if (IsPreviewing)
            {
                return;
            }

            Apply(snapshot, events);
        });
    }

    public void BeginPreview() => Post(() =>
    {
        IsPreviewing = true;
        PreviewChanged?.Invoke(this, EventArgs.Empty);
    });

    public void PublishPreview(SpeedSnapshot snapshot, IReadOnlyList<SpeedEvent>? events = null) => Post(() =>
    {
        if (IsPreviewing)
        {
            Apply(snapshot, events);
        }
    });

    public void EndPreview() => Post(() =>
    {
        if (!IsPreviewing)
        {
            return;
        }

        IsPreviewing = false;
        SpeedSnapshot live;
        lock (_gate)
        {
            live = _latestLive;
        }

        PreviewChanged?.Invoke(this, EventArgs.Empty);
        Apply(live, null);
    });

    private void Apply(SpeedSnapshot snapshot, IReadOnlyList<SpeedEvent>? events)
    {
        Snapshot = snapshot;
        SnapshotChanged?.Invoke(this, snapshot);
        if (events is null)
        {
            return;
        }

        foreach (var speedEvent in events)
        {
            EventRaised?.Invoke(this, speedEvent);
        }
    }

    private void Post(Action action)
    {
        if (_context is null || SynchronizationContext.Current == _context)
        {
            action();
        }
        else
        {
            _context.Post(static state => ((Action)state!)(), action);
        }
    }
}
