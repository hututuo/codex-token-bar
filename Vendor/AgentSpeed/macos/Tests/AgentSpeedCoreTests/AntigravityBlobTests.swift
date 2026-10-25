import Foundation
import Testing
@testable import AgentSpeedCore

/// The blob builders of `spec/tools/antigravity_fixtures.py`, with the unknown fields a real row carries.
enum AntigravityBlobEncoder {
    typealias PB = ProtobufEncoder

    /// 2026-10-21T00:00:00Z, the fixture day.
    static let day: Int64 = 1_792_540_800_000

    /// `HH:MM:SS.mmm` of the fixture day in Unix milliseconds.
    static func ms(_ clock: String) -> Int64 {
        let parts = clock.split(whereSeparator: { $0 == ":" || $0 == "." }).map { Int64($0)! }
        return day + ((parts[0] * 60 + parts[1]) * 60 + parts[2]) * 1000 + parts[3]
    }

    /// A `Timestamp` of `ms` plus sub-millisecond nanos, or with explicit nanos.
    static func stamp(_ field: UInt64, _ ms: Int64, extraNanos: Int64 = 0, nanos: Int64? = nil) -> [UInt8] {
        let seconds = ms >= 0 ? ms / 1000 : -((-ms + 999) / 1000)
        let nanos = nanos ?? (ms - seconds * 1000) * 1_000_000 + extraNanos
        return PB.message(field, PB.int(1, seconds), PB.int(2, nanos))
    }

    static func usage(input: UInt64 = 0, output: UInt64 = 0, cache: UInt64 = 0, thinking: UInt64 = 0,
                      response: UInt64 = 0, responseId: String = "", messageId: String = "") -> [UInt8] {
        PB.uint(1, 1026) + PB.uint(2, input) + PB.uint(3, output) + PB.uint(5, cache) + PB.uint(6, 24)
            + PB.string(7, messageId) + PB.message(8, PB.string(1, "sessionID"), PB.string(2, "f00dfeed"))
            + PB.uint(9, thinking) + PB.uint(10, response) + PB.string(11, responseId) + PB.string(13, "standard")
    }

    static func step(created: Int64? = nil, viewable: Int64? = nil, finished: Int64? = nil, completed: Int64? = nil,
                     usage: [UInt8]? = nil, lastChunk: Int64? = nil, started: Int64? = nil, extra: [UInt8] = []) -> [UInt8] {
        var parts: [UInt8] = []
        if let created { parts += stamp(1, created, extraNanos: 123_456) }
        parts += PB.uint(3, 2)
        parts += PB.message(4, PB.string(1, "call-a1"), PB.string(2, "run_command"), PB.string(3, #"{"path":"x"}"#))
        for (field, value) in [(6, viewable), (7, finished), (8, completed)] as [(UInt64, Int64?)] {
            if let value { parts += stamp(field, value, extraNanos: 987_654) }
        }
        if let usage {
            parts += PB.bytes(9, usage)
            parts += PB.fixed32(10, 0x3C4C_CCCD)
        }
        parts += PB.string(12, "exec-7f21") + PB.uint(21, 1)
        if let lastChunk { parts += stamp(22, lastChunk, extraNanos: 5_000) }
        if let started { parts += stamp(32, started, extraNanos: 1) }
        return parts + extra
    }

    static func trajectory(created: Int64, uris: [String] = [], workspace: String? = nil, parent: String = "",
                           nesting: Int64 = 0, subagent: (String, String)? = nil, root: String = "") -> [UInt8] {
        var parts: [UInt8] = []
        if let workspace { parts += PB.message(1, PB.string(1, workspace), PB.string(2, workspace)) }
        parts += stamp(2, created) + PB.string(5, parent) + PB.string(6, root)
        for uri in uris { parts += PB.string(7, uri) }
        if let subagent {
            parts += PB.message(8, PB.string(1, subagent.0), PB.string(2, subagent.1), PB.string(3, "(prompt omitted)"))
        }
        return parts + PB.packed(15, [101, 202, 30303]) + PB.int(17, nesting)
    }

    static func chatModel(responseModel: String = "", display: String = "") -> [UInt8] {
        PB.string(1, "(system prompt omitted)") + PB.uint(3, 1026) + PB.message(4, usage(input: 1, output: 1))
            + PB.fixed32(5, 0x3C23_D70A) + PB.message(11, PB.uint(2, 700_000_000)) + PB.message(12, PB.uint(1, 2))
            + PB.string(19, responseModel) + PB.string(21, display)
    }

    static func generation(_ steps: [UInt64], responseModel: String = "", display: String = "",
                           packed: Bool = true) -> [UInt8] {
        let indices = packed ? PB.packed(2, steps) : steps.flatMap { PB.key(2, 0) + PB.varint($0) }
        return PB.bytes(1, chatModel(responseModel: responseModel, display: display)) + indices
            + PB.string(4, "exec-7f21")
    }

    static func executor(reason: Int64, lastStep: Int64, model: String) -> [UInt8] {
        let planner = PB.uint(1, 1026) + PB.string(28, model)
        return PB.int(1, reason) + PB.uint(2, 4) + PB.key(3, 0) + PB.varint(signed: lastStep)
            + PB.string(9, "exec-7f21") + PB.message(10, PB.message(1, planner))
    }
}

@Suite("Antigravity blobs")
struct AntigravityBlobTests {
    typealias PB = ProtobufEncoder
    typealias AG = AntigravityBlobEncoder

    static func step(_ bytes: [UInt8]) -> LineExtraction<AntigravityStepMetadata> {
        bytes.withUnsafeBytes { AntigravityBlobs.stepMetadata($0) }
    }

    static func generation(_ bytes: [UInt8]) -> LineExtraction<AntigravityGeneration> {
        bytes.withUnsafeBytes { AntigravityBlobs.generation($0) }
    }

    static func executor(_ bytes: [UInt8]) -> LineExtraction<AntigravityExecutor> {
        bytes.withUnsafeBytes { AntigravityBlobs.executor($0) }
    }

    static func trajectory(_ bytes: [UInt8]) -> LineExtraction<AntigravityTrajectory> {
        bytes.withUnsafeBytes { AntigravityBlobs.trajectory($0) }
    }

    // MARK: - Steps

    @Test func stepDecodesEveryTimestamp() throws {
        let blob = AG.step(created: AG.ms("09:00:01.050"), viewable: AG.ms("09:00:01.800"),
                           finished: AG.ms("09:00:04.250"), completed: AG.ms("09:00:04.300"),
                           usage: AG.usage(input: 12000, output: 480, thinking: 300, response: 180,
                                           responseId: "resp-ag-main-1", messageId: "msg-ag-main-1"),
                           lastChunk: AG.ms("09:00:04.200"), started: AG.ms("09:00:01.060"),
                           extra: PB.fixed64(9001, 0x0123_4567_89AB_CDEF))
        let expected = AntigravityStepMetadata(
            createdMs: AG.ms("09:00:01.050"), viewableMs: AG.ms("09:00:01.800"),
            finishedGeneratingMs: AG.ms("09:00:04.250"), completedMs: AG.ms("09:00:04.300"),
            lastCompletedChunkMs: AG.ms("09:00:04.200"), startedMs: AG.ms("09:00:01.060"),
            usage: AntigravityUsage(input: 12000, output: 480, cacheRead: 0, thinking: 300, response: 180,
                                    key: "resp-ag-main-1")
        )
        #expect(Self.step(blob) == .line(expected))
        #expect(expected.timestamps.count == 6)
    }

    @Test func invalidTimestampsAreNil() {
        let created = AG.ms("09:10:01.050")
        let blob = PB.message(1) + PB.message(6, PB.int(2, 5_000_000)) + PB.message(7, PB.int(1, -1_761_000_000))
            + AG.stamp(8, AG.ms("09:01:40.000"), nanos: 1_999_999_999) + AG.stamp(22, AG.ms("09:01:41.000"), nanos: -1)
            + AG.stamp(32, created, extraNanos: 999_999) + PB.uint(1, 5)
        let expected = AntigravityStepMetadata(completedMs: AG.ms("09:01:40.000"),
                                               lastCompletedChunkMs: AG.ms("09:01:41.000"), startedMs: created)
        #expect(Self.step(blob) == .line(expected))
    }

    @Test func usageKeyFallsBackToMessageId() {
        let cases: [([UInt8], String?)] = [
            (AG.usage(input: 1, responseId: "resp", messageId: "msg"), "resp"),
            (AG.usage(input: 1, messageId: "msg-ag-orbit-1"), "msg-ag-orbit-1"),
            (AG.usage(input: 1), nil),
            (AG.usage(input: 1) + PB.bytes(11, []) + PB.bytes(7, []), nil),
            (PB.string(11, "old") + PB.string(11, "new") + PB.bytes(7, [0xFF]), "new"),
            (PB.bytes(7, [0x61, 0xFF]), "a\u{FFFD}"),
        ]
        for (usage, key) in cases {
            guard case .line(let step) = Self.step(PB.bytes(9, usage)) else {
                Issue.record("malformed")
                continue
            }
            #expect(step.usage?.key == key)
        }
    }

    @Test func usageFieldsAreRaw() {
        let blob = PB.bytes(9, AG.usage(input: 3000, cache: 1000, thinking: 64, response: 136))
        let usage = AntigravityUsage(input: 3000, output: 0, cacheRead: 1000, thinking: 64, response: 136)
        #expect(Self.step(blob) == .line(AntigravityStepMetadata(usage: usage)))
        #expect(Self.step(AG.step(created: 1000)) == .line(AntigravityStepMetadata(createdMs: 1000)))
        #expect(Self.step(PB.bytes(9, [])) == .line(AntigravityStepMetadata(usage: AntigravityUsage())))
        #expect(Self.step(PB.uint(9, 5)) == .line(AntigravityStepMetadata()))
    }

    @Test(arguments: [2, 3, 5, 9, 10] as [UInt64])
    func tokenCountAboveCapIsMalformed(field: UInt64) {
        let atCap = PB.uint(field, AntigravityBlobs.maxTokens)
        guard case .line(let step) = Self.step(PB.bytes(9, atCap)), let usage = step.usage else {
            Issue.record("at the cap must decode")
            return
        }
        #expect([usage.input, usage.output, usage.cacheRead, usage.thinking, usage.response].max() == 10_000_000)
        #expect(Self.step(PB.bytes(9, PB.uint(field, AntigravityBlobs.maxTokens + 1))) == .malformed)
        #expect(Self.step(PB.bytes(9, PB.int(field, -1))) == .malformed)
        #expect(Self.step(PB.bytes(9, PB.uint(field, 1) + PB.uint(field, 10_000_001))) == .malformed)
        #expect(Self.step(PB.bytes(9, PB.uint(field, 10_000_001) + PB.uint(field, 1))) != .malformed)
        #expect(Self.step(PB.bytes(9, PB.fixed64(field, .max))) != .malformed)
    }

    @Test func unusedFieldsAreNotCapped() {
        let usage = PB.uint(1, .max) + PB.uint(4, .max) + PB.uint(6, .max) + PB.uint(2, 7)
        #expect(Self.step(PB.bytes(9, usage)) == .line(AntigravityStepMetadata(usage: AntigravityUsage(input: 7))))
    }

    @Test func malformedSteps() {
        let created = AG.ms("09:30:00.500")
        #expect(Self.step(AG.stamp(1, created) + PB.key(2, 7)) == .malformed)
        #expect(Self.step(AG.stamp(1, created) + PB.key(2, 2) + PB.varint(9)) == .malformed)
        #expect(Self.step(PB.bytes(7, [0x08])) == .malformed)
        #expect(Self.step(PB.bytes(32, [0x00])) == .malformed)
        #expect(Self.step(PB.bytes(9, [0x0B])) == .malformed)
        #expect(Self.step(PB.bytes(9, PB.uint(2, 1)) + PB.bytes(9, PB.uint(2, 10_000_001))) == .malformed)
        // Only the last occurrence of a message is read; unknown nested fields are never parsed.
        #expect(Self.step(PB.bytes(1, [0x0F]) + AG.stamp(1, created)) == .line(AntigravityStepMetadata(createdMs: created)))
        #expect(Self.step(PB.bytes(4, [0x0F]) + PB.bytes(9, [0x0F]) + PB.bytes(9, [])) != .malformed)
        #expect(Self.step(PB.bytes(9, PB.bytes(8, [0x0F]))) == .line(AntigravityStepMetadata(usage: AntigravityUsage())))
    }

    @Test func emptyBlobsAreEmptyMessages() {
        #expect(Self.step([]) == .line(AntigravityStepMetadata()))
        #expect(Self.generation([]) == .line(AntigravityGeneration()))
        #expect(Self.executor([]) == .line(AntigravityExecutor()))
        #expect(Self.trajectory([]) == .line(AntigravityTrajectory()))
        let null = UnsafeRawBufferPointer(start: nil, count: 0)
        #expect(AntigravityBlobs.stepMetadata(null) == .line(AntigravityStepMetadata()))
        #expect(AntigravityBlobs.trajectory(null) == .line(AntigravityTrajectory()))
    }

    // MARK: - Generations

    @Test func generationModelFallsBackToDisplayName() {
        #expect(Self.generation(AG.generation([1], responseModel: "gemini-3.1-pro-high", display: "Gemini 3.1 Pro (High)"))
            == .line(AntigravityGeneration(stepIndices: [1], model: "gemini-3.1-pro-high")))
        #expect(Self.generation(AG.generation([5], display: "Gemini 3.1 Pro (High)"))
            == .line(AntigravityGeneration(stepIndices: [5], model: "Gemini 3.1 Pro (High)")))
        #expect(Self.generation(AG.generation([2])) == .line(AntigravityGeneration(stepIndices: [2])))
        #expect(Self.generation(PB.packed(2, [4])) == .line(AntigravityGeneration(stepIndices: [4])))
        #expect(Self.generation(PB.uint(1, 3) + PB.uint(2, 4)) == .line(AntigravityGeneration(stepIndices: [4])))
        #expect(Self.generation(PB.string(1, "x") + PB.uint(2, 4)) == .malformed)
        let twice = PB.bytes(1, AG.chatModel(responseModel: "first")) + PB.bytes(1, AG.chatModel(display: "second"))
        #expect(Self.generation(twice) == .line(AntigravityGeneration(model: "second")))
    }

    @Test func generationStepIndicesArePackedOrUnpacked() {
        #expect(Self.generation(AG.generation([3, 0, 9], packed: false))
            == .line(AntigravityGeneration(stepIndices: [0, 3, 9])))
        #expect(Self.generation(PB.packed(2, [1, 2]) + PB.uint(2, 7) + PB.packed(2, [2, 300]) + PB.fixed32(2, 5))
            == .line(AntigravityGeneration(stepIndices: [1, 2, 7, 300])))
    }

    @Test func malformedGenerations() {
        #expect(Self.generation(PB.key(1, 2) + PB.varint(50) + Array("abc".utf8)) == .malformed)
        #expect(Self.generation(PB.bytes(1, [0x0F]) + PB.packed(2, [1])) == .malformed)
        #expect(Self.generation(PB.bytes(2, [0x80])) == .malformed)
        #expect(Self.generation(PB.bytes(1, [0x0F]) + PB.bytes(1, AG.chatModel(display: "ok")))
            == .line(AntigravityGeneration(model: "ok")))
        #expect(Self.generation(PB.bytes(1, PB.bytes(4, [0x0F]) + PB.string(19, "m")))
            == .line(AntigravityGeneration(model: "m")))
    }

    // MARK: - Executors

    @Test func executorDecodesNestedModel() {
        #expect(Self.executor(AG.executor(reason: 4, lastStep: 8, model: "gemini-3.1-pro"))
            == .line(AntigravityExecutor(terminationReason: 4, lastStepIdx: 8, model: "gemini-3.1-pro")))
        #expect(Self.executor(AG.executor(reason: 1, lastStep: -1, model: "gemini-3.1-flash-image"))
            == .line(AntigravityExecutor(terminationReason: 1, lastStepIdx: -1, model: "gemini-3.1-flash-image")))
        #expect(Self.executor(AG.executor(reason: 0, lastStep: 3, model: ""))
            == .line(AntigravityExecutor(terminationReason: 0, lastStepIdx: 3)))
        #expect(Self.executor(PB.int(1, -2) + PB.int(3, 5) + PB.message(10, PB.string(28, "not nested")))
            == .line(AntigravityExecutor(terminationReason: -2, lastStepIdx: 5)))
        #expect(Self.executor(PB.message(10, PB.message(1, PB.string(28, "a")), PB.message(1, PB.string(28, "b"))))
            == .line(AntigravityExecutor(model: "b")))
    }

    @Test func malformedExecutors() {
        #expect(Self.executor(PB.bytes(10, [0x0F])) == .malformed)
        #expect(Self.executor(PB.message(10, PB.bytes(1, [0x0F]))) == .malformed)
        #expect(Self.executor(PB.int(3, 1) + PB.key(4, 3)) == .malformed)
        #expect(Self.executor(PB.message(10, PB.bytes(2, [0x0F]), PB.message(1, PB.bytes(5, [0x0F]))))
            == .line(AntigravityExecutor()))
    }

    // MARK: - Trajectories

    @Test func trajectoryProjectPrefersWorkspaceURIs() {
        let created = AG.ms("09:00:00.000")
        let main = AG.trajectory(created: created, uris: ["file:///Users/dev/projects/star%20map", "file:///other"],
                                 workspace: "file:///Users/dev/projects/old-name", root: "3f6c2a10")
        #expect(Self.trajectory(main) == .line(AntigravityTrajectory(
            createdMs: created, project: "star map", cwdPath: "/Users/dev/projects/star map")))
        let browser = AG.trajectory(created: created, workspace: "file:///Users/dev/projects/orbit-web", parent: "PARENT")
        #expect(Self.trajectory(browser) == .line(AntigravityTrajectory(
            createdMs: created, project: "orbit-web", cwdPath: "/Users/dev/projects/orbit-web", parentConversationId: "PARENT",
            isSubagent: true)))
        let windows = AG.trajectory(created: created, uris: ["file:///c%3A/Users/dev/projects/orbit"])
        #expect(Self.trajectory(windows) == .line(AntigravityTrajectory(
            createdMs: created, project: "orbit", cwdPath: "/c:/Users/dev/projects/orbit")))
    }

    @Test func trajectoryProjectFallsBackToFirstWorkspace() {
        let workspaces = PB.message(1, PB.string(1, "file:///a/first")) + PB.message(1, PB.string(1, "file:///a/second"))
        let first = AntigravityTrajectory(project: "first", cwdPath: "/a/first")
        #expect(Self.trajectory(workspaces) == .line(first))
        #expect(Self.trajectory(PB.bytes(7, []) + PB.string(7, "file:///a/b") + workspaces) == .line(first))
        #expect(Self.trajectory(PB.string(7, "file:///") + workspaces) == .line(first))
        #expect(Self.trajectory(PB.string(7, "file://host")) == .line(AntigravityTrajectory()))
        #expect(Self.trajectory(PB.message(1, PB.string(1, "x/one"), PB.string(1, "y/two")))
            == .line(AntigravityTrajectory(project: "two")))
        #expect(Self.trajectory(PB.message(1, PB.string(2, "file:///a/b"))) == .line(AntigravityTrajectory()))
        #expect(Self.trajectory(PB.uint(7, 5) + workspaces) == .line(first))
    }

    @Test func trajectorySubagentMarkers() {
        let created = AG.ms("09:00:11.300")
        let sub = AG.trajectory(created: created, uris: ["file:///Users/dev/projects/star%20map"], parent: "MAIN",
                                nesting: 1, subagent: ("research", "Map the call sites"), root: "MAIN")
        #expect(Self.trajectory(sub) == .line(AntigravityTrajectory(
            createdMs: created, project: "star map", cwdPath: "/Users/dev/projects/star map", parentConversationId: "MAIN",
            isSubagent: true)))
        let cases: [([UInt8], Bool)] = [
            (AG.trajectory(created: created, nesting: 2), true),
            (AG.trajectory(created: created, nesting: -1), false),
            (AG.trajectory(created: created, subagent: ("image_generation", "Render the logo")), true),
            (PB.bytes(8, []), true),
            (PB.bytes(8, [0x0F]), true),
            (PB.uint(8, 1), false),
            (PB.bytes(5, []), false),
            (PB.uint(17, UInt64(UInt32.max)), true),
            (AG.trajectory(created: created), false),
        ]
        for (blob, isSubagent) in cases {
            guard case .line(let trajectory) = Self.trajectory(blob) else {
                Issue.record("malformed")
                continue
            }
            #expect(trajectory.isSubagent == isSubagent, "\(blob)")
            #expect(trajectory.parentConversationId == nil)
        }
    }

    @Test func malformedTrajectories() {
        let uris = PB.string(7, "file:///a/nova")
        #expect(Self.trajectory(PB.bytes(1, [0x0F]) + uris) == .malformed)
        #expect(Self.trajectory(PB.bytes(1, PB.bytes(1, [0x80])) + uris) != .malformed)
        #expect(Self.trajectory(uris + PB.message(1, PB.string(1, "file:///a/b")) + PB.bytes(1, [0x0F]))
            == .line(AntigravityTrajectory(project: "nova", cwdPath: "/a/nova")))
        #expect(Self.trajectory(PB.bytes(2, [0x0F]) + uris) == .malformed)
        #expect(Self.trajectory(PB.bytes(2, [0x0F]) + AG.stamp(2, 5000) + uris)
            == .line(AntigravityTrajectory(createdMs: 5000, project: "nova", cwdPath: "/a/nova")))
        #expect(Self.trajectory(uris + PB.key(9, 6)) == .malformed)
    }

    @Test func invalidUTF8BecomesReplacementCharacters() {
        let blob = PB.bytes(5, [0x61, 0xFF, 0x62]) + PB.bytes(7, Array("file:///x/".utf8) + [0xC3])
        #expect(Self.trajectory(blob) == .line(AntigravityTrajectory(
            project: "\u{FFFD}", cwdPath: "/x/\u{FFFD}", parentConversationId: "a\u{FFFD}b", isSubagent: true)))
        #expect(Self.trajectory(PB.bytes(7, Array("file:///x/%C3".utf8)))
            == .line(AntigravityTrajectory(project: "\u{FFFD}", cwdPath: "/x/\u{FFFD}")))
        #expect(Self.generation(PB.message(1, PB.bytes(21, [0xE2, 0x82, 0x41])))
            == .line(AntigravityGeneration(model: "\u{FFFD}A")))
        #expect(Self.executor(PB.message(10, PB.message(1, PB.bytes(28, [0xF0, 0x80, 0x80, 0x80]))))
            == .line(AntigravityExecutor(model: String(repeating: "\u{FFFD}", count: 4))))
    }

    @Test(arguments: [
        ("file:///c%3A/Users/dev/projects/orbit", "orbit"),
        ("file:///Users/dev/projects/star%20map", "star map"),
        (#"C:\Users\dev\x"#, "x"),
        ("c:/Users/dev/proj", "proj"),
        ("file:///C:/Users/dev/proj%5C", "proj"),
        ("vscode-remote://ssh-remote%2Bdev/home/dev/proj", "proj"),
        ("file://server/share/dir/", "dir"),
        ("file:////x", "x"),
        ("x+y.z-w://h/p", "p"),
        ("FILE:///X/Y", "Y"),
        ("a:b", "a:b"),
        ("ab:x%20y", "x y"),
        ("1ab:/x", "x"),
        ("%41:b", "%41:b"),
        ("/Users/dev/x%20y", "x%20y"),
        ("file:///x/%zz%4", "%zz%4"),
        ("ab:%%41", "%A"),
        ("file:///x/%C3%A9t%C3%A9", "été"),
        ("file:///x/%e2%82%ac", "€"),
        ("file:///x/%C3%28", "\u{FFFD}("),
        ("file:///x/a%2Fb", "b"),
        ("file:///x/a%5Cb", "b"),
        ("file:///x/café", "café"),
    ] as [(String, String)])
    func uriBasename(uri: String, basename: String) {
        #expect(AntigravityBlobs.uriBasename(uri) == basename)
    }

    @Test(arguments: ["", "/", #"\\"#, "file:", "file://", "file:///", "file://host", "file:///%2F"])
    func uriWithoutComponentHasNoBasename(uri: String) {
        #expect(AntigravityBlobs.uriBasename(uri) == nil)
    }

    // MARK: - Fixture databases

    static var databases: [String: [String: Any]] {
        get throws {
            let antigravity = try #require(try Fixtures.json("parser-expected.json")["antigravity"] as? [String: Any])
            return try #require(antigravity["databases"] as? [String: [String: Any]])
        }
    }

    struct Decoded {
        var trajectory: [LineExtraction<AntigravityTrajectory>] = []
        var generations: [LineExtraction<AntigravityGeneration>?] = []
        var executors: [LineExtraction<AntigravityExecutor>?] = []
        var steps: [LineExtraction<AntigravityStepMetadata>?] = []

        var malformed: Int {
            func count<Value>(_ values: [LineExtraction<Value>?]) -> Int {
                values.filter { if case .malformed = $0 { true } else { false } }.count
            }
            return count(trajectory.map(Optional.some)) + count(generations) + count(executors) + count(steps)
        }
    }

    /// Reads a fixture database with the queries of METRICS 4.8, decoding every blob inside the row callback.
    static func decode(_ relative: String) throws -> Decoded {
        let connection = try SQLiteConnection(path: Fixtures.root.appendingPathComponent(relative).path, mode: .immutable)
        defer { connection.close() }
        func rows<Value>(_ sql: String, column: Int32,
                         _ decode: (UnsafeRawBufferPointer) -> LineExtraction<Value>) throws -> [LineExtraction<Value>?] {
            var values: [LineExtraction<Value>?] = []
            try connection.prepare(sql).forEachRow { row in
                values.append(row.isNull(column) ? nil : row.withBlob(column, decode))
            }
            return values
        }
        var decoded = Decoded()
        decoded.trajectory = try rows("SELECT CASE WHEN length(data) <= 1048576 THEN data END FROM "
                                      + "trajectory_metadata_blob ORDER BY rowid LIMIT 1", column: 0,
                                      AntigravityBlobs.trajectory).compactMap { $0 }
        decoded.generations = try rows("SELECT idx, CASE WHEN typeof(size) = 'integer' AND size <= 1048576 AND "
                                       + "length(data) <= 1048576 THEN data END FROM gen_metadata WHERE idx > -1 "
                                       + "ORDER BY idx, rowid", column: 1, AntigravityBlobs.generation)
        decoded.executors = try rows("SELECT idx, CASE WHEN length(data) <= 1048576 THEN data END FROM "
                                     + "executor_metadata WHERE idx > -1 ORDER BY idx, rowid", column: 1,
                                     AntigravityBlobs.executor)
        decoded.steps = try rows("SELECT idx, step_type, status, CASE WHEN length(metadata) <= 1048576 THEN metadata "
                                 + "END FROM steps WHERE idx > -1 ORDER BY idx, rowid", column: 3,
                                 AntigravityBlobs.stepMetadata)
        return decoded
    }

    @Test func fixtureDatabasesHaveTheExpectedMalformedBlobs() throws {
        let databases = try Self.databases
        #expect(databases.count == 11)
        var checked = 0
        for (relative, expected) in databases.sorted(by: { $0.key < $1.key }) where expected["unsupported"] == nil {
            let decoded = try Self.decode(relative)
            #expect(decoded.malformed == expected.int("malformedLines"), "\(relative)")
            guard case .line(let trajectory) = try #require(decoded.trajectory.first) else {
                Issue.record("\(relative): malformed trajectory")
                continue
            }
            #expect(trajectory.project == expected.string("project"), "\(relative)")
            #expect(trajectory.isSubagent == (expected["isSubagent"] as? Bool), "\(relative)")
            #expect(!decoded.steps.isEmpty, "\(relative)")
            checked += 1
        }
        #expect(checked == 10)
    }

    @Test func mainConversationDecodesAsWritten() throws {
        let decoded = try Self.decode("antigravity/antigravity-cli/conversations/3f6c2a10-8b4d-4e5f-9a1b-2c3d4e5f6a7b.db")
        #expect(decoded.trajectory == [.line(AntigravityTrajectory(
            createdMs: AG.ms("09:00:00.000"), project: "star map", cwdPath: "/Users/dev/projects/star map"))])
        #expect(decoded.generations == [
            .line(AntigravityGeneration(stepIndices: [1], model: "gemini-3.1-pro-high")),
            .line(AntigravityGeneration(stepIndices: [3], model: "gemini-3.1-pro-high-exp-b")),
            .line(AntigravityGeneration(stepIndices: [5], model: "Gemini 3.1 Pro (High)")),
            nil,
        ])
        #expect(decoded.executors == [.line(AntigravityExecutor(terminationReason: 4, lastStepIdx: 8, model: "gemini-3.1-pro"))])
        #expect(decoded.steps.count == 9)
        #expect(decoded.steps[1] == .line(AntigravityStepMetadata(
            createdMs: AG.ms("09:00:01.050"), viewableMs: AG.ms("09:00:01.800"),
            finishedGeneratingMs: AG.ms("09:00:04.250"), completedMs: AG.ms("09:00:04.300"),
            lastCompletedChunkMs: AG.ms("09:00:04.200"),
            usage: AntigravityUsage(input: 12000, output: 480, thinking: 300, response: 180, key: "resp-ag-main-1")
        )))
        #expect(decoded.steps[8] == .line(AntigravityStepMetadata(
            createdMs: AG.ms("09:01:39.200"), viewableMs: AG.ms("09:01:40.000"), completedMs: AG.ms("09:01:39.400"))))
    }

    @Test func inFlightConversationDecodesAsWritten() throws {
        let decoded = try Self.decode("antigravity/antigravity/conversations/5e2d1c0b-9a8f-4e7d-8c6b-5a4f3e2d1c0b.db")
        #expect(decoded.trajectory == [.line(AntigravityTrajectory(
            createdMs: AG.ms("09:10:00.000"), project: "orbit", cwdPath: "/c:/Users/dev/projects/orbit"))])
        #expect(decoded.steps.count == 14)
        #expect(decoded.steps[1] == .line(AntigravityStepMetadata(
            createdMs: AG.ms("09:10:01.050"), completedMs: AG.ms("09:10:03.200"),
            lastCompletedChunkMs: AG.ms("09:10:03.050"),
            usage: AntigravityUsage(input: 3000, cacheRead: 1000, thinking: 64, response: 136, key: "msg-ag-orbit-1")
        )))
        guard case .line(let unkeyed) = decoded.steps[6] else {
            Issue.record("step 6 malformed")
            return
        }
        #expect(unkeyed.usage?.key == nil)
        #expect(decoded.steps[11] == .malformed)
        #expect(decoded.executors == [
            .line(AntigravityExecutor(terminationReason: 1, lastStepIdx: 7, model: "gemini-3.1-flash")),
            .line(AntigravityExecutor(terminationReason: 2, lastStepIdx: 9, model: "gemini-3.1-flash-b")),
        ])
        let image = try Self.decode("antigravity/antigravity-ide/conversations/7c8d9e0f-1a2b-4c3d-9e4f-5a6b7c8d9e0f.db")
        #expect(image.executors == [.line(AntigravityExecutor(terminationReason: 1, lastStepIdx: -1,
                                                              model: "gemini-3.1-flash-image"))])
    }
}
