// Standalone bounded discovery probe; production seven-file compile is documented in the audit.
// AppResources lookup and unused Exact/SourceFileObservation dependencies are isolated stubs.
import Foundation
protocol DatabaseAccessing {
 func readRows<T>(_ sql: String, bindings: [SQLiteBinding], map: (SQLiteStatement) throws -> T) throws -> [T]
 func execute(_ sql: String, bindings: [SQLiteBinding]) throws
 func transaction<T>(_ body: (SQLiteDatabaseConnection) throws -> T) throws -> T
}
extension DatabaseAccessing {
 func readRows<T>(_ sql: String, map: (SQLiteStatement) throws -> T) throws -> [T] { try readRows(sql, bindings: [], map: map) }
 func execute(_ sql: String) throws { try execute(sql, bindings: []) }
}
enum AppResources { static func url(forResource: String, withExtension: String) -> URL? { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TOKENBAR_AUDIT_REPO"]!).appendingPathComponent("Sources/CodexTokenBar/Resources/" + forResource + "." + withExtension) } }
struct SourceFileObservation { let size: UInt64; let modifiedAt: Double; let physicalStamp: String; init(indexedLogicalSize: UInt64, modifiedAt: Double, physicalStamp: String) { size=indexedLogicalSize; self.modifiedAt=modifiedAt; self.physicalStamp=physicalStamp } }
struct CodexUsageIndexUpgradeRequiredError: Error {}
enum CodexUsageHistoryIndex {
 static func businessIndexDirectory(legacyCache: Bool = false) -> URL { fatalError("production discovery prohibited by fixture") }
 static func prepareBusinessSnapshot(at: URL) throws { fatalError("exact normalization not used by permission fixture") }
}
import Foundation
@main struct Probe {
 static func main() throws {
 let fm = FileManager.default
 let scenario = CommandLine.arguments.dropFirst().first ?? "nested"
 let root = fm.temporaryDirectory.appendingPathComponent("tokenbar-sol-gate-" + UUID().uuidString)
 let support = root.appendingPathComponent("support")
 var exact = root.appendingPathComponent("exact")
 var blocked: URL?
 try fm.createDirectory(at: root, withIntermediateDirectories: true)
 switch scenario {
 case "nested":
   let directory = support.appendingPathComponent("modeltrace")
   try fm.createDirectory(at: directory, withIntermediateDirectories: true)
   try SQLiteDatabaseDriver(url: directory.appendingPathComponent("modeltrace.sqlite"), bypassBusinessRoutes: true).execute("CREATE TABLE preserved(id INTEGER PRIMARY KEY); INSERT INTO preserved VALUES(42)")
   blocked=directory
 case "root":
   try fm.createDirectory(at: exact, withIntermediateDirectories: true)
   try SQLiteDatabaseDriver(url: exact.appendingPathComponent(String(repeating:"a",count:64)+".sqlite"), bypassBusinessRoutes:true).execute("CREATE TABLE preserved(id INTEGER PRIMARY KEY); INSERT INTO preserved VALUES(17)")
   blocked=exact
 case "ancestor":
   let parent=root.appendingPathComponent("blocked")
   exact=parent.appendingPathComponent("exact")
   try fm.createDirectory(at: exact, withIntermediateDirectories: true)
   blocked=parent
 case "root-symlink":
   let actual=root.appendingPathComponent("actual-exact")
   try fm.createDirectory(at: actual, withIntermediateDirectories: true)
   try fm.createSymbolicLink(at:exact,withDestinationURL:actual)
 case "dangling":
   try fm.createSymbolicLink(at:exact,withDestinationURL:root.appendingPathComponent("missing-exact"))
 case "absent": break
 default: fatalError("unsupported scenario")
 }
 if let blocked { try fm.setAttributes([.posixPermissions:0o000],ofItemAtPath:blocked.path) }
 defer { BusinessSQLiteRoutes.deactivate(); if let blocked { try? fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:blocked.path) }; try? fm.removeItem(at:root) }
 let c = BusinessDatabaseMigration.Configuration(container:support.appendingPathComponent("codex-ledger.sqlite"),support:support,exact:exact,legacyExact:root.appendingPathComponent("legacy-exact"))
 var ready=false
 do { try BusinessDatabaseMigration.migrate(c,availableBytes:1<<32); ready=true } catch { print("migration_error",String(describing:error)) }
 let marked=fm.fileExists(atPath:c.container.appendingPathExtension("initialized").path)
 let expected=["absent","root-symlink"].contains(scenario)
 print("scenario=\(scenario) ready=\(ready) initialized=\(marked) expected_ready=\(expected) pass=\(ready==expected && marked==expected)")
 }
}
