using System.Diagnostics;
using System.Runtime.Versioning;
using System.Threading.Channels;
using AgentSpeed.Core;
using AgentSpeed.Core.Reporting;

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
    private static readonly HashSet<ReportSection> AllowedSections = [ReportSection.Sources, ReportSection.Models];

    public static async Task RunAsync(StartCommand start, StatusEmitter status, CancellationToken cancellationToken)
    {
        if (!AgentSpeedReportSourcePolicy.HasRequiredDenyList(start.DeniedSourceIds))
        {
            throw new ReporterFailure("service_unsupported");
        }

        var username = start.Username;
        var snapshots = Channel.CreateBounded<SpeedSnapshot>(new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = false,
            AllowSynchronousContinuations = false,
        });
        var hub = new SpeedHub(context: null);
        hub.LivePublished += (_, snapshot) => snapshots.Writer.TryWrite(snapshot);
        using var monitor = new LiveMonitor(hub, new MonitorConfiguration(
            AgentSpeedReportSourcePolicy.ReportableSources,
            DshRoot: start.LocalSourceRoots.GetValueOrDefault("deepseek"),
            OpenCodeRoot: start.LocalSourceRoots.GetValueOrDefault("opencode"),
            GeminiRoot: start.LocalSourceRoots.GetValueOrDefault("gemini")));
        monitor.Start();

        await status.PublishAsync(Status(
            "waiting_for_snapshot", "waiting_for_snapshot", ReportSample.Empty, null, null), cancellationToken).ConfigureAwait(false);
        var readySnapshot = await WaitForReadySnapshotAsync(snapshots.Reader, cancellationToken).ConfigureAwait(false);
        var sample = ReportSample.From(readySnapshot, ReportTrafficSample.Off);
        var window = new ReportWindow(sample); // The first complete monitor snapshot is a baseline, never an upload seed.

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
                Metric: SpeedMetric.Output)
            {
                // Keep parity with the native client for negotiated model-level statistics only.
                // Cost, traffic, profile, identity, and avatar extensions remain disabled.
                Extensions = new ReportExtensions(
                    ModelHarnessRequests: discovery.Extensions.ModelHarnessRequests,
                    ExecutionModes: discovery.Extensions.ExecutionModes),
            };
            var reportUrl = discovery.Api.Endpoint(ReportEndpoint.Reports);

            while (!cancellationToken.IsCancellationRequested)
            {
                using (var shortWait = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
                {
                    shortWait.CancelAfter(TimeSpan.FromMilliseconds(250));
                    try
                    {
                        _ = await snapshots.Reader.WaitToReadAsync(shortWait.Token).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                    {
                    }
                }

                var sampleChanged = false;
                while (snapshots.Reader.TryRead(out var latest))
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
                            await status.PublishAsync(Status("registering", "registering", sample, lastReportAt, identity.ProfileUrl), cancellationToken)
                                .ConfigureAwait(false);
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
                    await status.PublishAsync(Status("reporting", "reporting", sample, lastReportAt, identity.ProfileUrl), cancellationToken)
                        .ConfigureAwait(false);
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

                            if (!ReportPayloadWhitelist.IsAllowed(queuedBody))
                            {
                                throw new ReporterFailure("reporting_failed");
                            }

                            var builder = new ReportRequestBuilder(Client.UserAgent, identity.DeviceId, ApiKey: null);
                            var request = builder.Make(
                                "POST", reportUrl, queuedBody, signer,
                                DateTimeOffset.UtcNow.ToUnixTimeSeconds() + clockCorrection);
                            if (!ReportPayloadWhitelist.IsAllowed(request.Body))
                            {
                                throw new ReporterFailure("reporting_failed");
                            }
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
        }
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
