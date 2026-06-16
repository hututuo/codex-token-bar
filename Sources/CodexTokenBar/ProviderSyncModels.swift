import Foundation

struct ProviderSyncProviderCount: Identifiable, Equatable {
    var id: String { provider }
    let provider: String
    let count: Int
}

struct ProviderSyncSQLiteCount: Identifiable, Equatable {
    var id: String { "\(provider)-\(archived)" }
    let provider: String
    let archived: Int
    let count: Int
}

struct ProviderSyncWorkspaceIssue: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let label: String
    let threadCount: Int
}

struct ProviderSyncWorkspaceCount: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let label: String
    let threadCount: Int
    let interactiveThreadCount: Int
    let isActive: Bool
}

struct ProviderSyncVisibilitySummary: Equatable {
    var sqliteThreads: Int = 0
    var activeThreads: Int = 0
    var archivedThreads: Int = 0
    var userThreads: Int = 0
    var desktopUserThreads: Int = 0
    var currentWorkspaceDesktopThreads: Int = 0
    var cliExecUserThreads: Int = 0
    var subagentThreads: Int = 0
    var activeWorkspacePath: String?
    var workspaces: [ProviderSyncWorkspaceCount] = []
}

struct ProviderSyncBackupRecord: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let createdAt: Date
    let sequence: Int
    let targetProvider: String
    let sessionFileCount: Int
}

struct ProviderSyncSnapshot: Equatable {
    var codexHome: String = "~/.codex"
    var detectedProvider: String = "openai"
    var providerSource: String = "等待扫描"
    var sessionFilesFound: Int = 0
    var sessionProviders: [ProviderSyncProviderCount] = []
    var sqliteProviders: [ProviderSyncSQLiteCount] = []
    var invalidSessionFiles: Int = 0
    var changedSessionFiles: Int = 0
    var sqliteRowsChanged: Int = 0
    var sqliteRowsToRepair: Int = 0
    var sqliteIntegrity: String = "未验证"
    var sessionIndexCurrentThreadPresent: Bool = false
    var sessionIndexRows: Int = 0
    var workspaceOrderMissing: Int = 0
    var workspaceIssues: [ProviderSyncWorkspaceIssue] = []
    var visibilitySummary = ProviderSyncVisibilitySummary()
    var codexRunning: Bool = false
    var lastBackupPath: String?
    var backupRecords: [ProviderSyncBackupRecord] = []
    var status: String = "扫描后可同步历史 provider"
    var isWorking: Bool = false

    var hasMixedProviders: Bool {
        sessionProviders.count > 1 || Set(sqliteProviders.map(\.provider)).count > 1
    }

    var compactProviderSummary: String {
        guard !sessionProviders.isEmpty else { return "未扫描" }
        return sessionProviders
            .prefix(3)
            .map { "\($0.provider) \($0.count)" }
            .joined(separator: "  ")
    }
}
