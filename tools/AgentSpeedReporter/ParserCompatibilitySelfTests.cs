using System.Text;
using System.Text.Json;
using AgentSpeed.Core;
using AgentSpeed.Core.Antigravity;
using AgentSpeed.Core.Monitoring;
using AgentSpeed.Core.Parsing;

namespace CodexTokenBar.AgentSpeedReporter;

/// <summary>Offline regression checks for the shared Codex and Claude parser compatibility fixtures.</summary>
internal static class ParserCompatibilitySelfTests
{
    private const string FixtureRelativePath = "Tests/Fixtures/upstream-parser-compat.json";

    public static void Run()
    {
        var fixturePath = FindFixture();
        using var document = JsonDocument.Parse(File.ReadAllBytes(fixturePath));
        if (document.RootElement.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidOperationException("parser_compat_fixture_must_be_array");
        }

        var count = 0;
        foreach (var fixture in document.RootElement.EnumerateArray())
        {
            RunFixture(fixture);
            count++;
        }

        if (count == 0)
        {
            throw new InvalidOperationException("parser_compat_fixture_is_empty");
        }

        CodexResetClearsPaginatedOrdinal();
        ClaudeDisplayTitles();
        ClaudeRootOwnership();
        AntigravityStoreLocations();
        Console.WriteLine($"PASS: upstream parser compatibility ({count} fixtures, Codex reset, Claude display titles, Claude root ownership and Antigravity stores)");
    }

    private static void ClaudeRootOwnership()
    {
        var folder = Path.Combine(Path.GetTempPath(), "tokenbar-claude-ownership-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var day = new DateTimeOffset(2026, 10, 20, 0, 0, 0, TimeSpan.Zero);
        var now = day.AddHours(10);
        var nowMs = now.ToUnixTimeMilliseconds();
        var todayStartMs = day.ToUnixTimeMilliseconds();
        var desktopOnly = new HashSet<SourceKind> { SourceKind.ClaudeDesktop };
        var bothClients = new HashSet<SourceKind> { SourceKind.ClaudeCode, SourceKind.ClaudeDesktop };
        try
        {
            var shared = Path.Combine(folder, "shared");
            Write(shared, "code", 0, Assistant("cli", "copied-legacy", 101));
            Write(shared, "desktop", 1, Assistant("claude-desktop", "copied-legacy", 101),
                Assistant("claude-desktop", "unique-desktop", 13));
            var legacy = Configuration(desktopOnly, shared);
            using (var core = new MonitorCore(legacy, SourceLocations.Resolve(legacy), todayStartMs, zone: TimeZoneInfo.Utc))
            {
                core.Clock = () => nowMs;
                var report = core.Seed(nowMs, todayStartMs, CancellationToken.None);
                var snapshot = core.BuildSnapshot(nowMs, todayStartMs, MonitorState.Running, observeLive: false).Snapshot;
                Check("claude-legacy-disabled-copy", "filesRead", 2, report.FilesRead, "shared legacy root");
                Check("claude-legacy-disabled-copy", "output", 13L, snapshot.Today.Output, "only unique Desktop usage counts");
                Check("claude-legacy-disabled-copy", "requests", 1L, snapshot.Today.Requests, "Code retains ownership of copied history");
                Check("claude-legacy-disabled-copy", "desktopOutput", 13L,
                    snapshot.Sources.Single(source => source.Kind == SourceKind.ClaudeDesktop).Today.Output, "Desktop source total");
                CheckDisabledCode("claude-legacy-disabled-copy", snapshot);
                CheckDisabledCode("claude-legacy-disabled-copy-starting", core.BuildStartingSnapshot(nowMs, todayStartMs, 0));
            }

            var codeRoot = Path.Combine(folder, "explicit-code");
            var desktopRoot = Path.Combine(folder, "explicit-desktop");
            // Wrong-root copies are deliberately older so they reach shared dedupe first if the ownership gate fails.
            Write(desktopRoot, "wrong-code", 0, Assistant("cli", "same-code", 1001));
            Write(codeRoot, "wrong-desktop", 1, Assistant("claude-desktop", "same-desktop", 1003));
            Write(codeRoot, "right-code", 2, Assistant("cli", "same-code", 11));
            Write(desktopRoot, "right-desktop", 3, Assistant("claude-desktop", "same-desktop", 13));
            var explicitRoots = Configuration(bothClients, Path.Combine(folder, "unused-legacy"),
                new Dictionary<SourceKind, IReadOnlyList<string>> {
                    [SourceKind.ClaudeCode] = [codeRoot], [SourceKind.ClaudeDesktop] = [desktopRoot] });
            using (var core = new MonitorCore(explicitRoots, SourceLocations.Resolve(explicitRoots), todayStartMs, zone: TimeZoneInfo.Utc))
            {
                core.Clock = () => nowMs;
                var report = core.Seed(nowMs, todayStartMs, CancellationToken.None);
                var snapshot = core.BuildSnapshot(nowMs, todayStartMs, MonitorState.Running, observeLive: false).Snapshot;
                Check("claude-explicit-wrong-copy-first", "filesRead", 4, report.FilesRead, "distinct explicit roots");
                Check("claude-explicit-wrong-copy-first", "output", 24L, snapshot.Today.Output, "only selected copies count");
                Check("claude-explicit-wrong-copy-first", "requests", 2L, snapshot.Today.Requests, "one request per selected key");
                Check("claude-explicit-wrong-copy-first", "codeOutput", 11L,
                    snapshot.Sources.Single(source => source.Kind == SourceKind.ClaudeCode).Today.Output, "wrong-root Code copy cannot claim");
                Check("claude-explicit-wrong-copy-first", "desktopOutput", 13L,
                    snapshot.Sources.Single(source => source.Kind == SourceKind.ClaudeDesktop).Today.Output, "wrong-root Desktop copy cannot claim");
            }

            var disabledRoot = Path.Combine(folder, "disabled-code");
            var enabledRoot = Path.Combine(folder, "enabled-desktop");
            Write(disabledRoot, "unscanned", 0, Assistant("cli", "disabled-only", 999));
            Write(enabledRoot, "scanned", 1, Assistant("claude-desktop", "enabled-only", 17));
            var filtered = Configuration(desktopOnly, Path.Combine(folder, "unused-filtered-legacy"),
                new Dictionary<SourceKind, IReadOnlyList<string>> {
                    [SourceKind.ClaudeCode] = [disabledRoot], [SourceKind.ClaudeDesktop] = [enabledRoot] });
            var locations = SourceLocations.Resolve(filtered);
            Check("claude-disabled-root-filter", "retainedOwnership", true,
                locations.ClaudeRootsBySource?.GetValueOrDefault(SourceKind.ClaudeCode)?.Contains(disabledRoot) == true,
                "disabled source selection remains available for ownership checks");
            var walkRoots = locations.FileRoots(desktopOnly).Where(root => root.Family == RootFamily.Claude).Select(root => root.Path).ToArray();
            Check("claude-disabled-root-filter", "walkRootCount", 1, walkRoots.Length, "only enabled source roots are scanned");
            Check("claude-disabled-root-filter", "walkRoot", enabledRoot, walkRoots.Single(), "disabled-only root is excluded");
            using (var core = new MonitorCore(filtered, locations, todayStartMs, zone: TimeZoneInfo.Utc))
            {
                core.Clock = () => nowMs;
                var report = core.Seed(nowMs, todayStartMs, CancellationToken.None);
                var snapshot = core.BuildSnapshot(nowMs, todayStartMs, MonitorState.Running, observeLive: false).Snapshot;
                Check("claude-disabled-root-filter", "filesDiscovered", 1, report.FilesDiscovered, "disabled directory is never walked");
                Check("claude-disabled-root-filter", "trackedFiles", 1, core.TrackedFileCount, "disabled transcript is never tracked");
                Check("claude-disabled-root-filter", "output", 17L, snapshot.Today.Output, "enabled source remains readable");
                CheckDisabledCode("claude-disabled-root-filter", snapshot);
            }

            var parentRoot = Path.Combine(folder, "nested-parent");
            var nestedRoot = Path.Combine(parentRoot, "nested-code");
            Write(nestedRoot, "original-code", 0, Assistant("cli", "nested-copy", 101));
            Write(parentRoot, "copied-desktop", 1, Assistant("claude-desktop", "nested-copy", 101),
                Assistant("claude-desktop", "nested-unique", 19));
            var nested = Configuration(desktopOnly, Path.Combine(folder, "unused-nested-legacy"),
                new Dictionary<SourceKind, IReadOnlyList<string>> {
                    [SourceKind.ClaudeCode] = [nestedRoot], [SourceKind.ClaudeDesktop] = [parentRoot] });
            var nestedLocations = SourceLocations.Resolve(nested);
            var nestedWalkRoots = nestedLocations.FileRoots(desktopOnly).Where(root => root.Family == RootFamily.Claude)
                .Select(root => root.Path).ToArray();
            Check("claude-disabled-nested-ownership", "walkRootCount", 1, nestedWalkRoots.Length, "only the enabled parent is walked");
            Check("claude-disabled-nested-ownership", "walkRoot", parentRoot, nestedWalkRoots.Single(), "nested Code root has no separate walk");
            using (var core = new MonitorCore(nested, nestedLocations, todayStartMs, zone: TimeZoneInfo.Utc))
            {
                core.Clock = () => nowMs;
                var enabledRoots = core.Roots.Where(root => root.Family == RootFamily.Claude && root.Enabled).ToArray();
                Check("claude-disabled-nested-ownership", "enabledRootCount", 1, enabledRoots.Length, "one enabled Claude root");
                Check("claude-disabled-nested-ownership", "enabledRoot", parentRoot, enabledRoots.Single().Path, "only the parent is enabled");
                Check("claude-disabled-nested-ownership", "retainedNestedRoot", true,
                    core.Roots.Any(root => root.Family == RootFamily.Claude && root.Path == nestedRoot && !root.Enabled),
                    "disabled nested selection still determines ownership");
                var report = core.Seed(nowMs, todayStartMs, CancellationToken.None);
                var snapshot = core.BuildSnapshot(nowMs, todayStartMs, MonitorState.Running, observeLive: false).Snapshot;
                Check("claude-disabled-nested-ownership", "filesDiscovered", 2, report.FilesDiscovered, "parent walk encounters both transcripts once");
                Check("claude-disabled-nested-ownership", "filesRead", 2, report.FilesRead, "nested original participates in shared dedupe");
                Check("claude-disabled-nested-ownership", "trackedFiles", 2, core.TrackedFileCount, "both encountered transcripts are tracked");
                Check("claude-disabled-nested-ownership", "output", 19L, snapshot.Today.Output, "only unique Desktop usage counts");
                Check("claude-disabled-nested-ownership", "requests", 1L, snapshot.Today.Requests, "nested Code original retains the copied key");
                Check("claude-disabled-nested-ownership", "desktopOutput", 19L,
                    snapshot.Sources.Single(source => source.Kind == SourceKind.ClaudeDesktop).Today.Output, "Desktop copy cannot reclaim the nested Code key");
                CheckDisabledCode("claude-disabled-nested-ownership", snapshot);
                CheckDisabledCode("claude-disabled-nested-ownership-starting", core.BuildStartingSnapshot(nowMs, todayStartMs, 0));
            }
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }

        MonitorConfiguration Configuration(IReadOnlySet<SourceKind> enabled, string legacyRoot,
            IReadOnlyDictionary<SourceKind, IReadOnlyList<string>>? selected = null)
        {
            var absent = Path.Combine(folder, "absent");
            return new MonitorConfiguration(enabled, CodexRoot: absent, ClaudeRoot: legacyRoot, DshRoot: absent,
                OpenCodeRoot: absent, GeminiRoot: absent, OmpRoot: absent, AntigravityRoot: absent,
                WorkBuddyRoot: absent, WorkBuddyAiRoot: absent, ZCodeRoot: absent, KimiRoot: absent,
                GrokBuildRoot: absent, ClaudeRootsBySource: selected);
        }

        string Assistant(string entrypoint, string id, int output) => JsonSerializer.Serialize(new {
            type = "assistant", entrypoint, timestamp = now.AddSeconds(-5).ToString("O"),
            message = new { id, model = "fixture", stop_reason = "end_turn", usage = new { output_tokens = output } }
        });

        void Write(string root, string name, int order, params string[] lines)
        {
            var project = Path.Combine(root, "p");
            Directory.CreateDirectory(project);
            var path = Path.Combine(project, name + ".jsonl");
            File.WriteAllText(path, string.Join("\n", lines) + "\n", new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            File.SetLastWriteTimeUtc(path, now.AddSeconds(order - 60).UtcDateTime);
        }

        static void CheckDisabledCode(string fixture, SpeedSnapshot snapshot)
        {
            var code = snapshot.Sources.Single(source => source.Kind == SourceKind.ClaudeCode);
            Check(fixture, "codeEnabled", false, code.Enabled, "disabled source status");
            Check(fixture, "codePath", string.Empty, code.RootPath, "disabled source path remains hidden");
            Check(fixture, "codeAvailable", false, code.Available, "disabled source is unavailable");
            Check(fixture, "codeSessions", 0, code.SessionCount, "disabled source has no sessions in the view");
        }
    }

    private static void AntigravityStoreLocations()
    {
        string[] names = ["antigravity-cli", "antigravity", "antigravity-ide", "antigravity-acp"];
        var home = Path.Combine(Path.GetTempPath(), "tokenbar-antigravity-path-fixture");
        var gemini = Path.Combine(home, ".gemini");
        CheckPaths("default", names.Select(name => Path.Combine(gemini, name)), AntigravityPaths.Stores(gemini, null));
        CheckPaths("empty-setting", AntigravityPaths.DefaultStores(gemini), AntigravityPaths.Stores(gemini, ""));
        CheckPaths("public-default", names, LiveMonitor.DefaultAntigravityStores.Select(Path.GetFileName));
        foreach (var parent in new[] { gemini, Path.Combine(home, "antigravity-chat"), Path.Combine(home, "custom-store") })
        {
            // Resolution is independent of existence: child stores created after monitor startup must join.
            var expected = new[] { parent }.Concat(names.Select(name => Path.Combine(parent, name)));
            CheckPaths("parent", expected, AntigravityPaths.Stores(gemini, parent + Path.DirectorySeparatorChar));
            CheckPaths("public-parent", expected, LiveMonitor.AntigravityStores(parent));
            foreach (var name in names)
            {
                var store = Path.Combine(parent, name);
                CheckPaths("direct-store", [store], AntigravityPaths.Stores(gemini, store));
                var conversations = Path.Combine(store, "conversations");
                CheckPaths("direct-conversations", [conversations], AntigravityPaths.Stores(gemini, conversations));
                CheckPaths("conversations-folder", [conversations], AntigravityPaths.Stores(gemini, store).Select(AntigravityPaths.ConversationsOf));
            }
        }

        var upper = Path.Combine(home, "ANTIGRAVITY-ACP");
        CheckPaths("case-insensitive-direct-store", [upper], AntigravityPaths.Stores(gemini, upper));
        var upperConversations = Path.Combine(upper, "CONVERSATIONS");
        CheckPaths("case-insensitive-conversations", [upperConversations], AntigravityPaths.Stores(gemini, upperConversations));
        var backup = Path.Combine(home, "antigravity-backup");
        CheckPaths("backup-store", [], AntigravityPaths.Stores(gemini, backup));
        CheckPaths("backup-conversations", [], AntigravityPaths.Stores(gemini, Path.Combine(backup, "conversations")));
        var copiedBackup = Path.Combine(home, "CUSTOM-BACKUP");
        CheckPaths("case-insensitive-backup", [], AntigravityPaths.Stores(gemini, copiedBackup));

        static void CheckPaths(string fixture, IEnumerable<string?> expected, IEnumerable<string?> actual)
        {
            Check("antigravity-" + fixture, "paths", string.Join("|", expected), string.Join("|", actual), "store root resolution");
        }
    }

    private static void ClaudeDisplayTitles()
    {
        var parser = new ClaudeParser("/p/session/subagents/agent-worker.jsonl", new Deduper());
        var sink = new RecordingSink();
        Feed(parser, sink,
        [
            """{"type":"user","timestamp":"2026-10-20T10:00:00Z","message":{"role":"user","content":[{"type":"tool_result","content":"ignored result"},{"type":"text","text":"<system-reminder>private reminder</system-reminder>\nInspect\u0000cache eviction\nLater context"}]}}""",
            """{"type":"assistant","timestamp":"2026-10-20T10:00:02Z","message":{"id":"followup","model":"fixture","stop_reason":"end_turn","usage":{"output_tokens":8}}}""",
            """{"type":"user","timestamp":"2026-10-20T10:00:03Z","message":{"role":"user","content":"later request title"}}""",
        ]);
        Check("claude-display-title", "title", "Inspect cache eviction", parser.DisplayTitle, sink.Describe());

        var reordered = new ClaudeParser("/p/session/subagents/agent-reordered.jsonl", new Deduper());
        Feed(reordered, new RecordingSink(),
        [
            """{"message":{"role":"user","content":"Late type metadata still labels this task"},"type":"user","timestamp":"2026-10-20T10:00:00Z"}""",
        ]);
        Check("claude-display-title-key-order", "title", "Late type metadata still labels this task", reordered.DisplayTitle, "message before type");

        var explicitParser = new ClaudeParser("/p/session/subagents/agent-explicit.jsonl", new Deduper());
        Feed(explicitParser, new RecordingSink(),
        [
            """{"type":"progress","title":"lower priority","agentName":"Explore"}""",
            """{"type":"user","timestamp":"2026-10-20T10:00:00Z","message":{"role":"user","content":"fallback request"}}""",
        ]);
        Check("claude-agent-name-priority", "title", "Explore", explicitParser.DisplayTitle, "metadata-only record");

        var customTitle = new ClaudeParser("/p/session/subagents/agent-custom-title.jsonl", new Deduper());
        Feed(customTitle, new RecordingSink(),
        [
            """{"type":"progress","customTitle":"First task name"}""",
            """{"type":"progress","customTitle":"Renamed task"}""",
        ]);
        Check("claude-custom-title-metadata", "title", "Renamed task", customTitle.DisplayTitle, "metadata-only rename record");

        var unnamed = new ClaudeParser("/p/session/subagents/agent-unnamed.jsonl", new Deduper());
        Feed(unnamed, new RecordingSink(),
        [
            """{"type":"user","timestamp":"2026-10-20T10:00:00Z","message":{"role":"user","content":[{"type":"tool_result","content":"not a title"}]}}""",
        ]);
        Check("claude-no-invented-title", "title", null, unnamed.DisplayTitle, "tool-result-only record");

        var oversizedMetadata = new ClaudeParser("/p/session/subagents/agent-oversized.jsonl", new Deduper());
        Feed(oversizedMetadata, new RecordingSink(),
        [JsonSerializer.Serialize(new { type = "progress", agentName = new string('x', 20_000) })]);
        Check("claude-oversized-metadata-title", "title", null, oversizedMetadata.DisplayTitle, "oversized metadata is skipped");

        var longText = string.Concat(Enumerable.Repeat("👩‍💻e\u0301", 125));
        var bounded = new ClaudeParser("/p/session/subagents/agent-bounded.jsonl", new Deduper());
        Feed(bounded, new RecordingSink(),
        [JsonSerializer.Serialize(new { type = "user", timestamp = "2026-10-20T10:00:00Z", message = new { role = "user", content = longText } })]);
        var runes = 0;
        if (bounded.DisplayTitle is { } boundedTitle)
        {
            foreach (var _ in boundedTitle.EnumerateRunes()) runes++;
        }
        Check("claude-title-limit", "length", 120, runes, "Unicode title cap");

        var interrupt = new ClaudeParser("/p/session/subagents/agent-interrupt.jsonl", new Deduper());
        var longInterruptText = "[Request interrupted by user" + new string('x', 20_000);
        Feed(interrupt, new RecordingSink(),
        [
            """{"type":"user","timestamp":"2026-10-20T10:00:00Z","message":{"role":"user","content":"start work"}}""",
            JsonSerializer.Serialize(new { type = "user", timestamp = "2026-10-20T10:00:02Z", message = new { role = "user", content = longInterruptText } }),
        ]);
        Check("claude-long-interrupt", "phase", "idle", interrupt.Phase.ToString().ToLowerInvariant(), "bounded interrupt scan");

        var systemOnly = new ClaudeParser("/p/session/subagents/agent-system.jsonl", new Deduper());
        Feed(systemOnly, new RecordingSink(),
        [
            """{"type":"user","timestamp":"2026-10-20T10:00:00Z","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>private reminder</system-reminder>"}]}}""",
            """{"type":"user","timestamp":"2026-10-20T10:00:02Z","message":{"role":"user","content":[{"type":"text","text":"<command-name>help</command-name>"}]}}""",
        ]);
        Check("claude-system-only-title", "title", null, systemOnly.DisplayTitle, "system-tag-only record");

        var longUser = new ClaudeParser("/p/session/subagents/agent-long-user.jsonl", new Deduper());
        var longUserSink = new RecordingSink();
        Feed(longUser, longUserSink,
        [
            JsonSerializer.Serialize(new { type = "user", timestamp = "2026-10-20T10:00:00Z", message = new { role = "user", content = new string('x', 20_000) } }),
            """{"type":"assistant","timestamp":"2026-10-20T10:00:02Z","message":{"id":"long-user-followup","model":"fixture","stop_reason":"end_turn","usage":{"output_tokens":9}}}""",
        ]);
        Check("claude-long-user-no-title", "title", null, longUser.DisplayTitle, "oversized user text is skipped for labels");
        Check("claude-long-user-still-parses-usage", "output", 9L, longUserSink.Latest.Values.Sum(response => response.Tokens.Output), longUserSink.Describe());
    }

    private static void RunFixture(JsonElement fixture)
    {
        var name = RequiredString(fixture, "name");
        var family = RequiredString(fixture, "family");
        if (!fixture.TryGetProperty("lines", out var lines) || lines.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidOperationException($"{name}: lines_must_be_array");
        }

        var deduper = new Deduper();
        TranscriptParser parser = family switch
        {
            "codex" => new CodexParser($"parser-compat:{name}", deduper),
            "claude" => new ClaudeParser($"parser-compat:{name}", deduper),
            _ => throw new InvalidOperationException($"{name}: unsupported_family:{family}"),
        };

        var batch = parser.NewBatch();
        foreach (var line in lines.EnumerateArray())
        {
            if (line.ValueKind != JsonValueKind.String)
            {
                throw new InvalidOperationException($"{name}: each_line_must_be_a_jsonl_string");
            }

            batch.OnLine(Encoding.UTF8.GetBytes(line.GetString()!));
        }

        var sink = new RecordingSink();
        batch.ApplyTo(sink);
        var expected = fixture.GetProperty("expected");
        var expectedOutput = expected.GetProperty("output").GetInt64();
        var expectedResponses = expected.GetProperty("responseCount").GetInt32();
        var expectedPhase = RequiredString(expected, "phase");
        var expectedModel = OptionalString(expected, "model");
        var expectedStopped = expected.GetProperty("stopped").GetBoolean();
        var actualOutput = sink.Latest.Values.Sum(response => response.Tokens.Output);
        var actualPhase = parser.Phase.ToString().ToLowerInvariant();

        Check(name, "output", expectedOutput, actualOutput, sink.Describe());
        Check(name, "responseCount", expectedResponses, sink.Latest.Count, sink.Describe());
        Check(name, "phase", expectedPhase, actualPhase, sink.Describe());
        Check(name, "model", expectedModel, parser.Model, sink.Describe());
        Check(name, "stopped", expectedStopped, parser.ConfirmedStopped, sink.Describe());
    }

    private static void CodexResetClearsPaginatedOrdinal()
    {
        var parser = new CodexParser("parser-compat:reset", new Deduper());
        var sink = new RecordingSink();
        Feed(parser, sink,
        [
            """{"timestamp":"2026-10-31T10:00:00Z","ordinal":0,"type":"session_meta","payload":{"id":"before-reset","thread_source":"subagent","history_mode":"paginated","subagent_history_start_ordinal":6}}""",
            LegacyTokenCount("2026-10-31T10:00:01Z", 5, "before-reset", 7),
        ]);
        if (sink.Latest.Count != 0)
        {
            throw new InvalidOperationException($"codex_reset_setup_expected_copied_prefix_to_be_skipped:{sink.Describe()}");
        }

        parser.Reset();
        Feed(parser, sink,
        [
            """{"timestamp":"2026-10-31T10:01:00Z","ordinal":0,"type":"session_meta","payload":{"id":"after-reset","thread_source":"subagent"}}""",
            LegacyTokenCount("2026-10-31T10:01:01Z", 1, "after-reset", 17),
        ]);

        var actualOutput = sink.Latest.Values.Sum(response => response.Tokens.Output);
        Check("codex-reset-clears-paginated-ordinal", "output", 17L, actualOutput, sink.Describe());
        Check("codex-reset-clears-paginated-ordinal", "responseCount", 1, sink.Latest.Count, sink.Describe());
    }

    private static string LegacyTokenCount(string timestamp, int ordinal, string threadId, int output) =>
        JsonSerializer.Serialize(new {
            timestamp, ordinal, type = "event_msg",
            payload = new {
                thread_id = threadId, type = "token_count",
                info = new {
                    total_token_usage = new { input_tokens = 0, output_tokens = output, total_tokens = output },
                    last_token_usage = new { input_tokens = 0, output_tokens = output, total_tokens = output }
                }
            }
        });

    private static void Feed(TranscriptParser parser, IResponseSink sink, IEnumerable<string> lines)
    {
        var batch = parser.NewBatch();
        foreach (var line in lines)
        {
            batch.OnLine(Encoding.UTF8.GetBytes(line));
        }

        batch.ApplyTo(sink);
    }

    private static string FindFixture()
    {
        foreach (var start in new[] { Environment.CurrentDirectory, AppContext.BaseDirectory })
        {
            for (DirectoryInfo? directory = new DirectoryInfo(start); directory is not null; directory = directory.Parent)
            {
                var candidate = Path.Combine(directory.FullName, FixtureRelativePath);
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
        }

        throw new FileNotFoundException(
            $"Could not find {FixtureRelativePath} above the working directory or reporter output directory.");
    }

    private static string RequiredString(JsonElement element, string property)
    {
        var value = element.GetProperty(property);
        return value.ValueKind == JsonValueKind.String
            ? value.GetString()!
            : throw new InvalidOperationException($"fixture_property_must_be_string:{property}");
    }

    private static string? OptionalString(JsonElement element, string property)
    {
        var value = element.GetProperty(property);
        return value.ValueKind switch
        {
            JsonValueKind.Null => null,
            JsonValueKind.String => value.GetString(),
            _ => throw new InvalidOperationException($"fixture_property_must_be_string_or_null:{property}"),
        };
    }

    private static void Check<T>(string fixture, string field, T expected, T actual, string detail)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            var expectedText = expected is null
                ? "null"
                : System.Convert.ToString(expected, System.Globalization.CultureInfo.InvariantCulture) ?? "null";
            var actualText = actual is null
                ? "null"
                : System.Convert.ToString(actual, System.Globalization.CultureInfo.InvariantCulture) ?? "null";
            throw new InvalidOperationException(
                $"parser_compat_{fixture}_{field}: expected={expectedText}; actual={actualText}; latest={detail}");
        }
    }

    private sealed class RecordingSink : IResponseSink
    {
        public Dictionary<string, ParsedResponse> Latest { get; } = new(StringComparer.Ordinal);

        public void OnResponse(ParsedResponse response, bool isCompletion) => Latest[response.Key] = response;

        public string Describe() => string.Join(
            ",",
            Latest.OrderBy(pair => pair.Key, StringComparer.Ordinal)
                .Select(pair => $"{pair.Key}:{pair.Value.Tokens.Output}"));
    }
}
