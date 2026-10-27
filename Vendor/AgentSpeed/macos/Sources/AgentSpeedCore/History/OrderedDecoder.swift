import Foundation

/// Reads and decodes whole transcripts on worker threads while one consumer takes them strictly in order (startup
/// order decides key ownership). Workers never run more than a bounded number of files or bytes ahead.
///
/// `@unchecked Sendable`: all mutable state is guarded by `condition`.
final class OrderedDecoder: @unchecked Sendable {
    struct Job: Sendable {
        var path: String
        var family: TranscriptFamily
        var size: Int64

        /// Compressed sessions decode to several times their size; the window counts that. A database's size is its
        /// `.db` plus `-wal`.
        var weight: Int64 { TranscriptReader.isCompressedStream(path) ? size &* 8 : size }
    }

    struct Output: Sendable {
        var lines: DecodedLines
        var read: FileTailer.ReadResult
    }

    private let jobs: [Job]
    private let maxFilesAhead: Int
    private let maxBytesAhead: Int64
    private let condition = NSCondition()
    private var nextToClaim = 0
    private var nextToConsume = 0
    private var bytesAhead: Int64 = 0
    private var results: [Int: Output] = [:]
    private var cancelled = false
    private var runningWorkers = 0

    init(jobs: [Job], maxFilesAhead: Int = 256, maxBytesAhead: Int64 = 256 << 20) {
        self.jobs = jobs
        self.maxFilesAhead = max(1, maxFilesAhead)
        self.maxBytesAhead = max(1, maxBytesAhead)
    }

    func start(workers: Int, qos: QualityOfService = .utility) {
        let count = max(1, min(workers, jobs.count))
        condition.lock()
        runningWorkers = count
        condition.unlock()
        for index in 0..<count {
            let thread = Thread { [self] in work() }
            thread.name = "app.agentspeed.history.decode.\(index)"
            thread.qualityOfService = qos
            thread.start()
        }
    }

    /// The next job's output, waiting for it if needed. Nil when every job was consumed or after `cancel()`.
    func next() -> Output? {
        condition.lock()
        defer { condition.unlock() }
        guard nextToConsume < jobs.count else { return nil }
        while results[nextToConsume] == nil, !cancelled {
            condition.wait()
        }
        guard !cancelled, let output = results.removeValue(forKey: nextToConsume) else { return nil }
        bytesAhead -= jobs[nextToConsume].weight
        nextToConsume += 1
        condition.broadcast()
        return output
    }

    /// Stops the workers after their current file and wakes the consumer.
    func cancel() {
        condition.lock()
        cancelled = true
        results.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks until every worker thread has returned.
    func waitForWorkers() {
        condition.lock()
        while runningWorkers > 0 { condition.wait() }
        condition.unlock()
    }

    private func work() {
        defer {
            condition.lock()
            runningWorkers -= 1
            condition.broadcast()
            condition.unlock()
        }
        while let index = claim() {
            let job = jobs[index]
            var reader = TranscriptReader(path: job.path, start: .beginning)
            let (lines, read) = TranscriptDecoder.decode(job.family, reader: &reader)
            condition.lock()
            if !cancelled { results[index] = Output(lines: lines, read: read) }
            condition.broadcast()
            condition.unlock()
        }
    }

    private func claim() -> Int? {
        condition.lock()
        defer { condition.unlock() }
        while !cancelled, nextToClaim < jobs.count {
            let ahead = nextToClaim - nextToConsume
            let size = jobs[nextToClaim].weight
            // The consumer's next file is always admitted, however large.
            if ahead == 0 || (ahead < maxFilesAhead && bytesAhead + size <= maxBytesAhead) {
                let index = nextToClaim
                nextToClaim += 1
                bytesAhead += size
                return index
            }
            condition.wait()
        }
        return nil
    }
}
