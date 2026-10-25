namespace AgentSpeed.Core.Engine;

internal sealed partial class TodayLedger
{
    private readonly Dictionary<(SourceKind Source, ExecutionModeKey Key), ExecutionModeTotals> _modes = [];
    private IReadOnlyList<ExecutionModeUsage>? _modeRows;

    public IReadOnlyList<ExecutionModeUsage> Modes => _modeRows ??= ExecutionModeUsage.Combine(_modes.Select(p =>
        new ExecutionModeUsage(p.Key.Key.Model, p.Key.Source, p.Key.Key.Kind, p.Key.Key.Mode, p.Key.Key.Evidence,
            p.Key.Key.Provider.Length == 0 ? null : p.Key.Key.Provider, p.Value.Requests, p.Value.Output, p.Value.MeasuredOutput, p.Value.MeasuredMs)));

    private void ResetModes() { _modes.Clear(); _modeRows = null; }

    private void ApplyModes(in Entry entry, int sign)
    {
        foreach (var kind in Enum.GetValues<ExecutionModeKind>())
        {
            var key = (entry.Source, ExecutionModeKey.Of(entry.Model, entry.Modes.Attribute(kind)));
            var measured = entry.Measured is not null;
            var amount = new ExecutionModeTotals(sign * entry.Requests, sign * entry.Tokens.Output,
                measured ? sign * entry.Tokens.Output : 0, sign * (entry.Measured?.DurationMs ?? 0));
            var value = _modes.GetValueOrDefault(key) + amount;
            if (value == default) _modes.Remove(key);
            else _modes[key] = value;
        }
        _modeRows = null;
    }
}
