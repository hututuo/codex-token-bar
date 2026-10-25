using AgentSpeed.Core.IO;
using AgentSpeed.Core.Monitoring;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.History;

/// <summary>A whole file read off-thread: lines extracted into a batch, to be applied to its parser in order.</summary>
internal sealed record PreparedFile(
    int Index,
    TranscriptParser Parser,
    ILineBatch? Batch,
    TailReadResult Result,
    bool Oversized,
    Exception? Error);

/// <summary>One file to read: its path, family, root (omp sub-agents depend on it) and size.</summary>
internal readonly record struct ReadJob(string Path, RootFamily Family, string Root, long Size);

/// <summary>
/// Reads whole transcripts on a few below-normal-priority worker threads, at most a bounded amount ahead of the
/// consumer, and hands them out strictly in job order (startup order decides key ownership, METRICS 5).
/// </summary>
internal sealed class OrderedFileReader : IDisposable
{
    private readonly IReadOnlyList<ReadJob> _jobs;
    private readonly IDeduper _deduper;
    private readonly PreparedFile?[] _done;
    private readonly long _maxBufferedBytes;
    private readonly int _maxAhead;
    private readonly object _gate = new();
    private readonly CancellationTokenSource _stop;
    private readonly List<Thread> _workers = [];
    private int _nextJob;
    private int _nextOut;
    private long _bufferedBytes;

    public OrderedFileReader(
        IReadOnlyList<ReadJob> jobs,
        IDeduper deduper,
        int workers,
        long maxBufferedBytes,
        CancellationToken cancellationToken)
    {
        _jobs = jobs;
        _deduper = deduper;
        _done = new PreparedFile?[jobs.Count];
        _maxBufferedBytes = maxBufferedBytes;
        _maxAhead = Math.Max(2, workers * 2);
        _stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var count = Math.Clamp(workers, 1, Math.Max(1, jobs.Count));
        for (var i = 0; i < count; i++)
        {
            var thread = new Thread(Work)
            {
                IsBackground = true,
                Name = "Agent Speed history reader",
                Priority = ThreadPriority.BelowNormal,
            };
            _workers.Add(thread);
            thread.Start();
        }
    }

    /// <summary>The next file in job order; null when every job was handed out or reading was cancelled.</summary>
    public PreparedFile? Next()
    {
        lock (_gate)
        {
            if (_nextOut >= _jobs.Count)
            {
                return null;
            }

            while (_done[_nextOut] is null)
            {
                if (_stop.IsCancellationRequested)
                {
                    return null;
                }

                Monitor.Wait(_gate, 200);
            }

            var prepared = _done[_nextOut]!;
            _done[_nextOut] = null;
            _bufferedBytes -= Weight(_jobs[_nextOut]);
            _nextOut++;
            Monitor.PulseAll(_gate);
            return prepared;
        }
    }

    public void Dispose()
    {
        _stop.Cancel();
        lock (_gate)
        {
            Monitor.PulseAll(_gate);
        }

        foreach (var worker in _workers)
        {
            worker.Join(TimeSpan.FromSeconds(10));
        }

        _stop.Dispose();
    }

    // Compressed rollouts decode to many times their size; one huge file must not stall the smaller ones.
    private long Weight(ReadJob job) => Math.Min(
        job.Path.EndsWith(".zst", StringComparison.OrdinalIgnoreCase) ? job.Size * 12 : job.Size,
        _maxBufferedBytes / 2);

    private void Work()
    {
        while (true)
        {
            int index;
            lock (_gate)
            {
                while (true)
                {
                    if (_stop.IsCancellationRequested || _nextJob >= _jobs.Count)
                    {
                        return;
                    }

                    var weight = Weight(_jobs[_nextJob]);
                    var withinWindow = _nextJob - _nextOut < _maxAhead;
                    var withinBudget = _bufferedBytes + weight <= _maxBufferedBytes || _nextJob == _nextOut;
                    if (withinWindow && withinBudget)
                    {
                        index = _nextJob++;
                        _bufferedBytes += weight;
                        break;
                    }

                    Monitor.Wait(_gate, 200);
                }
            }

            var prepared = Read(index);
            lock (_gate)
            {
                _done[index] = prepared;
                Monitor.PulseAll(_gate);
            }
        }
    }

    private PreparedFile Read(int index)
    {
        var (path, family, root, _) = _jobs[index];
        TranscriptParser? parser = null;
        TranscriptTailer? tailer = null;
        try
        {
            parser = Families.CreateParser(family, path, _deduper, root);
            tailer = Families.CreateTailer(family, path);
            tailer.StartAt(0);
            var batch = parser.NewBatch();
            var result = tailer.ReadAppended(batch, _stop.Token);
            return new PreparedFile(index, parser, batch, result, tailer is DocumentTailer { Oversized: true }, null);
        }
        catch (Exception e)
        {
            // Including out-of-memory on one huge file: that file counts as unreadable, the app keeps running.
            return new PreparedFile(index, parser ?? new ClaudeParser(path, _deduper), null, default, false, e);
        }
        finally
        {
            (tailer as IDisposable)?.Dispose();
        }
    }
}
