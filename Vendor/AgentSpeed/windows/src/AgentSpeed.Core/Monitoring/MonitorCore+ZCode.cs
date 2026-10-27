using AgentSpeed.Core.Engine;
using AgentSpeed.Core.ZCode;

namespace AgentSpeed.Core.Monitoring;

internal sealed partial class MonitorCore
{
    private ZCodeSource? _zcode;
    private SourceRoot? _zcodeRoot;
    private string _zcodeRootPath = string.Empty;
    private bool _zcodeSeeded;

    private void InitializeZCode(SourceLocations locations)
    {
        _zcodeRootPath = locations.ZCodeRoot;
        if (_enabled.Contains(SourceKind.ZCode) && locations.ZCodeRoot.Length > 0)
        {
            _zcode = new ZCodeSource(locations.ZCodeRoot, _deduper);
            _zcodeRoot = new SourceRoot(RootFamily.ZCode, _zcode.WatchDirectory, enabled: true);
        }
    }

    private void RefreshZCodeAvailability()
    {
        if (_zcode is not null)
        {
            if (_zcodeRoot?.Path != _zcode.WatchDirectory)
            {
                _zcodeRoot = new SourceRoot(RootFamily.ZCode, _zcode.WatchDirectory, enabled: true);
            }

            _zcodeRoot.Available = _zcode.Available;
        }
    }

    private void SeedZCode(long todayStartMs)
    {
        if (_zcode is not null && !_zcodeSeeded)
        {
            ApplyZCode(_zcode.Seed(todayStartMs), seeded: true);
            _zcodeSeeded = true;
        }
    }

    private bool RefreshZCode()
    {
        RefreshZCodeAvailability();
        return _zcode is not null && ApplyZCode(_zcode.Refresh(), seeded: false);
    }

    private bool ApplyZCode(ZCodeUpdate update, bool seeded)
    {
        foreach (var id in update.Removed)
        {
            _engine.RemoveAgent(id);
            _linksChanged |= _links.Remove(id);
        }

        foreach (var state in update.Agents)
        {
            var link = new AgentLink(state.Id, LinkKind.ZCodeSession, state.SessionId, state.ParentSessionId, state.CreatedMs);
            if (!_links.TryGetValue(state.Id, out var previous) || previous != link)
            {
                _links[state.Id] = link;
                _linksChanged = true;
            }

            _engine.UpdateAgent(new AgentInfo(state.Id, SourceKind.ZCode, state.Project, state.Model,
                state.ParentSessionId is not null, state.Phase, state.StartMs, state.LastMs, _parents.GetValueOrDefault(state.Id)) { Modes = state.Modes });
        }

        long? liveNow = seeded ? null : Clock();
        foreach (var (response, completion) in update.Responses)
        {
            _responsesSeen++;
            _engine.Upsert(response, completion, seeded, liveNow);
            _observer?.OnResponse(response, completion, seeded);
        }

        return update.Changed;
    }
}
