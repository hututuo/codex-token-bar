using System.Security.Cryptography;
using System.Text.Json;
using AgentSpeed.Core;
using AgentSpeed.Core.IO;
using CodexTokenBar.LocalSource;

namespace ClaudeLocalReader;

internal static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false,
    };

    private static async Task<int> Main(string[] args)
    {
        try
        {
            var options = ParseArguments(args);
            if (options.SelfTest)
            {
                await RunSelfTestsAsync().ConfigureAwait(false);
                Console.Out.WriteLine("ClaudeLocalReader self-test passed.");
                return 0;
            }

            if (options.CaptureStatusline)
            {
                await StatuslineCache.ReadAndCacheAsync(Console.OpenStandardInput(), CancellationToken.None)
                    .ConfigureAwait(false);
                Console.Out.WriteLine("Claude · Token Bar 本地读取");
                return 0;
            }

            if (!string.IsNullOrWhiteSpace(options.Root) && options.CaptureStatusline)
            {
                throw new ArgumentException("--root cannot be combined with --capture-statusline.");
            }

            await RunRuntimeAsync(options).ConfigureAwait(false);
            return 0;
        }
        catch (OperationCanceledException)
        {
            return 0;
        }
        catch (Exception)
        {
            // Do not echo source paths, captured content, or parser details into helper stdout.
            Console.Error.WriteLine("ClaudeLocalReader failed; local input was not published.");
            return 2;
        }
    }

    private static async Task RunRuntimeAsync(Options options)
    {
        var enabled = options.Sources;
        var claudeRoot = enabled.Any(IsClaudeSource)
            ? Path.GetFullPath(options.Root ?? LiveMonitor.DefaultClaudeRoot)
            : null;
        var codexRoot = enabled.Contains(SourceKind.Codex)
            ? Path.GetFullPath(options.CodexRoot ?? LiveMonitor.DefaultCodexRoot)
            : null;
        if (claudeRoot is not null)
        {
            EnsureLocalPath(claudeRoot, "Claude");
        }
        if (codexRoot is not null)
        {
            EnsureLocalPath(codexRoot, "Codex");
        }

        foreach (var path in options.OtherRoots.Values) { EnsureLocalPath(Path.GetFullPath(path), "Activity"); }
        var configuration = new MonitorConfiguration(enabled, CodexRoot: codexRoot, ClaudeRoot: claudeRoot,
            DshRoot: options.OtherRoots.GetValueOrDefault(SourceKind.DeepSeek),
            OpenCodeRoot: options.OtherRoots.GetValueOrDefault(SourceKind.OpenCode),
            GeminiRoot: options.OtherRoots.GetValueOrDefault(SourceKind.Gemini));
        var hub = new SpeedHub(context: null);
        var processSalt = RandomNumberGenerator.GetBytes(32);
        var latest = new SnapshotCell();
        var responseEvents = new ResponseEventBuffer();
        var firstReady = new TaskCompletionSource<SpeedSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        hub.LivePublished += (_, snapshot) =>
        {
            latest.Update(snapshot);
            if (snapshot.State.Kind != MonitorStateKind.Starting)
            {
                firstReady.TrySetResult(snapshot);
            }
        };
        hub.EventRaised += (_, speedEvent) =>
        {
            if (speedEvent is SpeedEvent.ResponseCompleted completed)
            {
                responseEvents.Add(completed.Response);
            }
        };

        using var lifetime = new CancellationTokenSource();
        var protocolOutput = new LocalSourceProtocolOutput(Console.OpenStandardOutput());
        using var sourceReadPipe = options.Watch && Console.IsInputRedirected
            ? new LocalSourceReadPipe(Console.OpenStandardInput(), protocolOutput.WriteLine)
            : null;
        using var monitor = new LiveMonitor(hub, configuration, readBackend: sourceReadPipe);
        ConsoleCancelEventHandler cancelHandler = (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            lifetime.Cancel();
        };
        Console.CancelKeyPress += cancelHandler;
        Task? parentWatch = null;
        if (sourceReadPipe is not null)
        {
            parentWatch = WatchSourcePipeAsync(sourceReadPipe.Start(), lifetime);
        }

        try
        {
            monitor.Start();
            var ready = await WaitForReadySnapshotAsync(firstReady.Task, lifetime.Token).ConfigureAwait(false);
            WriteSnapshot(protocolOutput, RuntimeSnapshotMapper.Map(ready, processSalt, enabled, responseEvents.Read()));
            if (!options.Watch)
            {
                return;
            }

            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
            while (await timer.WaitForNextTickAsync(lifetime.Token).ConfigureAwait(false))
            {
                WriteSnapshot(protocolOutput, RuntimeSnapshotMapper.Map(latest.Read(), processSalt, enabled, responseEvents.Read()));
            }
        }
        finally
        {
            lifetime.Cancel();
            monitor.Dispose();
            sourceReadPipe?.Dispose();
            Console.CancelKeyPress -= cancelHandler;
            if (parentWatch is not null)
            {
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

    private static async Task<SpeedSnapshot> WaitForReadySnapshotAsync(
        Task<SpeedSnapshot> firstReady,
        CancellationToken cancellationToken)
    {
        var timeout = Task.Delay(TimeSpan.FromSeconds(30), cancellationToken);
        var completed = await Task.WhenAny(firstReady, timeout).ConfigureAwait(false);
        if (completed == firstReady)
        {
            return await firstReady.ConfigureAwait(false);
        }

        cancellationToken.ThrowIfCancellationRequested();
        throw new TimeoutException("The local Claude monitor did not publish its initial snapshot.");
    }

    private static async Task WatchSourcePipeAsync(Task pipeCompletion, CancellationTokenSource lifetime)
    {
        await pipeCompletion.ConfigureAwait(false);
        if (!lifetime.IsCancellationRequested)
        {
            lifetime.Cancel();
        }
    }

    private static void WriteSnapshot(LocalSourceProtocolOutput output, RuntimeSnapshot snapshot)
    {
        output.WriteLine(JsonSerializer.SerializeToUtf8Bytes(snapshot, JsonOptions));
    }

    private static Options ParseArguments(string[] args)
    {
        var watch = false;
        var once = false;
        var captureStatusline = false;
        var selfTest = false;
        var sourceWasSpecified = false;
        var sources = new HashSet<SourceKind>();
        string? root = null;
        string? codexRoot = null;
        var otherRoots = new Dictionary<SourceKind, string>();
        for (var index = 0; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--once":
                    once = true;
                    break;
                case "--watch":
                    watch = true;
                    break;
                case "--capture-statusline":
                    captureStatusline = true;
                    break;
                case "--self-test":
                    selfTest = true;
                    break;
                case "--root" when index + 1 < args.Length:
                    if (root is not null)
                    {
                        throw new ArgumentException("--root may be provided only once.");
                    }

                    root = args[++index];
                    if (string.IsNullOrWhiteSpace(root))
                    {
                        throw new ArgumentException("--root requires a local directory path.");
                    }

                    break;
                case "--codex-root" when index + 1 < args.Length:
                    if (codexRoot is not null)
                    {
                        throw new ArgumentException("--codex-root may be provided only once.");
                    }

                    codexRoot = args[++index];
                    if (string.IsNullOrWhiteSpace(codexRoot))
                    {
                        throw new ArgumentException("--codex-root requires a local directory path.");
                    }

                    break;
                case "--dsh-root" or "--gemini-root" or "--opencode-root" when index + 1 < args.Length:
                    var rootSource = args[index] switch {
                        "--dsh-root" => SourceKind.DeepSeek,
                        "--gemini-root" => SourceKind.Gemini,
                        _ => SourceKind.OpenCode,
                    };
                    if (!otherRoots.TryAdd(rootSource, args[++index]) || string.IsNullOrWhiteSpace(args[index]))
                        throw new ArgumentException("A local source root may be specified only once.");
                    break;
                case "--source" when index + 1 < args.Length:
                    sourceWasSpecified = true;
                    var source = args[++index] switch
                    {
                        "codex" => SourceKind.Codex,
                        "deepseek" => SourceKind.DeepSeek,
                        "gemini" => SourceKind.Gemini,
                        "opencode" => SourceKind.OpenCode,
                        "claudeCode" => SourceKind.ClaudeCode,
                        "claudeDesktop" => SourceKind.ClaudeDesktop,
                        _ => throw new ArgumentException("Only supported local sources are allowed."),
                    };
                    sources.Add(source);
                    break;
                default:
                    throw new ArgumentException("Unknown or incomplete helper argument.");
            }
        }

        if ((watch && once)
            || (captureStatusline && (watch || once || root is not null || codexRoot is not null || otherRoots.Count > 0 || sourceWasSpecified))
            || (selfTest && (watch || once || captureStatusline || root is not null || codexRoot is not null || otherRoots.Count > 0 || sourceWasSpecified)))
        {
            throw new ArgumentException("Helper modes cannot be combined.");
        }

        if (sourceWasSpecified && sources.Count == 0)
        {
            throw new ArgumentException("At least one local source is required.");
        }
        if (!sourceWasSpecified)
        {
            sources = [SourceKind.ClaudeCode, SourceKind.ClaudeDesktop];
        }
        if (root is not null && !sources.Any(IsClaudeSource))
        {
            throw new ArgumentException("--root requires a Claude source.");
        }
        if (codexRoot is not null && !sources.Contains(SourceKind.Codex))
        {
            throw new ArgumentException("--codex-root requires --source codex.");
        }

        if (otherRoots.Keys.Any(source => !sources.Contains(source)))
            throw new ArgumentException("A source root requires its corresponding --source.");
        return new Options(watch, captureStatusline, selfTest, root, codexRoot, sources, otherRoots);
    }

    private static bool IsClaudeSource(SourceKind source) =>
        source is SourceKind.ClaudeCode or SourceKind.ClaudeDesktop;

    private static void EnsureLocalPath(string path, string sourceName)
    {
        if (!HasAllowedLocalRootPathSyntax(path))
        {
            throw new ArgumentException("Only local filesystem paths are supported.");
        }

        LocalSourcePathPolicy.EnsureReadablePath(path);
        var fullPath = Path.GetFullPath(path);
        var current = Path.GetPathRoot(fullPath);
        if (string.IsNullOrEmpty(current))
        {
            throw new ArgumentException($"{sourceName} root must be a local filesystem path.");
        }

        foreach (var component in fullPath[current.Length..].Split(
            [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, component);
            if (!Directory.Exists(current) && !File.Exists(current))
            {
                break;
            }

            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
            {
                throw new ArgumentException("Claude root cannot include a reparse point or symbolic link.");
            }
        }
    }

    private static bool HasAllowedLocalRootPathSyntax(string path)
    {
        const string extendedPrefix = @"\\?\";
        if (path.StartsWith(extendedPrefix, StringComparison.Ordinal))
        {
            // Windows canonicalization can preserve this extended-length local drive form.
            // Do not permit UNC, device, volume, or GLOBALROOT namespaces through this prefix.
            return IsDriveRootedPath(path, extendedPrefix.Length);
        }

        if (path.StartsWith(@"\\", StringComparison.Ordinal) || path.StartsWith("//", StringComparison.Ordinal))
        {
            return false;
        }

        return IsDriveRootedPath(path, 0) || Path.IsPathFullyQualified(path);
    }

    private static bool IsDriveRootedPath(string path, int start) =>
        path.Length >= start + 3
        && ((path[start] is >= 'A' and <= 'Z') || (path[start] is >= 'a' and <= 'z'))
        && path[start + 1] == ':'
        && path[start + 2] is '\\' or '/';

    private static async Task RunSelfTestsAsync()
    {
        const string input = """
            {
              "schema_version": 1,
              "captured_at_epoch": 1700000000.25,
              "session_id": "local-session",
              "model": { "id": "claude-sonnet-4-6", "display_name": "Claude Sonnet", "path": "drop-me" },
              "rate_limits": {
                "five_hour": { "used_percentage": 12.5, "resets_at": 1900000000.2, "token": "drop-me" },
                "seven_day": { "used_percentage": 20, "resets_at": "2030-03-17T17:46:40Z" },
                "spend_limit": null,
                "unknown_window": { "used_percentage": 99 }
              },
              "cost": { "total_api_duration_ms": 1200, "total_duration_ms": 1400, "credential": "drop-me" },
              "context_window": {
                "context_window_size": 200000,
                "total_input_tokens": 1000,
                "total_output_tokens": 20,
                "current_usage": {
                  "input_tokens": 400,
                  "output_tokens": 10,
                  "cache_creation_input_tokens": 30,
                  "cache_read_input_tokens": 250,
                  "prompt": "drop-me"
                },
                "cwd": "drop-me"
              },
              "unknown": "drop-me"
            }
            """;
        const string rawStatusline = """
            {"session_id":"raw","model":{"id":"claude-sonnet"},"cost":{"total_api_duration_ms":1200},
             "context_window":{"current_usage":{"output_tokens":80}},"api_key":"discard"}
            """;
        var captured = StatuslineCache.Parse(System.Text.Encoding.UTF8.GetBytes(rawStatusline), fromStatusline: true);
        Require(captured.SchemaVersion == 1 && captured.SessionId == "raw", "raw Claude statusline normalization");
        Require(Math.Abs(captured.CapturedAtEpoch - DateTimeOffset.UtcNow.ToUnixTimeSeconds()) < 5, "local capture clock");
        Require(captured.ContextWindow?.CurrentUsage?.OutputTokens == 80, "per-response output preserved");
        ExpectInvalid(rawStatusline); // Disk reader remains strict about normalized metadata.
        var snapshot = StatuslineCache.Parse(System.Text.Encoding.UTF8.GetBytes(input));
        var normalized = JsonDocument.Parse(StatuslineCache.Serialize(snapshot));
        var root = normalized.RootElement;
        Require(root.GetProperty("schema_version").GetInt32() == 1, "schema version");
        Require(root.GetProperty("rate_limits").GetProperty("five_hour").GetProperty("resets_at").GetInt64() == 1_900_000_000, "numeric reset normalization");
        Require(root.GetProperty("rate_limits").GetProperty("seven_day").GetProperty("resets_at").GetInt64() == 1_900_000_000, "text reset normalization");
        Require(!root.TryGetProperty("unknown", out _), "unknown top-level field removal");
        Require(!root.GetProperty("model").TryGetProperty("path", out _), "unknown model field removal");
        Require(!root.GetProperty("context_window").TryGetProperty("cwd", out _), "unknown context field removal");

        ExpectInvalid("{\"schema_version\":1,\"captured_at_epoch\":1,\"rate_limits\":{\"five_hour\":{\"used_percentage\":101}}}");
        ExpectInvalid("{\"schema_version\":1,\"captured_at_epoch\":1,\"context_window\":{\"current_usage\":{\"input_tokens\":-1}}}");
        Require(HasAllowedLocalRootPathSyntax(@"C:\Users\Test\.codex\sessions"), "normal local drive path accepted");
        Require(HasAllowedLocalRootPathSyntax(@"\\?\C:\Users\Test\.codex\sessions"), "extended-length local drive path accepted");
        Require(HasAllowedLocalRootPathSyntax(@"\\?\d:/Users/Test/.codex/sessions"), "extended-length local drive path accepts forward separators");
        Require(!HasAllowedLocalRootPathSyntax(@"\\?\UNC\server\share"), "extended UNC rejected");
        Require(!HasAllowedLocalRootPathSyntax(@"\\.\C:\Users\Test"), "device namespace rejected");
        Require(!HasAllowedLocalRootPathSyntax(@"\\?\GLOBALROOT\Device\HarddiskVolume1"), "GLOBALROOT namespace rejected");
        Require(!HasAllowedLocalRootPathSyntax(@"\\server\share"), "UNC path rejected");
        Require(!HasAllowedLocalRootPathSyntax("//server/share"), "slash UNC path rejected");
        Require(!HasAllowedLocalRootPathSyntax(@"\\?\C:relative"), "drive-relative verbatim path rejected");
        Require(LocalSourcePathPolicy.IsLocalDriveType(2), "removable drives are local");
        Require(LocalSourcePathPolicy.IsLocalDriveType(3), "fixed drives are local");
        Require(LocalSourcePathPolicy.IsLocalDriveType(5), "CD-ROM drives are local and read-only");
        Require(LocalSourcePathPolicy.IsLocalDriveType(6), "RAM disks are local");
        Require(!LocalSourcePathPolicy.IsLocalDriveType(0), "unknown drives are rejected");
        Require(!LocalSourcePathPolicy.IsLocalDriveType(1), "unmounted drives are rejected");
        Require(!LocalSourcePathPolicy.IsLocalDriveType(4), "mapped network drives are rejected");
        try
        {
            StatuslineCache.Parse(new byte[StatuslineCache.MaximumInputBytes + 1]);
            throw new InvalidOperationException("input limit test failed");
        }
        catch (InvalidDataException)
        {
        }

        var mapped = RuntimeSnapshotMapper.Map(CreateSampleSnapshot(), RandomNumberGenerator.GetBytes(32));
        Require(mapped.Client == "claude", "runtime client mapping");
        Require(mapped.MainAgents.Count == 1 && mapped.Subagents.Count == 1, "main/subagent mapping");
        Require(mapped.MainAgents[0].Id.StartsWith("agent-", StringComparison.Ordinal), "opaque runtime id");
        Require(mapped.Subagents[0].ParentId == mapped.MainAgents[0].Id, "opaque parent id mapping");
        Require(mapped.Subagents[0].Phase == "generating", "runtime phase mapping");
        Require(mapped.LatestResponse?.Client == "claudeCode", "legacy Claude latest-response mapping");

        var onlyCode = RuntimeSnapshotMapper.Map(
            CreateSampleSnapshot(),
            RandomNumberGenerator.GetBytes(32),
            new HashSet<SourceKind> { SourceKind.ClaudeCode });
        Require(onlyCode.SourceAvailable["claudeCode"] && !onlyCode.SourceAvailable["claudeDesktop"], "enabled source filtering");
        Require(onlyCode.MainAgents.Count == 1 && onlyCode.Subagents.Count == 1, "enabled Claude source attribution");

        var codexOnly = RuntimeSnapshotMapper.Map(
            CreateSampleSnapshot(),
            RandomNumberGenerator.GetBytes(32),
            new HashSet<SourceKind> { SourceKind.Codex },
            [new ResponseEventInput(1, new ResponseSummary(SourceKind.Codex, "private-project", null, 7, 11,
                TimeSpan.FromSeconds(3), 2.3, DateTimeOffset.UtcNow))]);
        Require(codexOnly.Client == "claude", "backward-compatible top-level client id");
        Require(codexOnly.SourceAvailable["codex"] && !codexOnly.SourceAvailable["claudeCode"], "Codex source opt-in mapping");
        Require(codexOnly.LiveOutputTps == 8 && codexOnly.LiveTotalTps == 10, "selected-source rate totals");
        Require(codexOnly.ModelRates.Count == 1 && codexOnly.ModelRates[0].Client == "codex"
            && codexOnly.ModelRates[0].Model == "unknown", "unknown Codex model retention");
        Require(codexOnly.MainAgents.Single().Client == "codex", "Codex task mapping");
        Require(codexOnly.LatestResponse is null, "latest-response filtering by selected source");
        var codexLatest = CreateSampleSnapshot() with
        {
            LastResponse = new ResponseSummary(SourceKind.Codex, "private-project", null, 7, 11,
                TimeSpan.FromSeconds(3), 2.3, DateTimeOffset.UtcNow),
        };
        var mappedCodexLatest = RuntimeSnapshotMapper.Map(
            codexLatest, RandomNumberGenerator.GetBytes(32), new HashSet<SourceKind> { SourceKind.Codex });
        Require(mappedCodexLatest.LatestResponse?.Client == "codex", "Codex latest-response mapping");
        Require(codexOnly.ResponseEvents.Count == 1 && codexOnly.ResponseEvents[0].Client == "codex"
            && codexOnly.ResponseEvents[0].Model is null, "bounded response event projection");
        Require(!codexOnly.ResponseEvents[0].Id.Contains("private", StringComparison.Ordinal), "response event id redaction");
        var codexJson = JsonSerializer.Serialize(codexOnly, JsonOptions);
        Require(!codexJson.Contains("private-project", StringComparison.Ordinal)
            && !codexJson.Contains("C:\\Users", StringComparison.Ordinal), "runtime path and project redaction");
        var manyResponses = Enumerable.Range(1, 40).Select(sequence => new ResponseEventInput(sequence,
            new ResponseSummary(SourceKind.Codex, "private-project", null, sequence, sequence + 1,
                TimeSpan.FromSeconds(1), 1, DateTimeOffset.UtcNow))).ToArray();
        var boundedEvents = RuntimeSnapshotMapper.Map(
            CreateSampleSnapshot(), RandomNumberGenerator.GetBytes(32),
            new HashSet<SourceKind> { SourceKind.Codex }, manyResponses);
        Require(boundedEvents.ResponseEvents.Count == 32, "bounded response event history");

        var modelSwitchBase = CreateSampleSnapshot();
        var switchedSession = modelSwitchBase.Agents.Single(agent => agent.Source == SourceKind.ClaudeCode && !agent.IsSubagent);
        var afterModelSwitch = modelSwitchBase with
        {
            Agents = modelSwitchBase.Agents.Select(agent => agent.Id == switchedSession.Id
                ? agent with { Model = "claude-opus-4-1" }
                : agent).ToArray(),
            LiveModels =
            [
                new SourceModelRate(SourceKind.ClaudeCode, "claude-sonnet-4-6", new Rate(0.5, 0.75)),
                new SourceModelRate(SourceKind.ClaudeCode, "claude-opus-4-1", new Rate(2.25, 3.0)),
            ],
        };
        var mappedModelSwitch = RuntimeSnapshotMapper.Map(
            afterModelSwitch,
            RandomNumberGenerator.GetBytes(32),
            new HashSet<SourceKind> { SourceKind.ClaudeCode });
        Require(mappedModelSwitch.MainAgents.Single().Model == "claude-opus-4-1", "session current model after switch");
        Require(mappedModelSwitch.ModelRates.Count(rate => rate.Model == "claude-sonnet-4-6") == 1
            && mappedModelSwitch.ModelRates.Single(rate => rate.Model == "claude-sonnet-4-6").OutputTps == 0.5
            && mappedModelSwitch.ModelRates.Single(rate => rate.Model == "claude-opus-4-1").OutputTps == 2.25,
            "previous-model live tail remains attributed across a session model switch");

        var sharedModelSnapshot = CreateSampleSnapshot() with
        {
            LiveModels =
            [
                new SourceModelRate(SourceKind.ClaudeCode, "shared-model", new Rate(2, 3)),
                new SourceModelRate(SourceKind.Codex, "shared-model", new Rate(5, 7)),
            ],
        };
        var mappedSharedModels = RuntimeSnapshotMapper.Map(
            sharedModelSnapshot,
            RandomNumberGenerator.GetBytes(32),
            new HashSet<SourceKind> { SourceKind.ClaudeCode, SourceKind.Codex });
        var sharedModelRates = mappedSharedModels.ModelRates.Where(rate => rate.Model == "shared-model").ToArray();
        Require(sharedModelRates.Length == 2
            && sharedModelRates.Single(rate => rate.Client == "claudeCode").OutputTps == 2
            && sharedModelRates.Single(rate => rate.Client == "codex").OutputTps == 5,
            "same-name model rates stay isolated by source");

        var defaultArguments = ParseArguments([]);
        Require(defaultArguments.Sources.Count == 2
            && defaultArguments.Sources.Contains(SourceKind.ClaudeCode)
            && defaultArguments.Sources.Contains(SourceKind.ClaudeDesktop), "default source set stays Claude-only");
        var codexArguments = ParseArguments(["--source", "codex", "--codex-root", "C:\\Users\\Test\\.codex\\sessions"]);
        Require(codexArguments.Sources.Count == 1
            && codexArguments.Sources.Contains(SourceKind.Codex)
            && codexArguments.CodexRoot is not null,
            "explicit Codex root CLI selection");
        var externalArguments = ParseArguments(
        [
            "--source", "deepseek", "--dsh-root", "C:\\Users\\Test\\.deepseek\\sessions",
            "--source", "gemini", "--gemini-root", "C:\\Users\\Test\\.gemini",
            "--source", "opencode", "--opencode-root", "C:\\Users\\Test\\.local\\share\\opencode",
        ]);
        Require(externalArguments.Sources.SetEquals([SourceKind.DeepSeek, SourceKind.Gemini, SourceKind.OpenCode])
            && externalArguments.OtherRoots.Count == 3
            && externalArguments.OtherRoots.ContainsKey(SourceKind.DeepSeek)
            && externalArguments.OtherRoots.ContainsKey(SourceKind.Gemini)
            && externalArguments.OtherRoots.ContainsKey(SourceKind.OpenCode),
            "explicit DeepSeek, Gemini, and OpenCode source roots");

        var externalBase = CreateSampleSnapshot();
        var externalSources = new[] { SourceKind.DeepSeek, SourceKind.Gemini, SourceKind.OpenCode };
        var externalSnapshot = externalBase with
        {
            Sources = externalBase.Sources.Concat(externalSources.Select((source, index) => new SourceStatus(
                source, true, "private-path", true, 1, new Rate(index + 1, index + 2), TokenTotals.Zero, 1))).ToArray(),
            Agents = externalBase.Agents.Concat(externalSources.Select((source, index) => new AgentStatus(
                $"private-external-{index}", source, "private-project", null, AgentPhase.Generating,
                false, new Rate(index + 1, index + 2), null, DateTimeOffset.UtcNow))).ToArray(),
            LiveModels = externalSources.Select((source, index) => new SourceModelRate(
                source, $"external-model-{index}", new Rate(index + 1, index + 2))).ToArray(),
        };
        var mappedExternalSources = RuntimeSnapshotMapper.Map(
            externalSnapshot,
            RandomNumberGenerator.GetBytes(32),
            externalSources.ToHashSet());
        Require(mappedExternalSources.SourceAvailable["deepseek"]
            && mappedExternalSources.SourceAvailable["gemini"]
            && mappedExternalSources.SourceAvailable["opencode"],
            "explicit external sources appear as available");
        Require(mappedExternalSources.LiveOutputTps == 6 && mappedExternalSources.LiveTotalTps == 9
            && mappedExternalSources.MainAgents.Select(agent => agent.Client).Order(StringComparer.Ordinal)
                .SequenceEqual(["deepseek", "gemini", "opencode"])
            && mappedExternalSources.ModelRates.Select(rate => rate.Client).Order(StringComparer.Ordinal)
                .SequenceEqual(["deepseek", "gemini", "opencode"]),
            "external source totals, agents, and models map by source");

        var sample = CreateSampleSnapshot();
        var staleIdle = new AgentStatus(
            "C:\\Users\\someone\\.claude\\projects\\old.jsonl",
            SourceKind.ClaudeCode,
            "ignored-project",
            "claude-sonnet-4-6",
            AgentPhase.Idle,
            false,
            Rate.Zero,
            null,
            DateTimeOffset.UtcNow.AddMinutes(-6));
        var withStaleIdle = sample with { Agents = sample.Agents.Append(staleIdle).ToArray() };
        var prunedIdle = RuntimeSnapshotMapper.Map(withStaleIdle, RandomNumberGenerator.GetBytes(32));
        Require(prunedIdle.MainAgents.Count == 1, "stale idle transcript removal");
        await LocalSourceReadPipeSelfTests.RunAsync().ConfigureAwait(false);

        static void ExpectInvalid(string json)
        {
            try
            {
                StatuslineCache.Parse(System.Text.Encoding.UTF8.GetBytes(json));
                throw new InvalidOperationException("invalid cache test failed");
            }
            catch (InvalidDataException)
            {
            }
        }

        static void Require(bool condition, string test)
        {
            if (!condition)
            {
                throw new InvalidOperationException($"self-test failed: {test}");
            }
        }

        static SpeedSnapshot CreateSampleSnapshot()
        {
            var now = DateTimeOffset.UtcNow;
            var main = new AgentStatus("C:\\Users\\someone\\.claude\\projects\\main.jsonl", SourceKind.ClaudeCode,
                "ignored-project", "claude-sonnet-4-6", AgentPhase.Tools, false, new Rate(2, 3), 1.5, now);
            var sub = new AgentStatus("C:\\Users\\someone\\.claude\\projects\\subagents\\sub.jsonl", SourceKind.ClaudeCode,
                "ignored-project", "claude-haiku-4-5", AgentPhase.Generating, true, new Rate(1, 1), 1, now, main.Id);
            var sources = new[]
            {
                new SourceStatus(SourceKind.ClaudeCode, true, "private-path", true, 2, new Rate(3, 4), TokenTotals.Zero, 1, new Rate(1.2, 1.6)),
                new SourceStatus(SourceKind.ClaudeDesktop, true, "private-path", false, 0, Rate.Zero, TokenTotals.Zero, 0),
                new SourceStatus(SourceKind.Codex, true, "private-path", true, 2, new Rate(8, 10), TokenTotals.Zero, 1, new Rate(2, 3)),
            };
            var response = new ResponseSummary(SourceKind.ClaudeCode, "ignored-project", "claude-sonnet-4-6", 10, 20,
                TimeSpan.FromSeconds(2), 5, now);
            var codex = new AgentStatus("C:\\Users\\someone\\.codex\\sessions\\codex.jsonl", SourceKind.Codex,
                "ignored-codex-project", null, AgentPhase.Generating, false, new Rate(8, 10), 2.3, now);
            return new SpeedSnapshot(now, MonitorState.Running, new Rate(11, 14), 0.4, Rate.Zero, null, null,
                TokenTotals.Zero, sources, [main, sub, codex], 2, 1, [], response, [])
            {
                LiveModels =
                [
                    new SourceModelRate(SourceKind.ClaudeCode, "claude-sonnet-4-6", new Rate(2, 3)),
                    new SourceModelRate(SourceKind.ClaudeCode, "claude-haiku-4-5", new Rate(1, 1)),
                    new SourceModelRate(SourceKind.Codex, null, new Rate(8, 10)),
                ],
            };
        }
    }

    private static void Require(bool condition, string test)
    {
        if (!condition)
        {
            throw new InvalidOperationException($"self-test failed: {test}");
        }
    }

    private sealed class SnapshotCell
    {
        private readonly object _gate = new();
        private SpeedSnapshot _latest = SpeedSnapshot.Empty;

        public void Update(SpeedSnapshot snapshot)
        {
            lock (_gate)
            {
                _latest = snapshot;
            }
        }

        public SpeedSnapshot Read()
        {
            lock (_gate)
            {
                return _latest;
            }
        }
    }

    private sealed class ResponseEventBuffer
    {
        private const int MaximumEvents = 32;
        private readonly object _gate = new();
        private readonly Queue<ResponseEventInput> _events = new();
        private long _sequence;

        public void Add(ResponseSummary response)
        {
            lock (_gate)
            {
                _events.Enqueue(new ResponseEventInput(++_sequence, response));
                while (_events.Count > MaximumEvents)
                {
                    _events.Dequeue();
                }
            }
        }

        public IReadOnlyList<ResponseEventInput> Read()
        {
            lock (_gate)
            {
                return _events.ToArray();
            }
        }
    }

    private sealed record Options(
        bool Watch,
        bool CaptureStatusline,
        bool SelfTest,
        string? Root,
        string? CodexRoot,
        IReadOnlySet<SourceKind> Sources,
        IReadOnlyDictionary<SourceKind, string> OtherRoots);
}
