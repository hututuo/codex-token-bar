import Darwin
import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Traffic samplers")
struct TrafficSamplerTests {
    /// Recorded on macOS 27.0.1 through a pseudo-terminal (CRLF line ends), trimmed; names keep dots and spaces.
    static let recorded = """
        ,bytes_in,bytes_out,\r
        apsd.577,264548,30437,\r
        mDNSResponder.662,2233207265,232304878,\r
        WeChatAppEx Hel.40989,202712184,30060,\r
        python3.14.86948,436364,120325,\r
        GitHub Desktop .66297,3875,2615,\r
        Codex (Service).97613,85013675,3192751,\r
        2.1.308.36412,5876095,265390404,\r
        ,bytes_in,bytes_out,\r
        apsd.577,264600,30500,\r
        2.1.308.36412,5877000,265400000,\r

        """

    static func feed(_ parser: inout NettopParser, _ text: String, chunk: Int) -> [NettopParser.Sample] {
        let bytes = Array(text.utf8)
        var samples: [NettopParser.Sample] = []
        var index = 0
        while index < bytes.count {
            let end = min(index + chunk, bytes.count)
            samples += bytes[index..<end].withUnsafeBytes { parser.feed($0) }
            index = end
        }
        return samples
    }

    @Test(arguments: [1, 7, 4096])
    func recordedOutputParsesInAnyChunking(chunk: Int) throws {
        var parser = NettopParser()
        let completed = Self.feed(&parser, Self.recorded, chunk: chunk)
        #expect(completed.count == 1, "the second header completes the first sample")
        guard case .rows(let first) = try #require(completed.first) else { Issue.record("unparseable"); return }
        #expect(first.map(\.pid) == [577, 662, 40989, 86948, 66297, 97613, 36412])
        #expect(first[1] == .init(pid: 662, rx: 2_233_207_265, tx: 232_304_878))
        #expect(first[6] == .init(pid: 36412, rx: 5_876_095, tx: 265_390_404))
        let last = parser.finish()
        #expect(last == .rows([.init(pid: 577, rx: 264_600, tx: 30500), .init(pid: 36412, rx: 5_877_000, tx: 265_400_000)]))
        #expect(parser.finish() == nil)
    }

    @Test func badLinesAreSkippedAndColumnsFollowTheHeader() {
        var parser = NettopParser()
        let text = """
            ,bytes_out,bytes_in,
            no-pid-here,1,2,
            odd,name.12,3,4,
            bad.13,x,4,
            huge.14,1,99999999999999999999,
            ok.15,10,20,

            """
        _ = Self.feed(&parser, text, chunk: 64)
        #expect(parser.finish() == .rows([.init(pid: 12, rx: 4, tx: 3), .init(pid: 15, rx: 20, tx: 10)]))
    }

    @Test func samplesWithoutColumnsOrParseableLinesAreUnparseable() {
        var parser = NettopParser()
        _ = Self.feed(&parser, ",time,state,\nfoo.1,a,b,\n", chunk: 64)
        #expect(parser.finish() == .unparseable)
        _ = Self.feed(&parser, ",bytes_in,bytes_out,\ngarbage\n", chunk: 64)
        #expect(parser.finish() == .unparseable)
        _ = Self.feed(&parser, ",bytes_in,bytes_out,\n", chunk: 64)
        #expect(parser.finish() == .rows([]), "a header alone is an empty sample")
    }

    @Test func anUnterminatedLineIsNeverReadAsACounter() {
        var parser = NettopParser()
        _ = Self.feed(&parser, ",bytes_in,bytes_out,\nok.15,10,20,\npartial.16,123", chunk: 64)
        #expect(parser.finish() == .rows([.init(pid: 15, rx: 10, tx: 20)]))
        let next = Self.feed(&parser, "456,7,\n,bytes_in,bytes_out,\nok.15,11,21,\n", chunk: 64)
        #expect(next.isEmpty, "the completed line arrived outside a sample and is dropped")
        #expect(parser.finish() == .rows([.init(pid: 15, rx: 11, tx: 21)]))
    }

    @Test func kernelProcessArgumentsParse() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { bytes += $0 }
        bytes += Array("/opt/homebrew/bin/node".utf8) + [0, 0, 0, 0]
        let nodeArgument: [UInt8] = Array("node".utf8)
        bytes.append(contentsOf: nodeArgument)
        bytes.append(0)
        let scriptPath: [UInt8] = Array("/x/@google/gemini-cli/dist/index.js".utf8)
        bytes.append(contentsOf: scriptPath)
        bytes.append(0)
        let yoloArgument: [UInt8] = Array("--yolo".utf8)
        bytes.append(contentsOf: yoloArgument)
        bytes.append(0)
        bytes += Array("PATH=/usr/bin".utf8) + [0]
        let arguments = bytes.withUnsafeBytes { ProcessReader.parseArguments($0) }
        #expect(arguments == ["node", "/x/@google/gemini-cli/dist/index.js", "--yolo"])
    }

    @Test func interfaceCountersAre64BitAndFiltered() throws {
        let reader = MachineCounterReader()
        let counted = CountedInterfaces.current()
        let counters = try #require(reader.read(counted: counted))
        #expect(Set(counters.keys).isSubset(of: counted))
        #expect(!counted.contains("lo0") && !counted.contains { $0.hasPrefix("utun") || $0.hasPrefix("bridge") })
        let everything = try #require(reader.read(counted: ["lo0"]))
        #expect(everything["lo0"].map { $0.rx > 0 } ?? true)
    }

    @Test func processListingFindsThisProcessWithItsDetails() throws {
        let reader = ProcessReader()
        let entries = reader.list(nowMs: 0)
        let me = try #require(entries.first { $0.pid == getpid() })
        #expect(me.ppid == getppid())
        #expect(me.startUs > 1_600_000_000_000_000)
        #expect(reader.executablePath(of: me).map { !$0.isEmpty } == true)
        #expect(reader.arguments(of: me)?.isEmpty == false)
        #expect(reader.workingDirectory(of: me) == FileManager.default.currentDirectoryPath)
        let handle = try FileHandle(forReadingFrom: Fixtures.root.appendingPathComponent("traffic-cases.json"))
        defer { try? handle.close() }
        #expect(reader.openFiles(of: me, nowMs: 0).contains { $0.hasSuffix("traffic-cases.json") })
        let later = reader.list(nowMs: 1000)
        #expect(later.contains(me), "known pids keep their entry between full reads")
    }

    @Test(.enabled(if: NettopChild.isAvailable), .timeLimit(.minutes(1)))
    func nettopChildStreamsSamplesAndIsReaped() async throws {
        let queue = DispatchQueue(label: "test.nettop")
        let sampler = NettopSampler(queue: queue, clock: TrafficCore.monotonicMs)
        queue.sync { sampler.run(interval: 1) }
        let pid = try #require(queue.sync { sampler.childPid })
        var rows: [NettopParser.Row]?
        for _ in 0..<50 where rows == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            rows = queue.sync { sampler.takeSample() }
        }
        #expect(rows?.isEmpty == false)
        #expect(queue.sync { sampler.status } == .sampling)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        #expect(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size)
        #expect(Int32(bitPattern: info.e_tdev) != -1, "the pseudo-terminal is its controlling terminal")
        queue.sync { sampler.stop() }
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "killed and reaped")
    }
}
