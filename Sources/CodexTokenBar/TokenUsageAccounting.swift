import Foundation

/// Codex input includes cached input; output includes reasoning. Keep the raw
/// components and derive the two disjoint input buckets only when pricing.
struct UsageAccountingComponents: Codable, Equatable, Sendable {
    var input: Int = 0
    var cached: Int = 0
    var output: Int = 0
    var reasoning: Int = 0

    var total: Int { input.addingReportingOverflow(output).partialValue }
    var isValid: Bool {
        input >= 0 && cached >= 0 && output >= 0 && reasoning >= 0
            && cached <= input && reasoning <= output
            && !input.addingReportingOverflow(output).overflow
    }

    func subtracting(_ other: Self) -> Self? {
        guard input >= other.input, cached >= other.cached,
              output >= other.output, reasoning >= other.reasoning else { return nil }
        let value = Self(input: input - other.input, cached: cached - other.cached,
                         output: output - other.output, reasoning: reasoning - other.reasoning)
        return value.isValid ? value : nil
    }

    func adding(_ other: Self) -> Self? {
        let values = [(input, other.input), (cached, other.cached),
                      (output, other.output), (reasoning, other.reasoning)]
            .map { $0.addingReportingOverflow($1) }
        guard values.allSatisfy({ !$0.overflow }) else { return nil }
        return Self(input: values[0].partialValue, cached: values[1].partialValue,
                    output: values[2].partialValue, reasoning: values[3].partialValue)
    }
}

struct UsageAccountingSnapshot {
    let components: UsageAccountingComponents
    let reportedTotal: Int?
    /// Input and output must be present. Missing cache/reasoning details mean
    /// zero only for the established Codex format; neither can stand in for I/O.
    let hasInputAndOutput: Bool
    let hasInvalidNumber: Bool
    let signature: String

    var usable: Bool { hasInputAndOutput && !hasInvalidNumber && components.isValid }
    var hasUnexplainedUsage: Bool {
        (reportedTotal ?? 0) > 0 || components.input > 0 || components.cached > 0
            || components.output > 0 || components.reasoning > 0 || hasInvalidNumber
    }
}

/// 0 is a measured component delta; other rows are retained for diagnosis and
/// excluded from every numeric aggregate, including request counts.
enum UsageAccountingKind: Int, Codable, Sendable {
    case counted = 0
    case reportedOnly = 1
    case invalid = 2
    case legacyUnresolved = 3
}

struct UsageAccountingResult {
    let components: UsageAccountingComponents
    let kind: UsageAccountingKind
    var tokens: Int { kind == .counted ? components.total : 0 }
}

/// Stored on the existing source/checkpoint, not in a separate ledger. An
/// absent legacy checkpoint is deliberately different from a fresh file.
struct UsageAccountingState: Codable, Equatable, Sendable {
    static let revision = "codex-components-v1"
    var previous: UsageAccountingComponents?
    var unreflected = UsageAccountingComponents()
    var canStartFromZero = false
    var counterReset = false
    var lastSnapshot: String?

    static var fresh: Self { Self(canStartFromZero: true) }

    var encoded: String {
        // All values are finite integers; failure is a programming error, not
        // an excuse to persist a fresh (zero) checkpoint.
        String(data: try! JSONEncoder().encode(self), encoding: .utf8)!
    }

    static func decode(_ value: String?) throws -> Self {
        guard let value else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(value.utf8))
    }

    mutating func observe(
        last: UsageAccountingSnapshot?, total: UsageAccountingSnapshot?
    ) -> UsageAccountingResult? {
        let anchor = previous ?? (canStartFromZero ? UsageAccountingComponents() : nil)
        let cumulative = total.flatMap { $0.usable && !($0.components.total == 0 && ($0.reportedTotal ?? 0) > 0) ? $0.components : nil }
        let pending = unreflected
        var cumulativeDelta: UsageAccountingComponents?
        if let cumulative {
            if let anchor {
                cumulativeDelta = cumulative.subtracting(anchor)?.subtracting(pending)
                if cumulative.input < anchor.input || cumulative.cached < anchor.cached
                    || cumulative.output < anchor.output || cumulative.reasoning < anchor.reasoning {
                    counterReset = true
                }
            }
            previous = cumulative
            unreflected = UsageAccountingComponents()
        }
        if cumulative != nil { canStartFromZero = false }

        if let last, last.usable, last.components.total > 0 {
            if cumulative == nil {
                if let next = unreflected.adding(last.components) {
                    unreflected = next
                } else {
                    previous = nil
                    unreflected = UsageAccountingComponents()
                }
            }
            return UsageAccountingResult(components: last.components, kind: .counted)
        }
        // A malformed last snapshot is not permission to replace it with a
        // differently scoped cumulative quantity.
        if let last, last.hasInvalidNumber || (last.hasInputAndOutput && !last.components.isValid) {
            return UsageAccountingResult(components: last.components, kind: .invalid)
        }
        if let delta = cumulativeDelta, delta.total > 0 {
            return UsageAccountingResult(components: delta, kind: .counted)
        }
        if last?.hasUnexplainedUsage == true {
            return UsageAccountingResult(components: last!.components, kind: .reportedOnly)
        }
        if (cumulativeDelta == nil || total?.components.total == 0), total?.hasUnexplainedUsage == true {
            return UsageAccountingResult(components: total!.components,
                                         kind: total!.usable ? .reportedOnly : .invalid)
        }
        return nil
    }
}

/// Foundation normalizes the JSON integer spelling `-0` to an unsigned zero.
/// Check that rare spelling at its exact usage path before NSNumber loses it.
/// Ordinary token lines only pay for a lexical precheck, not another JSON walk.
enum TokenUsageLexicalValidation {
    private static let negativeZero = try! NSRegularExpression(pattern: #":\s*-0(?=[,\s}\]])"#)
    private static let fields: Set<String> = ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens"]

    static func negativeZeroFields(in line: String) -> [String: Set<String>] {
        guard negativeZero.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { return [:] }
        // The caller has already validated the complete JSON document.
        let bytes = Array(line.utf8)
        var index = 0
        var result: [String: Set<String>] = [:]
        func whitespace() {
            while index < bytes.count && [UInt8(9), 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        func string() -> String {
            let start = index
            index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 { index += 1; break }
                index += 1
            }
            return (try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])) as? String ?? ""
        }
        func value(_ path: [String]) {
            whitespace()
            guard index < bytes.count else { return }
            if bytes[index] == 123 {
                index += 1
                whitespace()
                while index < bytes.count && bytes[index] != 125 {
                    let key = string()
                    whitespace()
                    index += 1 // colon
                    value(path + [key])
                    whitespace()
                    if index < bytes.count && bytes[index] == 44 { index += 1; whitespace() } else { break }
                }
                index += 1
            } else if bytes[index] == 91 {
                index += 1
                whitespace()
                while index < bytes.count && bytes[index] != 93 {
                    value(path + ["[]"])
                    whitespace()
                    if index < bytes.count && bytes[index] == 44 { index += 1 } else { break }
                }
                index += 1
            } else if bytes[index] == 34 {
                _ = string()
            } else {
                let start = index
                while index < bytes.count && ![UInt8(9), 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                if bytes[start..<index].elementsEqual([45, 48]), path.count == 4,
                   path[0] == "payload", path[1] == "info",
                   ["last_token_usage", "total_token_usage"].contains(path[2]), fields.contains(path[3]) {
                    result[path[2], default: []].insert(path[3])
                }
            }
        }
        value([])
        return result
    }
}
