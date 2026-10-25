namespace AgentSpeed.Core.History;

internal sealed partial class HistoryStore
{
    private const string ModesSchema = """
        CREATE TABLE IF NOT EXISTS contribution_modes (
            file_id INTEGER NOT NULL, day TEXT NOT NULL, source TEXT NOT NULL, model TEXT NOT NULL,
            kind TEXT NOT NULL, mode TEXT NOT NULL, evidence TEXT NOT NULL, provider TEXT NOT NULL,
            requests INTEGER NOT NULL, output INTEGER NOT NULL, measured_output INTEGER NOT NULL, measured_ms INTEGER NOT NULL,
            PRIMARY KEY (file_id,day,source,model,kind,mode,evidence,provider)) WITHOUT ROWID;
        """;

    private void LoadModes(Dictionary<long, StoredFile> files)
    {
        using var rows = _connection.Prepare("SELECT file_id,day,source,model,kind,mode,evidence,provider,requests,output,measured_output,measured_ms FROM contribution_modes");
        while (rows.Step())
        {
            if (!files.TryGetValue(rows.GetInt64(0), out var file) || Key(rows.GetString(1), rows.GetString(2)) is not { } day
                || !file.Days.TryGetValue(day, out var aggregate) || !TryKind(rows.GetString(4), out var kind)) continue;
            var mode = rows.GetString(5);
            var evidence = rows.GetString(6);
            var provider = rows.GetString(7) ?? string.Empty;
            if (!ExecutionModes.IsIdentifier(mode, 64) || evidence is not ("served" or "recorded" or "selected" or "unknown")
                || ((mode == "unknown") != (evidence == "unknown"))
                || (provider.Length > 0 && !ExecutionModes.IsIdentifier(provider, 32))) continue;
            aggregate.Modes[new(rows.GetString(3) ?? string.Empty, kind, mode!, evidence!, provider)] =
                new(Math.Max(0, rows.GetInt64(8)), Math.Max(0, rows.GetInt64(9)), Math.Max(0, rows.GetInt64(10)), Math.Max(0, rows.GetInt64(11)));
        }
    }

    private void SaveModes(StoredFile file)
    {
        using var delete = _connection.Prepare("DELETE FROM contribution_modes WHERE file_id=?1");
        delete.Bind(1, file.Id).Run();
        using var insert = _connection.Prepare("INSERT INTO contribution_modes(file_id,day,source,model,kind,mode,evidence,provider,requests,output,measured_output,measured_ms) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)");
        foreach (var (day, aggregate) in file.Days)
        foreach (var (key, totals) in aggregate.Modes)
            insert.Bind(1, file.Id).Bind(2, day.Day).Bind(3, SourceNames.Of(day.Source)).Bind(4, key.Model)
                .Bind(5, ExecutionModes.Name(key.Kind)).Bind(6, key.Mode).Bind(7, key.Evidence).Bind(8, key.Provider)
                .Bind(9, totals.Requests).Bind(10, totals.Output).Bind(11, totals.MeasuredOutput).Bind(12, totals.MeasuredMs).Run();
    }

    private static bool TryKind(string? text, out ExecutionModeKind kind)
    {
        foreach (var value in Enum.GetValues<ExecutionModeKind>())
            if (ExecutionModes.Name(value) == text) { kind = value; return true; }
        kind = default;
        return false;
    }
}
