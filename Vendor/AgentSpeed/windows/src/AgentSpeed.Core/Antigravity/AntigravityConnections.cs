using System.Diagnostics;

namespace AgentSpeed.Core.Antigravity;

/// <summary>
/// Keeps few conversation databases open (METRICS 5.4): a connection idle for 60 seconds is closed, and at most 16 stay
/// open, the least recently read closed first. A connection whose read is running is left alone and closed later.
/// Owned by the monitor thread.
/// </summary>
internal sealed class AntigravityConnections
{
    public const int MaxOpen = 16;

    public static readonly TimeSpan IdleTimeout = TimeSpan.FromSeconds(60);

    private readonly List<AntigravityTailer> _open = [];

    /// <summary>Records a finished read and closes the oldest connections over the cap.</summary>
    public void Touch(AntigravityTailer tailer)
    {
        _open.Remove(tailer);
        if (tailer.HasConnection)
        {
            _open.Add(tailer);
        }

        if (_open.Count <= MaxOpen)
        {
            return;
        }

        _open.Sort(static (a, b) => a.LastReadTimestamp.CompareTo(b.LastReadTimestamp));
        for (var i = 0; i < _open.Count && _open.Count > MaxOpen;)
        {
            if (_open[i].TryCloseConnection())
            {
                _open.RemoveAt(i);
            }
            else
            {
                i++;
            }
        }
    }

    /// <summary>Closes connections not read for <see cref="IdleTimeout"/>.</summary>
    public void CloseIdle()
    {
        var now = Stopwatch.GetTimestamp();
        for (var i = _open.Count - 1; i >= 0; i--)
        {
            var tailer = _open[i];
            if (!tailer.HasConnection)
            {
                _open.RemoveAt(i);
            }
            else if (Stopwatch.GetElapsedTime(tailer.LastReadTimestamp, now) >= IdleTimeout && tailer.TryCloseConnection())
            {
                _open.RemoveAt(i);
            }
        }
    }

    public void Forget(AntigravityTailer tailer) => _open.Remove(tailer);

    public void CloseAll()
    {
        foreach (var tailer in _open)
        {
            tailer.Dispose();
        }

        _open.Clear();
    }
}
