using System.Text;
using System.Text.Json;
using AgentSpeed.Core;
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
        Console.WriteLine($"PASS: upstream parser compatibility ({count} fixtures, Codex reset and Claude display titles)");
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
