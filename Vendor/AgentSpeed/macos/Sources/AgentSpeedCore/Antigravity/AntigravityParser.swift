import Foundation

/// Per-database Antigravity state machine (METRICS 4.8). Fed one batch per read: the complete first read, then the
/// rows of each incremental read. Responses are planner steps with a terminal status; the phase is a function of the
/// latest step and the executor rows read so far.
struct AntigravityParser: Sendable {
    /// Steps created this long before the conversation are copies made by a fork.
    static let copyToleranceMs: Int64 = 2000

    private struct LatestStep: Sendable {
        var idx: Int64
        var stepType: Int64
        var status: Int64
        var metadata: AntigravityStepMetadata
    }

    private struct Emitted: Sendable {
        var idx: Int64
        var record: ResponseRecord
    }

    let agentId: String
    let fileID: FileID
    /// The file name without `.db`.
    let conversationId: String
    private(set) var state: AgentState
    /// The last read found no `steps` table with the required columns (`unsupportedFormat`).
    private(set) var isUnsupported = false

    private var createdMs: Int64?
    private var trajectoryApplied = false
    private var latest: LatestStep?
    private var generations: [Int64: AntigravityGeneration] = [:]
    /// Step idx → the lowest `gen_metadata` idx whose `step_indices` contains it.
    private var generationOfStep: [UInt64: Int64] = [:]
    private var executors: [Int64: AntigravityExecutor] = [:]
    private var emitted: [String: Emitted] = [:]
    /// Step idx whose malformed metadata was counted by an earlier read (open rows are read again).
    private var malformedSteps: Set<Int64> = []

    init(agentId: String, fileID: FileID) {
        self.agentId = agentId
        self.fileID = fileID
        conversationId = String((agentId as NSString).lastPathComponent.dropLast(3))
        state = AgentState(source: .antigravity)
        state.thread = SessionThread(id: conversationId, parentId: nil, createdMs: 0)
    }

    mutating func noteMalformedLine() {
        state.malformedLines += 1
    }

    mutating func consume(_ batch: AntigravityBatch, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        isUnsupported = batch.unsupported
        guard !batch.unsupported else { return }
        if let trajectory = batch.trajectory, !trajectoryApplied {
            trajectoryApplied = true
            apply(trajectory)
        }
        var modelsChanged = false
        for row in batch.generations {
            guard let value = row.value else { continue }
            guard case .line(let generation) = value else {
                noteInvalid(value)
                continue
            }
            let replaced = generations.updateValue(generation, forKey: row.idx) != nil
            if replaced {
                rebuildGenerationIndex()
            } else {
                for step in generation.stepIndices where generationOfStep[step].map({ row.idx < $0 }) ?? true {
                    generationOfStep[step] = row.idx
                }
            }
            modelsChanged = true
        }
        for row in batch.executors {
            guard let value = row.value else { continue }
            guard case .line(let executor) = value else {
                noteInvalid(value)
                continue
            }
            executors[row.idx] = executor
            modelsChanged = true
        }
        var counted: Set<Int64> = []
        for row in batch.steps {
            guard let value = row.metadata else { continue }
            guard case .line(let metadata) = value else {
                if !malformedSteps.contains(row.idx) {
                    noteInvalid(value)
                    counted.insert(row.idx)
                }
                continue
            }
            step(row, metadata: metadata, deduper: &deduper, emit: emit)
        }
        malformedSteps.formUnion(counted)
        if modelsChanged { resolveModels(emit: emit) }
        updateAgentModel()
        updatePhase()
    }

    /// A blob that does not decode counts as one malformed line.
    private mutating func noteInvalid<Value>(_ extraction: LineExtraction<Value>) {
        if case .malformed = extraction { state.malformedLines += 1 }
    }

    private mutating func apply(_ extraction: LineExtraction<AntigravityTrajectory>) {
        guard case .line(let trajectory) = extraction else {
            noteInvalid(extraction)
            return
        }
        createdMs = trajectory.createdMs
        state.project = trajectory.project
        state.cwdPath = trajectory.cwdPath
        state.isSubagent = trajectory.isSubagent
        state.thread = SessionThread(id: conversationId, parentId: trajectory.parentConversationId, createdMs: createdMs ?? 0)
        if let createdMs { state.noteLine(at: createdMs) }
    }

    private mutating func step(
        _ row: AntigravityStepRow,
        metadata: AntigravityStepMetadata,
        deduper: inout Deduper,
        emit: (ResponseUpsert) -> Void
    ) {
        if let createdMs, let created = metadata.createdMs, created < createdMs - Self.copyToleranceMs { return }
        let times = metadata.timestamps
        for time in times { state.noteLine(at: time) }
        if latest.map({ row.idx >= $0.idx }) ?? true {
            latest = LatestStep(idx: row.idx, stepType: row.stepType, status: row.status, metadata: metadata)
        }
        guard row.stepType == AntigravityStep.plannerResponse, !AntigravityStep.isOpen(row.status),
              let usage = metadata.usage, usage.hasTokens else { return }
        let key = usage.key ?? "antigravity:\(conversationId):\(row.idx)"
        guard !deduper.isOwnedByOtherFile(key, for: fileID) else { return }
        var startMs = metadata.createdMs
        let endMs: Int64
        if let end = metadata.finishedGeneratingMs ?? metadata.lastCompletedChunkMs ?? metadata.completedMs {
            endMs = end
        } else {
            guard let latestTime = times.max() else { return }
            endMs = latestTime
            startMs = nil
        }
        if AntigravityStep.failedStatuses.contains(row.status) { startMs = nil }
        let claim = deduper.claim(key, for: fileID)
        let record = ResponseRecord(
            key: key, source: .antigravity, agentId: agentId, model: model(forStep: row.idx), startMs: startMs,
            endMs: endMs, usage: usage.tokens, isFinal: true
        )
        let previous = emitted[key]
        emitted[key] = Emitted(idx: row.idx, record: record)
        if previous?.record != record { emit(ResponseUpsert(record: record, isCompletion: claim == .new)) }
    }

    /// `chat_model.response_model` (else `model_display_name`) of the lowest generation listing the step, else the
    /// planner model of the executor run with the smallest `last_step_idx >=` the step (ties: lowest idx).
    private func model(forStep idx: Int64) -> String? {
        if idx >= 0, let generation = generationOfStep[UInt64(idx)].flatMap({ generations[$0] }), let model = generation.model {
            return model
        }
        var best: (last: Int64, idx: Int64, model: String?)?
        for (executorIdx, executor) in executors where executor.lastStepIdx >= idx {
            if let current = best, (current.last, current.idx) <= (executor.lastStepIdx, executorIdx) { continue }
            best = (executor.lastStepIdx, executorIdx, executor.model)
        }
        return best?.model ?? nil
    }

    private mutating func rebuildGenerationIndex() {
        generationOfStep = [:]
        for (idx, generation) in generations {
            for step in generation.stepIndices where generationOfStep[step].map({ idx < $0 }) ?? true {
                generationOfStep[step] = idx
            }
        }
    }

    /// A later read may name the model of an earlier response: the response is updated (METRICS 4.4).
    private mutating func resolveModels(emit: (ResponseUpsert) -> Void) {
        for (key, entry) in emitted.sorted(by: { ($0.value.idx, $0.key) < ($1.value.idx, $1.key) }) {
            let model = model(forStep: entry.idx)
            guard model != entry.record.model else { continue }
            var record = entry.record
            record.model = model
            emitted[key] = Emitted(idx: entry.idx, record: record)
            emit(ResponseUpsert(record: record, isCompletion: false))
        }
    }

    /// The model of the response with the highest idx that has one.
    private mutating func updateAgentModel() {
        var best: (idx: Int64, model: String)?
        for entry in emitted.values {
            guard let model = entry.record.model else { continue }
            if let current = best, current.idx > entry.idx || (current.idx == entry.idx && current.model <= model) { continue }
            best = (entry.idx, model)
        }
        state.model = best?.model
    }

    /// METRICS 4.8 Phase: a function of the latest step and the executor rows.
    private mutating func updatePhase() {
        let at = state.lastLineMs ?? 0
        guard let latest else {
            state.setPhase(.idle, at: at)
            return
        }
        if executors.values.contains(where: { $0.terminationReason != 0 && $0.lastStepIdx >= latest.idx }) {
            state.setPhase(.idle, at: at)
            return
        }
        let open = AntigravityStep.isOpen(latest.status)
        switch latest.stepType {
        case AntigravityStep.plannerResponse:
            if open {
                state.setPhase(.generating, at: at, inFlightStartMs: latest.metadata.createdMs)
            } else {
                state.setPhase(.idle, at: at)
            }
        case AntigravityStep.userInput:
            if AntigravityStep.failedStatuses.contains(latest.status) {
                state.setPhase(.idle, at: at)
            } else {
                state.setPhase(.generating, at: at, inFlightStartMs: latest.metadata.createdMs)
            }
        default:
            if open {
                state.setPhase(.tools, at: at)
            } else if latest.status == AntigravityStep.done {
                state.setPhase(.generating, at: at, inFlightStartMs: latest.metadata.completedMs ?? latest.metadata.createdMs)
            } else {
                state.setPhase(.idle, at: at)
            }
        }
    }
}
