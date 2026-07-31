import Foundation

enum SessionManagementThreadStatus: String, Codable, CaseIterable, Sendable {
    case notLoaded
    case idle
    case active
    case loaded
    case systemError
    case unknown

    init(appServerValue: String?) {
        let normalized = appServerValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter(\.isLetter)
        switch normalized {
        case "notloaded": self = .notLoaded
        case "idle": self = .idle
        case "active": self = .active
        case "loaded": self = .loaded
        case "systemerror": self = .systemError
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .notLoaded: return "未加载"
        case .idle: return "空闲"
        case .active: return "运行中"
        case .loaded: return "已加载"
        case .systemError: return "系统错误"
        case .unknown: return "状态未知"
        }
    }

    var permitsMutation: Bool {
        self == .notLoaded
    }
}

enum SessionManagementCollection: String, CaseIterable, Identifiable, Sendable {
    case all
    case recent
    case officialArchive
    case large
    case forks
    case similar
    case subagents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部会话"
        case .recent: return "最近使用"
        case .officialArchive: return "官方归档"
        case .large: return "大容量"
        case .forks: return "Fork 分支"
        case .similar: return "可能相似"
        case .subagents: return "Subagent"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "rectangle.stack"
        case .recent: return "clock"
        case .officialArchive: return "archivebox"
        case .large: return "internaldrive"
        case .forks: return "arrow.triangle.branch"
        case .similar: return "square.on.square"
        case .subagents: return "person.2"
        }
    }
}

enum SessionManagementSort: String, CaseIterable, Identifiable, Sendable {
    case recent
    case size
    case oldest
    case title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return "最近使用"
        case .size: return "容量"
        case .oldest: return "最久未用"
        case .title: return "标题"
        }
    }
}

enum SessionManagementInactivityFilter: String, CaseIterable, Identifiable, Sendable {
    case any
    case fiveDays
    case tenDays
    case thirtyDays
    case oneMonth
    case threeMonths
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: return "不限"
        case .fiveDays: return "5 天以上"
        case .tenDays: return "10 天以上"
        case .thirtyDays: return "30 天以上"
        case .oneMonth: return "1 个月以上"
        case .threeMonths: return "3 个月以上"
        case .custom: return "自定义"
        }
    }

    var requiresCustomDays: Bool {
        self == .custom
    }

    func matches(
        lastUsedAt: Date?,
        now: Date,
        customDays: Int?,
        calendar: Calendar
    ) -> Bool {
        guard self != .any else { return true }
        guard let lastUsedAt,
              let boundary = boundary(
                  now: now,
                  customDays: customDays,
                  calendar: calendar
              ) else {
            return false
        }
        return lastUsedAt <= boundary
    }

    private func boundary(
        now: Date,
        customDays: Int?,
        calendar: Calendar
    ) -> Date? {
        switch self {
        case .any:
            return nil
        case .fiveDays:
            return calendar.date(byAdding: .day, value: -5, to: now)
        case .tenDays:
            return calendar.date(byAdding: .day, value: -10, to: now)
        case .thirtyDays:
            return calendar.date(byAdding: .day, value: -30, to: now)
        case .oneMonth:
            return calendar.date(byAdding: .month, value: -1, to: now)
        case .threeMonths:
            return calendar.date(byAdding: .month, value: -3, to: now)
        case .custom:
            guard let customDays, customDays > 0 else { return nil }
            return calendar.date(byAdding: .day, value: -customDays, to: now)
        }
    }
}

struct SessionManagementCapabilities: Equatable, Sendable {
    let canOfficialMutate: Bool
    let canCreateRecoveryPackage: Bool
    let canRestoreRecoveryPackage: Bool
    let recoveryRestoreUnavailableReason: String?

    static let readOnly = SessionManagementCapabilities(
        canOfficialMutate: false,
        canCreateRecoveryPackage: true,
        canRestoreRecoveryPackage: false,
        recoveryRestoreUnavailableReason: "Codex 当前没有官方会话导入接口；恢复功能在能够安全重建官方索引前保持关闭。"
    )
}

struct SessionManagementFileIdentity: Codable, Equatable, Sendable {
    let deviceID: UInt64
    let fileID: UInt64
    let size: Int64
    let modifiedAt: Date?
}

struct SessionManagementRolloutSnapshot: Equatable, Sendable {
    let threadID: String
    let relativePath: String
    let fileIdentity: SessionManagementFileIdentity
    let sha256: String
}

struct SessionManagementThread: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var preview: String
    var firstUserMessage: String
    var cwd: String
    var rolloutPath: String
    var createdAt: Date?
    var updatedAt: Date?
    var recencyAt: Date?
    var archived: Bool
    var archivedAt: Date?
    var tokensUsed: Int64?
    var fileBytes: Int64?
    var fileModifiedAt: Date?
    var status: SessionManagementThreadStatus
    var source: String
    var model: String
    var gitBranch: String
    var sessionID: String?
    var forkedFromID: String?
    var parentThreadID: String?
    var isSubagent: Bool
    var spawnChildCount: Int
    var forkChildCount: Int
    var similarityGroupID: String?
    var similarityReason: String?
    var protectionReasons: [String]
    var canArchive: Bool
    var canUnarchive: Bool
    var canDelete: Bool
    var rolloutIdentityVerified: Bool

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(id.prefix(12)) : trimmed
    }

    var projectID: String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? SessionManagementPresentation.missingProjectID
            : (trimmed as NSString).standardizingPath
    }

    var lastUsedAt: Date? {
        recencyAt ?? updatedAt ?? fileModifiedAt ?? createdAt
    }

    var hasForkLineage: Bool {
        forkedFromID != nil || forkChildCount > 0
    }
}

struct SessionManagementProject: Identifiable, Equatable, Sendable {
    let id: String
    let cwd: String
    let displayName: String
    let threadCount: Int
    let totalBytes: Int64?
    let updatedAt: Date?
}

struct SessionManagementCatalog: Equatable, Sendable {
    var threads: [SessionManagementThread]
    let generatedAt: Date
    let codexHome: String
    var totalBytes: Int64?
    var warnings: [String]
    var capabilities: SessionManagementCapabilities
    var deletionVerificationComplete = true

    static func empty(codexHome: String = "") -> Self {
        Self(
            threads: [],
            generatedAt: Date(),
            codexHome: codexHome,
            totalBytes: nil,
            warnings: [],
            capabilities: .readOnly
        )
    }
}

struct SessionManagementDeletionImpact: Equatable, Sendable {
    let requested: [SessionManagementThread]
    let effectiveRoots: [SessionManagementThread]
    let affected: [SessionManagementThread]
    let indirectDescendants: [SessionManagementThread]
    let externalForkReferences: [SessionManagementThread]
    let totalBytes: Int64?
    let coveringRootIDByThreadID: [String: String]

    static let empty = SessionManagementDeletionImpact(
        requested: [],
        effectiveRoots: [],
        affected: [],
        indirectDescendants: [],
        externalForkReferences: [],
        totalBytes: nil,
        coveringRootIDByThreadID: [:]
    )
}

struct SessionManagementDeletionConfirmation: Equatable, Sendable {
    let impact: SessionManagementDeletionImpact
    let codexHomeIdentity: CodexHomeIdentity
    let rolloutSnapshotsByThreadID: [String: SessionManagementRolloutSnapshot]
}

struct SessionManagementDeletionExpectation: Equatable, Sendable {
    let confirmedRootIDs: [String]
    let confirmedAffectedThreadIDs: [String]
    let pendingRootIDs: [String]
    let pendingAffectedThreadIDs: [String]
    let affectedThreadIDsByRootID: [String: [String]]
    let currentRootID: String
    let requiresRecoveryEvidence: Bool
    let codexHomeIdentity: CodexHomeIdentity
    let rolloutSnapshotsByThreadID: [String: SessionManagementRolloutSnapshot]

    init(
        confirmation: SessionManagementDeletionConfirmation,
        pendingRootIndex: Int,
        requiresRecoveryEvidence: Bool
    ) {
        let confirmedImpact = confirmation.impact
        let roots = confirmedImpact.effectiveRoots.map(\.id)
        let boundedIndex = min(max(0, pendingRootIndex), roots.count)
        let pendingRoots = Array(roots.dropFirst(boundedIndex))
        let pendingRootSet = Set(pendingRoots)
        let affectedByRoot = Dictionary(
            grouping: confirmedImpact.affected,
            by: {
                confirmedImpact.coveringRootIDByThreadID[$0.id] ?? $0.id
            }
        ).mapValues { $0.map(\.id).sorted() }
        let pendingAffected: [String] = confirmedImpact.affected.compactMap {
            thread -> String? in
            guard let rootID =
                    confirmedImpact.coveringRootIDByThreadID[thread.id],
                  pendingRootSet.contains(rootID) else {
                return nil
            }
            return thread.id
        }

        confirmedRootIDs = roots
        confirmedAffectedThreadIDs = confirmedImpact.affected.map(\.id).sorted()
        pendingRootIDs = pendingRoots
        pendingAffectedThreadIDs = pendingAffected
        affectedThreadIDsByRootID = affectedByRoot
        currentRootID = pendingRoots.first ?? ""
        self.requiresRecoveryEvidence = requiresRecoveryEvidence
        codexHomeIdentity = confirmation.codexHomeIdentity
        rolloutSnapshotsByThreadID =
            confirmation.rolloutSnapshotsByThreadID
    }
}

struct SessionManagementContextMessage: Identifiable, Equatable, Sendable {
    let id: String
    let role: String
    let timestamp: String?
    let text: String
    let isTruncated: Bool
    let byteOffset: Int64
}

struct SessionManagementContextPage: Equatable, Sendable {
    let threadID: String
    let messages: [SessionManagementContextMessage]
    let nextBeforeOffset: Int64?
    let hasMoreBefore: Bool
    let fileIdentity: SessionManagementFileIdentity
    let warnings: [String]
}

struct SessionManagementRecoveryPackageManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let compressionMethod = "zip-deflate-9"

    let schemaVersion: Int
    let threadID: String
    let createdAt: Int64
    let originalRelativePath: String
    let originalByteCount: Int64
    let sha256: String
    let compression: String
    let restoreSupported: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case threadID = "threadId"
        case createdAt
        case originalRelativePath
        case originalByteCount = "originalBytes"
        case sha256
        case compression
        case restoreSupported
    }
}

struct SessionManagementRecoveryPackageResult: Equatable, Sendable {
    let packageURL: URL
    let manifest: SessionManagementRecoveryPackageManifest
    let compressedBytes: Int64
    let sourceIdentity: SessionManagementFileIdentity
    let packageIdentity: SessionManagementFileIdentity
    let packageSHA256: String
}

struct SessionManagementPublishedRecoveryPackageError: LocalizedError, Sendable {
    let result: SessionManagementRecoveryPackageResult
    let detail: String

    var errorDescription: String? {
        "恢复包已安全发布到 \(result.packageURL.path)，但发布后的最终复核失败：\(detail)"
    }
}

struct SessionManagementAppServerThread: Equatable, Sendable {
    let id: String
    let title: String
    let preview: String
    let cwd: String
    let rolloutPath: String
    let createdAt: Date?
    let updatedAt: Date?
    let archived: Bool
    let status: SessionManagementThreadStatus
    let source: String
    let model: String
    let sessionID: String?
    let forkedFromID: String?
    let parentThreadID: String?
}

enum SessionManagementPresentation {
    static let visiblePageSize = 100
    static let missingProjectID = "__codex_token_bar_no_cwd__"
    static let largeThreadThreshold: Int64 = 100 * 1024 * 1024

    static func projects(from threads: [SessionManagementThread]) -> [SessionManagementProject] {
        Dictionary(grouping: threads.filter { !$0.isSubagent }, by: \.projectID)
            .map { id, rows in
                let cwd = id == missingProjectID ? "" : id
                let folder = cwd.isEmpty ? "未记录工作目录" : URL(fileURLWithPath: cwd).lastPathComponent
                return SessionManagementProject(
                    id: id,
                    cwd: cwd,
                    displayName: folder.isEmpty ? cwd : folder,
                    threadCount: rows.count,
                    totalBytes: rows.allSatisfy { $0.fileBytes != nil }
                        ? rows.reduce(0) { $0 + max(0, $1.fileBytes ?? 0) }
                        : nil,
                    updatedAt: rows.compactMap(\.lastUsedAt).max()
                )
            }
            .sorted {
                let left = $0.updatedAt ?? .distantPast
                let right = $1.updatedAt ?? .distantPast
                if left != right { return left > right }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    static func filteredThreads(
        in catalog: SessionManagementCatalog,
        collection: SessionManagementCollection,
        projectID: String?,
        query: String,
        sort: SessionManagementSort,
        inactivityFilter: SessionManagementInactivityFilter = .any,
        customInactiveDays: Int? = nil,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [SessionManagementThread] {
        let recentBoundary = now.addingTimeInterval(-7 * 24 * 60 * 60)
        var rows = catalog.threads.filter { thread in
            switch collection {
            case .all:
                return !thread.isSubagent
            case .recent:
                guard !thread.isSubagent,
                      let lastUsedAt = thread.lastUsedAt else {
                    return false
                }
                return lastUsedAt >= recentBoundary
            case .officialArchive:
                return thread.archived
            case .large:
                return (thread.fileBytes ?? -1) >= largeThreadThreshold
            case .forks:
                return thread.hasForkLineage && !thread.isSubagent
            case .similar:
                return thread.similarityGroupID != nil && !thread.isSubagent
            case .subagents:
                return thread.isSubagent
            }
        }
        if let projectID, !projectID.isEmpty {
            rows = rows.filter { $0.projectID == projectID }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            rows = rows.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(needle)
                    || $0.preview.localizedCaseInsensitiveContains(needle)
                    || $0.firstUserMessage.localizedCaseInsensitiveContains(needle)
                    || $0.cwd.localizedCaseInsensitiveContains(needle)
                    || $0.id.localizedCaseInsensitiveContains(needle)
            }
        }
        rows = rows.filter {
            inactivityFilter.matches(
                lastUsedAt: $0.lastUsedAt,
                now: now,
                customDays: customInactiveDays,
                calendar: calendar
            )
        }
        return rows.sorted { left, right in
            switch sort {
            case .recent:
                return compareDate(left.lastUsedAt, right.lastUsedAt, descending: true, leftID: left.id, rightID: right.id)
            case .oldest:
                return compareDate(left.lastUsedAt, right.lastUsedAt, descending: false, leftID: left.id, rightID: right.id)
            case .size:
                if left.fileBytes != right.fileBytes {
                    return (left.fileBytes ?? -1) > (right.fileBytes ?? -1)
                }
                return compareDate(left.lastUsedAt, right.lastUsedAt, descending: true, leftID: left.id, rightID: right.id)
            case .title:
                let order = left.displayTitle.localizedCaseInsensitiveCompare(right.displayTitle)
                return order == .orderedSame ? left.id < right.id : order == .orderedAscending
            }
        }
    }

    static func visibleThreads(
        _ threads: [SessionManagementThread],
        limit: Int,
        selectedThreadID: String?
    ) -> [SessionManagementThread] {
        let boundedLimit = max(1, limit)
        var visible = Array(threads.prefix(boundedLimit))
        guard let selectedThreadID,
              !visible.contains(where: { $0.id == selectedThreadID }),
              let selected = threads.first(where: { $0.id == selectedThreadID }) else {
            return visible
        }
        if visible.count == boundedLimit {
            visible.removeLast()
        }
        visible.append(selected)
        return visible
    }

    static func deletionImpact(
        threads: [SessionManagementThread],
        selectedThreadIDs: Set<String>
    ) -> SessionManagementDeletionImpact {
        let byID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        let requested = threads.filter { selectedThreadIDs.contains($0.id) }
        guard !requested.isEmpty else { return .empty }
        var childrenByParent: [String: [String]] = [:]
        for thread in threads {
            guard let parent = thread.parentThreadID, byID[parent] != nil else { continue }
            childrenByParent[parent, default: []].append(thread.id)
        }
        for key in childrenByParent.keys {
            childrenByParent[key]?.sort()
        }
        func closure(from rootID: String) -> Set<String> {
            var result: Set<String> = []
            var pending = [rootID]
            while let current = pending.popLast() {
                guard result.insert(current).inserted else { continue }
                pending.append(contentsOf: (childrenByParent[current] ?? []).reversed())
            }
            return result
        }

        var effectiveRootIDs: [String] = []
        var closureByRoot: [String: Set<String>] = [:]
        for thread in requested {
            if effectiveRootIDs.contains(where: {
                closureByRoot[$0]?.contains(thread.id) == true
            }) {
                continue
            }
            let selectedClosure = closure(from: thread.id)
            let replacedRoots = effectiveRootIDs.filter(selectedClosure.contains)
            effectiveRootIDs.removeAll(where: selectedClosure.contains)
            for root in replacedRoots {
                closureByRoot.removeValue(forKey: root)
            }
            effectiveRootIDs.append(thread.id)
            closureByRoot[thread.id] = selectedClosure
        }

        var affectedIDs: Set<String> = []
        var affected: [SessionManagementThread] = []
        var coveringRootIDByThreadID: [String: String] = [:]
        for rootID in effectiveRootIDs {
            var ids = Array(closureByRoot[rootID] ?? []).sorted()
            if let rootIndex = ids.firstIndex(of: rootID) {
                ids.remove(at: rootIndex)
                ids.insert(rootID, at: 0)
            }
            for id in ids where affectedIDs.insert(id).inserted {
                if let thread = byID[id] {
                    affected.append(thread)
                    coveringRootIDByThreadID[id] = rootID
                }
            }
        }
        let requestedIDs = Set(requested.map(\.id))
        let externalForkReferences = threads.filter {
            !affectedIDs.contains($0.id)
                && $0.forkedFromID.map(affectedIDs.contains) == true
        }
        var knownTotal: Int64 = 0
        var totalOverflowed = false
        for thread in affected {
            guard let bytes = thread.fileBytes else {
                totalOverflowed = true
                break
            }
            let addition = knownTotal.addingReportingOverflow(max(0, bytes))
            knownTotal = addition.partialValue
            totalOverflowed = totalOverflowed || addition.overflow
        }
        let totalBytes: Int64? = totalOverflowed ? nil : knownTotal
        return SessionManagementDeletionImpact(
            requested: requested,
            effectiveRoots: effectiveRootIDs.compactMap { byID[$0] },
            affected: affected,
            indirectDescendants: affected.filter { !requestedIDs.contains($0.id) },
            externalForkReferences: externalForkReferences,
            totalBytes: totalBytes,
            coveringRootIDByThreadID: coveringRootIDByThreadID
        )
    }

    private static func compareDate(
        _ left: Date?,
        _ right: Date?,
        descending: Bool,
        leftID: String,
        rightID: String
    ) -> Bool {
        let leftDate = left ?? .distantPast
        let rightDate = right ?? .distantPast
        if leftDate == rightDate { return leftID < rightID }
        return descending ? leftDate > rightDate : leftDate < rightDate
    }
}
