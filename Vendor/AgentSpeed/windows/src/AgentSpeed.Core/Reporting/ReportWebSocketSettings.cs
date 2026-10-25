namespace AgentSpeed.Core.Reporting;

/// <summary>Strictly negotiated Agent Speed report WebSocket limits (REPORTING-WEBSOCKET 3).</summary>
public sealed record ReportWebSocketSettings(
    int MinIntervalMs,
    int MaxInFlight,
    int AckTimeoutMs,
    int MaxMessageBytes,
    int PingIntervalSeconds,
    int PongTimeoutSeconds)
{
    public const string Path = "/v1/reports/ws";
    public const string Subprotocol = "agent-speed-report.v1";

    public static ReportWebSocketSettings Defaults { get; } = new(50, 8, 2_000, 65_536, 20, 10);

    public ReportJson ToJson() => ReportJson.Object(
        ("path", ReportJson.Of(Path)),
        ("subprotocol", ReportJson.Of(Subprotocol)),
        ("minIntervalMs", ReportJson.Of(MinIntervalMs)),
        ("maxInFlight", ReportJson.Of(MaxInFlight)),
        ("ackTimeoutMs", ReportJson.Of(AckTimeoutMs)),
        ("maxMessageBytes", ReportJson.Of(MaxMessageBytes)),
        ("pingIntervalSeconds", ReportJson.Of(PingIntervalSeconds)),
        ("pongTimeoutSeconds", ReportJson.Of(PongTimeoutSeconds)));
}
