import Darwin
import Foundation

/// Runs the nettop child on the traffic queue and keeps the newest complete sample (METRICS 10.3): a sample is complete
/// when the next header arrives or the output has been quiet for `quietMs`. Health: no complete sample for 10 s, an
/// exit, or 10 consecutive unparseable samples → restart after 1, 2, 4 … 60 s; five restarts within 10 minutes, or a
/// missing nettop, → unavailable until `retry()`.
final class NettopSampler {
    static let quietMs = 30
    static let stallMs: Int64 = 10_000
    static let unparseableLimit = 10
    static let maxBackoffMs: Int64 = 60_000
    static let failureWindowMs: Int64 = 600_000
    /// Restarts allowed within `failureWindowMs`.
    static let failureLimit = 5

    enum Status: Equatable {
        /// Not wanted (off or standby).
        case idle
        /// Launched; no complete sample yet.
        case starting
        case sampling
        /// Waiting to restart after a failure.
        case recovering
        case unavailable
    }

    private let queue: DispatchQueue
    private let clock: () -> Int64
    private(set) var status: Status = .idle
    /// The interval of the running (or next) child.
    private(set) var interval: Int?
    /// A failure restarted the child since the last call to `takeStreamBreak()` (METRICS 10.4.3: a new stream).
    private var streamBroken = false

    private var child: NettopChild?
    private var reader: DispatchSourceRead?
    private var quietTimer: DispatchSourceTimer?
    private var parser = NettopParser()
    private var newest: [NettopParser.Row]?
    private var launchedMs: Int64 = 0
    private var lastSampleMs: Int64?
    private var unparseableRun = 0
    private var failures: [Int64] = []
    private var backoffMs: Int64 = 1000
    private var restartAtMs: Int64?
    private var readBuffer = [UInt8](repeating: 0, count: 65_536)
    /// Diagnostics: samples completed and launches.
    private(set) var samplesCompleted = 0
    private(set) var launches = 0
    /// Diagnostics: CPU time spent reading and parsing nettop's output.
    private(set) var readNanos: UInt64 = 0

    init(queue: DispatchQueue, clock: @escaping () -> Int64) {
        self.queue = queue
        self.clock = clock
    }

    deinit { stopChild() }

    var childPid: pid_t? { child?.pid }

    /// Keeps a child running at `interval`; a different interval restarts it (the caller rate-limits that).
    func run(interval: Int) {
        guard status != .unavailable else { return }
        if let child, child.interval == interval { return }
        self.interval = interval
        if status == .recovering { return }
        stopChild()
        launch()
    }

    /// Stops the child (off or standby); not a failure.
    func stop() {
        stopChild()
        status = status == .unavailable ? .unavailable : .idle
        restartAtMs = nil
        interval = nil
        newest = nil
    }

    /// Clears `unavailable` and the failure history (Settings retry, METRICS 10.3).
    func retry() {
        failures.removeAll()
        backoffMs = 1000
        restartAtMs = nil
        if status == .unavailable { status = .idle }
    }

    /// The newest complete sample since the last call, if any.
    func takeSample() -> [NettopParser.Row]? {
        defer { newest = nil }
        return newest
    }

    /// True once after a failure restart: the next samples start a new stream.
    func takeStreamBreak() -> Bool {
        defer { streamBroken = false }
        return streamBroken
    }

    /// After a sleep or a stalled queue the child gets a fresh stall allowance instead of counting as failed.
    func resumeAfterGap() {
        guard status == .starting || status == .sampling else { return }
        lastSampleMs = clock()
    }

    /// Health checks and due restarts; call once per tick.
    func poll() {
        let now = clock()
        switch status {
        case .recovering:
            if let restartAtMs, now >= restartAtMs {
                self.restartAtMs = nil
                launch()
            }
        case .starting, .sampling:
            if now - (lastSampleMs ?? launchedMs) > Self.stallMs { fail() }
        case .idle, .unavailable:
            break
        }
    }

    // MARK: - Child

    private func launch() {
        guard let interval else { return }
        guard NettopChild.isAvailable else {
            status = .unavailable
            return
        }
        do {
            let child = try NettopChild.launch(interval: interval)
            self.child = child
            launches += 1
            launchedMs = clock()
            lastSampleMs = nil
            unparseableRun = 0
            parser = NettopParser()
            status = .starting
            let reader = DispatchSource.makeReadSource(fileDescriptor: child.output, queue: queue)
            reader.setEventHandler { [weak self] in self?.drain() }
            reader.resume()
            self.reader = reader
        } catch NettopChild.LaunchError.missing {
            status = .unavailable
        } catch {
            fail()
        }
    }

    private func stopChild() {
        reader?.cancel()
        reader = nil
        quietTimer?.cancel()
        quietTimer = nil
        child?.terminate()
        child = nil
    }

    private func drain() {
        guard let child else { return }
        let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        defer { readNanos += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started }
        var ended = false
        while true {
            let count = readBuffer.withUnsafeMutableBytes { read(child.output, $0.baseAddress, $0.count) }
            if count > 0 {
                let samples = readBuffer.withUnsafeBytes { parser.feed(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
                for sample in samples { accept(sample) }
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { break }
            ended = true // EOF or EIO: every slave descriptor closed, the child is gone
            break
        }
        if ended {
            if let sample = parser.finish() { accept(sample) }
            fail()
            return
        }
        armQuietTimer()
    }

    private func armQuietTimer() {
        if quietTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in
                guard let self, let sample = parser.finish() else { return }
                accept(sample)
            }
            timer.schedule(deadline: .now() + .milliseconds(Self.quietMs), leeway: .milliseconds(5))
            timer.resume()
            quietTimer = timer
        } else {
            quietTimer?.schedule(deadline: .now() + .milliseconds(Self.quietMs), leeway: .milliseconds(5))
        }
    }

    private func accept(_ sample: NettopParser.Sample) {
        switch sample {
        case .rows(let rows):
            newest = rows
            lastSampleMs = clock()
            unparseableRun = 0
            samplesCompleted += 1
            if status == .starting { status = .sampling }
            backoffMs = 1000
        case .unparseable:
            unparseableRun += 1
            if unparseableRun >= Self.unparseableLimit { fail() }
        }
    }

    /// Stops the child and schedules a restart, or gives up after too many failures.
    private func fail() {
        stopChild()
        newest = nil
        let now = clock()
        failures = failures.filter { now - $0 < Self.failureWindowMs }
        failures.append(now)
        if failures.count > Self.failureLimit {
            status = .unavailable
            restartAtMs = nil
            return
        }
        status = .recovering
        streamBroken = true
        restartAtMs = now + backoffMs
        backoffMs = min(backoffMs * 2, Self.maxBackoffMs)
    }
}
