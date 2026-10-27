using AgentSpeed.Core.Antigravity;
using AgentSpeed.Core.IO.Sqlite;
using AgentSpeed.Core.Monitoring;
using AgentSpeed.Core.Parsing;
using AgentSpeed.Core.ZCode;

namespace AgentSpeed.Core.History;

internal sealed partial class HistoryAnalyzer
{
    private sealed record PlannedZCodeSession(string Id, List<ParsedResponse> Responses, long Size, long Modified, StoredFile? Previous);

    private void PlanZCode(Plan plan, SourceLocations locations, IReadOnlySet<SourceKind> enabled, bool zoneChanged, bool repricing,
        CancellationToken cancellationToken)
    {
        if (!enabled.Contains(SourceKind.ZCode) || locations.ZCodeRoot.Length == 0)
        {
            return;
        }

        var path = ZCodeDatabase.DatabasePath(locations.ZCodeRoot);
        if (AntigravityStamp.Of(path) is not { } stamp)
        {
            return;
        }

        try
        {
            using var database = ZCodeDatabase.Open(path);
            foreach (var group in database.Read(cancellationToken: cancellationToken).GroupBy(r => r.SessionId))
            {
                var id = path + "#" + group.Key;
                plan.Discovered++;
                var previous = _entries.GetValueOrDefault(id);
                if (previous is not null && !zoneChanged && previous.Version == _options.Version && previous.Family == "zcode"
                    && previous.Size == stamp.Length && previous.Modified == stamp.LastWriteUtc.Ticks && !(repricing && previous.HasUnpriced))
                {
                    continue;
                }

                plan.ZCodeSessions.Add(new PlannedZCodeSession(id,
                    [.. group.Select(row => row.Response(path)).OfType<ParsedResponse>()], stamp.Length, stamp.LastWriteUtc.Ticks, previous));
            }
        }
        catch (InvalidDataException)
        {
        }
        catch (Exception error) when (error is SqliteException or IOException or UnauthorizedAccessException)
        {
            plan.ZCodeFailed = true;
        }
    }

    private bool AnalyzeZCodeSessions(List<PlannedZCodeSession> sessions, KeyLedger ledger, DayLabeler labeler,
        List<(StoredFile, ulong[])> pending, Action<bool> flush, ref HistoryProgress state, ref int analyzed,
        Action<HistoryProgress>? progress, CancellationToken cancellationToken)
    {
        foreach (var session in sessions)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                return false;
            }

            var responses = new Dictionary<string, ParsedResponse>(StringComparer.Ordinal);
            foreach (var response in session.Responses)
            {
                if (ledger.TryClaim(response.Key, session.Id, out var owner) || string.Equals(owner, session.Id, StringComparison.Ordinal))
                {
                    responses[response.Key] = response;
                }
            }

            var entry = new StoredFile
            {
                Id = session.Previous?.Id ?? 0, Path = session.Id, Family = "zcode", Size = session.Size, Modified = session.Modified,
                Version = _options.Version, Days = DayAggregate.Contributions(responses.Values, SourceKind.ZCode, labeler, Pricing),
            };
            _entries[session.Id] = entry;
            pending.Add((entry, ledger.FinishFile()));
            analyzed++;
            state = state with { FilesDone = state.FilesDone + 1 };
            flush(false);
            progress?.Invoke(state);
        }

        return true;
    }
}
