#!/usr/bin/env python3
"""Create a fixed-release producer checkout and verify its synthetic upgrade inputs.

No installed application, user database, or network API is opened. The old
checkout receives one test-only producer; all production files come from the
verified release commit. Run its XCTest before invoking ``verify``.
"""

import argparse
import hashlib
import io
import json
from pathlib import Path
import sqlite3
import subprocess
import tarfile
import tempfile

RELEASE_TAG = "v0.9.7"
RELEASE_SHA = "0219554ce444b0013987da7b82e3c2e891f4afdb"
EXACT_NAMES = [character * 64 + ".sqlite" for character in "ab"]

PRODUCER = r'''
import Foundation
import XCTest
@testable import CodexTokenBar

/// Built against the unmodified production implementation at the public tag.
final class Release097FixtureProducerTests: XCTestCase {
    func testExportActualV097Inputs() throws {
        let configured = try XCTUnwrap(ProcessInfo.processInfo.environment["TOKENBAR_V097_FIXTURE_ROOT"])
        let root = URL(fileURLWithPath: configured).appendingPathComponent("inputs")
        let manager = FileManager.default
        let exact = root.appendingPathComponent("exact", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try manager.createDirectory(at: exact, withIntermediateDirectories: true)
        try manager.createDirectory(at: support, withIntermediateDirectories: true)
        let session = "019ff8b9-09e7-75c1-b9a5-14fe7b60065a"
        for (number, letter) in ["a", "b"].enumerated() {
            let scale = number + 1
            let home = root.appendingPathComponent("home-\(letter)")
            try manager.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            let file = home.appendingPathComponent("sessions/rollout-\(session).jsonl")
            func token(_ timestamp: String, input: Int, cached: Int, output: Int, reasoning: Int,
                       lastInput: Int, lastCached: Int, lastOutput: Int, lastReasoning: Int) throws -> String {
                func usage(_ i: Int, _ c: Int, _ o: Int, _ r: Int) -> [String: Int] {
                    ["input_tokens": i * scale, "cached_input_tokens": c * scale,
                     "output_tokens": o * scale, "reasoning_output_tokens": r * scale,
                     "total_tokens": (i + o) * scale]
                }
                let value: [String: Any] = ["timestamp": timestamp, "type": "event_msg", "payload": [
                    "type": "token_count", "info": [
                        "total_token_usage": usage(input, cached, output, reasoning),
                        "last_token_usage": usage(lastInput, lastCached, lastOutput, lastReasoning)
                    ]
                ]]
                return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
            }
            let lines = [
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\"}}",
                "{\"timestamp\":\"2026-10-21T10:00:00Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-6.1-sol\"}}",
                try token("2026-10-21T10:00:01Z", input: 80, cached: 32, output: 20, reasoning: 5,
                          lastInput: 80, lastCached: 32, lastOutput: 20, lastReasoning: 5),
                try token("2026-10-21T10:00:02Z", input: 120, cached: 48, output: 35, reasoning: 8,
                          lastInput: 40, lastCached: 16, lastOutput: 15, lastReasoning: 3)
            ]
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            let target = exact.appendingPathComponent(String(repeating: letter, count: 64) + ".sqlite")
            XCTAssertFalse(manager.fileExists(atPath: target.path), "Never overwrite an earlier release fixture")
            let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: target)
            let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: home, origin: .userSelected))
            _ = try index.synchronize(files: [file], sessionID: analyzer.sessionID(from:)) { file, id, request, fingerprint, emit in
                try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                                                         insertFingerprint: fingerprint, emit: emit)
            }
            let database = SQLiteDatabaseDriver(url: target)
            XCTAssertEqual(try database.readRows("SELECT value FROM schema_meta WHERE key='schema_version'") { $0.text(0) }, ["14"])
            XCTAssertEqual(try database.readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }, [155 * scale])
            _ = try database.readRows("PRAGMA wal_checkpoint(TRUNCATE)") { $0.int(0) }
            _ = try database.readRows("PRAGMA journal_mode=DELETE") { $0.text(0) }
        }

        // The released production initializer creates this schema, not a
        // current empty database relabelled with an old version number.
        let quota = support.appendingPathComponent("quota-history.sqlite")
        try QuotaHistoryDatabase(databaseURL: quota).migrate()
        let database = SQLiteDatabaseDriver(url: quota)
        try database.execute("""
            INSERT INTO quota_snapshots(id,created_at,account_key,source,plan_type,limit_name,account_name,
                five_hour_used_percent,five_hour_resets_at,seven_day_used_percent,seven_day_resets_at,
                status,identity_version,home_identity,stable_account_key,identity_plan_type,identity_limit_id,
                five_hour_cycle_generation,five_hour_reset_anchor,seven_day_cycle_generation,seven_day_reset_anchor)
            VALUES(42,1800000000,?,'synthetic-release097','pro','codex','synthetic',12,1800003600,23,1800600000,
                'available',1,'synthetic-home','synthetic-account','pro','codex',2,1800000000,3,1800000000);
            """, bindings: [.text("synthetic\0account")])
        try database.execute("UPDATE sqlite_sequence SET seq=12345 WHERE name='quota_snapshots'")
        _ = try database.readRows("PRAGMA wal_checkpoint(TRUNCATE)") { $0.int(0) }
        _ = try database.readRows("PRAGMA journal_mode=DELETE") { $0.text(0) }

        let body = ObservedSpeedSample(
            id: "v097-body", threadID: "synthetic-thread", turnID: "synthetic-turn", itemID: "synthetic-item",
            model: "gpt-6.1-sol", startedAt: 1800000536, endedAt: 1800000540,
            outputTokens: 200, outputCharacters: 400, outputBytes: 400, chunkCount: 1,
            durationSeconds: 4, tokensPerSecond: 50, confidence: "high", networkWarning: nil,
            source: "synthetic-v097", measurementKind: "completed_body", tokenizer: "o200k_base", bodyPhase: "final_answer")
        var stream = body
        stream.id = "v097-retired-stream"
        stream.measurementKind = nil
        stream.tokenizer = nil
        let legacyJSON = support.appendingPathComponent("observed-speed-release097.json")
        var collector = ObservedSpeedCollector(storeURL: legacyJSON)
        collector.samples = [body, stream]
        collector.persist()
        XCTAssertNil(collector.persistenceError)
        XCTAssertEqual(ObservedSpeedCollector(storeURL: legacyJSON).samples, [body, stream])
        print("V097_PRODUCER_READY exact=2 quota=1 json=1 synthetic=true")
    }
}
'''

# This test is appended only to the archived public tag's existing test module.
# Exact and quota schemas are created by that tag's real production functions.
RUST_PRODUCER = r'''

#[test]
fn release097_export_actual_rust_inputs() {
    let configured = PathBuf::from(std::env::var("TOKENBAR_V097_FIXTURE_ROOT").expect("required isolated fixture root"));
    let root = configured.join("inputs");
    let old_support = root.join("producer-support");
    let _guard = app_paths::app_path_test_env_guard(&[
        ("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", old_support.clone()),
        ("CODEX_TOKEN_BAR_TAURI_CACHE_DIR", root.join("producer-cache")),
        ("CODEX_TOKEN_BAR_SUPPORT_BASE_DIR", root.join("producer-shared-support")),
        ("CODEX_TOKEN_BAR_CACHE_BASE_DIR", root.join("producer-shared-cache")),
        ("CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR", root.join("producer-old-cache")),
    ]);
    fs::create_dir_all(root.join("exact")).unwrap();
    fs::create_dir_all(root.join("support")).unwrap();
    let date = |at: i64| OffsetDateTime::from_unix_timestamp(at).unwrap().format(&Rfc3339).unwrap();
    let now = OffsetDateTime::now_utc().unix_timestamp();
    for (letter, scale) in [("a", 1_u64), ("b", 2_u64)] {
        let home = root.join(format!("home-{letter}"));
        fs::create_dir_all(home.join("sessions")).unwrap();
        let file = home.join("sessions/rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065a.jsonl");
        let token = |age: i64, input: u64, cached: u64, output: u64, reasoning: u64,
                     li: u64, lc: u64, lo: u64, lr: u64| {
            let usage = |i: u64, c: u64, o: u64, r: u64| serde_json::json!({
                "input_tokens": i*scale, "cached_input_tokens": c*scale, "output_tokens": o*scale,
                "reasoning_output_tokens": r*scale, "total_tokens": (i+o)*scale
            });
            serde_json::json!({"timestamp":date(now-age),"type":"event_msg","payload":{
                "type":"token_count","info":{"total_token_usage":usage(input,cached,output,reasoning),
                "last_token_usage":usage(li,lc,lo,lr)}}}).to_string()
        };
        write_lines(&file, &[
            r#"{"type":"session_meta","payload":{"id":"019ff8b9-09e7-75c1-b9a5-14fe7b60065a"}}"#.to_owned(),
            serde_json::json!({"timestamp":date(now-65),"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}).to_string(),
            token(64,80,32,20,5,80,32,20,5), token(63,120,48,35,8,40,16,15,3),
        ]);
        assert_eq!(dashboard_snapshot(&home).unwrap().stats.total_tokens,155*scale);
        let source = super::exact_usage_index::database_path(&home).unwrap();
        let database = Connection::open(&source).unwrap();
        assert_eq!(database.query_row("SELECT value FROM metadata WHERE key='schema_version'",[],|r|r.get::<_,String>(0)).unwrap(),"14");
        database.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;").unwrap();
        drop(database);
        fs::copy(&source, root.join(format!("exact/{letter}.sqlite3"))).unwrap();
    }
    let home = fs::canonicalize(root.join("home-a")).unwrap();
    let identity = crate::core::quota_history::QuotaHistoryIdentity::from_canonical_parts(&home,Some("sub:release097"),"pro","codex").unwrap();
    let bundle = crate::models::AccountQuotaBundle {
        updated_at: date(now), attribution_identity: None,
        account: crate::models::AccountInfo { display_name:"Synthetic v097".into(),plan_label:"pro".into() },
        quota: crate::models::QuotaSnapshot {
            five_hour: crate::models::QuotaLimit {label:"5h".into(),availability:crate::models::QuotaAvailability::Measured,
                remaining_percent:Some(65.0),used_percent:Some(35.0),resets_at:date(now+10000),resets_at_unix:Some(now+10000),cycle_id:Some("v097-5h".into())},
            seven_day: crate::models::QuotaLimit {label:"7d".into(),availability:crate::models::QuotaAvailability::Measured,
                remaining_percent:Some(70.0),used_percent:Some(30.0),resets_at:date(now+200000),resets_at_unix:Some(now+200000),cycle_id:Some("v097-7d".into())},
            reserve_windows:vec![],reset_credit:crate::models::ResetCreditSummary{available_count:0,status:"synthetic".into(),credits:vec![]},pace_label:"synthetic".into()
        }, quota_history_daily:vec![],quota_history_24h:vec![],quota_history_7d:vec![],quota_history_30d:vec![],warnings:vec![],diagnostics:vec![]
    };
    crate::core::quota_history::record_bundle(&identity,&bundle).unwrap();
    let source = app_paths::quota_history_database_path().unwrap();
    let database = Connection::open(&source).unwrap();
    assert_eq!(database.query_row("SELECT COUNT(*) FROM quota_snapshots",[],|r|r.get::<_,i64>(0)).unwrap(),1);
    database.execute_batch("UPDATE quota_snapshots SET id=42; UPDATE sqlite_sequence SET seq=12345 WHERE name='quota_snapshots'; PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;").unwrap();
    drop(database);
    fs::copy(source,root.join("support/quota-history.sqlite")).unwrap();
    let sample = crate::models::SpeedSample {
        id:"v097-rust-body".into(),thread_id:"synthetic-thread".into(),turn_id:"synthetic-turn".into(),item_id:"synthetic-item".into(),
        model:Some("gpt-6.1-sol".into()),started_at:(now-64) as f64,ended_at:(now-60) as f64,output_tokens:200,
        output_characters:400,output_bytes:400,chunk_count:4,duration_seconds:4.0,tokens_per_second:50.0,
        confidence:"medium".into(),network_warning:None,source:"synthetic-v097".into(),
        measurement_kind:Some("completed_body".into()),tokenizer:Some("o200k_base".into()),body_phase:Some("final_answer".into()),quality_reason:None,
    };
    let mut stream = sample.clone(); stream.id="v097-rust-retired-stream".into();stream.measurement_kind=None;stream.tokenizer=None;
    // Serialize the public tag's SpeedSample, in its verified StoredSamples v1
    // envelope (observed.rs:78). No current schema or current sample type is used.
    let bytes=serde_json::to_vec(&serde_json::json!({"version":1,"samples":[sample,stream],"bodyRetentionDays":15})).unwrap();
    fs::write(root.join("support/observed-speed-release097.json"),bytes).unwrap();
    println!("V097_RUST_PRODUCER_READY exact=2 quota=1 json=1 synthetic=true");
}
'''


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extract_revision(repository, revision, destination):
    archive = subprocess.check_output(["git", "archive", revision], cwd=repository)
    destination.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        for member in source.getmembers():
            target = (destination / member.name).resolve()
            if not target.is_relative_to(destination.resolve()):
                raise SystemExit(f"Unsafe archive member: {member.name}")
            if member.issym() or member.islnk():
                parent = destination if member.islnk() else target.parent
                if not (parent / member.linkname).resolve().is_relative_to(destination.resolve()):
                    raise SystemExit(f"Unsafe archive link: {member.name}")
        options = {"filter": "data"} if hasattr(tarfile, "data_filter") else {}
        source.extractall(destination, **options)


def prepare(source_dir, fixture_dir, platform="swift"):
    repository = Path(__file__).resolve().parents[1]
    actual = subprocess.check_output(
        ["git", "rev-parse", f"{RELEASE_TAG}^{{commit}}"], cwd=repository, text=True
    ).strip()
    if actual != RELEASE_SHA:
        raise SystemExit(f"Release tag mismatch: expected {RELEASE_SHA}, found {actual}")
    if source_dir.exists() or fixture_dir.exists():
        raise SystemExit("Use new source and fixture directories; existing evidence is never overwritten")
    extract_revision(repository, RELEASE_SHA, source_dir)
    producer_source = PRODUCER if platform == "swift" else RUST_PRODUCER
    if platform == "swift":
        producer = source_dir / "Tests/CodexTokenBarTests/Release097FixtureProducerTests.swift"
        producer.write_text(producer_source)
    else:
        producer = source_dir / "tauri-app/src-tauri/src/core/usage/token_count_jsonl/tests.rs"
        with producer.open("a") as output:
            output.write(producer_source)
    inputs = fixture_dir / "inputs"
    inputs.mkdir(parents=True)
    (inputs / "provenance.json").write_text(json.dumps({
        "release_tag": RELEASE_TAG,
        "release_sha": RELEASE_SHA,
        "platform": platform,
        "synthetic": True,
        "producer_sha256": hashlib.sha256(producer_source.encode()).hexdigest(),
    }, indent=2) + "\n")
    print(json.dumps({"source_dir": str(source_dir), "fixture_dir": str(fixture_dir), "release_sha": actual}))


def verify(fixture_dir, platform="swift"):
    inputs = fixture_dir / "inputs"
    provenance = json.loads((inputs / "provenance.json").read_text())
    if provenance.get("release_sha") != RELEASE_SHA or provenance.get("synthetic") is not True or provenance.get("platform", "swift") != platform:
        raise SystemExit("Fixture provenance does not identify the pinned synthetic release producer")
    artifacts = {}
    exact_names = EXACT_NAMES if platform == "swift" else ["a.sqlite3", "b.sqlite3"]
    metadata = "schema_meta" if platform == "swift" else "metadata"
    events = "events" if platform == "swift" else "event_rows"
    for name in exact_names:
        relative = "exact/" + name
        database = inputs / relative
        with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
            schema = connection.execute(f"SELECT value FROM {metadata} WHERE key='schema_version'").fetchone()[0]
            count, tokens = connection.execute(f"SELECT COUNT(*),COALESCE(SUM(tokens),0) FROM {events}").fetchone()
            check = connection.execute("PRAGMA quick_check").fetchall()
        expected_tokens = 155 if name.startswith("a") else 310
        if schema != "14" or count < 2 or tokens != expected_tokens or check != [("ok",)]:
            raise SystemExit(f"The actual v0.9.7 producer did not create a valid historical schema14: {relative}")
        artifacts[relative] = {"sha256": digest(database), "schema": schema, "events": count, "tokens": tokens}
    quota = inputs / "support/quota-history.sqlite"
    with sqlite3.connect(quota.as_uri() + "?mode=ro", uri=True) as connection:
        if connection.execute("SELECT id FROM quota_snapshots").fetchall() != [(42,)]:
            raise SystemExit("Released quota initializer fixture is missing its synthetic historical row")
        if connection.execute("SELECT seq FROM sqlite_sequence WHERE name='quota_snapshots'").fetchone()[0] != 12345:
            raise SystemExit("Released quota AUTOINCREMENT fixture is incomplete")
    artifacts["support/quota-history.sqlite"] = {"sha256": digest(quota)}
    body = inputs / "support/observed-speed-release097.json"
    saved = json.loads(body.read_text())
    samples = saved if platform == "swift" else saved["samples"]
    expected_ids = {"v097-body", "v097-retired-stream"} if platform == "swift" else {"v097-rust-body", "v097-rust-retired-stream"}
    if {sample["id"] for sample in samples} != expected_ids:
        raise SystemExit("Released JSON encoder fixture is incomplete")
    if platform == "rust" and (saved["version"] != 1 or saved["bodyRetentionDays"] != 15):
        raise SystemExit("Released Rust JSON envelope or retention preference is incomplete")
    artifacts["support/observed-speed-release097.json"] = {"sha256": digest(body)}
    summary = {"release_sha": RELEASE_SHA, "artifacts": artifacts, "verified": True}
    receipt = inputs / "fixture-result.json"
    if receipt.exists() and json.loads(receipt.read_text()) != summary:
        raise SystemExit("Immutable public-release inputs changed after their first verification")
    receipt.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps(summary, sort_keys=True))


def allocate_rust_runtime(env_file):
    root = Path(tempfile.mkdtemp(prefix="tokenbar-v097-runtime-")).resolve()
    (root / ".tokenbar-v097-disposable").write_text(RELEASE_SHA + "\n")
    settings = {
        "TOKENBAR_V097_RUNTIME_ROOT": root,
        "TOKENBAR_V097_FIXTURE_ROOT": root / "fixtures",
        "TOKENBAR_V097_RUST_INPUTS": root / "fixtures/inputs",
        "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR": root / "support",
        "CODEX_TOKEN_BAR_TAURI_CACHE_DIR": root / "cache",
        "CODEX_TOKEN_BAR_SUPPORT_BASE_DIR": root / "shared-support",
        "CODEX_TOKEN_BAR_CACHE_BASE_DIR": root / "shared-cache",
        "CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR": root / "old-cache",
    }
    for key, value in settings.items():
        if key.startswith("CODEX_TOKEN_BAR_"):
            value.mkdir(parents=True)
    with env_file.open("a", encoding="utf-8") as output:
        for key, value in settings.items():
            output.write(f"{key}={value}\n")
    print(json.dumps({key: str(value) for key, value in settings.items()}, sort_keys=True))


def prepare_current_rust(source_dir):
    """Instrument a disposable exact-HEAD archive, never the real app entrypoint.

    cfg(test) deliberately skips production A routing. A feature-gated module
    and tiny example run this repository's new probe in non-test compilation.
    """
    if source_dir.exists():
        raise SystemExit("Use a new candidate probe directory")
    repository = Path(__file__).resolve().parents[1]
    candidate = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
    extract_revision(repository, candidate, source_dir)
    native = source_dir / "tauri-app/src-tauri"
    relative = "core/usage/token_count_jsonl/release097_upgrade_tests.rs"
    if not (native / "src" / relative).is_file():
        raise SystemExit("The exact candidate commit does not contain the reviewed release097 production probe")
    with (native / "src/lib.rs").open("a") as output:
        output.write(f'\n#[cfg(feature = "business-store-fixture")]\n#[path = "{relative}"]\npub mod release097_upgrade_probe;\n')
    example = native / "examples/release097-upgrade-probe.rs"
    example.write_text(r'''
fn main() {
    let phase = std::env::args().nth(1).expect("required explicit probe phase");
    let root = std::env::var_os("TOKENBAR_V097_RUNTIME_ROOT").expect("required isolated runtime root");
    match codex_token_bar_lib::release097_upgrade_probe::run_production_probe(std::path::Path::new(&root), &phase) {
        Ok(report) => println!("{}", report),
        Err(error) => { eprintln!("V097_RUST_PRODUCTION_FAIL: {error}"); std::process::exit(1); }
    }
}
''')
    with (native / "Cargo.toml").open("a") as output:
        output.write('\n[[example]]\nname = "release097-upgrade-probe"\npath = "examples/release097-upgrade-probe.rs"\nrequired-features = ["business-store-fixture"]\n')
    report = {"candidate_sha": candidate, "probe_source_sha256": digest(native / "src" / relative), "temporary_injection": ["src/lib.rs", "Cargo.toml", "examples/release097-upgrade-probe.rs"]}
    (source_dir / "release097-probe-injection.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, sort_keys=True))


def verify_release_swift_dependency(source_dir):
    """Verify the LFS binary against the exact public release's dependency pin.

    The source archive needs no .git. SwiftPM creates a separate Git checkout
    for TiktokenSwift; the existing helper fetches/checks out LFS inside it.
    """
    lock = json.loads((source_dir / "Package.resolved").read_text())
    pin = next(item["state"]["revision"] for item in lock["pins"] if item["identity"] == "tiktokenswift")
    expected = "661c349ebdc5e90c29f855e8c19f8984d401863b"
    if pin != expected:
        raise SystemExit("The public release TiktokenSwift pin changed")
    checkout = source_dir / ".build/checkouts/TiktokenSwift"
    actual = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    if actual != pin:
        raise SystemExit("SwiftPM resolved a different TiktokenSwift revision")
    manifest = (checkout / "Package.swift").read_text()
    frameworks = ["Sources/TiktokenFFI/TiktokenFFI.xcframework", "TiktokenFFI.xcframework"]
    framework = next((name for name in frameworks if f'path: "{name}"' in manifest), None)
    if framework is None:
        raise SystemExit("Cannot locate the pinned TiktokenFFI framework")
    relative = framework + "/macos-arm64_x86_64/TiktokenFFI.framework/TiktokenFFI"
    frozen = subprocess.check_output(["git", "-C", str(checkout), "show", f"{pin}:{relative}"])
    if frozen.startswith(b"version https://git-lfs.github.com/spec/v1\n"):
        fields = dict(line.split(" ", 1) for line in frozen.decode().splitlines())
        algorithm, expected_digest = fields["oid"].split(":", 1)
        if algorithm != "sha256":
            raise SystemExit("Unsupported public release LFS hash")
        expected_size = int(fields["size"])
    else:
        expected_digest = hashlib.sha256(frozen).hexdigest()
        expected_size = len(frozen)
    binary = checkout / relative
    if binary.stat().st_size != expected_size or digest(binary) != expected_digest:
        raise SystemExit("Pinned TiktokenFFI LFS bytes do not match their Git OID and size")
    print(json.dumps({"revision": pin, "sha256": expected_digest, "size": expected_size, "verified": True}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    export = commands.add_parser("prepare")
    export.add_argument("source_dir", type=lambda value: Path(value).resolve())
    export.add_argument("fixture_dir", type=lambda value: Path(value).resolve())
    export.add_argument("--platform", choices=["swift", "rust"], default="swift")
    validate = commands.add_parser("verify")
    validate.add_argument("fixture_dir", type=lambda value: Path(value).resolve())
    validate.add_argument("--platform", choices=["swift", "rust"], default="swift")
    allocate = commands.add_parser("allocate-rust-runtime")
    allocate.add_argument("env_file", type=lambda value: Path(value).resolve())
    current = commands.add_parser("prepare-current-rust")
    current.add_argument("source_dir", type=lambda value: Path(value).resolve())
    dependency = commands.add_parser("verify-v097-swift-dependency")
    dependency.add_argument("source_dir", type=lambda value: Path(value).resolve())
    arguments = parser.parse_args()
    if arguments.command == "prepare":
        prepare(arguments.source_dir, arguments.fixture_dir, arguments.platform)
    elif arguments.command == "verify":
        verify(arguments.fixture_dir, arguments.platform)
    elif arguments.command == "allocate-rust-runtime":
        allocate_rust_runtime(arguments.env_file)
    elif arguments.command == "prepare-current-rust":
        prepare_current_rust(arguments.source_dir)
    else:
        verify_release_swift_dependency(arguments.source_dir)


if __name__ == "__main__":
    main()
