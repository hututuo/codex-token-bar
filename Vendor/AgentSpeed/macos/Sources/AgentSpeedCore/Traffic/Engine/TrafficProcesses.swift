import Foundation

/// A process identity (METRICS 10.3): pid and start time in microseconds since 1970.
struct ProcessIdentity: Hashable, Sendable, Comparable {
    var pid: Int32
    var startUs: Int64

    static func < (lhs: ProcessIdentity, rhs: ProcessIdentity) -> Bool {
        (lhs.startUs, lhs.pid) < (rhs.startUs, rhs.pid)
    }
}

/// One row of a process-table listing: the cheap part read for every process on every refresh.
struct ProcessEntry: Equatable, Sendable {
    var pid: Int32
    var ppid: Int32
    var startUs: Int64

    var identity: ProcessIdentity { ProcessIdentity(pid: pid, startUs: startUs) }
}

/// Reads the expensive details of a process on demand (METRICS 10.5, 10.6). The table asks for the path once per
/// identity, for arguments only when a rule needs them, and attribution asks for the working directory and open files.
protocol ProcessInspector: AnyObject {
    func executablePath(of entry: ProcessEntry) -> String?
    func arguments(of entry: ProcessEntry) -> [String]?
    /// macOS: `CFBundleIdentifier` of the app whose `Contents/MacOS` holds `executable`; nil outside an app bundle.
    func bundleIdentifier(of entry: ProcessEntry, executable: String) -> String?
    func workingDirectory(of entry: ProcessEntry) -> String?
    /// Open file paths; implementations cache them (macOS: refreshed every 10 s).
    func openFiles(of entry: ProcessEntry, nowMs: Int64) -> [String]
}

/// A process's role in a source (METRICS 10.5).
enum TrafficRole: String, Sendable {
    /// A root agent process.
    case agent
    /// Part of an agent process (a wrapper's native child, a relaunch): counted as the root's own traffic.
    case own = "self"
    /// A descendant that is not an agent process.
    case tool
}

/// The sticky classification of one process identity.
struct ProcessClass: Equatable, Sendable {
    var source: SourceKind
    var role: TrafficRole
    var root: ProcessIdentity

    var isAgentMember: Bool { role != .tool }
}
