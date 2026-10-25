namespace AgentSpeed.Core.Engine;

/// <summary>
/// The agents list (METRICS 6.7): recent or generating agents plus their ancestors, grouped under their root and
/// listed depth-first so every agent is immediately followed by its children.
/// </summary>
internal static class AgentList
{
    /// <param name="describe">Builds an agent's frame from its post-staleness phase.</param>
    public static List<AgentFrame> Build(
        IReadOnlyDictionary<string, AgentInfo> agents, long nowMs, Func<AgentInfo, AgentPhase, AgentFrame> describe)
    {
        var nodes = new Dictionary<string, Node>(StringComparer.Ordinal);
        foreach (var agent in agents.Values)
        {
            var phase = PhaseAt(agent, nowMs);
            if (phase == AgentPhase.Generating
                || agent.LastLineMs is { } last && nowMs - last <= SpeedEngine.AgentListWindowMs)
            {
                nodes[agent.Id] = new Node(describe(agent, phase));
            }
        }

        foreach (var id in nodes.Keys.ToArray())
        {
            var parentId = agents[id].ParentId;
            while (parentId is not null && !nodes.ContainsKey(parentId) && agents.TryGetValue(parentId, out var parent))
            {
                nodes[parentId] = new Node(describe(parent, PhaseAt(parent, nowMs)));
                parentId = parent.ParentId;
            }
        }

        foreach (var node in nodes.Values)
        {
            node.Parent = node.Frame.Info.ParentId is { } parentId && nodes.TryGetValue(parentId, out var parent)
                ? parent
                : null;
        }

        BreakCycles(nodes.Values);
        var roots = new List<Node>();
        foreach (var node in nodes.Values)
        {
            (node.Parent?.Children ?? roots).Add(node);
        }

        foreach (var root in roots)
        {
            Aggregate(root);
        }

        roots.Sort(CompareGroups);
        var list = new List<AgentFrame>(nodes.Count);
        foreach (var root in roots)
        {
            Emit(root, list);
        }

        return list;
    }

    public static AgentPhase PhaseAt(in AgentInfo agent, long nowMs) =>
        agent.LastLineMs is { } last && nowMs - last > SpeedEngine.StaleMs ? AgentPhase.Idle : agent.Phase;

    // Parent links come resolved and acyclic; this only keeps a bad link from hiding agents.
    private static void BreakCycles(IReadOnlyCollection<Node> nodes)
    {
        foreach (var node in nodes)
        {
            var steps = 0;
            for (var ancestor = node.Parent; ancestor is not null && steps++ < nodes.Count; ancestor = ancestor.Parent)
            {
                if (ReferenceEquals(ancestor, node))
                {
                    node.Parent = null;
                    break;
                }
            }
        }
    }

    private static void Aggregate(Node node)
    {
        node.Group = node.Own;
        foreach (var child in node.Children)
        {
            Aggregate(child);
            node.Group = node.Group.With(child.Group);
        }

        node.Children.Sort(static (a, b) => Compare(a.Own, b.Own, a, b));
    }

    private static void Emit(Node node, List<AgentFrame> list)
    {
        list.Add(node.Parent is { } parent ? node.Frame with { ParentId = parent.Id } : node.Frame);
        foreach (var child in node.Children)
        {
            Emit(child, list);
        }
    }

    private static int CompareGroups(Node a, Node b) => Compare(a.Group, b.Group, a, b);

    private static int Compare(in Rank a, in Rank b, Node aNode, Node bNode)
    {
        if (a.Generating != b.Generating)
        {
            return a.Generating ? -1 : 1;
        }

        var byLive = b.Live.CompareTo(a.Live);
        if (byLive != 0)
        {
            return byLive;
        }

        var byActivity = b.Activity.CompareTo(a.Activity);
        return byActivity != 0 ? byActivity : string.CompareOrdinal(aNode.Id, bNode.Id);
    }

    /// <summary>Sort keys of one agent, or of a whole group when merged.</summary>
    private readonly record struct Rank(bool Generating, double Live, long Activity)
    {
        public Rank With(in Rank other) =>
            new(Generating || other.Generating, Live + other.Live, Math.Max(Activity, other.Activity));
    }

    private sealed class Node(AgentFrame frame)
    {
        public AgentFrame Frame { get; } = frame;

        public string Id => Frame.Info.Id;

        public Rank Own { get; } = new(frame.Phase == AgentPhase.Generating, frame.Live.Output, frame.Info.LastLineMs ?? 0);

        public Rank Group { get; set; }

        public Node? Parent { get; set; }

        public List<Node> Children { get; } = [];
    }
}
