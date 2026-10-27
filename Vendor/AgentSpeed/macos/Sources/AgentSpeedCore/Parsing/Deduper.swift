import Foundation

/// Identifies one transcript file for deduplication ownership.
typealias FileID = Int32

/// Global, bounded set of response keys shared by every file (METRICS 3.4). FIFO eviction.
///
/// The daily history uses the unbounded `hashed()` variant instead: ownership by 64-bit key hash (METRICS 8).
struct Deduper: Sendable {
    enum Claim: Equatable {
        /// The key was never seen; the caller now owns it.
        case new
        /// The key was first seen in the same file.
        case sameFile
        /// The key was first seen in another file.
        case otherFile
    }

    static let defaultCapacity = 65_536

    let capacity: Int
    private var owners: [String: FileID] = [:]
    private var ring: [String] = []
    private var head = 0
    private var ledger: KeyLedger?

    init(capacity: Int = Deduper.defaultCapacity) {
        self.capacity = max(1, capacity)
        owners.reserveCapacity(min(self.capacity, 4096))
    }

    /// Unbounded ownership by key hash; keys owned by files analysed earlier are added with `insertSettled`.
    static func hashed() -> Deduper {
        var deduper = Deduper(capacity: 1)
        deduper.ledger = KeyLedger()
        return deduper
    }

    /// Hashed mode: marks keys as owned by files that are not read again.
    mutating func insertSettled(_ hashes: [UInt64]) {
        ledger?.insertSettled(hashes)
    }

    var count: Int { ledger?.count ?? owners.count }

    func contains(_ key: String) -> Bool {
        if let ledger { return ledger.contains(KeyHash.fnv1a(key)) }
        return owners[key] != nil
    }

    /// True when another file already owns the key; never claims it.
    func isOwnedByOtherFile(_ key: String, for file: FileID) -> Bool {
        if let ledger { return ledger.isOwnedElsewhere(KeyHash.fnv1a(key), by: file) }
        return owners[key].map { $0 != file } ?? false
    }

    mutating func claim(_ key: String, for file: FileID) -> Claim {
        if ledger != nil { return ledger!.claim(KeyHash.fnv1a(key), for: file) }
        if let owner = owners[key] {
            return owner == file ? .sameFile : .otherFile
        }
        if ring.count < capacity {
            ring.append(key)
        } else {
            owners[ring[head]] = nil
            ring[head] = key
            head = (head + 1) % capacity
        }
        owners[key] = file
        return .new
    }

    /// Hashed mode: ends the current file and returns the hashes it owns.
    mutating func finishFile() -> [UInt64] {
        ledger?.settleCurrent() ?? []
    }
}

/// Key-hash ownership for the hashed deduper: keys of finished files plus those of the file being read.
struct KeyLedger: Sendable {
    private var settled: Set<UInt64> = []
    private var current: Set<UInt64> = []
    private var currentOrder: [UInt64] = []
    private var currentFile: FileID?

    init() {}

    var count: Int { settled.count + current.count }

    func contains(_ hash: UInt64) -> Bool { settled.contains(hash) || current.contains(hash) }

    /// Adds keys owned by files that are not read again.
    mutating func insertSettled<S: Sequence>(_ hashes: S) where S.Element == UInt64 {
        for hash in hashes { settled.insert(hash) }
    }

    mutating func reserveSettled(_ count: Int) {
        settled.reserveCapacity(count)
    }

    func isOwnedElsewhere(_ hash: UInt64, by file: FileID) -> Bool {
        file == currentFile ? settled.contains(hash) : contains(hash)
    }

    mutating func claim(_ hash: UInt64, for file: FileID) -> Deduper.Claim {
        if file != currentFile {
            _ = settleCurrent()
            currentFile = file
        }
        if current.contains(hash) { return .sameFile }
        if settled.contains(hash) { return .otherFile }
        current.insert(hash)
        currentOrder.append(hash)
        return .new
    }

    /// Moves the current file's keys into the settled set and returns them in first-seen order.
    mutating func settleCurrent() -> [UInt64] {
        defer {
            current.removeAll(keepingCapacity: current.count < 1 << 16)
            currentOrder = []
            currentFile = nil
        }
        for hash in currentOrder { settled.insert(hash) }
        return currentOrder
    }
}

/// 64-bit FNV-1a over the UTF-8 bytes of a response key (METRICS 8).
enum KeyHash {
    static let offsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325
    static let prime: UInt64 = 0x0000_0100_0000_01B3

    static func fnv1a(_ key: String) -> UInt64 {
        var key = key
        return key.withUTF8 { bytes in
            var hash = offsetBasis
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= prime
            }
            return hash
        }
    }
}
