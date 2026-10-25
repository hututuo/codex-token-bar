namespace AgentSpeed.Core.Traffic.Engine;

/// <summary>
/// The app's table of the current user's processes with their sticky attribution (METRICS 10.5): the path is read once
/// per identity, arguments only when a rule needs them; a process is classified when first seen and keeps its class for
/// its lifetime; an exited process stays for <see cref="ExitedRetentionMs"/> so late counter rows still match.
/// </summary>
internal sealed class ProcessTable
{
    public const long ExitedRetentionMs = 10_000;

    internal sealed class Record
    {
        public required ProcessEntry Entry { get; init; }

        public required string Executable { get; init; }

        public bool ArgumentsRead { get; set; }

        public IReadOnlyList<string>? Arguments { get; set; }

        public bool WorkingDirectoryRead { get; set; }

        public string? WorkingDirectory { get; set; }

        public ProcessClass? Class { get; set; }

        public bool BundleRead { get; set; }

        public string? Bundle { get; set; }

        public bool Classified { get; set; }

        /// <summary>When the listing stopped containing it.</summary>
        public long? ExitedMs { get; set; }

        public bool Alive => ExitedMs is null;
    }

    private readonly long _exitedRetentionMs;
    private readonly Dictionary<ProcessIdentity, Record> _records = new();
    private HashSet<ProcessIdentity> _alive = new();
    private HashSet<ProcessIdentity> _present = new();
    private readonly List<ProcessIdentity> _exited = new();
    private readonly Dictionary<int, ProcessEntry> _current = new();
    private readonly List<ProcessEntry> _fresh = new();
    private readonly Dictionary<ProcessIdentity, HashSet<ProcessIdentity>> _members = new();

    public ProcessTable(TrafficPlatform platform, long exitedRetentionMs = ExitedRetentionMs, AgentProcessRules? rules = null)
    {
        Rules = rules ?? new AgentProcessRules(platform);
        _exitedRetentionMs = exitedRetentionMs;
    }

    public AgentProcessRules Rules { get; }

    public IReadOnlyDictionary<ProcessIdentity, Record> Records => _records;

    /// <summary>Agent and self members of each root.</summary>
    public IReadOnlyDictionary<ProcessIdentity, HashSet<ProcessIdentity>> Members => _members;

    public int AliveCount => _alive.Count;

    /// <summary>Some agent process (alive, or exited within the retention) is in the table (METRICS 10.10).</summary>
    public bool HasAgentProcess => _members.Count > 0;

    /// <summary>Replaces the listing; new identities are read and classified (parents first).</summary>
    public void Refresh(IReadOnlyList<ProcessEntry> entries, IProcessInspector inspector, long nowMs)
    {
        _present.Clear();
        _fresh.Clear();
        foreach (var entry in entries)
        {
            var identity = entry.Identity;
            _present.Add(identity);
            if (_alive.Contains(identity))
            {
                continue;
            }

            if (_records.TryGetValue(identity, out var known))
            {
                // Missing from one listing only (a failed read): alive again.
                known.ExitedMs = null;
            }
            else
            {
                _fresh.Add(entry);
            }
        }

        foreach (var identity in _alive)
        {
            if (!_present.Contains(identity) && _records.TryGetValue(identity, out var record))
            {
                record.ExitedMs = nowMs;
                _exited.Add(identity);
            }
        }

        (_alive, _present) = (_present, _alive);
        if (_fresh.Count > 0)
        {
            _current.Clear();
            foreach (var entry in entries)
            {
                _current[entry.Pid] = entry;
            }

            foreach (var entry in _fresh)
            {
                _records[entry.Identity] = new Record { Entry = entry, Executable = inspector.ExecutablePath(entry) ?? string.Empty };
            }

            _fresh.Sort((a, b) => a.Identity.CompareTo(b.Identity));
            foreach (var entry in _fresh)
            {
                Classify(entry, inspector);
            }
        }

        Prune(nowMs);
    }

    public Record? Find(ProcessIdentity identity) => _records.GetValueOrDefault(identity);

    public ProcessClass? ClassOf(ProcessIdentity identity) => _records.TryGetValue(identity, out var record) ? record.Class : null;

    /// <summary>The root process's working directory, read once per process.</summary>
    public string? WorkingDirectory(ProcessIdentity identity, IProcessInspector inspector)
    {
        if (!_records.TryGetValue(identity, out var record))
        {
            return null;
        }

        if (!record.WorkingDirectoryRead)
        {
            record.WorkingDirectoryRead = true;
            record.WorkingDirectory = record.Alive ? inspector.WorkingDirectory(record.Entry) : null;
        }

        return record.WorkingDirectory;
    }

    private ProcessEntry? Parent(in ProcessEntry entry) =>
        _current.TryGetValue(entry.ParentPid, out var parent) && parent.Pid != entry.Pid && parent.StartUs <= entry.StartUs ? parent : null;

    private IReadOnlyList<string>? Arguments(Record record, IProcessInspector inspector)
    {
        if (!record.ArgumentsRead)
        {
            record.ArgumentsRead = true;
            record.Arguments = inspector.Arguments(record.Entry);
        }

        return record.Arguments;
    }

    private void Classify(ProcessEntry entry, IProcessInspector inspector)
    {
        if (!_records.TryGetValue(entry.Identity, out var record) || record.Classified)
        {
            return;
        }

        record.Classified = true;
        var ancestors = new List<ProcessEntry>();
        var seen = new HashSet<ProcessIdentity> { entry.Identity };
        var cursor = Parent(entry);
        while (cursor is { } ancestor && seen.Add(ancestor.Identity))
        {
            ancestors.Add(ancestor);
            cursor = Parent(ancestor);
        }

        // Ancestors first seen in the same refresh are classified before their descendants.
        for (var i = ancestors.Count - 1; i >= 0; i--)
        {
            if (_records.TryGetValue(ancestors[i].Identity, out var a) && !a.Classified)
            {
                Classify(ancestors[i], inspector);
            }
        }

        ProcessClass? nearest = null;
        foreach (var ancestor in ancestors)
        {
            if (_records.TryGetValue(ancestor.Identity, out var a) && a.Class is { IsAgentMember: true } c)
            {
                nearest = c;
                break;
            }
        }

        var executable = record.Executable;
        var ancestorExecutables = ancestors.Select(a => _records.TryGetValue(a.Identity, out var r) ? r.Executable : string.Empty).ToArray();
        string? Bundle()
        {
            if (!record.BundleRead)
            {
                record.BundleRead = true;
                record.Bundle = inspector.BundleId(record.Entry);
            }

            return record.Bundle;
        }

        var source = Rules.Source(
            executable,
            () => Rules.NeedsArguments(executable, Bundle) ? Arguments(record, inspector) : null,
            ancestorExecutables,
            Bundle);
        ProcessClass? processClass = (source, nearest) switch
        {
            ({ } s, var n) when n?.Source != s => new ProcessClass(s, TrafficRole.Agent, entry.Identity),
            ({ } s, { } n) => new ProcessClass(s, TrafficRole.Self, n.Root),
            (null, { } n) => new ProcessClass(n.Source, TrafficRole.Tool, n.Root),
            _ => null,
        };
        record.Class = processClass;
        if (processClass is { IsAgentMember: true } member)
        {
            if (!_members.TryGetValue(member.Root, out var set))
            {
                set = new HashSet<ProcessIdentity>();
                _members[member.Root] = set;
            }

            set.Add(entry.Identity);
        }
    }

    private void Prune(long nowMs)
    {
        if (_exited.Count == 0)
        {
            return;
        }

        var write = 0;
        for (var read = 0; read < _exited.Count; read++)
        {
            var identity = _exited[read];
            if (!_records.TryGetValue(identity, out var record) || record.ExitedMs is not { } exitedMs)
            {
                continue;
            }

            if (nowMs - exitedMs <= _exitedRetentionMs)
            {
                _exited[write++] = identity;
                continue;
            }

            _records.Remove(identity);
            if (record.Class is { IsAgentMember: true } member && _members.TryGetValue(member.Root, out var set))
            {
                set.Remove(identity);
                if (set.Count == 0)
                {
                    _members.Remove(member.Root);
                }
            }
        }

        _exited.RemoveRange(write, _exited.Count - write);
    }
}
