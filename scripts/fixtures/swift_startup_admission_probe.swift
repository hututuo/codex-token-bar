// Bounded admission regression probe. The migration/SQLite files are compiled from this checkout.
// Exact discovery is deliberately unavailable; this is not a complete application startup test.
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
enum AppResources { static func url(forResource: String, withExtension: String) -> URL? { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TOKENBAR_FIXTURE_REPO"]!).appendingPathComponent("Sources/CodexTokenBar/Resources/" + forResource + "." + withExtension) } }
struct SourceFileObservation { let size: UInt64; let modifiedAt: Double; let physicalStamp: String; init(indexedLogicalSize: UInt64, modifiedAt: Double, physicalStamp: String) { size=indexedLogicalSize; self.modifiedAt=modifiedAt; self.physicalStamp=physicalStamp } }
struct CodexUsageIndexUpgradeRequiredError: Error {}
enum CodexUsageHistoryIndex {
 static func businessIndexDirectory(legacyCache: Bool = false) -> URL { fatalError("production discovery prohibited by fixture") }
 static func prepareBusinessSnapshot(at: URL) throws { fatalError("exact normalization not used by permission fixture") }
}
import Foundation

@main struct RiskProbe {
 static func main() throws {
  let fm=FileManager.default
  let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
  try fm.createDirectory(at:root,withIntermediateDirectories:true)
  let support=root.appendingPathComponent("support")
  let quota=support.appendingPathComponent("quota-history.sqlite")
  try SQLiteDatabaseDriver(url:quota,bypassBusinessRoutes:true).execute("CREATE TABLE preserved(id INTEGER PRIMARY KEY,value INTEGER); INSERT INTO preserved VALUES(42,123)")
  let c=BusinessDatabaseMigration.Configuration(container:support.appendingPathComponent("codex-ledger.sqlite"),support:support,exact:root.appendingPathComponent("exact"),legacyExact:root.appendingPathComponent("legacy"))
  try BusinessDatabaseMigration.migrate(c,availableBytes:1<<32)
  let raw=SQLiteDatabaseDriver(url:c.container,readOnly:true,bypassBusinessRoutes:true)
  func activation() throws -> String { try raw.readRows("SELECT value FROM tb_container_meta WHERE key='activation_state'",map:{$0.text(0) ?? ""}).first ?? "missing" }
  print("initial_activation=\(try activation())")
  BusinessSQLiteRoutes.deactivate()
  let late=support.appendingPathComponent("body-speed-late.sqlite")
  try SQLiteDatabaseDriver(url:late,bypassBusinessRoutes:true).execute("CREATE TABLE preserved(id INTEGER PRIMARY KEY,value INTEGER); INSERT INTO preserved VALUES(77,456)")
  do { try BusinessDatabaseMigration.migrate(c,availableBytes:0); print("UNEXPECTED_NO_FAILURE") }
  catch { print("injected_space_failure=\(error.localizedDescription)") }
  let failedActivation = try activation()
  print("activation_after_failed_added_import=\(failedActivation)")
  print("initialized_marker_still_present=\(fm.fileExists(atPath:c.container.appendingPathExtension("initialized").path))")
  let store=BusinessSQLiteStore(containerURL:c.container,logicalURL:quota,module:"quota.swift",sourceIdentity:"quota-history.sqlite")
  print("existing_ledger_row_still_intact=\(try raw.readRows("SELECT value FROM \(SQLiteStoreNamespace.quote(store.prefix+"preserved")) WHERE id=42",map:{$0.int(0) ?? -1}))")
  let routeAvailable = BusinessSQLiteRoutes.store(for:quota) != nil
  print("routes_active_after_failure=\(routeAvailable)")
  try BusinessDatabaseMigration.migrate(c,availableBytes:1<<32)
  print("activation_after_space_restored=\(try activation())")
  print("restored_old_row=\(try SQLiteDatabaseDriver(url:quota).readRows("SELECT value FROM preserved WHERE id=42",map:{$0.int(0) ?? -1}))")
  print("restored_new_row=\(try SQLiteDatabaseDriver(url:late).readRows("SELECT value FROM preserved WHERE id=77",map:{$0.int(0) ?? -1}))")
  BusinessSQLiteRoutes.deactivate()
  guard failedActivation == "ready", routeAvailable else {
   fputs("FAIL: a deferred late import hid previously published ledger capabilities\n", stderr)
   exit(1)
  }
  print("PASS: late-import failure preserved the published ledger")
 }
}
