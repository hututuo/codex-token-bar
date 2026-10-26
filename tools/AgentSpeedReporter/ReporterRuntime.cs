using System.Diagnostics;
using System.Runtime.Versioning;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Text;
using System.Net.WebSockets;
using System.Threading.Channels;
using AgentSpeed.Core;
using AgentSpeed.Core.Reporting;
using AgentSpeed.Core.Pricing;

namespace CodexTokenBar.AgentSpeedReporter;

internal sealed class ReporterFailure(string code) : Exception(code)
{
    public string Code { get; } = code;
}

[SupportedOSPlatform("windows")]
internal static class ReporterRuntime
{
    private const string ServiceText = "https://deng.codexradar.com";
    private const string ExpectedApiText = "https://speed-api.codexradar.com/api/agent-speed";
    private const string ClientVersion = "0.9.7";
    private static readonly ReportServiceUrl Service = ReportServiceUrl.Parse(ServiceText)!;
    private static readonly ReportClientInfo Client = ReportClientInfo.Windows(ClientVersion);
    private static readonly HashSet<ReportSection> AllowedSections = [ReportSection.Sources, ReportSection.Models, ReportSection.Cost];

    private sealed class WebSocketRunState(
        ReportSample sample,
        ReportDiscovery discovery,
        PersistedIdentity identity,
        string username,
        long clockCorrection,
        SourceReadObservationBuffer sourceObservations)
    {
        public ReportSample Sample = sample;
        public WebSocketReportWindow Window = new(sample);
        public SourceReadObservationBuffer SourceObservations = sourceObservations;
        public ReportDiscovery Discovery = discovery;
        public PersistedIdentity Identity = identity;
        public string Username = username;
        public long ClockCorrection = clockCorrection;
        public string RunId = ReportCanonical.NewUuid();
        public int Sequence;
        public long? LastActivityAt;
        public long WindowStartedAt = MonotonicMs();
        public DateTimeOffset? LastReportAt;
        public int NonceReplayedCount;
        public int BadResponseCount;
        public int RunConflictCount;
        public bool ResetFailuresRequested;
        public long? LastAutomaticRegistrationAt;

        public void ResetWindow()
        {
            Window.ResetForReconnectOrResume(Sample);
            SourceObservations.Clear();
        }

        public void DropWindow(ReportSample sample)
        {
            Window.DropAndRebase(sample);
            SourceObservations.Clear();
        }
    }

    private sealed record PendingWebSocketReport(string BodySha256, long SentAtMs, long Generation);

    private sealed record WebSocketExit(int? RetryAfterSeconds = null, bool Quiet = false);

    private sealed record WebSocketRunResult(
        bool FallbackToHttp,
        ReportSample Sample,
        ReportDiscovery Discovery,
        PersistedIdentity Identity,
        long ClockCorrection);

    public static async Task RunAsync(string username, string transportChoice, StatusEmitter status, CancellationToken cancellationToken)
    {
        if (ReporterTransportChoice.StartFailure(transportChoice, supportsWebSocket: true) is { } selectionFailure)
        {
            throw new ReporterFailure(selectionFailure);
        }

        var snapshots = new SnapshotMailbox();
        var hub = new SpeedHub(context: null);
        hub.LivePublished += (_, snapshot) => snapshots.Publish(snapshot);
        using var monitor = new LiveMonitor(hub, pricing: new PriceBook(), realtimeEventMode: transportChoice == "websocket");
        monitor.Start();

        await status.PublishAsync(Status(
            "waiting_for_snapshot", "waiting_for_snapshot", ReportSample.Empty, null, null), cancellationToken).ConfigureAwait(false);
        var readySnapshot = await WaitForReadySnapshotAsync(snapshots, cancellationToken).ConfigureAwait(false);
        var sample = ReportSample.From(readySnapshot, ReportTrafficSample.Off);

        using var transport = new HttpReportTransport();
        var api = new ReportApi(transport, Client.UserAgent);
        await status.PublishAsync(Status("discovering", "discovering", sample, null, null), cancellationToken).ConfigureAwait(false);
        var discovery = await DiscoverAsync(api, cancellationToken).ConfigureAwait(false);
        if (!discovery.SupportsThisClient)
        {
            throw new ReporterFailure("service_unsupported");
        }

        if (discovery.Api.Text != ExpectedApiText)
        {
            throw new ReporterFailure("service_unsupported");
        }

        if (ReporterTransportChoice.StartFailure(transportChoice, discovery.SupportsWebSocket) is { } capabilityFailure)
        {
            throw new ReporterFailure(capabilityFailure);
        }

        if (discovery.ApiKeyMode == ReportApiKeyMode.Required)
        {
            throw new ReporterFailure("api_key_required");
        }

        if (ReportUsername.Validate(username, discovery.UsernameRules) is not null)
        {
            throw new ReporterFailure("username_invalid");
        }

        var sections = discovery.Sections.Where(AllowedSections.Contains).ToHashSet();
        if (sections.Count == 0)
        {
            throw new ReporterFailure("service_unsupported");
        }

        DpapiReportKeyStore keyStore;
        PersistedIdentity identity;
        SoftwareReportSigner signer;
        try
        {
            keyStore = DpapiReportKeyStore.Standard();
            (identity, signer) = keyStore.LoadOrCreate();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException)
        {
            throw new ReporterFailure("key_unavailable");
        }

        using (signer)
        {
            await status.PublishAsync(Status("registering", "registering", sample, null, identity.ProfileUrl), cancellationToken)
                .ConfigureAwait(false);
            var clockCorrection = 0L;
            if (identity.RegisteredUsername is null)
            {
                var registration = await RegisterAsync(api, discovery, identity, signer, keyStore, username,
                    clockCorrection, cancellationToken).ConfigureAwait(false);
                identity = registration.Identity;
                clockCorrection = registration.ClockCorrection;
            }
            else if (!ReportUsername.IsSameName(identity.RegisteredUsername, username))
            {
                identity = await RenameAsync(api, discovery, identity, signer, keyStore, username, cancellationToken)
                    .ConfigureAwait(false);
            }

            if (ReporterTransportChoice.UsesWebSocket(transportChoice))
            {
                var websocketResult = await RunWebSocketAsync(
                    snapshots,
                    sample,
                    status,
                    api,
                    discovery,
                    identity,
                    signer,
                    keyStore,
                    username,
                    clockCorrection,
                    cancellationToken).ConfigureAwait(false);
                if (!websocketResult.FallbackToHttp)
                {
                    return;
                }

                sample = websocketResult.Sample;
                discovery = websocketResult.Discovery;
                identity = websocketResult.Identity;
                clockCorrection = websocketResult.ClockCorrection;
                sections = discovery.Sections.Where(AllowedSections.Contains).ToHashSet();
                await RunHttpAsync(snapshots, sample, sections, status, api, discovery, identity, signer,
                    keyStore, username, clockCorrection, fallbackOccurred: true, cancellationToken).ConfigureAwait(false);
                return;
            }

            await RunHttpAsync(snapshots, sample, sections, status, api, discovery, identity, signer,
                keyStore, username, clockCorrection, fallbackOccurred: false, cancellationToken).ConfigureAwait(false);
            return;
        }
    }

    private static async Task RunHttpAsync(
        ChannelReader<SpeedSnapshot> snapshots,
        ReportSample sample,
        HashSet<ReportSection> sections,
        StatusEmitter status,
        ReportApi api,
        ReportDiscovery discovery,
        PersistedIdentity identity,
        SoftwareReportSigner signer,
        DpapiReportKeyStore keyStore,
        string username,
        long initialClockCorrection,
        bool fallbackOccurred,
        CancellationToken cancellationToken)
    {
        var window = new ReportWindow(sample);
        var clockCorrection = initialClockCorrection;
        var lastReportAt = (DateTimeOffset?)null;
        var strikes = 0;
        var scheduler = new ReportScheduler(discovery.Limits);
        var titleTracker = new ReportTitleTracker();
        var runId = ReportCanonical.NewUuid();
        var bodies = new Dictionary<int, byte[]>();
        Task<ReportCallResult>? pendingCall = null;
        ReportTicket? pendingTicket = null;
        var reportOptions = new ReportOptions(
            sections,
            MaxModels: discovery.Limits.MaxModels,
            BodyLimit: discovery.Limits.SendLimitBytes,
            Metric: SpeedMetric.Output, PriceVersion: PriceBook.Bundled.Version)
        {
            // Keep parity with the native client for negotiated model-level statistics only.
            // Traffic, profile, identity, and avatar extensions remain disabled.
            Extensions = new ReportExtensions(
                ModelHarnessRequests: discovery.Extensions.ModelHarnessRequests,
                ExecutionModes: discovery.Extensions.ExecutionModes),
        };
        var reportUrl = discovery.Api.Endpoint(ReportEndpoint.Reports);

        if (fallbackOccurred)
        {
            await PublishStatusAsync("reporting", "http_fallback").ConfigureAwait(false);
        }

        while (!cancellationToken.IsCancellationRequested)
        {
            using (var shortWait = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            {
                shortWait.CancelAfter(TimeSpan.FromMilliseconds(250));
                try
                {
                    _ = await snapshots.WaitToReadAsync(shortWait.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                {
                }
            }

            var sampleChanged = false;
            while (snapshots.TryRead(out var latest))
            {
                if (latest.State.Kind == MonitorStateKind.Starting)
                {
                    continue;
                }

                sample = ReportSample.From(latest, ReportTrafficSample.Off);
                sampleChanged = true;
            }

            if (pendingCall is { IsCompleted: true } completed && pendingTicket is { } ticket)
            {
                ReportCallResult result;
                try
                {
                    result = await completed.ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }

                pendingCall = null;
                pendingTicket = null;
                var (outcome, reaction) = ReportOutcome.Classify(result.Reply, hasPendingKey: false);
                Apply(scheduler.Finish(ticket, outcome, MonotonicMs()), sample);
                if (result.Reply?.IsSuccess == true)
                {
                    lastReportAt = DateTimeOffset.UtcNow;
                    strikes = 0;
                    var profile = SafeProfileUrl(result.Reply.ProfileUrl);
                    if (profile is not null && profile != identity.ProfileUrl)
                    {
                        identity = identity with { ProfileUrl = profile };
                        keyStore.WriteIdentity(identity);
                    }
                }

                switch (reaction)
                {
                    case ReportReaction.CorrectClock correction:
                        if (correction.ServerTime is { } serverTime)
                        {
                            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                            if (serverTime >= now - 86_400 && serverTime <= now + 86_400)
                            {
                                clockCorrection = serverTime - now;
                            }
                        }

                        break;
                    case ReportReaction.ReRegister:
                    case ReportReaction.RecheckRegistration:
                        await PublishStatusAsync("registering", "registering").ConfigureAwait(false);
                        var registration = await RegisterAsync(api, discovery, identity, signer, keyStore, username,
                            clockCorrection, cancellationToken).ConfigureAwait(false);
                        identity = registration.Identity;
                        clockCorrection = registration.ClockCorrection;
                        runId = ReportCanonical.NewUuid();
                        scheduler = new ReportScheduler(discovery.Limits);
                        window = new ReportWindow(sample);
                        titleTracker = new ReportTitleTracker();
                        bodies.Clear();
                        break;
                    case ReportReaction.Rename:
                        identity = await RenameAsync(api, discovery, identity, signer, keyStore, username, cancellationToken)
                            .ConfigureAwait(false);
                        break;
                    case ReportReaction.RefreshDiscovery refresh:
                        if (refresh.Upgrade)
                        {
                            throw new ReporterFailure("service_unsupported");
                        }

                        discovery = await DiscoverAsync(api, cancellationToken).ConfigureAwait(false);
                        scheduler.Update(discovery.Limits);
                        break;
                    case ReportReaction.NewRun:
                        runId = ReportCanonical.NewUuid();
                        scheduler = new ReportScheduler(discovery.Limits);
                        window = new ReportWindow(sample);
                        titleTracker = new ReportTitleTracker();
                        bodies.Clear();
                        break;
                    case ReportReaction.NeedsUser user:
                        throw new ReporterFailure(user.Problem switch
                        {
                            ReportProblem.ApiKey => "api_key_required",
                            ReportProblem.UsernameTaken => "username_taken",
                            ReportProblem.UsernameRejected => "username_invalid",
                            ReportProblem.Forbidden => "forbidden",
                            _ => "reporting_failed",
                        });
                    case ReportReaction.Strike:
                        if (++strikes >= 3)
                        {
                            throw new ReporterFailure("reporting_failed");
                        }

                        break;
                }

            }

            var active = sample.IsWorking || sample.Live.Output > 0 || window.HasTokenIncrement(sample);
            var nowMs = MonotonicMs();
            titleTracker.Update(sample.Live.Output, reportOptions.Redline, nowMs / 1000.0);
            Apply(scheduler.Tick(nowMs, active, blocked: false), sample);

            if (sampleChanged || DateTimeOffset.UtcNow.Second % 2 == 0)
            {
                await PublishStatusAsync("reporting", "reporting").ConfigureAwait(false);
            }
        }

        void Apply(IReadOnlyList<ReportAction> actions, ReportSample current)
        {
            var windowChanged = false;
            foreach (var action in actions)
            {
                switch (action)
                {
                    case ReportAction.Discard discard:
                        window.Discard(current, discard.KeepingTick);
                        windowChanged = true;
                        break;
                    case ReportAction.Build build:
                        var content = window.Take(current);
                        windowChanged = true;
                        var envelope = new ReportEnvelope(
                            Client,
                            identity.DeviceId,
                            identity.RegisteredUsername ?? username,
                            runId,
                            build.Ticket.Seq,
                            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + clockCorrection * 1000,
                            build.Ticket.WindowMs,
                            build.Ticket.Activity,
                            TitleLevel: titleTracker.Level);
                        var body = ReportBody.Data(envelope, content, current, reportOptions);
                        if (!ReportPayloadWhitelist.IsAllowed(body))
                        {
                            throw new ReporterFailure("reporting_failed");
                        }

                        bodies[build.Ticket.Seq] = body;
                        break;
                    case ReportAction.Send send:
                        if (pendingCall is not null || !bodies.TryGetValue(send.Ticket.Seq, out var queuedBody))
                        {
                            throw new ReporterFailure("reporting_failed");
                        }

                        var builder = new ReportRequestBuilder(Client.UserAgent, identity.DeviceId, ApiKey: null);
                        var request = builder.Make(
                            "POST", reportUrl, queuedBody, signer,
                            DateTimeOffset.UtcNow.ToUnixTimeSeconds() + clockCorrection);
                        pendingTicket = send.Ticket;
                        pendingCall = api.CallAsync(request, cancellationToken);
                        break;
                    case ReportAction.Delivered delivered:
                        bodies.Remove(delivered.Ticket.Seq);
                        break;
                    case ReportAction.Lost lost:
                        bodies.Remove(lost.Ticket.Seq);
                        break;
                }
            }

            window.Observe(current, peaks: !windowChanged);
        }
        Task PublishStatusAsync(string phase, string code) =>
            status.PublishAsync(Status(phase, HttpFallbackStatus.MessageCode(fallbackOccurred, code),
                sample, lastReportAt, identity.ProfileUrl), cancellationToken);
    }

    private static async Task<WebSocketRunResult> RunWebSocketAsync(
        ChannelReader<SpeedSnapshot> snapshots,
        ReportSample initialSample,
        StatusEmitter status,
        ReportApi api,
        ReportDiscovery discovery,
        PersistedIdentity identity,
        SoftwareReportSigner signer,
        DpapiReportKeyStore keyStore,
        string username,
        long initialClockCorrection,
        CancellationToken cancellationToken)
    {
        if (!discovery.SupportsWebSocket)
        {
            throw new ReporterFailure("websocket_not_supported");
        }

        var state = new WebSocketRunState(
            initialSample, discovery, identity, username, initialClockCorrection, new SourceReadObservationBuffer());
        var failures = 0;
        var retryAfterSeconds = (int?)null;
        var mismatchRefreshUsed = false;

        while (!cancellationToken.IsCancellationRequested)
        {
            DrainSnapshotsAndRebaseline(snapshots, state);
            await status.PublishAsync(Status(
                "waiting_for_activity", "websocket_waiting_for_activity", state.Sample, state.LastReportAt, state.Identity.ProfileUrl),
                cancellationToken).ConfigureAwait(false);
            await WaitForWebSocketActivityAsync(snapshots, state, cancellationToken).ConfigureAwait(false);
            DrainSnapshotsAndRebaseline(snapshots, state);
            ReportWebSocketSession? session = null;
            var connectStartedAt = DateTimeOffset.UtcNow;
            var connectStartedTimestamp = Stopwatch.GetTimestamp();
            try
            {
                var negotiationAttempts = 0;
                WebSocketReady ready;
                while (true)
                {
                    (session, ready) = await ReportWebSocketSession.ConnectAsync(
                        state.Discovery,
                        Client.UserAgent,
                        state.Identity.DeviceId,
                        signer,
                        DateTimeOffset.UtcNow.ToUnixTimeSeconds() + state.ClockCorrection,
                        cancellationToken).ConfigureAwait(false);
                    if (ready.Settings == state.Discovery.WebSocket)
                    {
                        mismatchRefreshUsed = false;
                        break;
                    }

                    await session.DisposeAsync().ConfigureAwait(false);
                    session = null;
                    if (negotiationAttempts++ > 0 || mismatchRefreshUsed)
                    {
                        throw new ReporterFailure("websocket_configuration_mismatch");
                    }

                    mismatchRefreshUsed = true;
                    try
                    {
                        state.Discovery = await DiscoverAsync(api, cancellationToken).ConfigureAwait(false);
                    }
                    catch (ReporterFailure)
                    {
                        throw new ReporterFailure("websocket_configuration_mismatch");
                    }

                    if (!state.Discovery.SupportsWebSocket)
                    {
                        throw new ReporterFailure("websocket_not_supported");
                    }
                }

                await status.PublishAsync(Status(
                    "connected", "websocket_connected", state.Sample, state.LastReportAt, state.Identity.ProfileUrl), cancellationToken)
                    .ConfigureAwait(false);
                DrainSnapshotsAndRebaseline(snapshots, state);
                var connectedAt = MonotonicMs();
                var exit = await RunConnectedWebSocketAsync(
                    session,
                    snapshots,
                    state,
                    status,
                    api,
                    keyStore,
                    signer,
                    username,
                    connectedAt,
                    cancellationToken).ConfigureAwait(false);
                if (exit.Quiet)
                {
                    using var closeDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(1));
                    try
                    {
                        await session.CloseAsync(closeDeadline.Token).ConfigureAwait(false);
                    }
                    catch (Exception) { }

                    failures = 0;
                    mismatchRefreshUsed = false;
                    continue;
                }

                retryAfterSeconds = exit.RetryAfterSeconds;
                if (state.ResetFailuresRequested)
                {
                    failures = 0;
                    state.ResetFailuresRequested = false;
                }
                else if (retryAfterSeconds is null)
                {
                    failures = Math.Min(failures + 1, 7);
                }

                await status.PublishAsync(Status(
                    "reconnecting", "websocket_reconnecting", state.Sample, state.LastReportAt, state.Identity.ProfileUrl), cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (ReporterFailure)
            {
                throw;
            }
            catch (AuthenticationException)
            {
                throw new ReporterFailure("websocket_protocol_error");
            }
            catch (Exception error) when (IsTransientWebSocketFailure(error))
            {
                if (ContainsException<InvalidDataException>(error) || ContainsException<DecoderFallbackException>(error))
                {
                    throw new ReporterFailure("websocket_protocol_error");
                }

                if (ContainsException<AuthenticationException>(error))
                {
                    throw new ReporterFailure("websocket_protocol_error");
                }

                if (error is WebSocketHandshakeException handshake)
                {
                    var statusCode = (int)handshake.StatusCode;
                    if (statusCode is 401 or 403)
                    {
                        throw new ReporterFailure(statusCode == 401 ? "api_key_required" : "forbidden");
                    }

                    if (statusCode is >= 300 and < 400 or 404 or 410)
                    {
                        throw new ReporterFailure("websocket_not_supported");
                    }

                    if (statusCode is >= 400 and < 500 and not (429 or 503))
                    {
                        throw new ReporterFailure("websocket_protocol_error");
                    }

                    if (statusCode is 429 or 503)
                    {
                        retryAfterSeconds = Math.Clamp(handshake.RetryAfterSeconds ?? 60, 5, 3_600);
                    }
                }

                if (error is ReportWebSocketCloseException close)
                {
                    var code = (int?)close.CloseStatus;
                    if (code == 4004)
                    {
                        if (state.LastAutomaticRegistrationAt is { } last
                            && MonotonicMs() - last < 3_600_000)
                        {
                            throw new ReporterFailure("unknown_device");
                        }

                        var registration = await RegisterAsync(
                            api, state.Discovery, state.Identity, signer, keyStore, username,
                            state.ClockCorrection, cancellationToken).ConfigureAwait(false);
                        state.Identity = registration.Identity;
                        state.ClockCorrection = registration.ClockCorrection;
                        state.LastAutomaticRegistrationAt = MonotonicMs();
                        state.RunId = ReportCanonical.NewUuid();
                        state.Sequence = 0;
                    }
                    else if (code is 1002 or 1003 or 1007 or 1009 or 4000 or 4001 or 4003 or 4009 or 4410)
                    {
                        throw new ReporterFailure(code == 4009 ? "websocket_replaced" : "websocket_protocol_error");
                    }

                    if (code is 4429 or 4503)
                    {
                        retryAfterSeconds = 60;
                    }
                }

                var sleepResumeDetected = WebSocketSleepResume.IsDetected(
                    DateTimeOffset.UtcNow - connectStartedAt,
                    Stopwatch.GetElapsedTime(connectStartedTimestamp),
                    TimeSpan.FromSeconds((state.Discovery.WebSocket?.PingIntervalSeconds ?? 30) * 2));
                if (WebSocketFallbackPolicy.ShouldFallbackToHttp(
                    error, cancellationToken.IsCancellationRequested, retryAfterSeconds, sleepResumeDetected))
                {
                    DrainSnapshotsAndRebaseline(snapshots, state);
                    state.ResetWindow();
                    await status.PublishAsync(Status(
                        "reporting", "http_fallback", state.Sample, state.LastReportAt, state.Identity.ProfileUrl), cancellationToken)
                        .ConfigureAwait(false);
                    return new WebSocketRunResult(true, state.Sample, state.Discovery, state.Identity, state.ClockCorrection);
                }

                state.ResetWindow(); // Drop unacknowledged work and source timing on reconnect.
                failures = Math.Min(failures + 1, 6);
                await status.PublishAsync(Status(
                    "reconnecting", "websocket_reconnecting", state.Sample, state.LastReportAt, state.Identity.ProfileUrl), cancellationToken)
                    .ConfigureAwait(false);
            }
            finally
            {
                if (session is not null)
                {
                    await session.DisposeAsync().ConfigureAwait(false);
                }
            }

            var jitter = 0.8 + Random.Shared.NextDouble() * 0.4;
            var delayMs = WebSocketRetryDelay.CalculateMilliseconds(failures, retryAfterSeconds, jitter);
            retryAfterSeconds = null;
            await Task.Delay(TimeSpan.FromMilliseconds(delayMs), cancellationToken).ConfigureAwait(false);
            state.ResetWindow();
        }

        return new WebSocketRunResult(false, state.Sample, state.Discovery, state.Identity, state.ClockCorrection);
    }

    private static async Task<WebSocketExit> RunConnectedWebSocketAsync(
        ReportWebSocketSession session,
        ChannelReader<SpeedSnapshot> snapshots,
        WebSocketRunState state,
        StatusEmitter status,
        ReportApi api,
        DpapiReportKeyStore keyStore,
        SoftwareReportSigner signer,
        string username,
        long connectedAt,
        CancellationToken cancellationToken)
    {
        var negotiated = state.Discovery.WebSocket ?? throw new ReporterFailure("websocket_not_supported");
        var pending = new Dictionary<(string RunId, int Seq), PendingWebSocketReport>();
        var reportOptions = new ReportOptions(
            state.Discovery.Sections.Where(AllowedSections.Contains).ToHashSet(),
            MaxModels: state.Discovery.Limits.MaxModels,
            BodyLimit: state.Discovery.Limits.SendLimitBytes,
            Metric: SpeedMetric.Output, PriceVersion: PriceBook.Bundled.Version)
        {
            Extensions = new ReportExtensions(
                ModelHarnessRequests: state.Discovery.Extensions.ModelHarnessRequests,
                ExecutionModes: state.Discovery.Extensions.ExecutionModes),
        };
        var reportUrl = state.Discovery.Api.Endpoint(ReportEndpoint.Reports);
        var titleTracker = new ReportTitleTracker();
        var connectionGeneration = WebSocketConnectionGeneration.Next();
        var lastSendAt = MonotonicMs();
        state.WindowStartedAt = lastSendAt;
        var lastWallClock = DateTimeOffset.UtcNow;
        var lastObservedSample = state.Sample;
        var pendingChanges = false;
        var forceActivityTransition = false;
        var badMessages = 0;
        var activityBefore = GetWebSocketActivity(state.LastActivityAt, lastSendAt);
        using var snapshotWaitLifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        Task<WebSocketMessage> messageTask = session.ReadMessageAsync(cancellationToken);
        Task<bool> snapshotReadyTask = snapshots.WaitToReadAsync(snapshotWaitLifetime.Token).AsTask();

        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var now = MonotonicMs();
                var wallNow = DateTimeOffset.UtcNow;
                if (wallNow - lastWallClock > TimeSpan.FromSeconds(negotiated.PingIntervalSeconds * 2))
                {
                    // Sleep/resume or a long process pause invalidates the open sampling window and all in-flight claims.
                    state.ResetWindow();
                    return new WebSocketExit();
                }

                lastWallClock = wallNow;
                while (snapshotReadyTask.IsCompletedSuccessfully && snapshotReadyTask.Result)
                {
                    while (snapshots.TryRead(out var latest))
                    {
                        if (latest.State.Kind == MonitorStateKind.Starting)
                        {
                            continue;
                        }

                        state.SourceObservations.Observe(latest.SourceReadObservation);
                        var next = ReportSample.From(latest, ReportTrafficSample.Off);
                        var tokenIncrement = state.Window.HasTokenIncrement(next);
                        var changed = HasRealtimeChange(lastObservedSample, next) || tokenIncrement;
                        if (next.IsWorking || next.Live.Output > 0 || tokenIncrement)
                        {
                            state.LastActivityAt = now;
                        }

                        state.Sample = next;
                        lastObservedSample = next;
                        state.Window.Observe(next);
                        if (pending.Count >= negotiated.MaxInFlight)
                        {
                            state.DropWindow(next);
                            state.WindowStartedAt = now;
                            pendingChanges = false;
                            forceActivityTransition = false;
                        }
                        else if (changed)
                        {
                            pendingChanges = true;
                        }
                    }

                    snapshotReadyTask = snapshots.WaitToReadAsync(snapshotWaitLifetime.Token).AsTask();
                }

                while (messageTask.IsCompleted)
                {
                    WebSocketMessage message;
                    try
                    {
                        message = await messageTask.ConfigureAwait(false);
                    }
                    catch (InvalidDataException)
                    {
                        throw new ReporterFailure("websocket_protocol_error");
                    }

                    messageTask = session.ReadMessageAsync(cancellationToken);
                    switch (message)
                    {
                        case WebSocketMessage.Ack { Value: var ack }:
                            if (!TryAcceptAck(ack, state.RunId, pending, connectionGeneration, out _))
                            {
                                continue;
                            }

                            state.LastReportAt = ack.AcceptedAt;
                            if (MonotonicMs() - connectedAt >= 60_000)
                            {
                                state.NonceReplayedCount = 0;
                                state.BadResponseCount = 0;
                                state.RunConflictCount = 0;
                                state.ResetFailuresRequested = true;
                            }

                            await status.PublishAsync(Status(
                                "reporting", "reporting", state.Sample, state.LastReportAt, state.Identity.ProfileUrl), cancellationToken)
                                .ConfigureAwait(false);
                            break;
                        case WebSocketMessage.Error { Value: var error }:
                            var action = await HandleWebSocketErrorAsync(
                                error, state, pending, api, keyStore, signer, username, cancellationToken).ConfigureAwait(false);
                            if (action is { } exit)
                            {
                                return exit;
                            }

                            break;
                    }
                }

                now = MonotonicMs();
                foreach (var entry in pending.Values)
                {
                    if (now - entry.SentAtMs >= negotiated.AckTimeoutMs)
                    {
                        session.Abort();
                        return new WebSocketExit();
                    }
                }

                var activityNow = GetWebSocketActivity(state.LastActivityAt, now);
                if (activityNow != activityBefore)
                {
                    activityBefore = activityNow;
                    forceActivityTransition = true;
                }

                if (activityNow == ReportActivity.Leaving)
                {
                    if (pending.Count < negotiated.MaxInFlight)
                    {
                        await TrySendWebSocketReportAsync(
                            session, state, pending, connectionGeneration, reportUrl, reportOptions, signer, titleTracker,
                            ReportActivity.Leaving, negotiated.MaxMessageBytes, negotiated.AckTimeoutMs,
                            cancellationToken).ConfigureAwait(false);
                    }

                    return new WebSocketExit(Quiet: true);
                }

                var heartbeatDue = activityNow == ReportActivity.Idle
                    && now - lastSendAt >= state.Discovery.Limits.HeartbeatSeconds * 1_000L;
                var minIntervalDue = now - lastSendAt >= negotiated.MinIntervalMs;
                if (pending.Count >= negotiated.MaxInFlight)
                {
                    if (pendingChanges || forceActivityTransition)
                    {
                        state.DropWindow(state.Sample);
                        state.WindowStartedAt = now;
                        pendingChanges = false;
                        forceActivityTransition = false;
                    }
                }
                else if (minIntervalDue && (pendingChanges || forceActivityTransition || heartbeatDue))
                {
                    var activity = activityNow == ReportActivity.Active ? ReportActivity.Active : ReportActivity.Idle;
                    await TrySendWebSocketReportAsync(
                        session, state, pending, connectionGeneration, reportUrl, reportOptions, signer, titleTracker,
                        activity, negotiated.MaxMessageBytes, negotiated.AckTimeoutMs, cancellationToken).ConfigureAwait(false);
                    lastSendAt = now;
                    state.WindowStartedAt = now;
                    pendingChanges = false;
                    forceActivityTransition = false;
                }

                var waitMs = 250;
                if (pendingChanges || forceActivityTransition)
                {
                    waitMs = (int)Math.Clamp(negotiated.MinIntervalMs - (now - lastSendAt), 1, waitMs);
                }

                var idleHeartbeatMs = state.Discovery.Limits.HeartbeatSeconds * 1_000L - (now - lastSendAt);
                if (activityNow == ReportActivity.Idle)
                {
                    waitMs = (int)Math.Clamp(Math.Min(waitMs, idleHeartbeatMs), 1, waitMs);
                }

                if (pending.Count > 0)
                {
                    var nextTimeout = pending.Values.Min(item => item.SentAtMs + negotiated.AckTimeoutMs - now);
                    waitMs = (int)Math.Clamp(Math.Min(waitMs, nextTimeout), 1, waitMs);
                }

                var delayTask = Task.Delay(waitMs, cancellationToken);
                _ = await Task.WhenAny(snapshotReadyTask, messageTask, delayTask).ConfigureAwait(false);
            }

            return new WebSocketExit();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            await TrySendLeavingOnStopAsync(session, state, pending, connectionGeneration, reportUrl, reportOptions, signer, titleTracker,
                negotiated.MaxMessageBytes)
                .ConfigureAwait(false);
            throw;
        }
        catch (InvalidDataException)
        {
            badMessages++;
            throw new ReporterFailure("websocket_protocol_error");
        }
        finally
        {
            snapshotWaitLifetime.Cancel();
            try
            {
                await snapshotReadyTask.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }

            _ = badMessages;
        }
    }

    private static async Task<WebSocketExit?> HandleWebSocketErrorAsync(
        WebSocketError error,
        WebSocketRunState state,
        Dictionary<(string RunId, int Seq), PendingWebSocketReport> pending,
        ReportApi api,
        DpapiReportKeyStore keyStore,
        SoftwareReportSigner signer,
        string username,
        CancellationToken cancellationToken)
    {
        if (error.RunId is { } runId && error.Seq is { } seq)
        {
            if (runId != state.RunId || !pending.Remove((runId, seq)))
            {
                return null;
            }
        }

        if (error.HttpStatus is 429 or 503 || error.Code is "rate_limited" or "service_unavailable")
        {
            return new WebSocketExit(Math.Clamp(error.RetryAfterSeconds ?? 60, 5, 3_600));
        }

        switch (error.Code)
        {
            case "timestamp_out_of_window":
                if (error.ServerTime is { } serverTime)
                {
                    var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                    if (serverTime >= now - 86_400 && serverTime <= now + 86_400)
                    {
                        state.ClockCorrection = serverTime - now;
                    }
                }

                return null;
            case "nonce_replayed":
                if (++state.NonceReplayedCount >= 3)
                {
                    throw new ReporterFailure("reporting_failed");
                }

                return null;
            case "seq_conflict":
                state.RunId = ReportCanonical.NewUuid();
                state.Sequence = 0;
                state.ResetWindow();
                pending.Clear();
                return new WebSocketExit();
            case "run_conflict":
                if (++state.RunConflictCount > 1)
                {
                    throw new ReporterFailure("reporting_failed");
                }

                state.ResetWindow();
                pending.Clear();
                return new WebSocketExit();
            case "unknown_device":
                if (state.LastAutomaticRegistrationAt is { } lastRegistration
                    && MonotonicMs() - lastRegistration < 3_600_000)
                {
                    throw new ReporterFailure("unknown_device");
                }

                var registration = await RegisterAsync(api, state.Discovery, state.Identity, signer, keyStore, username,
                    state.ClockCorrection, cancellationToken).ConfigureAwait(false);
                state.Identity = registration.Identity;
                state.ClockCorrection = registration.ClockCorrection;
                state.LastAutomaticRegistrationAt = MonotonicMs();
                state.RunId = ReportCanonical.NewUuid();
                state.Sequence = 0;
                state.ResetWindow();
                pending.Clear();
                return new WebSocketExit();
            case "username_mismatch":
                state.Identity = await RenameAsync(api, state.Discovery, state.Identity, signer, keyStore, username, cancellationToken)
                    .ConfigureAwait(false);
                state.RunId = ReportCanonical.NewUuid();
                state.Sequence = 0;
                state.ResetWindow();
                pending.Clear();
                return new WebSocketExit();
            case "api_key_required":
            case "api_key_invalid":
                throw new ReporterFailure("api_key_required");
            case "forbidden":
                throw new ReporterFailure("forbidden");
            case "signature_invalid":
            case "version_unsupported":
            case "payload_too_large":
            case "payload_invalid":
            case "bad_request":
            case "gone":
                throw new ReporterFailure("websocket_protocol_error");
            default:
                if (error.HttpStatus >= 400 && error.HttpStatus < 500 && ++state.BadResponseCount >= 3)
                {
                    throw new ReporterFailure("websocket_protocol_error");
                }

                if (error.Fatal)
                {
                    return new WebSocketExit();
                }

                return null;
        }
    }

    private static async Task TrySendWebSocketReportAsync(
        ReportWebSocketSession session,
        WebSocketRunState state,
        Dictionary<(string RunId, int Seq), PendingWebSocketReport> pending,
        long connectionGeneration,
        Uri reportUrl,
        ReportOptions options,
        SoftwareReportSigner signer,
        ReportTitleTracker titleTracker,
        ReportActivity activity,
        int maxMessageBytes,
        int sendTimeoutMs,
        CancellationToken cancellationToken)
    {
        var content = state.Window.Take(state.Sample);
        var observation = state.SourceObservations.Take();
        var seq = ++state.Sequence;
        var nowMs = MonotonicMs();
        var builtAtMs = nowMs;
        titleTracker.Update(state.Sample.Live.Output, options.Redline, nowMs / 1000.0);
        var envelope = new ReportEnvelope(
            Client,
            state.Identity.DeviceId,
            state.Identity.RegisteredUsername ?? state.Username,
            state.RunId,
            seq,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + state.ClockCorrection * 1_000,
            Math.Clamp(nowMs - state.WindowStartedAt, 0, ReportBody.MaxWindowMs),
            activity,
            TitleLevel: titleTracker.Level);

        var sections = options.Sections.ToHashSet();
        byte[]? message = null;
        ReportRequest? request = null;
        var staleObservation = false;
        var timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + state.ClockCorrection;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var candidateOptions = options with { Sections = sections };
            var baseBody = ReportBody.Data(envelope, content, state.Sample, candidateOptions);
            if (!RealtimeReportBody.TryAppendSourceTiming(
                baseBody,
                observation,
                Stopwatch.GetTimestamp(),
                state.ClockCorrection,
                out var body,
                out _))
            {
                staleObservation = true;
                break;
            }

            if (body is null)
            {
                message = null;
                break;
            }

            if (!ReportPayloadWhitelist.IsAllowed(body, allowRealtime: true)
                || body.Length > state.Discovery.Limits.SendLimitBytes)
            {
                message = null;
            }
            else
            {
                request = new ReportRequestBuilder(Client.UserAgent, state.Identity.DeviceId, ApiKey: null)
                    .Make("POST", reportUrl, body, signer, timestamp);
                message = ReportWebSocketSession.EncodeReport(request);
                if (message.Length <= maxMessageBytes)
                {
                    break;
                }
            }

            if (sections.Remove(ReportSection.Models))
            {
                continue;
            }

            if (sections.Remove(ReportSection.Sources))
            {
                continue;
            }

            message = null;
            break;
        }

        if (staleObservation || message is null || request is null || message.Length > maxMessageBytes)
        {
            return; // The sequence and window are consumed; the v1 delta is never split or replayed.
        }

        if (MonotonicMs() - builtAtMs > 1_000
            || (observation is not null && observation.AgeMilliseconds(Stopwatch.GetTimestamp()) > 1_000))
        {
            return; // Never refresh or replay a report or source observation that sat locally for more than one second.
        }

        var hash = Convert.ToHexStringLower(SHA256.HashData(request.Body));
        var key = (state.RunId, seq);
        var sendAtTimestamp = Stopwatch.GetTimestamp();
        if (MonotonicMs() - builtAtMs > 1_000
            || (observation is not null && observation.AgeMilliseconds(sendAtTimestamp) > 1_000))
        {
            return; // Recheck the observation age immediately before writing to the socket.
        }

        pending[key] = new PendingWebSocketReport(hash, MonotonicMs(), connectionGeneration);
        var immediatelyBeforeSend = Stopwatch.GetTimestamp();
        if (MonotonicMs() - builtAtMs > 1_000
            || (observation is not null && observation.AgeMilliseconds(immediatelyBeforeSend) > 1_000))
        {
            pending.Remove(key);
            return; // Hashing and pending-state registration must not let stale source data onto the socket.
        }

        await session.SendMessageAsync(message, sendTimeoutMs, cancellationToken).ConfigureAwait(false);
    }

    private static async Task TrySendLeavingOnStopAsync(
        ReportWebSocketSession session,
        WebSocketRunState state,
        Dictionary<(string RunId, int Seq), PendingWebSocketReport> pending,
        long connectionGeneration,
        Uri reportUrl,
        ReportOptions options,
        SoftwareReportSigner signer,
        ReportTitleTracker titleTracker,
        int maxMessageBytes)
    {
        if (pending.Count >= (state.Discovery.WebSocket?.MaxInFlight ?? 0))
        {
            return;
        }

        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(1));
        try
        {
            await TrySendWebSocketReportAsync(session, state, pending, connectionGeneration, reportUrl, options, signer, titleTracker,
                ReportActivity.Leaving, maxMessageBytes, state.Discovery.WebSocket?.AckTimeoutMs ?? 2_000,
                deadline.Token).ConfigureAwait(false);
        }
        catch (Exception) { }
    }

    private static async Task WaitForWebSocketActivityAsync(
        ChannelReader<SpeedSnapshot> snapshots,
        WebSocketRunState state,
        CancellationToken cancellationToken)
    {
        var sawTokenIncrement = false;
        while (!HasRecentWebSocketActivity(state.LastActivityAt, MonotonicMs()) && !sawTokenIncrement)
        {
            var latest = await snapshots.ReadAsync(cancellationToken).ConfigureAwait(false);
            if (latest.State.Kind == MonitorStateKind.Starting)
            {
                continue;
            }

            var next = ReportSample.From(latest, ReportTrafficSample.Off);
            var tokenIncrement = state.Window.HasTokenIncrement(next);
            sawTokenIncrement |= tokenIncrement;
            state.Sample = next;
            state.ResetWindow(); // Activity after quiet starts a new run window.
            if (IsActiveSample(next) || tokenIncrement)
            {
                state.LastActivityAt = MonotonicMs();
            }
        }

        state.LastActivityAt ??= MonotonicMs();
    }

    private static void DrainSnapshotsAndRebaseline(ChannelReader<SpeedSnapshot> snapshots, WebSocketRunState state)
    {
        ReportSample? latestSample = null;
        while (snapshots.TryRead(out var latest))
        {
            if (latest.State.Kind != MonitorStateKind.Starting)
            {
                latestSample = ReportSample.From(latest, ReportTrafficSample.Off);
            }
        }

        if (latestSample is { } sample)
        {
            state.Sample = sample;
            if (IsActiveSample(sample))
            {
                state.LastActivityAt = MonotonicMs();
            }
        }

        state.ResetWindow();
        state.WindowStartedAt = MonotonicMs();
    }

    private static bool HasRecentWebSocketActivity(long? lastActivityAt, long nowMs) =>
        lastActivityAt is { } last && Math.Max(0, nowMs - last) < 600_000;

    private static bool IsActiveSample(ReportSample sample) => sample.IsWorking || sample.Live.Output > 0;

    private static ReportActivity GetWebSocketActivity(long? lastActivityAt, long nowMs)
    {
        if (lastActivityAt is not { } last)
        {
            return ReportActivity.Leaving;
        }

        var since = Math.Max(0, nowMs - last);
        return since < 15_000 ? ReportActivity.Active : since < 600_000 ? ReportActivity.Idle : ReportActivity.Leaving;
    }

    private static bool HasRealtimeChange(ReportSample previous, ReportSample next)
    {
        if (previous.Live != next.Live || previous.EstimatedShare != next.EstimatedShare
            || previous.Facts.Epoch != next.Facts.Epoch
            || previous.Facts.Counters.Version != next.Facts.Counters.Version
            || previous.Sources.Count != next.Sources.Count
            || previous.Facts.Agents.Count != next.Facts.Agents.Count)
        {
            return true;
        }

        foreach (var (kind, value) in next.Sources)
        {
            if (!previous.Sources.TryGetValue(kind, out var old) || old != value)
            {
                return true;
            }
        }

        foreach (var (kind, value) in next.Facts.Agents)
        {
            if (!previous.Facts.Agents.TryGetValue(kind, out var old) || old != value)
            {
                return true;
            }
        }

        return false;
    }

    private static bool TryAcceptAck(
        WebSocketAck ack,
        string currentRun,
        Dictionary<(string RunId, int Seq), PendingWebSocketReport> pending,
        long connectionGeneration,
        out PendingWebSocketReport accepted)
    {
        accepted = null!;
        var key = (ack.RunId, ack.Seq);
        if (ack.RunId != currentRun || !pending.TryGetValue(key, out var candidate)
            || !WebSocketAckMatcher.Matches(
                ack, currentRun, ack.Seq, candidate.BodySha256, candidate.Generation, connectionGeneration))
        {
            return false;
        }

        pending.Remove(key);
        accepted = candidate;
        return true;
    }

    private static bool IsTransientWebSocketFailure(Exception error) => error is
        TimeoutException or WebSocketException or ReportWebSocketCloseException or WebSocketHandshakeException or HttpRequestException or IOException or
        OperationCanceledException or System.Net.Sockets.SocketException;

    private static bool ContainsException<TException>(Exception error) where TException : Exception
    {
        for (Exception? current = error; current is not null; current = current.InnerException)
        {
            if (current is TException)
            {
                return true;
            }
        }

        return false;
    }

    private static async Task<SpeedSnapshot> WaitForReadySnapshotAsync(
        ChannelReader<SpeedSnapshot> snapshots,
        CancellationToken cancellationToken)
    {
        while (await snapshots.WaitToReadAsync(cancellationToken).ConfigureAwait(false))
        {
            while (snapshots.TryRead(out var snapshot))
            {
                if (snapshot.State.Kind != MonitorStateKind.Starting)
                {
                    return snapshot;
                }
            }
        }

        throw new OperationCanceledException(cancellationToken);
    }

    private static async Task<ReportDiscovery> DiscoverAsync(ReportApi api, CancellationToken cancellationToken)
    {
        var outcome = await api.DiscoverAsync(Service, cancellationToken: cancellationToken).ConfigureAwait(false);
        if (outcome is ReportDiscoveryOutcome.Document document)
        {
            if (!document.Discovery.SupportsThisClient
                || !string.Equals(document.Discovery.Api.Text, ExpectedApiText, StringComparison.Ordinal))
            {
                throw new ReporterFailure("service_unsupported");
            }

            return document.Discovery;
        }

        throw new ReporterFailure(outcome switch
        {
            ReportDiscoveryOutcome.NotSupported or ReportDiscoveryOutcome.Invalid or ReportDiscoveryOutcome.Gone
                => "service_unsupported",
            _ => "service_unavailable",
        });
    }

    private static async Task<(PersistedIdentity Identity, long ClockCorrection)> RegisterAsync(
        ReportApi api,
        ReportDiscovery discovery,
        PersistedIdentity identity,
        SoftwareReportSigner signer,
        DpapiReportKeyStore keyStore,
        string username,
        long clockCorrection,
        CancellationToken cancellationToken)
    {
        var builder = new ReportRequestBuilder(Client.UserAgent, identity.DeviceId, ApiKey: null);
        var body = ReportDocuments.Registration(identity.DeviceId, username, signer.PublicKey, Client);
        var url = discovery.Api.Endpoint(ReportEndpoint.Devices);
        for (var attemptNumber = 0; attemptNumber < 2; attemptNumber++)
        {
            var request = builder.Make("POST", url, body, signer,
                DateTimeOffset.UtcNow.ToUnixTimeSeconds() + clockCorrection);
            var result = await api.CallAsync(request, cancellationToken).ConfigureAwait(false);
            if (result.Reply is { Result: "created" or "exists" } reply)
            {
                var updated = identity with
                {
                    RegisteredUsername = reply.Username ?? username,
                    ProfileUrl = SafeProfileUrl(reply.ProfileUrl) ?? identity.ProfileUrl,
                };
                keyStore.WriteIdentity(updated);
                return (updated, clockCorrection);
            }

            if (result.Reply is { Code: "timestamp_out_of_window", ServerTime: { } serverTime } && attemptNumber == 0)
            {
                clockCorrection = serverTime - DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                continue;
            }

            throw new ReporterFailure(FailureCode(result.Reply));
        }

        throw new ReporterFailure("service_unavailable");
    }

    private static async Task<PersistedIdentity> RenameAsync(
        ReportApi api,
        ReportDiscovery discovery,
        PersistedIdentity identity,
        SoftwareReportSigner signer,
        DpapiReportKeyStore keyStore,
        string username,
        CancellationToken cancellationToken)
    {
        var builder = new ReportRequestBuilder(Client.UserAgent, identity.DeviceId, ApiKey: null);
        var url = discovery.Api.Endpoint(ReportEndpoint.Device(identity.DeviceId));
        var body = ReportDocuments.Rename(username);
        var request = builder.Make("PATCH", url, body, signer, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        var result = await api.CallAsync(request, cancellationToken).ConfigureAwait(false);
        if (result.Reply is not { Result: "updated" or "unchanged" } reply)
        {
            throw new ReporterFailure(FailureCode(result.Reply));
        }

        var updated = identity with
        {
            RegisteredUsername = reply.Username ?? username,
            ProfileUrl = SafeProfileUrl(reply.ProfileUrl) ?? identity.ProfileUrl,
        };
        keyStore.WriteIdentity(updated);
        return updated;
    }

    private static string FailureCode(ReportReply? reply) => reply?.Code switch
    {
        "api_key_required" or "api_key_invalid" => "api_key_required",
        "username_taken" => "username_taken",
        "username_invalid" => "username_invalid",
        "forbidden" => "forbidden",
        "gone" => "service_unsupported",
        _ => reply is null ? "service_unavailable" : "reporting_failed",
    };

    private static string? SafeProfileUrl(string? value)
    {
        if (value is null || value.Length > 2048 || !Uri.TryCreate(value, UriKind.Absolute, out var uri)
            || uri.Scheme != Uri.UriSchemeHttps || uri.UserInfo.Length != 0 || uri.Query.Length > 256
            || uri.Fragment.Length > 256 || uri.Host is not ("deng.codexradar.com" or "codexradar.com"))
        {
            return null;
        }

        return uri.AbsoluteUri;
    }

    private static HelperStatus Status(
        string phase,
        string code,
        ReportSample sample,
        DateTimeOffset? lastReportAt,
        string? profileUrl)
    {
        var sources = sample.Sources
            .Select(pair => new StatusSource(
                StatusProtocol.SourceId(pair.Key),
                StatusProtocol.SourceName(pair.Key),
                SafeRate(pair.Value.Live.Output)))
            .Where(source => source.Tps > 0)
            .OrderBy(source => source.Id, StringComparer.Ordinal)
            .Take(32)
            .ToArray();
        return new HelperStatus(
            Version: 1,
            Phase: phase,
            MessageCode: code,
            LiveOutputTps: SafeRate(sample.Live.Output),
            EstimatedShare: Math.Clamp(double.IsFinite(sample.EstimatedShare) ? sample.EstimatedShare : 0, 0, 1),
            LastReportAt: lastReportAt?.ToString("O"),
            Sources: sources,
            ProfileUrl: SafeProfileUrl(profileUrl));
    }

    private static double SafeRate(double value) => Math.Clamp(double.IsFinite(value) ? value : 0, 0, ReportBody.MaxTokS);

    private static long MonotonicMs() => (long)(Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency);
}
