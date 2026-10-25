import Foundation

struct KimiLine: Sendable {
    var type: String
    var time: Int64?
    var agent: String?
    var model: String?
    var hasModeSelection = false
    var provider: String?
    var role: String?
    var messageId: String?
    var usage: TokenUsage?
    var durationMs: Int64?
    var hasTools = false
    var partial = false
    var cwd: String?
    var event: String?
}

enum KimiLineExtractor {
    static func extract(_ bytes: UnsafeRawBufferPointer) -> LineExtraction<KimiLine> {
        guard bytes.contains(where: { ![9, 10, 13, 32].contains($0) }) else { return .blank }
        guard let json = try? JSONParser.parse(Data(bytes)), json.object != nil else { return .malformed }
        guard let type = json["type"]?.string else { return .line(KimiLine(type: "")) }
        var line = KimiLine(type: type, time: timestamp(json["time"] ?? json["created_at"]), agent: json["agentId"]?.string,
                            model: json["model"]?.string, provider: json["provider"]?.string)
        line.hasModeSelection = json["model"] != nil
        line.cwd = json["environmentDisclosure"]?["cwd"]?.string ?? json["cwd"]?.string ?? json["workDir"]?.string ?? json["work_dir"]?.string
        if type == "context.append_loop_event", let event = json["event"] {
            line.event = event["type"]?.string ?? event.string
            line.messageId = event["messageId"]?.string
            line.usage = usage(event["usage"])
            line.durationMs = timing(event)
            line.hasTools = event["finishReason"]?.string == "tool_calls"
            line.role = line.event == "step.end" ? "assistant" : nil
            return .line(line)
        }
        let outer = json["message"]
        let message = outer?["message"] ?? outer
        let meta = outer?["meta"] ?? json["meta"]
        line.role = message?["role"]?.string
        line.messageId = message?["providerMessageId"]?.string ?? message?["id"]?.string ?? meta?["messageId"]?.string
        line.usage = usage(message?["usage"] ?? meta?["usage"])
        if let selected = meta?["model"]?["model"] {
            line.hasModeSelection = true
            line.model = selected.string
        }
        line.provider = meta?["model"]?["provider"]?.string ?? line.provider
        line.durationMs = timing(message?["llmTiming"] ?? meta?["llmTiming"] ?? json["llmTiming"])
        line.hasTools = !(message?["toolCalls"]?.array ?? []).isEmpty
        line.partial = message?["partial"]?.bool == true
        if type == "usage.record" { line.usage = usage(json["usage"]) }
        return .line(line)
    }

    private static func usage(_ value: JSONValue?) -> TokenUsage? {
        guard let value, value.object != nil else { return nil }
        let other = HarnessJSON.count(value["inputOther"])
        let read = HarnessJSON.count(value["inputCacheRead"])
        let creation = HarnessJSON.count(value["inputCacheCreation"])
        let output = HarnessJSON.count(value["output"])
        var reasoning = HarnessJSON.count(value["raw"]?["reasoning_tokens"])
        if reasoning == 0 { reasoning = HarnessJSON.count(value["raw"]?["completion_tokens_details"]?["reasoning_tokens"]) }
        return TokenUsage(input: TokenCount.sum(other, read, creation), cachedInput: read, cacheWriteInput: creation,
                          output: output, reasoning: min(output, reasoning))
    }

    private static func timing(_ value: JSONValue?) -> Int64? {
        guard let first = milliseconds(value?["llmFirstTokenLatencyMs"]),
              let stream = milliseconds(value?["llmStreamDurationMs"]), first >= 0, stream >= 0,
              first <= ResponseTiming.maxIntervalMs, stream <= ResponseTiming.maxIntervalMs else { return nil }
        return first + stream
    }

    private static func milliseconds(_ value: JSONValue?) -> Int64? {
        HarnessJSON.milliseconds(value)
    }

    private static func timestamp(_ value: JSONValue?) -> Int64? {
        guard let time = value?.string.flatMap(Timestamp.parse) ?? milliseconds(value), DayLabeler.hasDay(time) else { return nil }
        return time
    }
}
