import CryptoKit
import Foundation
import Darwin

/// A single background owner. Own checkpoints and SQLite never hold a billing
/// index operation gate. Only new complete lines are decoded on valid appends.
actor CacheRetentionEngine {
    private let database: CacheRetentionDatabase
    private let source: CodexDataSource

    init(source: CodexDataSource, databaseURL: URL? = nil) throws {
        self.source = source
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexTokenBarSwift/cache-retention-v1", isDirectory: true)
        database = try CacheRetentionDatabase(url: databaseURL ?? directory.appendingPathComponent(CacheRetentionIdentity.hash(source.usageIdentityKey) + ".sqlite"))
    }

    func snapshot(scope: CacheRetentionScope) throws -> CacheRetentionSnapshot {
        try database.snapshot(scope: scope, now: Date())
    }

    func synchronize(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> Int {
        guard source.homeIdentity == CodexHomeIdentity.read(at: source.codexHome) else { throw CacheRetentionError.sourceChanged }
        let files = try CodexUsageAnalyzer(dataSource: source).usageJSONLFiles()
        let kinds = try knownSubagents()
        let kindKeys = Set(kinds.map(CacheRetentionIdentity.hash))
        let summaries = try database.summaries()
        var visited: Set<String> = []
        var failures = 0
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let key = CacheRetentionIdentity.hash(CodexRolloutReader.logicalURL(file).standardizedFileURL.path)
            visited.insert(key)
            do {
                let preferred = try SourceFileObservation.readPreferredPhysical(at: file)
                let signature = fingerprint(preferred.observation)
                let old = summaries[key]
                let sameKind = old.map { $0.isChild == ($0.explicitChild || kindKeys.contains($0.session)) } ?? false
                if old?.fingerprint != signature || !sameKind {
                    let checkpoint = try await read(file: preferred.file, observation: preferred.observation,
                        cached: sameKind ? database.checkpoint(key) : nil, knownSubagents: kinds)
                    try checkBudget()
                    try database.publish(key: key, fingerprint: signature, checkpoint: checkpoint)
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as SQLiteDatabaseError { throw error }
            catch CacheRetentionError.budgetExceeded { throw CacheRetentionError.budgetExceeded }
            catch { failures += 1 }
            if index % 16 == 0 || index == files.count - 1 { progress(index + 1, files.count) }
            await Task.yield()
        }
        guard source.homeIdentity == CodexHomeIdentity.read(at: source.codexHome) else { throw CacheRetentionError.sourceChanged }
        try database.removeMissing(visited)
        return failures
    }

    private func knownSubagents() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: source.stateDatabase.path) else { return [] }
        let reader = SQLiteDatabaseDriver(url: source.stateDatabase, readOnly: true, createsFileIfMissing: false, busyTimeoutMilliseconds: 150)
        return Set(try reader.readRows("SELECT id,source FROM threads;") { s -> String? in
            guard (s.text(1) ?? "").contains("subagent") else { return nil }
            return s.text(0)
        }.compactMap { $0 })
    }

    private func fingerprint(_ observation: SourceFileObservation) -> String {
        "\(CacheRetentionParser.revision):\(observation.size):\(observation.modifiedAt):\(observation.physicalStamp)"
    }

    private func checkBudget() throws {
        var total: UInt64 = 0
        for suffix in ["", "-wal"] {
            if let attr = try? FileManager.default.attributesOfItem(atPath: database.url.path + suffix), let size = attr[.size] as? NSNumber { total += size.uint64Value }
        }
        if total > 500 * 1024 * 1024 { throw CacheRetentionError.budgetExceeded }
    }

    private static func newlineOffset(in data: Data, from offset: Int) -> Int? {
        guard offset < data.count else { return nil }
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress,
                  let found = memchr(base.advanced(by: offset), 10, bytes.count - offset) else { return nil }
            return base.distance(to: found)
        }
    }

    private func read(file: URL, observation: SourceFileObservation, cached: CacheRetentionCheckpoint?, knownSubagents: Set<String>) async throws -> CacheRetentionCheckpoint {
        let reader = try CodexRolloutReader(forReadingFrom: file)
        defer { try? reader.close() }
        let opened = try SourceFileObservation.readPhysical(handle: reader.physicalHandle)
        guard opened.matches(observation) else { throw CacheRetentionError.sourceChanged }
        let metadata = try PaginatedHistoryBoundary.metadata(file: file, handle: reader)
        var state = CacheRetentionCheckpoint(generation: UUID().uuidString, parser: .init(metadata: metadata))
        var hasher = SHA256()
        var lastYield = ProcessInfo.processInfo.systemUptime
        if let cached, cached.parserRevision == CacheRetentionParser.revision {
            var remaining = cached.offset
            while remaining > 0 {
                try Task.checkCancellation()
                let data = try reader.read(upToCount: Int(min(remaining, 256 * 1024))) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data); remaining -= UInt64(data.count)
                if ProcessInfo.processInfo.systemUptime - lastYield > 0.05 { await Task.yield(); lastYield = ProcessInfo.processInfo.systemUptime }
            }
            let prefixHasher = hasher
            let digest = prefixHasher.finalize().map { String(format: "%02x", $0) }.joined()
            if remaining == 0, digest == cached.prefixDigest {
                state = cached
                state.parser.excludedSubagent = state.parser.explicitSubagent || knownSubagents.contains(where: { CacheRetentionIdentity.hash($0) == state.parser.sessionKey })
            } else {
                try reader.seek(toOffset: 0); hasher = SHA256()
            }
        }
        var buffer = Data()
        var completedLines = 0
        var scanOffset = 0
        while true {
            try Task.checkCancellation()
            let chunk = try reader.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            var consumed = 0
            while let newline = Self.newlineOffset(in: buffer, from: scanOffset) {
                let bytes = Data(buffer[(buffer.startIndex + consumed)..<(buffer.startIndex + newline)])
                autoreleasepool { state.parser.consume(bytes, knownSubagents: knownSubagents) }
                let end = newline + 1
                hasher.update(data: buffer[(buffer.startIndex + consumed)..<(buffer.startIndex + end)])
                state.offset += UInt64(end - consumed)
                consumed = end; scanOffset = end; completedLines += 1
                if state.parser.excludedSubagent { break }
                if completedLines % 256 == 0, ProcessInfo.processInfo.systemUptime - lastYield > 0.05 {
                    await Task.yield(); lastYield = ProcessInfo.processInfo.systemUptime
                }
            }
            // Every byte has now been searched once. Retain only a partial
            // line and resume scanning at its old end on the next chunk.
            scanOffset = buffer.count - consumed
            if consumed > 0 { buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + consumed)) }
            if state.parser.excludedSubagent { break }
            if buffer.count > 32 * 1024 * 1024 { throw CacheRetentionError.oversizedLine }
        }
        let after = try SourceFileObservation.readPhysical(handle: reader.physicalHandle)
        let named = try SourceFileObservation.readPreferredPhysical(at: file)
        guard opened.matches(after), opened.matches(named.observation) else { throw CacheRetentionError.sourceChanged }
        // Partial tail is deliberately not part of the committed prefix.
        state.prefixDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return state
    }
}
