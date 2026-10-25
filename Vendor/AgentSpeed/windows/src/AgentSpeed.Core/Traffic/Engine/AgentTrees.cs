namespace AgentSpeed.Core.Traffic.Engine;

/// <summary>One agent of the 6.7 list as traffic attribution sees it (METRICS 10.6).</summary>
/// <param name="Transcript">The transcript (or database) a process may hold open; null when the id is not a path.</param>
/// <param name="Intervals">Fixtures: recorded <c>[from, to]</c> intervals in which the agent was generating, running tools or writing lines.</param>
/// <param name="Working">Live list: the phase after the staleness rule is generating or tools.</param>
/// <param name="LastLineMs">Live list: the last line time.</param>
internal sealed record TrafficAgent(
    string Id,
    SourceKind Source,
    string? ParentId,
    string? CwdPath,
    string? Transcript,
    IReadOnlyList<(long From, long To)>? Intervals = null,
    bool Working = false,
    long? LastLineMs = null)
{
    /// <summary>Active during <c>[startMs, endMs]</c>: working, or a line at or after <c>startMs − 2000</c>.</summary>
    public bool IsActive(long startMs, long endMs)
    {
        if (Intervals is { } intervals)
        {
            foreach (var (from, to) in intervals)
            {
                if (from <= endMs && to >= startMs - 2000)
                {
                    return true;
                }
            }

            return false;
        }

        return Working || LastLineMs is { } last && last >= startMs - 2000;
    }

    /// <summary>The traffic view of one 6.7 row: its transcript when the id is a path (OpenCode ids are not).</summary>
    public static TrafficAgent From(AgentStatus status)
    {
        var lastLineMs = status.LastActivity.ToUnixTimeMilliseconds();
        var transcript = Path.IsPathFullyQualified(status.Id) ? status.Id : null;
        return new TrafficAgent(status.Id, status.Source, status.ParentId, null, transcript,
            Working: status.Phase != AgentPhase.Idle, LastLineMs: lastLineMs > 0 ? lastLineMs : null);
    }
}

/// <summary>The agent trees of the 6.7 list (roots with their sub-agents) and the candidate rule of METRICS 10.6.</summary>
internal sealed class AgentTrees
{
    private Dictionary<string, TrafficAgent> _agents = new(StringComparer.Ordinal);
    private Dictionary<string, string> _rootOf = new(StringComparer.Ordinal);
    private Dictionary<string, List<TrafficAgent>> _membersOf = new(StringComparer.Ordinal);
    private Dictionary<SourceKind, string[]> _rootsBySource = new();
    private readonly List<string> _candidates = new();

    /// <summary>Every tree's root id, sorted.</summary>
    public IReadOnlyList<string> Roots { get; private set; } = [];

    public IReadOnlyDictionary<string, TrafficAgent> Agents => _agents;

    public void Replace(IEnumerable<TrafficAgent> list)
    {
        var agents = new Dictionary<string, TrafficAgent>(StringComparer.Ordinal);
        foreach (var agent in list)
        {
            agents[agent.Id] = agent;
        }

        _agents = agents;
        _rootOf = new Dictionary<string, string>(StringComparer.Ordinal);
        _membersOf = new Dictionary<string, List<TrafficAgent>>(StringComparer.Ordinal);
        foreach (var agent in agents.Values)
        {
            var root = ResolveRoot(agent.Id);
            _rootOf[agent.Id] = root;
            if (!_membersOf.TryGetValue(root, out var members))
            {
                members = new List<TrafficAgent>();
                _membersOf[root] = members;
            }

            members.Add(agent);
        }

        _rootsBySource = agents.Values
            .GroupBy(a => a.Source)
            .ToDictionary(g => g.Key, g => g.Select(a => _rootOf[a.Id]).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray());
        Roots = [.. _rootOf.Values.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal)];
    }

    public string? RootOf(string id) => _rootOf.GetValueOrDefault(id);

    private string ResolveRoot(string id)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var current = id;
        while (_agents.TryGetValue(current, out var agent) && agent.ParentId is { } parent && _agents.ContainsKey(parent) && seen.Add(current))
        {
            current = parent;
        }

        return current;
    }

    public bool IsTreeActive(string root, long startMs, long endMs) =>
        _membersOf.TryGetValue(root, out var members) && members.Exists(m => m.IsActive(startMs, endMs));

    /// <summary>Some agent was active during <c>[startMs, endMs]</c> (METRICS 10.10 cadence).</summary>
    public bool AnyActive(long startMs, long endMs) => _agents.Values.Any(a => a.IsActive(startMs, endMs));

    /// <summary>
    /// The candidate trees of <paramref name="source"/> for one root process (METRICS 10.6 steps 1–3; each step only applies
    /// when it leaves at least one). Open files and the working directory are only asked when more than one candidate is active.
    /// The returned list is reused by the next call.
    /// </summary>
    public IReadOnlyList<string> Candidates(SourceKind source, long startMs, long endMs, TrafficPlatform platform,
        Func<HashSet<string>> openFiles, Func<string?> workingDirectory)
    {
        _candidates.Clear();
        if (!_rootsBySource.TryGetValue(source, out var roots))
        {
            return _candidates;
        }

        foreach (var root in roots)
        {
            if (IsTreeActive(root, startMs, endMs))
            {
                _candidates.Add(root);
            }
        }

        if (_candidates.Count <= 1)
        {
            return _candidates;
        }

        var open = openFiles();
        if (open.Count > 0)
        {
            var owned = _candidates.Where(root => _membersOf[root].Exists(a => a.Transcript is { } t && open.Contains(platform.Normalize(t)))).ToArray();
            if (owned.Length > 0)
            {
                _candidates.Clear();
                _candidates.AddRange(owned);
            }
        }

        if (_candidates.Count > 1 && workingDirectory() is { Length: > 0 } directory)
        {
            var wanted = platform.Normalize(directory);
            var same = _candidates.Where(root => _agents.TryGetValue(root, out var a) && a.CwdPath is { } cwd && platform.Normalize(cwd) == wanted).ToArray();
            if (same.Length > 0)
            {
                _candidates.Clear();
                _candidates.AddRange(same);
            }
        }

        return _candidates;
    }
}
