import Foundation

struct GrokBuildUsage: Sendable {
    var model: String?
    var usage: TokenUsage
    var durationMs: Int64?
    var requestCount: Int
}

struct GrokBuildLine: Sendable {
    var kind: String
    var time: Int64?
    var model: String?
    var status: String?
    var promptId: String?
    var eventId: String?
    var batches: [GrokBuildUsage] = []

    static func extract(_ bytes: UnsafeRawBufferPointer) -> LineExtraction<GrokBuildLine> {
        guard bytes.contains(where: { ![9, 10, 13, 32].contains($0) }) else { return .blank }
        guard let json = try? JSONParser.parse(Data(bytes)), json.object != nil else { return .malformed }
        guard let method = json["method"]?.string, method == "session/update" || method == "_x.ai/session/update" else {
            return .line(GrokBuildLine(kind: ""))
        }
        let params = json["params"]
        let update = params?["update"]
        let milliseconds = integer(params?["_meta"]?["agentTimestampMs"])
        var secondsMs: Int64?
        if let seconds = json["timestamp"]?.literal?.double, seconds.isFinite, abs(seconds) < Double(Int64.max) / 1000 {
            secondsMs = Int64(seconds * 1000)
        }
        let time = (milliseconds ?? secondsMs).flatMap { DayLabeler.hasDay($0) ? $0 : nil }
        var line = GrokBuildLine(kind: update?["sessionUpdate"]?.string ?? "", time: time,
                                 model: update?["model"]?.string ?? update?["model_id"]?.string,
                                 status: update?["status"]?.string, promptId: update?["prompt_id"]?.string,
                                 eventId: params?["_meta"]?["eventId"]?.string)
        if line.kind == "turn_completed", let usage = update?["usage"] {
            if let models = usage["modelUsage"]?.object, !models.isEmpty {
                line.batches = models.keys.sorted().prefix(256).compactMap { model in
                    models[model].flatMap { batch($0, model: model) }
                }
            } else if let batch = batch(usage["totals"] ?? usage, model: line.model) {
                line.batches = [batch]
            }
        }
        return .line(line)
    }

    private static func integer(_ value: JSONValue?) -> Int64? {
        HarnessJSON.milliseconds(value)
    }

    private static func batch(_ value: JSONValue, model: String?) -> GrokBuildUsage? {
        guard value.object != nil else { return nil }
        func count(_ camel: String, _ snake: String) -> Int { HarnessJSON.count(value[camel] ?? value[snake]) }
        let input = count("inputTokens", "input_tokens")
        let duration = integer(value["apiDurationMs"] ?? value["api_duration_ms"])
        let output = count("outputTokens", "output_tokens")
        return GrokBuildUsage(model: model, usage: TokenUsage(input: input,
            cachedInput: min(input, count("cachedReadTokens", "cache_read_input_tokens")),
            cacheWriteInput: min(input, count("cacheCreationTokens", "cache_creation_input_tokens")),
            output: output, reasoning: min(output, count("reasoningTokens", "reasoning_tokens"))),
            durationMs: duration.flatMap { $0 > 0 && $0 <= ResponseTiming.maxIntervalMs ? $0 : nil },
            requestCount: min(100_000, max(1, count("modelCalls", "model_calls"))))
    }
}
