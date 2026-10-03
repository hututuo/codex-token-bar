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

    static func isRollout(_ file: URL) -> Bool {
        file.pathExtension == "jsonl" || file.lastPathComponent.hasSuffix(".jsonl.zst")
    }
    static func logicalURL(_ file: URL) -> URL {
        file.lastPathComponent.hasSuffix(".jsonl.zst") ? file.deletingPathExtension() : file
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
    private static func openPreferred(_ file: URL) throws -> (URL, FileHandle) {
        var lastError: Error = failure("普通/压缩来源正在转换，请重试", file: file)
        for _ in 0..<3 {
            do {
                let physical = try physicalURL(for: file)
                let handle = try FileHandle(forReadingFrom: physical)
                if physical.lastPathComponent.hasSuffix(".jsonl.zst"),
                   FileManager.default.fileExists(atPath: logicalURL(file).path) {
                    try? handle.close()
                    continue
                }
                return (physical, handle)
            } catch {
                lastError = error
                let value = error as NSError
                guard (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT))
                    || (value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoSuchFileError)
                else { throw error }
            }
        }
        throw lastError
    }
    init(forReadingFrom file: URL) throws {
        let opened = try Self.openPreferred(file)
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
        position = next
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
            guard descriptor & 0x18 == 0 else { throw failure("不支持的zstd保留位") }
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
