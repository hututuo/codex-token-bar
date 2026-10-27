using AgentSpeed.Core.Antigravity;
using AgentSpeed.Core.Engine;
using AgentSpeed.Core.IO;
using AgentSpeed.Core.IO.Sqlite;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.ZCode;

internal sealed record ZCodeAgent(string Id, string SessionId, string? ParentSessionId, long CreatedMs,
    string? Project, string? Model, AgentPhase Phase, long? StartMs, long LastMs)
{
    public ExecutionModes Modes { get; init; } = ExecutionModes.Empty;
    public bool ModeContext { get; init; }
}

internal sealed class ZCodeUpdate
{
    public List<(ParsedResponse Response, bool Completion)> Responses { get; } = [];
    public List<ZCodeAgent> Agents { get; } = [];
    public List<string> Removed { get; } = [];
    public bool Changed => Responses.Count > 0 || Agents.Count > 0 || Removed.Count > 0;
}

internal sealed class ZCodeSource(string root, IDeduper deduper)
{
    private readonly Dictionary<string, ParsedResponse> _emitted = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ZCodeAgent> _agents = new(StringComparer.Ordinal);
    private AntigravityStamp? _stamp;
    private FileIdentity? _identity;
    private string? _lastPath;
    private long _sinceMs;
    private long? _lastReadMs;

    internal Func<long> ClockMs { get; set; } = static () => Environment.TickCount64;

    public string DatabasePath => ZCodeDatabase.DatabasePath(root);
    public string WatchDirectory => Path.GetDirectoryName(DatabasePath) ?? string.Empty;
    public bool Available => File.Exists(DatabasePath);
    public bool Unsupported { get; private set; }
    public bool Unreadable { get; private set; }
    public IEnumerable<ZCodeAgent> Agents => _agents.Values;

    public ZCodeUpdate Seed(long todayStartMs)
    {
        _sinceMs = Math.Max(0, todayStartMs - Monitoring.MonitorCore.BacklogWindowMs);
        var update = Refresh(force: true);
        _lastReadMs = null;
        return update;
    }

    public int ActiveSessionCount(long todayStartMs) => _agents.Values.Count(a => a.LastMs >= todayStartMs && a.ParentSessionId is null);

    public bool IsWatchedPath(string path) =>
        string.Equals(path, DatabasePath, PathComparison) || string.Equals(path, DatabasePath + "-wal", PathComparison);

    public ZCodeUpdate Refresh(bool force = false)
    {
        var update = new ZCodeUpdate();
        var path = DatabasePath;
        var stamp = AntigravityStamp.Of(path);
        var identity = ReadIdentity(path);
        var replaced = !string.Equals(path, _lastPath, PathComparison)
            || (_identity is { } knownIdentity && identity is { } currentIdentity && knownIdentity != currentIdentity);
        if (stamp is null || replaced)
        {
            update.Removed.AddRange(_agents.Keys);
            _agents.Clear();
            _stamp = null;
            _lastReadMs = null;
        }

        _lastPath = path;
        _identity = identity;
        if (stamp is null || (!force && stamp == _stamp))
        {
            return update;
        }

        var now = ClockMs();
        if (!force && _lastReadMs is { } previousRead && now - previousRead < 500)
        {
            return update;
        }

        _lastReadMs = now;
        try
        {
            using var database = ZCodeDatabase.Open(DatabasePath);
            var rows = database.Read(_sinceMs);
            foreach (var group in rows.GroupBy(r => r.SessionId))
            {
                var latest = group.MaxBy(r => r.StartedMs)!;
                var last = group.Max(r => Math.Max(r.UpdatedMs, r.CompletedMs ?? r.StartedMs ?? 0));
                var agent = new ZCodeAgent(latest.AgentId(DatabasePath), latest.SessionId, latest.ParentId, latest.CreatedMs,
                    latest.Directory is { } cwd ? PathText.Basename(cwd) : null, latest.Model,
                    latest.Status == "running" ? AgentPhase.Generating : AgentPhase.Idle,
                    latest.Status == "running" ? latest.StartedMs : null, last) { Modes = latest.Modes };
                if (!_agents.TryGetValue(agent.Id, out var known) || known != agent)
                {
                    _agents[agent.Id] = agent;
                    update.Agents.Add(agent);
                }

                foreach (var row in group)
                {
                    if (row.Response(DatabasePath) is not { } response || (_emitted.TryGetValue(response.Key, out var previous) && previous == response))
                    {
                        continue;
                    }

                    var completion = deduper.TryClaim(response.Key, response.AgentId, out var owner);
                    if (!completion && !string.Equals(owner, response.AgentId, StringComparison.Ordinal))
                    {
                        continue;
                    }

                    _emitted[response.Key] = response;
                    update.Responses.Add((response, completion));
                }
            }

            foreach (var candidate in database.ReadAgents(_sinceMs))
            {
                var agent = candidate;
                if (_agents.TryGetValue(agent.Id, out var known))
                {
                    if (agent.LastMs < known.LastMs)
                    {
                        continue;
                    }

                    agent = agent with { Model = agent.Model ?? known.Model, Modes = agent.ModeContext ? agent.Modes : agent.Modes.IsEmpty ? known.Modes : agent.Modes };
                    if (agent == known)
                    {
                        continue;
                    }
                }

                _agents[agent.Id] = agent;
                var previous = update.Agents.FindIndex(item => item.Id == agent.Id);
                if (previous >= 0)
                {
                    update.Agents[previous] = agent;
                }
                else
                {
                    update.Agents.Add(agent);
                }
            }

            Unsupported = false;
            Unreadable = false;
            _stamp = stamp;
        }
        catch (InvalidDataException)
        {
            Unsupported = true;
            _stamp = stamp;
        }
        catch (Exception error) when (error is SqliteException or IOException or UnauthorizedAccessException)
        {
            Unreadable = true;
        }

        return update;
    }

    private static FileIdentity? ReadIdentity(string path)
    {
        try
        {
            using var handle = TranscriptTailer.Open(path);
            return FileIdentity.From(handle);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return null;
        }
    }

    private static StringComparison PathComparison => OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
}
