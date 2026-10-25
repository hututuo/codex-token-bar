using System.Diagnostics;

namespace AgentSpeed.Core;

public enum SourceReadMode
{
    Event,
    Log,
    Poll,
    Mixed,
    Unknown,
}

/// <summary>Read-boundary timing for fresh source data; never inferred from snapshot publication time.</summary>
public sealed record SourceReadObservation(
    SourceReadMode SourceMode,
    DateTimeOffset ObservedAt,
    long ObservedAtTimestamp,
    long? SourceResolutionMs)
{
    public static SourceReadObservation Capture(SourceReadMode mode, long? sourceResolutionMs)
    {
        var monotonic = Stopwatch.GetTimestamp();
        var wall = DateTimeOffset.UtcNow;
        return new SourceReadObservation(mode, wall, monotonic, sourceResolutionMs);
    }

    public long AgeMilliseconds(long nowTimestamp) =>
        Math.Max(0, (long)Stopwatch.GetElapsedTime(ObservedAtTimestamp, nowTimestamp).TotalMilliseconds);

    /// <summary>Combines a report window's observations, keeping its earliest actual read boundary.</summary>
    public static SourceReadObservation? MergeEarliest(
        SourceReadObservation? first,
        SourceReadObservation? next)
    {
        if (first is null)
        {
            return next;
        }

        if (next is null)
        {
            return first;
        }

        var earliest = first.ObservedAtTimestamp <= next.ObservedAtTimestamp ? first : next;
        var mode = first.SourceMode == next.SourceMode ? first.SourceMode : SourceReadMode.Mixed;
        long? resolution = first.SourceResolutionMs is { } left && next.SourceResolutionMs is { } right
            ? Math.Max(left, right)
            : null;
        return earliest with { SourceMode = mode, SourceResolutionMs = resolution };
    }
}
