using AgentSpeed.Core.Antigravity;
using AgentSpeed.Core.Gemini;
using AgentSpeed.Core.Omp;
using AgentSpeed.Core.Parsing;
using AgentSpeed.Core.WorkBuddy;

namespace AgentSpeed.Core.Monitoring;

/// <summary>How a transcript names its parent (METRICS 6.7).</summary>
internal enum LinkKind : byte
{
    /// <summary>Claude: by the <c>subagents</c> folder layout.</summary>
    Path,

    /// <summary>Codex: by parent thread id.</summary>
    CodexThread,

    /// <summary>DeepSeek Harness: by parent session id.</summary>
    DshSession,

    /// <summary>OpenCode: by <c>session_v2.parent_id</c>.</summary>
    OpenCodeSession,

    /// <summary>Gemini CLI: by the sanitized main session id inside the same <c>chats</c> folder.</summary>
    GeminiSession,

    /// <summary>omp: <c>&lt;dir&gt;/&lt;name&gt;.jsonl</c> below a session's folder belongs to <c>&lt;dir&gt;.jsonl</c>.</summary>
    OmpPath,

    /// <summary>Antigravity: by <c>parent_conversation_id</c>, compared case-insensitively.</summary>
    AntigravityConversation,

    /// <summary>WorkBuddy: by the <c>subagents</c> folder layout, like Claude, within the China edition only.</summary>
    WorkBuddyPath,

    /// <summary>WorkBuddy AI: by the <c>subagents</c> folder layout, within the international edition only.</summary>
    WorkBuddyAiPath,
    ZCodeSession,
    KimiSession,
    GrokBuildSession,
}

/// <summary>What one transcript says about its parent (METRICS 6.7).</summary>
/// <param name="ThreadId">The id other transcripts use to name this one as their parent.</param>
/// <param name="Rank">Preferred first among several candidates with the same <paramref name="ThreadId"/> when lower.</param>
internal readonly record struct AgentLink(
    string Id, LinkKind Kind, string? ThreadId, string? ParentThreadId, long? CreatedMs, int Rank = 0)
{
    public static AgentLink Of(TranscriptParser parser) => parser switch
    {
        GrokBuild.GrokParser grok => new AgentLink(grok.AgentId, LinkKind.GrokBuildSession, grok.SessionId, grok.ParentSessionId, grok.CreatedMs),
        Kimi.KimiParser kimi => new AgentLink(kimi.AgentId, LinkKind.KimiSession, kimi.AgentId, kimi.ParentPath, kimi.CreatedMs),
        CodexParser codex => new AgentLink(codex.AgentId, LinkKind.CodexThread, codex.MetaThreadId, codex.ParentThreadId, codex.CreatedMs),
        DshParser dsh => new AgentLink(dsh.AgentId, LinkKind.DshSession, dsh.SessionId, dsh.ParentSession, dsh.CreatedMs),
        GeminiParser gemini => OfGemini(gemini),
        OmpParser omp => new AgentLink(omp.AgentId, LinkKind.OmpPath, null, omp.ParentPath, omp.HeaderMs),
        AntigravityParser antigravity => new AgentLink(
            antigravity.AgentId,
            LinkKind.AntigravityConversation,
            antigravity.ConversationId.ToLowerInvariant(),
            antigravity.ParentConversationId?.ToLowerInvariant(),
            antigravity.CreatedMs),
        WorkBuddyParser workBuddy => new AgentLink(
            workBuddy.AgentId,
            workBuddy.Source == SourceKind.WorkBuddyAi ? LinkKind.WorkBuddyAiPath : LinkKind.WorkBuddyPath,
            null,
            ParentLinks.ClaudeParentPath(workBuddy.AgentId),
            null),
        _ => new AgentLink(parser.AgentId, LinkKind.Path, null, null, null),
    };

    // Main sessions are keyed by their chats folder plus sanitized session id; sub-agents name <chats>/<dir>.
    private static AgentLink OfGemini(GeminiParser gemini)
    {
        var path = gemini.AgentId;
        var thread = gemini.IsMainSession && gemini.SessionId is { Length: > 0 } session && FolderOf(path, 1) is { } chats
            ? chats + "\n" + GeminiPaths.Sanitize(session)
            : null;
        var parent = gemini.ParentDirectory is { Length: > 0 } directory && FolderOf(path, 2) is { } parentChats
            ? parentChats + "\n" + directory
            : null;
        return new AgentLink(path, LinkKind.GeminiSession, thread, parent, gemini.StartTimeMs ?? 0, gemini.IsDocument ? 1 : 0);
    }

    private static string? FolderOf(string path, int levels)
    {
        var end = path.Length;
        for (var i = 0; i < levels; i++)
        {
            end = path.AsSpan(0, end).LastIndexOfAny('/', '\\');
            if (end < 0)
            {
                return null;
            }
        }

        return path[..end];
    }
}

/// <summary>
/// Resolves parent agent ids (METRICS 6.7): Claude, omp and WorkBuddy by path, Codex by parent thread, dsh, OpenCode and
/// Gemini by parent session, Antigravity by parent conversation.
/// </summary>
internal static class ParentLinks
{
    private const string SubagentsFolder = "subagents";
    private const string TranscriptExtension = ".jsonl";

    /// <summary>Maps each agent that has a parent to that parent's id; self references and cycles are dropped.</summary>
    /// <param name="pathComparer">How transcript paths compare on this file system.</param>
    public static Dictionary<string, string> Resolve(IReadOnlyCollection<AgentLink> agents, StringComparer pathComparer)
    {
        var byPath = new Dictionary<string, AgentLink>(agents.Count, pathComparer);
        var byThread = new Dictionary<(LinkKind, string), AgentLink>();
        var conversations = new Dictionary<string, List<AgentLink>>(StringComparer.Ordinal);
        var grokSessions = new Dictionary<string, List<AgentLink>>(StringComparer.Ordinal);
        foreach (var agent in agents)
        {
            byPath.TryAdd(agent.Id, agent);
            if (agent.Kind == LinkKind.AntigravityConversation)
            {
                if (agent.ThreadId is { Length: > 0 } conversation)
                {
                    if (!conversations.TryGetValue(conversation, out var copies))
                    {
                        conversations[conversation] = copies = [];
                    }

                    copies.Add(agent);
                }
            }
            else if (agent.Kind == LinkKind.GrokBuildSession && agent.ThreadId is { Length: > 0 } grok)
            {
                if (!grokSessions.TryGetValue(grok, out var copies))
                {
                    grokSessions[grok] = copies = [];
                }

                copies.Add(agent);
            }
            else if (!IsPathKind(agent.Kind) && agent.ThreadId is { Length: > 0 } thread
                && (!byThread.TryGetValue((agent.Kind, thread), out var known) || CreatedBefore(agent, known)))
            {
                byThread[(agent.Kind, thread)] = agent;
            }
        }

        var parents = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var agent in agents)
        {
            string? parent = null;
            switch (agent.Kind)
            {
                case LinkKind.Path:
                    if (ClaudeParentPath(agent.Id) is { } candidate && byPath.TryGetValue(candidate, out var tracked))
                    {
                        parent = tracked.Id;
                    }

                    break;
                case LinkKind.OmpPath:
                    if (agent.ParentThreadId is { } folder && byPath.TryGetValue(folder, out var session) && session.Kind == LinkKind.OmpPath)
                    {
                        parent = session.Id;
                    }

                    break;
                case LinkKind.WorkBuddyPath or LinkKind.WorkBuddyAiPath:
                    // Nested sub-agents are stored flat under the main session, so they attach to it.
                    if (agent.ParentThreadId is { } main && byPath.TryGetValue(main, out var mainSession) && mainSession.Kind == agent.Kind)
                    {
                        parent = mainSession.Id;
                    }

                    break;
                case LinkKind.GrokBuildSession:
                    if (agent.ParentThreadId is { Length: > 0 } grok && grokSessions.TryGetValue(grok, out var sessions))
                    {
                        parent = PreferredCopy(sessions, agent.Id, group: true).Id;
                    }

                    break;
                case LinkKind.AntigravityConversation:
                    if (agent.ParentThreadId is { Length: > 0 } conversation && conversations.TryGetValue(conversation, out var copies))
                    {
                        parent = PreferredCopy(copies, agent.Id).Id;
                    }

                    break;
                default:
                    if (agent.ParentThreadId is { Length: > 0 } thread && byThread.TryGetValue((agent.Kind, thread), out var owner))
                    {
                        parent = owner.Id;
                    }

                    break;
            }

            if (parent is not null && !string.Equals(parent, agent.Id, StringComparison.Ordinal))
            {
                parents[agent.Id] = parent;
            }
        }

        DropCycles(parents);
        return parents;
    }

    /// <summary><c>dir/session/subagents/name.jsonl</c> → <c>dir/session.jsonl</c>, with either separator.</summary>
    public static string? ClaudeParentPath(string path)
    {
        var span = path.AsSpan();
        var name = span.LastIndexOfAny('/', '\\');
        if (name < 0)
        {
            return null;
        }

        var folder = span[..name];
        var start = folder.LastIndexOfAny('/', '\\');
        return start >= 0 && folder[(start + 1)..].SequenceEqual(SubagentsFolder)
            ? string.Concat(folder[..start], TranscriptExtension)
            : null;
    }

    private static bool IsPathKind(LinkKind kind) =>
        kind is LinkKind.Path or LinkKind.OmpPath or LinkKind.WorkBuddyPath or LinkKind.WorkBuddyAiPath;

    // Copies of one conversation in several stores: the one in the child's own conversations folder, then ordinal path.
    private static AgentLink PreferredCopy(List<AgentLink> copies, string child, bool group = false)
    {
        var folder = group ? FolderOf(FolderOf(child)) : FolderOf(child);
        AgentLink? best = null;
        foreach (var copy in copies)
        {
            if (best is not { } current)
            {
                best = copy;
                continue;
            }

            var sameFolder = string.Equals(group ? FolderOf(FolderOf(copy.Id)) : FolderOf(copy.Id), folder, StringComparison.Ordinal);
            var currentSameFolder = string.Equals(group ? FolderOf(FolderOf(current.Id)) : FolderOf(current.Id), folder, StringComparison.Ordinal);
            if (sameFolder != currentSameFolder ? sameFolder : string.CompareOrdinal(copy.Id, current.Id) < 0)
            {
                best = copy;
            }
        }

        return best!.Value;
    }

    private static string FolderOf(string path)
    {
        var cut = path.AsSpan().LastIndexOfAny('/', '\\');
        return cut < 0 ? string.Empty : path[..cut];
    }

    private static bool CreatedBefore(in AgentLink a, in AgentLink b)
    {
        if (a.Rank != b.Rank)
        {
            return a.Rank < b.Rank;
        }

        var byTime = (a.CreatedMs ?? long.MaxValue).CompareTo(b.CreatedMs ?? long.MaxValue);
        return byTime != 0 ? byTime < 0 : string.CompareOrdinal(a.Id, b.Id) < 0;
    }

    // In ordinal id order, drops the link of each agent whose chain of parents still loops.
    private static void DropCycles(Dictionary<string, string> parents)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var id in parents.Keys.Order(StringComparer.Ordinal).ToList())
        {
            seen.Clear();
            string? current = id;
            while (current is not null && seen.Add(current))
            {
                current = parents.GetValueOrDefault(current);
            }

            if (current is not null)
            {
                parents.Remove(id);
            }
        }
    }
}
