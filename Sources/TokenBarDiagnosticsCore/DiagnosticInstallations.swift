import Foundation
import CryptoKit

public enum DiagnosticInstallations {
    private struct Receipt: Codable {
        let schema: Int
        let attempt: String
        let targetVersion: String
        let targetBuild: String
        let sourceBuild: String
        let binding: String
    }
    private static func binding(_ app: URL) -> String {
        SHA256.hash(data:Data(app.standardizedFileURL.resolvingSymlinksInPath().path.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    /// Private installation identity is never copied to the exported bundle.
    public static func prepare(configuration: DiagnosticConfiguration, attempt: String, targetVersion: String, targetBuild: String, sourceBuild: String) {
        guard let app = configuration.application, let id = UUID(uuidString:attempt)?.uuidString.lowercased(),
              DiagnosticEvent.version(targetBuild) != "unknown", DiagnosticEvent.version(targetVersion) != "unknown" else { return }
        let root = configuration.journal.appendingPathComponent("installations")
        do {
            try DiagnosticFiles.ownedDirectory(root)
            let receipt = Receipt(schema:1, attempt:id, targetVersion:targetVersion, targetBuild:targetBuild,
                sourceBuild:DiagnosticEvent.version(sourceBuild), binding:binding(app))
            try DiagnosticFiles.create(root.appendingPathComponent("pending-\(id).json"), data:JSONEncoder().encode(receipt))
        } catch { /* Receipts observe installation; they never authorize it. */ }
    }
    public static func confirm(configuration: DiagnosticConfiguration, version: String, build: String, journal: DiagnosticJournal) {
        guard let app=configuration.application, let current=UInt64(build) else { return }
        let root=configuration.journal.appendingPathComponent("installations")
        guard let files=try? DiagnosticFiles.files(root,prefix:"pending-",suffix:".json") else{return}
        for file in files.prefix(32) {
            guard let bytes=try? DiagnosticFiles.read(file,limit:8192),let receipt=try? JSONDecoder().decode(Receipt.self,from:bytes),
                  receipt.schema==1,let id=UUID(uuidString:receipt.attempt)?.uuidString.lowercased(),
                  receipt.binding==binding(app),let target=UInt64(receipt.targetBuild),current>=target,
                  DiagnosticEvent.version(version)==DiagnosticEvent.version(receipt.targetVersion),
                  receipt.sourceBuild=="unknown" || current>(UInt64(receipt.sourceBuild) ?? UInt64.max) else{continue}
            do {
                try DiagnosticFiles.create(root.appendingPathComponent("confirmed-\(id).json"),data:Data("{\"schema\":1,\"confirmed\":true}\n".utf8))
                journal.record(.updater,.confirmed,attempt:id,targetVersion:receipt.targetVersion,targetBuild:receipt.targetBuild)
            }catch{}
        }
    }
}
