use super::*;
use crate::core::business_store_container::{Container, StoreSpec};
use rusqlite::Connection;
use sha2::{Digest, Sha256};
use std::fs;
use tempfile::TempDir;

struct ExactCase {
    _root: TempDir,
    old: std::path::PathBuf,
    current: std::path::PathBuf,
    raw: std::path::PathBuf,
}
const FP: &[u8] = &[1, 100, 90, 5, 0, 105, 1, 100, 90, 5, 0, 105];
impl ExactCase {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let old = root.path().join("old.sqlite");
        let current = root.path().join("current.sqlite");
        let raw = root.path().join("rollout.jsonl");
        let text="{\"timestamp\":\"2026-11-01T01:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"synthetic-session\",\"history_mode\":\"paginated\"}}\n{\"synthetic\":true}\n";
        fs::write(&raw, text).unwrap();
        let db = Connection::open(&old).unwrap();
        db.execute_batch("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL) WITHOUT ROWID;
          INSERT INTO metadata VALUES('schema_version','14'),('codex_home_identity','synthetic-home'),('event_id_sequence','1'),('fork_replay_boundary_revision','paginated-owned-turn-v6');
          CREATE TABLE sources(source_id INTEGER PRIMARY KEY,path TEXT NOT NULL,session_id TEXT NOT NULL,is_explicit_subagent_fork INTEGER NOT NULL);
          CREATE TABLE event_rows(id INTEGER PRIMARY KEY,source_id INTEGER NOT NULL,ordinal INTEGER NOT NULL,timestamp INTEGER NOT NULL,tokens INTEGER NOT NULL,input_tokens INTEGER NOT NULL,cached_input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,reasoning_output_tokens INTEGER NOT NULL,accounting_kind INTEGER NOT NULL,model TEXT);
          INSERT INTO event_rows VALUES(1,7,1,1793494800,105,100,90,5,0,0,'synthetic-model');
          CREATE INDEX event_rows_source_idx ON event_rows(source_id,timestamp,input_tokens,cached_input_tokens,output_tokens);
          CREATE TABLE usage_ledger_bindings(event_id INTEGER PRIMARY KEY,source_id INTEGER NOT NULL,raw_generation INTEGER NOT NULL,raw_offset INTEGER,user_prompt_start INTEGER,user_prompt_end INTEGER,assistant_response_start INTEGER,assistant_response_end INTEGER,fingerprint BLOB,available INTEGER NOT NULL);
          INSERT INTO usage_ledger_bindings VALUES(1,7,1,NULL,NULL,NULL,NULL,NULL,NULL,1);
          CREATE INDEX binding_identity ON usage_ledger_bindings(source_id,fingerprint);
          CREATE TABLE source_fingerprints(source_id INTEGER NOT NULL,fingerprint BLOB NOT NULL,PRIMARY KEY(source_id,fingerprint)) WITHOUT ROWID;
          CREATE TABLE source_chunks(source_id INTEGER NOT NULL,chunk_index INTEGER NOT NULL,byte_count INTEGER NOT NULL,sha256 BLOB NOT NULL,PRIMARY KEY(source_id,chunk_index)) WITHOUT ROWID;
          CREATE TABLE retained_usage_revisions(revision_id INTEGER PRIMARY KEY,tokens INTEGER NOT NULL); INSERT INTO retained_usage_revisions VALUES(1,105);
          CREATE TABLE usage_ledger_unresolved(id INTEGER PRIMARY KEY,tokens INTEGER NOT NULL);INSERT INTO usage_ledger_unresolved VALUES(1,9);").unwrap();
        db.execute(
            "INSERT INTO sources VALUES(7,?1,'synthetic-session',0)",
            [raw.to_string_lossy().as_ref()],
        )
        .unwrap();
        db.execute("INSERT INTO source_fingerprints VALUES(7,?1)", [FP])
            .unwrap();
        db.execute(
            "INSERT INTO source_chunks VALUES(7,0,?1,?2)",
            params![
                text.len() as i64,
                Sha256::digest(text.as_bytes()).as_slice()
            ],
        )
        .unwrap();
        let receipt = serde_json::json!({"status":"copied","sourceSchema":13,"targetSchema":14,"sourcePath":"synthetic-cache","rollbackPath":"synthetic-rollback","manifestPath":"synthetic-manifest"});
        db.execute(
            "INSERT INTO metadata VALUES('release_upgrade_retention_v1',?1)",
            [receipt.to_string()],
        )
        .unwrap();
        drop(db);
        Container::backup_snapshot(&old, &current).unwrap();
        Self {
            _root: root,
            old,
            current,
            raw,
        }
    }
    fn update(&self, sql: &str) {
        Connection::open(&self.current)
            .unwrap()
            .execute_batch(sql)
            .unwrap();
    }
    fn enrich(&self) {
        let db = Connection::open(&self.current).unwrap();
        db.execute(
            "UPDATE usage_ledger_bindings SET raw_generation=2,raw_offset=150,fingerprint=?1 WHERE event_id=1",
            [FP],
        )
        .unwrap();
    }
    fn covers(&self) -> bool {
        Container::exact_snapshot_covers(&self.current, &self.old).unwrap()
    }
    fn repair(&self) {
        Connection::open(&self.old).unwrap().execute_batch("INSERT INTO metadata VALUES('parser_repair_verify_pending','paginated-owned-turn-v6');UPDATE sources SET is_explicit_subagent_fork=1").unwrap();
        self.update("UPDATE sources SET is_explicit_subagent_fork=0");
    }
}

#[test]
fn incident_exact_combined_repair_metadata_fork_and_unknown_binding_is_covered_once() {
    let f = ExactCase::new();
    f.repair();
    f.enrich();
    Connection::open(&f.old).unwrap().execute_batch("INSERT INTO metadata VALUES('state_size','100'),('state_modified_ns','100'),('storage_maintenance_last_checked_unix','100')").unwrap();
    f.update("INSERT INTO metadata VALUES('state_size','100'),('state_modified_ns','200'),('storage_maintenance_last_checked_unix','200'); INSERT INTO event_rows VALUES(2,7,2,1793494801,20,15,10,5,0,0,'synthetic-model'); UPDATE metadata SET value='2' WHERE key='event_id_sequence'");
    let old = fs::read(&f.old).unwrap();
    let current = fs::read(&f.current).unwrap();
    assert!(f.covers());
    assert!(f.covers());
    assert_eq!(fs::read(&f.old).unwrap(), old);
    assert_eq!(fs::read(&f.current).unwrap(), current);
    let db = Connection::open(&f.current).unwrap();
    assert_eq!(
        db.query_row("SELECT count(*) FROM event_rows", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        2
    );
}
#[test]
fn incident_unknown_binding_requires_prefix_membership_and_unique_event_identity() {
    for mutation in [
        "DELETE FROM source_chunks",
        "UPDATE source_chunks SET sha256=zeroblob(32)",
        "DELETE FROM source_fingerprints",
        "INSERT INTO event_rows SELECT 2,source_id,2,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,accounting_kind,model FROM event_rows",
        "INSERT INTO usage_ledger_bindings SELECT 2,source_id,raw_generation,raw_offset,NULL,NULL,NULL,NULL,fingerprint,0 FROM usage_ledger_bindings",
        "UPDATE usage_ledger_bindings SET raw_generation=0",
    ] {
        let f=ExactCase::new();f.enrich();f.update(mutation);assert!(!f.covers(),"must reject {mutation}");
    }
}
#[test]
fn incident_known_fingerprint_amount_home_and_retained_evidence_remain_protected() {
    for mutation in [
        "UPDATE event_rows SET input_tokens=999",
        "DELETE FROM event_rows",
        "UPDATE metadata SET value='other-home' WHERE key='codex_home_identity'",
        "DELETE FROM retained_usage_revisions",
        "DELETE FROM usage_ledger_unresolved",
        "UPDATE usage_ledger_bindings SET fingerprint=x'020304'",
        "UPDATE metadata SET value='changed' WHERE key='fork_replay_boundary_revision'",
    ] {
        let f = ExactCase::new();
        Connection::open(&f.old)
            .unwrap()
            .execute("UPDATE usage_ledger_bindings SET fingerprint=?1", [FP])
            .unwrap();
        f.enrich();
        f.update(mutation);
        assert!(!f.covers(), "must reject {mutation}");
    }
}
#[test]
fn incident_fork_reset_requires_actual_bounded_paginated_no_parent_header() {
    for (header,session) in [
        ("{\"timestamp\":\"2026-11-01T01:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"synthetic-session\",\"history_mode\":\"paginated\",\"forked_from_id\":\"parent\"}}\n","synthetic-session"),
        ("{\"timestamp\":\"2026-11-01T01:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"wrong-session\",\"history_mode\":\"paginated\"}}\n","synthetic-session"),
        ("not JSON\n","synthetic-session"),
    ] {
        let f=ExactCase::new();f.repair();fs::write(&f.raw,header).unwrap();
        assert!(!crate::core::usage::token_count_jsonl::recovery_source::is_paginated_without_parent(&f.raw,session));assert!(!f.covers());
    }
    let f = ExactCase::new();
    f.repair();
    fs::remove_file(&f.raw).unwrap();
    assert!(!f.covers());
    let f = ExactCase::new();
    f.repair();
    Connection::open(&f.old)
        .unwrap()
        .execute(
            "UPDATE metadata SET value='unknown-repair' WHERE key='parser_repair_verify_pending'",
            [],
        )
        .unwrap();
    assert!(!f.covers());
}
#[test]
fn incident_plain_and_compressed_header_use_same_rules_without_materializing_source() {
    let f = ExactCase::new();
    f.repair();
    let logical = fs::read(&f.raw).unwrap();
    let zst = f.raw.with_extension("jsonl.zst");
    let bytes = zstd::stream::encode_all(logical.as_slice(), 1).unwrap();
    fs::write(&zst, &bytes).unwrap();
    fs::remove_file(&f.raw).unwrap();
    assert!(f.covers());
    assert_eq!(fs::read(&zst).unwrap(), bytes);
    assert!(!f.raw.exists());
    let f = ExactCase::new();
    f.repair();
    let huge = vec![b' '; 256 * 1024 + 1];
    fs::write(&f.raw, huge).unwrap();
    assert!(!f.covers());
}
#[test]
fn incident_partial_chunk_growth_checks_original_bytes_instead_of_trusting_a_new_hash() {
    let f = ExactCase::new();
    f.enrich();
    let old = fs::read(&f.raw).unwrap();
    let mut grown = old.clone();
    grown.extend_from_slice(b"{\"later\":true}\n");
    fs::write(&f.raw, &grown).unwrap();
    Connection::open(&f.current)
        .unwrap()
        .execute(
            "UPDATE source_chunks SET byte_count=?1,sha256=?2",
            params![grown.len() as i64, Sha256::digest(&grown).as_slice()],
        )
        .unwrap();
    assert!(f.covers());
    grown[0] = b' ';
    fs::write(&f.raw, &grown).unwrap();
    assert!(!f.covers());
}
#[test]
fn incident_new_known_positions_never_replace_old_known_positions_during_rebinding() {
    let f = ExactCase::new();
    Connection::open(&f.old)
        .unwrap()
        .execute("UPDATE usage_ledger_bindings SET raw_offset=99", [])
        .unwrap();
    f.enrich();
    assert!(!f.covers());
}

fn quota_pair() -> (TempDir, std::path::PathBuf, std::path::PathBuf) {
    let root = tempfile::tempdir().unwrap();
    let old = root.path().join("old.sqlite");
    let current = root.path().join("new.sqlite");
    Connection::open(&old).unwrap().execute_batch("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY,account_key TEXT NOT NULL,used REAL NOT NULL);INSERT INTO quota_snapshots VALUES(1,'account',10);CREATE TABLE quota_history_legacy_claims(name TEXT PRIMARY KEY,owner TEXT NOT NULL);INSERT INTO quota_history_legacy_claims VALUES('display','account');CREATE TABLE quota_history_maintenance(key TEXT PRIMARY KEY,value TEXT NOT NULL);INSERT INTO quota_history_maintenance VALUES('policy_version','3'),('last_compacted_at','100')").unwrap();
    Container::backup_snapshot(&old, &current).unwrap();
    (root, old, current)
}
#[test]
fn incident_quota_daily_maintenance_is_module_scoped_and_keeps_business_rows_strict() {
    let (_root, old, current) = quota_pair();
    Connection::open(&current).unwrap().execute_batch("INSERT INTO quota_snapshots VALUES(2,'account',11);UPDATE quota_history_maintenance SET value='200' WHERE key='last_compacted_at'").unwrap();
    assert!(Container::retry_snapshot_covers(&current, &old, "quota_history_legacy").unwrap());
    assert!(!Container::retry_snapshot_covers(&current, &old, "body_speed").unwrap());
    for mutation in [
        "UPDATE quota_snapshots SET used=99 WHERE id=1",
        "DELETE FROM quota_snapshots WHERE id=1",
        "UPDATE quota_history_legacy_claims SET owner='another'",
        "UPDATE quota_history_maintenance SET value='2' WHERE key='policy_version'",
        "UPDATE quota_history_maintenance SET value='NaN' WHERE key='last_compacted_at'",
        "UPDATE quota_history_maintenance SET value='99' WHERE key='last_compacted_at'",
        "INSERT INTO quota_history_maintenance VALUES('future-policy','1')",
    ] {
        let (_root, old, current) = quota_pair();
        Connection::open(&current)
            .unwrap()
            .execute_batch(mutation)
            .unwrap();
        assert!(
            !Container::retry_snapshot_covers(&current, &old, "quota_history_legacy").unwrap(),
            "must reject {mutation}"
        );
    }
}
#[test]
fn incident_destination_replacement_checks_current_proof_inside_write_transaction() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("a.sqlite");
    let input = root.path().join("old.sqlite");
    Connection::open(&input).unwrap().execute_batch("CREATE TABLE records(id INTEGER PRIMARY KEY,amount INTEGER);INSERT INTO records VALUES(1,100)").unwrap();
    let spec = StoreSpec::new("quota_history_legacy", "home", "quota").unwrap();
    let mut a = Container::open(&path).unwrap();
    a.import_snapshot(&input, &spec, &input, 1.0, false)
        .unwrap();
    let expected = a.proof(&spec).unwrap();
    let writer = a.into_store_connection(&spec).unwrap();
    writer
        .execute("INSERT INTO records VALUES(2,334108)", [])
        .unwrap();
    drop(writer);
    let mut a = Container::open_existing(&path).unwrap();
    let changed = a.proof(&spec).unwrap();
    assert!(a
        .replace_frozen_snapshot(
            &input,
            &spec,
            &input,
            2.0,
            &expected,
            &Container::snapshot_proof_path(&input).unwrap()
        )
        .is_err());
    assert_eq!(a.proof(&spec).unwrap(), changed);
}

#[test]
fn incident_null_maintenance_key_cannot_hide_a_changed_unknown_value() {
    let (_root, old, current) = quota_pair();
    for path in [&old, &current] {
        Connection::open(path)
            .unwrap()
            .execute(
                "INSERT INTO quota_history_maintenance VALUES(NULL,'old')",
                [],
            )
            .unwrap();
    }
    Connection::open(&current)
        .unwrap()
        .execute(
            "UPDATE quota_history_maintenance SET value='changed' WHERE key IS NULL",
            [],
        )
        .unwrap();
    assert!(!Container::retry_snapshot_covers(&current, &old, "quota_history_legacy").unwrap());
}
#[test]
fn incident_same_generation_fingerprint_fill_needs_the_full_content_proof_too() {
    let f = ExactCase::new();
    f.enrich();
    f.update("UPDATE usage_ledger_bindings SET raw_generation=1");
    assert!(f.covers());
    for mutation in [
        "DELETE FROM source_chunks",
        "DELETE FROM source_fingerprints",
        "UPDATE usage_ledger_bindings SET raw_offset=-1; DELETE FROM source_chunks",
    ] {
        let f = ExactCase::new();
        f.enrich();
        f.update("UPDATE usage_ledger_bindings SET raw_generation=1");
        f.update(mutation);
        assert!(!f.covers(), "{mutation}");
    }
}
#[test]
fn incident_operational_metadata_has_typed_paired_and_forward_clock_guards() {
    for mutation in [
        "INSERT INTO metadata VALUES('state_size','corrupt'),('state_modified_ns','123')",
        "INSERT INTO metadata VALUES('state_size','123')",
        "INSERT INTO metadata VALUES('storage_maintenance_last_checked_unix','NaN')",
        "INSERT INTO metadata VALUES('storage_maintenance_last_compacted_unix','-1')",
    ] {
        let f = ExactCase::new();
        f.update(mutation);
        assert!(!f.covers(), "{mutation}");
    }
    let f = ExactCase::new();
    Connection::open(&f.old)
        .unwrap()
        .execute(
            "INSERT INTO metadata VALUES('storage_maintenance_last_checked_unix','100')",
            [],
        )
        .unwrap();
    f.update("INSERT INTO metadata VALUES('storage_maintenance_last_checked_unix','99')");
    assert!(!f.covers());
}
#[test]
fn incident_replacement_rechecks_the_attached_source_against_its_frozen_proof() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("a.sqlite");
    let input = root.path().join("frozen.sqlite");
    Connection::open(&input).unwrap().execute_batch("CREATE TABLE records(id INTEGER PRIMARY KEY,amount INTEGER);INSERT INTO records VALUES(1,100)").unwrap();
    let spec = StoreSpec::new("quota_history_legacy", "home", "quota").unwrap();
    let mut a = Container::open(&path).unwrap();
    a.import_snapshot(&input, &spec, &input, 1.0, false)
        .unwrap();
    let expected = a.proof(&spec).unwrap();
    let frozen = Container::snapshot_proof_path(&input).unwrap();
    Connection::open(&input)
        .unwrap()
        .execute("UPDATE records SET amount=999", [])
        .unwrap();
    assert!(a
        .replace_frozen_snapshot(&input, &spec, &input, 2.0, &expected, &frozen)
        .is_err());
    assert_eq!(a.proof(&spec).unwrap(), expected);
}
#[test]
fn incident_47937_same_second_unknown_bindings_use_indexed_multiplicities() {
    let f = ExactCase::new();
    for path in [&f.old, &f.current] {
        let mut db = Connection::open(path).unwrap();
        let tx = db.transaction().unwrap();
        for index in 2..=47_937i64 {
            tx.execute("INSERT INTO event_rows VALUES(?1,7,?1,1793494800,?2,?3,90,5,0,0,'synthetic-model')",params![index,100+index+5,100+index]).unwrap();
            let mut fp = vec![1u8];
            for mut n in [
                100 + index as u64,
                90,
                5,
                0,
                105 + index as u64,
                1,
                100 + index as u64,
                90,
                5,
                0,
                105 + index as u64,
            ] {
                loop {
                    let byte = (n & 127) as u8;
                    n >>= 7;
                    fp.push(byte | if n > 0 { 128 } else { 0 });
                    if n == 0 {
                        break;
                    }
                }
            }
            tx.execute(
                "INSERT INTO source_fingerprints VALUES(7,?1)",
                [fp.as_slice()],
            )
            .unwrap();
            if path == &f.old {
                tx.execute("INSERT INTO usage_ledger_bindings VALUES(?1,7,1,NULL,NULL,NULL,NULL,NULL,NULL,1)",[index]).unwrap();
            } else {
                tx.execute("INSERT INTO usage_ledger_bindings VALUES(?1,7,2,NULL,NULL,NULL,NULL,NULL,?2,0)",params![index,fp]).unwrap();
            }
        }
        tx.commit().unwrap();
    }
    f.enrich();
    let db = Connection::open_with_flags(&f.current, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .unwrap();
    db.execute(
        "ATTACH DATABASE ?1 AS tb_exact_history_source",
        [f.old.to_string_lossy().as_ref()],
    )
    .unwrap();
    let before = std::time::Instant::now();
    let verified = VerifiedLegacySources::prepare(&db, "").unwrap();
    assert!(verified.bindings_cover().unwrap());
    let mut plan=db.prepare("EXPLAIN QUERY PLAN SELECT id FROM tb_exact_history_source.event_rows event WHERE EXISTS(SELECT 1 FROM temp.tb_legacy_old_observations candidate WHERE candidate.source_id=event.source_id AND candidate.timestamp IS event.timestamp AND candidate.input_tokens IS event.input_tokens AND candidate.cached_input_tokens IS event.cached_input_tokens AND candidate.output_tokens IS event.output_tokens AND candidate.reasoning_output_tokens IS event.reasoning_output_tokens AND candidate.accounting_kind IS event.accounting_kind AND candidate.n=1)").unwrap();
    let details = plan
        .query_map([], |r| r.get::<_, String>(3))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert!(
        details
            .iter()
            .any(|line| line.contains("SEARCH") && line.contains("tb_legacy_old_observations_key")),
        "{details:?}"
    );
    eprintln!(
        "47937 same-second legacy bindings validated with grouped indexes in {:?}",
        before.elapsed()
    );
}

#[test]
fn incident_maintenance_exception_requires_a_unique_primary_key() {
    let (_root, old, current) = quota_pair();
    for path in [&old, &current] {
        Connection::open(path).unwrap().execute_batch("DROP TABLE quota_history_maintenance; CREATE TABLE quota_history_maintenance(key TEXT,value TEXT NOT NULL); INSERT INTO quota_history_maintenance VALUES('policy_version','3'),('last_compacted_at','100'),('last_compacted_at','500')").unwrap();
    }
    Connection::open(&current).unwrap().execute("UPDATE quota_history_maintenance SET value=CASE rowid WHEN 2 THEN '200' ELSE '0' END WHERE key='last_compacted_at'",[]).unwrap();
    assert!(!Container::retry_snapshot_covers(&current, &old, "quota_history_legacy").unwrap());
}
#[test]
fn incident_atomic_source_replacement_is_detected_even_when_size_and_mtime_match() {
    use crate::core::usage::token_count_jsonl::recovery_source::{
        after_read_for_testing, is_paginated_without_parent, prefix_fragment_matches,
    };
    let f = ExactCase::new();
    let bytes = fs::read(&f.raw).unwrap();
    let stamp = fs::metadata(&f.raw).unwrap().modified().unwrap();
    let replacement = f.raw.with_extension("replacement");
    fs::write(&replacement, &bytes).unwrap();
    fs::File::options()
        .write(true)
        .open(&replacement)
        .unwrap()
        .set_modified(stamp)
        .unwrap();
    let destination = f.raw.clone();
    let staged = replacement.clone();
    after_read_for_testing(move || {
        fs::rename(staged, destination).unwrap();
    });
    assert!(!is_paginated_without_parent(&f.raw, "synthetic-session"));
    fs::write(&replacement, &bytes).unwrap();
    fs::File::options()
        .write(true)
        .open(&replacement)
        .unwrap()
        .set_modified(stamp)
        .unwrap();
    let destination = f.raw.clone();
    after_read_for_testing(move || {
        fs::rename(replacement, destination).unwrap();
    });
    assert!(!prefix_fragment_matches(
        &f.raw,
        0,
        bytes.len() as u64,
        Sha256::digest(&bytes).as_slice()
    ));
}
