import Foundation

/// Follows one transcript file: plain JSONL (METRICS 5), a zstd frame stream for `.zstd` files (METRICS 5.1), a
/// compressed Codex session re-read from the start on every change (`.jsonl.zst`, METRICS 5.3), a whole document
/// re-read on every change for Gemini CLI legacy `.json` files (METRICS 4.6), or an Antigravity conversation
/// database (METRICS 5.4).
struct TranscriptReader: Sendable {
    private var plain: FileTailer?
    private var frames: ZstdFrameTailer?
    private var compressed: CompressedStreamReader?
    private var document: DocumentReader?
    private var database: AntigravityReader?
    /// omp: the first read delivers the file's session header before the lines at its start offset (METRICS 4.7).
    private var headerPending: Bool

    /// `readsHeaderFirst`: an omp file that starts being read past its beginning.
    init(
        path: String,
        start: FileTailer.Start = .beginning,
        maxLineBytes: Int = FileTailer.defaultMaxLineBytes,
        readsHeaderFirst: Bool = false
    ) {
        headerPending = readsHeaderFirst && start != .beginning
        if Self.isDatabase(path) {
            database = AntigravityReader(path: path, start: start)
        } else if Self.isFrameStream(path) {
            frames = ZstdFrameTailer(path: path, start: start, maxLineBytes: maxLineBytes)
        } else if Self.isCompressedStream(path) {
            compressed = CompressedStreamReader(path: path, start: start, maxLineBytes: maxLineBytes)
        } else if Self.isDocument(path) {
            document = DocumentReader(path: path, start: start)
        } else {
            plain = FileTailer(path: path, start: start, maxLineBytes: maxLineBytes)
        }
    }

    static func isFrameStream(_ path: String) -> Bool {
        path.hasSuffix(".zstd")
    }

    static func isCompressedStream(_ path: String) -> Bool {
        path.hasSuffix(".jsonl.zst")
    }

    static func isDocument(_ path: String) -> Bool {
        path.hasSuffix(".json")
    }

    static func isDatabase(_ path: String) -> Bool {
        path.hasSuffix(".db")
    }

    var isDocument: Bool { document != nil }

    /// The next read decodes the file whole: a compressed session, a legacy Gemini document, or an Antigravity
    /// database that was not read at startup and is read completely on its first change.
    var readsWholeFile: Bool { compressed != nil || document != nil || database?.defersFirstRead == true }

    /// An Antigravity database whose `mode=ro` connection is open.
    var hasOpenConnection: Bool { database?.hasOpenConnection == true }

    mutating func closeConnection() {
        database?.closeConnection()
    }

    /// Reads an Antigravity conversation database (METRICS 5.4); nil batch when nothing could be read.
    mutating func readDatabase() -> (AntigravityBatch?, FileTailer.ReadResult) {
        guard database != nil else { return (nil, FileTailer.ReadResult(failed: true)) }
        return database!.read()
    }

    /// Reads every complete line appended since the last call (a document is delivered whole, as one unit).
    /// `onMalformed` reports frames that failed to decode.
    mutating func read(
        onReset: () -> Void = {},
        onMalformed: () -> Void = {},
        onLine: (UnsafeRawBufferPointer) -> Void
    ) -> FileTailer.ReadResult {
        if database != nil {
            // Databases are read in batches (`readDatabase`), never as lines.
            return FileTailer.ReadResult(failed: true)
        }
        if frames != nil {
            return frames!.read(onReset: onReset, onMalformed: onMalformed, onLine: onLine)
        }
        if compressed != nil {
            return compressed!.read(onReset: onReset, onMalformed: onMalformed, onLine: onLine)
        }
        if document != nil {
            return document!.read(onReset: onReset, onDocument: onLine)
        }
        if headerPending {
            headerPending = false
            let path = plain!.path
            if let header = OmpHeader.headerLine(atPath: path, maxLineBytes: plain!.maxLineBytes) {
                header.withUnsafeBytes { onLine($0) }
            }
        }
        return plain!.read(onReset: onReset, onLine: onLine)
    }
}

/// Reads a whole-document file again whenever its size, modification time or identity changes. Read-only, never
/// follows symlinks; documents over `maxBytes` are not read.
struct DocumentReader: Sendable {
    static let defaultMaxBytes: Int64 = 64 << 20

    let path: String
    let maxBytes: Int64
    private var start: FileTailer.Start?
    private var lastStat: FileStat?

    init(path: String, start: FileTailer.Start = .beginning, maxBytes: Int64 = DocumentReader.defaultMaxBytes) {
        self.path = path
        self.start = start
        self.maxBytes = maxBytes
    }

    mutating func read(onReset: () -> Void, onDocument: (UnsafeRawBufferPointer) -> Void) -> FileTailer.ReadResult {
        var result = FileTailer.ReadResult()
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            result.failed = true
            return result
        }
        defer { Darwin.close(descriptor) }
        guard let stat = FileStat.fstat(descriptor), stat.isRegularFile else {
            result.failed = true
            return result
        }
        result.stat = stat
        if let pending = start {
            start = nil
            if case .beginning = pending {} else {
                // Not read at startup: only a later change reads it.
                lastStat = stat
                return result
            }
        }
        if let lastStat, lastStat.size == stat.size, lastStat.modifiedNs == stat.modifiedNs, lastStat.identity == stat.identity {
            return result
        }
        if let lastStat, lastStat.identity != stat.identity {
            result.didReset = true
            onReset()
        }
        lastStat = stat
        guard stat.size <= maxBytes else {
            result.oversized = true
            return result
        }
        let size = Int(stat.size)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(1, size), alignment: 16)
        defer { buffer.deallocate() }
        var filled = 0
        while filled < size {
            let count = Darwin.pread(descriptor, buffer.baseAddress! + filled, size - filled, off_t(filled))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            filled += count
        }
        result.bytesRead = filled
        onDocument(UnsafeRawBufferPointer(rebasing: buffer[0..<filled]))
        return result
    }
}
