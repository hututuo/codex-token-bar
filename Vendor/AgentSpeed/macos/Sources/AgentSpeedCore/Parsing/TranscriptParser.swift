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

/// A family-agnostic per-file parser. Exactly one of the machines is set.
struct TranscriptParser: Sendable {
    let family: TranscriptFamily
    private var codex: CodexParser?
    private var claude: ClaudeParser?
    private var dsh: DshParser?
    private var gemini: GeminiParser?
    private var omp: OmpParser?
    private var antigravity: AntigravityParser?
    private var workbuddy: WorkBuddyParser?
    private var kimi: KimiParser?
    private var grokBuild: GrokBuildParser?

    /// `root` is the root folder the file was discovered under (omp and WorkBuddy derive `isSubagent` from it,
    /// METRICS 4.7, 4.9).
    init(family: TranscriptFamily, agentId: String, fileID: FileID, root: String? = nil) {
        self.family = family
        switch family {
        case .codex: codex = CodexParser(agentId: agentId, fileID: fileID)
        case .claude: claude = ClaudeParser(agentId: agentId, fileID: fileID)
        case .dsh: dsh = DshParser(agentId: agentId, fileID: fileID)
        case .gemini: gemini = GeminiParser(agentId: agentId, fileID: fileID)
        case .omp: omp = OmpParser(agentId: agentId, fileID: fileID, root: root)
        case .antigravity: antigravity = AntigravityParser(agentId: agentId, fileID: fileID)
        case .workbuddy, .workbuddyAi:
            workbuddy = WorkBuddyParser(source: family.sources[0], agentId: agentId, fileID: fileID, root: root)
        case .kimi: kimi = KimiParser(agentId: agentId, fileID: fileID)
        case .grokBuild: grokBuild = GrokBuildParser(agentId: agentId, fileID: fileID)
        }
    }

    var state: AgentState {
        codex?.state ?? claude?.state ?? dsh?.state ?? gemini?.state ?? omp?.state ?? workbuddy?.state ?? kimi?.state ?? grokBuild?.state ?? antigravity!.state
    }

    /// An Antigravity database without the expected tables (`unsupportedFormat`).
    var isUnsupported: Bool { antigravity?.isUnsupported ?? false }

    /// Decodes one unit of input: a line, or a whole document for Gemini CLI legacy `.json` files. Antigravity
    /// databases are never fed bytes; their reads arrive as batches.
    func decode(_ bytes: UnsafeRawBufferPointer) -> DecodedLine? {
        switch family {
        case .codex: .codex(CodexLineExtractor.extract(bytes))
        case .claude: .claude(ClaudeLineExtractor.extract(bytes))
        case .dsh: .dsh(DshLineExtractor.extract(bytes))
        case .gemini:
            .gemini(gemini?.isDocument == true ? GeminiLineExtractor.extractDocument(bytes) : GeminiLineExtractor.extract(bytes))
        case .omp: .omp(OmpLineExtractor.extract(bytes))
        case .workbuddy, .workbuddyAi: .workbuddy(WorkBuddyLineExtractor.extract(bytes))
        case .antigravity: nil
        case .kimi: .kimi(KimiLineExtractor.extract(bytes))
        case .grokBuild: .grokBuild(GrokBuildLine.extract(bytes))
        }
    }

    var hasPartialHistory: Bool { grokBuild?.partialHistory ?? false }

    mutating func refreshMetadata(deduper: inout Deduper, emit: (ResponseUpsert) -> Void) -> Bool {
        grokBuild?.refreshMetadata(deduper: &deduper, emit: emit) ?? false
    }

    /// Counts a unit of input that could not be decoded at all, such as a corrupt zstd frame (METRICS 5.1).
    mutating func noteMalformedLine() {
        codex?.noteMalformedLine()
        claude?.noteMalformedLine()
        dsh?.noteMalformedLine()
        gemini?.noteMalformedLine()
        omp?.noteMalformedLine()
        antigravity?.noteMalformedLine()
        workbuddy?.noteMalformedLine()
        kimi?.noteMalformedLine()
        grokBuild?.noteMalformedLine()
    }

    mutating func consume(_ line: DecodedLine, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        switch line {
        case .codex(let extraction): codex?.consume(extraction, deduper: &deduper, emit: emit)
        case .claude(let extraction): claude?.consume(extraction, deduper: &deduper, emit: emit)
        case .dsh(let extraction): dsh?.consume(extraction, deduper: &deduper, emit: emit)
        case .gemini(let extraction): gemini?.consume(extraction, deduper: &deduper, emit: emit)
        case .omp(let extraction): omp?.consume(extraction, deduper: &deduper, emit: emit)
        case .workbuddy(let extraction): workbuddy?.consume(extraction, deduper: &deduper, emit: emit)
        case .kimi(let extraction): kimi?.consume(extraction, deduper: &deduper, emit: emit)
        case .grokBuild(let extraction): grokBuild?.consume(extraction, deduper: &deduper, emit: emit)
        }
    }

    mutating func consume(rawLine bytes: UnsafeRawBufferPointer, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        guard let line = decode(bytes) else { return }
        consume(line, deduper: &deduper, emit: emit)
    }

    mutating func consume(_ lines: DecodedLines, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        switch lines {
        case .codex(let extractions):
            for extraction in extractions { codex?.consume(extraction, deduper: &deduper, emit: emit) }
        case .claude(let extractions):
            for extraction in extractions { claude?.consume(extraction, deduper: &deduper, emit: emit) }
        case .dsh(let extractions):
            for extraction in extractions { dsh?.consume(extraction, deduper: &deduper, emit: emit) }
        case .gemini(let extractions):
            for extraction in extractions { gemini?.consume(extraction, deduper: &deduper, emit: emit) }
        case .omp(let extractions):
            for extraction in extractions { omp?.consume(extraction, deduper: &deduper, emit: emit) }
        case .antigravity(let batch):
            if let batch { antigravity?.consume(batch, deduper: &deduper, emit: emit) }
        case .workbuddy(let extractions):
            for extraction in extractions { workbuddy?.consume(extraction, deduper: &deduper, emit: emit) }
        case .kimi(let extractions):
            for extraction in extractions { kimi?.consume(extraction, deduper: &deduper, emit: emit) }
        case .grokBuild(let extractions):
            for extraction in extractions { grokBuild?.consume(extraction, deduper: &deduper, emit: emit) }
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
