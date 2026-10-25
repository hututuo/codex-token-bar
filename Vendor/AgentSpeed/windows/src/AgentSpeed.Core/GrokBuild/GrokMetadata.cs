using System.Text.Json;
using AgentSpeed.Core.Harnesses;
using AgentSpeed.Core.IO;
using AgentSpeed.Core.Parsing;
using static AgentSpeed.Core.Harnesses.HarnessJson;

namespace AgentSpeed.Core.GrokBuild;

internal sealed record GrokMetadata(string? Id, string? Cwd, string? Model, string? Parent, string? Kind, long? CreatedMs)
{
    public static GrokMetadata? Read(string folder)
    {
        try
        {
            var path = Path.Combine(folder, "summary.json");
            using var document = HarnessJson.ReadMetadata(path, 1024 * 1024);
            if (document is null) return null;
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            var session = Get(root, "info");
            return new GrokMetadata(String(session, "id"), String(session, "cwd"), String(root, "current_model_id"),
                String(root, "parent_session_id"), String(root, "session_kind"), Timestamp(Get(root, "created_at")));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }
}

internal sealed class GrokBatch(GrokParser owner, GrokMetadata? metadata) : ILineBatch
{
    private readonly List<GrokLine> _lines = [];
    private int _malformed;
    public int Count => _lines.Count;
    public void OnLine(ReadOnlySpan<byte> line) => _lines.Add(GrokLine.Read(line));
    public void OnMalformed() => _malformed++;
    public void ApplyTo(IResponseSink sink) => owner.ApplyBatch(metadata, _lines, _malformed, sink);
    public void Clear()
    {
        _lines.Clear();
        _malformed = 0;
    }
}

internal sealed class GrokTailer(string path) : FileTailer(path)
{
    public override TailReadResult ReadAppended(ILineSink sink, CancellationToken cancellationToken = default)
    {
        var result = base.ReadAppended(sink, cancellationToken);
        return result with { LastWriteUtc = GrokFiles.Modified(Path, result.LastWriteUtc) };
    }
}

internal static class GrokFiles
{
    public static DateTime Modified(string path, DateTime updatesWriteUtc)
    {
        try
        {
            var summary = new FileInfo(Path.Combine(Path.GetDirectoryName(path) ?? string.Empty, "summary.json"));
            return summary.Exists && summary.LastWriteTimeUtc > updatesWriteUtc ? summary.LastWriteTimeUtc : updatesWriteUtc;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return updatesWriteUtc;
        }
    }
}
