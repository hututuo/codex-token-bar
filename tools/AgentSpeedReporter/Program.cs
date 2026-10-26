using System.Text;
using AgentSpeed.Core;
using AgentSpeed.Core.Reporting;

namespace CodexTokenBar.AgentSpeedReporter;

internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--self-test")
        {
            return await SelfTests.RunAsync().ConfigureAwait(false);
        }

        var input = Console.OpenStandardInput();
        var output = Console.OpenStandardOutput();
        Console.SetOut(TextWriter.Null);
        Console.SetError(TextWriter.Null);

        var start = await StatusProtocol.ReadStartCommandAsync(input).ConfigureAwait(false);
        if (start is null)
        {
            // A disabled or malformed first line performs no scan and makes no network request.
            return 0;
        }

        if (!OperatingSystem.IsWindows())
        {
            return 64;
        }

        using var lifetime = new CancellationTokenSource();
        var status = new StatusEmitter(output);
        var parentWatch = StatusProtocol.WatchParentExitAsync(input, lifetime);
        try
        {
            await ReporterRuntime.RunAsync(start, status, lifetime.Token).ConfigureAwait(false);
            return 0;
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
            return 0;
        }
        catch (ReporterFailure failure)
        {
            await status.PublishErrorAsync(failure.Code, CancellationToken.None).ConfigureAwait(false);
            return 1;
        }
        catch (Exception)
        {
            await status.PublishErrorAsync("reporting_failed", CancellationToken.None).ConfigureAwait(false);
            return 1;
        }
        finally
        {
            lifetime.Cancel();
            try
            {
                await parentWatch.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }
        }
    }
}

internal static class SelfTests
{
    public static async Task<int> RunAsync()
    {
        try
        {
            await DefaultOffDoesNotStartAsync().ConfigureAwait(false);
            await InvalidShortUsernameDoesNotStartAsync().ConfigureAwait(false);
            await InvalidSourcePolicyDoesNotStartAsync().ConfigureAwait(false);
            await ParentEofCancelsAsync().ConfigureAwait(false);
            SourcePolicyIsDefaultDeniedByKind();
            PayloadIsWhitelisted();
            InitialSnapshotIsOnlyABaseline();
            Console.WriteLine("PASS: Agent Speed reporter local tests");
            return 0;
        }
        catch (Exception)
        {
            Console.WriteLine("FAIL: Agent Speed reporter local tests");
            return 1;
        }
    }

    private static async Task DefaultOffDoesNotStartAsync()
    {
        await using var input = new MemoryStream(Encoding.UTF8.GetBytes("{\"enabled\":false,\"username\":\"TokenBar-1234\",\"deniedSourceIds\":[\"claudeCode\",\"claudeDesktop\"]}\n"));
        if (await StatusProtocol.ReadStartCommandAsync(input).ConfigureAwait(false) is not null)
        {
            throw new InvalidOperationException();
        }
    }

    private static async Task InvalidShortUsernameDoesNotStartAsync()
    {
        await using var input = new MemoryStream(Encoding.UTF8.GetBytes("{\"enabled\":true,\"username\":\"x\",\"deniedSourceIds\":[\"claudeCode\",\"claudeDesktop\"]}\n"));
        if (await StatusProtocol.ReadStartCommandAsync(input).ConfigureAwait(false) is not null)
        {
            throw new InvalidOperationException();
        }
    }

    private static async Task InvalidSourcePolicyDoesNotStartAsync()
    {
        await using var missing = new MemoryStream(Encoding.UTF8.GetBytes("{\"enabled\":true,\"username\":\"TokenBar-1234\"}\n"));
        await using var altered = new MemoryStream(Encoding.UTF8.GetBytes("{\"enabled\":true,\"username\":\"TokenBar-1234\",\"deniedSourceIds\":[\"claudeCode\",\"claudeCode\"]}\n"));
        if (await StatusProtocol.ReadStartCommandAsync(missing).ConfigureAwait(false) is not null
            || await StatusProtocol.ReadStartCommandAsync(altered).ConfigureAwait(false) is not null)
        {
            throw new InvalidOperationException();
        }
    }

    private static async Task ParentEofCancelsAsync()
    {
        using var lifetime = new CancellationTokenSource();
        await StatusProtocol.WatchParentExitAsync(new MemoryStream(), lifetime).ConfigureAwait(false);
        if (!lifetime.IsCancellationRequested)
        {
            throw new InvalidOperationException();
        }
    }

    private static void PayloadIsWhitelisted()
    {
        const string allowed = "{\"schema\":1,\"client\":{},\"deviceId\":\"id\",\"username\":\"TokenBar-1234\",\"run\":{},\"sentAt\":\"2026-01-01T00:00:00Z\",\"windowMs\":0,\"activity\":\"idle\",\"live\":{},\"peak\":{},\"delta\":{},\"title\":{},\"sources\":[],\"models\":[{\"sources\":[\"codex\"],\"harnessRequests\":[],\"modeUsage\":[]}]}";
        const string withTraffic = "{\"schema\":1,\"sources\":[{\"traffic\":{}}]}";
        const string withCost = "{\"schema\":1,\"models\":[{\"cost\":{}}]}";
        const string codexOnly = "{\"schema\":1,\"sources\":[{\"source\":\"codex\"}],\"models\":[{\"sources\":[\"codex\"]}]}";
        const string claudeCode = "{\"schema\":1,\"sources\":[{\"source\":\"claudeCode\"}],\"models\":[]}";
        const string claudeDesktop = "{\"schema\":1,\"sources\":[{\"source\":\"claudeDesktop\"}],\"models\":[]}";
        const string mixed = "{\"schema\":1,\"sources\":[{\"source\":\"codex\"},{\"source\":\"claudeCode\"}],\"models\":[]}";
        const string unattributed = "{\"schema\":1,\"delta\":{\"requests\":10}}";
        if (!ReportPayloadWhitelist.IsAllowed(Encoding.UTF8.GetBytes(allowed))
            || !ReportPayloadWhitelist.IsAllowed(Encoding.UTF8.GetBytes(codexOnly))
            || ReportPayloadWhitelist.IsAllowed(Encoding.UTF8.GetBytes(withTraffic))
            || ReportPayloadWhitelist.IsAllowed(Encoding.UTF8.GetBytes(withCost)))
        {
            throw new InvalidOperationException();
        }

        if (ReportPayloadWhitelist.IsAllowed(Encoding.UTF8.GetBytes(claudeCode))
            || ReportPayloadWhitelist.IsAllowed(Encoding.UTF8.GetBytes(claudeDesktop))
            || ReportPayloadWhitelist.IsAllowed(Encoding.UTF8.GetBytes(mixed))
            || ReportPayloadWhitelist.IsAllowed(Encoding.UTF8.GetBytes(unattributed)))
        {
            throw new InvalidOperationException();
        }
    }

    private static void SourcePolicyIsDefaultDeniedByKind()
    {
        if (!AgentSpeedReportSourcePolicy.IsReportable(SourceKind.Codex)
            || !AgentSpeedReportSourcePolicy.IsReportable(SourceKind.DeepSeek)
            || AgentSpeedReportSourcePolicy.IsReportable(SourceKind.ClaudeCode)
            || AgentSpeedReportSourcePolicy.IsReportable(SourceKind.ClaudeDesktop)
            || AgentSpeedReportSourcePolicy.ReportableSources.Count != Enum.GetValues<SourceKind>().Length - 2
            || !AgentSpeedReportSourcePolicy.HasRequiredDenyList(["claudeCode", "claudeDesktop"])
            || AgentSpeedReportSourcePolicy.HasRequiredDenyList(["claudeCode", "claudeCode"]))
        {
            throw new InvalidOperationException();
        }
    }

    private static void InitialSnapshotIsOnlyABaseline()
    {
        var counters = new ReportCounters();
        counters.Add(new ReportUsage(Requests: 3, Input: 40, Output: 20), new ReportModelKey("gpt-5", SourceKind.Codex));
        var facts = new ReportLiveFacts(
            new Dictionary<SourceKind, ReportAgentCounts>(),
            new Dictionary<ReportModelKey, int>(),
            counters,
            Epoch: 7);
        var sample = ReportSample.Empty with { Facts = facts };
        var window = new ReportWindow(sample);
        if (window.Content(sample).Usage.Total != ReportUsage.Zero)
        {
            throw new InvalidOperationException();
        }
    }
}
