import Foundation

struct CodexControlledProcess: Codable, Equatable, Sendable {
    var pid: UInt32
    var executablePath: String
    var userDataMarker: String
    var startedAt: Int64
    var processStartIdentity: String
}

struct CodexInstance: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var codexHome: String
    var electronDataDirectory: String
    var workingDirectory: String?
    var arguments: [String]
    var managed: Bool
    var isDefault: Bool
    var autoSyncEnabled: Bool
    var createdAt: Int64
    var updatedAt: Int64
    var controlledProcess: CodexControlledProcess?
}

struct CodexInstanceConflict: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var threadId: String
    var instanceIds: [String]
    var relativePaths: [String]
    var hashes: [String]
    var detectedAt: Int64
    var reason: String
    var resolved: Bool
}

struct CodexInstanceRegistrySnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var updatedAt: Int64
    var instances: [CodexInstance]
    var conflicts: [CodexInstanceConflict]
    var registryPath: String
}

enum CodexInstanceCreateMode: String, Codable, Sendable {
    case empty
    case copyConfiguration
}

struct CodexInstanceCreateRequest: Codable, Equatable, Sendable {
    var name: String
    var mode: CodexInstanceCreateMode
    var sourceHome: String?
    var copyAuth: Bool
    var workingDirectory: String?
    var arguments: [String]
    var autoSyncEnabled: Bool
}

struct CodexInstanceImportRequest: Codable, Equatable, Sendable {
    var name: String
    var codexHome: String
    var workingDirectory: String?
    var arguments: [String]
    var autoSyncEnabled: Bool
}

struct CodexInstanceUpdateRequest: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var workingDirectory: String?
    var arguments: [String]
    var autoSyncEnabled: Bool
}

struct CodexInstanceActionResult: Codable, Equatable, Sendable {
    var instance: CodexInstance?
    var message: String
}

struct CodexInstanceRuntimeStatus: Codable, Equatable, Sendable {
    var id: String
    var running: Bool
    var controlled: Bool
    var pid: UInt32?
    var message: String
}

struct CodexInstanceSyncOperation: Codable, Equatable, Sendable {
    var threadId: String
    var sourceInstanceId: String
    var destinationInstanceId: String
    var sourcePath: String
    var destinationPath: String
    var kind: String
    var sourceHash: String
    var destinationHash: String?
    var backupPath: String?
    var installedHash: String?
}

struct CodexInstanceSyncPreview: Codable, Equatable, Sendable {
    var instanceIds: [String]
    var operations: [CodexInstanceSyncOperation]
    var conflicts: [CodexInstanceConflict]
    var unchangedThreads: Int
}

struct CodexInstanceSyncResult: Codable, Equatable, Sendable {
    var transactionId: String?
    var operationsApplied: Int
    var conflicts: [CodexInstanceConflict]
    var message: String
}

struct CodexInstanceSyncTransactionSummary: Codable, Equatable, Identifiable, Sendable {
    var transactionId: String
    var createdAt: Int64
    var state: String
    var instanceIds: [String]
    var operations: Int
    var conflicts: Int

    var id: String { transactionId }
}
