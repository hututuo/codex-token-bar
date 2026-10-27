import Foundation

/// The app's table of the current user's processes with their sticky attribution (METRICS 10.5): the path is read
/// once per identity, arguments only when a rule needs them; a process is classified when first seen and keeps its
/// class for its lifetime; an exited process stays for `exitedRetentionMs` so late counter rows still match.
final class ProcessTable {
    static let exitedRetentionMs: Int64 = 10_000

    struct Record {
        var entry: ProcessEntry
        var executable: String
        var arguments: [String]??
        var workingDirectory: String??
        var processClass: ProcessClass?
        var isClassified = false
        /// When the listing stopped containing it.
        var exitedMs: Int64?

        var alive: Bool { exitedMs == nil }
    }

    let rules: AgentProcessRules
    private let exitedRetentionMs: Int64
    private(set) var records: [ProcessIdentity: Record] = [:]
    private var alive: Set<ProcessIdentity> = []
    private var exited: [ProcessIdentity] = []
    /// The newest identity per pid (alive first), for counter rows that carry only a pid (macOS nettop).
    private var byPid: [Int32: ProcessIdentity] = [:]
    /// Agent and own members of each root.
    private(set) var members: [ProcessIdentity: Set<ProcessIdentity>] = [:]

    init(platform: TrafficPlatform, exitedRetentionMs: Int64 = ProcessTable.exitedRetentionMs) {
        rules = AgentProcessRules(platform: platform)
        self.exitedRetentionMs = exitedRetentionMs
    }

    var aliveCount: Int { alive.count }

    /// Replaces the listing; new identities are read and classified (parents first). Work is proportional to the
    /// changes, apart from one pass over the listing.
    func refresh(_ entries: [ProcessEntry], inspector: ProcessInspector, nowMs: Int64) {
        var present = Set<ProcessIdentity>(minimumCapacity: entries.count)
        var fresh: [ProcessEntry] = []
        for entry in entries {
            let identity = entry.identity
            present.insert(identity)
            guard !alive.contains(identity) else { continue }
            if records[identity] != nil {
                // Missing from one listing only (a failed read): alive again.
                records[identity]?.exitedMs = nil
                byPid[entry.pid] = identity
            } else {
                fresh.append(entry)
            }
        }
        for identity in alive where !present.contains(identity) {
            records[identity]?.exitedMs = nowMs
            exited.append(identity)
        }
        alive = present
        if !fresh.isEmpty {
            var current: [Int32: ProcessEntry] = [:]
            current.reserveCapacity(entries.count)
            for entry in entries { current[entry.pid] = entry }
            for entry in fresh {
                records[entry.identity] = Record(
                    entry: entry, executable: inspector.executablePath(of: entry) ?? "", arguments: nil,
                    workingDirectory: nil, processClass: nil)
                byPid[entry.pid] = entry.identity
            }
            fresh.sort { $0.identity < $1.identity }
            for entry in fresh {
                classify(entry, current: current, inspector: inspector)
            }
        }
        prune(nowMs: nowMs)
    }

    func record(_ identity: ProcessIdentity) -> Record? { records[identity] }

    func processClass(of identity: ProcessIdentity) -> ProcessClass? { records[identity]?.processClass }

    /// The identity a pid-only counter row refers to: the live process with that pid, else a recently exited one.
    func identity(forPid pid: Int32) -> ProcessIdentity? { byPid[pid] }

    /// Some agent process (alive, or exited within the retention) is in the table (METRICS 10.10).
    var hasAgentProcess: Bool { !members.isEmpty }

    /// The root process's working directory, read once per process.
    func workingDirectory(of identity: ProcessIdentity, inspector: ProcessInspector) -> String? {
        guard let record = records[identity] else { return nil }
        if let known = record.workingDirectory { return known }
        let directory = record.alive ? inspector.workingDirectory(of: record.entry) : nil
        records[identity]?.workingDirectory = .some(directory)
        return directory
    }

    // MARK: - Classification

    private func parent(of entry: ProcessEntry, current: [Int32: ProcessEntry]) -> ProcessEntry? {
        guard let parent = current[entry.ppid], parent.pid != entry.pid, parent.startUs <= entry.startUs else { return nil }
        return parent
    }

    private func arguments(of identity: ProcessIdentity, inspector: ProcessInspector) -> [String]? {
        guard let record = records[identity] else { return nil }
        if let known = record.arguments { return known }
        let arguments = inspector.arguments(of: record.entry)
        records[identity]?.arguments = .some(arguments)
        return arguments
    }

    private func classify(_ entry: ProcessEntry, current: [Int32: ProcessEntry], inspector: ProcessInspector) {
        let identity = entry.identity
        guard let record = records[identity], !record.isClassified else { return }
        records[identity]?.isClassified = true
        var ancestors: [ProcessEntry] = []
        var seen: Set<ProcessIdentity> = [identity]
        var cursor = parent(of: entry, current: current)
        while let ancestor = cursor, !seen.contains(ancestor.identity) {
            seen.insert(ancestor.identity)
            ancestors.append(ancestor)
            cursor = parent(of: ancestor, current: current)
        }
        // Ancestors first seen in the same refresh are classified before their descendants.
        for ancestor in ancestors.reversed() where records[ancestor.identity]?.isClassified == false {
            classify(ancestor, current: current, inspector: inspector)
        }
        let nearest = ancestors.lazy.compactMap { self.records[$0.identity]?.processClass }.first { $0.isAgentMember }
        let executable = record.executable
        let ancestorExecutables = ancestors.map { records[$0.identity]?.executable ?? "" }
        let bundle = { inspector.bundleIdentifier(of: entry, executable: executable) }
        let source = rules.source(
            executable: executable,
            arguments: {
                rules.needsArguments(executable: executable, bundleIdentifier: bundle)
                    ? arguments(of: identity, inspector: inspector) : nil
            },
            bundleIdentifier: bundle,
            ancestorExecutables: ancestorExecutables)
        let processClass: ProcessClass?
        if let source, nearest?.source != source {
            processClass = ProcessClass(source: source, role: .agent, root: identity)
        } else if let source, let nearest {
            processClass = ProcessClass(source: source, role: .own, root: nearest.root)
        } else if let nearest {
            processClass = ProcessClass(source: nearest.source, role: .tool, root: nearest.root)
        } else {
            processClass = nil
        }
        records[identity]?.processClass = processClass
        if let processClass, processClass.isAgentMember {
            members[processClass.root, default: []].insert(identity)
        }
    }

    // MARK: - Housekeeping

    private func prune(nowMs: Int64) {
        while let first = exited.first, records[first]?.exitedMs == nil { exited.removeFirst() }
        guard let first = exited.first, let exitedMs = records[first]?.exitedMs, nowMs - exitedMs > exitedRetentionMs
        else { return }
        var kept: [ProcessIdentity] = []
        for identity in exited {
            guard let record = records[identity], let exitedMs = record.exitedMs else { continue }
            guard nowMs - exitedMs > exitedRetentionMs else {
                kept.append(identity)
                continue
            }
            records[identity] = nil
            if byPid[identity.pid] == identity { byPid[identity.pid] = nil }
            if let processClass = record.processClass, processClass.isAgentMember {
                members[processClass.root]?.remove(identity)
                if members[processClass.root]?.isEmpty == true { members[processClass.root] = nil }
            }
        }
        exited = kept
    }
}
