using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using AgentSpeed.Core;
using AgentSpeed.Core.Monitoring;
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
            await ReporterRuntime.RunAsync(start.Username, start.Transport, status, lifetime.Token).ConfigureAwait(false);
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
            await ParentEofCancelsAsync().ConfigureAwait(false);
            await TransportChoiceIsExplicitAsync().ConfigureAwait(false);
            RealtimeModeOnlyTightensEventDrivenPublication();
            PayloadIsWhitelisted();
            DiscoveryWebSocketCapabilityIsStrict();
            WebSocketRealtimeTimingCarriesFreshSourceReadMetadata();
            SourceReadObservationTracksOnlyNewTranscriptResponses();
            SourceReadObservationBufferMergesEarliestWindowMetadata();
            await SnapshotMailboxKeepsTimingAlignedWithUnconsumedLatestSnapshotAsync().ConfigureAwait(false);
            ExplicitTransportDoesNotFallBackToHttp();
            WebSocketAcknowledgementsRequireTheExactPendingTupleAndConnection();
            WebSocketDropsBackpressureAndSleepWindows();
            WebSocketRetryAfterRemainsAMinimumDeadline();
            WebSocketRequestsSignTheExactV1BytesAndKeepTheApiBasePath();
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
        await using var input = new MemoryStream(Encoding.UTF8.GetBytes("{\"enabled\":false,\"username\":\"TokenBar-1234\"}\n"));
        if (await StatusProtocol.ReadStartCommandAsync(input).ConfigureAwait(false) is not null)
        {
            throw new InvalidOperationException();
        }
    }

    private static async Task InvalidShortUsernameDoesNotStartAsync()
    {
        await using var input = new MemoryStream(Encoding.UTF8.GetBytes("{\"enabled\":true,\"username\":\"x\"}\n"));
        if (await StatusProtocol.ReadStartCommandAsync(input).ConfigureAwait(false) is not null)
        {
            throw new InvalidOperationException();
        }
    }

    private static async Task TransportChoiceIsExplicitAsync()
    {
        await using var legacyInput = new MemoryStream(Encoding.UTF8.GetBytes("{\"enabled\":true,\"username\":\"TokenBar-1234\"}\n"));
        var legacy = await StatusProtocol.ReadStartCommandAsync(legacyInput).ConfigureAwait(false);
        if (legacy?.Transport != "http")
        {
            throw new InvalidOperationException();
        }

        await using var websocketInput = new MemoryStream(Encoding.UTF8.GetBytes("{\"enabled\":true,\"username\":\"TokenBar-1234\",\"transport\":\"websocket\"}\n"));
        var websocket = await StatusProtocol.ReadStartCommandAsync(websocketInput).ConfigureAwait(false);
        if (websocket?.Transport != "websocket")
        {
            throw new InvalidOperationException();
        }
    }

    private static void RealtimeModeOnlyTightensEventDrivenPublication()
    {
        using var legacy = new LiveMonitor(new SpeedHub());
        using var realtime = new LiveMonitor(new SpeedHub(), realtimeEventMode: true);
        if (legacy.EventDebounce != TimeSpan.FromMilliseconds(80)
            || legacy.ChangePublishMinimumInterval != TimeSpan.FromMilliseconds(100)
            || realtime.EventDebounce != TimeSpan.FromMilliseconds(50)
            || realtime.ChangePublishMinimumInterval != TimeSpan.FromMilliseconds(50)
            || realtime.SnapshotPublishInterval != TimeSpan.FromMilliseconds(500)
            || realtime.SourcePollInterval != TimeSpan.FromSeconds(1)
            || realtime.SourceDiscoveryInterval != TimeSpan.FromSeconds(10)
            || legacy.SnapshotPublishInterval != realtime.SnapshotPublishInterval
            || legacy.SourcePollInterval != realtime.SourcePollInterval
            || legacy.SourceDiscoveryInterval != realtime.SourceDiscoveryInterval)
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
        const string allowed = "{\"schema\":1,\"client\":{},\"deviceId\":\"id\",\"username\":\"TokenBar-1234\",\"run\":{},\"sentAt\":\"2026-01-01T00:00:00Z\",\"windowMs\":0,\"activity\":\"idle\",\"live\":{},\"peak\":{},\"delta\":{},\"title\":{},\"sources\":[],\"models\":[{\"harnessRequests\":[],\"modeUsage\":[]}]}";
        const string withTraffic = "{\"schema\":1,\"sources\":[{\"traffic\":{}}]}";
        const string withCost = "{\"schema\":1,\"models\":[{\"cost\":{}}]}";
        if (!ReportPayloadWhitelist.IsAllowed(Encoding.UTF8.GetBytes(allowed))
            || ReportPayloadWhitelist.IsAllowed(Encoding.UTF8.GetBytes(allowed.Replace(
                "\"title\":{},\"sources\"",
                "\"title\":{},\"realtime\":{\"sourceMode\":\"unknown\",\"observedAt\":null,\"observationAgeMs\":null,\"sourceResolutionMs\":null},\"sources\"")))
            || ReportPayloadWhitelist.IsAllowed(Encoding.UTF8.GetBytes(withTraffic))
            || ReportPayloadWhitelist.IsAllowed(Encoding.UTF8.GetBytes(withCost)))
        {
            throw new InvalidOperationException();
        }

        var realtime = allowed.Replace(
            "\"title\":{},\"sources\"",
            "\"title\":{},\"realtime\":{\"sourceMode\":\"unknown\",\"observedAt\":null,\"observationAgeMs\":null,\"sourceResolutionMs\":null},\"sources\"");
        if (!ReportPayloadWhitelist.IsAllowed(Encoding.UTF8.GetBytes(realtime), allowRealtime: true))
        {
            throw new InvalidOperationException();
        }
    }

    private static void DiscoveryWebSocketCapabilityIsStrict()
    {
        const string json = "{\"protocol\":\"agent-speed-report\",\"versions\":[1],\"service\":{\"name\":\"Test\",\"terms\":\"https://example.com/terms\",\"privacy\":\"https://example.com/privacy\"},\"api\":\"https://api.example.com/agent-speed\",\"extensions\":{\"reportWebSocket\":1},\"websocket\":{\"path\":\"/v1/reports/ws\",\"subprotocol\":\"agent-speed-report.v1\"}}";
        var service = ReportServiceUrl.Parse("https://example.com")!;
        var supported = ReportDiscovery.Parse(Encoding.UTF8.GetBytes(json), service, out _);
        if (supported is null || !supported.SupportsWebSocket
            || supported.WebSocket != ReportWebSocketSettings.Defaults
            || supported.Api.WebSocketEndpoint().AbsoluteUri != "wss://api.example.com/agent-speed/v1/reports/ws")
        {
            throw new InvalidOperationException();
        }

        foreach (var invalid in new[]
        {
            json.Replace("\"reportWebSocket\":1", "\"reportWebSocket\":1.0", StringComparison.Ordinal),
            json.Replace("\"reportWebSocket\":1", "\"reportWebSocket\":1e0", StringComparison.Ordinal),
            json.Replace("\"reportWebSocket\":1", "\"reportWebSocket\":2", StringComparison.Ordinal),
            json.Replace("\"reportWebSocket\":1", "\"reportWebSocket\":true", StringComparison.Ordinal),
            json.Replace("\"reportWebSocket\":1", "\"reportWebSocket\":\"1\"", StringComparison.Ordinal),
            json.Replace("\"extensions\":{\"reportWebSocket\":1},", string.Empty, StringComparison.Ordinal),
            json.Replace("\"websocket\":{\"path\":\"/v1/reports/ws\",\"subprotocol\":\"agent-speed-report.v1\"}", "\"websocket\":{\"path\":\"/v1/reports/ws\",\"subprotocol\":\"agent-speed-report.v1\",\"minIntervalMs\":1001}", StringComparison.Ordinal),
            json.Replace("\"subprotocol\":\"agent-speed-report.v1\"", "\"subprotocol\":\"other\"", StringComparison.Ordinal),
            json.Replace("\"subprotocol\":\"agent-speed-report.v1\"", "\"subprotocol\":\"agent-speed-report.v1\",\"minIntervalMs\":9", StringComparison.Ordinal),
        })
        {
            var parsed = ReportDiscovery.Parse(Encoding.UTF8.GetBytes(invalid), service, out _);
            if (parsed is null || parsed.SupportsWebSocket)
            {
                throw new InvalidOperationException();
            }
        }
    }

    private static void WebSocketRealtimeTimingCarriesFreshSourceReadMetadata()
    {
        const string body = "{\"schema\":1,\"client\":{},\"deviceId\":\"id\",\"username\":\"TokenBar-1234\",\"run\":{},\"sentAt\":\"2026-01-01T00:00:00Z\",\"windowMs\":0,\"activity\":\"idle\",\"live\":{},\"peak\":{},\"delta\":{},\"title\":{}}";
        var bytes = Encoding.UTF8.GetBytes(body);
        if (!RealtimeReportBody.TryAppendSourceTiming(bytes, observation: null, Stopwatch.GetTimestamp(), 0,
                out var unknown, out var unknownAge)
            || unknown is null
            || unknownAge is not null
            || !ReportPayloadWhitelist.IsAllowed(unknown, allowRealtime: true)
            || !Encoding.UTF8.GetString(unknown).Contains("\"sourceMode\":\"unknown\"", StringComparison.Ordinal)
            || !Encoding.UTF8.GetString(unknown).Contains("\"observedAt\":null", StringComparison.Ordinal)
            || !Encoding.UTF8.GetString(unknown).Contains("\"sourceResolutionMs\":null", StringComparison.Ordinal))
        {
            throw new InvalidOperationException();
        }

        var observedAt = DateTimeOffset.Parse("2026-10-25T04:05:06.789Z", CultureInfo.InvariantCulture);
        var observation = new SourceReadObservation(
            SourceReadMode.Poll,
            observedAt,
            Stopwatch.GetTimestamp() - Stopwatch.Frequency / 4,
            1_000);
        if (!RealtimeReportBody.TryAppendSourceTiming(bytes, observation, Stopwatch.GetTimestamp(), 60,
                out var realtime, out var age)
            || realtime is null
            || age is not (>= 0 and <= 1_000)
            || !ReportPayloadWhitelist.IsAllowed(realtime, allowRealtime: true))
        {
            throw new InvalidOperationException();
        }

        using var parsed = JsonDocument.Parse(realtime);
        var fields = parsed.RootElement.GetProperty("realtime");
        if (fields.GetProperty("sourceMode").GetString() != "poll"
            || fields.GetProperty("observedAt").GetString() != "2026-10-25T04:06:06.789Z"
            || fields.GetProperty("observationAgeMs").GetInt32() != age!.Value
            || fields.GetProperty("sourceResolutionMs").GetInt32() != 1_000)
        {
            throw new InvalidOperationException();
        }

        var stale = observation with { ObservedAtTimestamp = Stopwatch.GetTimestamp() - 2 * Stopwatch.Frequency };
        if (RealtimeReportBody.TryAppendSourceTiming(bytes, stale, Stopwatch.GetTimestamp(), 0, out _, out var staleAge)
            || staleAge is not (> 1_000))
        {
            throw new InvalidOperationException();
        }

        var realtimeText = Encoding.UTF8.GetString(realtime);
        var validAge = "\"observationAgeMs\":" + age.Value.ToString(CultureInfo.InvariantCulture);
        var unknownText = Encoding.UTF8.GetString(unknown);
        var invalidTimings = new[]
        {
            Encoding.UTF8.GetBytes(realtimeText.Replace(validAge, "\"observationAgeMs\":-1", StringComparison.Ordinal)),
            Encoding.UTF8.GetBytes(unknownText.Replace("\"observationAgeMs\":null", "\"observationAgeMs\":0", StringComparison.Ordinal)),
            Encoding.UTF8.GetBytes(unknownText.Replace("\"sourceMode\":\"unknown\"", "\"sourceMode\":\"unknown\",\"ignored\":true", StringComparison.Ordinal)),
        };
        if (invalidTimings.Any(invalid => ReportPayloadWhitelist.IsAllowed(invalid, allowRealtime: true)))
        {
            throw new InvalidOperationException();
        }
    }

    private static void SourceReadObservationTracksOnlyNewTranscriptResponses()
    {
        var root = Path.Combine(Path.GetTempPath(), "agent-speed-source-observation-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "rollout.jsonl");
        try
        {
            File.WriteAllText(path, string.Empty);
            var configuration = new MonitorConfiguration(new HashSet<SourceKind> { SourceKind.Codex }, CodexRoot: root);
            using var monitor = new MonitorCore(configuration, root, string.Empty, string.Empty, todayStartMs: 0);
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            monitor.Seed(now, 0, CancellationToken.None);

            var line = string.Create(CultureInfo.InvariantCulture,
                $"{{\"timestamp\":\"{DateTimeOffset.UtcNow:yyyy-MM-dd'T'HH:mm:ss.fff'Z'}\",\"type\":\"token_usage_record\",\"payload\":{{\"thread_id\":\"thread-test\",\"response_id\":\"response-test\",\"usage\":{{\"input_tokens\":10,\"output_tokens\":5}}}}}}\n");
            File.AppendAllText(path, line, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            _ = monitor.ProcessPaths([path], now + 1, 0);
            var fresh = monitor.BuildSnapshot(now + 1, 0, MonitorState.Running, observeLive: true).Snapshot;
            if (fresh.SourceReadObservation is not { SourceMode: SourceReadMode.Log, SourceResolutionMs: null } sourceObservation
                || sourceObservation.ObservedAt == default
                || sourceObservation.AgeMilliseconds(Stopwatch.GetTimestamp()) is < 0 or > 900_000)
            {
                throw new InvalidOperationException();
            }

            File.AppendAllText(path, line, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            _ = monitor.ProcessPaths([path], now + 2, 0);
            var duplicate = monitor.BuildSnapshot(now + 2, 0, MonitorState.Running, observeLive: true).Snapshot;
            var timerOnly = monitor.BuildSnapshot(now + 3, 0, MonitorState.Running, observeLive: true).Snapshot;
            if (duplicate.SourceReadObservation is not null || timerOnly.SourceReadObservation is not null)
            {
                throw new InvalidOperationException();
            }
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static void SourceReadObservationBufferMergesEarliestWindowMetadata()
    {
        var first = new SourceReadObservation(
            SourceReadMode.Log,
            DateTimeOffset.Parse("2026-10-25T04:05:06.000Z", CultureInfo.InvariantCulture),
            1_000,
            null);
        var second = new SourceReadObservation(
            SourceReadMode.Poll,
            DateTimeOffset.Parse("2026-10-25T04:05:07.000Z", CultureInfo.InvariantCulture),
            2_000,
            1_000);
        var buffer = new SourceReadObservationBuffer();
        buffer.Observe(first);
        buffer.Observe(second);
        var merged = buffer.Take();
        if (merged is not { SourceMode: SourceReadMode.Mixed, SourceResolutionMs: null }
            || merged.ObservedAtTimestamp != first.ObservedAtTimestamp
            || buffer.Take() is not null)
        {
            throw new InvalidOperationException();
        }

        buffer.Observe(second);
        buffer.Clear();
        if (buffer.Take() is not null)
        {
            throw new InvalidOperationException();
        }
    }

    private static async Task SnapshotMailboxKeepsTimingAlignedWithUnconsumedLatestSnapshotAsync()
    {
        var first = new SourceReadObservation(
            SourceReadMode.Log,
            DateTimeOffset.Parse("2026-10-25T04:05:06.000Z", CultureInfo.InvariantCulture),
            1_000,
            null);
        var second = new SourceReadObservation(
            SourceReadMode.Poll,
            DateTimeOffset.Parse("2026-10-25T04:05:07.000Z", CultureInfo.InvariantCulture),
            2_000,
            1_000);
        var afterTake = new SourceReadObservation(
            SourceReadMode.Poll,
            DateTimeOffset.Parse("2026-10-25T04:05:08.000Z", CultureInfo.InvariantCulture),
            3_000,
            1_000);
        var mailbox = new SnapshotMailbox();
        mailbox.Publish(SpeedSnapshot.Empty with
        {
            Today = new TokenTotals(Requests: 1, Output: 4),
            SourceReadObservation = first,
        });
        mailbox.Publish(SpeedSnapshot.Empty with
        {
            Today = new TokenTotals(Requests: 2, Output: 9),
            SourceReadObservation = second,
        });

        if (!mailbox.TryRead(out var latest)
            || latest.Today.Requests != 2
            || latest.Today.Output != 9
            || latest.SourceReadObservation is not { SourceMode: SourceReadMode.Mixed, SourceResolutionMs: null } merged
            || merged.ObservedAtTimestamp != first.ObservedAtTimestamp)
        {
            throw new InvalidOperationException();
        }

        var currentWindowObservations = new SourceReadObservationBuffer();
        currentWindowObservations.Observe(latest.SourceReadObservation);
        var currentWindowObservation = currentWindowObservations.Take();
        if (currentWindowObservation != latest.SourceReadObservation || currentWindowObservations.Take() is not null)
        {
            throw new InvalidOperationException();
        }

        var nextRead = mailbox.ReadAsync().AsTask();
        if (nextRead.IsCompleted)
        {
            throw new InvalidOperationException();
        }

        mailbox.Publish(SpeedSnapshot.Empty with
        {
            Today = new TokenTotals(Requests: 3, Output: 12),
            SourceReadObservation = afterTake,
        });
        var next = await nextRead.ConfigureAwait(false);
        if (next.Today.Requests != 3
            || next.Today.Output != 12
            || next.SourceReadObservation != afterTake)
        {
            throw new InvalidOperationException();
        }
    }

    private static void ExplicitTransportDoesNotFallBackToHttp()
    {
        if (ReporterTransportChoice.StartFailure("http", supportsWebSocket: false) is not null
            || ReporterTransportChoice.UsesWebSocket("http")
            || ReporterTransportChoice.StartFailure("websocket", supportsWebSocket: false) != "websocket_not_supported"
            || !ReporterTransportChoice.UsesWebSocket("websocket"))
        {
            throw new InvalidOperationException();
        }
    }

    private static void WebSocketAcknowledgementsRequireTheExactPendingTupleAndConnection()
    {
        const string runId = "c3d4e5f6-a7b8-4c9d-8e0f-1a2b3c4d5e6f";
        const string hash = "5432dab6e9dfe089930177ace227082abec9824e2ed9c9b0fa902f37bb4502e3";
        var acceptedAt = DateTimeOffset.Parse("2026-10-24T20:00:00.028Z", System.Globalization.CultureInfo.InvariantCulture);
        var ack = new WebSocketAck(runId, 42, "accepted", hash, acceptedAt, acceptedAt);
        if (!WebSocketAckMatcher.Matches(ack, runId, 42, hash, pendingGeneration: 7, currentGeneration: 7)
            || WebSocketAckMatcher.Matches(ack, "00000000-0000-4000-8000-000000000000", 42, hash, 7, 7)
            || WebSocketAckMatcher.Matches(ack, runId, 43, hash, 7, 7)
            || WebSocketAckMatcher.Matches(ack, runId, 42, new string('0', 64), 7, 7)
            || WebSocketAckMatcher.Matches(ack, runId, 42, hash, pendingGeneration: 6, currentGeneration: 7))
        {
            throw new InvalidOperationException();
        }
    }

    private static void WebSocketDropsBackpressureAndSleepWindows()
    {
        var window = new WebSocketReportWindow(UsageSample(0));
        var beforeBackpressure = UsageSample(5);
        if (!window.HasTokenIncrement(beforeBackpressure))
        {
            throw new InvalidOperationException();
        }

        window.Observe(beforeBackpressure);
        var atCapacity = UsageSample(9);
        window.DropAndRebase(atCapacity);
        var afterCapacity = UsageSample(10);
        var next = window.Take(afterCapacity);
        if (next.Usage.Total.Output != 1)
        {
            throw new InvalidOperationException();
        }

        window.ResetForReconnectOrResume(UsageSample(17));
        var afterResume = window.Take(UsageSample(18));
        if (afterResume.Usage.Total.Output != 1)
        {
            throw new InvalidOperationException();
        }
    }

    private static void WebSocketRetryAfterRemainsAMinimumDeadline()
    {
        if (WebSocketRetryDelay.CalculateMilliseconds(failureCount: 1, retryAfterSeconds: 60, jitter: 0.8) != 60_000
            || WebSocketRetryDelay.CalculateMilliseconds(failureCount: 1, retryAfterSeconds: 1, jitter: 0.8) != 5_000
            || WebSocketRetryDelay.CalculateMilliseconds(failureCount: 7, retryAfterSeconds: 5, jitter: 1.2) != 36_000
            || WebSocketRetryDelay.CalculateMilliseconds(failureCount: 1, retryAfterSeconds: null, jitter: 0.8) != 400)
        {
            throw new InvalidOperationException();
        }
    }

    private static void WebSocketRequestsSignTheExactV1BytesAndKeepTheApiBasePath()
    {
        const string deviceId = "6f1c2a9e-3b4d-4e5f-8a7b-9c0d1e2f3a4b";
        const string handshakeNonce = "EBESExQVFhcYGRobHB0eHw";
        using var signer = new SoftwareReportSigner();
        var api = ReportServiceUrl.ParseApi("https://api.example.com/agent-speed", discoveryIsLoopbackHttp: false)!;
        var builder = new ReportRequestBuilder("AgentSpeed/0.9.7 (Windows)", deviceId, ApiKey: null);
        var handshake = builder.Make("GET", api.WebSocketEndpoint(), Array.Empty<byte>(), signer,
            1_792_872_000, nonce: handshakeNonce);
        var handshakeCanonical = ReportCanonical.Build("GET", "api.example.com", "/agent-speed/v1/reports/ws",
            "1792872000", handshakeNonce, deviceId, Array.Empty<byte>());
        if (api.WebSocketEndpoint().AbsoluteUri != "wss://api.example.com/agent-speed/v1/reports/ws"
            || handshake.Header("Content-Type") is not null
            || handshake.Header(ReportCanonical.SignatureHeader) is not { } handshakeSignature
            || !signer.PublicKey.Verify(Encoding.UTF8.GetBytes(handshakeCanonical), Base64Url.Decode(handshakeSignature) ?? []))
        {
            throw new InvalidOperationException();
        }

        var body = Encoding.UTF8.GetBytes("{\"schema\":1,\"realtime\":{\"sourceMode\":\"unknown\",\"observedAt\":null,\"observationAgeMs\":null,\"sourceResolutionMs\":null}}");
        var post = builder.Make("POST", api.Endpoint(ReportEndpoint.Reports), body, signer,
            1_792_872_000, nonce: "AAECAwQFBgcICQoLDA0ODw");
        var encoded = ReportWebSocketSession.EncodeReport(post);
        using var outer = JsonDocument.Parse(encoded);
        if (outer.RootElement.GetProperty("type").GetString() != "report"
            || outer.RootElement.GetProperty("body").GetString() != Encoding.UTF8.GetString(body)
            || outer.RootElement.GetProperty("headers").EnumerateObject().Count() != 4)
        {
            throw new InvalidOperationException();
        }
    }

    private static ReportSample UsageSample(long output)
    {
        var counters = new ReportCounters();
        if (output > 0)
        {
            counters.Add(new ReportUsage(Requests: 1, Output: output), new ReportModelKey("gpt-5", SourceKind.Codex));
        }

        var facts = new ReportLiveFacts(
            new Dictionary<SourceKind, ReportAgentCounts>(),
            new Dictionary<ReportModelKey, int>(),
            counters,
            Epoch: 1);
        return ReportSample.Empty with { Facts = facts };
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
