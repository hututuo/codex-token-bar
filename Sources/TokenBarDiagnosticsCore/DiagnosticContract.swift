import Foundation

/// This is a projection contract, not an arbitrary-text logger. Unknown fields
/// are discarded on both intake and export; no source paths or error prose.
public enum DiagnosticArea: String, Codable, CaseIterable, Sendable {
    case startup, updater, installer, migration, index, refresh, backendProgress, uiProgress, storage, frontend, shutdown
}
public enum DiagnosticPhase: String, Codable, CaseIterable, Sendable {
    case started, progress, ready, failed, waiting, checking, available, downloading, downloaded
    case verifying, replacing, launched, confirmed, cancelled, preparing, importing, activating, retained, completed
    case copied, migrated, validated, switching, switched, retiring
}
public struct DiagnosticEvent: Codable, Sendable {
    public let schema: Int
    public let session: String
    public let sequence: Int64
    public let at: Int64
    public let area: DiagnosticArea
    public let phase: DiagnosticPhase
    public let version: String
    public let build: String
    public let metrics: [String: Int64]
    public let attempt: String?
    public let targetVersion: String?
    public let targetBuild: String?

    public static let metricKeys: Set<String> = ["completed", "total", "elapsed_ms", "code", "retry", "generation", "published_generation", "schema_version", "files", "pending", "available", "unavailable", "staged", "consumed", "numeric_ready", "detail_ready", "sequence", "pid", "bytes", "dropped", "backend_at", "ui_at", "stage_code"]
    public init(session: String, sequence: Int64, area: DiagnosticArea, phase: DiagnosticPhase,
                version: String, build: String, metrics: [String: Int64] = [:], attempt: String? = nil,
                targetVersion: String? = nil, targetBuild: String? = nil, at: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        schema = 1; self.session = UUID(uuidString: session)?.uuidString.lowercased() ?? "unknown"
        self.sequence = max(0, sequence); self.at = max(0, at); self.area = area; self.phase = phase
        self.version = Self.version(version); self.build = Self.version(build)
        self.metrics = metrics.filter { Self.metricKeys.contains($0.key) }
        self.attempt = attempt.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        self.targetVersion = targetVersion.map(Self.version); self.targetBuild = targetBuild.map(Self.version)
    }
    public static func version(_ value: String) -> String {
        guard !value.isEmpty, value.count <= 32, value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.count <= 10 }) else { return "unknown" }
        return value
    }
    /// Decode into a typed contract and reconstruct it: synthesized Codable
    /// alone would accept unvalidated strings from tampered on-disk records.
    public static func sanitized(_ bytes: Data) -> DiagnosticEvent? {
        guard bytes.count <= 8192, let row = try? JSONDecoder().decode(Self.self, from: bytes), row.schema == 1,
              UUID(uuidString: row.session) != nil else { return nil }
        return .init(session: row.session, sequence: row.sequence, area: row.area, phase: row.phase,
            version: row.version, build: row.build, metrics: row.metrics, attempt: row.attempt,
            targetVersion: row.targetVersion, targetBuild: row.targetBuild, at: row.at)
    }
}

public struct DiagnosticConfiguration: Sendable {
    public let home: URL
    public let support: URL
    public let journal: URL
    public let application: URL?
    public init(home: URL, application: URL? = nil) {
        self.home = home
        support = home.appendingPathComponent("Library/Application Support/CodexTokenBar")
        journal = support.appendingPathComponent("diagnostics/v1")
        self.application = application
    }
    public static var production: Self {
        .init(home: FileManager.default.homeDirectoryForCurrentUser,
              application: Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil)
    }
}
