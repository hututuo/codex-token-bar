import Foundation

/// Checkpointed association only; cumulative turn/thread totals are never consumption.
/// The legacy parser remains authoritative for ordinary requests and their stable IDs.
struct CodexCompactionAccounting: Codable, Equatable {
    struct Record: Codable, Equatable {
        var responseID: String
        var timestamp: Double
        var components: UsageAccountingComponents?
        var cacheWriteInputTokens: Int?
        var reportedTotal: Int?
        var ordinal: UInt64?
        var offset: UInt64
        var model: String?
        var prompt: UInt64?
        var assistant: UInt64?
        var compacted = false
        var mirrored = false
        var emitted = false
        var unknownEmitted = false
    }
    var recent: [Record] = []
    var lastModernID: String?
    var anchorNextEmptyLegacy = false

    mutating func remember(_ record: Record) -> Record? {
        lastModernID = record.responseID
        if let i = recent.firstIndex(where: { $0.responseID == record.responseID }) {
            // A late exact response ID resolves an unknown observation; keep its
            // marker position and timestamp so all published interval locators agree.
            if recent[i].compacted, recent[i].components == nil, record.components != nil {
                recent[i].components = record.components
                recent[i].cacheWriteInputTokens = record.cacheWriteInputTokens
                recent[i].reportedTotal = record.reportedTotal
                return recent[i]
            }
            return nil
        }
        recent.append(record)
        if recent.count > 128 { recent.removeFirst(recent.count - 128) }
        return nil
    }

    mutating func compact(_ fallback: Record) -> Record? {
        anchorNextEmptyLegacy = true
        lastModernID = fallback.responseID
        if let i = recent.firstIndex(where: { $0.responseID == fallback.responseID }) {
            guard !recent[i].compacted else { return nil }
            recent[i].compacted = true
            recent[i].offset = fallback.offset
            // Preserve usage time/model/turn links from the actual response.
            return recent[i].mirrored ? nil : recent[i]
        }
        var item = fallback
        item.compacted = true
        recent.append(item)
        if recent.count > 128 { recent.removeFirst(recent.count - 128) }
        return item
    }

    mutating func markEmitted(_ record: Record) {
        guard let i = recent.firstIndex(where: { $0.responseID == record.responseID }) else { return }
        if record.components != nil { recent[i].emitted = true }
        else { recent[i].unknownEmitted = true }
    }

    /// Only the nearest preceding modern packet can be the legacy mirror.
    /// Equal counts in a later independent request must remain a new request.
    mutating func observeLegacy(last: UsageAccountingComponents?, counted: Bool) -> Bool {
        defer { lastModernID = nil; anchorNextEmptyLegacy = false }
        guard counted, let last, let id = lastModernID,
              let i = recent.firstIndex(where: { $0.responseID == id }),
              recent[i].components == last, !recent[i].mirrored else { return false }
        recent[i].mirrored = true
        return recent[i].emitted
    }
}
