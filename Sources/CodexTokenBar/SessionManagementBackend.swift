import CryptoKit
import Darwin
import Dispatch
import Foundation

protocol SessionManagementAppServerServing: Sendable {
    func listSessionManagementThreads(
        codexPath: String,
        dataSource: CodexDataSource?
    ) async throws -> [SessionManagementAppServerThread]

    func listSessionManagementDescendants(
        codexPath: String,
        dataSource: CodexDataSource?,
        ancestorThreadID: String
    ) async throws -> [SessionManagementAppServerThread]

    func readSessionManagementThreadStatus(
        codexPath: String,
        dataSource: CodexDataSource?,
        threadID: String
    ) async throws -> SessionManagementThreadStatus

    func archiveSessionManagementThread(
        codexPath: String,
        dataSource: CodexDataSource?,
        threadID: String
    ) async throws

    func unarchiveSessionManagementThread(
        codexPath: String,
        dataSource: CodexDataSource?,
        threadID: String
    ) async throws
}

extension CodexAppServerClient: SessionManagementAppServerServing {}

protocol SessionManagementOfficialDeleting: Sendable {
    func delete(
        codexPath: String,
        dataSource: CodexDataSource,
        threadID: String,
        prelaunchVerification: @escaping @Sendable () throws -> Void
    ) async throws -> String
}

protocol SessionManagementServicing: Sendable {
    func loadCatalog(dataSource: CodexDataSource) async throws -> SessionManagementCatalog
    func prepareDeletionConfirmation(
        selectedThreadIDs: Set<String>,
        dataSource: CodexDataSource
    ) async throws -> SessionManagementDeletionConfirmation
    func loadContextPage(
        thread: SessionManagementThread,
        dataSource: CodexDataSource,
        beforeOffset: Int64?,
        pageSize: Int
    ) async throws -> SessionManagementContextPage
    func archive(threadID: String, dataSource: CodexDataSource) async throws
    func unarchive(threadID: String, dataSource: CodexDataSource) async throws
    func delete(
        rootID: String,
        expectation: SessionManagementDeletionExpectation,
        recoveryPackages: [String: SessionManagementRecoveryPackageResult],
        dataSource: CodexDataSource
    ) async throws -> String
    func createRecoveryPackage(
        thread: SessionManagementThread,
        dataSource: CodexDataSource,
        expectedSnapshot: SessionManagementRolloutSnapshot?
    ) async throws -> SessionManagementRecoveryPackageResult
}

extension SessionManagementServicing {
    func createRecoveryPackage(
        thread: SessionManagementThread,
        dataSource: CodexDataSource
    ) async throws -> SessionManagementRecoveryPackageResult {
        try await createRecoveryPackage(
            thread: thread,
            dataSource: dataSource,
            expectedSnapshot: nil
        )
    }
}

enum SessionManagementBackendError: LocalizedError, Equatable {
    case databaseUnavailable
    case unsupportedSchema(String)
    case threadNotFound(String)
    case rolloutUnavailable(String)
    case rolloutUntrusted(String)
    case rolloutIdentityMismatch(String)
    case compressedContextUnsupported
    case mutationBlocked(SessionManagementThreadStatus)
    case externalWriterDetected([String])
    case liveDeletionRequiresArchive([String])
    case dataSourceIdentityUnavailable
    case dataSourceIdentityChanged
    case autoResumeStateUnavailable(String)
    case autoResumeProtected(String)
    case concurrentMutation
    case coordinationUnavailable(String)
    case deletionScopeChanged(String)
    case recoveryEvidenceMismatch(String)
    case recoverySourceUnsafe
    case recoveryPackageFailed(String)
    case officialDeleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return "Codex 会话数据库不可用"
        case .unsupportedSchema(let detail):
            return "当前 Codex 会话数据库结构不受支持：\(detail)"
        case .threadNotFound(let id):
            return "未找到会话：\(id)"
        case .rolloutUnavailable(let path):
            return "会话正文文件不可用：\(path)"
        case .rolloutUntrusted(let path):
            return "会话正文不在当前 Codex 数据目录内：\(path)"
        case .rolloutIdentityMismatch(let id):
            return "会话正文首行身份与目标会话不一致：\(id)"
        case .compressedContextUnsupported:
            return "该旧会话正文仍是 zstd 压缩格式，当前版本只显示元数据；不会为了展示而解压或改写原文件。"
        case .mutationBlocked(let status):
            if status == .idle || status == .loaded {
                return "会话仍被 Codex 加载（\(status.label)），已暂停归档或删除；退出对应 Codex writer 后刷新再试。"
            }
            return "会话当前状态为“\(status.label)”，已暂停归档或删除。"
        case .externalWriterDetected(let writers):
            return "目标会话文件可能正在被其他进程使用，危险操作已关闭。检测到：\(writers.joined(separator: "、"))"
        case .liveDeletionRequiresArchive(let ids):
            return "Codex 仍在运行；为冻结会话谱系，本次范围中的未归档会话需先官方归档再删除：\(ids.joined(separator: "、"))"
        case .dataSourceIdentityUnavailable:
            return "无法绑定 Codex 数据目录的物理身份，危险操作已安全关闭。"
        case .dataSourceIdentityChanged:
            return "Codex 数据目录的物理身份已变化，危险操作已安全关闭；请重新选择目录并刷新。"
        case .autoResumeStateUnavailable(let detail):
            return "无法确认自动续跑保护状态，危险操作已安全关闭：\(detail)"
        case .autoResumeProtected(let id):
            return "会话 \(id) 已被启用的自动续跑任务保护，危险操作已暂停。"
        case .concurrentMutation:
            return "另一个会话归档、恢复、删除或打包操作正在执行，本次操作已暂停。"
        case .coordinationUnavailable(let detail):
            return "无法取得会话写操作的跨进程协调锁，危险操作已安全关闭：\(detail)"
        case .deletionScopeChanged(let detail):
            return "官方递归删除范围与已确认范围不一致，整批删除已停止：\(detail)"
        case .recoveryEvidenceMismatch(let id):
            return "会话 \(id) 的正文或恢复包已不再与删除前快照一致，整批删除已停止。"
        case .recoverySourceUnsafe:
            return "深度压缩恢复包只允许从未被 Codex 加载、身份完整且允许删除的会话创建。"
        case .recoveryPackageFailed(let detail):
            return "创建深度压缩恢复包失败：\(detail)"
        case .officialDeleteFailed(let detail):
            return "Codex 官方删除失败：\(detail)"
        }
    }
}

private final class SessionManagementMutationLease: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 1)

    func acquire() -> Bool {
        semaphore.wait(timeout: .now()) == .success
    }

    func release() {
        semaphore.signal()
    }
}

private final class SessionManagementCoordinationLease: @unchecked Sendable {
    private let homeDirectory: ProviderSyncHomeDirectory
    private let crossProcessLock: CodexCrossProcessFileLock
    private var threadLeases: [AutoResumeThreadLease] = []
    private var released = false

    init(
        dataSource: CodexDataSource,
        ownerID: String
    ) throws {
        guard let expectedHomeIdentity = dataSource.homeIdentity else {
            throw SessionManagementBackendError.dataSourceIdentityUnavailable
        }
        let canonicalHome = dataSource.codexHome.standardizedFileURL
            .resolvingSymlinksInPath()
        homeDirectory = try ProviderSyncHomeDirectory(
            canonicalURL: canonicalHome,
            expectedHomeIdentity: expectedHomeIdentity
        )
        do {
            let pinnedLock = try homeDirectory.pinFile(
                relativePath: FoundationSessionManagementBackend
                    .crossProcessLockRelativePath,
                createParents: true
            )
            crossProcessLock = try CodexCrossProcessFileLock(
                parentDirectoryDescriptor: pinnedLock.parent.rawValue,
                fileName: pinnedLock.name,
                label: "当前 Codex Home 的会话写操作"
            )
        } catch {
            try? homeDirectory.close()
            if CodexCrossProcessFileLock.isContention(error) {
                throw SessionManagementBackendError.concurrentMutation
            }
            throw SessionManagementBackendError.coordinationUnavailable(
                error.localizedDescription
            )
        }
        _ = ownerID
    }

    func acquireAutoResumeLeases(
        threadIDs: [String],
        codexHome: URL,
        ownerID: String
    ) throws {
        let coordinator = AutoResumeSharedCoordinator(
            codexHome: codexHome,
            ownerID: ownerID
        )
        for threadID in Array(Set(threadIDs)).sorted() {
            let lease: AutoResumeThreadLease?
            do {
                lease = try coordinator.acquireThreadLease(threadID: threadID)
            } catch {
                throw SessionManagementBackendError.autoResumeStateUnavailable(
                    error.localizedDescription
                )
            }
            guard let lease else {
                throw SessionManagementBackendError.autoResumeProtected(threadID)
            }
            threadLeases.append(lease)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        for lease in threadLeases.reversed() {
            lease.release()
        }
        threadLeases.removeAll()
        crossProcessLock.release()
        try? homeDirectory.close()
    }

    deinit {
        release()
    }
}

final class FoundationSessionManagementOfficialDeleteExecutor: SessionManagementOfficialDeleting, @unchecked Sendable {
    private let timeout: TimeInterval
    private let mutationGate: @Sendable () throws -> Void

    init(
        timeout: TimeInterval = 6 * 60 * 60,
        mutationGate: @escaping @Sendable () throws -> Void = {
            try CodexMultiInstanceMutationGate.ensureNoActiveNonDefaultInstance()
        }
    ) {
        self.timeout = timeout
        self.mutationGate = mutationGate
    }

    func delete(
        codexPath: String,
        dataSource: CodexDataSource,
        threadID: String,
        prelaunchVerification: @escaping @Sendable () throws -> Void
    ) async throws -> String {
        try CodexThreadID.validate(threadID)
        return try await Task.detached(priority: .userInitiated) { [timeout, mutationGate] in
            try mutationGate()
            try prelaunchVerification()
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = dataSource.codexHome.path
            let result = try CodexThreadDeleteSubprocess.run(
                executableURL: URL(fileURLWithPath: codexPath),
                arguments: ["delete", "--force", threadID],
                environment: environment,
                timeout: timeout
            )
            guard result.terminationStatus == 0 else {
                throw SessionManagementBackendError.officialDeleteFailed(
                    result.stderr.isEmpty ? result.stdout : result.stderr
                )
            }
            return result.stdout.isEmpty ? "会话已由 Codex 官方命令永久删除" : result.stdout
        }.value
    }
}

final class FoundationSessionManagementBackend: SessionManagementServicing, @unchecked Sendable {
    private static let mutationLease = SessionManagementMutationLease()
    static let crossProcessLockRelativePath =
        "backups_state/codex-token-bar/session-operation.lock"
    static let recoveryPackageAnchorRelativePath =
        "backups_state/codex-token-bar/session-recovery/.directory-anchor"

    private let appServer: any SessionManagementAppServerServing
    private let officialDelete: any SessionManagementOfficialDeleting
    private let codexBinaryProvider: @Sendable () throws -> String
    private let mutationGate: @Sendable () throws -> Void
    private let externalWriterDetector: @Sendable () -> [String]
    private let openFileHoldersDetector: @Sendable (String) throws -> [Int32]
    private let autoResumeProtectedThreadIDsProvider: @Sendable () throws -> Set<String>
    private let fileManager: FileManager
    private let coordinationOwnerID =
        "session-management-backend-\(UUID().uuidString.lowercased())-\(ProcessInfo.processInfo.processIdentifier)"

    init(
        appServer: any SessionManagementAppServerServing = CodexAppServerClient(),
        officialDelete: any SessionManagementOfficialDeleting =
            FoundationSessionManagementOfficialDeleteExecutor(),
        codexBinaryProvider: @escaping @Sendable () throws -> String = {
            try CodexBinaryLocator.findExecutable()
        },
        mutationGate: @escaping @Sendable () throws -> Void = {
            try CodexMultiInstanceMutationGate.ensureNoActiveNonDefaultInstance()
        },
        externalWriterDetector: @escaping @Sendable () -> [String] = {
            SessionManagementExternalWriterGate.runningWriters()
        },
        openFileHoldersDetector: @escaping @Sendable (String) throws -> [Int32] = {
            try CodexInstanceEngine.processesHoldingFileOpen(atPath: $0)
        },
        autoResumeProtectedThreadIDsProvider: @escaping @Sendable () throws -> Set<String> = {
            guard let data = UserDefaults.standard.data(
                forKey: AutoResumeTaskManager.collectionStorageKey
            ) else {
                return []
            }
            do {
                let collection = try JSONDecoder()
                    .decode(AutoResumeTaskCollection.self, from: data)
                    .normalized
                return Set(collection.tasks.compactMap {
                    guard $0.configuration.enabled else { return nil }
                    return $0.configuration.target?.id
                })
            } catch {
                throw SessionManagementBackendError.autoResumeStateUnavailable(
                    error.localizedDescription
                )
            }
        },
        fileManager: FileManager = .default
    ) {
        self.appServer = appServer
        self.officialDelete = officialDelete
        self.codexBinaryProvider = codexBinaryProvider
        self.mutationGate = mutationGate
        self.externalWriterDetector = externalWriterDetector
        self.openFileHoldersDetector = openFileHoldersDetector
        self.autoResumeProtectedThreadIDsProvider = autoResumeProtectedThreadIDsProvider
        self.fileManager = fileManager
    }

    func loadCatalog(dataSource: CodexDataSource) async throws -> SessionManagementCatalog {
        try ensureDataSourceIdentity(dataSource)
        let local = try await Task.detached(priority: .utility) {
            try Self.readLocalThreads(
                dataSource: dataSource,
                fileManager: self.fileManager
            )
        }.value

        var warnings = local.warnings
        var deletionVerificationComplete = local.verificationComplete
        var liveThreads: [SessionManagementAppServerThread] = []
        var officialMutationsAvailable = false
        do {
            let codexPath = try codexBinaryProvider()
            liveThreads = try await appServer.listSessionManagementThreads(
                codexPath: codexPath,
                dataSource: dataSource
            )
            officialMutationsAvailable = true
        } catch {
            deletionVerificationComplete = false
            warnings.append(
                "Codex App Server 运行态读取失败；目录仍可浏览，但官方归档、恢复和删除已关闭：\(error.localizedDescription)"
            )
        }
        let liveDeletionRequiresArchive = !externalWriterDetector().isEmpty
        if liveDeletionRequiresArchive {
            warnings.append(
                "Codex 正在运行：已归档且未加载的会话仍可删除；未归档会话请先执行官方归档。"
            )
        }
        let protectedThreadIDs: Set<String>
        do {
            protectedThreadIDs = try autoResumeProtectedThreadIDsProvider()
        } catch {
            protectedThreadIDs = []
            officialMutationsAvailable = false
            deletionVerificationComplete = false
            warnings.append(error.localizedDescription)
        }

        var threads = Self.mergeAndEnrich(
            local: local.threads,
            appServer: liveThreads,
            officialMutationsAvailable: officialMutationsAvailable,
            liveDeletionRequiresArchive: liveDeletionRequiresArchive,
            autoResumeProtectedThreadIDs: protectedThreadIDs
        )
        threads.sort {
            ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast)
        }
        try ensureDataSourceIdentity(dataSource)
        return SessionManagementCatalog(
            threads: threads,
            generatedAt: Date(),
            codexHome: dataSource.displayPath,
            totalBytes: threads.allSatisfy { $0.fileBytes != nil }
                ? threads.reduce(0) { $0 + max(0, $1.fileBytes ?? 0) }
                : nil,
            warnings: warnings,
            capabilities: SessionManagementCapabilities(
                canOfficialMutate: officialMutationsAvailable,
                canCreateRecoveryPackage: true,
                canRestoreRecoveryPackage: false,
                recoveryRestoreUnavailableReason:
                    "Codex 当前没有官方会话导入接口；恢复功能在能够安全重建官方索引前保持关闭。"
            ),
            deletionVerificationComplete: deletionVerificationComplete
        )
    }

    func prepareDeletionConfirmation(
        selectedThreadIDs: Set<String>,
        dataSource: CodexDataSource
    ) async throws -> SessionManagementDeletionConfirmation {
        guard !selectedThreadIDs.isEmpty else {
            throw SessionManagementBackendError.deletionScopeChanged(
                "没有可确认的删除会话"
            )
        }
        guard Self.mutationLease.acquire() else {
            throw SessionManagementBackendError.concurrentMutation
        }
        defer { Self.mutationLease.release() }
        try ensureDataSourceIdentity(dataSource)
        let coordination = try acquireCoordination(dataSource: dataSource)
        defer { coordination.release() }
        try mutationGate()
        try ensureRolloutRootsTrusted(dataSource)

        let initialCatalog = try await loadCatalog(dataSource: dataSource)
        guard initialCatalog.deletionVerificationComplete else {
            throw SessionManagementBackendError.deletionScopeChanged(
                "确认前官方与本地会话目录读取不完整"
            )
        }
        let initialImpact = SessionManagementPresentation.deletionImpact(
            threads: initialCatalog.threads,
            selectedThreadIDs: selectedThreadIDs
        )
        guard !initialImpact.effectiveRoots.isEmpty,
              Set(initialImpact.requested.map(\.id)) == selectedThreadIDs else {
            throw SessionManagementBackendError.deletionScopeChanged(
                "所选会话已从严格目录消失"
            )
        }
        try ensureLiveDeletionScopeAllowed(initialImpact.affected)
        if let blocked = initialImpact.affected.first(where: {
            !$0.status.permitsMutation
                || !$0.rolloutIdentityVerified
                || !$0.canDelete
        }) {
            throw SessionManagementBackendError.deletionScopeChanged(
                "受影响会话 \(blocked.id) 未通过删除安全门禁"
            )
        }
        try coordination.acquireAutoResumeLeases(
            threadIDs: initialImpact.affected.map(\.id),
            codexHome: dataSource.codexHome,
            ownerID: coordinationOwnerID
        )
        let codexPath = try codexBinaryProvider()
        for affected in initialImpact.affected {
            let status = try await appServer.readSessionManagementThreadStatus(
                codexPath: codexPath,
                dataSource: dataSource,
                threadID: affected.id
            )
            guard status.permitsMutation else {
                throw SessionManagementBackendError.mutationBlocked(status)
            }
            try ensureAutoResumeNotProtected(affected.id)
            try ensureRolloutNotOpenElsewhere(
                threadID: affected.id,
                dataSource: dataSource
            )
        }
        guard let homeIdentity = dataSource.homeIdentity else {
            throw SessionManagementBackendError.dataSourceIdentityUnavailable
        }
        let snapshots = try await Task.detached(priority: .userInitiated) {
            var byID: [String: SessionManagementRolloutSnapshot] = [:]
            byID.reserveCapacity(initialImpact.affected.count)
            for thread in initialImpact.affected {
                try Task.checkCancellation()
                let snapshot = try Self.captureRolloutSnapshot(
                    thread: thread,
                    dataSource: dataSource,
                    fileManager: self.fileManager
                )
                guard byID.updateValue(snapshot, forKey: thread.id) == nil else {
                    throw SessionManagementBackendError.deletionScopeChanged(
                        "确认范围包含重复会话 \(thread.id)"
                    )
                }
            }
            return byID
        }.value

        let finalCatalog = try await loadCatalog(dataSource: dataSource)
        guard finalCatalog.deletionVerificationComplete else {
            throw SessionManagementBackendError.deletionScopeChanged(
                "快照完成后的官方与本地会话目录读取不完整"
            )
        }
        let finalImpact = SessionManagementPresentation.deletionImpact(
            threads: finalCatalog.threads,
            selectedThreadIDs: selectedThreadIDs
        )
        try ensureLiveDeletionScopeAllowed(finalImpact.affected)
        guard Self.deletionScopeMatches(finalImpact, initialImpact),
              finalImpact.affected.allSatisfy({
                  $0.status.permitsMutation
                      && $0.rolloutIdentityVerified
                      && $0.canDelete
              }) else {
            throw SessionManagementBackendError.deletionScopeChanged(
                "建立确认快照期间递归影响范围或安全状态发生变化"
            )
        }
        try await Task.detached(priority: .userInitiated) {
            for thread in finalImpact.affected {
                guard let snapshot = snapshots[thread.id] else {
                    throw SessionManagementBackendError.deletionScopeChanged(
                        "确认快照遗漏会话 \(thread.id)"
                    )
                }
                try Self.verifyRolloutSnapshot(
                    snapshot,
                    thread: thread,
                    dataSource: dataSource,
                    fileManager: self.fileManager
                )
            }
        }.value
        try ensureDataSourceIdentity(dataSource)
        return SessionManagementDeletionConfirmation(
            impact: finalImpact,
            codexHomeIdentity: homeIdentity,
            rolloutSnapshotsByThreadID: snapshots
        )
    }

    func loadContextPage(
        thread: SessionManagementThread,
        dataSource: CodexDataSource,
        beforeOffset: Int64?,
        pageSize: Int
    ) async throws -> SessionManagementContextPage {
        try await Task.detached(priority: .userInitiated) {
            try await Self.readContextPage(
                thread: thread,
                dataSource: dataSource,
                beforeOffset: beforeOffset,
                pageSize: max(1, pageSize),
                fileManager: self.fileManager
            )
        }.value
    }

    func archive(threadID: String, dataSource: CodexDataSource) async throws {
        guard Self.mutationLease.acquire() else {
            throw SessionManagementBackendError.concurrentMutation
        }
        defer { Self.mutationLease.release() }
        try ensureDataSourceIdentity(dataSource)
        let coordination = try acquireCoordination(dataSource: dataSource)
        defer { coordination.release() }
        try coordination.acquireAutoResumeLeases(
            threadIDs: [threadID],
            codexHome: dataSource.codexHome,
            ownerID: coordinationOwnerID
        )
        try mutationGate()
        try ensureRolloutRootsTrusted(dataSource)
        try ensureAutoResumeNotProtected(threadID)
        try ensureRolloutNotOpenElsewhere(threadID: threadID, dataSource: dataSource)
        try ensureDataSourceIdentity(dataSource)
        let codexPath = try codexBinaryProvider()
        try await appServer.archiveSessionManagementThread(
            codexPath: codexPath,
            dataSource: dataSource,
            threadID: threadID
        )
        try ensureDataSourceIdentity(dataSource)
    }

    func unarchive(threadID: String, dataSource: CodexDataSource) async throws {
        guard Self.mutationLease.acquire() else {
            throw SessionManagementBackendError.concurrentMutation
        }
        defer { Self.mutationLease.release() }
        try ensureDataSourceIdentity(dataSource)
        let coordination = try acquireCoordination(dataSource: dataSource)
        defer { coordination.release() }
        try coordination.acquireAutoResumeLeases(
            threadIDs: [threadID],
            codexHome: dataSource.codexHome,
            ownerID: coordinationOwnerID
        )
        try mutationGate()
        try ensureRolloutRootsTrusted(dataSource)
        try ensureAutoResumeNotProtected(threadID)
        try ensureRolloutNotOpenElsewhere(threadID: threadID, dataSource: dataSource)
        try ensureDataSourceIdentity(dataSource)
        let codexPath = try codexBinaryProvider()
        try await appServer.unarchiveSessionManagementThread(
            codexPath: codexPath,
            dataSource: dataSource,
            threadID: threadID
        )
        try ensureDataSourceIdentity(dataSource)
    }

    func delete(
        rootID: String,
        expectation: SessionManagementDeletionExpectation,
        recoveryPackages: [String: SessionManagementRecoveryPackageResult],
        dataSource: CodexDataSource
    ) async throws -> String {
        guard Self.mutationLease.acquire() else {
            throw SessionManagementBackendError.concurrentMutation
        }
        defer { Self.mutationLease.release() }
        guard expectation.currentRootID == rootID,
              expectation.pendingRootIDs.first == rootID,
              expectation.confirmedRootIDs.contains(rootID),
              !expectation.pendingAffectedThreadIDs.isEmpty else {
            throw SessionManagementBackendError.deletionScopeChanged(
                "当前删除根没有与确认计划绑定"
            )
        }
        guard expectation.requiresRecoveryEvidence else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(rootID)
        }
        guard dataSource.homeIdentity == expectation.codexHomeIdentity,
              Set(expectation.rolloutSnapshotsByThreadID.keys)
                == Set(expectation.confirmedAffectedThreadIDs),
              expectation.rolloutSnapshotsByThreadID.allSatisfy({
                  $0.key == $0.value.threadID
              }) else {
            throw SessionManagementBackendError.deletionScopeChanged(
                "确认时 Codex Home 或 rollout 快照绑定不完整"
            )
        }
        try ensureDataSourceIdentity(dataSource)
        let coordination = try acquireCoordination(dataSource: dataSource)
        defer { coordination.release() }
        try mutationGate()
        try ensureRolloutRootsTrusted(dataSource)
        let codexPath = try codexBinaryProvider()
        let validated = try await validateDeletionExpectation(
            expectation,
            codexPath: codexPath,
            dataSource: dataSource
        )
        try ensureLiveDeletionScopeAllowed(validated.pendingAffected)
        try coordination.acquireAutoResumeLeases(
            threadIDs: expectation.pendingAffectedThreadIDs,
            codexHome: dataSource.codexHome,
            ownerID: coordinationOwnerID
        )
        for affected in validated.pendingAffected {
            let freshStatus = try await appServer.readSessionManagementThreadStatus(
                codexPath: codexPath,
                dataSource: dataSource,
                threadID: affected.id
            )
            guard freshStatus.permitsMutation else {
                throw SessionManagementBackendError.mutationBlocked(freshStatus)
            }
            guard affected.rolloutIdentityVerified else {
                throw SessionManagementBackendError.rolloutIdentityMismatch(affected.id)
            }
            try ensureAutoResumeNotProtected(affected.id)
            try ensureRolloutNotOpenElsewhere(
                threadID: affected.id,
                dataSource: dataSource
            )
        }
        let finalValidated = try await validateDeletionExpectation(
            expectation,
            codexPath: codexPath,
            dataSource: dataSource
        )
        try ensureLiveDeletionScopeAllowed(finalValidated.pendingAffected)
        for affected in finalValidated.pendingAffected {
            guard let recovery = recoveryPackages[affected.id] else {
                throw SessionManagementBackendError.recoveryEvidenceMismatch(
                    affected.id
                )
            }
            try Self.verifyRecoveryEvidence(
                recovery,
                thread: affected,
                expectedSnapshot:
                    expectation.rolloutSnapshotsByThreadID[affected.id],
                dataSource: dataSource,
                fileManager: fileManager
            )
        }
        for affected in finalValidated.pendingAffected {
            let finalStatus = try await appServer.readSessionManagementThreadStatus(
                codexPath: codexPath,
                dataSource: dataSource,
                threadID: affected.id
            )
            guard finalStatus.permitsMutation else {
                throw SessionManagementBackendError.mutationBlocked(finalStatus)
            }
            try ensureRolloutNotOpenElsewhere(
                threadID: affected.id,
                dataSource: dataSource
            )
        }
        let evidenceLease = try Self.pinDeletionEvidence(
            pendingAffected: finalValidated.pendingAffected,
            expectation: expectation,
            recoveryPackages: recoveryPackages,
            dataSource: dataSource,
            fileManager: fileManager
        )
        defer { evidenceLease.close() }
        try ensureDataSourceIdentity(dataSource)
        let result = try await officialDelete.delete(
            codexPath: codexPath,
            dataSource: dataSource,
            threadID: rootID,
            prelaunchVerification: {
                try evidenceLease.verifyBeforeDelete(fileManager: self.fileManager)
                try self.ensureLiveDeletionScopeAllowed(
                    finalValidated.pendingAffected
                )
                for affected in finalValidated.pendingAffected {
                    try self.ensureRolloutNotOpenElsewhere(
                        threadID: affected.id,
                        dataSource: dataSource
                    )
                }
            }
        )
        try evidenceLease.verifyAfterDelete(fileManager: fileManager)
        try ensureDataSourceIdentity(dataSource)
        return result
    }

    private struct ValidatedDeletionExpectation {
        let pendingAffected: [SessionManagementThread]
    }

    private func acquireCoordination(
        dataSource: CodexDataSource
    ) throws -> SessionManagementCoordinationLease {
        do {
            return try SessionManagementCoordinationLease(
                dataSource: dataSource,
                ownerID: coordinationOwnerID
            )
        } catch let error as SessionManagementBackendError {
            throw error
        } catch {
            throw SessionManagementBackendError.coordinationUnavailable(
                error.localizedDescription
            )
        }
    }

    private func validateDeletionExpectation(
        _ expectation: SessionManagementDeletionExpectation,
        codexPath: String,
        dataSource: CodexDataSource
    ) async throws -> ValidatedDeletionExpectation {
        let confirmedRoots = expectation.confirmedRootIDs
        let confirmedAffected = expectation.confirmedAffectedThreadIDs
        let pendingRoots = expectation.pendingRootIDs
        let pendingAffected = expectation.pendingAffectedThreadIDs
        guard Set(confirmedRoots).count == confirmedRoots.count,
              Set(confirmedAffected).count == confirmedAffected.count,
              Set(pendingRoots).count == pendingRoots.count,
              Set(pendingAffected).count == pendingAffected.count,
              !pendingRoots.isEmpty,
              pendingRoots.first == expectation.currentRootID,
              Set(pendingRoots).isSubset(of: Set(confirmedRoots)),
              Set(pendingAffected).isSubset(of: Set(confirmedAffected)),
              Set(expectation.affectedThreadIDsByRootID.keys)
                == Set(confirmedRoots),
              Set(expectation.affectedThreadIDsByRootID.values.flatMap { $0 })
                == Set(confirmedAffected),
              Set(expectation.rolloutSnapshotsByThreadID.keys)
                == Set(confirmedAffected),
              expectation.rolloutSnapshotsByThreadID.allSatisfy({
                  $0.key == $0.value.threadID
              }),
              dataSource.homeIdentity == expectation.codexHomeIdentity else {
            throw SessionManagementBackendError.deletionScopeChanged(
                "确认计划内部不一致"
            )
        }
        let derivedPendingAffected = expectation.affectedThreadIDsByRootID
            .filter { Set(pendingRoots).contains($0.key) }
            .values
            .flatMap { $0 }
        guard Set(derivedPendingAffected) == Set(pendingAffected) else {
            throw SessionManagementBackendError.deletionScopeChanged(
                "待执行根与待影响会话映射不一致"
            )
        }

        let local = try await Task.detached(priority: .userInitiated) {
            try Self.readLocalThreads(
                dataSource: dataSource,
                fileManager: self.fileManager
            )
        }.value
        guard local.verificationComplete else {
            throw SessionManagementBackendError.deletionScopeChanged(
                "本地只读会话目录不完整"
            )
        }
        let localByID = Dictionary(
            uniqueKeysWithValues: local.threads.map { ($0.id, $0) }
        )
        let officialRows = try await appServer.listSessionManagementThreads(
            codexPath: codexPath,
            dataSource: dataSource
        )
        let officialByID = try Self.uniqueOfficialThreadMap(officialRows)

        let completedAffected = Set(confirmedAffected)
            .subtracting(pendingAffected)
        if let reappeared = completedAffected.sorted().first(where: {
            localByID[$0] != nil || officialByID[$0] != nil
        }) {
            throw SessionManagementBackendError.deletionScopeChanged(
                "此前删除根的闭包仍包含或重新出现会话 \(reappeared)"
            )
        }

        let localImpact = SessionManagementPresentation.deletionImpact(
            threads: local.threads,
            selectedThreadIDs: Set(pendingRoots)
        )
        guard Set(localImpact.effectiveRoots.map(\.id)) == Set(pendingRoots),
              Set(localImpact.affected.map(\.id)) == Set(pendingAffected) else {
            throw SessionManagementBackendError.deletionScopeChanged(
                "本地 rollout parent 闭包已变化"
            )
        }
        for rootID in pendingRoots {
            let expectedForRoot = Set(
                expectation.affectedThreadIDsByRootID[rootID] ?? []
            )
            let localForRoot = Set(localImpact.affected.compactMap {
                localImpact.coveringRootIDByThreadID[$0.id] == rootID
                    ? $0.id
                    : nil
            })
            guard !expectedForRoot.isEmpty,
                  expectedForRoot.contains(rootID),
                  localForRoot == expectedForRoot,
                  localByID[rootID] != nil,
                  officialByID[rootID] != nil else {
                throw SessionManagementBackendError.deletionScopeChanged(
                    "删除根 \(rootID) 的本地或官方身份已变化"
                )
            }

            let descendants = try await appServer.listSessionManagementDescendants(
                codexPath: codexPath,
                dataSource: dataSource,
                ancestorThreadID: rootID
            )
            let descendantByID = try Self.uniqueOfficialThreadMap(descendants)
            let officialQueryIDs = Set(descendantByID.keys).union([rootID])
            guard officialQueryIDs == expectedForRoot else {
                throw SessionManagementBackendError.deletionScopeChanged(
                    "thread/list ancestorThreadId 对 \(rootID) 返回了不同闭包"
                )
            }

            let officialGraphIDs = Self.officialDescendantClosure(
                rootID: rootID,
                threadsByID: officialByID
            )
            guard officialGraphIDs == expectedForRoot else {
                throw SessionManagementBackendError.deletionScopeChanged(
                    "官方完整列表与 ancestorThreadId 闭包不一致"
                )
            }

            for threadID in expectedForRoot {
                guard let localThread = localByID[threadID],
                      let officialThread = officialByID[threadID] else {
                    throw SessionManagementBackendError.deletionScopeChanged(
                        "官方闭包包含本地未知会话 \(threadID)"
                    )
                }
                if threadID != rootID,
                   descendantByID[threadID] == nil {
                    throw SessionManagementBackendError.deletionScopeChanged(
                        "ancestorThreadId 遗漏会话 \(threadID)"
                    )
                }
                guard localThread.parentThreadID
                        == officialThread.parentThreadID else {
                    throw SessionManagementBackendError.deletionScopeChanged(
                        "会话 \(threadID) 的本地 parent 与官方 parent 不一致"
                    )
                }
                guard localThread.rolloutIdentityVerified else {
                    throw SessionManagementBackendError.rolloutIdentityMismatch(
                        threadID
                    )
                }
                guard let expectedSnapshot =
                        expectation.rolloutSnapshotsByThreadID[threadID] else {
                    throw SessionManagementBackendError.deletionScopeChanged(
                        "会话 \(threadID) 缺少确认时 rollout 快照"
                    )
                }
                try Self.verifyRolloutSnapshot(
                    expectedSnapshot,
                    thread: localThread,
                    dataSource: dataSource,
                    fileManager: fileManager
                )
            }
        }
        let rows = pendingAffected.compactMap { localByID[$0] }
        guard rows.count == pendingAffected.count else {
            throw SessionManagementBackendError.deletionScopeChanged(
                "待删除闭包包含本地未知会话"
            )
        }
        return ValidatedDeletionExpectation(pendingAffected: rows)
    }

    private static func uniqueOfficialThreadMap(
        _ rows: [SessionManagementAppServerThread]
    ) throws -> [String: SessionManagementAppServerThread] {
        var byID: [String: SessionManagementAppServerThread] = [:]
        for row in rows {
            if byID[row.id] != nil {
                throw SessionManagementBackendError.deletionScopeChanged(
                    "官方列表对会话 \(row.id) 返回重复记录"
                )
            }
            byID[row.id] = row
        }
        return byID
    }

    private static func officialDescendantClosure(
        rootID: String,
        threadsByID: [String: SessionManagementAppServerThread]
    ) -> Set<String> {
        var childrenByParent: [String: [String]] = [:]
        for row in threadsByID.values {
            guard let parent = row.parentThreadID else { continue }
            childrenByParent[parent, default: []].append(row.id)
        }
        var result: Set<String> = []
        var pending = [rootID]
        while let current = pending.popLast() {
            guard result.insert(current).inserted else { continue }
            pending.append(contentsOf: childrenByParent[current] ?? [])
        }
        return result
    }

    private func ensureDataSourceIdentity(_ dataSource: CodexDataSource) throws {
        guard let expected = dataSource.homeIdentity else {
            throw SessionManagementBackendError.dataSourceIdentityUnavailable
        }
        guard CodexHomeIdentity.read(
            at: dataSource.codexHome,
            fileManager: fileManager
        ) == expected else {
            throw SessionManagementBackendError.dataSourceIdentityChanged
        }
    }

    private func ensureLiveDeletionScopeAllowed(
        _ threads: [SessionManagementThread]
    ) throws {
        guard !externalWriterDetector().isEmpty else { return }
        let unarchived = threads.filter { !$0.archived }.map(\.id).sorted()
        guard unarchived.isEmpty else {
            throw SessionManagementBackendError.liveDeletionRequiresArchive(
                unarchived
            )
        }
    }

    private func ensureRolloutRootsTrusted(
        _ dataSource: CodexDataSource
    ) throws {
        for root in [
            dataSource.codexHome.appendingPathComponent(
                "sessions",
                isDirectory: true
            ),
            dataSource.codexHome.appendingPathComponent(
                "archived_sessions",
                isDirectory: true
            ),
        ] {
            var metadata = stat()
            if Darwin.lstat(root.path, &metadata) != 0 {
                if errno == ENOENT { continue }
                throw SessionManagementBackendError.rolloutUntrusted(root.path)
            }
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw SessionManagementBackendError.rolloutUntrusted(root.path)
            }
        }
    }

    private func ensureAutoResumeNotProtected(_ threadID: String) throws {
        let protected: Set<String>
        do {
            protected = try autoResumeProtectedThreadIDsProvider()
        } catch let error as SessionManagementBackendError {
            throw error
        } catch {
            throw SessionManagementBackendError.autoResumeStateUnavailable(
                error.localizedDescription
            )
        }
        guard !protected.contains(threadID) else {
            throw SessionManagementBackendError.autoResumeProtected(threadID)
        }
    }

    private func ensureRolloutNotOpenElsewhere(
        threadID: String,
        dataSource: CodexDataSource
    ) throws {
        try CodexThreadID.validate(threadID)
        let database = SQLiteDatabaseDriver(
            url: dataSource.stateDatabase,
            readOnly: true,
            createsFileIfMissing: false,
            busyTimeoutMilliseconds: 5_000,
            consistency: .externallyOwnedWAL
        )
        let columns = Set(try SQLiteReadRecovery.run {
            try database.readRows("PRAGMA table_info(threads)") {
                $0.text(1) ?? ""
            }
        })
        guard columns.contains("id"), columns.contains("rollout_path") else {
            throw SessionManagementBackendError.unsupportedSchema(
                "官方写操作前无法定位 threads.rollout_path"
            )
        }
        let paths = try SQLiteReadRecovery.run {
            try database.readRows(
                "SELECT rollout_path FROM threads WHERE id = ? LIMIT 1",
                bindings: [.text(threadID)]
            ) {
                $0.text(0) ?? ""
            }
        }
        guard let rawPath = paths.first else {
            throw SessionManagementBackendError.threadNotFound(threadID)
        }
        let rollout = try Self.trustedRolloutURL(
            rawPath,
            dataSource: dataSource,
            fileManager: fileManager
        )
        guard let metadata = try? Self.readSessionMetadata(from: rollout),
              metadata.id == threadID else {
            throw SessionManagementBackendError.rolloutIdentityMismatch(threadID)
        }
        let holders: [Int32]
        do {
            holders = try openFileHoldersDetector(rollout.path)
        } catch {
            throw SessionManagementBackendError.externalWriterDetected(
                ["会话文件占用状态无法确认"]
            )
        }
        guard holders.isEmpty else {
            let labels = holders.sorted().map { "会话文件占用进程 PID \($0)" }
            throw SessionManagementBackendError.externalWriterDetected(labels)
        }
    }

    func createRecoveryPackage(
        thread: SessionManagementThread,
        dataSource: CodexDataSource,
        expectedSnapshot: SessionManagementRolloutSnapshot?
    ) async throws -> SessionManagementRecoveryPackageResult {
        guard Self.mutationLease.acquire() else {
            throw SessionManagementBackendError.concurrentMutation
        }
        defer { Self.mutationLease.release() }
        try ensureDataSourceIdentity(dataSource)
        let coordination = try acquireCoordination(dataSource: dataSource)
        defer { coordination.release() }
        try coordination.acquireAutoResumeLeases(
            threadIDs: [thread.id],
            codexHome: dataSource.codexHome,
            ownerID: coordinationOwnerID
        )
        try mutationGate()
        try ensureRolloutRootsTrusted(dataSource)
        try ensureAutoResumeNotProtected(thread.id)
        let freshCatalog = try await loadCatalog(dataSource: dataSource)
        guard let fresh = freshCatalog.threads.first(where: { $0.id == thread.id }),
              fresh.status.permitsMutation,
              fresh.rolloutIdentityVerified,
              fresh.canDelete else {
            throw SessionManagementBackendError.recoverySourceUnsafe
        }
        try ensureRolloutNotOpenElsewhere(threadID: thread.id, dataSource: dataSource)
        let result = try await Task.detached(priority: .userInitiated) {
            try Self.createRecoveryPackageSync(
                thread: fresh,
                dataSource: dataSource,
                expectedSnapshot: expectedSnapshot,
                fileManager: self.fileManager
            )
        }.value
        do {
            try ensureDataSourceIdentity(dataSource)
        } catch {
            throw SessionManagementPublishedRecoveryPackageError(
                result: result,
                detail: error.localizedDescription
            )
        }
        return result
    }
}

private extension FoundationSessionManagementBackend {
    struct TrustedRolloutBinding {
        let homeDirectory: ProviderSyncHomeDirectory
        let boundFile: ProviderSyncBoundRegularFile
        let relativePath: String

        func close() {
            try? boundFile.close()
            try? boundFile.file.parent.close()
            try? homeDirectory.close()
        }
    }

    struct PinnedRecoveryPackageDirectory {
        let homeDirectory: ProviderSyncHomeDirectory
        let anchor: ProviderSyncPinnedFile

        var url: URL {
            anchor.displayURL.deletingLastPathComponent()
        }

        func verify() throws {
            try homeDirectory.verifyParent(anchor)
        }

        func close() {
            try? anchor.parent.close()
            try? homeDirectory.close()
        }
    }

    final class DeletionEvidenceLease: @unchecked Sendable {
        struct Source {
            let threadID: String
            let binding: TrustedRolloutBinding
            let descriptor: ProviderSyncOwnedFileDescriptor
            let snapshot: SessionManagementRolloutSnapshot
        }

        struct Package {
            let threadID: String
            let binding: PinnedRecoveryPackageDirectory
            let descriptor: ProviderSyncOwnedFileDescriptor
            let fileName: String
            let identity: SessionManagementFileIdentity
            let sha256: String
        }

        let codexHome: URL
        let codexHomeIdentity: CodexHomeIdentity
        let sources: [Source]
        let packages: [Package]
        private var closed = false

        init(
            codexHome: URL,
            codexHomeIdentity: CodexHomeIdentity,
            sources: [Source],
            packages: [Package]
        ) {
            self.codexHome = codexHome
            self.codexHomeIdentity = codexHomeIdentity
            self.sources = sources
            self.packages = packages
        }

        func verifyBeforeDelete(fileManager: FileManager) throws {
            guard CodexHomeIdentity.read(
                at: codexHome,
                fileManager: fileManager
            ) == codexHomeIdentity else {
                throw SessionManagementBackendError.dataSourceIdentityChanged
            }
            for source in sources {
                try source.binding.homeDirectory.verifyBoundFile(
                    source.binding.boundFile
                )
                try FoundationSessionManagementBackend
                    .verifyDescriptorSnapshot(
                        descriptor: source.descriptor.rawValue,
                        expected: source.snapshot,
                        sourceLabel: source.binding.boundFile.file.displayURL
                            .lastPathComponent
                    )
            }
            for package in packages {
                try package.binding.verify()
                try FoundationSessionManagementBackend
                    .verifyPinnedPackageDescriptor(
                        package,
                        requirePathBinding: true
                    )
            }
        }

        func verifyAfterDelete(fileManager: FileManager) throws {
            guard CodexHomeIdentity.read(
                at: codexHome,
                fileManager: fileManager
            ) == codexHomeIdentity else {
                throw SessionManagementBackendError.dataSourceIdentityChanged
            }
            // The official delete may unlink the rollout path. Its already-open
            // descriptor must still identify the exact bytes that were
            // confirmed and packaged.
            for source in sources {
                try FoundationSessionManagementBackend
                    .verifyDescriptorSnapshot(
                        descriptor: source.descriptor.rawValue,
                        expected: source.snapshot,
                        sourceLabel: source.binding.boundFile.file.displayURL
                            .lastPathComponent
                    )
            }
            for package in packages {
                try package.binding.verify()
                try FoundationSessionManagementBackend
                    .verifyPinnedPackageDescriptor(
                        package,
                        requirePathBinding: true
                    )
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            for package in packages {
                try? package.descriptor.close()
                package.binding.close()
            }
            for source in sources {
                try? source.descriptor.close()
                source.binding.close()
            }
        }

        deinit {
            close()
        }
    }

    struct LocalThreadResult {
        let threads: [SessionManagementThread]
        let warnings: [String]
        let verificationComplete: Bool

        init(
            threads: [SessionManagementThread],
            warnings: [String],
            verificationComplete: Bool = true
        ) {
            self.threads = threads
            self.warnings = warnings
            self.verificationComplete = verificationComplete
        }
    }

    struct SessionMetadata {
        let id: String
        let cwd: String
        let sessionID: String?
        let forkedFromID: String?
        let parentThreadID: String?
        let source: String
    }

    struct ParsedMessage {
        let role: String
        let timestamp: String?
        let text: String
        let isTruncated: Bool
    }

    static func readLocalThreads(
        dataSource: CodexDataSource,
        fileManager: FileManager
    ) throws -> LocalThreadResult {
        var warnings: [String] = []
        var byID: [String: SessionManagementThread] = [:]
        var verificationComplete = true
        do {
            let database = try readDatabaseThreads(
                dataSource: dataSource,
                fileManager: fileManager
            )
            warnings.append(contentsOf: database.warnings)
            verificationComplete =
                verificationComplete && database.verificationComplete
            for thread in database.threads {
                byID[thread.id] = thread
            }
        } catch {
            warnings.append(
                "只读状态库补充失败；继续从 rollout 正文建立目录：\(error.localizedDescription)"
            )
        }

        let scanned = scanRolloutThreads(
            dataSource: dataSource,
            fileManager: fileManager
        )
        warnings.append(contentsOf: scanned.warnings)
        verificationComplete =
            verificationComplete && scanned.verificationComplete
        var databaseOwnerByRolloutPath: [String: String] = [:]
        for thread in byID.values {
            let path = thread.rolloutPath.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !path.isEmpty {
                databaseOwnerByRolloutPath[
                    URL(fileURLWithPath: path).standardizedFileURL.path
                ] = thread.id
            }
        }
        for scannedThread in scanned.threads {
            let scannedPath = URL(
                fileURLWithPath: scannedThread.rolloutPath
            ).standardizedFileURL.path
            if let databaseOwnerID = databaseOwnerByRolloutPath[scannedPath],
               databaseOwnerID != scannedThread.id {
                if var owner = byID[databaseOwnerID] {
                    owner.rolloutIdentityVerified = false
                    byID[databaseOwnerID] = owner
                }
                warnings.append(
                    "rollout 首行 ID \(scannedThread.id) 与状态库记录 \(databaseOwnerID) 不一致，双方危险操作均已关闭：\(scannedPath)"
                )
                verificationComplete = false
                continue
            }
            guard var existing = byID[scannedThread.id] else {
                byID[scannedThread.id] = scannedThread
                continue
            }
            if existing.rolloutPath.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty || !existing.rolloutIdentityVerified {
                existing.rolloutPath = scannedThread.rolloutPath
                existing.fileBytes = scannedThread.fileBytes
                existing.fileModifiedAt = scannedThread.fileModifiedAt
                existing.rolloutIdentityVerified =
                    scannedThread.rolloutIdentityVerified
            }
            if existing.cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.cwd = scannedThread.cwd
            }
            if existing.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.source = scannedThread.source
            }
            existing.createdAt = existing.createdAt ?? scannedThread.createdAt
            existing.updatedAt = existing.updatedAt ?? scannedThread.updatedAt
            existing.recencyAt = existing.recencyAt ?? scannedThread.recencyAt
            existing.sessionID = existing.sessionID ?? scannedThread.sessionID
            existing.forkedFromID =
                existing.forkedFromID ?? scannedThread.forkedFromID
            existing.parentThreadID =
                existing.parentThreadID ?? scannedThread.parentThreadID
            existing.isSubagent = existing.isSubagent || scannedThread.isSubagent
            existing.archived = existing.archived || scannedThread.archived
            if !scannedThread.rolloutIdentityVerified {
                existing.rolloutIdentityVerified = false
            }
            byID[existing.id] = existing
        }

        return LocalThreadResult(
            threads: byID.values.sorted { $0.id < $1.id },
            warnings: warnings,
            verificationComplete: verificationComplete
        )
    }

    static func readDatabaseThreads(
        dataSource: CodexDataSource,
        fileManager: FileManager
    ) throws -> LocalThreadResult {
        guard fileManager.fileExists(atPath: dataSource.stateDatabase.path) else {
            throw SessionManagementBackendError.databaseUnavailable
        }
        let database = SQLiteDatabaseDriver(
            url: dataSource.stateDatabase,
            readOnly: true,
            createsFileIfMissing: false,
            busyTimeoutMilliseconds: 5_000,
            consistency: .externallyOwnedWAL
        )
        let columns = Set(try SQLiteReadRecovery.run {
            try database.readRows("PRAGMA table_info(threads)") {
                $0.text(1) ?? ""
            }
        })
        guard columns.contains("id") else {
            throw SessionManagementBackendError.unsupportedSchema("threads.id 缺失")
        }
        func value(_ name: String, fallback: String = "NULL") -> String {
            columns.contains(name) ? "\"\(name)\"" : fallback
        }
        func textPreview(_ name: String, length: Int) -> String {
            columns.contains(name) ? "substr(\"\(name)\", 1, \(length))" : "NULL"
        }
        let sql = """
        SELECT
          \(value("id")),
          \(value("rollout_path")),
          \(textPreview("title", length: 4_096)),
          \(textPreview("preview", length: 4_096)),
          \(textPreview("first_user_message", length: 4_096)),
          \(value("cwd")),
          \(value("created_at")),
          \(value("created_at_ms")),
          \(value("updated_at")),
          \(value("updated_at_ms")),
          \(value("recency_at")),
          \(value("recency_at_ms")),
          \(value("archived", fallback: "0")),
          \(value("archived_at")),
          \(value("tokens_used")),
          \(value("source")),
          \(value("model")),
          \(value("git_branch")),
          \(value("agent_role")),
          \(value("thread_source")),
          \(textPreview("name", length: 4_096))
        FROM threads
        """
        var warnings: [String] = []
        let rows = try SQLiteReadRecovery.run {
            try database.readRows(sql) { statement -> SessionManagementThread in
                let id = statement.text(0) ?? ""
                let rawRolloutPath = statement.text(1) ?? ""
                let expandedRolloutPath =
                    (rawRolloutPath as NSString).expandingTildeInPath
                let normalizedRolloutPath =
                    (expandedRolloutPath as NSString).isAbsolutePath
                    ? URL(fileURLWithPath: expandedRolloutPath)
                        .standardizedFileURL.path
                    : dataSource.codexHome
                        .appendingPathComponent(expandedRolloutPath)
                        .standardizedFileURL.path
                let name = statement.text(20) ?? ""
                let title = name.isEmpty ? (statement.text(2) ?? "") : name
                let source = firstNonempty([
                    statement.text(19),
                    statement.text(15),
                ])
                let agentRole = statement.text(18) ?? ""
                return SessionManagementThread(
                    id: id,
                    title: title,
                    preview: statement.text(3) ?? "",
                    firstUserMessage: statement.text(4) ?? "",
                    cwd: firstNonempty([
                        statement.text(5),
                    ]),
                    rolloutPath: normalizedRolloutPath,
                    createdAt: preferredDate(
                        seconds: statement.double(6),
                        milliseconds: statement.double(7)
                    ),
                    updatedAt: preferredDate(
                        seconds: statement.double(8),
                        milliseconds: statement.double(9)
                    ),
                    recencyAt: preferredDate(
                        seconds: statement.double(10),
                        milliseconds: statement.double(11)
                    ),
                    archived: (statement.int(12) ?? 0) != 0,
                    archivedAt: epochDate(statement.double(13)),
                    tokensUsed: statement.int64(14),
                    fileBytes: nil,
                    fileModifiedAt: nil,
                    status: .unknown,
                    source: source,
                    model: statement.text(16) ?? "",
                    gitBranch: statement.text(17) ?? "",
                    sessionID: nil,
                    forkedFromID: nil,
                    parentThreadID: nil,
                    isSubagent:
                        !agentRole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || source.lowercased().contains("subagent"),
                    spawnChildCount: 0,
                    forkChildCount: 0,
                    similarityGroupID: nil,
                    similarityReason: nil,
                    protectionReasons: [],
                    canArchive: false,
                    canUnarchive: false,
                    canDelete: false,
                    rolloutIdentityVerified: false
                )
            }
        }
        let validRows = rows.filter { !$0.id.isEmpty }
        let verificationComplete = validRows.count == rows.count
        if validRows.count != rows.count {
            warnings.append("本地数据库中有 \(rows.count - validRows.count) 条记录缺少会话 ID，已跳过。")
        }
        return LocalThreadResult(
            threads: validRows,
            warnings: warnings,
            verificationComplete: verificationComplete
        )
    }

    static func scanRolloutThreads(
        dataSource: CodexDataSource,
        fileManager: FileManager
    ) -> LocalThreadResult {
        var warnings: [String] = []
        var verificationComplete = true
        var candidates: [CodexUsageHistoryIndex.SessionCatalogCandidate] = []
        let propertyKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        for (root, archived) in [
            (dataSource.sessionsRoot, false),
            (
                dataSource.codexHome.appendingPathComponent(
                    "archived_sessions",
                    isDirectory: true
                ),
                true
            ),
        ] {
            var rootMetadata = stat()
            if Darwin.lstat(root.path, &rootMetadata) != 0 {
                if errno != ENOENT {
                    warnings.append("只读扫描无法确认目录身份：\(root.path)")
                    verificationComplete = false
                }
                continue
            }
            guard (rootMetadata.st_mode & S_IFMT) == S_IFDIR else {
                warnings.append("只读扫描拒绝符号链接或非目录根：\(root.path)")
                verificationComplete = false
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: propertyKeys,
                options: [.skipsPackageDescendants],
                errorHandler: { url, error in
                    warnings.append(
                        "只读扫描无法读取 \(url.path)：\(error.localizedDescription)"
                    )
                    verificationComplete = false
                    return true
                }
            ) else {
                warnings.append("只读扫描无法打开目录：\(root.path)")
                verificationComplete = false
                continue
            }
            while let candidate = enumerator.nextObject() as? URL {
                let values: URLResourceValues
                do {
                    values = try candidate.resourceValues(forKeys: Set(propertyKeys))
                } catch {
                    warnings.append(
                        "只读扫描无法读取 \(candidate.path) 的属性：\(error.localizedDescription)"
                    )
                    verificationComplete = false
                    continue
                }
                if values.isSymbolicLink == true {
                    warnings.append("只读扫描拒绝符号链接组件：\(candidate.path)")
                    verificationComplete = false
                    if values.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true,
                      candidate.pathExtension.lowercased() == "jsonl" else {
                    continue
                }
                let trusted: URL
                do {
                    trusted = try trustedRolloutURL(
                        candidate.path,
                        dataSource: dataSource,
                        fileManager: fileManager
                    )
                } catch {
                    warnings.append(
                        "只读扫描拒绝不可信 rollout \(candidate.path)：\(error.localizedDescription)"
                    )
                    verificationComplete = false
                    continue
                }
                candidates.append(
                    CodexUsageHistoryIndex.SessionCatalogCandidate(
                        file: trusted,
                        archived: archived
                    )
                )
            }
        }

        let index: CodexUsageHistoryIndex
        do {
            index = try CodexUsageHistoryIndex(
                codexHome: dataSource.codexHome,
                fileManager: fileManager
            )
        } catch {
            warnings.append(
                "会话增量索引不可用；状态库记录仍可浏览，危险操作保持关闭：\(error.localizedDescription)"
            )
            return LocalThreadResult(
                threads: [],
                warnings: warnings,
                verificationComplete: false
            )
        }

        var indexedEntries: [CodexUsageHistoryIndex.SessionCatalogEntry] = []
        var snapshotIsCurrent = false
        if verificationComplete {
            do {
                let synchronized = try index.synchronizeSessionCatalog(
                    candidates: candidates
                ) { file in
                    let metadata = try readSessionMetadata(from: file)
                    return CodexUsageHistoryIndex.SessionCatalogMetadata(
                        threadID: metadata.id,
                        cwd: metadata.cwd,
                        sessionID: metadata.sessionID,
                        forkedFromID: metadata.forkedFromID,
                        parentThreadID: metadata.parentThreadID,
                        source: metadata.source
                    )
                }
                indexedEntries = synchronized.entries
                snapshotIsCurrent = true
            } catch {
                warnings.append(
                    "会话增量索引更新失败；保留上一份完整目录并等待下次重试，危险操作保持关闭：\(error.localizedDescription)"
                )
                verificationComplete = false
            }
        } else {
            warnings.append(
                "本轮会话目录枚举不完整；保留上一份完整增量索引，危险操作保持关闭。"
            )
        }
        if !snapshotIsCurrent {
            do {
                indexedEntries = try index.sessionCatalogEntries()
            } catch {
                warnings.append(
                    "上一份会话增量索引读取失败：\(error.localizedDescription)"
                )
                indexedEntries = []
            }
        }

        var byID: [String: SessionManagementThread] = [:]
        for entry in indexedEntries {
            let metadata = entry.metadata
            guard !metadata.threadID.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                warnings.append("会话增量索引发现缺少会话 ID 的 rollout：\(entry.path)")
                verificationComplete = false
                continue
            }
            var thread = SessionManagementThread(
                id: metadata.threadID,
                title: "",
                preview: "",
                firstUserMessage: "",
                cwd: metadata.cwd,
                rolloutPath: entry.path,
                createdAt: entry.createdAt,
                updatedAt: entry.modifiedAt,
                recencyAt: entry.modifiedAt,
                archived: entry.archived,
                archivedAt: entry.archived ? entry.modifiedAt : nil,
                tokensUsed: nil,
                fileBytes: entry.sizeBytes,
                fileModifiedAt: entry.modifiedAt,
                status: .unknown,
                source: metadata.source,
                model: "",
                gitBranch: "",
                sessionID: metadata.sessionID,
                forkedFromID: metadata.forkedFromID,
                parentThreadID: metadata.parentThreadID,
                isSubagent: metadata.parentThreadID != nil
                    || metadata.source.lowercased().contains("subagent"),
                spawnChildCount: 0,
                forkChildCount: 0,
                similarityGroupID: nil,
                similarityReason: nil,
                protectionReasons: [],
                canArchive: false,
                canUnarchive: false,
                canDelete: false,
                rolloutIdentityVerified: snapshotIsCurrent
            )
            if let existing = byID[metadata.threadID],
                   existing.rolloutPath != thread.rolloutPath {
                warnings.append(
                    "会话增量索引发现重复会话 ID \(metadata.threadID)，危险操作将保持关闭：\(existing.rolloutPath)、\(thread.rolloutPath)"
                )
                verificationComplete = false
                if (thread.fileModifiedAt ?? .distantPast)
                    < (existing.fileModifiedAt ?? .distantPast) {
                    thread = existing
                }
                thread.rolloutIdentityVerified = false
            }
            byID[metadata.threadID] = thread
        }
        return LocalThreadResult(
            threads: byID.values.sorted { $0.id < $1.id },
            warnings: warnings,
            verificationComplete: verificationComplete
        )
    }

    struct RolloutInspection {
        let url: URL?
        let identity: SessionManagementFileIdentity?
        let metadata: SessionMetadata?
    }

    static func rolloutInspection(
        rawPath: String,
        threadID: String,
        dataSource: CodexDataSource,
        fileManager: FileManager
    ) -> RolloutInspection {
        guard let url = try? trustedRolloutURL(
            rawPath,
            dataSource: dataSource,
            fileManager: fileManager
        ) else {
            return RolloutInspection(url: nil, identity: nil, metadata: nil)
        }
        let identity = fileIdentity(url: url, fileManager: fileManager)
        let metadata = try? readSessionMetadata(from: url)
        guard metadata?.id == threadID else {
            return RolloutInspection(url: url, identity: identity, metadata: nil)
        }
        return RolloutInspection(url: url, identity: identity, metadata: metadata)
    }

    static func mergeAndEnrich(
        local: [SessionManagementThread],
        appServer: [SessionManagementAppServerThread],
        officialMutationsAvailable: Bool,
        liveDeletionRequiresArchive: Bool = false,
        autoResumeProtectedThreadIDs: Set<String> = []
    ) -> [SessionManagementThread] {
        var byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for live in appServer {
            if var thread = byID[live.id] {
                if !live.title.isEmpty { thread.title = live.title }
                if !live.preview.isEmpty { thread.preview = live.preview }
                if !live.cwd.isEmpty { thread.cwd = live.cwd }
                if !live.rolloutPath.isEmpty { thread.rolloutPath = live.rolloutPath }
                thread.createdAt = live.createdAt ?? thread.createdAt
                thread.updatedAt = live.updatedAt ?? thread.updatedAt
                thread.archived = live.archived
                thread.status = live.status
                if !live.source.isEmpty { thread.source = live.source }
                if !live.model.isEmpty { thread.model = live.model }
                thread.sessionID = live.sessionID ?? thread.sessionID
                thread.forkedFromID = live.forkedFromID ?? thread.forkedFromID
                thread.parentThreadID = live.parentThreadID ?? thread.parentThreadID
                thread.isSubagent = thread.parentThreadID != nil
                    || thread.isSubagent
                    || live.source.lowercased().contains("subagent")
                byID[live.id] = thread
            } else {
                byID[live.id] = SessionManagementThread(
                    id: live.id,
                    title: live.title,
                    preview: live.preview,
                    firstUserMessage: "",
                    cwd: live.cwd,
                    rolloutPath: live.rolloutPath,
                    createdAt: live.createdAt,
                    updatedAt: live.updatedAt,
                    recencyAt: nil,
                    archived: live.archived,
                    archivedAt: nil,
                    tokensUsed: nil,
                    fileBytes: nil,
                    fileModifiedAt: nil,
                    status: live.status,
                    source: live.source,
                    model: live.model,
                    gitBranch: "",
                    sessionID: live.sessionID,
                    forkedFromID: live.forkedFromID,
                    parentThreadID: live.parentThreadID,
                    isSubagent: live.parentThreadID != nil
                        || live.source.lowercased().contains("subagent"),
                    spawnChildCount: 0,
                    forkChildCount: 0,
                    similarityGroupID: nil,
                    similarityReason: nil,
                    protectionReasons: [],
                    canArchive: false,
                    canUnarchive: false,
                    canDelete: false,
                    rolloutIdentityVerified: false
                )
            }
        }

        let spawnCounts = Dictionary(grouping: byID.values.compactMap(\.parentThreadID), by: { $0 })
            .mapValues(\.count)
        let forkCounts = Dictionary(grouping: byID.values.compactMap(\.forkedFromID), by: { $0 })
            .mapValues(\.count)
        let similarity = similarityGroups(Array(byID.values))
        let recentBoundary = Date().addingTimeInterval(-24 * 60 * 60)
        for id in Array(byID.keys) {
            guard var thread = byID[id] else { continue }
            thread.spawnChildCount = spawnCounts[id] ?? 0
            thread.forkChildCount = forkCounts[id] ?? 0
            if let match = similarity[id] {
                thread.similarityGroupID = match.groupID
                thread.similarityReason = match.reason
            }
            var protection: [String] = []
            if thread.status == .idle || thread.status == .loaded {
                protection.append("会话仍被 Codex 加载")
            } else if !thread.status.permitsMutation {
                protection.append("运行状态为\(thread.status.label)")
            }
            if let lastUsedAt = thread.lastUsedAt, lastUsedAt >= recentBoundary {
                protection.append("24 小时内仍有活动")
            }
            if thread.forkChildCount > 0 {
                protection.append("是 \(thread.forkChildCount) 个 fork 的来源")
            }
            if thread.spawnChildCount > 0 {
                protection.append("有 \(thread.spawnChildCount) 个 subagent 后代")
            }
            if thread.isSubagent {
                protection.append("属于 subagent 会话")
            }
            if autoResumeProtectedThreadIDs.contains(thread.id) {
                protection.append("已被自动续跑任务保护")
            }
            if !thread.rolloutIdentityVerified {
                protection.append("rollout 首行身份无法验证")
            }
            thread.protectionReasons = protection
            let safe = officialMutationsAvailable
                && thread.status.permitsMutation
                && thread.rolloutIdentityVerified
                && !autoResumeProtectedThreadIDs.contains(thread.id)
            thread.canArchive = safe && !thread.archived
            thread.canUnarchive = safe && thread.archived
            thread.canDelete = safe
                && (!liveDeletionRequiresArchive || thread.archived)
            if liveDeletionRequiresArchive, !thread.archived {
                thread.protectionReasons.append(
                    "Codex 运行中需先官方归档再删除"
                )
            }
            byID[id] = thread
        }
        return Array(byID.values)
    }

    struct SimilarityMatch {
        let groupID: String
        let reason: String
    }

    static func similarityGroups(
        _ threads: [SessionManagementThread]
    ) -> [String: SimilarityMatch] {
        var candidates: [String: [(id: String, reason: String)]] = [:]
        for thread in threads where !thread.isSubagent {
            let title = normalizedSimilarityText(thread.displayTitle)
            let first = normalizedSimilarityText(thread.firstUserMessage)
            let key: String
            let reason: String
            if title.count >= 8, first.count >= 12 {
                key = "title:\(title)|first:\(first)"
                reason = "规范化标题与首条消息一致"
            } else if first.count >= 20 {
                key = "first:\(first)"
                reason = "规范化首条消息一致"
            } else if title.count >= 16 {
                key = "title:\(title)"
                reason = "规范化标题一致"
            } else {
                continue
            }
            candidates[key, default: []].append((thread.id, reason))
        }
        var result: [String: SimilarityMatch] = [:]
        for (key, values) in candidates where values.count > 1 {
            let digest = SHA256.hash(data: Data(key.utf8))
                .prefix(8)
                .map { String(format: "%02x", $0) }
                .joined()
            for value in values {
                result[value.id] = SimilarityMatch(
                    groupID: digest,
                    reason: value.reason
                )
            }
        }
        return result
    }

    static func normalizedSimilarityText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    static func readContextPage(
        thread: SessionManagementThread,
        dataSource: CodexDataSource,
        beforeOffset: Int64?,
        pageSize: Int,
        fileManager: FileManager
    ) async throws -> SessionManagementContextPage {
        let url = try trustedRolloutURL(
            thread.rolloutPath,
            dataSource: dataSource,
            fileManager: fileManager
        )
        guard !url.lastPathComponent.hasSuffix(".zst") else {
            throw SessionManagementBackendError.compressedContextUnsupported
        }
        guard let identity = fileIdentity(url: url, fileManager: fileManager) else {
            throw SessionManagementBackendError.rolloutUnavailable(url.path)
        }
        guard let metadata = try? readSessionMetadata(from: url),
              metadata.id == thread.id else {
            throw SessionManagementBackendError.rolloutIdentityMismatch(thread.id)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = identity.size
        var cursor = min(max(0, beforeOffset ?? size), size)
        var warnings: [String] = []
        if beforeOffset == nil, cursor > 0, try byte(at: cursor - 1, handle: handle) != 0x0A {
            warnings.append("正文尾部仍在写入或记录不完整，本页暂缓该尾行。")
            cursor = (try previousNewline(before: cursor, handle: handle)) ?? 0
        }

        var messages: [SessionManagementContextMessage] = []
        while messages.count < pageSize, cursor > 0 {
            try Task.checkCancellation()
            let lineEnd: Int64
            if try byte(at: cursor - 1, handle: handle) == 0x0A {
                lineEnd = cursor - 1
            } else {
                lineEnd = cursor
            }
            let previous = try previousNewline(before: lineEnd, handle: handle)
            let lineStart = previous.map { $0 + 1 } ?? 0
            cursor = lineStart
            guard lineEnd > lineStart else { continue }
            let completed = try readCompletedLine(
                range: lineStart..<lineEnd,
                handle: handle
            )
            if let parsed = try await parseMessage(completed) {
                messages.append(
                    SessionManagementContextMessage(
                        id: "\(thread.id):\(lineStart)",
                        role: parsed.role,
                        timestamp: parsed.timestamp,
                        text: parsed.text,
                        isTruncated: parsed.isTruncated,
                        byteOffset: lineStart
                    )
                )
            }
        }
        return SessionManagementContextPage(
            threadID: thread.id,
            messages: messages.reversed(),
            nextBeforeOffset: cursor > 0 ? cursor : nil,
            hasMoreBefore: cursor > 0,
            fileIdentity: identity,
            warnings: warnings
        )
    }

    static func readCompletedLine(
        range: Range<Int64>,
        handle: FileHandle
    ) throws -> CodexCompletedRolloutLine {
        let accumulator = CodexRolloutLineAccumulator()
        try handle.seek(toOffset: UInt64(range.lowerBound))
        var remaining = range.upperBound - range.lowerBound
        while remaining > 0 {
            let count = Int(min(Int64(1024 * 1024), remaining))
            guard let data = try handle.read(upToCount: count), !data.isEmpty else {
                throw SessionManagementBackendError.rolloutUnavailable("读取正文时提前结束")
            }
            try accumulator.append(data)
            remaining -= Int64(data.count)
        }
        return try accumulator.finish()
    }

    static func parseMessage(
        _ completed: CodexCompletedRolloutLine
    ) async throws -> ParsedMessage? {
        switch completed {
        case .memory(let data):
            return parseSmallMessage(data)
        case .mapped(let mapped):
            guard let message = try CodexLargeRolloutMessage.parse(mapped) else {
                return nil
            }
            let collector = SessionManagementTextCollector(maximumUTF8Bytes: 64 * 1024)
            try await message.emitBody { chunk in
                collector.append(chunk)
            }
            let snapshot = collector.snapshot()
            return ParsedMessage(
                role: message.speaker == "User" ? "user" : "assistant",
                timestamp: message.timestamp,
                text: snapshot.text,
                isTruncated: snapshot.truncated
            )
        }
    }

    static func parseSmallMessage(_ data: Data) -> ParsedMessage? {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              event["type"] as? String == "response_item",
              let payload = event["payload"] as? [String: Any],
              payload["type"] as? String == "message",
              let role = payload["role"] as? String,
              role == "user" || role == "assistant",
              let content = payload["content"] as? [[String: Any]] else {
            return nil
        }
        let text = content.compactMap { block -> String? in
            switch block["type"] as? String {
            case "input_text", "output_text":
                return block["text"] as? String
            case "input_image":
                return "[图片附件]"
            default:
                return nil
            }
        }.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let limited = utf8Prefix(text, maximumBytes: 64 * 1024)
        return ParsedMessage(
            role: role,
            timestamp: event["timestamp"] as? String,
            text: limited.text,
            isTruncated: limited.truncated
        )
    }

    static func previousNewline(
        before offset: Int64,
        handle: FileHandle
    ) throws -> Int64? {
        var end = offset
        while end > 0 {
            let start = max(0, end - Int64(1024 * 1024))
            try handle.seek(toOffset: UInt64(start))
            guard let data = try handle.read(upToCount: Int(end - start)),
                  !data.isEmpty else {
                return nil
            }
            if let index = data.lastIndex(of: 0x0A) {
                return start + Int64(index)
            }
            end = start
        }
        return nil
    }

    static func byte(at offset: Int64, handle: FileHandle) throws -> UInt8? {
        guard offset >= 0 else { return nil }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: 1)?.first
    }

    static func deletionScopeMatches(
        _ current: SessionManagementDeletionImpact,
        _ confirmed: SessionManagementDeletionImpact
    ) -> Bool {
        Set(current.requested.map(\.id)) == Set(confirmed.requested.map(\.id))
            && current.effectiveRoots.map(\.id)
                == confirmed.effectiveRoots.map(\.id)
            && Set(current.affected.map(\.id))
                == Set(confirmed.affected.map(\.id))
            && current.coveringRootIDByThreadID
                == confirmed.coveringRootIDByThreadID
    }

    static func captureRolloutSnapshot(
        thread: SessionManagementThread,
        dataSource: CodexDataSource,
        fileManager: FileManager
    ) throws -> SessionManagementRolloutSnapshot {
        let binding = try bindTrustedRollout(
            thread.rolloutPath,
            dataSource: dataSource,
            fileManager: fileManager
        )
        defer { binding.close() }
        let descriptor = Darwin.dup(binding.boundFile.descriptor.rawValue)
        guard descriptor >= 0 else {
            throw SessionManagementBackendError.rolloutUnavailable(
                "无法复制确认时 rollout descriptor"
            )
        }
        let owned = ProviderSyncOwnedFileDescriptor(descriptor)
        defer { try? owned.close() }
        guard let identity = fileIdentity(fileDescriptor: descriptor) else {
            throw SessionManagementBackendError.rolloutIdentityMismatch(thread.id)
        }
        let snapshot = SessionManagementRolloutSnapshot(
            threadID: thread.id,
            relativePath: binding.relativePath,
            fileIdentity: identity,
            sha256: try hashDescriptor(descriptor).sha256
        )
        try verifyDescriptorSnapshot(
            descriptor: descriptor,
            expected: snapshot,
            sourceLabel: binding.boundFile.file.displayURL.lastPathComponent
        )
        try binding.homeDirectory.verifyBoundFile(binding.boundFile)
        return snapshot
    }

    static func verifyRolloutSnapshot(
        _ expected: SessionManagementRolloutSnapshot,
        thread: SessionManagementThread,
        dataSource: CodexDataSource,
        fileManager: FileManager
    ) throws {
        guard expected.threadID == thread.id else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }
        let binding = try bindTrustedRollout(
            thread.rolloutPath,
            dataSource: dataSource,
            fileManager: fileManager
        )
        defer { binding.close() }
        guard binding.relativePath == expected.relativePath else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }
        let descriptor = Darwin.dup(binding.boundFile.descriptor.rawValue)
        guard descriptor >= 0 else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }
        let owned = ProviderSyncOwnedFileDescriptor(descriptor)
        defer { try? owned.close() }
        try verifyDescriptorSnapshot(
            descriptor: descriptor,
            expected: expected,
            sourceLabel: binding.boundFile.file.displayURL.lastPathComponent
        )
        try binding.homeDirectory.verifyBoundFile(binding.boundFile)
    }

    static func verifyDescriptorSnapshot(
        descriptor: Int32,
        expected: SessionManagementRolloutSnapshot,
        sourceLabel: String
    ) throws {
        guard fileIdentity(fileDescriptor: descriptor)
                == expected.fileIdentity else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(
                expected.threadID
            )
        }
        let metadataDescriptor = Darwin.dup(descriptor)
        guard metadataDescriptor >= 0 else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(
                expected.threadID
            )
        }
        let metadataHandle = FileHandle(
            fileDescriptor: metadataDescriptor,
            closeOnDealloc: true
        )
        defer { try? metadataHandle.close() }
        guard let metadata = try? readSessionMetadata(
            from: metadataHandle,
            sourceLabel: sourceLabel
        ),
              metadata.id == expected.threadID else {
            throw SessionManagementBackendError.rolloutIdentityMismatch(
                expected.threadID
            )
        }
        let digest = try hashDescriptor(descriptor)
        guard digest.byteCount == expected.fileIdentity.size,
              digest.sha256 == expected.sha256,
              fileIdentity(fileDescriptor: descriptor)
                == expected.fileIdentity else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(
                expected.threadID
            )
        }
    }

    static func hashDescriptor(
        _ descriptor: Int32
    ) throws -> (sha256: String, byteCount: Int64) {
        let duplicated = Darwin.dup(descriptor)
        guard duplicated >= 0 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "无法复制待校验文件 descriptor"
            )
        }
        let handle = FileHandle(
            fileDescriptor: duplicated,
            closeOnDealloc: true
        )
        defer { try? handle.close() }
        return try hashRollout(sourceHandle: handle)
    }

    static func pinDeletionEvidence(
        pendingAffected: [SessionManagementThread],
        expectation: SessionManagementDeletionExpectation,
        recoveryPackages: [String: SessionManagementRecoveryPackageResult],
        dataSource: CodexDataSource,
        fileManager: FileManager
    ) throws -> DeletionEvidenceLease {
        var sources: [DeletionEvidenceLease.Source] = []
        var packages: [DeletionEvidenceLease.Package] = []
        var completed = false
        defer {
            if !completed {
                for package in packages {
                    try? package.descriptor.close()
                    package.binding.close()
                }
                for source in sources {
                    try? source.descriptor.close()
                    source.binding.close()
                }
            }
        }

        for thread in pendingAffected {
            guard let expected =
                    expectation.rolloutSnapshotsByThreadID[thread.id],
                  let recovery = recoveryPackages[thread.id],
                  recovery.manifest.threadID == thread.id,
                  recovery.manifest.originalRelativePath
                    == expected.relativePath,
                  recovery.manifest.originalByteCount
                    == expected.fileIdentity.size,
                  recovery.manifest.sha256 == expected.sha256,
                  recovery.sourceIdentity == expected.fileIdentity else {
                throw SessionManagementBackendError.recoveryEvidenceMismatch(
                    thread.id
                )
            }
            let sourceBinding = try bindTrustedRollout(
                thread.rolloutPath,
                dataSource: dataSource,
                fileManager: fileManager
            )
            do {
                guard sourceBinding.relativePath == expected.relativePath else {
                    throw SessionManagementBackendError
                        .recoveryEvidenceMismatch(thread.id)
                }
                let sourceDescriptor = Darwin.dup(
                    sourceBinding.boundFile.descriptor.rawValue
                )
                guard sourceDescriptor >= 0 else {
                    throw SessionManagementBackendError
                        .recoveryEvidenceMismatch(thread.id)
                }
                let ownedSource = ProviderSyncOwnedFileDescriptor(
                    sourceDescriptor
                )
                do {
                    try verifyDescriptorSnapshot(
                        descriptor: sourceDescriptor,
                        expected: expected,
                        sourceLabel: sourceBinding.boundFile.file.displayURL
                            .lastPathComponent
                    )
                    try sourceBinding.homeDirectory.verifyBoundFile(
                        sourceBinding.boundFile
                    )
                    sources.append(
                        DeletionEvidenceLease.Source(
                            threadID: thread.id,
                            binding: sourceBinding,
                            descriptor: ownedSource,
                            snapshot: expected
                        )
                    )
                } catch {
                    try? ownedSource.close()
                    throw error
                }
            } catch {
                sourceBinding.close()
                throw error
            }

            let packageBinding = try pinRecoveryPackageDirectory(
                dataSource: dataSource,
                createParents: false
            )
            do {
                let packageDirectory =
                    packageBinding.url.standardizedFileURL
                guard recovery.packageURL.deletingLastPathComponent()
                        .standardizedFileURL == packageDirectory else {
                    throw SessionManagementBackendError
                        .recoveryEvidenceMismatch(thread.id)
                }
                let fileName = recovery.packageURL.lastPathComponent
                let descriptor = Darwin.openat(
                    packageBinding.anchor.parent.rawValue,
                    fileName,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else {
                    throw SessionManagementBackendError
                        .recoveryEvidenceMismatch(thread.id)
                }
                let ownedPackage = ProviderSyncOwnedFileDescriptor(descriptor)
                do {
                    let package = DeletionEvidenceLease.Package(
                        threadID: thread.id,
                        binding: packageBinding,
                        descriptor: ownedPackage,
                        fileName: fileName,
                        identity: recovery.packageIdentity,
                        sha256: recovery.packageSHA256
                    )
                    try verifyPinnedPackageDescriptor(
                        package,
                        requirePathBinding: true
                    )
                    packages.append(package)
                } catch {
                    try? ownedPackage.close()
                    throw error
                }
            } catch {
                packageBinding.close()
                throw error
            }
        }
        let lease = DeletionEvidenceLease(
            codexHome: dataSource.codexHome,
            codexHomeIdentity: expectation.codexHomeIdentity,
            sources: sources,
            packages: packages
        )
        try lease.verifyBeforeDelete(fileManager: fileManager)
        completed = true
        return lease
    }

    static func verifyPinnedPackageDescriptor(
        _ package: DeletionEvidenceLease.Package,
        requirePathBinding: Bool
    ) throws {
        guard fileIdentity(fileDescriptor: package.descriptor.rawValue)
                == package.identity else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(
                package.threadID
            )
        }
        if requirePathBinding {
            guard let metadata = try providerSyncEntryMetadata(
                directory: package.binding.anchor.parent.rawValue,
                name: package.fileName
            ),
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  SessionManagementFileIdentity(
                      deviceID: UInt64(metadata.st_dev),
                      fileID: UInt64(metadata.st_ino),
                      size: Int64(metadata.st_size),
                      modifiedAt: Date(
                          timeIntervalSince1970:
                              TimeInterval(metadata.st_mtimespec.tv_sec)
                              + TimeInterval(metadata.st_mtimespec.tv_nsec)
                                  / 1_000_000_000
                      )
                  ) == package.identity else {
                throw SessionManagementBackendError.recoveryEvidenceMismatch(
                    package.threadID
                )
            }
        }
        let digest = try hashDescriptor(package.descriptor.rawValue)
        guard digest.byteCount == package.identity.size,
              digest.sha256 == package.sha256,
              fileIdentity(fileDescriptor: package.descriptor.rawValue)
                == package.identity else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(
                package.threadID
            )
        }
    }

    static func trustedRolloutURL(
        _ rawPath: String,
        dataSource: CodexDataSource,
        fileManager: FileManager
    ) throws -> URL {
        let binding = try bindTrustedRollout(
            rawPath,
            dataSource: dataSource,
            fileManager: fileManager
        )
        defer { binding.close() }
        return binding.boundFile.file.displayURL
    }

    static func bindTrustedRollout(
        _ rawPath: String,
        dataSource: CodexDataSource,
        fileManager: FileManager
    ) throws -> TrustedRolloutBinding {
        _ = fileManager
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SessionManagementBackendError.rolloutUnavailable(rawPath)
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let candidate = (expanded as NSString).isAbsolutePath
            ? URL(fileURLWithPath: expanded)
            : dataSource.codexHome.appendingPathComponent(expanded)
        let standardizedCandidate = candidate.standardizedFileURL
        let lexicalHome = dataSource.codexHome.standardizedFileURL
        let canonicalHome = lexicalHome.resolvingSymlinksInPath()
        let bases = [lexicalHome, canonicalHome]
        let relativePath = bases.compactMap { base -> String? in
            let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
            guard standardizedCandidate.path.hasPrefix(prefix) else { return nil }
            return String(standardizedCandidate.path.dropFirst(prefix.count))
        }.first
        guard let relativePath else {
            throw SessionManagementBackendError.rolloutUntrusted(
                standardizedCandidate.path
            )
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard let root = components.first,
              root == "sessions" || root == "archived_sessions",
              components.count > 1 else {
            throw SessionManagementBackendError.rolloutUntrusted(
                standardizedCandidate.path
            )
        }
        do {
            let home = try ProviderSyncHomeDirectory(
                canonicalURL: canonicalHome,
                expectedHomeIdentity: dataSource.homeIdentity
            )
            do {
                guard let bound = try home.bindRegularFile(
                    relativePath: relativePath
                ) else {
                    throw SessionManagementBackendError.rolloutUnavailable(
                        standardizedCandidate.path
                    )
                }
                do {
                    try home.verifyBoundFile(bound)
                    return TrustedRolloutBinding(
                        homeDirectory: home,
                        boundFile: bound,
                        relativePath: relativePath
                    )
                } catch {
                    try? bound.close()
                    try? bound.file.parent.close()
                    throw error
                }
            } catch {
                try? home.close()
                throw error
            }
        } catch let error as SessionManagementBackendError {
            throw error
        } catch {
            throw SessionManagementBackendError.rolloutUntrusted(
                "\(standardizedCandidate.path)（\(error.localizedDescription)）"
            )
        }
    }

    static func pinRecoveryPackageDirectory(
        dataSource: CodexDataSource,
        createParents: Bool
    ) throws -> PinnedRecoveryPackageDirectory {
        let home = try ProviderSyncHomeDirectory(
            canonicalURL: dataSource.codexHome.standardizedFileURL
                .resolvingSymlinksInPath(),
            expectedHomeIdentity: dataSource.homeIdentity
        )
        do {
            let anchor = try home.pinFile(
                relativePath: recoveryPackageAnchorRelativePath,
                createParents: createParents
            )
            do {
                try home.verifyParent(anchor)
                return PinnedRecoveryPackageDirectory(
                    homeDirectory: home,
                    anchor: anchor
                )
            } catch {
                try? anchor.parent.close()
                throw error
            }
        } catch {
            try? home.close()
            throw error
        }
    }

    static func readSessionMetadata(from url: URL) throws -> SessionMetadata {
        guard !url.lastPathComponent.hasSuffix(".zst") else {
            throw SessionManagementBackendError.compressedContextUnsupported
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try readSessionMetadata(
            from: handle,
            sourceLabel: url.lastPathComponent
        )
    }

    static func readSessionMetadata(
        from handle: FileHandle,
        sourceLabel: String
    ) throws -> SessionMetadata {
        try handle.seek(toOffset: 0)
        let accumulator = CodexRolloutLineAccumulator()
        var foundNewline = false
        while !foundNewline,
              let chunk = try handle.read(upToCount: 64 * 1024),
              !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: 0x0A) {
                try accumulator.append(Data(chunk[..<newline]))
                foundNewline = true
            } else {
                try accumulator.append(chunk)
            }
        }
        let completed = try accumulator.finish()
        guard case .memory(let data) = completed,
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              event["type"] as? String == "session_meta",
              let payload = event["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              !id.isEmpty else {
            throw SessionManagementBackendError.rolloutIdentityMismatch(sourceLabel)
        }
        try handle.seek(toOffset: 0)
        let historyBase = payload["history_base"] as? [String: Any]
            ?? payload["historyBase"] as? [String: Any]
        return SessionMetadata(
            id: id,
            cwd: payload["cwd"] as? String ?? "",
            sessionID: firstNonemptyOptional([
                payload["session_id"] as? String,
                payload["sessionId"] as? String,
            ]),
            forkedFromID: firstNonemptyOptional([
                payload["forked_from_id"] as? String,
                payload["forkedFromId"] as? String,
                historyBase?["thread_id"] as? String,
                historyBase?["threadId"] as? String,
            ]),
            parentThreadID: firstNonemptyOptional([
                payload["parent_thread_id"] as? String,
                payload["parentThreadId"] as? String,
            ]),
            source: sourceDescription(payload["source"])
        )
    }

    static func fileIdentity(
        url: URL,
        fileManager: FileManager
    ) -> SessionManagementFileIdentity? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let deviceID = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            return nil
        }
        return SessionManagementFileIdentity(
            deviceID: deviceID,
            fileID: fileID,
            size: size,
            modifiedAt: attributes[.modificationDate] as? Date
        )
    }

    static func fileIdentity(
        fileDescriptor: Int32
    ) -> SessionManagementFileIdentity? {
        var value = stat()
        guard Darwin.fstat(fileDescriptor, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        let modifiedAt = Date(
            timeIntervalSince1970:
                TimeInterval(value.st_mtimespec.tv_sec)
                + TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return SessionManagementFileIdentity(
            deviceID: UInt64(value.st_dev),
            fileID: UInt64(value.st_ino),
            size: Int64(value.st_size),
            modifiedAt: modifiedAt
        )
    }

    static func createRecoveryPackageSync(
        thread: SessionManagementThread,
        dataSource: CodexDataSource,
        expectedSnapshot: SessionManagementRolloutSnapshot?,
        fileManager: FileManager
    ) throws -> SessionManagementRecoveryPackageResult {
        try CodexThreadID.validate(thread.id)
        let sourceBinding = try bindTrustedRollout(
            thread.rolloutPath,
            dataSource: dataSource,
            fileManager: fileManager
        )
        defer { sourceBinding.close() }
        let source = sourceBinding.boundFile.file.displayURL
        let relativePath = sourceBinding.relativePath
        let packageBinding: PinnedRecoveryPackageDirectory
        do {
            packageBinding = try pinRecoveryPackageDirectory(
                dataSource: dataSource,
                createParents: true
            )
        } catch {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "恢复包目录含不可信路径组件：\(error.localizedDescription)"
            )
        }
        defer { packageBinding.close() }
        let packageDirectory = packageBinding.url
        do {
            try packageBinding.verify()
            try cleanupAbandonedRecoveryArtifacts(
                packageBinding: packageBinding
            )
        } catch {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "恢复包目录身份无法固定：\(error.localizedDescription)"
            )
        }
        let stagingDirectory = packageDirectory.appendingPathComponent(
            ".\(thread.id)-\(UUID().uuidString).staging",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let partialURL = packageDirectory.appendingPathComponent(
            ".\(thread.id)-\(UUID().uuidString).partial.zip"
        )
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
            try? fileManager.removeItem(at: partialURL)
        }
        let manifestURL = stagingDirectory.appendingPathComponent("manifest.json")
        let rolloutMemberURL = stagingDirectory.appendingPathComponent("rollout.jsonl")

        guard !source.lastPathComponent.hasSuffix(".zst") else {
            throw SessionManagementBackendError.compressedContextUnsupported
        }
        let sourceDescriptor = Darwin.dup(
            sourceBinding.boundFile.descriptor.rawValue
        )
        guard sourceDescriptor >= 0 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "无法复制已绑定的会话正文描述符：\(String(cString: strerror(errno)))"
            )
        }
        _ = fcntl(sourceDescriptor, F_SETFD, FD_CLOEXEC)
        let sourceHandle = FileHandle(
            fileDescriptor: sourceDescriptor,
            closeOnDealloc: true
        )
        defer { try? sourceHandle.close() }
        guard let identity = fileIdentity(fileDescriptor: sourceDescriptor),
              let metadata = try? readSessionMetadata(
                from: sourceHandle,
                sourceLabel: source.lastPathComponent
              ),
              metadata.id == thread.id else {
            throw SessionManagementBackendError.rolloutIdentityMismatch(thread.id)
        }
        if let expectedSnapshot {
            guard expectedSnapshot.threadID == thread.id,
                  expectedSnapshot.relativePath == relativePath,
                  expectedSnapshot.fileIdentity == identity else {
                throw SessionManagementBackendError.recoveryEvidenceMismatch(
                    thread.id
                )
            }
        }
        func verifyBoundSource(_ phase: String) throws {
            guard fileIdentity(fileDescriptor: sourceDescriptor) == identity else {
                throw SessionManagementBackendError.recoveryPackageFailed(
                    "源会话在\(phase)期间发生变化，已停止打包"
                )
            }
            do {
                try sourceBinding.homeDirectory.verifyBoundFile(
                    sourceBinding.boundFile
                )
            } catch {
                throw SessionManagementBackendError.recoveryPackageFailed(
                    "源会话父目录或路径在\(phase)期间发生变化，已停止打包：\(error.localizedDescription)"
                )
            }
        }
        let copied = try copyAndHashRollout(
            sourceHandle: sourceHandle,
            destinationURL: rolloutMemberURL
        )
        guard copied.byteCount == identity.size else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "源会话在快照复制期间发生变化，已停止打包"
            )
        }
        if let expectedSnapshot,
           (copied.sha256 != expectedSnapshot.sha256
            || copied.byteCount != expectedSnapshot.fileIdentity.size) {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(
                thread.id
            )
        }
        try verifyBoundSource("快照复制")
        try packageBinding.verify()
        let manifest = SessionManagementRecoveryPackageManifest(
            schemaVersion: SessionManagementRecoveryPackageManifest.schemaVersion,
            threadID: thread.id,
            createdAt: Int64(floor(Date().timeIntervalSince1970)),
            originalRelativePath: relativePath,
            originalByteCount: copied.byteCount,
            sha256: copied.sha256,
            compression: SessionManagementRecoveryPackageManifest.compressionMethod,
            restoreSupported: false
        )
        let finalURL = packageDirectory.appendingPathComponent(
            "\(thread.id)-\(manifest.sha256).ctb-session.zip"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        if fileManager.fileExists(atPath: finalURL.path) {
            do {
                var metadata = stat()
                guard Darwin.lstat(finalURL.path, &metadata) == 0,
                      (metadata.st_mode & S_IFMT) == S_IFREG else {
                    throw SessionManagementBackendError.recoveryPackageFailed(
                        "既有恢复包不是常规文件"
                    )
                }
                try packageBinding.verify()
                let verified = try verifyRecoveryPackage(
                    at: finalURL,
                    expectedManifest: manifest,
                    requireExactManifest: false,
                    fileManager: fileManager
                )
                try packageBinding.verify()
                try verifyBoundSource("既有恢复包复核")
                let packageEvidence = try pinnedPackageEvidence(
                    packageURL: finalURL,
                    packageBinding: packageBinding
                )
                return SessionManagementRecoveryPackageResult(
                    packageURL: finalURL,
                    manifest: verified.manifest,
                    compressedBytes: verified.compressedBytes,
                    sourceIdentity: identity,
                    packageIdentity: packageEvidence.identity,
                    packageSHA256: packageEvidence.sha256
                )
            } catch {
                let attributes = try? fileManager.attributesOfItem(
                    atPath: finalURL.path
                )
                let packageEvidence = try? pinnedPackageEvidence(
                    packageURL: finalURL,
                    packageBinding: packageBinding
                )
                throw SessionManagementPublishedRecoveryPackageError(
                    result: SessionManagementRecoveryPackageResult(
                        packageURL: finalURL,
                        manifest: manifest,
                        compressedBytes:
                            (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                        sourceIdentity: identity,
                        packageIdentity: packageEvidence?.identity
                            ?? SessionManagementFileIdentity(
                                deviceID: 0,
                                fileID: 0,
                                size:
                                    (attributes?[.size] as? NSNumber)?
                                        .int64Value ?? 0,
                                modifiedAt:
                                    attributes?[.modificationDate] as? Date
                            ),
                        packageSHA256: packageEvidence?.sha256 ?? ""
                    ),
                    detail: error.localizedDescription
                )
            }
        }

        let zip = try CodexThreadDeleteSubprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: [
                "-9",
                "-j",
                partialURL.path,
                rolloutMemberURL.path,
                manifestURL.path,
            ],
            timeout: 6 * 60 * 60
        )
        guard zip.terminationStatus == 0 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                zip.stderr.isEmpty ? zip.stdout : zip.stderr
            )
        }
        try verifyBoundSource("压缩")
        try packageBinding.verify()
        _ = try verifyRecoveryPackage(
            at: partialURL,
            expectedManifest: manifest,
            requireExactManifest: true,
            fileManager: fileManager
        )
        try verifyBoundSource("回读校验")
        try packageBinding.verify()
        try syncPinnedRegularFile(
            name: partialURL.lastPathComponent,
            packageBinding: packageBinding
        )
        try packageBinding.verify()
        try providerSyncRenameExclusive(
            fromDirectory: packageBinding.anchor.parent.rawValue,
            fromName: partialURL.lastPathComponent,
            toDirectory: packageBinding.anchor.parent.rawValue,
            toName: finalURL.lastPathComponent
        )
        do {
            guard Darwin.fsync(packageBinding.anchor.parent.rawValue) == 0 else {
                throw SessionManagementBackendError.recoveryPackageFailed(
                    "恢复包目录发布后持久化失败"
                )
            }
            let verified = try verifyRecoveryPackage(
                at: finalURL,
                expectedManifest: manifest,
                requireExactManifest: true,
                fileManager: fileManager
            )
            try packageBinding.verify()
            try verifyBoundSource("最终发布复核")
            let packageEvidence = try pinnedPackageEvidence(
                packageURL: finalURL,
                packageBinding: packageBinding
            )
            return SessionManagementRecoveryPackageResult(
                packageURL: finalURL,
                manifest: verified.manifest,
                compressedBytes: verified.compressedBytes,
                sourceIdentity: identity,
                packageIdentity: packageEvidence.identity,
                packageSHA256: packageEvidence.sha256
            )
        } catch {
            let attributes = try? fileManager.attributesOfItem(
                atPath: finalURL.path
            )
            let compressedBytes =
                (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let packageEvidence = try? pinnedPackageEvidence(
                packageURL: finalURL,
                packageBinding: packageBinding
            )
            throw SessionManagementPublishedRecoveryPackageError(
                result: SessionManagementRecoveryPackageResult(
                    packageURL: finalURL,
                    manifest: manifest,
                    compressedBytes: compressedBytes,
                    sourceIdentity: identity,
                    packageIdentity: packageEvidence?.identity
                        ?? SessionManagementFileIdentity(
                            deviceID: 0,
                            fileID: 0,
                            size: compressedBytes,
                            modifiedAt:
                                attributes?[.modificationDate] as? Date
                        ),
                    packageSHA256: packageEvidence?.sha256 ?? ""
                ),
                detail: error.localizedDescription
            )
        }
    }

    static func syncPinnedRegularFile(
        name: String,
        packageBinding: PinnedRecoveryPackageDirectory
    ) throws {
        guard !name.isEmpty, !name.contains("/") else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "待同步恢复包文件名无效"
            )
        }
        try packageBinding.verify()
        let descriptor = Darwin.openat(
            packageBinding.anchor.parent.rawValue,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "无法相对已固定目录打开待发布恢复包"
            )
        }
        let owned = ProviderSyncOwnedFileDescriptor(descriptor)
        defer { try? owned.close() }
        guard fileIdentity(fileDescriptor: descriptor) != nil,
              Darwin.fsync(descriptor) == 0 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "待发布恢复包同步失败"
            )
        }
        try packageBinding.verify()
    }

    static func copyAndHashRollout(
        sourceHandle: FileHandle,
        destinationURL: URL
    ) throws -> (sha256: String, byteCount: Int64) {
        let destinationDescriptor = Darwin.open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard destinationDescriptor >= 0 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "无法创建恢复包快照：\(String(cString: strerror(errno)))"
            )
        }
        let destinationHandle = FileHandle(
            fileDescriptor: destinationDescriptor,
            closeOnDealloc: true
        )
        defer { try? destinationHandle.close() }
        try sourceHandle.seek(toOffset: 0)
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let data = try sourceHandle.read(upToCount: 1024 * 1024),
              !data.isEmpty {
            hasher.update(data: data)
            let addition = byteCount.addingReportingOverflow(Int64(data.count))
            guard !addition.overflow else {
                throw SessionManagementBackendError.recoveryPackageFailed(
                    "会话正文长度溢出"
                )
            }
            byteCount = addition.partialValue
            try destinationHandle.write(contentsOf: data)
        }
        try destinationHandle.synchronize()
        return (
            hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            byteCount
        )
    }

    static func pinnedPackageEvidence(
        packageURL: URL,
        packageBinding: PinnedRecoveryPackageDirectory
    ) throws -> (
        identity: SessionManagementFileIdentity,
        sha256: String
    ) {
        guard packageURL.deletingLastPathComponent().standardizedFileURL
                == packageBinding.url.standardizedFileURL else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "恢复包路径不属于已固定目录"
            )
        }
        try packageBinding.verify()
        let name = packageURL.lastPathComponent
        guard !name.isEmpty, !name.contains("/") else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "恢复包文件名无效"
            )
        }
        let descriptor = Darwin.openat(
            packageBinding.anchor.parent.rawValue,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "无法绑定已发布恢复包"
            )
        }
        let owned = ProviderSyncOwnedFileDescriptor(descriptor)
        defer { try? owned.close() }
        guard let identity = fileIdentity(fileDescriptor: descriptor),
              let entry = try providerSyncEntryMetadata(
                  directory: packageBinding.anchor.parent.rawValue,
                  name: name
              ),
              (entry.st_mode & S_IFMT) == S_IFREG,
              UInt64(entry.st_dev) == identity.deviceID,
              UInt64(entry.st_ino) == identity.fileID else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "恢复包路径与打开的物理文件不一致"
            )
        }
        let digest = try hashDescriptor(descriptor)
        guard digest.byteCount == identity.size,
              fileIdentity(fileDescriptor: descriptor) == identity else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "恢复包在物理快照期间发生变化"
            )
        }
        try packageBinding.verify()
        return (identity, digest.sha256)
    }

    static func cleanupAbandonedRecoveryArtifacts(
        packageBinding: PinnedRecoveryPackageDirectory
    ) throws {
        try packageBinding.verify()
        let names = try descriptorRelativeDirectoryNames(
            packageBinding.anchor.parent.rawValue
        )
        for name in names.sorted() {
            if isRestrictedRecoveryPartialName(name) {
                guard let metadata = try providerSyncEntryMetadata(
                    directory: packageBinding.anchor.parent.rawValue,
                    name: name
                ) else {
                    continue
                }
                guard (metadata.st_mode & S_IFMT) == S_IFREG else {
                    throw SessionManagementBackendError.recoveryPackageFailed(
                        "遗留 partial 名称被非常规文件占用：\(name)"
                    )
                }
                try providerSyncUnlinkIfExists(
                    directory: packageBinding.anchor.parent.rawValue,
                    name: name
                )
                continue
            }
            guard isRestrictedRecoveryStagingName(name) else { continue }
            guard let metadata = try providerSyncEntryMetadata(
                directory: packageBinding.anchor.parent.rawValue,
                name: name
            ),
                  (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw SessionManagementBackendError.recoveryPackageFailed(
                    "遗留 staging 名称被非目录占用：\(name)"
                )
            }
            let descriptor = Darwin.openat(
                packageBinding.anchor.parent.rawValue,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw SessionManagementBackendError.recoveryPackageFailed(
                    "无法绑定遗留 staging：\(name)"
                )
            }
            let owned = ProviderSyncOwnedFileDescriptor(descriptor)
            do {
                let members = try descriptorRelativeDirectoryNames(descriptor)
                let allowed = Set(["manifest.json", "rollout.jsonl"])
                guard Set(members).isSubset(of: allowed) else {
                    throw SessionManagementBackendError.recoveryPackageFailed(
                        "遗留 staging 含非受限成员，未自动删除：\(name)"
                    )
                }
                for member in members {
                    guard let memberMetadata = try providerSyncEntryMetadata(
                        directory: descriptor,
                        name: member
                    ),
                          (memberMetadata.st_mode & S_IFMT) == S_IFREG else {
                        throw SessionManagementBackendError
                            .recoveryPackageFailed(
                                "遗留 staging 成员不是常规文件：\(name)/\(member)"
                            )
                    }
                    try providerSyncUnlinkIfExists(
                        directory: descriptor,
                        name: member
                    )
                }
                try owned.close()
                try providerSyncUnlinkIfExists(
                    directory: packageBinding.anchor.parent.rawValue,
                    name: name,
                    flags: AT_REMOVEDIR
                )
            } catch {
                try? owned.close()
                throw error
            }
        }
        guard Darwin.fsync(packageBinding.anchor.parent.rawValue) == 0 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "恢复包目录清理后持久化失败"
            )
        }
        try packageBinding.verify()
    }

    static func descriptorRelativeDirectoryNames(
        _ directory: Int32
    ) throws -> [String] {
        let descriptor = Darwin.openat(
            directory,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "无法复制已固定恢复包目录"
            )
        }
        guard let stream = Darwin.fdopendir(descriptor) else {
            let savedError = errno
            Darwin.close(descriptor)
            throw SessionManagementBackendError.recoveryPackageFailed(
                "无法枚举已固定恢复包目录："
                    + String(cString: strerror(savedError))
            )
        }
        defer { Darwin.closedir(stream) }
        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(stream) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: length + 1
                ) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "枚举已固定恢复包目录失败："
                    + String(cString: strerror(errno))
            )
        }
        return names
    }

    static func isRestrictedRecoveryStagingName(_ name: String) -> Bool {
        isRestrictedRecoveryTemporaryName(
            name,
            suffix: ".staging"
        )
    }

    static func isRestrictedRecoveryPartialName(_ name: String) -> Bool {
        isRestrictedRecoveryTemporaryName(
            name,
            suffix: ".partial.zip"
        )
    }

    static func isRestrictedRecoveryTemporaryName(
        _ name: String,
        suffix: String
    ) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(suffix) else {
            return false
        }
        let body = String(
            name.dropFirst().dropLast(suffix.count)
        )
        guard body.count == 73 else { return false }
        let separator = body.index(body.startIndex, offsetBy: 36)
        guard body[separator] == "-" else { return false }
        let first = String(body[..<separator])
        let secondStart = body.index(after: separator)
        let second = String(body[secondStart...])
        return UUID(uuidString: first) != nil
            && UUID(uuidString: second) != nil
    }

    static func verifyRecoveryEvidence(
        _ evidence: SessionManagementRecoveryPackageResult,
        thread: SessionManagementThread,
        expectedSnapshot: SessionManagementRolloutSnapshot?,
        dataSource: CodexDataSource,
        fileManager: FileManager
    ) throws {
        guard evidence.manifest.threadID == thread.id,
              evidence.manifest.originalByteCount == evidence.sourceIdentity.size,
              evidence.packageURL.lastPathComponent
                == "\(thread.id)-\(evidence.manifest.sha256).ctb-session.zip" else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }
        let packageBinding: PinnedRecoveryPackageDirectory
        do {
            packageBinding = try pinRecoveryPackageDirectory(
                dataSource: dataSource,
                createParents: false
            )
        } catch {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }
        defer { packageBinding.close() }
        let expectedPackageDirectory = packageBinding.url.standardizedFileURL
        guard evidence.packageURL.deletingLastPathComponent().standardizedFileURL
                == expectedPackageDirectory else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }
        var packageMetadata = stat()
        guard Darwin.lstat(evidence.packageURL.path, &packageMetadata) == 0,
              (packageMetadata.st_mode & S_IFMT) == S_IFREG else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }
        let verifiedPackage: (
            manifest: SessionManagementRecoveryPackageManifest,
            compressedBytes: Int64
        )
        do {
            try packageBinding.verify()
            verifiedPackage = try verifyRecoveryPackage(
                at: evidence.packageURL,
                expectedManifest: evidence.manifest,
                requireExactManifest: true,
                fileManager: fileManager
            )
            try packageBinding.verify()
        } catch {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }
        guard verifiedPackage.compressedBytes == evidence.compressedBytes else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }
        let packageEvidence: (
            identity: SessionManagementFileIdentity,
            sha256: String
        )
        do {
            packageEvidence = try pinnedPackageEvidence(
                packageURL: evidence.packageURL,
                packageBinding: packageBinding
            )
        } catch {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }
        guard packageEvidence.identity == evidence.packageIdentity,
              packageEvidence.sha256 == evidence.packageSHA256 else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }

        let sourceBinding: TrustedRolloutBinding
        do {
            sourceBinding = try bindTrustedRollout(
                thread.rolloutPath,
                dataSource: dataSource,
                fileManager: fileManager
            )
        } catch {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }
        defer { sourceBinding.close() }
        guard sourceBinding.relativePath
                == evidence.manifest.originalRelativePath else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }
        let descriptor = Darwin.dup(
            sourceBinding.boundFile.descriptor.rawValue
        )
        guard descriptor >= 0 else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let identity = fileIdentity(fileDescriptor: descriptor),
              identity == evidence.sourceIdentity,
              let metadata = try? readSessionMetadata(
                from: handle,
                sourceLabel: sourceBinding.boundFile.file.displayURL.lastPathComponent
              ),
              metadata.id == thread.id else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }
        if let expectedSnapshot {
            guard expectedSnapshot.threadID == thread.id,
                  expectedSnapshot.relativePath == sourceBinding.relativePath,
                  expectedSnapshot.fileIdentity == identity,
                  expectedSnapshot.sha256 == evidence.manifest.sha256 else {
                throw SessionManagementBackendError.recoveryEvidenceMismatch(
                    thread.id
                )
            }
        }
        let digest = try hashRollout(sourceHandle: handle)
        guard digest.byteCount == evidence.manifest.originalByteCount,
              digest.sha256 == evidence.manifest.sha256,
              fileIdentity(fileDescriptor: descriptor)
                == evidence.sourceIdentity else {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }
        do {
            try sourceBinding.homeDirectory.verifyBoundFile(
                sourceBinding.boundFile
            )
        } catch {
            throw SessionManagementBackendError.recoveryEvidenceMismatch(thread.id)
        }
    }

    static func hashRollout(
        sourceHandle: FileHandle
    ) throws -> (sha256: String, byteCount: Int64) {
        try sourceHandle.seek(toOffset: 0)
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let data = try sourceHandle.read(upToCount: 1024 * 1024),
              !data.isEmpty {
            hasher.update(data: data)
            let addition = byteCount.addingReportingOverflow(Int64(data.count))
            guard !addition.overflow else {
                throw SessionManagementBackendError.recoveryPackageFailed(
                    "会话正文长度溢出"
                )
            }
            byteCount = addition.partialValue
        }
        return (
            hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            byteCount
        )
    }

    static func verifyRecoveryPackage(
        at packageURL: URL,
        expectedManifest: SessionManagementRecoveryPackageManifest,
        requireExactManifest: Bool,
        fileManager: FileManager
    ) throws -> (
        manifest: SessionManagementRecoveryPackageManifest,
        compressedBytes: Int64
    ) {
        let test = try CodexThreadDeleteSubprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-t", packageURL.path],
            timeout: 60
        )
        guard test.terminationStatus == 0 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                test.stderr.isEmpty ? test.stdout : test.stderr
            )
        }
        let manifestRead = try CodexThreadDeleteSubprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", packageURL.path, "manifest.json"],
            timeout: 60
        )
        guard manifestRead.terminationStatus == 0,
              let manifestData = manifestRead.stdout.data(using: .utf8) else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "压缩包内 manifest 无法读取"
            )
        }
        let decoded = try JSONDecoder().decode(
            SessionManagementRecoveryPackageManifest.self,
            from: manifestData
        )
        let matchingContent =
            decoded.schemaVersion == expectedManifest.schemaVersion
            && decoded.threadID == expectedManifest.threadID
            && decoded.originalRelativePath == expectedManifest.originalRelativePath
            && decoded.originalByteCount == expectedManifest.originalByteCount
            && decoded.sha256 == expectedManifest.sha256
            && decoded.compression == expectedManifest.compression
            && decoded.restoreSupported == expectedManifest.restoreSupported
        guard matchingContent,
              !requireExactManifest || decoded == expectedManifest else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "压缩包内 manifest 校验不一致"
            )
        }
        let recovered = try streamedZipMemberDigest(
            packageURL: packageURL,
            memberName: "rollout.jsonl"
        )
        guard recovered.byteCount == decoded.originalByteCount,
              recovered.sha256 == decoded.sha256 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "压缩包内会话正文的长度或 SHA-256 校验失败"
            )
        }
        let compressedBytes = (
            try fileManager.attributesOfItem(atPath: packageURL.path)[.size]
                as? NSNumber
        )?.int64Value ?? 0
        return (decoded, compressedBytes)
    }

    static func streamedZipMemberDigest(
        packageURL: URL,
        memberName: String
    ) throws -> (sha256: String, byteCount: Int64) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", packageURL.path, memberName]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let errorCollector = SessionManagementPipeTailCollector(
            handle: error.fileHandleForReading,
            maximumBytes: 64 * 1024
        )
        try process.run()
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let data = try output.fileHandleForReading.read(upToCount: 1024 * 1024),
              !data.isEmpty {
            hasher.update(data: data)
            let (next, overflow) = byteCount.addingReportingOverflow(Int64(data.count))
            guard !overflow else {
                process.terminate()
                throw SessionManagementBackendError.recoveryPackageFailed(
                    "恢复包成员长度溢出"
                )
            }
            byteCount = next
        }
        process.waitUntilExit()
        let stderr = errorCollector.finish()
        guard process.terminationStatus == 0 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                stderr.isEmpty ? "无法回读压缩包成员" : stderr
            )
        }
        return (
            hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            byteCount
        )
    }

    static func syncFile(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "无法打开待发布恢复包进行持久化确认"
            )
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "恢复包持久化确认失败"
            )
        }
    }

    static func syncDirectory(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "无法打开恢复包目录进行持久化确认"
            )
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw SessionManagementBackendError.recoveryPackageFailed(
                "恢复包目录持久化确认失败"
            )
        }
    }

    static func sourceDescription(_ value: Any?) -> String {
        if let string = value as? String { return string }
        guard let object = value as? [String: Any] else { return "" }
        return (object["type"] as? String)
            ?? (object["kind"] as? String)
            ?? object.keys.sorted().first
            ?? ""
    }

    static func firstNonempty(_ values: [String?]) -> String {
        firstNonemptyOptional(values) ?? ""
    }

    static func firstNonemptyOptional(_ values: [String?]) -> String? {
        values.compactMap {
            let value = $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }.first
    }

    static func preferredDate(seconds: Double?, milliseconds: Double?) -> Date? {
        if let milliseconds, milliseconds > 0 {
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }
        return epochDate(seconds)
    }

    static func epochDate(_ raw: Double?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
    }

    static func utf8Prefix(
        _ value: String,
        maximumBytes: Int
    ) -> (text: String, truncated: Bool) {
        let data = Data(value.utf8)
        guard data.count > maximumBytes else { return (value, false) }
        var end = maximumBytes
        while end > 0, String(data: data.prefix(end), encoding: .utf8) == nil {
            end -= 1
        }
        return (
            String(data: data.prefix(end), encoding: .utf8) ?? "",
            true
        )
    }
}

private final class SessionManagementTextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumUTF8Bytes: Int
    private var data = Data()
    private var truncated = false

    init(maximumUTF8Bytes: Int) {
        self.maximumUTF8Bytes = max(1, maximumUTF8Bytes)
    }

    func append(_ value: String) {
        lock.withLock {
            let incoming = Data(value.utf8)
            let remaining = max(0, maximumUTF8Bytes - data.count)
            if incoming.count <= remaining {
                data.append(incoming)
            } else {
                data.append(incoming.prefix(remaining))
                truncated = true
            }
        }
    }

    func snapshot() -> (text: String, truncated: Bool) {
        lock.withLock {
            var valid = data.count
            while valid > 0, String(data: data.prefix(valid), encoding: .utf8) == nil {
                valid -= 1
            }
            return (
                String(data: data.prefix(valid), encoding: .utf8) ?? "",
                truncated
            )
        }
    }
}

private final class SessionManagementPipeTailCollector: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private let handle: FileHandle
    private let maximumBytes: Int
    private var tail = Data()

    init(handle: FileHandle, maximumBytes: Int) {
        self.handle = handle
        self.maximumBytes = max(0, maximumBytes)
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            while true {
                guard let data = try? handle.read(upToCount: 8 * 1024),
                      !data.isEmpty else {
                    break
                }
                lock.withLock {
                    tail.append(data)
                    if tail.count > self.maximumBytes {
                        tail.removeFirst(tail.count - self.maximumBytes)
                    }
                }
            }
        }
    }

    func finish() -> String {
        _ = group.wait(timeout: .now() + 2)
        try? handle.close()
        return lock.withLock {
            String(decoding: tail, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

enum SessionManagementExternalWriterGate {
    static func runningWriters(
        currentProcessID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> [String] {
        guard let processes = processExecutablePaths() else {
            return ["外部进程状态无法确认"]
        }
        var writers: [String] = []
        for (pid, executablePath) in processes where pid != currentProcessID {
            let normalized = executablePath.lowercased()
            let executableName = URL(fileURLWithPath: executablePath)
                .lastPathComponent
                .lowercased()
            if executableName == "codex" || normalized.contains("/codex.app/") {
                writers.append("Codex (PID \(pid))")
            }
        }
        return Array(Set(writers)).sorted()
    }

    private static func processExecutablePaths() -> [(pid: Int32, path: String)]? {
        var capacity = 1_024
        var processIDs: [Int32]
        var count: Int32
        while true {
            processIDs = [Int32](repeating: 0, count: capacity)
            count = processIDs.withUnsafeMutableBytes { rawBuffer in
                proc_listallpids(rawBuffer.baseAddress, Int32(rawBuffer.count))
            }
            guard count >= 0 else { return nil }
            if Int(count) < capacity {
                break
            }
            let (next, overflow) = capacity.multipliedReportingOverflow(by: 2)
            guard !overflow, next <= 1_048_576 else { return nil }
            capacity = next
        }

        var result: [(pid: Int32, path: String)] = []
        result.reserveCapacity(Int(count))
        for pid in processIDs.prefix(Int(count)) where pid > 0 {
            var pathBuffer = [CChar](repeating: 0, count: 4_096)
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard length > 0 else {
                // 进程可能已在枚举后退出；不能据此把整个探测误判为失败。
                continue
            }
            let end = pathBuffer.firstIndex(of: 0) ?? min(Int(length), pathBuffer.count)
            let bytes = pathBuffer[..<end].map { UInt8(bitPattern: $0) }
            result.append((pid, String(decoding: bytes, as: UTF8.self)))
        }
        return result
    }
}
