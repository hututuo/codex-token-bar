using System.Security.Cryptography;
using System.Text.Json;
using AgentSpeed.Core;

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
                RunSelfTests();
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
        var root = Path.GetFullPath(options.Root ?? LiveMonitor.DefaultClaudeRoot);
        EnsureLocalPath(root);
        var enabled = options.Sources;
        var configuration = new MonitorConfiguration(enabled, ClaudeRoot: root);
        var hub = new SpeedHub(context: null);
        var processSalt = RandomNumberGenerator.GetBytes(32);
        var latest = new SnapshotCell();
        var firstReady = new TaskCompletionSource<SpeedSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        hub.LivePublished += (_, snapshot) =>
        {
            latest.Update(snapshot);
            if (snapshot.State.Kind != MonitorStateKind.Starting)
            {
                firstReady.TrySetResult(snapshot);
            }
        };

        using var monitor = new LiveMonitor(hub, configuration);
        using var lifetime = new CancellationTokenSource();
        ConsoleCancelEventHandler cancelHandler = (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            lifetime.Cancel();
        };
        Console.CancelKeyPress += cancelHandler;
        Task? parentWatch = null;
        if (options.Watch && Console.IsInputRedirected)
        {
            parentWatch = WatchParentInputAsync(lifetime);
        }

        try
        {
            monitor.Start();
            var ready = await WaitForReadySnapshotAsync(firstReady.Task, lifetime.Token).ConfigureAwait(false);
            WriteSnapshot(RuntimeSnapshotMapper.Map(ready, processSalt, enabled));
            if (!options.Watch)
            {
                return;
            }

            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
            while (await timer.WaitForNextTickAsync(lifetime.Token).ConfigureAwait(false))
            {
                WriteSnapshot(RuntimeSnapshotMapper.Map(latest.Read(), processSalt, enabled));
            }
        }
        finally
        {
            lifetime.Cancel();
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

    private static async Task WatchParentInputAsync(CancellationTokenSource lifetime)
    {
        var input = Console.OpenStandardInput();
        var buffer = new byte[256];
        try
        {
            while (await input.ReadAsync(buffer, lifetime.Token).ConfigureAwait(false) > 0)
            {
                // The helper has no input protocol in watch mode; EOF is the parent's shutdown signal.
            }

            if (!lifetime.IsCancellationRequested)
            {
                lifetime.Cancel();
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (IOException)
        {
            if (!lifetime.IsCancellationRequested)
            {
                lifetime.Cancel();
            }
        }
    }

    private static void WriteSnapshot(RuntimeSnapshot snapshot)
    {
        Console.Out.WriteLine(JsonSerializer.Serialize(snapshot, JsonOptions));
        Console.Out.Flush();
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
                case "--source" when index + 1 < args.Length:
                    sourceWasSpecified = true;
                    var source = args[++index] switch
                    {
                        "claudeCode" => SourceKind.ClaudeCode,
                        "claudeDesktop" => SourceKind.ClaudeDesktop,
                        _ => throw new ArgumentException("Only local Claude sources are supported."),
                    };
                    sources.Add(source);
                    break;
                default:
                    throw new ArgumentException("Unknown or incomplete helper argument.");
            }
        }

        if ((watch && once) || (captureStatusline && (watch || once || root is not null || sourceWasSpecified))
            || (selfTest && (watch || once || captureStatusline || root is not null || sourceWasSpecified)))
        {
            throw new ArgumentException("Helper modes cannot be combined.");
        }

        if (sourceWasSpecified && sources.Count == 0)
        {
            throw new ArgumentException("At least one Claude source is required.");
        }
        if (!sourceWasSpecified)
        {
            sources = [SourceKind.ClaudeCode, SourceKind.ClaudeDesktop];
        }

        return new Options(watch, captureStatusline, selfTest, root, sources);
    }

    private static void EnsureLocalPath(string path)
    {
        if (path.StartsWith("\\\\", StringComparison.Ordinal) || path.StartsWith("//", StringComparison.Ordinal))
        {
            throw new ArgumentException("Network paths are not supported.");
        }

        var fullPath = Path.GetFullPath(path);
        var current = Path.GetPathRoot(fullPath);
        if (string.IsNullOrEmpty(current))
        {
            throw new ArgumentException("Claude root must be a local filesystem path.");
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

    private static void RunSelfTests()
    {
        const string input = """
            {
              "schema_version": 1,
              "captured_at_epoch": 1800000000.25,
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

        var onlyCode = RuntimeSnapshotMapper.Map(
            CreateSampleSnapshot(),
            RandomNumberGenerator.GetBytes(32),
            new HashSet<SourceKind> { SourceKind.ClaudeCode });
        Require(onlyCode.SourceAvailable["claudeCode"] && !onlyCode.SourceAvailable["claudeDesktop"], "enabled source filtering");
        Require(onlyCode.MainAgents.Count == 1 && onlyCode.Subagents.Count == 1, "enabled Claude source attribution");

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
                new SourceStatus(SourceKind.ClaudeCode, true, "private-path", true, 2, new Rate(3, 4), TokenTotals.Zero, 1),
                new SourceStatus(SourceKind.ClaudeDesktop, true, "private-path", false, 0, Rate.Zero, TokenTotals.Zero, 0),
            };
            var response = new ResponseSummary(SourceKind.ClaudeCode, "ignored-project", "claude-sonnet-4-6", 10, 20,
                TimeSpan.FromSeconds(2), 5, now);
            return new SpeedSnapshot(now, MonitorState.Running, new Rate(3, 4), 0.4, Rate.Zero, null, null,
                TokenTotals.Zero, sources, [main, sub], 1, 1, [], response, []);
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

    private sealed record Options(
        bool Watch,
        bool CaptureStatusline,
        bool SelfTest,
        string? Root,
        IReadOnlySet<SourceKind> Sources);
}
