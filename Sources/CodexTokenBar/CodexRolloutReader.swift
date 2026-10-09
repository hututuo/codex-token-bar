import CZstd
import Darwin
import Foundation

/// Offsets always address decoded JSONL bytes. A physical file is not a ledger ID.
protocol CodexReadHandle: AnyObject {
    var physicalHandle: FileHandle { get }
    func read(upToCount count: Int) throws -> Data?
    func readBytes(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
    func seek(toOffset offset: UInt64) throws
    func offset() throws -> UInt64
    func close() throws
    func logicalSize() throws -> UInt64
    func validateDecodedEnd(at size: UInt64) throws
}

/// Work performed by the rollout reader on the calling thread. These counters
/// are compiled as instrumentation in debug builds for focused regressions.
struct CodexRolloutReaderWorkCounters: Equatable {
    var open: UInt64 = 0
    var decoded_bytes: UInt64 = 0
    var structure_blocks: UInt64 = 0
}

#if DEBUG
private final class CodexRolloutReaderWorkCounterBox {
    var value = CodexRolloutReaderWorkCounters()
}
#endif

extension FileHandle: CodexReadHandle {
    var physicalHandle: FileHandle { self }
    func logicalSize() throws -> UInt64 { try SourceFileObservation.readPhysical(handle: self).size }
    func validateDecodedEnd(at size: UInt64) throws {}
    func readBytes(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        while true {
            let n = Darwin.read(fileDescriptor, buffer.baseAddress, buffer.count)
            if n >= 0 { return n }
            if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
    }
}

final class CodexRolloutReader: CodexReadHandle, @unchecked Sendable {
    struct Layout: Sendable {
        var logicalSize: UInt64?
        let singleFrame: Bool
        let declaredSize: Bool
    }
    private final class LayoutCache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: Layout] = [:]
        func get(_ key: String) -> Layout? {
            lock.lock(); defer { lock.unlock() }; return entries[key]
        }
        func put(_ layout: Layout, key: String) {
            lock.lock(); defer { lock.unlock() }
            if entries.count >= 32768 { entries.removeAll(keepingCapacity: true) }
            entries[key] = layout
        }
    }
    private static let cache = LayoutCache()
    private static let workCounterThreadKey = "CodexRolloutReader.workCounters"
    let physicalHandle: FileHandle
    let physicalURL: URL
    private(set) var layout: Layout
    var isCompressed: Bool { context != nil }
    var supportsMetadataReuse: Bool { isCompressed && layout.singleFrame && layout.declaredSize }
    private var context: OpaquePointer?
    private var input: [UInt8] = []
    private var inputCount = 0
    private var inputPosition = 0
    private var lastHint = 0
    private var position: UInt64 = 0
    private var closed = false
    private let cacheKey: String
    // At most 8 KiB from this pinned reader; never a conversation-body cache.
    private var probeHead = Data()
    private var probeTail = Data()
    private var probeTailEnd: UInt64 = 0

    func cachedProbeWindows(size: UInt64) throws -> (head: Data, tail: Data)? {
        guard isCompressed else { return nil }
        let observed = try SourceFileObservation.readPhysical(handle: physicalHandle)
        guard "\(physicalURL.path):\(observed.size):\(observed.modifiedAt):\(observed.physicalStamp)" == cacheKey else {
            probeHead.removeAll(); probeTail.removeAll()
            return nil
        }
        guard probeHead.count == Int(min(size, 4096)),
              size <= 4096 || (probeTailEnd == size && probeTail.count == 4096) else { return nil }
        return (probeHead, size > 4096 ? probeTail : Data())
    }

    private func retainProbeWindows(_ bytes: UnsafeRawBufferPointer, startingAt start: UInt64) {
        guard !bytes.isEmpty else { return }
        if start <= UInt64(probeHead.count), probeHead.count < 4096 {
            let skip = Int(UInt64(probeHead.count) - start)
            if skip < bytes.count {
                let count = min(bytes.count - skip, 4096 - probeHead.count)
                probeHead.append(contentsOf: bytes[skip..<(skip + count)])
            }
        }
        if start != probeTailEnd { probeTail.removeAll(keepingCapacity: true) }
        // Copy only the suffix, even if the decoder supplied a very large buffer.
        if bytes.count >= 4096 {
            probeTail = Data(bytes.suffix(4096))
        } else {
            let excess = max(0, probeTail.count + bytes.count - 4096)
            if excess > 0 { probeTail.removeFirst(excess) }
            probeTail.append(contentsOf: bytes)
        }
        probeTailEnd = start + UInt64(bytes.count)
    }

    static func isRollout(_ file: URL) -> Bool {
        file.pathExtension == "jsonl" || file.lastPathComponent.hasSuffix(".jsonl.zst")
    }

    /// Reset reader work counters for the current thread. Test helpers use a
    /// thread-local box so concurrent XCTest cases cannot affect each other.
    static func resetWorkCountersForCurrentThread() {
        #if DEBUG
        workCounterBox().value = CodexRolloutReaderWorkCounters()
        #endif
    }

    /// Snapshot reader work counters for the current thread.
    static func workCountersForCurrentThread() -> CodexRolloutReaderWorkCounters {
        #if DEBUG
        return workCounterBox().value
        #else
        return CodexRolloutReaderWorkCounters()
        #endif
    }

    /// Count a physical open performed by a reader-layer observation helper.
    static func recordPhysicalOpenForCurrentThread() {
        #if DEBUG
        workCounterBox().value.open &+= 1
        #endif
    }

    #if DEBUG
    private static func workCounterBox() -> CodexRolloutReaderWorkCounterBox {
        let dictionary = Thread.current.threadDictionary
        if let existing = dictionary[workCounterThreadKey] as? CodexRolloutReaderWorkCounterBox {
            return existing
        }
        let box = CodexRolloutReaderWorkCounterBox()
        dictionary[workCounterThreadKey] = box
        return box
    }

    private static func recordDecodedBytes(_ count: UInt64) {
        workCounterBox().value.decoded_bytes &+= count
    }

    private static func recordStructureBlock() {
        workCounterBox().value.structure_blocks &+= 1
    }
    #else
    private static func recordDecodedBytes(_ count: UInt64) {}
    private static func recordStructureBlock() {}
    #endif
    static func logicalURL(_ file: URL) -> URL {
        file.lastPathComponent.hasSuffix(".jsonl.zst") ? file.deletingPathExtension() : file
    }
    /// Resolve the directory even when the logical JSONL leaf no longer exists.
    /// Keep the leaf itself: an unsafe plain entry must still be rejected, not
    /// followed to a different source or hidden behind a compressed twin.
    static func canonicalLogicalURL(_ file: URL) -> URL {
        let logical = logicalURL(file.standardizedFileURL)
        return logical.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(logical.lastPathComponent)
    }
    static func physicalURL(for file: URL) throws -> URL {
        let logical = logicalURL(file)
        var status = Darwin.stat()
        if lstat(logical.path, &status) == 0 { return logical }
        let error = errno
        guard error == ENOENT, logical.pathExtension == "jsonl" else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error), userInfo: [NSFilePathErrorKey: logical.path])
        }
        return URL(fileURLWithPath: logical.path + ".zst")
    }
    private static func openPreferred(_ file: URL, allowsCompressed: Bool) throws -> (URL, FileHandle) {
        var lastError: Error = failure("普通/压缩来源正在转换，请重试", file: file)
        for _ in 0..<3 {
            do {
                let physical = try physicalURL(for: file)
                guard allowsCompressed || !physical.lastPathComponent.hasSuffix(".jsonl.zst") else {
                    throw failure("可选原文读取已延期：来源为压缩历史", file: physical)
                }
                let handle = try FileHandle(forReadingFrom: physical)
                recordPhysicalOpenForCurrentThread()
                if physical.lastPathComponent.hasSuffix(".jsonl.zst") {
                    var status = Darwin.stat()
                    if lstat(logicalURL(file).path, &status) == 0 {
                        try? handle.close()
                        continue
                    }
                    if errno != ENOENT {
                        let code = errno
                        try? handle.close()
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                    }
                }
                return (physical, handle)
            } catch {
                lastError = error
                guard SourceFileObservation.isMissingFileError(error) else { throw error }
            }
        }
        throw lastError
    }
    init(forReadingFrom file: URL, allowsCompressed: Bool = true) throws {
        let opened = try Self.openPreferred(file, allowsCompressed: allowsCompressed)
        physicalURL = opened.0
        physicalHandle = opened.1
        let observed = try SourceFileObservation.readPhysical(handle: physicalHandle)
        cacheKey = "\(physicalURL.path):\(observed.size):\(observed.modifiedAt):\(observed.physicalStamp)"
        layout = Layout(logicalSize: observed.size, singleFrame: false, declaredSize: false)
        do {
            if physicalURL.lastPathComponent.hasSuffix(".jsonl.zst") {
                if let cached = Self.cache.get(cacheKey) { layout = cached }
                else {
                    do { layout = try Self.inspect(physicalHandle, physicalSize: observed.size) }
                    catch { throw Self.failure("zstd结构检查失败：\(error.localizedDescription)", file: physicalURL) }
                    guard try SourceFileObservation.readPhysical(handle: physicalHandle).matches(observed) else {
                        throw Self.failure("来源在压缩帧检查期间发生变化", file: physicalURL)
                    }
                    Self.cache.put(layout, key: cacheKey)
                }
                guard let ctx = ZSTD_createDStream() else { throw Self.failure("无法创建zstd解码器", file: physicalURL) }
                context = ctx
                input = [UInt8](repeating: 0, count: 128 * 1024)
                try resetDecoder()
            }
        } catch {
            if let context { ZSTD_freeDStream(context); self.context = nil }
            try? physicalHandle.close()
            throw error
        }
    }
    deinit { if let context { ZSTD_freeDStream(context) }; if !closed { try? physicalHandle.close() } }
    static func failure(_ message: String, file: URL) -> NSError {
        NSError(domain: "CodexRolloutReader", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(message)：\(file.path)", NSFilePathErrorKey: file.path])
    }
    private func checked(_ result: Int) throws -> Int {
        if ZSTD_isError(result) != 0 {
            throw Self.failure("zstd解码失败：\(String(cString: ZSTD_getErrorName(result)))", file: physicalURL)
        }
        return result
    }
    private func resetDecoder() throws {
        guard let context else { return }
        try physicalHandle.seek(toOffset: 0)
        _ = try checked(ZSTD_initDStream(context))
        _ = try checked(ZSTD_DCtx_setMaxWindowSize(context, 128 * 1024 * 1024))
        inputCount = 0; inputPosition = 0; lastHint = 0; position = 0
    }
    func close() throws {
        if closed { return }
        closed = true
        if let context { ZSTD_freeDStream(context); self.context = nil }
        try physicalHandle.close()
    }
    func offset() throws -> UInt64 { isCompressed ? position : try physicalHandle.offset() }
    func read(upToCount count: Int) throws -> Data? {
        guard count >= 0 else { throw Self.failure("无效读取长度", file: physicalURL) }
        var data = Data(count: count)
        let n = try data.withUnsafeMutableBytes { try readBytes(into: $0) }
        data.count = n
        return data
    }
    func readBytes(into output: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !closed else { throw Self.failure("来源读取器已关闭", file: physicalURL) }
        guard let context else { return try physicalHandle.readBytes(into: output) }
        guard !output.isEmpty else { return 0 }
        var out = ZSTD_outBuffer(dst: output.baseAddress, size: output.count, pos: 0)
        while out.pos < out.size {
            if Task.isCancelled { throw CancellationError() }
            if inputPosition == inputCount {
                inputCount = try input.withUnsafeMutableBytes { try physicalHandle.readBytes(into: $0) }
                inputPosition = 0
                if inputCount == 0 {
                    guard lastHint == 0 else { throw Self.failure("压缩来源截断，未到完整帧结尾", file: physicalURL) }
                    break
                }
            }
            let before = inputPosition
            let beforeOutput = out.pos
            lastHint = try input.withUnsafeBytes { bytes in
                var source = ZSTD_inBuffer(src: bytes.baseAddress, size: inputCount, pos: inputPosition)
                let result = ZSTD_decompressStream(context, &out, &source)
                inputPosition = source.pos
                return try checked(result)
            }
            if before == inputPosition && beforeOutput == out.pos {
                throw Self.failure("zstd解码未推进", file: physicalURL)
            }
        }
        let (next, overflow) = position.addingReportingOverflow(UInt64(out.pos))
        guard !overflow else { throw Self.failure("逻辑字节偏移溢出", file: physicalURL) }
        retainProbeWindows(UnsafeRawBufferPointer(rebasing: output[..<out.pos]), startingAt: position)
        position = next
        if out.pos > 0 { Self.recordDecodedBytes(UInt64(out.pos)) }
        return out.pos
    }
    func seek(toOffset target: UInt64) throws {
        guard isCompressed else { try physicalHandle.seek(toOffset: target); return }
        if target < position { try resetDecoder() }
        var discard = [UInt8](repeating: 0, count: 64 * 1024)
        while position < target {
            let wanted = Int(min(UInt64(discard.count), target - position))
            let n = try discard.withUnsafeMutableBytes { try readBytes(into: UnsafeMutableRawBufferPointer(rebasing: $0[..<wanted])) }
            guard n > 0 else { throw Self.failure("逻辑偏移超过解码来源结尾", file: physicalURL) }
        }
    }
    func logicalSize() throws -> UInt64 {
        if let size = layout.logicalSize { return size }
        // Unknown-size frames are streamed once, without a materialized file.
        let saved = position
        try resetDecoder()
        var discard = [UInt8](repeating: 0, count: 128 * 1024)
        while try discard.withUnsafeMutableBytes({ try readBytes(into: $0) }) > 0 {}
        let size = position
        let after = try SourceFileObservation.readPhysical(handle: physicalHandle)
        guard "\(physicalURL.path):\(after.size):\(after.modifiedAt):\(after.physicalStamp)" == cacheKey else {
            throw Self.failure("来源在逻辑长度核对期间发生变化", file: physicalURL)
        }
        layout.logicalSize = size
        Self.cache.put(layout, key: cacheKey)
        try seek(toOffset: saved)
        return size
    }
    func validateDecodedEnd(at size: UInt64) throws {
        guard isCompressed else { return }
        try seek(toOffset: size)
        guard try read(upToCount: 1)?.isEmpty == true else {
            throw Self.failure("实际解码长度与已声明长度不一致", file: physicalURL)
        }
    }
    private static func inspect(_ file: FileHandle, physicalSize: UInt64) throws -> Layout {
        func failure(_ message: String) -> NSError { NSError(domain: "CodexRolloutReader", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
        func number(_ count: Int) throws -> UInt64 {
            let data = try file.read(upToCount: count) ?? Data()
            guard data.count == count else { throw failure("压缩帧头或块头截断") }
            return data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        }
        func skip(_ count: UInt64) throws {
            let (end, overflow) = try file.offset().addingReportingOverflow(count)
            guard !overflow && end <= physicalSize else { throw failure("压缩帧内容截断或偏移溢出") }
            try file.seek(toOffset: end)
        }
        try file.seek(toOffset: 0)
        var total: UInt64? = 0
        var frames = 0
        var blocks = 0
        var skippable = false
        while try file.offset() < physicalSize {
            if Task.isCancelled { throw CancellationError() }
            let magic = try number(4)
            if (0x184d2a50...0x184d2a5f).contains(magic) {
                let size = try number(4); try skip(size); skippable = true; continue
            }
            guard magic == 0xfd2fb528 else { throw failure("无效zstd帧魔数或尾随内容") }
            let descriptor = try number(1)
            guard descriptor & 0x08 == 0 else { throw failure("不支持的zstd保留位") }
            let single = descriptor & 0x20 != 0
            if !single { try skip(1) }
            try skip([0, 1, 2, 4][Int(descriptor & 3)])
            let count = [single ? 1 : 0, 2, 4, 8][Int(descriptor >> 6)]
            let size: UInt64? = count == 0 ? nil : try number(count)
            if let old = total, let size {
                let (adjusted, overflow1) = size.addingReportingOverflow(descriptor >> 6 == 1 ? 256 : 0)
                let (sum, overflow2) = old.addingReportingOverflow(adjusted)
                guard !overflow1 && !overflow2 else { throw failure("zstd逻辑长度溢出") }
                total = sum
            } else { total = nil }
            while true {
                blocks += 1
                recordStructureBlock()
                guard blocks <= 1_000_000 else { throw failure("压缩帧结构检查超出工作预算") }
                let header = try number(3), kind = header >> 1 & 3, length = header >> 3
                guard kind != 3 && length <= 128 * 1024 else { throw failure("无效zstd块头") }
                try skip(kind == 1 ? 1 : length)
                if header & 1 != 0 { break }
            }
            if descriptor & 4 != 0 { try skip(4) }
            frames += 1
        }
        guard frames > 0 else { throw failure("没有zstd数据帧") }
        return Layout(logicalSize: total, singleFrame: frames == 1 && !skippable, declaredSize: total != nil)
    }
}
