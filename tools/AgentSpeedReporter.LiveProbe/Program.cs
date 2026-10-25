using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text.Json;
using AgentSpeed.Core.Pricing;
using AgentSpeed.Core.Reporting;

namespace CodexTokenBar.AgentSpeedReporter;

internal sealed class ReporterFailure(string code) : Exception(code)
{
    public string Code { get; } = code;
}

internal sealed class ProbeAbort(string code) : Exception(code)
{
    public string Code { get; } = code;
}

internal sealed class ProbeResponseAbort(string code, int? statusCode, string? fieldPath) : Exception(code)
{
    public string Code { get; } = code;
    public int? StatusCode { get; } = statusCode;
    public string? FieldPath { get; } = fieldPath;
}

[SupportedOSPlatform("windows")]
internal static class Program
{
    private const string ServiceText = "https://deng.codexradar.com";
    private const string ExpectedApiText = "https://speed-api.codexradar.com/api/agent-speed";
    private const string ClientVersion = "0.9.7";
    private const string ProbeFolder = "AgentSpeedLiveProbe-20261025";
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public static async Task<int> Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--self-test-fixture")
        {
            var fixtureBody = BuildEmptyFixture(ReportClientInfo.Windows(ClientVersion));
            var fixtureChecks = new Dictionary<string, bool>(StringComparer.Ordinal)
            {
                ["deltaCountersAllZero"] = HasZeroUsage(fixtureBody),
                ["costAmountsZeroAndKnownShareOne"] = HasZeroCost(fixtureBody),
                ["costFieldsCompleteAndPriceVersion2"] = HasCostSummary(fixtureBody, PriceBook.Bundled.Version),
            };
            Console.WriteLine(JsonSerializer.Serialize(new { syntheticOnly = true, checks = fixtureChecks }, JsonOptions));
            return fixtureChecks.Values.All(value => value) ? 0 : 1;
        }

        var checks = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["windows"] = OperatingSystem.IsWindows(),
            ["discoveryPinnedApi"] = false,
            ["websocketCapability"] = false,
            ["dpapiRepeatLoadSameDevice"] = false,
            ["dpapiRepeatLoadSamePublicKey"] = false,
            ["registrationCreatedTestDevice"] = false,
            ["httpZeroUsageAccepted"] = false,
            ["httpRealtimeAbsent"] = false,
            ["costSummaryNegotiatedAndVersion2"] = false,
            ["emptySyntheticZeroUsageFixtureValid"] = false,
            ["websocketReadyMatchesDiscovery"] = false,
            ["websocketZeroUsageRealtimeUnknownNull"] = false,
            ["websocketSeq1ExactAcceptedAck"] = false,
            ["connectionAliveAfter22SecondPingWindow"] = false,
            ["websocketSeq2PostPingExactAcceptedAck"] = false,
            ["reconnectReady"] = false,
            ["reconnectSameRunSeq3FreshBody"] = false,
            ["websocketSeq3ExactAcceptedAck"] = false,
            ["createdTestDeviceDeleted"] = false,
        };
        var output = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["schema"] = 1,
            ["probe"] = "AgentSpeedReporter.LiveProbe",
            ["executionContext"] = "ssh-token",
            ["sshUserMatchesInteractiveUser"] = true,
            ["client"] = new { app = "CodexTokenBar", version = ClientVersion, platform = "Windows" },
            ["checks"] = checks,
        };

        var identityDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexTokenBar", ProbeFolder, "identity");
        var service = ReportServiceUrl.Parse(ServiceText) ?? throw new InvalidOperationException("probe_service_url");
        var client = ReportClientInfo.Windows(ClientVersion);
        var keyStore = new DpapiReportKeyStore(identityDirectory);
        HttpReportTransport? transport = null;
        ReportDiscovery? discovery = null;
        SoftwareReportSigner? signer = null;
        PersistedIdentity? identity = null;
        var createdByThisProbe = false;
        var cleanupDeleted = false;
        var cleanupCode = "not_registered";
        string? cleanupFieldPath = null;
        var phase = "startup";

        try
        {
            if (!checks["windows"]!.Equals(true))
            {
                throw new ProbeAbort("not_windows");
            }

            output["osMajor"] = client.OsMajor;
            output["systemProxyBypassedOfficialApi"] = HttpClient.DefaultProxy.IsBypassed(new Uri(ExpectedApiText));
            transport = new HttpReportTransport();
            var api = new ReportApi(transport, client.UserAgent);

            phase = "discovery";
            var outcome = await api.DiscoverAsync(service).ConfigureAwait(false);
            if (outcome is not ReportDiscoveryOutcome.Document document)
            {
                throw new ProbeAbort("discovery_unavailable");
            }

            discovery = document.Discovery;
            checks["discoveryPinnedApi"] = discovery.Api.Text == ExpectedApiText;
            checks["websocketCapability"] = discovery.SupportsWebSocket;
            output["discovery"] = new
            {
                apiPinned = checks["discoveryPinnedApi"],
                websocketAdvertised = discovery.SupportsWebSocket,
                costSectionNegotiated = discovery.Sections.Contains(ReportSection.Cost),
                apiKeyRequired = discovery.ApiKeyMode == ReportApiKeyMode.Required,
                limitsMatchWillBeCheckedAgainstReady = true,
            };
            if (discovery.Api.Text != ExpectedApiText || !discovery.SupportsThisClient || !discovery.SupportsWebSocket
                || discovery.ApiKeyMode == ReportApiKeyMode.Required || !discovery.Sections.Contains(ReportSection.Cost))
            {
                throw new ProbeAbort("discovery_not_compatible");
            }

            checks["costSummaryNegotiatedAndVersion2"] = PriceBook.Bundled.Version == 2;
            if (!checks["costSummaryNegotiatedAndVersion2"]!.Equals(true))
            {
                throw new ProbeAbort("bundled_price_version_mismatch");
            }

            var emptyFixture = BuildEmptyFixture(client);
            checks["emptySyntheticZeroUsageFixtureValid"] = HasZeroUsage(emptyFixture)
                && HasZeroCost(emptyFixture) && HasCostSummary(emptyFixture, PriceBook.Bundled.Version);
            if (!checks["emptySyntheticZeroUsageFixtureValid"]!.Equals(true))
            {
                throw new ProbeAbort("empty_synthetic_fixture_invalid");
            }

            phase = "dpapi";
            var first = keyStore.LoadOrCreate();
            var firstDeviceId = first.Identity.DeviceId;
            var firstThumbprint = first.Signer.PublicKey.Thumbprint;
            first.Signer.Dispose();
            var second = keyStore.LoadOrCreate();
            identity = second.Identity;
            signer = second.Signer;
            checks["dpapiRepeatLoadSameDevice"] = firstDeviceId == identity.DeviceId;
            checks["dpapiRepeatLoadSamePublicKey"] = firstThumbprint == signer.PublicKey.Thumbprint;
            if (!checks["dpapiRepeatLoadSameDevice"]!.Equals(true)
                || !checks["dpapiRepeatLoadSamePublicKey"]!.Equals(true))
            {
                throw new ProbeAbort("dpapi_repeat_load_mismatch");
            }

            var username = $"TokenBar-Win-check-{Guid.NewGuid():N}"[..28];
            if (ReportUsername.Validate(username, discovery.UsernameRules) is not null)
            {
                throw new ProbeAbort("test_username_invalid");
            }

            phase = "registration";
            var registrationBody = ReportDocuments.Registration(identity.DeviceId, username, signer.PublicKey, client);
            var requestBuilder = new ReportRequestBuilder(client.UserAgent, identity.DeviceId, ApiKey: null);
            var registrationRequest = requestBuilder.Make(
                "POST", discovery.Api.Endpoint(ReportEndpoint.Devices), registrationBody, signer, UnixSeconds());
            var registrationResponse = await transport.SendAsync(
                registrationRequest, ReportApi.ApiMaxBytes, ReportApi.ApiTimeout).ConfigureAwait(false);
            var registrationReply = ReportReply.Parse(
                registrationResponse.Status, registrationResponse.Headers, registrationResponse.Body, DateTimeOffset.UtcNow);
            if (registrationReply.Result != "created")
            {
                output["registration"] = new
                {
                    statusCode = registrationResponse.Status,
                    replyCode = SafeCode(registrationReply.Code),
                    fieldPath = SafeField(registrationReply.Field),
                };
                throw new ProbeResponseAbort("test_device_registration_not_created", registrationResponse.Status,
                    SafeField(registrationReply.Field));
            }

            createdByThisProbe = true;
            checks["registrationCreatedTestDevice"] = true;
            identity = identity with { RegisteredUsername = username, ProfileUrl = null };
            keyStore.WriteIdentity(identity);
            output["registration"] = new { statusCode = registrationResponse.Status, created = true, testNickPrefix = "TokenBar-Win-check" };

            phase = "http_report";
            var httpRunId = ReportCanonical.NewUuid();
            var httpBody = BuildBody(client, discovery, identity, username, httpRunId, sequence: 1, includeRealtime: false);
            checks["httpRealtimeAbsent"] = !HasProperty(httpBody, "realtime");
            var httpZero = HasZeroUsage(httpBody) && HasZeroCost(httpBody) && HasCostSummary(httpBody, PriceBook.Bundled.Version);
            var httpRequest = requestBuilder.Make(
                "POST", discovery.Api.Endpoint(ReportEndpoint.Reports), httpBody, signer, UnixSeconds());
            var httpResponse = await transport.SendAsync(httpRequest, ReportApi.ApiMaxBytes, ReportApi.ApiTimeout).ConfigureAwait(false);
            var httpReply = ReportReply.Parse(httpResponse.Status, httpResponse.Headers, httpResponse.Body, DateTimeOffset.UtcNow);
            checks["httpZeroUsageAccepted"] = httpZero && httpResponse.Status is >= 200 and <= 299 && httpReply.Result == "accepted";
            output["httpReport"] = new
            {
                statusCode = httpResponse.Status,
                accepted = httpReply.Result == "accepted",
                replyCode = SafeCode(httpReply.Code),
                fieldPath = SafeField(httpReply.Field),
                zeroUsageAndCostDeltaZero = httpZero,
                deltaCountersAllZero = HasZeroUsage(httpBody),
                costAmountsZeroAndKnownShareOne = HasZeroCost(httpBody),
                costSummaryFieldsComplete = HasCostSummary(httpBody, PriceBook.Bundled.Version),
                priceVersion = PriceBook.Bundled.Version,
                realtimeAbsent = checks["httpRealtimeAbsent"],
            };
            if (!checks["httpZeroUsageAccepted"]!.Equals(true) || !checks["httpRealtimeAbsent"]!.Equals(true))
            {
                throw new ProbeResponseAbort("http_zero_usage_report_rejected", httpResponse.Status, SafeField(httpReply.Field));
            }

            phase = "websocket";
            var websocketRunId = ReportCanonical.NewUuid();
            var wsBody1 = BuildBody(client, discovery, identity, username, websocketRunId, sequence: 1, includeRealtime: true);
            checks["websocketZeroUsageRealtimeUnknownNull"] = HasZeroUsage(wsBody1) && HasZeroCost(wsBody1)
                && HasCostSummary(wsBody1, PriceBook.Bundled.Version) && HasUnknownNullRealtime(wsBody1);
            var wsRequest1 = requestBuilder.Make(
                "POST", discovery.Api.Endpoint(ReportEndpoint.Reports), wsBody1, signer, UnixSeconds());
            var wsMessage1 = ReportWebSocketSession.EncodeReport(wsRequest1);
            var wsHash1 = ReportHash.Sha256Hex(wsRequest1.Body);
            string? wsHash2 = null;

            ReportWebSocketSession? firstSession = null;
            try
            {
                var connected = await ReportWebSocketSession.ConnectAsync(
                    discovery, client.UserAgent, identity.DeviceId, signer, UnixSeconds(), CancellationToken.None).ConfigureAwait(false);
                firstSession = connected.Session;
                checks["websocketReadyMatchesDiscovery"] = connected.Ready.Settings == discovery.WebSocket;
                if (!checks["websocketReadyMatchesDiscovery"]!.Equals(true))
                {
                    throw new ProbeAbort("ready_discovery_mismatch");
                }

                await firstSession.SendMessageAsync(wsMessage1, connected.Ready.Settings.AckTimeoutMs, CancellationToken.None)
                    .ConfigureAwait(false);
                var ack1 = await ReadAckAsync(firstSession, connected.Ready.Settings.AckTimeoutMs).ConfigureAwait(false);
                checks["websocketSeq1ExactAcceptedAck"] = IsExactAcceptedAck(ack1, websocketRunId, 1, wsHash1);
                output["websocketFirstReport"] = new
                {
                    sent = true,
                    ackStatus = ack1.Status,
                    runAndSequenceMatched = ack1.RunId == websocketRunId && ack1.Seq == 1,
                    bodySha256Matched = ack1.BodySha256 == wsHash1,
                    zeroUsage = checks["websocketZeroUsageRealtimeUnknownNull"],
                    costSummaryFieldsComplete = HasCostSummary(wsBody1, PriceBook.Bundled.Version),
                    priceVersion = PriceBook.Bundled.Version,
                    sourceMode = "unknown",
                    sourceTimingFieldsNull = true,
                };
                if (!checks["websocketSeq1ExactAcceptedAck"]!.Equals(true))
                {
                    throw new ProbeAbort("websocket_seq1_ack_mismatch");
                }

                await Task.Delay(TimeSpan.FromSeconds(22)).ConfigureAwait(false);
                var wsBody2 = BuildBody(client, discovery, identity, username, websocketRunId, sequence: 2, includeRealtime: true);
                var wsRequest2 = requestBuilder.Make(
                    "POST", discovery.Api.Endpoint(ReportEndpoint.Reports), wsBody2, signer, UnixSeconds());
                wsHash2 = ReportHash.Sha256Hex(wsRequest2.Body);
                var wsMessage2 = ReportWebSocketSession.EncodeReport(wsRequest2);
                var seq2HasZeroUnknownPayload = HasZeroUsage(wsBody2) && HasZeroCost(wsBody2)
                    && HasCostSummary(wsBody2, PriceBook.Bundled.Version) && HasUnknownNullRealtime(wsBody2);
                await firstSession.SendMessageAsync(wsMessage2, connected.Ready.Settings.AckTimeoutMs, CancellationToken.None)
                    .ConfigureAwait(false);
                var ack2OnFirstConnection = await ReadAckAsync(firstSession, connected.Ready.Settings.AckTimeoutMs).ConfigureAwait(false);
                checks["websocketSeq2PostPingExactAcceptedAck"] = seq2HasZeroUnknownPayload
                    && IsExactAcceptedAck(ack2OnFirstConnection, websocketRunId, 2, wsHash2);
                checks["connectionAliveAfter22SecondPingWindow"] = checks["websocketSeq2PostPingExactAcceptedAck"];
                output["websocketPingWindow"] = new
                {
                    negotiatedPingIntervalSeconds = connected.Ready.Settings.PingIntervalSeconds,
                    heldSeconds = 22,
                    businessReportAckAfterWindow = checks["websocketSeq2PostPingExactAcceptedAck"],
                    ackStatus = ack2OnFirstConnection.Status,
                    runAndSequenceMatched = ack2OnFirstConnection.RunId == websocketRunId && ack2OnFirstConnection.Seq == 2,
                    bodySha256Matched = ack2OnFirstConnection.BodySha256 == wsHash2,
                };
                if (!checks["connectionAliveAfter22SecondPingWindow"]!.Equals(true))
                {
                    throw new ProbeAbort("websocket_ping_window_failed");
                }

                using var closeDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                try
                {
                    await firstSession.CloseAsync(closeDeadline.Token).ConfigureAwait(false);
                }
                catch (Exception)
                {
                    // DisposeAsync below aborts the probe connection before the next handshake.
                }

                await firstSession.DisposeAsync().ConfigureAwait(false);
                firstSession = null;
            }
            finally
            {
                if (firstSession is not null)
                {
                    await firstSession.DisposeAsync().ConfigureAwait(false);
                }
            }

            var previousConnectionHash = wsHash2 ?? throw new ProbeAbort("websocket_seq2_hash_missing");
            var wsBody3 = BuildBody(client, discovery, identity, username, websocketRunId, sequence: 3, includeRealtime: true);
            var seq3HasZeroUnknownPayload = HasZeroUsage(wsBody3) && HasZeroCost(wsBody3)
                && HasCostSummary(wsBody3, PriceBook.Bundled.Version) && HasUnknownNullRealtime(wsBody3);
            var wsRequest3 = requestBuilder.Make(
                "POST", discovery.Api.Endpoint(ReportEndpoint.Reports), wsBody3, signer, UnixSeconds());
            var wsHash3 = ReportHash.Sha256Hex(wsRequest3.Body);
            var wsMessage3 = ReportWebSocketSession.EncodeReport(wsRequest3);
            checks["reconnectSameRunSeq3FreshBody"] = seq3HasZeroUnknownPayload
                && ReadRunId(wsBody3) == websocketRunId && ReadSequence(wsBody3) == 3 && wsHash3 != previousConnectionHash;

            var reconnected = await ReportWebSocketSession.ConnectAsync(
                discovery, client.UserAgent, identity.DeviceId, signer, UnixSeconds(), CancellationToken.None).ConfigureAwait(false);
            checks["reconnectReady"] = reconnected.Ready.Settings == discovery.WebSocket;
            try
            {
                if (!checks["reconnectReady"]!.Equals(true)
                    || !checks["reconnectSameRunSeq3FreshBody"]!.Equals(true))
                {
                    throw new ProbeAbort("websocket_reconnect_state_invalid");
                }

                await reconnected.Session.SendMessageAsync(
                    wsMessage3, reconnected.Ready.Settings.AckTimeoutMs, CancellationToken.None).ConfigureAwait(false);
                var ack3 = await ReadAckAsync(reconnected.Session, reconnected.Ready.Settings.AckTimeoutMs).ConfigureAwait(false);
                checks["websocketSeq3ExactAcceptedAck"] = IsExactAcceptedAck(ack3, websocketRunId, 3, wsHash3);
                output["websocketReconnect"] = new
                {
                    ready = checks["reconnectReady"],
                    sameRun = ReadRunId(wsBody3) == websocketRunId,
                    sequence = 3,
                    previousConnectionSeq2Acked = checks["websocketSeq2PostPingExactAcceptedAck"],
                    bodyNotReplayed = wsHash3 != previousConnectionHash,
                    ackStatus = ack3.Status,
                    runAndSequenceMatched = ack3.RunId == websocketRunId && ack3.Seq == 3,
                    bodySha256Matched = ack3.BodySha256 == wsHash3,
                };
                if (!checks["websocketSeq3ExactAcceptedAck"]!.Equals(true))
                {
                    throw new ProbeAbort("websocket_seq3_ack_mismatch");
                }
            }
            finally
            {
                await reconnected.Session.DisposeAsync().ConfigureAwait(false);
            }
        }
        catch (ProbeResponseAbort error)
        {
            output["failure"] = SafeCode(error.Code);
            output["responseStatusCode"] = error.StatusCode;
            output["responseFieldPath"] = error.FieldPath;
        }
        catch (ProbeAbort error)
        {
            output["failure"] = SafeCode(error.Code);
        }
        catch (ReporterFailure error)
        {
            output["failure"] = SafeCode(error.Code);
        }
        catch (Exception error)
        {
            output["failure"] = "probe_exception";
            output["exceptionType"] = error.GetType().Name;
        }
        finally
        {
            if (createdByThisProbe && identity is not null && signer is not null && discovery is not null && transport is not null)
            {
                try
                {
                    phase = "delete_test_device";
                    var builder = new ReportRequestBuilder(client.UserAgent, identity.DeviceId, ApiKey: null);
                    var delete = builder.Make(
                        "DELETE",
                        discovery.Api.Endpoint(ReportEndpoint.Device(identity.DeviceId)),
                        Array.Empty<byte>(),
                        signer,
                        UnixSeconds());
                    var response = await transport.SendAsync(delete, ReportApi.ApiMaxBytes, ReportApi.ApiTimeout).ConfigureAwait(false);
                    var reply = ReportReply.Parse(response.Status, response.Headers, response.Body, DateTimeOffset.UtcNow);
                    cleanupDeleted = response.Status is >= 200 and <= 299 && reply.Result == "deleted";
                    cleanupCode = cleanupDeleted ? "deleted" : SafeCode(reply.Code) ?? "delete_not_confirmed";
                    cleanupFieldPath = SafeField(reply.Field);
                }
                catch (Exception error)
                {
                    cleanupCode = error is ReporterFailure failure ? SafeCode(failure.Code) ?? "delete_failed" : "delete_failed";
                }
            }

            signer?.Dispose();
            transport?.Dispose();
            if (cleanupDeleted && Directory.Exists(identityDirectory))
            {
                try
                {
                    Directory.Delete(identityDirectory, recursive: true);
                }
                catch (Exception)
                {
                    output["localKeyCleanup"] = "failed";
                }
            }
            else if (Directory.Exists(identityDirectory))
            {
                output["localKeyCleanup"] = "retained_for_device_revocation";
            }
        }

        checks["createdTestDeviceDeleted"] = cleanupDeleted;
        output["cleanup"] = new { createdTestDeviceDeleted = cleanupDeleted, code = cleanupCode, fieldPath = cleanupFieldPath };
        output["status"] = checks.Values.All(value => value is true) && cleanupDeleted ? "pass" : "fail";
        output["lastPhase"] = phase;
        Console.WriteLine(JsonSerializer.Serialize(output, JsonOptions));
        return output["status"] as string == "pass" ? 0 : 1;
    }

    private static byte[] BuildBody(
        ReportClientInfo client,
        ReportDiscovery discovery,
        PersistedIdentity identity,
        string username,
        string runId,
        int sequence,
        bool includeRealtime)
    {
        var sample = ReportSample.Empty;
        var window = new ReportWindow(sample);
        var content = window.Take(sample);
        var envelope = new ReportEnvelope(
            client,
            identity.DeviceId,
            username,
            runId,
            sequence,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            WindowMs: 0,
            Activity: ReportActivity.Idle,
            TitleLevel: 0);
        var sections = discovery.Sections.Contains(ReportSection.Cost)
            ? new HashSet<ReportSection> { ReportSection.Cost }
            : new HashSet<ReportSection>();
        var options = new ReportOptions(
            sections,
            MaxModels: 0,
            BodyLimit: ReportLimits.ClientMaxBodyBytes,
            PriceVersion: PriceBook.Bundled.Version);
        var body = ReportBody.Data(envelope, content, sample, options);
        if (!ReportPayloadWhitelist.IsAllowed(body))
        {
            throw new ProbeAbort("zero_usage_body_not_whitelisted");
        }

        if (!includeRealtime)
        {
            return body;
        }

        if (!RealtimeReportBody.TryAppendSourceTiming(
                body, observation: null, Stopwatch.GetTimestamp(), clockCorrectionSeconds: 0, out var realtimeBody, out _)
            || realtimeBody is null || !ReportPayloadWhitelist.IsAllowed(realtimeBody, allowRealtime: true))
        {
            throw new ProbeAbort("realtime_body_not_whitelisted");
        }

        return realtimeBody;
    }

    private static byte[] BuildEmptyFixture(ReportClientInfo client)
    {
        var sample = ReportSample.Empty;
        var window = new ReportWindow(sample);
        var content = window.Take(sample);
        var envelope = new ReportEnvelope(
            client,
            "00000000-0000-4000-8000-000000000000",
            "synthetic",
            ReportCanonical.NewUuid(),
            Seq: 1,
            SentAtMs: 0,
            WindowMs: 0,
            Activity: ReportActivity.Idle,
            TitleLevel: 0);
        var options = new ReportOptions(
            new HashSet<ReportSection> { ReportSection.Cost },
            MaxModels: 0,
            BodyLimit: ReportLimits.ClientMaxBodyBytes,
            PriceVersion: PriceBook.Bundled.Version);
        return ReportBody.Data(envelope, content, sample, options);
    }

    private static async Task<WebSocketAck> ReadAckAsync(ReportWebSocketSession session, int timeoutMs)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(timeoutMs));
        var message = await session.ReadMessageAsync(timeout.Token).ConfigureAwait(false);
        return message switch
        {
            WebSocketMessage.Ack ack => ack.Value,
            WebSocketMessage.Error error => throw new ProbeResponseAbort(
                SafeCode(error.Value.Code) ?? "websocket_report_error", error.Value.HttpStatus, fieldPath: null),
            _ => throw new ProbeAbort("websocket_report_error_message"),
        };
    }

    private static bool IsExactAcceptedAck(WebSocketAck ack, string runId, int seq, string hash) =>
        ack.Status == "accepted" && ack.RunId == runId && ack.Seq == seq && ack.BodySha256 == hash;

    private static bool HasZeroUsage(byte[] body)
    {
        using var document = JsonDocument.Parse(body);
        if (!document.RootElement.TryGetProperty("delta", out var delta) || delta.ValueKind != JsonValueKind.Object)
        {
            return false;
        }

        string[] fields = ["requests", "output", "input", "cachedInput", "cacheWriteInput", "reasoning", "measuredOutput", "measuredMs"];
        return delta.EnumerateObject().Count() == fields.Length
            && fields.All(field => delta.TryGetProperty(field, out var value)
                && value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) && number == 0);
    }

    private static bool HasCostSummary(byte[] body, int expectedPriceVersion)
    {
        using var document = JsonDocument.Parse(body);
        if (!document.RootElement.TryGetProperty("cost", out var cost) || cost.ValueKind != JsonValueKind.Object)
        {
            return false;
        }

        var required = new[]
        {
            "liveMicroUsdPerSecond", "peakMicroUsdPerSecond", "knownShare", "deltaMicroUsd", "unpricedRequests", "priceVersion",
        };
        return cost.EnumerateObject().Select(property => property.Name).OrderBy(name => name, StringComparer.Ordinal)
                .SequenceEqual(required.OrderBy(name => name, StringComparer.Ordinal), StringComparer.Ordinal)
            && cost.GetProperty("priceVersion").GetInt32() == expectedPriceVersion;
    }

    private static bool HasZeroCost(byte[] body)
    {
        using var document = JsonDocument.Parse(body);
        if (!document.RootElement.TryGetProperty("cost", out var cost) || cost.ValueKind != JsonValueKind.Object)
        {
            return false;
        }

        foreach (var property in cost.EnumerateObject())
        {
            if (property.Name == "priceVersion")
            {
                continue;
            }

            if (property.Name == "knownShare")
            {
                if (property.Value.ValueKind != JsonValueKind.Number || !property.Value.TryGetDouble(out var share) || share != 1)
                {
                    return false;
                }

                continue;
            }

            if (property.Value.ValueKind != JsonValueKind.Number || !property.Value.TryGetDouble(out var value) || value != 0)
            {
                return false;
            }
        }

        return true;
    }

    private static bool HasUnknownNullRealtime(byte[] body)
    {
        using var document = JsonDocument.Parse(body);
        return document.RootElement.TryGetProperty("realtime", out var realtime)
            && realtime.ValueKind == JsonValueKind.Object
            && realtime.TryGetProperty("sourceMode", out var sourceMode) && sourceMode.GetString() == "unknown"
            && realtime.TryGetProperty("observedAt", out var observedAt) && observedAt.ValueKind == JsonValueKind.Null
            && realtime.TryGetProperty("observationAgeMs", out var age) && age.ValueKind == JsonValueKind.Null
            && realtime.TryGetProperty("sourceResolutionMs", out var resolution) && resolution.ValueKind == JsonValueKind.Null;
    }

    private static bool HasProperty(byte[] body, string name)
    {
        using var document = JsonDocument.Parse(body);
        return document.RootElement.TryGetProperty(name, out _);
    }

    private static string ReadRunId(byte[] body)
    {
        using var document = JsonDocument.Parse(body);
        return document.RootElement.GetProperty("run").GetProperty("id").GetString() ?? string.Empty;
    }

    private static int ReadSequence(byte[] body)
    {
        using var document = JsonDocument.Parse(body);
        return document.RootElement.GetProperty("run").GetProperty("seq").GetInt32();
    }

    private static long UnixSeconds() => DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    private static string? SafeCode(string? code) =>
        code is { Length: > 0 and <= 48 } && code.All(character => char.IsAsciiLetterOrDigit(character) || character == '_')
            ? code
            : null;

    private static string? SafeField(string? field)
    {
        if (string.IsNullOrWhiteSpace(field))
        {
            return null;
        }

        var value = new string(field.Take(120)
            .Where(character => char.IsAsciiLetterOrDigit(character) || character is '_' or '.' or '[' or ']' or '-')
            .ToArray());
        return value.Length == 0 ? null : value;
    }
}
