using System.Text.Json;
using AgentSpeed.Core.Harnesses;
using static AgentSpeed.Core.Harnesses.HarnessJson;
using AgentSpeed.Core.IO.Sqlite;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.ZCode;

internal sealed record ZCodeRow(
    string Id, string SessionId, string? ParentId, string? Directory, long CreatedMs, long UpdatedMs,
    string? Model, string? Provider, string Status, long? StartedMs, long? CompletedMs, long? DurationMs, TokenCounts Tokens)
{
    public ExecutionModes Modes { get; init; } = ExecutionModes.Empty;

    public string AgentId(string databasePath) => databasePath + "#" + SessionId;

    public ParsedResponse? Response(string databasePath)
    {
        if (Status == "running" || CompletedMs is not { } end || end <= 0)
        {
            return null;
        }

        long? start = StartedMs ?? (DurationMs is > 0 && DurationMs <= end ? end - DurationMs : null);
        return new ParsedResponse("zcode:" + Id, SourceKind.ZCode, AgentId(databasePath), Model, start, end, Tokens, Provider: Provider) { Modes = Modes };
    }
}

internal sealed class ZCodeDatabase : IDisposable
{
    private static readonly string[] UsageColumns =
        ["id", "session_id", "provider_id", "model_id", "status", "started_at", "completed_at", "duration_ms", "input_tokens", "output_tokens",
            "reasoning_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"];
    private static readonly string[] SessionColumns = ["id", "parent_id", "directory", "time_created", "time_updated"];
    private readonly SqliteConnection _connection;
    private bool? _hasParts;

    private ZCodeDatabase(SqliteConnection connection) => _connection = connection;

    public static string DatabasePath(string root) => HarnessPaths.ZCodeDatabase(root);

    public static ZCodeDatabase Open(string path)
    {
        var connection = SqliteReadOnly.Open(path, out _);
        try
        {
            if (!HasColumns(connection, "model_usage", UsageColumns) || !HasColumns(connection, "session", SessionColumns))
            {
                throw new InvalidDataException("Unsupported ZCode database schema.");
            }

            return new ZCodeDatabase(connection);
        }
        catch
        {
            connection.Dispose();
            throw;
        }
    }

    public List<ZCodeRow> Read(long sinceMs = 0, CancellationToken cancellationToken = default)
    {
        var hasModes = HasColumns(_connection, "model_usage", ["parent_user_message_id"])
            && HasColumns(_connection, "message", ["id", "session_id", "data"]);
        var modeColumn = hasModes ? ", CASE WHEN length(CAST(m.data AS BLOB))<=1048576 THEN m.data END" : ", NULL";
        var modeJoin = hasModes ? " LEFT JOIN message m ON m.id=u.parent_user_message_id AND m.session_id=u.session_id " : " ";
        using var rows = _connection.Prepare("""
            SELECT u.id,u.session_id,s.parent_id,s.directory,s.time_created,u.model_id,u.provider_id,u.status,
                   u.started_at,u.completed_at,u.duration_ms,u.input_tokens,u.output_tokens,u.reasoning_tokens,
                   u.cache_creation_input_tokens,u.cache_read_input_tokens,s.time_updated
            """ + modeColumn + " FROM model_usage u LEFT JOIN session s ON s.id=u.session_id " + modeJoin +
            " WHERE coalesce(u.completed_at,u.started_at)>=? ORDER BY u.started_at,u.id");
        rows.Bind(1, sinceMs);
        var result = new List<ZCodeRow>();
        while (rows.Step())
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (rows.GetString(0) is not { Length: > 0 } id || rows.GetString(1) is not { Length: > 0 } session)
            {
                continue;
            }

            var input = TokenCounts.Clamp(rows.GetInt64(11));
            var output = TokenCounts.Clamp(rows.GetInt64(12));
            result.Add(new ZCodeRow(id, session, rows.GetString(2), rows.GetString(3), ValidTimestamp(rows.GetInt64(4)) ?? 0, ValidTimestamp(rows.GetInt64(16)) ?? 0, rows.GetString(5),
                rows.GetString(6), rows.GetString(7) ?? string.Empty, ValidTimestamp(rows.GetInt64(8)), ValidTimestamp(rows.GetNullableInt64(9)), rows.GetNullableInt64(10),
                new TokenCounts(input, Math.Min(input, TokenCounts.Clamp(rows.GetInt64(15))), Math.Min(input, TokenCounts.Clamp(rows.GetInt64(14))),
                    output, Math.Min(output, TokenCounts.Clamp(rows.GetInt64(13)))))
            { Modes = ZCodeModes.Read(rows.GetUtf8(17), rows.GetString(6), rows.GetString(5)) });
        }

        return result;
    }

    public List<ZCodeAgent> ReadAgents(long sinceMs)
    {
        var result = new List<ZCodeAgent>();
        if (!HasColumns(_connection, "message", ["id", "session_id", "time_created", "time_updated", "data"]))
        {
            return result;
        }

        using var rows = _connection.Prepare("""
            SELECT m.id,m.session_id,m.time_created,m.time_updated,
                   CASE WHEN length(CAST(m.data AS BLOB))<=1048576 THEN m.data END,s.parent_id,s.directory,s.time_created,s.time_updated
            FROM session s JOIN message m ON m.id=(
                SELECT id FROM message WHERE session_id=s.id ORDER BY time_created DESC,id DESC LIMIT 1)
            WHERE s.time_updated>=?
            """);
        rows.Bind(1, sinceMs);
        while (rows.Step())
        {
            if (rows.GetString(0) is not { } message || rows.GetString(1) is not { } session || rows.GetUtf8(4).IsEmpty)
            {
                continue;
            }

            try
            {
                var reader = new Utf8JsonReader(rows.GetUtf8(4), JsonScan.Options);
                using var document = JsonDocument.ParseValue(ref reader);
                var root = document.RootElement;
                var role = String(root, "role");
                if (role is not "assistant" and not "user")
                {
                    continue;
                }

                var timing = Get(root, "time");
                var created = Timestamp(Get(timing, "created")) ?? ValidTimestamp(rows.GetInt64(2)) ?? 0;
                var completed = Timestamp(Get(timing, "completed"));
                var phase = role == "user" || (completed is null && Get(root, "error").ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
                    ? AgentPhase.Generating : AgentPhase.Idle;
                if (role == "assistant" && HasRunningTool(message))
                {
                    phase = AgentPhase.Tools;
                }

                var project = rows.GetString(6) ?? String(Get(root, "path"), "cwd");
                result.Add(new ZCodeAgent(_connection.Path + "#" + session, session, rows.GetString(5), ValidTimestamp(rows.GetInt64(7)) ?? 0,
                    project is null ? null : PathText.Basename(project), String(root, "modelId") ?? String(root, "modelID"), phase,
                    phase == AgentPhase.Generating ? created : null, Math.Max(ValidTimestamp(rows.GetInt64(8)) ?? 0, Math.Max(ValidTimestamp(rows.GetInt64(3)) ?? 0, completed ?? created)))
                { Modes = ZCodeModes.Read(rows.GetUtf8(4), null, null), ModeContext = role == "user" });
            }
            catch (JsonException)
            {
            }
        }

        return result;
    }

    private bool HasRunningTool(string message)
    {
        if (!(_hasParts ??= HasColumns(_connection, "part", ["message_id", "data"])))
        {
            return false;
        }

        using var rows = _connection.Prepare("SELECT CASE WHEN length(CAST(data AS BLOB))<=1048576 THEN data END FROM part WHERE message_id=?");
        rows.Bind(1, message);
        while (rows.Step())
        {
            if (rows.GetUtf8(0).IsEmpty)
            {
                continue;
            }

            try
            {
                var reader = new Utf8JsonReader(rows.GetUtf8(0), JsonScan.Options);
                using var document = JsonDocument.ParseValue(ref reader);
                var root = document.RootElement;
                if (String(root, "type") == "tool" && String(Get(root, "state"), "status") is "pending" or "running")
                {
                    return true;
                }
            }
            catch (JsonException)
            {
            }
        }

        return false;
    }

    public void Dispose() => _connection.Dispose();

    private static bool HasColumns(SqliteConnection connection, string table, string[] required)
    {
        using var query = connection.Prepare(table switch
        {
            "model_usage" => "PRAGMA table_info(model_usage)",
            "session" => "PRAGMA table_info(session)",
            "message" => "PRAGMA table_info(message)",
            "part" => "PRAGMA table_info(part)",
            _ => throw new ArgumentOutOfRangeException(nameof(table)),
        });
        var columns = new HashSet<string>(StringComparer.Ordinal);
        while (query.Step())
        {
            if (query.GetString(1) is { } name)
            {
                columns.Add(name);
            }
        }

        return required.All(columns.Contains);
    }
}
