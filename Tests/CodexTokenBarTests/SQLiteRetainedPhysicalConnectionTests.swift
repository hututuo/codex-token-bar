import Foundation
import XCTest
@testable import CodexTokenBar

final class SQLiteRetainedPhysicalConnectionTests: XCTestCase {
    private func directory() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("retained-physical-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root
    }
    private func bound() throws -> (CodexBusinessDatabase,BusinessSQLiteStore,SQLiteDatabaseDriver) {
        let root=try directory(),logical=root.appendingPathComponent("safety.sqlite")
        let container=try CodexBusinessDatabase(url:root.appendingPathComponent("codex-ledger.sqlite"))
        let store=BusinessSQLiteStore(containerURL:container.url,logicalURL:logical,module:"fixture",sourceIdentity:"safety")
        try container.register(store)
        BusinessSQLiteRoutes.install([store])
        addTeardownBlock { BusinessSQLiteRoutes.remove([store]) }
        try SQLiteDatabaseDriver(url:logical).execute("CREATE TABLE facts(value INTEGER); INSERT INTO facts VALUES(1)")
        return (container,store,SQLiteDatabaseDriver(url:logical,createsFileIfMissing:false,retainsPhysicalConnection:true))
    }

    func testRetainedPhysicalHandleKeepsFreshRowsAndNamespaceWithoutRepeatedOpens() throws {
        let (_,_,driver)=try bound()
        for _ in 0..<12 {
            XCTAssertEqual(try driver.readRows("SELECT value FROM facts"){$0.int(0)!},[1])
        }
        XCTAssertEqual(driver.physicalOpenCount,1,"Do not reparse the entire physical catalog for each safety read")
        let other=SQLiteDatabaseDriver(url:driver.url,createsFileIfMissing:false)
        try other.execute("INSERT INTO facts VALUES(2); CREATE TABLE late(value INTEGER); INSERT INTO late VALUES(7)")
        XCTAssertEqual(try driver.readRows("SELECT value FROM facts ORDER BY value"){$0.int(0)!},[1,2])
        XCTAssertEqual(try driver.readRows("SELECT value FROM late"){$0.int(0)!},[7],"Binding names must be refreshed even when the physical handle is reused")
        XCTAssertEqual(driver.physicalOpenCount,1)
    }

    func testRetainedHandleRechecksSealedOwnerAndRouteOnEveryOperation() throws {
        let (container,store,driver)=try bound()
        XCTAssertEqual(try driver.readRows("SELECT COUNT(*) FROM facts"){$0.int(0)!},[1])
        try container.driver.execute("UPDATE tb_stores SET state='sealed' WHERE store_id=?",bindings:[.text(store.id)])
        XCTAssertEqual(try driver.readRows("SELECT value FROM facts"){$0.int(0)!},[1])
        XCTAssertThrowsError(try driver.execute("INSERT INTO facts VALUES(2)"))
        try container.driver.execute("UPDATE tb_stores SET state='ready' WHERE store_id=?",bindings:[.text(store.id)])
        try driver.execute("INSERT INTO facts VALUES(3)")
        BusinessSQLiteRoutes.remove([store])
        XCTAssertThrowsError(try driver.execute("INSERT INTO facts VALUES(4)"))
        XCTAssertEqual(try container.driver.readRows("SELECT value FROM \"\(store.prefix)facts\" ORDER BY value"){$0.int(0)!},[1,3])
    }

    func testRetainedCatalogAvoidsRescanningUnchangedSchemaWithoutCachingRows() throws {
        let (_,_,driver)=try bound()
        let writer=SQLiteDatabaseDriver(url:driver.url,createsFileIfMissing:false)
        for value in 2...25 {
            try writer.execute("INSERT INTO facts VALUES(?)",bindings:[.int(value)])
            XCTAssertEqual(try driver.readRows("SELECT COUNT(*) FROM facts"){$0.int(0)!},[value])
        }
        XCTAssertEqual(driver.physicalCatalogReadCount,1,
            "Data-only commits must not enumerate the whole physical schema for each safety read")
        try writer.execute("CREATE TABLE later(value INTEGER);INSERT INTO later VALUES(31)")
        XCTAssertEqual(try driver.readRows("SELECT value FROM later"){$0.int(0)!},[31])
        XCTAssertEqual(driver.physicalCatalogReadCount,2,"External DDL must invalidate the namespace names")
    }

    func testRetainedCatalogSeesExternalRenameDropAndDoesNotAdmitForeignObjects() throws {
        let (container,_,driver)=try bound()
        let writer=SQLiteDatabaseDriver(url:driver.url,createsFileIfMissing:false)
        XCTAssertEqual(try driver.readRows("SELECT value FROM facts"){$0.int(0)!},[1])
        try container.driver.execute("CREATE TABLE unrelated_secret(value INTEGER);INSERT INTO unrelated_secret VALUES(99)")
        XCTAssertThrowsError(try driver.readRows("SELECT value FROM unrelated_secret"){$0.int(0)!})
        try writer.execute("ALTER TABLE facts RENAME TO renamed")
        XCTAssertEqual(try driver.readRows("SELECT value FROM renamed"){$0.int(0)!},[1])
        XCTAssertThrowsError(try driver.readRows("SELECT value FROM facts"){$0.int(0)!})
        try writer.execute("DROP TABLE renamed;CREATE TABLE facts(value INTEGER);INSERT INTO facts VALUES(2)")
        XCTAssertEqual(try driver.readRows("SELECT value FROM facts"){$0.int(0)!},[2])
    }

    func testRetainedCatalogDoesNotPublishUncommittedDDLOrRollbackNames() throws {
        let (_,_,driver)=try bound()
        XCTAssertEqual(try driver.readRows("SELECT value FROM facts"){$0.int(0)!},[1])
        let writer=SQLiteDatabaseDriver(url:driver.url,createsFileIfMissing:false)
        enum Stop:Error {case now}
        XCTAssertThrowsError(try writer.transaction { c in
            try c.execute("CREATE TABLE transient(value INTEGER)")
            throw Stop.now
        })
        XCTAssertEqual(try driver.readRows("SELECT value FROM facts"){$0.int(0)!},[1])
        XCTAssertEqual(driver.physicalCatalogReadCount,1,"A rolled-back schema must not invalidate the committed catalog")
        XCTAssertThrowsError(try driver.readRows("SELECT value FROM transient"){$0.int(0)!})
        try writer.execute("CREATE TABLE committed(value INTEGER);INSERT INTO committed VALUES(7)")
        XCTAssertEqual(try driver.readRows("SELECT value FROM committed"){$0.int(0)!},[7])
    }

    func testRetainedHandlePreservesRollbackAndIndependentCommits() throws {
        let (_,_,driver)=try bound()
        enum Stop:Error {case now}
        XCTAssertThrowsError(try driver.transaction { c in try c.execute("INSERT INTO facts VALUES(9)");throw Stop.now })
        XCTAssertEqual(try driver.readRows("SELECT value FROM facts"){$0.int(0)!},[1])
        try driver.withOperationConnection {
            try driver.transaction { try $0.execute("INSERT INTO facts VALUES(2)") }
            let other=SQLiteDatabaseDriver(url:driver.url,readOnly:true,createsFileIfMissing:false)
            XCTAssertEqual(try other.readRows("SELECT value FROM facts ORDER BY value"){$0.int(0)!},[1,2])
        }
        // A caller forgetting its COMMIT has always been rolled back by close.
        try driver.execute("BEGIN IMMEDIATE; INSERT INTO facts VALUES(99)")
        XCTAssertEqual(try driver.readRows("SELECT value FROM facts ORDER BY value"){$0.int(0)!},[1,2])
    }

    func testRetainedHandleDoesNotKeepReadingAReplacedPhysicalFile() throws {
        let root=try directory(),url=root.appendingPathComponent("db.sqlite")
        try SQLiteDatabaseDriver(url:url).execute("CREATE TABLE facts(value INTEGER);INSERT INTO facts VALUES(1)")
        let driver=SQLiteDatabaseDriver(url:url,createsFileIfMissing:false,retainsPhysicalConnection:true)
        XCTAssertEqual(try driver.readRows("SELECT value FROM facts"){$0.int(0)!},[1])
        try FileManager.default.moveItem(at:url,to:url.appendingPathExtension("retired"))
        try SQLiteDatabaseDriver(url:url).execute("CREATE TABLE facts(value INTEGER);INSERT INTO facts VALUES(2)")
        XCTAssertEqual(try driver.readRows("SELECT value FROM facts"){$0.int(0)!},[2])
        XCTAssertEqual(driver.physicalOpenCount,2)
    }

    func testRetainedHandleRejectsValidPhysicalAReplacementAndBlockedAdmission() throws {
        let (container,store,driver)=try bound()
        let root=container.url.deletingLastPathComponent()
        let configuration=BusinessDatabaseMigration.Configuration(container:container.url,support:root,
            exact:root.appendingPathComponent("exact"),legacyExact:root.appendingPathComponent("legacy"))
        BusinessSQLiteRoutes.activate(configuration,stores:[store])
        defer { BusinessSQLiteRoutes.deactivate() }
        XCTAssertEqual(try driver.readRows("SELECT value FROM facts"){$0.int(0)!},[1])
        BusinessSQLiteRoutes.activate(configuration,stores:[store],blockedReads:[store.id],blockedWrites:[store.id])
        XCTAssertThrowsError(try driver.readRows("SELECT value FROM facts"){$0.int(0)!})
        BusinessSQLiteRoutes.activate(configuration,stores:[store])
        XCTAssertEqual(try driver.readRows("SELECT value FROM facts"){$0.int(0)!},[1])
        // A real valid SQLite replacement must still fail the installed A identity.
        let replacement=root.appendingPathComponent("replacement.sqlite")
        _ = try CodexBusinessDatabase(url:replacement)
        try FileManager.default.moveItem(at:container.url,to:container.url.appendingPathExtension("retained"))
        try FileManager.default.moveItem(at:replacement,to:container.url)
        XCTAssertThrowsError(try driver.readRows("SELECT value FROM facts"){$0.int(0)!})
        XCTAssertThrowsError(try driver.execute("INSERT INTO facts VALUES(99)"))
    }

    func testRetainedPhysicalConnectionSerializesConcurrentTransactions() throws {
        let (_,_,driver)=try bound()
        let failures=Failures(),group=DispatchGroup()
        for value in 2...17 {
            group.enter()
            DispatchQueue.global(qos:.utility).async {
                defer { group.leave() }
                do { try driver.transaction { try $0.execute("INSERT INTO facts VALUES(?)",bindings:[.int(value)]) } }
                catch { failures.add() }
            }
        }
        XCTAssertEqual(group.wait(timeout:.now()+10),.success)
        XCTAssertEqual(failures.count,0)
        XCTAssertEqual(try driver.readRows("SELECT COUNT(*),SUM(value) FROM facts"){[$0.int(0)!,$0.int(1)!]},[[17,153]])
        XCTAssertEqual(driver.physicalOpenCount,1)
    }

    func testSafetyOperationNeverHoldsPhysicalMutexBeforeRecoveryGate() throws {
        let root=try directory()
        let safety=SharedAccountUsageSafetyDatabase(url:root.appendingPathComponent("safety.sqlite"))
        let data=Data("{}".utf8)
        XCTAssertTrue(safety.store(data,as:.preciseContinuity))
        let finished=DispatchSemaphore(value:0),failures=Failures()
        safety.withOperationConnection {
            DispatchQueue.global(qos:.utility).async {
                if safety.load(.preciseContinuity) != data { failures.add() }
                finished.signal()
            }
            XCTAssertEqual(finished.wait(timeout:.now()+1),.success,
                "An outer attribution scope must not hold the driver while another read owns the recovery gate")
            XCTAssertEqual(safety.load(.preciseContinuity),data)
        }
        XCTAssertEqual(failures.count,0)
        XCTAssertTrue(safety.persistenceHealthy)
    }
}

private final class Failures:@unchecked Sendable {
    private let lock=NSLock();private var value=0
    func add(){lock.lock();value+=1;lock.unlock()}
    var count:Int{lock.lock();defer{lock.unlock()};return value}
}
