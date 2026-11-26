import Foundation

/// Which family of transcript file a file belongs to. A new file-based source adds a case here, a line extractor and
/// parser (`DecodedLine`, `TranscriptParser`, `TranscriptDecoder`) and its location (`TranscriptLocations`).
enum TranscriptFamily: String, CaseIterable, Sendable {
    case codex
    case claude
    /// DeepSeek Harness (dsh).
    case dsh
    /// Gemini CLI.
    case gemini
    /// omp (oh-my-pi).
    case omp
    /// Antigravity: one SQLite database per conversation, read as a whole unit per change (METRICS 4.8, 5.4).
    case antigravity
    /// WorkBuddy (China edition) and WorkBuddy AI (international edition): one format, one root each (METRICS 4.9).
    case workbuddy
    case workbuddyAi
    case kimi
    case grokBuild

    /// Nil for sources that are not read from transcript files: OpenCode is a database (`OpencodeSource`).
    init?(_ source: SourceKind) {
        switch source {
        case .codex: self = .codex
        case .claudeCode, .claudeDesktop: self = .claude
        case .deepseek: self = .dsh
        case .gemini: self = .gemini
        case .omp: self = .omp
        case .antigravity: self = .antigravity
        case .workbuddy: self = .workbuddy
        case .workbuddyAi: self = .workbuddyAi
        case .kimi: self = .kimi
        case .grokBuild: self = .grokBuild
        case .opencode, .zcode: return nil
        }
    }

    /// Sources whose transcripts belong to this family.
    var sources: [SourceKind] {
        switch self {
        case .codex: [.codex]
        case .claude: [.claudeCode, .claudeDesktop]
        case .dsh: [.deepseek]
        case .gemini: [.gemini]
        case .omp: [.omp]
        case .antigravity: [.antigravity]
        case .workbuddy: [.workbuddy]
        case .workbuddyAi: [.workbuddyAi]
        case .kimi: [.kimi]
        case .grokBuild: [.grokBuild]
        }
    }

    /// File names (and for Gemini CLI, omp, Antigravity and WorkBuddy, folder layout) of this family's transcripts
    /// (METRICS 2, 4.6 – 4.9).
    var names: TranscriptNames {
        switch self {
        case .codex: .codexSession
        case .claude: .jsonl
        case .dsh: .dshSession
        case .gemini: .geminiSession
        case .omp: .ompSession
        case .antigravity: .antigravityDatabase
        case .workbuddy, .workbuddyAi: .workbuddySession
        case .kimi: .kimiSession
        case .grokBuild: .grokBuildSession
        }
    }

    /// An Antigravity database is one SQLite file plus its `-wal`; every other family is a single file.
    var isDatabase: Bool { self == .antigravity }

    /// The two WorkBuddy editions.
    var isWorkBuddy: Bool { self == .workbuddy || self == .workbuddyAi }

    /// The stat that identifies one transcript of this family; nil unless it is a regular file.
    func stat(_ path: String) -> FileStat? {
        if isDatabase { return FileStat.databaseStat(path) }
        if self == .grokBuild { return GrokBuildParser.stat(path) }
        guard let stat = FileStat.lstat(path), stat.isRegularFile else { return nil }
        return stat
    }

    /// The transcript a changed path belongs to: an Antigravity `<id>.db-wal` stands for `<id>.db`.
    func transcriptPath(forChanged path: String) -> String {
        if self == .grokBuild, (path as NSString).lastPathComponent == "summary.json" {
            return ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("updates.jsonl")
        }
        guard isDatabase, path.hasSuffix(".db-wal") else { return path }
        return String(path.dropLast(4))
    }
}

enum DecodedLine: Sendable {
    case codex(LineExtraction<CodexLine>)
    case claude(LineExtraction<ClaudeLine>)
    case dsh(LineExtraction<DshLine>)
    case gemini(LineExtraction<GeminiLine>)
    case omp(LineExtraction<OmpLine>)
    case workbuddy(LineExtraction<WorkBuddyLine>)
    case kimi(LineExtraction<KimiLine>)
    case grokBuild(LineExtraction<GrokBuildLine>)
}

/// Lines decoded ahead of time (off the state-machine thread) so seeding can extract in parallel. An Antigravity read
/// is one batch of database rows.
enum DecodedLines: Sendable {
    case codex([LineExtraction<CodexLine>])
    case claude([LineExtraction<ClaudeLine>])
    case dsh([LineExtraction<DshLine>])
    case gemini([LineExtraction<GeminiLine>])
    case omp([LineExtraction<OmpLine>])
    case antigravity(AntigravityBatch?)
    case workbuddy([LineExtraction<WorkBuddyLine>])
    case kimi([LineExtraction<KimiLine>])
    case grokBuild([LineExtraction<GrokBuildLine>])
}

/// The optional slots below used to reserve every parser's full inline size in
/// each tracked file, although only one family is active. Store only the active
/// payload and copy on mutation so snapshots retain independent value semantics.
private struct ParserStorage<Value: Sendable>: Sendable {
    private final class Box: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    private var box: Box
    init(_ value: Value) { box = Box(value) }
    var value: Value {
        _read { yield box.value }
        _modify {
            if !isKnownUniquelyReferenced(&box) { box = Box(box.value) }
            yield &box.value
        }
    }
}

/// A family-agnostic per-file parser. Only the selected machine allocates storage.
struct TranscriptParser: Sendable {
    let family: TranscriptFamily
    private var codex: ParserStorage<CodexParser>?
    private var claude: ParserStorage<ClaudeParser>?
    private var dsh: ParserStorage<DshParser>?
    private var gemini: ParserStorage<GeminiParser>?
    private var omp: ParserStorage<OmpParser>?
    private var antigravity: ParserStorage<AntigravityParser>?
    private var workbuddy: ParserStorage<WorkBuddyParser>?
    private var kimi: ParserStorage<KimiParser>?
    private var grokBuild: ParserStorage<GrokBuildParser>?

    /// `root` is the root folder the file was discovered under (omp and WorkBuddy derive `isSubagent` from it,
    /// METRICS 4.7, 4.9).
    init(family: TranscriptFamily, agentId: String, fileID: FileID, root: String? = nil, selectedSources: Set<SourceKind>? = nil) {
        self.family = family
        switch family {
        case .codex: codex = ParserStorage(CodexParser(agentId: agentId, fileID: fileID))
        case .claude: claude = ParserStorage(ClaudeParser(agentId: agentId, fileID: fileID, selectedSources: selectedSources))
        case .dsh: dsh = ParserStorage(DshParser(agentId: agentId, fileID: fileID))
        case .gemini: gemini = ParserStorage(GeminiParser(agentId: agentId, fileID: fileID))
        case .omp: omp = ParserStorage(OmpParser(agentId: agentId, fileID: fileID, root: root))
        case .antigravity: antigravity = ParserStorage(AntigravityParser(agentId: agentId, fileID: fileID))
        case .workbuddy, .workbuddyAi:
            workbuddy = ParserStorage(WorkBuddyParser(source: family.sources[0], agentId: agentId, fileID: fileID, root: root))
        case .kimi: kimi = ParserStorage(KimiParser(agentId: agentId, fileID: fileID))
        case .grokBuild: grokBuild = ParserStorage(GrokBuildParser(agentId: agentId, fileID: fileID))
        }
    }

    var state: AgentState {
        // Exactly one parser is initialized. A chain of ?? autoclosures copies
        // this large aggregate for every fallback during each snapshot scan.
        // Select the same initialized parser directly; retain value semantics.
        switch family {
        case .codex: codex!.value.state
        case .claude: claude!.value.state
        case .dsh: dsh!.value.state
        case .gemini: gemini!.value.state
        case .omp: omp!.value.state
        case .workbuddy, .workbuddyAi: workbuddy!.value.state
        case .kimi: kimi!.value.state
        case .grokBuild: grokBuild!.value.state
        case .antigravity: antigravity!.value.state
        }
    }

    /// An Antigravity database without the expected tables (`unsupportedFormat`).
    var isUnsupported: Bool { antigravity?.value.isUnsupported ?? false }

    /// Decodes one unit of input: a line, or a whole document for Gemini CLI legacy `.json` files. Antigravity
    /// databases are never fed bytes; their reads arrive as batches.
    func decode(_ bytes: UnsafeRawBufferPointer) -> DecodedLine? {
        switch family {
        case .codex: .codex(CodexLineExtractor.extract(bytes))
        case .claude: .claude(ClaudeLineExtractor.extract(bytes))
        case .dsh: .dsh(DshLineExtractor.extract(bytes))
        case .gemini:
            .gemini(gemini?.value.isDocument == true ? GeminiLineExtractor.extractDocument(bytes) : GeminiLineExtractor.extract(bytes))
        case .omp: .omp(OmpLineExtractor.extract(bytes))
        case .workbuddy, .workbuddyAi: .workbuddy(WorkBuddyLineExtractor.extract(bytes))
        case .antigravity: nil
        case .kimi: .kimi(KimiLineExtractor.extract(bytes))
        case .grokBuild: .grokBuild(GrokBuildLine.extract(bytes))
        }
    }

    var hasPartialHistory: Bool { grokBuild?.value.partialHistory ?? false }

    mutating func refreshMetadata(deduper: inout Deduper, emit: (ResponseUpsert) -> Void) -> Bool {
        grokBuild?.value.refreshMetadata(deduper: &deduper, emit: emit) ?? false
    }

    /// Counts a unit of input that could not be decoded at all, such as a corrupt zstd frame (METRICS 5.1).
    mutating func noteMalformedLine() {
        codex?.value.noteMalformedLine()
        claude?.value.noteMalformedLine()
        dsh?.value.noteMalformedLine()
        gemini?.value.noteMalformedLine()
        omp?.value.noteMalformedLine()
        antigravity?.value.noteMalformedLine()
        workbuddy?.value.noteMalformedLine()
        kimi?.value.noteMalformedLine()
        grokBuild?.value.noteMalformedLine()
    }

    mutating func consume(_ line: DecodedLine, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        switch line {
        case .codex(let extraction): codex?.value.consume(extraction, deduper: &deduper, emit: emit)
        case .claude(let extraction): claude?.value.consume(extraction, deduper: &deduper, emit: emit)
        case .dsh(let extraction): dsh?.value.consume(extraction, deduper: &deduper, emit: emit)
        case .gemini(let extraction): gemini?.value.consume(extraction, deduper: &deduper, emit: emit)
        case .omp(let extraction): omp?.value.consume(extraction, deduper: &deduper, emit: emit)
        case .workbuddy(let extraction): workbuddy?.value.consume(extraction, deduper: &deduper, emit: emit)
        case .kimi(let extraction): kimi?.value.consume(extraction, deduper: &deduper, emit: emit)
        case .grokBuild(let extraction): grokBuild?.value.consume(extraction, deduper: &deduper, emit: emit)
        }
    }

    mutating func consume(rawLine bytes: UnsafeRawBufferPointer, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        guard let line = decode(bytes) else { return }
        consume(line, deduper: &deduper, emit: emit)
    }

    mutating func consume(_ lines: DecodedLines, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        switch lines {
        case .codex(let extractions):
            for extraction in extractions { codex?.value.consume(extraction, deduper: &deduper, emit: emit) }
        case .claude(let extractions):
            for extraction in extractions { claude?.value.consume(extraction, deduper: &deduper, emit: emit) }
        case .dsh(let extractions):
            for extraction in extractions { dsh?.value.consume(extraction, deduper: &deduper, emit: emit) }
        case .gemini(let extractions):
            for extraction in extractions { gemini?.value.consume(extraction, deduper: &deduper, emit: emit) }
        case .omp(let extractions):
            for extraction in extractions { omp?.value.consume(extraction, deduper: &deduper, emit: emit) }
        case .antigravity(let batch):
            if let batch { antigravity?.value.consume(batch, deduper: &deduper, emit: emit) }
        case .workbuddy(let extractions):
            for extraction in extractions { workbuddy?.value.consume(extraction, deduper: &deduper, emit: emit) }
        case .kimi(let extractions):
            for extraction in extractions { kimi?.value.consume(extraction, deduper: &deduper, emit: emit) }
        case .grokBuild(let extractions):
            for extraction in extractions { grokBuild?.value.consume(extraction, deduper: &deduper, emit: emit) }
        }
    }
}

/// Reads a whole transcript (from the reader's position) and decodes its lines, off the state-machine thread.
enum TranscriptDecoder {
    static func decode(_ family: TranscriptFamily, reader: inout TranscriptReader) -> (lines: DecodedLines, read: FileTailer.ReadResult) {
        switch family {
        case .codex:
            let (lines, read) = extract(CodexLineExtractor.extract, reader: &reader)
            return (.codex(lines), read)
        case .claude:
            let (lines, read) = extract(ClaudeLineExtractor.extract, reader: &reader)
            return (.claude(lines), read)
        case .dsh:
            let (lines, read) = extract(DshLineExtractor.extract, reader: &reader)
            return (.dsh(lines), read)
        case .gemini:
            let extractor = reader.isDocument ? GeminiLineExtractor.extractDocument : GeminiLineExtractor.extract
            let (lines, read) = extract(extractor, reader: &reader)
            return (.gemini(lines), read)
        case .omp:
            let (lines, read) = extract(OmpLineExtractor.extract, reader: &reader)
            return (.omp(lines), read)
        case .antigravity:
            let (batch, read) = reader.readDatabase()
            return (.antigravity(batch), read)
        case .workbuddy, .workbuddyAi:
            let (lines, read) = extract(WorkBuddyLineExtractor.extract, reader: &reader)
            return (.workbuddy(lines), read)
        case .kimi:
            let (lines, read) = extract(KimiLineExtractor.extract, reader: &reader)
            return (.kimi(lines), read)
        case .grokBuild:
            let (lines, read) = extract(GrokBuildLine.extract, reader: &reader)
            return (.grokBuild(lines), read)
        }
    }

    private static func extract<Line: Sendable>(
        _ extractor: (UnsafeRawBufferPointer) -> LineExtraction<Line>,
        reader: inout TranscriptReader
    ) -> ([LineExtraction<Line>], FileTailer.ReadResult) {
        var lines: [LineExtraction<Line>] = []
        let read = reader.read(onMalformed: { lines.append(.malformed) }) { bytes in
            let extraction = extractor(bytes)
            if case .blank = extraction { return }
            lines.append(extraction)
        }
        return (lines, read)
    }
}
