namespace AgentSpeed.Core.Traffic.Windows;

/// <summary>Client-side guard: never more than four requests in any one-second window (WINDOWS-SERVICE 4).</summary>
internal sealed class HelperRequestLimiter
{
    public const int MaxRequests = 4;
    public const long WindowMs = 1000;

    private readonly long[] _sent = new long[MaxRequests];
    private int _count;
    private int _next;

    /// <summary>Records a request at <paramref name="nowMs"/> when allowed; false when it would be the fifth in a second.</summary>
    public bool TryAcquire(long nowMs)
    {
        if (_count == MaxRequests && nowMs - _sent[_next] < WindowMs)
        {
            return false;
        }

        _sent[_next] = nowMs;
        _next = (_next + 1) % MaxRequests;
        _count = Math.Min(_count + 1, MaxRequests);
        return true;
    }
}
