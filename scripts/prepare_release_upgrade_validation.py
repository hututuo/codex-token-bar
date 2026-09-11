#!/usr/bin/env python3
"""Export v0.9.1 with test-only fixture producers; production code stays unchanged."""
import io
from pathlib import Path
import subprocess
import sys
import tarfile

SWIFT_HARNESS = r'''
extension CodexUsageAnalyzerTests {
 func testExportActualReleaseSixFromLegacyJSONL() throws {
  let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RELEASE_HOME"]!)
  try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
  let file = home.appendingPathComponent("sessions/rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065a.jsonl")
  let a = try tokenCountLine(timestamp: Date().addingTimeInterval(-600), total: Usage(input:80,cachedInput:0,output:0,reasoning:0,total:80), last: Usage(input:80,cachedInput:0,output:0,reasoning:0,total:80))
  let b = try tokenCountLine(timestamp: Date().addingTimeInterval(-500), total: Usage(input:100,cachedInput:0,output:0,reasoning:0,total:100), last: Usage(input:20,cachedInput:0,output:0,reasoning:0,total:20))
  try ([a,b].joined(separator:"\n")+"\n").write(to:file,atomically:true,encoding:.utf8)
  let target=URL(fileURLWithPath: ProcessInfo.processInfo.environment["RELEASE_OUTPUT"]!)
  XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
  let index=try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL:target)
  let analyzer=CodexUsageAnalyzer(dataSource:dataSource(for:home))
  _ = try index.synchronize(files:[file],sessionID:analyzer.sessionID(from:)) { file,id,request,fp,emit in
   try analyzer.parseSessionIntoHistoryIndex(file:file,sessionID:id,request:request,insertFingerprint:fp,emit:emit)
  }
  let db=SQLiteDatabaseDriver(url:target)
  XCTAssertEqual(try db.readRows("SELECT value FROM schema_meta WHERE key='schema_version'"){$0.text(0)}.first!,"6")
  XCTAssertEqual(try db.readRows("SELECT SUM(tokens) FROM events"){$0.int(0)}.first!,100)
 }
}
'''

RUST_HARNESS = r'''
#[test]
fn export_actual_release_database() {
 let _guard=app_paths::app_path_test_env_guard(&[]);
 let root=PathBuf::from(std::env::var("RELEASE_HOME").unwrap());
 assert!(!root.exists());fs::create_dir_all(root.join("sessions")).unwrap();
 let file=root.join("sessions/rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065a.jsonl");
 let token=|age,total,last|serde_json::json!({"timestamp":recent_test_timestamp(age),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":total,"cached_input_tokens":0,"output_tokens":0,"total_tokens":total},"last_token_usage":{"input_tokens":last,"cached_input_tokens":0,"output_tokens":0,"total_tokens":last}}}}).to_string();
 write_lines(&file,&[token(10,80,80),token(9,100,20)]);
 assert_eq!(dashboard_snapshot(&root).unwrap().stats.total_tokens,100);
 let path=super::exact_usage_index::database_path(&root).unwrap();
 let db=Connection::open(&path).unwrap();
 assert_eq!(db.query_row("SELECT value FROM metadata WHERE key='schema_version'",[],|r|r.get::<_,String>(0)).unwrap(),"9");
 db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
 println!("ACTUAL RELEASE schema9 {}",path.display());
}
'''

SWIFT_HARNESS += r'''
extension CodexUsageAnalyzerTests {
 func testExportActualReleaseSixFromHistoricalBackup() throws {
  let home=URL(fileURLWithPath:ProcessInfo.processInfo.environment["RELEASE_HOME"]!)
  let target=URL(fileURLWithPath:ProcessInfo.processInfo.environment["RELEASE_OUTPUT"]!)
  XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
  let files=(FileManager.default.enumerator(at:home,includingPropertiesForKeys:nil)!.allObjects as! [URL]).filter{$0.pathExtension=="jsonl"}.sorted{$0.path<$1.path}
  XCTAssertEqual(files.count,164)
  let index=try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL:target)
  let analyzer=CodexUsageAnalyzer(dataSource:dataSource(for:home))
  _ = try index.synchronize(files:files,sessionID:analyzer.sessionID(from:)) { file,id,request,fp,emit in
   try analyzer.parseSessionIntoHistoryIndex(file:file,sessionID:id,request:request,insertFingerprint:fp,emit:emit)
  }
  let db=SQLiteDatabaseDriver(url:target)
  XCTAssertEqual(try db.readRows("SELECT value FROM schema_meta WHERE key='schema_version'"){$0.text(0)}.first!,"6")
  print("HISTORICAL RELEASE Swift rows,total",try db.readRows("SELECT COUNT(*),SUM(tokens) FROM events"){[$0.int64(0),$0.int64(1)]})
 }
}
'''
RUST_HARNESS += r'''
#[test]
fn export_actual_release_historical_database() {
 let _guard=app_paths::app_path_test_env_guard(&[]);
 let root=PathBuf::from(std::env::var("RELEASE_HOME").unwrap());
 assert!(root.join("sessions").exists());
 let path=super::exact_usage_index::database_path(&root).unwrap();assert!(!path.exists());
 let snapshot=dashboard_snapshot(&root).unwrap();
 assert!(snapshot.stats.total_tokens>0);
 let db=Connection::open(&path).unwrap();
 assert_eq!(db.query_row("SELECT value FROM metadata WHERE key='schema_version'",[],|r|r.get::<_,String>(0)).unwrap(),"9");
 println!("HISTORICAL RELEASE Rust rows,total {:?}",db.query_row("SELECT COUNT(*),SUM(tokens) FROM events",[],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,i64>(1)?))).unwrap());
 db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
}
'''

def main():
    repository = Path(__file__).resolve().parents[1]
    destination = Path(sys.argv[1]).resolve()
    if destination.exists():
        raise SystemExit("Use a new isolated directory; existing evidence is not overwritten")
    destination.mkdir(parents=True)
    archive = subprocess.check_output(["git", "archive", "v0.9.1"], cwd=repository)
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        source.extractall(destination)
    for relative, harness in [
        ("Tests/CodexTokenBarTests/CodexUsageAnalyzerTests.swift", SWIFT_HARNESS),
        ("tauri-app/src-tauri/src/core/usage/token_count_jsonl/tests.rs", RUST_HARNESS),
    ]:
        with (destination / relative).open("a") as output:
            output.write(harness)
    print(subprocess.check_output(["git", "rev-parse", "v0.9.1^{}"], cwd=repository).decode().strip())
    print(destination)

if __name__ == "__main__":
    main()
