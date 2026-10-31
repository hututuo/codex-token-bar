using System.Text;

namespace CodexTokenBar.AgentSpeedReporter;

/// <summary>Offline checks for strict known WebSocket messages and forward-compatible unknown message types.</summary>
internal static class WebSocketMessageCompatibilitySelfTests
{
    public static void Run()
    {
        UnknownTypedObjectIsIgnored();
        ValidAcknowledgementIsParsed();
        ValidErrorIsParsed();
        MalformedKnownMessagesAreRejected();
        InvalidJsonAndDuplicatesAreRejected();
        InvalidMessageTypesAreRejected();
        ValidUnmatchedAcknowledgementStillParses();
        Console.WriteLine("PASS: WebSocket message compatibility");
    }

    private static void UnknownTypedObjectIsIgnored()
    {
        var message = Parse("""{"type":"future_notice","detail":"ignored"}""");
        if (message is not null)
        {
            throw new InvalidOperationException("unknown_websocket_message_was_not_ignored");
        }
    }

    private static void ValidAcknowledgementIsParsed()
    {
        var message = Parse(Acknowledgement(1));
        if (message is not WebSocketMessage.Ack { Value: { Seq: 1, Status: "accepted" } })
        {
            throw new InvalidOperationException("valid_websocket_ack_was_not_parsed");
        }
    }

    private static void ValidErrorIsParsed()
    {
        var message = Parse("""{"type":"error","run":null,"httpStatus":422,"error":{"code":"payload_invalid"},"fatal":true}""");
        if (message is not WebSocketMessage.Error { Value: { HttpStatus: 422, Code: "payload_invalid", Fatal: true } })
        {
            throw new InvalidOperationException("valid_websocket_error_was_not_parsed");
        }
    }

    private static void MalformedKnownMessagesAreRejected()
    {
        ExpectInvalid("""{"type":"ack"}""", "malformed_ack");
        ExpectInvalid("""{"type":"error"}""", "malformed_error");
    }

    private static void InvalidJsonAndDuplicatesAreRejected()
    {
        ExpectInvalid("{not json", "invalid_json");
        ExpectInvalid("""{"type":"notice","type":"other"}""", "duplicate_members");
    }

    private static void InvalidMessageTypesAreRejected()
    {
        ExpectInvalid("{}", "missing_type");
        ExpectInvalid("""{"type":1}""", "non_string_type");
        ExpectInvalid("""{"type":""}""", "empty_type");
    }

    private static void ValidUnmatchedAcknowledgementStillParses()
    {
        var message = Parse(Acknowledgement(987));
        if (message is not WebSocketMessage.Ack { Value: { Seq: 987, Status: "duplicate" } })
        {
            throw new InvalidOperationException("valid_unmatched_websocket_ack_was_not_parsed");
        }
    }

    private static string Acknowledgement(int seq) =>
        $$"""{"type":"ack","run":{"id":"00000000-0000-4000-8000-000000000001","seq":{{seq}}},"status":"{{(seq == 1 ? "accepted" : "duplicate")}}","bodySha256":"{{new string('a', 64)}}","receivedAt":"2026-10-31T10:00:00.000Z","acceptedAt":"2026-10-31T10:00:00.000Z","processingMs":1}""";

    private static WebSocketMessage? Parse(string json) =>
        ReportWebSocketSession.ParseServiceMessage(Encoding.UTF8.GetBytes(json));

    private static void ExpectInvalid(string json, string name)
    {
        try
        {
            _ = Parse(json);
        }
        catch (InvalidDataException)
        {
            return;
        }

        throw new InvalidOperationException($"expected_invalid_websocket_message:{name}");
    }
}
