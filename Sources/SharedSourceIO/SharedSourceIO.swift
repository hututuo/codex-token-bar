import Darwin
import Foundation

/// One bounded physical-read coordinator. Consumers keep their own cursors and
/// parser state; file/ledger checkpoints are never advanced by this cache.
/// Generation changes invalidate the complete file entry. Verification probes
/// deliberately bypass caching, and never prove bytes by reading their cache.
public final class SharedSourceIO: @unchecked Sendable {
    public static let shared = SharedSourceIO()
    public struct Statistics: Sendable {
        public let physicalReads: UInt64, cacheHits: UInt64
        public let cachedBytes: Int, owners: Int
    }
    private struct Identity: Hashable { let device: Int32; let inode: UInt64 }
    private struct Stamp: Equatable {
        let identity: Identity
        let size: Int64, modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
    }
    private struct PageKey: Hashable { let identity: Identity; let index: Int64 }
    private struct Page { let bytes: Data; var touched: UInt64 }
    private struct Owner { let stamp: Stamp; var touched: UInt64 }
    private let lock = NSLock()
    private var pages: [PageKey:Page] = [:], owners: [Identity:Owner] = [:]
    private var bytes = 0, clock: UInt64 = 0, reads: UInt64 = 0, hits: UInt64 = 0
    private let limit: Int, ownerLimit: Int
    private static let pageBytes = 64 * 1024, maxRead = 4 * 1024 * 1024

    public init(maxCacheBytes: Int = 64 * 1024 * 1024, maxOwners: Int = 256) {
        limit = max(0,maxCacheBytes); ownerLimit = max(1,maxOwners)
    }
    public var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        return .init(physicalReads: reads, cacheHits: hits, cachedBytes: bytes, owners: owners.count)
    }
    /// Validation must re-read physical bytes, even when parsing is cached.
    public func withUncachedReads<T>(_ body: () throws -> T) rethrows -> T {
        let key = "TokenBar.SharedSourceIO.uncached"
        let previous = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = true
        defer { Thread.current.threadDictionary[key] = previous }
        return try body()
    }
    public func read(descriptor: Int32, offset: Int64, count: Int, probe: Bool = false) throws -> Data {
        let probe = probe || (Thread.current.threadDictionary["TokenBar.SharedSourceIO.uncached"] as? Bool == true)
        guard offset >= 0, count >= 0 else { throw POSIXError(.EINVAL) }
        guard count > 0 else { return Data() }
        let first = try Self.stamp(descriptor)
        lock.lock(); defer { lock.unlock() }
        let before = try Self.stamp(descriptor)
        guard before == first else { invalidate(first.identity); throw POSIXError(.EAGAIN) }
        clock &+= 1
        if owners[before.identity]?.stamp != before { invalidate(before.identity) }
        owners[before.identity] = .init(stamp:before,touched:clock)
        while owners.count > ownerLimit, let oldest = owners.min(by: { $0.value.touched < $1.value.touched })?.key { invalidate(oldest) }
        guard offset < before.size else { return Data() }
        let end = offset + min(Int64(min(count,Self.maxRead)),before.size-offset)
        var output = Data()
        output.reserveCapacity(Int(end-offset))
        do {
            if probe {
                output = try rawRead(descriptor,offset:offset,count:Int(end-offset))
            } else {
                var position = offset
                while position < end {
                    let index = position / Int64(Self.pageBytes)
                    let key = PageKey(identity:before.identity,index:index)
                    let page: Data
                    clock &+= 1
                    if var cached = pages[key] {
                        hits &+= 1; cached.touched = clock; pages[key] = cached; page = cached.bytes
                    } else {
                        let start = index * Int64(Self.pageBytes)
                        page = try rawRead(descriptor,offset:start,count:Int(min(Int64(Self.pageBytes),before.size-start)))
                        if page.count <= limit {
                            pages[key] = .init(bytes:page,touched:clock); bytes += page.count
                            while bytes > limit, let oldest = pages.min(by: { $0.value.touched < $1.value.touched })?.key {
                                if let removed = pages.removeValue(forKey:oldest) { bytes -= removed.bytes.count }
                            }
                        }
                    }
                    let start = Int(position-index*Int64(Self.pageBytes))
                    let length = min(page.count-start,Int(end-position))
                    guard length > 0 else { throw POSIXError(.EAGAIN) }
                    output.append(page[start..<(start+length)]); position += Int64(length)
                }
            }
            guard try Self.stamp(descriptor) == before else { throw POSIXError(.EAGAIN) }
            return output
        } catch { invalidate(before.identity); throw error }
    }
    /// POSIX-compatible entry point for upstream tailers. No parser changes.
    public func pread(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, offset: Int64, probe: Bool = false) -> Int {
        do {
            let data = try read(descriptor:descriptor,offset:offset,count:buffer.count,probe:probe)
            data.copyBytes(to:buffer.bindMemory(to:UInt8.self)); return data.count
        } catch let error as POSIXError { errno = error.code.rawValue; return -1 }
        catch { errno = EIO; return -1 }
    }
    private func rawRead(_ descriptor: Int32, offset: Int64, count: Int) throws -> Data {
        var result = Data(count:count), read = 0
        try result.withUnsafeMutableBytes { buffer in
            while read < count {
                let n = Darwin.pread(descriptor,buffer.baseAddress!.advanced(by:read),count-read,off_t(offset+Int64(read)))
                if n < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
                guard n > 0 else { throw POSIXError(.EAGAIN) }
                reads &+= 1; read += n
            }
        }
        return result
    }
    private func invalidate(_ identity: Identity) {
        for key in pages.keys.filter({ $0.identity == identity }) {
            if let removed = pages.removeValue(forKey:key) { bytes -= removed.bytes.count }
        }
        owners.removeValue(forKey:identity)
    }
    private static func stamp(_ descriptor: Int32) throws -> Stamp {
        var info = Darwin.stat()
        guard fstat(descriptor,&info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw POSIXError(.EINVAL) }
        return .init(identity:.init(device:info.st_dev,inode:info.st_ino),size:info.st_size,
            modifiedSeconds:info.st_mtimespec.tv_sec,modifiedNanos:info.st_mtimespec.tv_nsec,
            changedSeconds:info.st_ctimespec.tv_sec,changedNanos:info.st_ctimespec.tv_nsec)
    }
}
