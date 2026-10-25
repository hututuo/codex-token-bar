import Foundation
import os

/// Cost of today's or a day's responses (METRICS 9.6, 9.7): Σ known costs and the responses without a known price.
public struct CostTally: Equatable, Hashable, Sendable {
    public var costMicroUsd: Int64
    public var unpricedRequests: Int

    public init(costMicroUsd: Int64 = 0, unpricedRequests: Int = 0) {
        self.costMicroUsd = costMicroUsd
        self.unpricedRequests = unpricedRequests
    }

    public static let zero = CostTally()

    /// Adds (`sign` 1) or removes (`sign` -1) one response's cost; nil counts as unpriced.
    public mutating func add(_ cost: Int64?, sign: Int = 1, requestCount: Int = 1) {
        if let cost {
            costMicroUsd += Int64(sign) * cost
        } else {
            unpricedRequests += sign * requestCount
        }
    }

    public mutating func add(_ other: CostTally) {
        costMicroUsd += other.costMicroUsd
        unpricedRequests += other.unpricedRequests
    }

    /// Nothing is priced although there were requests.
    public func isUnknown(requests: Int) -> Bool { requests > 0 && unpricedRequests >= requests }
}

/// The price tables a process knows and the day bindings of METRICS 9.7: each local date keeps the table version it
/// was first priced with, and a response that table cannot price takes the current table (late pricing).
///
/// Thread-safe: the live engine and the daily history share one book.
public final class PriceBook: Sendable {
    private struct State {
        var tables: [Int: PriceTable]
        var current: Int
        var bindings: [String: Int]
        /// Dates bound (or re-bound) since the last `takeNewBindings()`.
        var unsaved: Set<String> = []
    }

    private let state: OSAllocatedUnfairLock<State>
    private let observer = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    /// The table bundled with this build (`spec/assets/prices.json`).
    public static let bundled: PriceTable = {
        guard case .success(let table) = PriceTable.load(Data(BundledPriceAssets.prices.utf8)) else {
            fatalError("The bundled price table does not validate; run python3 spec/tools/prices.py")
        }
        return table
    }()

    /// `tables` must not be empty; the highest version is current.
    public init(tables: [PriceTable], bindings: [String: Int] = [:]) {
        precondition(!tables.isEmpty)
        var byVersion: [Int: PriceTable] = [:]
        for table in tables { byVersion[table.version] = table }
        state = OSAllocatedUnfairLock(initialState: State(tables: byVersion, current: byVersion.keys.max()!, bindings: bindings))
    }

    /// A book with only the bundled table.
    public convenience init() {
        self.init(tables: [Self.bundled])
    }

    public var current: PriceTable { state.withLock { $0.tables[$0.current]! } }
    public var currentVersion: Int { state.withLock { $0.current } }
    public var bindings: [String: Int] { state.withLock { $0.bindings } }

    public func table(version: Int) -> PriceTable? { state.withLock { $0.tables[version] } }

    /// Every known table, by version.
    public var tables: [Int: PriceTable] { state.withLock { $0.tables } }

    /// Adds a table (a synced download or a stored copy). Returns true when it became the current table.
    @discardableResult
    public func add(_ table: PriceTable) -> Bool {
        state.withLock { state in
            if state.tables[table.version] == nil { state.tables[table.version] = table }
            guard table.version > state.current else { return false }
            state.current = table.version
            return true
        }
    }

    /// Takes the stored bindings: a stored date keeps its stored version; a binding whose table is unknown (missing
    /// or invalid copy) is replaced by the current version and saved again (returned). Dates bound in memory but not
    /// stored yet stay as they are.
    @discardableResult
    public func restore(bindings stored: [String: Int]) -> [String] {
        state.withLock { state in
            var repaired: [String] = []
            for (day, version) in stored {
                if state.tables[version] != nil {
                    state.bindings[day] = version
                    state.unsaved.remove(day)
                } else {
                    if state.bindings[day].map({ state.tables[$0] == nil }) ?? true { state.bindings[day] = state.current }
                    state.unsaved.insert(day)
                    repaired.append(day)
                }
            }
            return repaired.sorted()
        }
    }

    /// Adds the valid stored table copies, then takes the stored bindings (`restore`). Returns the repaired dates.
    @discardableResult
    public func restore(bindings stored: [String: Int], tables copies: [Int: Data]) -> [String] {
        for (version, data) in copies.sorted(by: { $0.key < $1.key }) where table(version: version) == nil {
            if case .success(let table) = PriceTable.load(data), table.version == version { add(table) }
        }
        return restore(bindings: stored)
    }

    /// "Clear history" deletes every binding (METRICS 9.7).
    public func clearBindings() {
        state.withLock { state in
            state.bindings = [:]
            state.unsaved = []
        }
    }

    /// The version bound to `day`, binding it to the current table first when it has none.
    public func version(forDay day: String) -> Int {
        let (version, bound) = state.withLock { state -> (Int, Bool) in
            if let version = state.bindings[day], state.tables[version] != nil { return (version, false) }
            state.bindings[day] = state.current
            state.unsaved.insert(day)
            return (state.current, true)
        }
        if bound { observer.withLock { $0 }?() }
        return version
    }

    /// The version bound to `day` without binding it.
    public func boundVersion(forDay day: String) -> Int? {
        state.withLock { $0.bindings[day] }
    }

    /// The cost of a response of local date `day` (METRICS 9.7): the day's table, else the current one.
    public func cost(of record: ResponseRecord, day: String) -> Int64? {
        cost(model: record.model, provider: record.provider, usage: record.usage, endMs: record.endMs, fast: record.fast, day: day)
    }

    public func cost(model: String?, provider: String?, usage: TokenUsage, endMs: Int64?, fast: Bool, day: String) -> Int64? {
        let version = version(forDay: day)
        let (bound, current) = state.withLock { ($0.tables[version]!, $0.tables[$0.current]!) }
        if let cost = bound.cost(model: model, provider: provider, usage: usage, endMs: endMs, fast: fast) { return cost }
        guard version != current.version else { return nil }
        return current.cost(model: model, provider: provider, usage: usage, endMs: endMs, fast: fast)
    }

    /// Bindings made since the last call, for the history store.
    public func takeNewBindings() -> [String: Int] {
        state.withLock { state in
            defer { state.unsaved = [] }
            var out: [String: Int] = [:]
            for day in state.unsaved { out[day] = state.bindings[day] }
            return out
        }
    }

    /// Called (on the binding thread) whenever a date is bound, so the owner can save it.
    public func setBindingObserver(_ handler: (@Sendable () -> Void)?) {
        observer.withLock { $0 = handler }
    }
}
