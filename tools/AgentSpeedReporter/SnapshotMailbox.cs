using System.Threading.Channels;
using AgentSpeed.Core;

namespace CodexTokenBar.AgentSpeedReporter;

/// <summary>
/// One-slot latest-snapshot mailbox. Reads coalesce only snapshots not yet consumed, preserving the earliest source
/// read observation for the latest cumulative snapshot that replaces them.
/// </summary>
internal sealed class SnapshotMailbox : ChannelReader<SpeedSnapshot>
{
    private sealed record PendingSnapshot(SpeedSnapshot Snapshot, SourceReadObservation? Observation);

    private readonly object _gate = new();
    private readonly SemaphoreSlim _available = new(0, 1);
    private PendingSnapshot? _pending;

    public void Publish(SpeedSnapshot snapshot)
    {
        lock (_gate)
        {
            var wasEmpty = _pending is null;
            var observation = SourceReadObservation.MergeEarliest(_pending?.Observation, snapshot.SourceReadObservation);
            _pending = new PendingSnapshot(snapshot, observation);
            if (wasEmpty)
            {
                _available.Release();
            }
        }
    }

    public override bool TryRead(out SpeedSnapshot item)
    {
        if (!_available.Wait(0))
        {
            item = null!;
            return false;
        }

        lock (_gate)
        {
            if (_pending is not { } pending)
            {
                item = null!;
                return false;
            }

            _pending = null;
            item = pending.Snapshot with { SourceReadObservation = pending.Observation };
            return true;
        }
    }

    public override ValueTask<bool> WaitToReadAsync(CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            if (_pending is not null)
            {
                return ValueTask.FromResult(true);
            }
        }

        return WaitForPendingAsync(cancellationToken);
    }

    private async ValueTask<bool> WaitForPendingAsync(CancellationToken cancellationToken)
    {
        await _available.WaitAsync(cancellationToken).ConfigureAwait(false);
        _available.Release();
        return true;
    }
}
