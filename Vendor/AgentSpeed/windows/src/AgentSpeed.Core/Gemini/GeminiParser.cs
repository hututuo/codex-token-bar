using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.Gemini;

/// <summary>
/// Gemini CLI session state machine (METRICS 4.6). A <c>.jsonl</c> file is fed line by line; a legacy <c>.json</c>
/// file is fed as one whole document, which resets the per-file state (never the deduper) and replays it.
/// </summary>
internal sealed class GeminiParser : TranscriptParser<GeminiLine>
{
    /// <summary>Legacy <c>.json</c> documents larger than this are not read (METRICS 4.6).</summary>
    public const int MaxDocumentBytes = 64 * 1024 * 1024;

    private readonly bool _pathIsSubagent;
    private readonly string? _pathProject;
    private readonly Dictionary<string, ParsedResponse> _responses = new(StringComparer.Ordinal);
    private readonly HashSet<string> _seenToolCalls = new(StringComparer.Ordinal);
    private long? _pendingStartMs;

    /// <summary>Id of the record that set <see cref="_pendingStartMs"/>.</summary>
    private string? _marker;

    public GeminiParser(string agentId, IDeduper deduper)
        : base(agentId, deduper, SourceKind.Gemini)
    {
        IsDocument = agentId.EndsWith(".json", StringComparison.OrdinalIgnoreCase);
        IsMainSession = GeminiPaths.IsMainSessionPath(agentId);
        ParentDirectory = GeminiPaths.ParentDirectoryOf(agentId);
        _pathIsSubagent = ParentDirectory is not null;
        _pathProject = GeminiProjects.ProjectOf(agentId);
        RestorePathState();
    }

    /// <summary>A legacy session: every line this parser receives is one whole JSON document.</summary>
    public bool IsDocument { get; }

    /// <summary>The file sits directly inside a <c>chats</c> folder.</summary>
    public bool IsMainSession { get; }

    /// <summary>The <c>&lt;dir&gt;</c> of <c>chats/&lt;dir&gt;/&lt;file&gt;</c>: the sanitized id of the main session (METRICS 6.7).</summary>
    public string? ParentDirectory { get; }

    /// <summary>The latest <c>sessionId</c> of a header or <c>$set</c>.</summary>
    public string? SessionId { get; private set; }

    /// <summary>The first parseable header <c>startTime</c>.</summary>
    public long? StartTimeMs { get; private set; }

    public override void Reset()
    {
        base.Reset();
        _responses.Clear();
        _seenToolCalls.Clear();
        _pendingStartMs = null;
        _marker = null;
        SessionId = null;
        StartTimeMs = null;
        RestorePathState();
    }

    public override void Apply(in GeminiLine line, IResponseSink sink)
    {
        if (line.Status == LineStatus.Malformed)
        {
            // A legacy document caught mid-write keeps its previous state.
            CountMalformed();
            return;
        }

        if (line.Status != LineStatus.Valid)
        {
            return;
        }

        switch (line.Kind)
        {
            case GeminiRecordKind.Rewind:
                Idle(LastLineMs ?? 0);
                break;
            case GeminiRecordKind.Patch:
                if (Phase == AgentPhase.Generating && _marker is { } marker && line.RemoveIds is { } removed
                    && Array.IndexOf(removed, marker) >= 0)
                {
                    Idle(LastLineMs ?? 0);
                }

                break;
            case GeminiRecordKind.Message:
                ApplyMessage(in line.Message, sink);
                break;
            case GeminiRecordKind.Metadata:
                ApplyMetadata(line.Metadata!, sink);
                break;
            case GeminiRecordKind.Header:
                ApplyHeader(line.Header!, sink);
                break;
            case GeminiRecordKind.Document:
                Reset();
                ApplyHeader(line.Header!, sink);
                break;
        }
    }

    protected override GeminiLine Extract(ReadOnlySpan<byte> line) =>
        IsDocument ? GeminiLineReader.ReadDocument(line) : GeminiLineReader.Read(line);

    private void ApplyHeader(GeminiHeader header, IResponseSink sink)
    {
        SetSessionId(header.SessionId);
        if (header.IsSubagentKind)
        {
            SetSubagent(true);
        }

        if (header.StartMs is { } start)
        {
            if (StartTimeMs is null)
            {
                StartTimeMs = start;
                MarkChanged();
            }

            Touch(start);
        }

        if (header.LastUpdatedMs is { } updated)
        {
            Touch(updated);
        }

        foreach (ref readonly var message in (header.Messages ?? []).AsSpan())
        {
            ApplyMessage(in message, sink);
        }
    }

    private void ApplyMetadata(GeminiMetadata metadata, IResponseSink sink)
    {
        if (metadata.LastUpdatedMs is { } updated)
        {
            Touch(updated);
        }

        if (metadata.IsSubagentKind)
        {
            SetSubagent(true);
        }

        if (metadata.SessionId is { } sessionId)
        {
            SetSessionId(sessionId);
        }

        if (metadata.Checkpoint is { } checkpoint)
        {
            ApplyCheckpoint(checkpoint, sink);
        }

        // A sub-agent writes its summary when it finished.
        if (metadata.HasSummary)
        {
            Idle(LastLineMs ?? 0);
        }
    }

    // $set.messages (v0.44 – v0.63): repeats the history; an in-flight request missing from it was rolled back.
    private void ApplyCheckpoint(GeminiCheckpoint checkpoint, IResponseSink sink)
    {
        foreach (var response in checkpoint.Responses)
        {
            var ownership = Claim(response.Id);
            if (ownership == Ownership.OtherFile)
            {
                continue;
            }

            if (_responses.TryGetValue(response.Id, out var existing))
            {
                Update(existing, response.TimestampMs, response.Tokens, response.Model, sink);
            }
            else
            {
                Emit(response.Id, null, response.TimestampMs, response.Tokens, response.Model, ownership == Ownership.New, sink);
            }
        }

        if (Phase == AgentPhase.Generating && (_marker is null || Array.IndexOf(checkpoint.Ids, _marker) < 0))
        {
            Idle(LastLineMs ?? 0);
        }
    }

    private void ApplyMessage(in GeminiMessage message, IResponseSink sink)
    {
        if (message.TimestampMs is not { } ts)
        {
            return;
        }

        Touch(ts);
        if (message.DetailMs is { } detail)
        {
            Touch(detail);
        }

        switch (message.Kind)
        {
            case GeminiMessageKind.User:
                Generating(ts, message.Id);
                return;
            case GeminiMessageKind.Error or GeminiMessageKind.Cancelled:
                Idle(ts);
                return;
            case GeminiMessageKind.Gemini:
                break;
            default:
                return;
        }

        var key = message.Id;
        if (!message.HasTokens)
        {
            if (Deduper.TryGetOwner(key, out var owner) && !string.Equals(owner, AgentId, StringComparison.Ordinal))
            {
                return;
            }
        }
        else
        {
            var ownership = Claim(key);
            if (ownership == Ownership.OtherFile)
            {
                return;
            }

            if (_responses.TryGetValue(key, out var existing))
            {
                Update(existing, ts, message.Tokens, message.Model, sink);
            }
            else
            {
                // Created when its tools finished (<= v0.31): the stream end is unknown.
                var start = message.FirstCallMs is { } firstCall && ts >= firstCall ? null : _pendingStartMs;
                Emit(key, start, ts, message.Tokens, message.Model, ownership == Ownership.New, sink);
                _pendingStartMs = null;
                _marker = null;
                SetPhase(message.HasFunctionCall || !message.HasVisibleText ? AgentPhase.Tools : AgentPhase.Idle, ts, null);
            }
        }

        ApplyToolCalls(in message, ts);
    }

    private void ApplyToolCalls(in GeminiMessage message, long ts)
    {
        if (message.ToolCalls is not { } calls)
        {
            return;
        }

        var anyNew = false;
        var completesTask = false;
        var allCancelled = true;
        long? latest = null;
        foreach (var call in calls)
        {
            if (_seenToolCalls.Contains(call.Id))
            {
                continue;
            }

            anyNew = true;
            completesTask |= call.CompletesTask;
            allCancelled &= call.IsCancelled;
            if (call.TimestampMs is { } callMs && (latest is not { } known || callMs > known))
            {
                latest = callMs;
            }
        }

        if (!anyNew)
        {
            return;
        }

        foreach (var call in calls)
        {
            _seenToolCalls.Add(call.Id);
        }

        if (completesTask || allCancelled)
        {
            Idle(ts);
        }
        else
        {
            Generating(latest ?? ts, message.Id);
        }
    }

    private void Emit(string key, long? startMs, long endMs, TokenCounts tokens, string? model, bool isCompletion, IResponseSink sink)
    {
        var response = new ParsedResponse(key, SourceKind.Gemini, AgentId, model, startMs, endMs, tokens, Final: true);
        _responses[key] = response;
        SetModel(model);
        sink.OnResponse(response, isCompletion);
    }

    private void Update(ParsedResponse existing, long endMs, TokenCounts tokens, string? model, IResponseSink sink)
    {
        var updated = existing with
        {
            Tokens = tokens,
            EndMs = Math.Max(existing.EndMs, endMs),
            Model = model ?? existing.Model,
        };
        SetModel(updated.Model);
        if (updated == existing)
        {
            return;
        }

        _responses[existing.Key] = updated;
        sink.OnResponse(updated, false);
    }

    private Ownership Claim(string key)
    {
        if (Deduper.TryClaim(key, AgentId, out var owner))
        {
            return Ownership.New;
        }

        return string.Equals(owner, AgentId, StringComparison.Ordinal) ? Ownership.ThisFile : Ownership.OtherFile;
    }

    private void Generating(long startMs, string marker)
    {
        _pendingStartMs = startMs;
        _marker = marker;
        SetPhase(AgentPhase.Generating, startMs, startMs);
    }

    private void Idle(long timestampMs)
    {
        _pendingStartMs = null;
        _marker = null;
        SetPhase(AgentPhase.Idle, timestampMs, null);
    }

    private void SetSessionId(string sessionId)
    {
        if (!string.Equals(SessionId, sessionId, StringComparison.Ordinal))
        {
            SessionId = sessionId;
            MarkChanged();
        }
    }

    private void RestorePathState()
    {
        SetSource(SourceKind.Gemini);
        Project = _pathProject;
        SetSubagent(_pathIsSubagent);
    }

    private enum Ownership : byte
    {
        New,
        ThisFile,
        OtherFile,
    }
}
