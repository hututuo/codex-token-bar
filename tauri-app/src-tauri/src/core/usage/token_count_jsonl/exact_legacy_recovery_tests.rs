use crate::core::{app_paths, business_store_route as route};
use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};
use sha2::Digest;
use std::fs;
use std::path::{Path, PathBuf};

type Phase = super::super::Schema11CandidatePhase;

fn write_database(path: &Path, value: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    let connection = Connection::open(path).unwrap();
    connection
        .execute_batch("CREATE TABLE sample(id INTEGER PRIMARY KEY, value TEXT NOT NULL);")
        .unwrap();
    connection
        .execute("INSERT INTO sample(id, value) VALUES (1, ?1)", [value])
        .unwrap();
}

fn sample_value(path: &Path) -> String {
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    connection
        .query_row("SELECT value FROM sample WHERE id=1", [], |row| row.get(0))
        .unwrap()
}

fn manifest_bytes(main: &Path, phase: Phase) -> Vec<u8> {
    let manifest = super::super::Schema11CandidateManifest {
        manifest_version: super::super::SCHEMA11_CANDIDATE_MANIFEST_VERSION,
        source_path: main.to_string_lossy().into_owned(),
        candidate_path: super::super::schema11_candidate_path(main)
            .to_string_lossy()
            .into_owned(),
        rollback_path: super::super::schema11_rollback_path(main)
            .to_string_lossy()
            .into_owned(),
        source_receipt: super::super::Schema11SourceReceipt {
            schema_version: 9,
            revision: Some("source-revision".into()),
            dashboard_revision: Some("dashboard-revision".into()),
            published_generation: Some(3),
            building_generation: None,
            database: super::super::Schema11FileStamp {
                size: 1024,
                modified_ns: "123456".into(),
            },
            wal: None,
        },
        source_facts: None,
        phase,
    };
    serde_json::to_vec(&manifest).unwrap()
}

fn write_manifest(main: &Path, phase: Phase) -> PathBuf {
    let path = super::super::schema11_manifest_path(main);
    fs::write(&path, manifest_bytes(main, phase)).unwrap();
    path
}

fn capture(paths: &[&Path]) -> Vec<(PathBuf, Vec<u8>)> {
    paths
        .iter()
        .map(|path| (path.to_path_buf(), fs::read(path).unwrap()))
        .collect()
}

fn assert_unchanged(files: &[(PathBuf, Vec<u8>)]) {
    for (path, expected) in files {
        assert_eq!(
            &fs::read(path).unwrap(),
            expected,
            "changed {}",
            path.display()
        );
    }
}

#[test]
fn relocation_equivalence_never_ignores_usage_other_metadata_or_unknown_receipts() {
    use crate::core::business_store_container::Container;
    let temporary = tempfile::tempdir().unwrap();
    let a = temporary.path().join("a.sqlite3");
    let b = temporary.path().join("b.sqlite3");
    for path in [&a, &b] {
        write_database(path, "same usage");
        Connection::open(path).unwrap().execute_batch("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT); INSERT INTO metadata VALUES('codex_home_identity','same-home')").unwrap();
    }
    let receipt = json!({"status":"copied","sourceSchema":14,"targetSchema":14,
        "sourcePath":a.to_string_lossy(),"rollbackPath":"kept-rollback","manifestPath":"kept-manifest"});
    let db = Connection::open(&b).unwrap();
    db.execute("INSERT INTO metadata VALUES('release_upgrade_retention_v1',?1)", [receipt.to_string()]).unwrap();
    assert!(Container::exact_relocation_equivalent(&a, &b).unwrap());
    // Native Swift's Codable receipt uses canonical decimal strings.
    let mut native_receipt = receipt.clone();
    native_receipt["sourceSchema"] = "13".into();
    native_receipt["targetSchema"] = "14".into();
    db.execute("UPDATE metadata SET value=?1 WHERE key='release_upgrade_retention_v1'", [native_receipt.to_string()]).unwrap();
    assert!(Container::exact_relocation_equivalent(&a, &b).unwrap());

    db.execute("UPDATE sample SET value='extra historical usage'", []).unwrap();
    assert!(!Container::exact_relocation_equivalent(&a, &b).unwrap());
    db.execute("UPDATE sample SET value='same usage'", []).unwrap();
    db.execute("UPDATE metadata SET value='other-home' WHERE key='codex_home_identity'", []).unwrap();
    assert!(!Container::exact_relocation_equivalent(&a, &b).unwrap());
    db.execute("UPDATE metadata SET value='same-home' WHERE key='codex_home_identity'", []).unwrap();
    let mut unknown = receipt;
    unknown["targetSchema"] = 999.into();
    db.execute("UPDATE metadata SET value=?1 WHERE key='release_upgrade_retention_v1'", [unknown.to_string()]).unwrap();
    assert!(Container::exact_relocation_equivalent(&a, &b).is_err());
}

#[test]
fn valid_manifest_phases_select_only_the_committed_main_and_preserve_evidence() {
    for phase in [
        Phase::Prepared,
        Phase::Copied,
        Phase::Migrated,
        Phase::Validated,
        Phase::Switching,
        Phase::Switched,
        Phase::Retained,
    ] {
        let temporary = tempfile::tempdir().unwrap();
        let current = temporary.path().join("current");
        let cache = temporary.path().join("cache");
        fs::create_dir_all(&current).unwrap();
        let main = current.join("home.sqlite3");
        let candidate = super::super::schema11_candidate_path(&main);
        let rollback = super::super::schema11_rollback_path(&main);
        write_database(&main, "committed-main");
        write_database(&candidate, "uncommitted-candidate");
        write_database(&rollback, "rollback-copy");
        let manifest = write_manifest(&main, phase);
        let originals = capture(&[&main, &candidate, &rollback, &manifest]);

        let mut observation = None;
        super::bootstrap_at(&current, &cache, |target, sources, manifests| {
            observation = Some((target.to_path_buf(), sources.to_vec(), manifests.to_vec()));
            Ok(())
        })
        .unwrap();

        let (target, sources, manifests) = observation.expect("manifest input was not imported");
        assert_eq!(
            target, main,
            "phase {phase:?} must retain the canonical target"
        );
        assert_eq!(sources, vec![main.clone()], "phase {phase:?} must use main");
        assert_eq!(sample_value(&sources[0]), "committed-main");
        assert_eq!(manifests.len(), 1);
        assert_eq!(manifests[0].0, manifest);
        assert_eq!(
            manifests[0].1,
            format!("{:x}", sha2::Sha256::digest(&fs::read(&manifest).unwrap()))
        );
        assert_unchanged(&originals);
    }
}

#[test]
fn switching_without_main_uses_rollback_but_never_candidate_or_a_new_identity() {
    let temporary = tempfile::tempdir().unwrap();
    let current = temporary.path().join("current");
    let cache = temporary.path().join("cache");
    fs::create_dir_all(&current).unwrap();
    let main = current.join("home.sqlite3");
    let candidate = super::super::schema11_candidate_path(&main);
    let rollback = super::super::schema11_rollback_path(&main);
    write_database(&candidate, "candidate-must-not-win");
    write_database(&rollback, "committed-rollback");
    let manifest = write_manifest(&main, Phase::Switching);
    let originals = capture(&[&candidate, &rollback, &manifest]);

    let mut observation = None;
    super::bootstrap_at(&current, &cache, |target, sources, manifests| {
        observation = Some((target.to_path_buf(), sources.to_vec(), manifests.to_vec()));
        Ok(())
    })
    .unwrap();

    let (target, sources, manifests) = observation.expect("switching fallback was not imported");
    assert_eq!(
        target, main,
        "rollback fallback must keep main's logical identity"
    );
    assert_eq!(sources, vec![rollback.clone()]);
    assert_eq!(sample_value(&sources[0]), "committed-rollback");
    assert!(!sources.contains(&candidate));
    assert_eq!(manifests.len(), 1);
    assert_eq!(manifests[0].0, manifest);
    assert_unchanged(&originals);
}

#[test]
fn retained_and_switched_missing_main_do_not_resurrect_rollback() {
    for phase in [Phase::Retained, Phase::Switched] {
        let temporary = tempfile::tempdir().unwrap();
        let current = temporary.path().join("current");
        let cache = temporary.path().join("cache");
        fs::create_dir_all(&current).unwrap();
        let main = current.join("home.sqlite3");
        let candidate = super::super::schema11_candidate_path(&main);
        let rollback = super::super::schema11_rollback_path(&main);
        write_database(&candidate, "candidate");
        write_database(&rollback, "older-rollback");
        let manifest = write_manifest(&main, phase);
        let originals = capture(&[&candidate, &rollback, &manifest]);
        let mut called = false;

        let result = super::bootstrap_at(&current, &cache, |_, _, _| {
            called = true;
            Ok(())
        });

        assert!(
            result.is_err(),
            "phase {phase:?} must not fall back to rollback"
        );
        assert!(
            !called,
            "unsafe input must fail before importing a namespace"
        );
        assert_unchanged(&originals);
    }
}

#[test]
fn switching_without_main_rejects_nonempty_unmoved_wal_and_journal() {
    for suffix in ["-wal", "-journal"] {
        let temporary = tempfile::tempdir().unwrap();
        let current = temporary.path().join("current");
        let cache = temporary.path().join("cache");
        fs::create_dir_all(&current).unwrap();
        let main = current.join("home.sqlite3");
        let candidate = super::super::schema11_candidate_path(&main);
        let rollback = super::super::schema11_rollback_path(&main);
        write_database(&candidate, "candidate");
        write_database(&rollback, "rollback");
        let manifest = write_manifest(&main, Phase::Switching);
        let leftover = super::super::sqlite_sidecar_path(&main, suffix);
        fs::write(&leftover, b"unmoved sqlite transaction").unwrap();
        let originals = capture(&[&candidate, &rollback, &manifest, &leftover]);
        let mut called = false;

        let result = super::bootstrap_at(&current, &cache, |_, _, _| {
            called = true;
            Ok(())
        });

        assert!(result.is_err(), "{suffix} must block rollback fallback");
        assert!(!called);
        assert_unchanged(&originals);
    }
}

#[test]
fn malformed_unknown_and_escaping_manifests_fail_before_import() {
    for mutation in [
        "malformed",
        "version",
        "phase",
        "source",
        "candidate",
        "rollback",
    ] {
        let temporary = tempfile::tempdir().unwrap();
        let current = temporary.path().join("current");
        let cache = temporary.path().join("cache");
        fs::create_dir_all(&current).unwrap();
        let main = current.join("home.sqlite3");
        let candidate = super::super::schema11_candidate_path(&main);
        let rollback = super::super::schema11_rollback_path(&main);
        write_database(&main, "main");
        write_database(&candidate, "candidate");
        write_database(&rollback, "rollback");
        let manifest = write_manifest(&main, Phase::Retained);
        if mutation == "malformed" {
            fs::write(&manifest, b"{not-json").unwrap();
        } else {
            let mut value: Value = serde_json::from_slice(&fs::read(&manifest).unwrap()).unwrap();
            match mutation {
                "version" => value["manifest_version"] = json!(2),
                "phase" => value["phase"] = json!("UnknownPhase"),
                "source" => value["source_path"] = json!(temporary.path().join("other.sqlite3")),
                "candidate" => {
                    value["candidate_path"] = json!(temporary.path().join("candidate.sqlite"))
                }
                "rollback" => {
                    value["rollback_path"] = json!(temporary.path().join("rollback.sqlite"))
                }
                _ => unreachable!(),
            }
            fs::write(&manifest, serde_json::to_vec(&value).unwrap()).unwrap();
        }
        let originals = capture(&[&main, &candidate, &rollback, &manifest]);
        let mut called = false;

        let result = super::bootstrap_at(&current, &cache, |_, _, _| {
            called = true;
            Ok(())
        });

        assert!(result.is_err(), "{mutation} manifest must be rejected");
        assert!(!called);
        assert_unchanged(&originals);
    }
}

#[cfg(unix)]
#[test]
fn symlink_manifest_is_rejected_without_touching_its_target() {
    use std::os::unix::fs::symlink;

    let temporary = tempfile::tempdir().unwrap();
    let current = temporary.path().join("current");
    let cache = temporary.path().join("cache");
    fs::create_dir_all(&current).unwrap();
    let main = current.join("home.sqlite3");
    write_database(&main, "main");
    let manifest = super::super::schema11_manifest_path(&main);
    let actual = temporary.path().join("actual-manifest.json");
    fs::write(&actual, manifest_bytes(&main, Phase::Retained)).unwrap();
    symlink(&actual, &manifest).unwrap();
    let originals = capture(&[&main, &actual]);
    let mut called = false;

    let result = super::bootstrap_at(&current, &cache, |_, _, _| {
        called = true;
        Ok(())
    });

    assert!(result.is_err());
    assert!(!called);
    assert_unchanged(&originals);
}

#[test]
fn manifest_changed_during_import_blocks_completion() {
    let temporary = tempfile::tempdir().unwrap();
    let current = temporary.path().join("current");
    let cache = temporary.path().join("cache");
    fs::create_dir_all(&current).unwrap();
    let main = current.join("home.sqlite3");
    write_database(&main, "main");
    write_manifest(&main, Phase::Retained);
    let source_before = fs::read(&main).unwrap();
    let mut called = false;

    let result = super::bootstrap_at(&current, &cache, |_, _, manifests| {
        called = true;
        assert_eq!(manifests.len(), 1);
        fs::write(&manifests[0].0, b"changed while importing").unwrap();
        Ok(())
    });

    assert!(result.is_err());
    assert!(called);
    assert_eq!(fs::read(&main).unwrap(), source_before);
}

#[test]
fn real_importer_resumes_a_partial_switching_fallback_idempotently() {
    let temporary = tempfile::tempdir().unwrap();
    let base = temporary.path().join("isolated-user-data");
    let support = base.join("tauri-support");
    let cache = base.join("tauri-usage-cache").join("exact-token-index");
    let current = support.join("exact-token-index");
    let shared_support = base.join("shared-support");
    let shared_cache = base.join("shared-cache");
    fs::create_dir_all(&current).unwrap();
    let main = current.join("home.sqlite3");
    let candidate = super::super::schema11_candidate_path(&main);
    let rollback = super::super::schema11_rollback_path(&main);
    write_database(&candidate, "candidate-must-not-win");
    write_database(&rollback, "committed-rollback");
    let manifest = write_manifest(&main, Phase::Switching);
    let originals = capture(&[&candidate, &rollback, &manifest]);

    let _environment = app_paths::app_path_test_env_guard(&[
        ("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", support.clone()),
        ("CODEX_TOKEN_BAR_TAURI_CACHE_DIR", base.join("tauri-cache")),
        ("CODEX_TOKEN_BAR_SUPPORT_BASE_DIR", shared_support),
        ("CODEX_TOKEN_BAR_CACHE_BASE_DIR", shared_cache),
        (
            "CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR",
            base.join("tauri-usage-cache"),
        ),
    ]);

    let mut fail_after_first_import = true;
    let mut observed_targets = Vec::new();
    let mut observed_sources = Vec::new();
    let mut import = |target: &Path, sources: &[PathBuf], manifests: &[(PathBuf, String)]| {
        observed_targets.push(target.to_path_buf());
        observed_sources.push(sources.to_vec());
        let store = route::exact_store_spec(target)?;
        drop(route::open_store_during_bootstrap(
            "exact",
            &store.source_identity,
            &store.logical_path,
            sources,
        )?);
        route::preserve_legacy_exact_migration(target, manifests)?;
        if std::mem::replace(&mut fail_after_first_import, false) {
            return Err("simulated stop after the first verified A import".into());
        }
        Ok(())
    };

    let first = super::bootstrap_at(&current, &cache, &mut import);
    assert!(first.is_err());
    assert!(!route::container_path()
        .unwrap()
        .with_extension("sqlite.initialized")
        .exists());
    assert_unchanged(&originals);

    super::bootstrap_at(&current, &cache, &mut import).unwrap();
    assert_eq!(observed_targets, vec![main.clone(), main.clone()]);
    assert_eq!(
        observed_sources,
        vec![vec![rollback.clone()], vec![rollback.clone()]]
    );
    assert_unchanged(&originals);

    route::bootstrap().unwrap();
    assert!(route::preserves_legacy_exact_migration(&main).unwrap());
    let store = route::exact_store_spec(&main).unwrap();
    let exported = temporary.path().join("exported.sqlite");
    route::export_store_to_path(
        &store.source_identity,
        &store.module,
        &store.logical_path,
        &exported,
    )
    .unwrap();
    assert_eq!(sample_value(&exported), "committed-rollback");
    assert_eq!(
        Connection::open_with_flags(&exported, OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap()
            .query_row("SELECT COUNT(*) FROM sample", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        1,
        "retry must replace the uncommitted import instead of duplicating rows"
    );
    assert_unchanged(&originals);
}

#[test]
fn a_namespace_schema11_paths_are_separate_from_legacy_default_siblings() {
    let index = Path::new("/tmp/exact/home.sqlite3");
    let legacy = super::super::schema11_paths_for_namespace(index, false);
    let isolated = super::super::schema11_paths_for_namespace(index, true);

    assert_eq!(legacy.0, super::super::schema11_candidate_path(index));
    assert_eq!(legacy.1, super::super::schema11_rollback_path(index));
    assert_eq!(legacy.2, super::super::schema11_manifest_path(index));
    assert_ne!(isolated.0, legacy.0);
    assert_ne!(isolated.1, legacy.1);
    assert_ne!(isolated.2, legacy.2);
    assert_eq!(
        isolated,
        super::super::schema11_paths_for_namespace(index, true),
        "the A-owned namespace paths must remain deterministic across retries"
    );
}

#[test]
fn ordinary_open_preserves_registered_history_after_original_main_is_deleted() {
    let temporary = tempfile::tempdir().unwrap();
    let main = temporary.path().join("home.sqlite3");
    write_database(&main, "committed");
    let manifest = write_manifest(&main, Phase::Retained);
    let before = fs::read(&manifest).unwrap();
    fs::remove_file(&main).unwrap();
    let (source, proof) = super::runtime_source(&main, true).unwrap();
    assert!(source.is_none());
    assert!(proof.is_some());
    assert!(super::runtime_source(&main, false).is_err());
    assert_eq!(fs::read(&manifest).unwrap(), before);
}

#[test]
fn ordinary_open_for_new_home_resolves_switching_rollback_and_rejects_unknown_manifest() {
    let temporary = tempfile::tempdir().unwrap();
    let main = temporary.path().join("home.sqlite3");
    let rollback = super::super::schema11_rollback_path(&main);
    write_database(&rollback, "preserved source");
    let manifest = write_manifest(&main, Phase::Switching);
    let (source, _) = super::runtime_source(&main, false).unwrap();
    assert_eq!(source, Some(rollback));
    let mut object: Value = serde_json::from_slice(&fs::read(&manifest).unwrap()).unwrap();
    object["manifest_version"] = json!(999);
    fs::write(&manifest, serde_json::to_vec(&object).unwrap()).unwrap();
    assert!(super::runtime_source(&main, true).is_err());
}

// Public relocation must preserve both originals without counting twice.
#[test]
fn relocated_legacy_pair_imports_once_and_records_both_sources() {
    run_relocated_pair(false, false, false, false);
}

#[test]
fn relocated_pair_selects_proven_cover_with_deleted_raw_sessions() {
    run_relocated_pair(true, false, false, false);
    run_relocated_pair(true, true, false, false);
}

#[test]
fn relocated_pair_retry_preserves_new_exact_rows_before_activation() {
    run_relocated_pair(true, false, true, false);
    run_relocated_pair(true, true, true, false);
}

#[test]
fn released_schema13_cache_and_schema14_support_pair_preserves_deleted_history() {
    run_relocated_pair(false, false, false, true);
    run_relocated_pair(true, false, false, true);
    run_relocated_pair(true, false, true, true);
}

fn run_relocated_pair(advance: bool, advance_cache: bool, freeze_before_advance: bool, old_schema13: bool) {
    let temporary = tempfile::tempdir().unwrap();
    let base = temporary.path();
    let support = base.join("support");
    let current = support.join("exact-token-index");
    let cache_base = base.join("cache");
    let cache = cache_base.join("exact-token-index");
    let home = base.join("home");
    fs::create_dir_all(home.join("sessions")).unwrap();
    fs::create_dir_all(&current).unwrap();
    fs::create_dir_all(&cache).unwrap();
    let _environment = app_paths::app_path_test_env_guard(&[
        ("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", support),
        ("CODEX_TOKEN_BAR_TAURI_CACHE_DIR", base.join("tauri-cache")),
        ("CODEX_TOKEN_BAR_SUPPORT_BASE_DIR", base.join("shared-support")),
        ("CODEX_TOKEN_BAR_CACHE_BASE_DIR", base.join("shared-cache")),
        ("CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR", cache_base),
    ]);
    let session = home.join("sessions/rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065a.jsonl");
    let usage = json!({"input_tokens":100,"cached_input_tokens":0,"output_tokens":15,"reasoning_output_tokens":0,"total_tokens":115});
    let event = json!({"timestamp":"2026-10-31T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":usage,"last_token_usage":usage}}});
    fs::write(&session, format!("{}\n{}\n", json!({"type":"session_meta","payload":{"id":"019ff8b9-09e7-75c1-b9a5-14fe7b60065a"}}), event)).unwrap();
    let legacy = cache.join("home.sqlite3");
    let durable = current.join("home.sqlite3");
    let mut index = super::super::ExactUsageIndex::open_at_for_testing(&home, legacy.clone()).unwrap();
    index.sync(&home, &mut Vec::new()).unwrap();
    drop(index);
    // This is the relocation implementation retained from public v0.9.7.
    super::super::relocate_legacy_index(&home, &legacy, &durable).unwrap();
    if old_schema13 {
        // Inverse of the released representation-only upgrade. The real
        // release fixture below adds the same transition to production probes.
        Connection::open(&legacy).unwrap().execute_batch("DROP TABLE source_representations; DROP VIEW canonical_usage_events; DROP TABLE usage_ledger_duplicates; DROP TABLE usage_scan_certificate; DROP TABLE usage_ledger_attribution_floors; UPDATE usage_ledger_meta SET value='1' WHERE key='revision'; DELETE FROM metadata WHERE key IN ('representation_revision','representation_upgrade_backup','canonical_projection_pending'); UPDATE metadata SET value='13' WHERE key='schema_version';").unwrap();
        let db = Connection::open(&durable).unwrap();
        let mut receipt: Value = serde_json::from_str(&db.query_row("SELECT value FROM metadata WHERE key='release_upgrade_retention_v1'", [], |r| r.get::<_,String>(0)).unwrap()).unwrap();
        receipt["sourceSchema"] = 13.into();
        receipt["targetSchema"] = 13.into();
        db.execute("UPDATE metadata SET value=?1 WHERE key='release_upgrade_retention_v1'", [receipt.to_string()]).unwrap();
        drop(db);
        // The released destination-exists guard is why cache stays at13.
        super::super::relocate_legacy_index(&home, &legacy, &durable).unwrap();
        assert_eq!(Connection::open(&legacy).unwrap().query_row("SELECT value FROM metadata WHERE key='schema_version'",[],|r|r.get::<_,String>(0)).unwrap(), "13");
    }
    let sum = |path: &Path| Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap()
        .query_row("SELECT SUM(tokens) FROM event_rows", [], |row| row.get::<_, i64>(0)).unwrap();
    assert_eq!(sum(&legacy), 115);
    assert_eq!(sum(&durable), 115);
    if freeze_before_advance {
        let store = route::exact_store_spec(&durable).unwrap();
        drop(route::open_store_during_bootstrap("exact", &store.source_identity, &store.logical_path, &[durable.clone(), legacy.clone()]).unwrap());
        assert!(!route::exact_sources_already_consumed(&durable, &[durable.clone(), legacy.clone()]).unwrap());
    }
    let expected = if advance {
        let total = json!({"input_tokens":107,"cached_input_tokens":0,"output_tokens":15,"reasoning_output_tokens":0,"total_tokens":122});
        let last = json!({"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":7});
        let event = json!({"timestamp":"2026-10-31T12:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":total,"last_token_usage":last}}});
        let mut file = fs::OpenOptions::new().append(true).open(&session).unwrap();
        std::io::Write::write_all(&mut file, format!("{event}\n").as_bytes()).unwrap();
        drop(file);
        let path = if advance_cache { &legacy } else { &durable };
        let mut index = super::super::ExactUsageIndex::open_at_for_testing(&home, path.clone()).unwrap();
        index.sync(&home, &mut Vec::new()).unwrap();
        drop(index);
        assert_eq!(sum(path), 122);
        122
    } else { 115 };
    if advance {
        use crate::core::business_store_container::Container;
        let (primary, old) = if advance_cache { (&legacy, &durable) } else { (&durable, &legacy) };
        assert!(Container::exact_snapshot_covers(primary, old).unwrap());
        let check = Connection::open(primary).unwrap();
        if old_schema13 {
            check.execute("ALTER TABLE usage_scan_certificate RENAME TO held_scan_certificate", []).unwrap();
            assert!(!Container::exact_snapshot_covers(primary, old).unwrap(), "A declared ledger2 without its projection objects cannot cover ledger1");
            check.execute("ALTER TABLE held_scan_certificate RENAME TO usage_scan_certificate", []).unwrap();
            assert!(Container::exact_snapshot_covers(primary, old).unwrap());
        }
        let sequence: String = check.query_row("SELECT value FROM metadata WHERE key='event_id_sequence'", [], |r| r.get(0)).unwrap();
        check.execute("UPDATE metadata SET value='0' WHERE key='event_id_sequence'", []).unwrap();
        assert!(!Container::exact_snapshot_covers(primary, old).unwrap(), "A cover must not regress the future event ID allocator");
        check.execute("UPDATE metadata SET value=?1 WHERE key='event_id_sequence'", [&sequence]).unwrap();
        let path: String = check.query_row("SELECT path FROM sources ORDER BY source_id LIMIT 1", [], |r| r.get(0)).unwrap();
        check.execute("UPDATE sources SET path=path||'.unrelated'", []).unwrap();
        assert!(!Container::exact_snapshot_covers(primary, old).unwrap(), "Equal numeric rows do not prove raw-source identity");
        check.execute("UPDATE sources SET path=?1", [&path]).unwrap();
        check.execute("UPDATE usage_ledger_bindings SET raw_offset=COALESCE(raw_offset,0)+1", []).unwrap();
        assert!(!Container::exact_snapshot_covers(primary, old).unwrap(), "Raw offsets in an unchanged generation cannot silently diverge");
        // Restore the complete binding rows from the unchanged predecessor;
        // the appended event's binding is not part of this comparison.
        check.execute("UPDATE usage_ledger_bindings SET raw_offset=raw_offset-1", []).unwrap();
        assert!(Container::exact_snapshot_covers(primary, old).unwrap());
    }
    fs::remove_file(&session).unwrap();
    let before = capture(&[&legacy, &durable]);
    super::bootstrap_at(&current, &cache, |target, sources, _| {
        assert_eq!(sources.len(), 2);
        let store = route::exact_store_spec(target)?;
        drop(route::open_store_during_bootstrap("exact", &store.source_identity, &store.logical_path, sources)?);
        Ok(())
    }).unwrap();
    assert_unchanged(&before);
    let store = route::exact_store_spec(&durable).unwrap();
    let container = crate::core::business_store_container::Container::open_existing(route::container_path().unwrap()).unwrap();
    for source in [&legacy, &durable] {
        let receipt = container.legacy_input_receipt(source).unwrap().unwrap();
        assert_eq!(receipt.store_id, store.id);
    }
    drop(container);
    route::bootstrap().unwrap();
    assert!(route::exact_sources_already_consumed(&durable, &[durable.clone(), legacy.clone()]).unwrap());
    let exported = base.join("exported.sqlite3");
    route::export_store_to_path(&store.source_identity, &store.module, &store.logical_path, &exported).unwrap();
    assert_eq!(sum(&exported), expected);
    println!("RELOCATED_PAIR_RECOVERY: expected={expected} advance_cache={advance_cache} both_receipts=true originals_unchanged=true raw_missing=true");
}
