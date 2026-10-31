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
