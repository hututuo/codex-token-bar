import Foundation

/// Reads local agent transcripts on a background queue and publishes snapshots to a `SpeedStore`.
@MainActor
public final class LiveMonitor {
    public private(set) var configuration: MonitorConfiguration
    /// Source sets whose measured peak each snapshot reports in `subsetPeaks` (METRICS 6.8).
    public private(set) var subsets: Set<SourceSet> = []
    /// Prices every response (METRICS 9); nil leaves costs unknown.
    public let pricing: PriceBook?
    private let store: SpeedStore
    private let realtimeEventMode: Bool
    private var core: MonitorCore?
    private var mailbox: SnapshotMailbox?

    public init(
        store: SpeedStore,
        configuration: MonitorConfiguration = MonitorConfiguration(),
        pricing: PriceBook? = nil,
        realtimeEventMode: Bool = false
    ) {
        self.store = store
        self.configuration = configuration
        self.pricing = pricing
        self.realtimeEventMode = realtimeEventMode
    }

    /// True between `start()` and `stop()`.
    public var isRunning: Bool { core != nil }

    public func start() {
        guard core == nil else { return }
        let mailbox = SnapshotMailbox { [weak store] snapshot, events in
            store?.publishLive(snapshot, events: events)
        }
        let core = MonitorCore(
            configuration: configuration,
            mailbox: mailbox,
            subsets: subsets,
            pricing: pricing,
            realtimeEventMode: realtimeEventMode
        )
        self.mailbox = mailbox
        self.core = core
        core.start()
    }

    public func stop() {
        mailbox?.close()
        core?.stop()
        mailbox = nil
        core = nil
    }

    /// Requests `SpeedSnapshot.subsetPeaks` for these sets (one per floating orb that tracks a subset). Kept across
    /// restarts and configuration changes; a running monitor publishes a fresh snapshot promptly when they change.
    public func setSubsets(_ sets: Set<SourceSet>) {
        subsets = sets
        core?.setSubsets(sets)
    }

    /// Applies new settings; transcripts are read again when the roots or the enabled sources change.
    public func update(configuration: MonitorConfiguration) {
        let needsRescan = configuration.requiresRescan(comparedTo: self.configuration)
        self.configuration = configuration
        guard needsRescan, isRunning else { return }
        stop()
        start()
    }

    public nonisolated static var defaultCodexRoot: URL {
        TranscriptLocations.defaultCodexRoot
    }

    public nonisolated static var defaultClaudeRoot: URL {
        TranscriptLocations.defaultClaudeRoot
    }

    public nonisolated static var defaultZcodeRoot: URL { TranscriptLocations.defaultZcodeRoot }
    public nonisolated static var defaultKimiRoot: URL { TranscriptLocations.defaultKimiRoot }
    public nonisolated static var defaultGrokBuildRoot: URL { TranscriptLocations.defaultGrokBuildRoot }

    public nonisolated static var defaultDshRoot: URL {
        TranscriptLocations.defaultDshRoot
    }

    /// Gemini CLI's default `tmp` folders (a configured root replaces both).
    public nonisolated static var defaultGeminiRoots: [URL] {
        TranscriptLocations.defaultGeminiRoots
    }

    /// The folder that contains OpenCode's `opencode.db`.
    public nonisolated static var defaultOpencodeRoot: URL {
        TranscriptLocations.defaultOpencodeRoot
    }

    /// omp's automatic `sessions` roots: the default root first, then one per named profile (a configured root
    /// replaces all of them).
    public nonisolated static var defaultOmpRoots: [URL] {
        TranscriptLocations.defaultOmpRoots
    }

    /// omp's default `sessions` root (the first of `defaultOmpRoots`).
    public nonisolated static var defaultOmpRoot: URL {
        TranscriptLocations.defaultOmpRoots[0]
    }

    /// Antigravity's store folders, each containing `conversations` (a configured store replaces all three).
    public nonisolated static var defaultAntigravityStores: [URL] {
        TranscriptLocations.defaultAntigravityStores
    }

    /// WorkBuddy's data folder (`~/.workbuddy`, China edition); its `projects` folder holds the sessions.
    public nonisolated static var defaultWorkBuddyDataFolder: URL {
        TranscriptLocations.defaultWorkBuddyDataFolder
    }

    /// WorkBuddy AI's data folder (`~/.workbuddy-ai`, international edition).
    public nonisolated static var defaultWorkBuddyAiDataFolder: URL {
        TranscriptLocations.defaultWorkBuddyAiDataFolder
    }

    /// The `projects` folder a WorkBuddy folder setting reads: the folder itself when it is called `projects`.
    public nonisolated static func workbuddyProjectsFolder(_ folder: URL) -> URL {
        TranscriptLocations.workbuddyProjects(folder)
    }

    /// False for a `*-backup` store (or its `conversations` folder), which is never read.
    public nonisolated static func isReadableAntigravityStore(_ folder: URL) -> Bool {
        TranscriptLocations.isReadableAntigravityRoot(TranscriptLocations.antigravityConversations(folder).path)
    }
}
