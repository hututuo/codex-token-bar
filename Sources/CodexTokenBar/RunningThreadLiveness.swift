import Darwin
import Foundation

/// Kernel handle observations only: no app-server RPC, lock acquisition,
/// transcript modification or subprocess. A loaded idle thread is excluded by
/// the scanner's terminal lifecycle before this evidence is consulted.
enum RunningThreadLiveness {
    struct FileIdentity: Hashable {
        let device: UInt32
        let inode: UInt64
    }

    struct Snapshot {
        let files: Set<FileIdentity>

        func contains(_ url: URL) throws -> Bool {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw failure() }
            guard info.st_mode & S_IFMT == S_IFREG else { return false }
            return files.contains(FileIdentity(device: UInt32(bitPattern: info.st_dev), inode: info.st_ino))
        }
    }

    static func snapshot() throws -> Snapshot {
        var capacity = 1_024
        while capacity <= 65_536 {
            var pids = [Int32](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            guard count >= 0 else { throw failure() }
            if Int(count) >= capacity { capacity *= 2; continue }
            var files = Set<FileIdentity>()
            for pid in pids.prefix(Int(count)) where pid > 0 && pid != getpid() {
                var path = [CChar](repeating: 0, count: 4_096)
                guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
                let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard URL(fileURLWithPath: executable, isDirectory: false).lastPathComponent.lowercased() == "codex" else { continue }
                files.formUnion(try writeHandles(processID: pid))
            }
            return Snapshot(files: files)
        }
        throw failure()
    }

    /// Internal test seam also verifies that a read-only FD or writer-lock FD
    /// cannot stand in for a write handle to the specific rollout inode.
    static func writeHandles(processID: Int32) throws -> Set<FileIdentity> {
        var capacity = 256
        while capacity <= 65_536 {
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let bytes = descriptors.withUnsafeMutableBytes {
                proc_pidinfo(processID, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            guard bytes > 0 else {
                if errno == ESRCH { return [] }
                throw failure()
            }
            let count = Int(bytes) / MemoryLayout<proc_fdinfo>.stride
            if count >= capacity { capacity *= 2; continue }
            var files = Set<FileIdentity>()
            for descriptor in descriptors.prefix(count) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
                let read = proc_pidfdinfo(processID, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size)
                guard read == size else {
                    // FDs can close between enumeration and inspection.
                    if errno == EBADF || errno == ESRCH || errno == ENOENT { continue }
                    throw failure()
                }
                // Kernel FWRITE is bit 1 (unlike userspace O_WRONLY).
                guard info.pfi.fi_openflags & 2 != 0 else { continue }
                files.insert(FileIdentity(device: info.pvip.vip_vi.vi_stat.vst_dev,
                    inode: info.pvip.vip_vi.vi_stat.vst_ino))
            }
            return files
        }
        throw failure()
    }

    private static func failure() -> NSError {
        NSError(domain: "CodexTokenBar.RunningWriter", code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "无法确认 Codex 会话的当前写入句柄"])
    }
}
