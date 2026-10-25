import Darwin
import Foundation

/// The current user's processes through libproc (METRICS 10.5, 10.6): the listing with parent and start time on every
/// refresh; path, arguments, working directory and open files on demand. Not thread-safe; one queue uses it.
final class ProcessReader: ProcessInspector {
    static let openFilesRefreshMs: Int64 = 10_000

    private let uid = getuid()
    private var pids: [Int32] = []
    private var argumentBuffer: [UInt8] = []
    private var openFiles: [ProcessIdentity: (readMs: Int64, paths: [String])] = [:]

    /// Every pid's parent and start time are read again this often; in between only new pids are read, since a pid is
    /// not reused within seconds (the kernel hands them out in sequence).
    static let fullReadIntervalMs: Int64 = 10_000

    private var known: [Int32: ProcessEntry] = [:]
    private var fullReadMs: Int64?
    /// Bundle ids by app path, read once per app (METRICS 10.5).
    private var bundleIds: [String: String?] = [:]
    static let maxBundleIds = 512
    static let maxInfoPlistBytes: Int64 = 1 << 20

    /// The current user's processes.
    func list(nowMs: Int64) -> [ProcessEntry] {
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard needed > 0 else { return [] }
        let capacity = Int(needed) / MemoryLayout<Int32>.size + 64
        if pids.count < capacity { pids = Array(repeating: 0, count: capacity) }
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_UID_ONLY), uid, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return [] }
        let full = fullReadMs.map { nowMs - $0 >= Self.fullReadIntervalMs } ?? true
        if full { fullReadMs = nowMs }
        let count = Int(bytes) / MemoryLayout<Int32>.size
        var entries: [ProcessEntry] = []
        entries.reserveCapacity(count)
        var listed: [Int32: ProcessEntry] = [:]
        listed.reserveCapacity(count)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0 else { continue }
            if !full, let entry = known[pid] {
                entries.append(entry)
                listed[pid] = entry
                continue
            }
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { continue }
            let entry = ProcessEntry(pid: pid, ppid: Int32(bitPattern: info.pbi_ppid), startUs: Self.startUs(info))
            entries.append(entry)
            listed[pid] = entry
        }
        known = listed
        return entries
    }

    private static func startUs(_ info: proc_bsdinfo) -> Int64 {
        Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec)
    }

    /// The pid still belongs to this identity.
    private func isSame(_ entry: ProcessEntry) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(entry.pid, PROC_PIDTBSDINFO, 0, &info, size) == size && Self.startUs(info) == entry.startUs
    }

    func executablePath(of entry: ProcessEntry) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(entry.pid, &path, UInt32(path.count))
        guard length > 0 else { return nil }
        return String(decoding: path.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `sysctl(KERN_PROCARGS2)`: argc, the executable path, padding, then argv.
    func arguments(of entry: ProcessEntry) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, entry.pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        if argumentBuffer.count < size { argumentBuffer = Array(repeating: 0, count: size) }
        let ok = argumentBuffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) == 0 }
        guard ok else { return nil }
        return argumentBuffer.withUnsafeBytes { Self.parseArguments(UnsafeRawBufferPointer(rebasing: $0[0..<size])) }
    }

    static func parseArguments(_ bytes: UnsafeRawBufferPointer) -> [String]? {
        guard bytes.count >= 4 else { return nil }
        let argc = Int(bytes.loadUnaligned(as: Int32.self))
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self))
            index += 1
        }
        return arguments
    }

    func bundleIdentifier(of entry: ProcessEntry, executable: String) -> String? {
        guard let app = Self.appBundle(containing: executable) else { return nil }
        if let known = bundleIds[app] { return known }
        if bundleIds.count >= Self.maxBundleIds { bundleIds.removeAll(keepingCapacity: true) }
        let identifier = Self.readBundleIdentifier(app: app)
        bundleIds[app] = .some(identifier)
        return identifier
    }

    /// `<app>.app` when the executable lies directly in its `Contents/MacOS`.
    static func appBundle(containing executable: String) -> String? {
        let macOS = (executable as NSString).deletingLastPathComponent
        guard (macOS as NSString).lastPathComponent == "MacOS" else { return nil }
        let contents = (macOS as NSString).deletingLastPathComponent
        guard (contents as NSString).lastPathComponent == "Contents" else { return nil }
        let app = (contents as NSString).deletingLastPathComponent
        return app.hasSuffix(".app") ? app : nil
    }

    private static func readBundleIdentifier(app: String) -> String? {
        let path = app + "/Contents/Info.plist"
        guard let stat = FileStat.stat(path), stat.isRegularFile, stat.size <= maxInfoPlistBytes,
              let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    func workingDirectory(of entry: ProcessEntry) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(entry.pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size, isSame(entry) else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { Self.cString($0) }
        return path.isEmpty ? nil : path
    }

    func openFiles(of entry: ProcessEntry, nowMs: Int64) -> [String] {
        let identity = entry.identity
        if let cached = openFiles[identity], nowMs - cached.readMs < Self.openFilesRefreshMs { return cached.paths }
        let paths = isSame(entry) ? readOpenFiles(entry.pid) : []
        openFiles[identity] = (nowMs, paths)
        if openFiles.count > 64 { openFiles = openFiles.filter { nowMs - $0.value.readMs < 60_000 } }
        return paths
    }

    private func readOpenFiles(_ pid: Int32) -> [String] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let bytes = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return [] }
        var paths: [String] = []
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in fds.prefix(Int(bytes) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { Self.cString($0) }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    private static func cString(_ bytes: UnsafeRawBufferPointer) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[0..<end]), as: UTF8.self)
    }
}
