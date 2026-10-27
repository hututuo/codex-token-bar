import CoreFoundation
import Foundation

public enum ClaudeStatuslineCaptureError: Error, Equatable {
    case inputTooLarge
    case invalidJSON
    case invalidField(String)
    case invalidCaptureTime
    case unsafeCachePath
    case fileSystemFailure(String, Int32)
}

/// Parses only the explicitly supported Claude statusline fields. Unknown input keys
/// are discarded, so paths, prompts, tool payloads, credentials, and future fields do
/// not enter the saved schema.
public enum ClaudeStatuslineParser {
    public static let maximumInputBytes = 64 * 1024

    private static let allowedWindows = ["five_hour", "seven_day", "spend_limit"]

    public static func parse(_ data: Data, capturedAt: Date = Date()) throws -> ClaudeStatuslineSnapshot {
        guard data.count <= maximumInputBytes else {
            throw ClaudeStatuslineCaptureError.inputTooLarge
        }
        let epochValue = capturedAt.timeIntervalSince1970
        guard epochValue.isFinite, epochValue >= 0, epochValue < 9_223_372_036_854_775_808.0 else {
            throw ClaudeStatuslineCaptureError.invalidCaptureTime
        }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ClaudeStatuslineCaptureError.invalidJSON
        }
        guard let object = root as? [String: Any] else {
            throw ClaudeStatuslineCaptureError.invalidJSON
        }

        let sessionId = try optionalString(object["session_id"], field: "session_id", maximumLength: 256)
        let model = try parseModel(object["model"])
        let rateLimits = try parseRateLimits(object["rate_limits"])
        let cost = try parseCost(object["cost"])
        let contextWindow = try parseContextWindow(object["context_window"])

        return ClaudeStatuslineSnapshot(
            capturedAtEpoch: Int64(epochValue.rounded(.down)),
            sessionId: sessionId,
            model: model,
            rateLimits: rateLimits,
            cost: cost,
            contextWindow: contextWindow
        )
    }

    private static func parseModel(_ value: Any?) throws -> ClaudeStatuslineSnapshot.Model? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any] else {
            throw ClaudeStatuslineCaptureError.invalidField("model")
        }
        let model = ClaudeStatuslineSnapshot.Model(
            id: try optionalString(object["id"], field: "model.id", maximumLength: 128),
            displayName: try optionalString(object["display_name"], field: "model.display_name", maximumLength: 128)
        )
        return model.id == nil && model.displayName == nil ? nil : model
    }

    private static func parseRateLimits(_ value: Any?) throws -> ClaudeStatuslineSnapshot.RateLimits? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any] else {
            throw ClaudeStatuslineCaptureError.invalidField("rate_limits")
        }

        var windows: [String: ClaudeStatuslineSnapshot.RateLimitWindow] = [:]
        for key in allowedWindows {
            guard let raw = object[key], !(raw is NSNull) else { continue }
            guard let window = raw as? [String: Any] else {
                throw ClaudeStatuslineCaptureError.invalidField("rate_limits.\(key)")
            }
            let percentage = try optionalNumber(window["used_percentage"], field: "rate_limits.\(key).used_percentage")
            let parsedWindow = ClaudeStatuslineSnapshot.RateLimitWindow(
                usedPercentage: percentage,
                resetsAt: try optionalEpoch(window["resets_at"], field: "rate_limits.\(key).resets_at")
            )
            if parsedWindow.usedPercentage != nil || parsedWindow.resetsAt != nil {
                windows[key] = parsedWindow
            }
        }
        guard !windows.isEmpty else { return nil }
        return ClaudeStatuslineSnapshot.RateLimits(
            fiveHour: windows["five_hour"],
            sevenDay: windows["seven_day"],
            spendLimit: windows["spend_limit"]
        )
    }

    private static func parseCost(_ value: Any?) throws -> ClaudeStatuslineSnapshot.CostCounters? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any] else {
            throw ClaudeStatuslineCaptureError.invalidField("cost")
        }
        let counters = ClaudeStatuslineSnapshot.CostCounters(
            totalAPIDurationMS: try optionalInteger(object["total_api_duration_ms"], field: "cost.total_api_duration_ms"),
            totalDurationMS: try optionalInteger(object["total_duration_ms"], field: "cost.total_duration_ms")
        )
        return counters.totalAPIDurationMS == nil && counters.totalDurationMS == nil ? nil : counters
    }

    private static func parseContextWindow(_ value: Any?) throws -> ClaudeStatuslineSnapshot.ContextCounters? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any] else {
            throw ClaudeStatuslineCaptureError.invalidField("context_window")
        }
        let currentUsage = try parseCurrentUsage(object["current_usage"])
        let counters = ClaudeStatuslineSnapshot.ContextCounters(
            contextWindowSize: try optionalInteger(object["context_window_size"], field: "context_window.context_window_size"),
            totalInputTokens: try optionalInteger(object["total_input_tokens"], field: "context_window.total_input_tokens"),
            totalOutputTokens: try optionalInteger(object["total_output_tokens"], field: "context_window.total_output_tokens"),
            currentUsage: currentUsage
        )
        return counters.contextWindowSize == nil
            && counters.totalInputTokens == nil
            && counters.totalOutputTokens == nil
            && counters.currentUsage == nil ? nil : counters
    }

    private static func parseCurrentUsage(_ value: Any?) throws -> ClaudeStatuslineSnapshot.CurrentUsage? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any] else {
            throw ClaudeStatuslineCaptureError.invalidField("context_window.current_usage")
        }
        let counters = ClaudeStatuslineSnapshot.CurrentUsage(
            inputTokens: try optionalInteger(object["input_tokens"], field: "context_window.current_usage.input_tokens"),
            outputTokens: try optionalInteger(object["output_tokens"], field: "context_window.current_usage.output_tokens"),
            cacheCreationInputTokens: try optionalInteger(object["cache_creation_input_tokens"], field: "context_window.current_usage.cache_creation_input_tokens"),
            cacheReadInputTokens: try optionalInteger(object["cache_read_input_tokens"], field: "context_window.current_usage.cache_read_input_tokens")
        )
        return counters.inputTokens == nil
            && counters.outputTokens == nil
            && counters.cacheCreationInputTokens == nil
            && counters.cacheReadInputTokens == nil ? nil : counters
    }

    private static func optionalString(_ value: Any?, field: String, maximumLength: Int) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String,
              !string.isEmpty,
              string.utf8.count <= maximumLength,
              !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ClaudeStatuslineCaptureError.invalidField(field)
        }
        return string
    }

    private static func optionalInteger(_ value: Any?, field: String) throws -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        let number = try validatedNumber(value, field: field)
        guard number.rounded(.towardZero) == number,
              number < 9_223_372_036_854_775_808.0
        else {
            throw ClaudeStatuslineCaptureError.invalidField(field)
        }
        return Int64(number)
    }

    private static func optionalEpoch(_ value: Any?, field: String) throws -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            guard !string.isEmpty, string.utf8.count <= 64 else {
                throw ClaudeStatuslineCaptureError.invalidField(field)
            }
            let formatters: [ISO8601DateFormatter] = [
                ISO8601DateFormatter(),
                ISO8601DateFormatter()
            ]
            formatters[0].formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatters[1].formatOptions = [.withInternetDateTime]
            guard let date = formatters.lazy.compactMap({ $0.date(from: string) }).first else {
                throw ClaudeStatuslineCaptureError.invalidField(field)
            }
            let epoch = date.timeIntervalSince1970
            guard epoch.isFinite, epoch >= 0, epoch < 9_223_372_036_854_775_808.0 else {
                throw ClaudeStatuslineCaptureError.invalidField(field)
            }
            return Int64(epoch.rounded(.down))
        }
        return try optionalInteger(value, field: field)
    }

    private static func optionalNumber(_ value: Any?, field: String) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        return try validatedNumber(value, field: field)
    }

    private static func validatedNumber(_ value: Any, field: String) throws -> Double {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            throw ClaudeStatuslineCaptureError.invalidField(field)
        }
        let double = number.doubleValue
        guard double.isFinite, double >= 0 else {
            throw ClaudeStatuslineCaptureError.invalidField(field)
        }
        return double
    }
}
