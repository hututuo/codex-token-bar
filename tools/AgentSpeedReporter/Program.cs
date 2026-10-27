using System.Text;
using System.Text.Json;
using AgentSpeed.Core;
using CodexTokenBar.LocalSource;
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
        var protocolOutput = new LocalSourceProtocolOutput(output);
        using var sourceReadPipe = new LocalSourceReadPipe(input, protocolOutput.WriteLine);
        var status = new StatusEmitter(protocolOutput);
        var parentWatch = WatchSourcePipeAsync(sourceReadPipe.Start(), lifetime);
        try
        {
            await ReporterRuntime.RunAsync(start, status, sourceReadPipe, lifetime.Token).ConfigureAwait(false);
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
            sourceReadPipe.Dispose();
            try
            {
                await parentWatch.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }
        }
    }

    private static async Task WatchSourcePipeAsync(Task pipeCompletion, CancellationTokenSource lifetime)
    {
        await pipeCompletion.ConfigureAwait(false);
        if (!lifetime.IsCancellationRequested)
        {
            lifetime.Cancel();
        }
    }
}

internal static class SelfTests
{
    public static async Task<int> RunAsync()
    {
        try
        {
            await LocalSourceReadPipeSelfTests.RunAsync().ConfigureAwait(false);
            await DefaultOffDoesNotStartAsync().ConfigureAwait(false);
            await InvalidShortUsernameDoesNotStartAsync().ConfigureAwait(false);
            await InvalidSourcePolicyDoesNotStartAsync().ConfigureAwait(false);
            await LegacyStartFrameIsCompatibleAsync().ConfigureAwait(false);
            await LocalSourceRootsAreAcceptedAsync().ConfigureAwait(false);
            await InvalidLocalSourceRootsAreRejectedAsync().ConfigureAwait(false);
            await StartFrameByteLimitIsPreservedAsync().ConfigureAwait(false);
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

    private static async Task LegacyStartFrameIsCompatibleAsync()
    {
        var start = await ReadStartAsync(CreateStartFrame()).ConfigureAwait(false);
        if (start is null
            || start.Username != "TokenBar-1234"
            || !start.DeniedSourceIds.SetEquals(["claudeCode", "claudeDesktop"])
            || start.LocalSourceRoots.Count != 0)
        {
            throw new InvalidOperationException();
        }
    }

    private static async Task LocalSourceRootsAreAcceptedAsync()
    {
        var roots = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["deepseek"] = @"C:\Users\Test\.deepseek\sessions",
            ["gemini"] = @"\\?\D:\Users\Test\.gemini",
            ["opencode"] = "E:/Users/Test/.local/share/opencode",
        };
        var start = await ReadStartAsync(CreateStartFrame(roots)).ConfigureAwait(false);
        if (start is null
            || start.LocalSourceRoots.Count != 3
            || start.LocalSourceRoots["deepseek"] != roots["deepseek"]
            || start.LocalSourceRoots["gemini"] != roots["gemini"]
            || start.LocalSourceRoots["opencode"] != roots["opencode"]
            || !start.DeniedSourceIds.SetEquals(["claudeCode", "claudeDesktop"]))
        {
            throw new InvalidOperationException();
        }

        var atLimit = @"C:\" + new string('a', 1021);
        var acceptedAtLimit = await ReadStartAsync(CreateStartFrame(new Dictionary<string, string> { ["deepseek"] = atLimit }))
            .ConfigureAwait(false);
        if (acceptedAtLimit is null || acceptedAtLimit.LocalSourceRoots["deepseek"].Length != 1024)
        {
            throw new InvalidOperationException();
        }
    }

    private static async Task InvalidLocalSourceRootsAreRejectedAsync()
    {
        var invalid = new (string Source, string Path)[]
        {
            ("claudeCode", @"C:\Users\Test\.claude"),
            ("claudeDesktop", @"C:\Users\Test\.claude"),
            ("codex", @"C:\Users\Test\.codex"),
            ("deepseek", @"\\server\share"),
            ("deepseek", @"\\?\UNC\server\share"),
            ("deepseek", @"\\.\C:\Users\Test"),
            ("deepseek", @"\\?\GLOBALROOT\Device\HarddiskVolume1"),
            ("deepseek", @"C:relative"),
            ("deepseek", string.Empty),
            ("deepseek", "C:\\Users\\Test\\bad\u0001path"),
            ("deepseek", @"C:\" + new string('a', 1022)),
        };
        foreach (var (source, path) in invalid)
        {
            var command = CreateStartFrame(new Dictionary<string, string> { [source] = path });
            if (await ReadStartAsync(command).ConfigureAwait(false) is not null)
            {
                throw new InvalidOperationException();
            }
        }

        const string fourEntries = "{\"enabled\":true,\"username\":\"TokenBar-1234\",\"deniedSourceIds\":[\"claudeCode\",\"claudeDesktop\"],\"localSourceRoots\":{\"deepseek\":\"C:\\\\a\",\"gemini\":\"C:\\\\b\",\"opencode\":\"C:\\\\c\",\"deepseek\":\"C:\\\\d\"}}";
        const string nonObject = "{\"enabled\":true,\"username\":\"TokenBar-1234\",\"deniedSourceIds\":[\"claudeCode\",\"claudeDesktop\"],\"localSourceRoots\":null}";
        if (await ReadStartAsync(fourEntries).ConfigureAwait(false) is not null
            || await ReadStartAsync(nonObject).ConfigureAwait(false) is not null)
        {
            throw new InvalidOperationException();
        }
    }

    private static async Task StartFrameByteLimitIsPreservedAsync()
    {
        var frame = CreateStartFrame();
        var belowLimit = frame + new string(' ', StatusProtocol.MaxInputBytes - 1 - Encoding.UTF8.GetByteCount(frame));
        if (await ReadStartAsync(belowLimit).ConfigureAwait(false) is null)
        {
            throw new InvalidOperationException();
        }

        var atLimit = frame + new string(' ', StatusProtocol.MaxInputBytes - Encoding.UTF8.GetByteCount(frame));
        if (await ReadStartAsync(atLimit).ConfigureAwait(false) is not null)
        {
            throw new InvalidOperationException();
        }
    }

    private static string CreateStartFrame(IReadOnlyDictionary<string, string>? localSourceRoots = null)
    {
        var rootsProperty = localSourceRoots is null
            ? string.Empty
            : ",\"localSourceRoots\":" + JsonSerializer.Serialize(localSourceRoots);
        return "{\"enabled\":true,\"username\":\"TokenBar-1234\",\"deniedSourceIds\":[\"claudeCode\",\"claudeDesktop\"]" + rootsProperty + "}";
    }

    private static async Task<StartCommand?> ReadStartAsync(string json)
    {
        await using var input = new MemoryStream(Encoding.UTF8.GetBytes(json + "\n"));
        return await StatusProtocol.ReadStartCommandAsync(input).ConfigureAwait(false);
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
