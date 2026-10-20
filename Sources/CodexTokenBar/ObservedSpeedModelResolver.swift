import Foundation

/// Incremental metadata-only lookup. It never infers a model from a neighbouring turn.
actor ObservedSpeedModelResolver {
    private struct Entry {
        var identity: String
        var offset: UInt64 = 0
        var carry = Data()
        var droppingLine = false
        var models: [String: String] = [:]
        var order: [String] = []
    }
    private var entries: [String: Entry] = [:]
    private let initialScanLimit: UInt64 = 32 * 1_024 * 1_024

    func resolve(home: URL, paths: [String: String], requested: [String: Set<String>]) -> [String: [String: String]] {
        let wanted = Set(requested.keys.sorted().prefix(8))
        var candidates: [String: Set<String>] = [:]
        for (thread, path) in paths where wanted.contains(thread) { candidates[thread, default: []].insert(path) }
        // A logical UUID can have several physical continuation/fork files. Inspect matching
        // filenames too, rather than assuming the thread table points at the newest writer.
        for folder in ["sessions", "archived_sessions"] {
            guard let files = FileManager.default.enumerator(at: home.appendingPathComponent(folder),
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let file as URL in files where file.pathExtension == "jsonl" {
                for thread in wanted where file.lastPathComponent.contains(thread) {
                    if candidates[thread, default: []].count < 8 { candidates[thread, default: []].insert(file.path) }
                }
            }
        }
        var result: [String: [String: String]] = [:]
        var conflicts: [String: Set<String>] = [:]
        var budget: UInt64 = 64 * 1_024 * 1_024
        var visited = Set<String>()
        let ordered = candidates.mapValues { paths in paths.sorted { left, right in
            let a = (try? FileManager.default.attributesOfItem(atPath: left)[.modificationDate] as? Date) ?? .distantPast
            let b = (try? FileManager.default.attributesOfItem(atPath: right)[.modificationDate] as? Date) ?? .distantPast
            return a == b ? left < right : a > b
        } }
        // Give each chat's newest writer a chance before scanning older continuations.
        for rank in 0..<8 {
            for thread in wanted.sorted() {
                guard let paths = ordered[thread], rank < paths.count else { continue }
                let path = paths[rank]
                guard visited.contains(path) || visited.count < 16 else { continue }
                visited.insert(path)
                let models = scan(path, budget: &budget)
                for turn in (requested[thread] ?? []).sorted().prefix(64) {
                    if let model = models[turn], conflicts[thread]?.contains(turn) != true {
                        if let previous = result[thread]?[turn], previous != model {
                            result[thread]?.removeValue(forKey: turn); conflicts[thread, default: []].insert(turn)
                        } else { result[thread, default: [:]][turn] = model }
                    }
                }
            }
        }
        if entries.count > 16 {
            let keep = Set(candidates.values.flatMap { $0 }.sorted().prefix(16))
            entries = entries.filter { keep.contains($0.key) }
        }
        return result
    }

    private func scan(_ path: String, budget: inout UInt64) -> [String: String] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return [:] }
        defer { try? handle.close() }
        let identity = "\(attrs[.systemNumber] ?? 0)-\(attrs[.systemFileNumber] ?? 0)"
        var entry = entries[path] ?? Entry(identity: identity)
        if entry.identity != identity || size < entry.offset { entry = Entry(identity: identity) }
        if entry.offset == 0, size > initialScanLimit {
            entry.offset = size - initialScanLimit; entry.droppingLine = true
        }
        guard (try? handle.seek(toOffset: entry.offset)) != nil else { return entry.models }
        var remaining = min(initialScanLimit, budget)
        while remaining > 0, let chunk = try? handle.read(upToCount: Int(min(65_536, remaining))), !chunk.isEmpty {
            entry.offset += UInt64(chunk.count); remaining -= UInt64(chunk.count); budget -= UInt64(chunk.count)
            entry.carry.append(chunk)
            while let newline = entry.carry.firstIndex(of: 10) {
                let line = entry.carry[..<newline]
                if !entry.droppingLine, line.range(of: Data("\"turn_context\"".utf8)) != nil,
                   let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   object["type"] as? String == "turn_context", let payload = object["payload"] as? [String: Any],
                   let turn = payload["turn_id"] as? String, !turn.isEmpty,
                   let model = payload["model"] as? String, !model.isEmpty, model != "unknown" {
                    if entry.models[turn] == nil { entry.order.append(turn) }
                    entry.models[turn] = model
                    while entry.order.count > 256 { entry.models.removeValue(forKey: entry.order.removeFirst()) }
                }
                entry.droppingLine = false
                entry.carry.removeSubrange(...newline)
            }
            // Tool payloads may be huge single lines. Skip without retaining their body.
            if entry.carry.count > 1_048_576 { entry.carry.removeAll(keepingCapacity: false); entry.droppingLine = true }
        }
        entries[path] = entry
        return entry.models
    }
}
