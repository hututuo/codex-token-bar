import Foundation

/// Token scope and quota ownership are independent: an aggregate Token
/// projection must not erase Codex history or relabel it as Claude quota.
struct SidebarTrendData {
    let bins: [BinUsage]
    let quota: [QuotaHistoryRecentBucket]
    let includesCodex: Bool

    init(codexBins: [BinUsage], projectedBins: [BinUsage]?,
         quota: [QuotaHistoryRecentBucket], clients: Set<String>) {
        bins = Array((projectedBins ?? codexBins).suffix(288))
        includesCodex = clients.contains("codex")
        self.quota = includesCodex ? Array(quota.suffix(288)) : []
    }

    var alignedQuota: [QuotaHistoryRecentBucket?] {
        let byTime = Dictionary(quota.map { (Int(floor($0.start.timeIntervalSince1970 / 300)), $0) },
                                uniquingKeysWith: { _, last in last })
        return bins.map { byTime[Int(floor($0.start.timeIntervalSince1970 / 300))] }
    }

    static func isolatedIndices(_ values: [Double?]) -> [Int] {
        func valid(_ index: Int) -> Bool {
            values.indices.contains(index) && values[index]?.isFinite == true
        }
        return values.indices.filter { valid($0) && !valid($0 - 1) && !valid($0 + 1) }
    }
}
