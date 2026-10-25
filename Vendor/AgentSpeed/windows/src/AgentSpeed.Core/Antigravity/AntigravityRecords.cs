using System.Text;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Antigravity;

/// <summary><c>steps.step_type</c> and <c>steps.status</c> values used by METRICS 4.8.</summary>
internal static class StepCodes
{
    public const long UserInput = 14;
    public const long PlannerResponse = 15;
    public const long Done = 3;

    /// <summary>Token counts above this make the step metadata malformed.</summary>
    public const ulong MaxTokens = 10_000_000;

    /// <summary>PENDING, RUNNING, GENERATING, WAITING, QUEUED; every other status is terminal.</summary>
    public static bool IsOpen(long status) => status is 1 or 2 or 8 or 9 or 11;

    /// <summary>CANCELED, ERROR, INTERRUPTED: such planner responses count in totals only.</summary>
    public static bool IsFailed(long status) => status is 6 or 7 or 12;
}

/// <summary><c>ModelUsageStats</c> of a step; the key is <c>response_id</c>, else <c>message_id</c>, else null.</summary>
internal sealed record AntigravityUsage(long Input, long Output, long CacheRead, long Thinking, long Response, string? Key)
{
    public bool HasTokens => Input > 0 || Output > 0 || CacheRead > 0 || Thinking > 0 || Response > 0;

    /// <summary>METRICS 4.8 Tokens: <c>input_tokens</c> excludes cached input, <c>output_tokens</c> includes thinking.</summary>
    public TokenCounts ToTokens() => new(
        Input + CacheRead, CacheRead, 0, Output > 0 ? Output : Thinking + Response, Thinking);
}

/// <summary>The <c>CortexStepMetadata</c> fields of one step; every timestamp is null when invalid.</summary>
internal sealed record AntigravityStep(
    long? CreatedMs,
    long? ViewableMs,
    long? FinishedGeneratingMs,
    long? CompletedMs,
    long? LastChunkMs,
    long? StartedMs,
    AntigravityUsage? Usage)
{
    /// <summary>Every valid timestamp of the step.</summary>
    public List<long> Times()
    {
        var times = new List<long>(6);
        foreach (var time in (ReadOnlySpan<long?>)[CreatedMs, ViewableMs, FinishedGeneratingMs, CompletedMs, LastChunkMs, StartedMs])
        {
            if (time is { } value)
            {
                times.Add(value);
            }
        }

        return times;
    }

    public long? LatestTime => Times() is { Count: > 0 } times ? times.Max() : null;
}

/// <summary>One <c>steps</c> row; <see cref="Step"/> is null when the metadata is absent, too large or malformed.</summary>
internal sealed record AntigravityStepRow(long Idx, long StepType, long Status, AntigravityStep? Step);

/// <summary>A <c>gen_metadata</c> row: the steps it generated and the model that served them.</summary>
internal sealed record AntigravityGeneration(long Idx, IReadOnlySet<ulong> StepIndices, string? Model);

/// <summary>An <c>executor_metadata</c> row: how the run ended, its last step and its planner model.</summary>
internal sealed record AntigravityExecutor(long Idx, long TerminationReason, long LastStepIdx, string? Model);

/// <summary><c>CortexTrajectoryMetadata</c>: when the conversation was created, where, and whose sub-agent it is.</summary>
internal sealed record AntigravityTrajectory(long? CreatedMs, string? ParentConversationId, string? Project, bool IsSubagent);

/// <summary>Decodes the protobuf blobs of an Antigravity database (METRICS 4.8). Pure and thread-safe.</summary>
internal static class AntigravityDecoder
{
    /// <exception cref="ProtoFormatException">The blob, or a nested message these rules read, is malformed.</exception>
    public static AntigravityStep Step(ReadOnlySpan<byte> blob)
    {
        var message = ProtoMessage.Parse(blob);
        var created = message.Timestamp(1);
        var viewable = message.Timestamp(6);
        var finished = message.Timestamp(7);
        var completed = message.Timestamp(8);
        var chunk = message.Timestamp(22);
        var started = message.Timestamp(32);
        AntigravityUsage? usage = null;
        if (message.TryMessage(9, out var stats))
        {
            var input = stats.UInt(2);
            var output = stats.UInt(3);
            var cache = stats.UInt(5);
            var thinking = stats.UInt(9);
            var response = stats.UInt(10);
            if (input > StepCodes.MaxTokens || output > StepCodes.MaxTokens || cache > StepCodes.MaxTokens
                || thinking > StepCodes.MaxTokens || response > StepCodes.MaxTokens)
            {
                throw new ProtoFormatException("implausible token count");
            }

            var key = NonEmpty(stats.String(11)) ?? NonEmpty(stats.String(7));
            usage = new AntigravityUsage((long)input, (long)output, (long)cache, (long)thinking, (long)response, key);
        }

        return new AntigravityStep(created, viewable, finished, completed, chunk, started, usage);
    }

    /// <exception cref="ProtoFormatException">Malformed.</exception>
    public static AntigravityGeneration Generation(long idx, ReadOnlySpan<byte> blob)
    {
        var message = ProtoMessage.Parse(blob);
        string? model = null;
        if (message.TryMessage(1, out var chat))
        {
            model = NonEmpty(chat.String(19)) ?? NonEmpty(chat.String(21));
        }

        return new AntigravityGeneration(idx, message.RepeatedUInt(2).ToHashSet(), model);
    }

    /// <exception cref="ProtoFormatException">Malformed.</exception>
    public static AntigravityExecutor Executor(long idx, ReadOnlySpan<byte> blob)
    {
        var message = ProtoMessage.Parse(blob);
        string? model = null;
        if (message.TryMessage(10, out var cascade) && cascade.TryMessage(1, out var planner))
        {
            model = NonEmpty(planner.String(28));
        }

        return new AntigravityExecutor(idx, message.Int(1), message.Int(3), model);
    }

    /// <exception cref="ProtoFormatException">Malformed.</exception>
    public static AntigravityTrajectory Trajectory(ReadOnlySpan<byte> blob)
    {
        var message = ProtoMessage.Parse(blob);
        string? workspaceUri = null;
        if (message.TryMessage(1, out var workspace, first: true))
        {
            workspaceUri = workspace.String(1);
        }

        var uris = message.Strings(7);
        var project = uris.Count > 0 ? UriBasename(uris[0]) : null;
        project ??= workspaceUri is not null ? UriBasename(workspaceUri) : null;
        var created = message.Timestamp(2);
        var parent = NonEmpty(message.String(5));
        var subagent = parent is not null || message.Int(17) > 0 || message.Has(8, ProtoMessage.WireLength);
        return new AntigravityTrajectory(created, parent, project, subagent);
    }

    /// <summary>
    /// Basename of a path or URI. A URI (a scheme of two or more characters) loses its scheme and authority and is
    /// percent-decoded as UTF-8 (invalid escapes stay) before splitting on <c>/</c> and <c>\</c>.
    /// </summary>
    public static string? UriBasename(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return null;
        }

        var scheme = SchemeLength(value);
        if (scheme > 0)
        {
            var rest = value[scheme..];
            if (rest.StartsWith("//", StringComparison.Ordinal))
            {
                var slash = rest.IndexOf('/', 2);
                rest = slash >= 0 ? rest[slash..] : string.Empty;
            }

            value = PercentDecode(rest);
        }

        var name = PathText.Basename(value);
        return name.Length > 0 ? name : null;
    }

    // "[A-Za-z][A-Za-z0-9+.-]+:" → its length including the colon, else 0.
    private static int SchemeLength(string value)
    {
        if (value.Length < 3 || !char.IsAsciiLetter(value[0]))
        {
            return 0;
        }

        var i = 1;
        while (i < value.Length && (char.IsAsciiLetterOrDigit(value[i]) || value[i] is '+' or '.' or '-'))
        {
            i++;
        }

        return i >= 2 && i < value.Length && value[i] == ':' ? i + 1 : 0;
    }

    // Python's urllib.parse.unquote(encoding="utf-8", errors="replace").
    private static string PercentDecode(string value)
    {
        if (!value.Contains('%', StringComparison.Ordinal))
        {
            return value;
        }

        var result = new StringBuilder(value.Length);
        var bytes = new List<byte>();
        void Flush()
        {
            if (bytes.Count > 0)
            {
                result.Append(Encoding.UTF8.GetString([.. bytes]));
                bytes.Clear();
            }
        }

        for (var i = 0; i < value.Length; i++)
        {
            var c = value[i];
            if (c == '%' && IsHex(value, i + 1) && IsHex(value, i + 2))
            {
                bytes.Add((byte)((HexValue(value[i + 1]) << 4) | HexValue(value[i + 2])));
                i += 2;
            }
            else if (c < 0x80)
            {
                bytes.Add((byte)c);
            }
            else
            {
                Flush();
                result.Append(c);
            }
        }

        Flush();
        return result.ToString();
    }

    private static bool IsHex(string value, int index) => index < value.Length && char.IsAsciiHexDigit(value[index]);

    private static int HexValue(char c) => c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;

    private static string? NonEmpty(string value) => value.Length > 0 ? value : null;
}
