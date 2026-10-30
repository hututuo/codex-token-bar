//! Public v0.9.7 upgrade evidence. Ordinary tests exercise the real A importer;
//! the dedicated workflow additionally injects this file into a disposable
//! candidate archive and runs `run_production_probe` with cfg(test) disabled.
//! That distinction matters: normal Exact/BodySpeed tests bypass A routing.

use crate::core::business_store_container::{Container, StoreSpec};
use crate::core::{app_paths, business_store_route as route};
use rusqlite::{Connection, OpenFlags};
#[cfg(not(test))]
use serde_json::json;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

const RELEASE_SHA: &str = "0219554ce444b0013987da7b82e3c2e891f4afdb";
const PATH_ENV: [&str; 5] = [
    "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR",
    "CODEX_TOKEN_BAR_TAURI_CACHE_DIR",
    "CODEX_TOKEN_BAR_SUPPORT_BASE_DIR",
    "CODEX_TOKEN_BAR_CACHE_BASE_DIR",
    "CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR",
];

macro_rules! checked {
    ($value:expr) => {
        $value.map_err(|error| error.to_string())?
    };
}
macro_rules! require {
    ($condition:expr, $message:expr) => {
        if !$condition {
            return Err($message.to_string());
        }
    };
}

fn sha(path: &Path) -> Result<String, String> {
    Ok(format!("{:x}", Sha256::digest(checked!(fs::read(path)))))
}

fn read_only(path: &Path) -> Result<Connection, String> {
    Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|error| error.to_string())
}

fn inputs() -> Result<PathBuf, String> {
    let configured = std::env::var_os("TOKENBAR_V097_RUST_INPUTS")
        .ok_or("The required actual v0.9.7 Rust inputs are missing")?;
    let root = checked!(fs::canonicalize(PathBuf::from(configured)));
    let provenance: Value = checked!(serde_json::from_slice(&checked!(fs::read(
        root.join("provenance.json")
    ))));
    require!(
        provenance["release_sha"] == RELEASE_SHA,
        "Wrong public tag SHA"
    );
    require!(
        provenance["platform"] == "rust",
        "Not actual Rust release inputs"
    );
    require!(
        provenance["synthetic"] == true,
        "Only synthetic inputs are allowed"
    );
    let receipt: Value = checked!(serde_json::from_slice(&checked!(fs::read(
        root.join("fixture-result.json")
    ))));
    require!(
        receipt["verified"] == true && receipt["release_sha"] == RELEASE_SHA,
        "Unverified public inputs"
    );
    let artifacts = receipt["artifacts"]
        .as_object()
        .ok_or("Missing artifact hashes")?;
    require!(
        artifacts.len() == 4,
        "Incomplete actual public-release artifacts"
    );
    for (relative, artifact) in artifacts {
        let path = checked!(fs::canonicalize(root.join(relative)));
        require!(
            path.starts_with(&root),
            "Artifact escaped the isolated input root"
        );
        require!(
            artifact["sha256"] == sha(&path)?,
            "A frozen public-release artifact changed"
        );
    }
    for (letter, expected) in [("a", 155_i64), ("b", 310_i64)] {
        let database = read_only(&root.join(format!("exact/{letter}.sqlite3")))?;
        let version: String = checked!(database.query_row(
            "SELECT value FROM metadata WHERE key='schema_version'",
            [],
            |row| row.get(0)
        ));
        let (count, tokens): (i64, i64) = checked!(database.query_row(
            "SELECT COUNT(*),COALESCE(SUM(tokens),0) FROM event_rows",
            [],
            |row| Ok((row.get(0)?, row.get(1)?))
        ));
        require!(
            version == "14" && count >= 2 && tokens == expected,
            "The old producer did not generate a populated schema14"
        );
    }
    Ok(root)
}

fn exact_spec(path: &Path) -> Result<StoreSpec, String> {
    route::exact_store_spec(path)
}

fn import_exact(path: &Path) -> Result<(), String> {
    let spec = exact_spec(path)?;
    drop(route::open_store_during_bootstrap(
        "exact",
        &spec.source_identity,
        &spec.logical_path,
        &[path.to_path_buf()],
    )?);
    Ok(())
}

fn verify_export(source: &Path, spec: &StoreSpec, target: &Path) -> Result<(), String> {
    route::export_store_to_path(
        &spec.source_identity,
        &spec.module,
        &spec.logical_path,
        target,
    )?;
    let expected = checked!(Container::snapshot_digest_path(source));
    let actual = checked!(Container::snapshot_digest_path(target));
    require!(
        actual == expected,
        "A changed schema, a typed field, rowid, key, or AUTOINCREMENT sequence during import"
    );
    Ok(())
}

#[cfg(not(test))]
fn validated_runtime(input: &Path, frozen: &Path) -> Result<PathBuf, String> {
    require!(
        input.is_absolute(),
        "An absolute disposable runtime root is required"
    );
    let root = checked!(fs::canonicalize(input));
    let configured = checked!(std::env::var("TOKENBAR_V097_RUNTIME_ROOT"));
    require!(
        checked!(fs::canonicalize(configured)) == root,
        "Runtime root does not match its explicit guard"
    );
    let temp = checked!(fs::canonicalize(std::env::temp_dir()));
    require!(
        root.starts_with(temp)
            && root
                .file_name()
                .and_then(|v| v.to_str())
                .is_some_and(|v| v.starts_with("tokenbar-v097-runtime-")),
        "Probe root is not an owned OS-temporary directory"
    );
    require!(
        checked!(fs::read_to_string(root.join(".tokenbar-v097-disposable"))).trim() == RELEASE_SHA,
        "Missing disposable root ownership marker"
    );
    require!(
        frozen.starts_with(&root),
        "Old Codex Homes must be inside the same isolated runtime root"
    );
    for key in PATH_ENV {
        let path = std::env::var_os(key)
            .ok_or_else(|| format!("Required path override {key} is missing"))?;
        let path = checked!(fs::canonicalize(PathBuf::from(path)));
        require!(
            path != root && path.starts_with(&root),
            format!("{key} escaped the isolated root")
        );
    }
    require!(
        std::env::var_os("CODEX_TOKEN_BAR_TEST_EXACT_INDEX_PATH").is_none(),
        "Production probe cannot use a cfg(test) Exact override"
    );
    let support = app_paths::quota_history_database_path()
        .ok_or("Missing isolated support path")?
        .parent()
        .ok_or("No support parent")?
        .to_path_buf();
    require!(
        app_paths::multi_client_usage_database_path()
            == Some(support.join("multi-client-usage.sqlite")),
        "B was redirected outside the expected business root"
    );
    Ok(root)
}

#[cfg(not(test))]
fn fnv(text: &str) -> String {
    let hash = text.bytes().fold(0xcbf29ce484222325_u64, |mut hash, byte| {
        hash ^= u64::from(byte);
        hash.wrapping_mul(0x100000001b3)
    });
    format!("{hash:016x}")
}

#[cfg(not(test))]
fn paths(frozen: &Path) -> Result<Vec<(PathBuf, PathBuf)>, String> {
    let exact = app_paths::usage_history_dir().ok_or("No isolated Exact root")?;
    Ok(["a", "b"]
        .iter()
        .map(|letter| {
            let home = fs::canonicalize(frozen.join(format!("home-{letter}")))
                .map_err(|e| e.to_string())?;
            let index = exact.join(format!("{}.sqlite3", fnv(&home.to_string_lossy())));
            Ok((home, index))
        })
        .collect::<Result<Vec<_>, String>>()?)
}

#[cfg(not(test))]
fn start() -> Result<(), String> {
    let coordinator = crate::core::business_startup::process_coordinator();
    require!(
        coordinator.begin_initial(),
        "Startup was already claimed in this isolated process"
    );
    let result = route::bootstrap();
    coordinator.finish(result.clone());
    result
}

#[cfg(not(test))]
fn body_check(frozen: &Path, home: &Path) -> Result<(), String> {
    use crate::core::live_rate;
    let now =
        checked!(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)).as_secs_f64();
    let scope = live_rate::LiveRateSourceScope::new(home.to_string_lossy(), home.to_string_lossy());
    let original = frozen.join("support/observed-speed-release097.json");
    let scope_key = format!("{}\n{}", home.to_string_lossy(), home.to_string_lossy());
    let legacy_json = app_paths::quota_history_database_path()
        .ok_or("No isolated support")?
        .with_file_name(format!("observed-speed-{}.json", fnv(&scope_key)));
    require!(
        sha(&legacy_json)? == sha(&original)?,
        "The legacy JSON changed before its body owner loaded"
    );
    let page = live_rate::read_body_speed_history(home, &scope, 0, 100, Some(now), Some(15));
    require!(
        page.samples.len() == 1 && page.samples[0].id == "v097-rust-body",
        "Actual production JSON-to-B import lost or duplicated the released body sample"
    );
    require!(
        page.retention_days == 15,
        "Released body retention was lost"
    );
    let repeated = live_rate::read_body_speed_history(home, &scope, 0, 100, Some(now), Some(15));
    require!(
        repeated.samples == page.samples,
        "Body JSON replay was not idempotent"
    );
    let b = app_paths::multi_client_usage_database_path().ok_or("No isolated B")?;
    require!(b != route::container_path()?, "A and B are the same file");
    let database = read_only(&b)?;
    let version: i64 = checked!(database.query_row("PRAGMA user_version", [], |row| row.get(0)));
    require!(
        version == 2,
        "B's physical version is not owned by the usage ledger"
    );
    let sentinel: i64 = checked!(database.query_row(
        "SELECT COUNT(*) FROM activity_speed_samples WHERE id='v097-existing-b-row'",
        [],
        |row| row.get(0)
    ));
    require!(
        sentinel == 1,
        "Body migration erased an unrelated committed B module row"
    );
    require!(
        sha(&legacy_json)? == sha(&original)?,
        "The body owner wrote to frozen public JSON"
    );
    Ok(())
}

/// Called only from the feature-gated example injected into a temporary exact
/// candidate archive. The shipped application never references this function.
#[cfg(not(test))]
pub fn run_production_probe(input: &Path, phase: &str) -> Result<Value, String> {
    use crate::core::usage::token_count_jsonl as token;
    // Validate every data root before opening even a purported old SQLite
    // input. Missing overrides fail instead of falling back to user APPDATA.
    let configured =
        std::env::var_os("TOKENBAR_V097_RUST_INPUTS").ok_or("Missing isolated release inputs")?;
    let frozen = checked!(fs::canonicalize(PathBuf::from(configured)));
    let root = validated_runtime(input, &frozen)?;
    require!(
        inputs()? == frozen,
        "Frozen input root changed after validation"
    );
    let stores = paths(&frozen)?;
    let a = route::container_path()?;
    let marker = PathBuf::from(format!("{}.initialized", a.display()));
    let quota = app_paths::quota_history_database_path().ok_or("No isolated quota path")?;
    if phase == "crash" {
        require!(
            !a.exists() && !marker.exists(),
            "Refusing existing runtime A"
        );
        checked!(fs::create_dir_all(
            stores[0].1.parent().ok_or("No Exact parent")?
        ));
        for (index, (_, target)) in stores.iter().enumerate() {
            require!(!target.exists(), "Refusing an existing legacy Exact source");
            checked!(fs::copy(
                frozen.join(format!(
                    "exact/{}.sqlite3",
                    if index == 0 { "a" } else { "b" }
                )),
                target
            ));
        }
        checked!(fs::copy(
            frozen.join("support/quota-history.sqlite"),
            &quota
        ));
        let scope = format!(
            "{}\n{}",
            stores[0].0.to_string_lossy(),
            stores[0].0.to_string_lossy()
        );
        let json_path = quota.with_file_name(format!("observed-speed-{}.json", fnv(&scope)));
        checked!(fs::copy(
            frozen.join("support/observed-speed-release097.json"),
            json_path
        ));
        import_exact(&stores[0].1)?;
        // Exit without SQLite/Rust destructors, while an actual committed WAL
        // handle remains open. No initialized marker has been published.
        let database = checked!(Connection::open(&a));
        checked!(database.execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; BEGIN IMMEDIATE; INSERT INTO tb_container_meta(key,value) VALUES('release097_crash_probe','committed-before-exit'); COMMIT;"));
        std::process::exit(86);
    }
    if phase == "missing-a" {
        require!(
            a.is_file() && marker.is_file(),
            "Missing-A fixture must start from a committed runtime"
        );
        let saved = a.with_extension("preserved.sqlite");
        require!(!saved.exists(), "Refusing to overwrite rollback evidence");
        checked!(fs::rename(&a, &saved));
        let result = route::bootstrap();
        let recreated = a.exists();
        checked!(fs::rename(saved, &a));
        require!(
            result.is_err() && !recreated,
            "Missing committed A was silently recreated"
        );
        return Ok(
            json!({"status":"PASS","phase":phase,"check":"missing-A-refuses-stale-resurrection"}),
        );
    }
    require!(
        phase == "resume" || phase == "reopen",
        "Unknown probe phase"
    );
    if phase == "resume" {
        require!(
            !marker.exists(),
            "Crash candidate unexpectedly published initialized"
        );
        require!(
            PathBuf::from(format!("{}-wal", a.display())).is_file(),
            "The abrupt-exit WAL fixture is missing"
        );
        let database = read_only(&a)?;
        let value: String = checked!(database.query_row(
            "SELECT value FROM tb_container_meta WHERE key='release097_crash_probe'",
            [],
            |row| row.get(0)
        ));
        require!(
            value == "committed-before-exit",
            "Committed crash WAL was lost before retry"
        );
    }
    start()?;
    if phase == "resume" {
        for (index, (_, path)) in stores.iter().enumerate() {
            verify_export(
                &frozen.join(format!(
                    "exact/{}.sqlite3",
                    if index == 0 { "a" } else { "b" }
                )),
                &exact_spec(path)?,
                &root.join(format!("proof-exact-{index}.sqlite3")),
            )?;
        }
        let identity = route::source_identity("quota_history_legacy", &quota)?;
        let spec = checked!(StoreSpec::new(
            "quota_history_legacy",
            &identity,
            format!("legacy/quota-history/{identity}")
        ));
        verify_export(
            &frozen.join("support/quota-history.sqlite"),
            &spec,
            &root.join("proof-quota.sqlite"),
        )?;
        for ((home, _), expected) in stores.iter().zip([155_u64, 310]) {
            require!(
                token::dashboard_snapshot(home)?.stats.total_tokens == expected,
                "Upgraded production totals differ from the public release"
            );
            require!(
                token::dashboard_snapshot(home)?.stats.total_tokens == expected,
                "Warm production refresh changed accounting"
            );
        }
        let extra = stores[0]
            .0
            .join("sessions/rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065b.jsonl");
        require!(!extra.exists(), "Refusing an existing incremental fixture");
        let line=json!({"timestamp":"2026-10-21T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5,"output_tokens":2,"total_tokens":7},"last_token_usage":{"input_tokens":5,"output_tokens":2,"total_tokens":7}}}}).to_string()+"\n";
        checked!(fs::write(&extra, line));
        require!(
            token::dashboard_snapshot(&stores[0].0)?.stats.total_tokens == 162,
            "New usage was not added to A"
        );
        require!(
            token::dashboard_snapshot(&stores[0].0)?.stats.total_tokens == 162,
            "Repeated new usage was double counted"
        );
        checked!(fs::remove_file(extra));
        let parked = root.join("parked-synthetic-sessions");
        checked!(fs::rename(stores[0].0.join("sessions"), &parked));
        let retained = token::dashboard_snapshot(&stores[0].0);
        checked!(fs::rename(&parked, stores[0].0.join("sessions")));
        require!(
            retained?.stats.total_tokens == 162,
            "Deleted/absent JSONL erased old accounting"
        );
        let b = crate::core::multi_client_usage::open_activity_module_connection()?;
        checked!(b.execute("INSERT INTO activity_speed_samples(source_identity,id,display_mode,estimator_id,estimator_version,metric_kind,client,model,started_at,ended_at,output_rate,covered_seconds,weighted_output) VALUES('v097-synthetic','v097-existing-b-row','model','fixture','1','output','codex','gpt-6.1-sol',1800000000,1800000010,12,10,120)", []));
        drop(b);
        body_check(&frozen, &stores[0].0)?;
        require!(
            token::dashboard_snapshot(&stores[0].0)?.stats.total_tokens == 162,
            "Importing B changed A's old accounting"
        );
        // The old physical indexes still contain their original fields/totals.
        for (index, (_, path)) in stores.iter().enumerate() {
            require!(
                sha(path)?
                    == sha(&frozen.join(format!(
                        "exact/{}.sqlite3",
                        if index == 0 { "a" } else { "b" }
                    )))?,
                "The production owner wrote to a frozen legacy index"
            );
            checked!(fs::remove_file(path));
        }
        require!(
            sha(&quota)? == sha(&frozen.join("support/quota-history.sqlite"))?,
            "A quota owner changed the frozen legacy quota file"
        );
        checked!(fs::remove_file(quota));
    } else {
        require!(
            token::dashboard_snapshot(&stores[0].0)?.stats.total_tokens == 162,
            "Restart reverted A to the frozen public total"
        );
        require!(
            token::dashboard_snapshot(&stores[1].0)?.stats.total_tokens == 310,
            "Restart mixed independent Home identities"
        );
        body_check(&frozen, &stores[0].0)?;
        let identity = route::source_identity("quota_history_legacy", &quota)?;
        let quota_store = route::open_registered_store(
            "quota_history_legacy",
            &identity,
            &format!("legacy/quota-history/{identity}"),
        )?
        .ok_or("Deleting frozen quota hid its active A partition")?;
        let id: i64 =
            checked!(quota_store.query_row("SELECT id FROM quota_snapshots", [], |row| row.get(0)));
        require!(id == 42, "Restart lost the released quota primary key");
        drop(quota_store);
        route::bootstrap()?;
    }
    inputs()?; // Frozen hashes must still match after all operations.
    Ok(
        json!({"status":"PASS","phase":phase,"releaseSHA":RELEASE_SHA,"cfgTest":false,"exactHomes":2,"totals":[162,310],"bodyInB":true,"oldArtifactsUnchanged":true,"crashWALRetained":true}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn isolated(run: impl FnOnce(&Path, &Path)) {
        let old =
            inputs().expect("The dedicated actual-release tests require verified v0.9.7 inputs");
        let root = tempfile::tempdir().unwrap();
        let support = root.path().join("support");
        fs::create_dir_all(&support).unwrap();
        let _guard = app_paths::app_path_test_env_guard(&[
            (PATH_ENV[0], support),
            (PATH_ENV[1], root.path().join("cache")),
            (PATH_ENV[2], root.path().join("shared-support")),
            (PATH_ENV[3], root.path().join("shared-cache")),
            (PATH_ENV[4], root.path().join("old-cache")),
        ]);
        run(root.path(), &old);
    }

    #[test]
    #[ignore = "dedicated workflow provides actual public-release inputs"]
    fn actual_v097_route_preserves_full_proof_and_deleted_source_history() {
        isolated(|root, old| {
            let source = root.join("old14.sqlite3");
            fs::copy(old.join("exact/a.sqlite3"), &source).unwrap();
            let bytes = fs::read(&source).unwrap();
            import_exact(&source).unwrap();
            route::bootstrap().unwrap(); // cfg(test) Exact discovery is intentionally bypassed above.
            let spec = exact_spec(&source).unwrap();
            verify_export(&source, &spec, &root.join("proof.sqlite3")).unwrap();
            let connection =
                route::open_registered_store("exact", &spec.source_identity, &spec.logical_path)
                    .unwrap()
                    .unwrap();
            connection
                .execute(
                    "INSERT INTO metadata(key,value) VALUES('release097_new_write','retained')",
                    [],
                )
                .unwrap();
            drop(connection);
            assert_eq!(fs::read(&source).unwrap(), bytes);
            fs::remove_file(&source).unwrap();
            let connection =
                route::open_registered_store("exact", &spec.source_identity, &spec.logical_path)
                    .unwrap()
                    .unwrap();
            assert_eq!(
                connection
                    .query_row(
                        "SELECT value FROM metadata WHERE key='release097_new_write'",
                        [],
                        |r| r.get::<_, String>(0)
                    )
                    .unwrap(),
                "retained"
            );
            assert_eq!(
                connection
                    .query_row("SELECT SUM(tokens) FROM event_rows", [], |r| r
                        .get::<_, i64>(0))
                    .unwrap(),
                155
            );
            println!("V097_RUST_UNIT_PROOF_OK");
        });
    }

    #[test]
    #[ignore = "dedicated workflow provides actual public-release inputs"]
    fn actual_v097_pending_source_disappearance_blocks_and_retries() {
        isolated(|root, old| {
            let source = root.join("old14.sqlite3");
            fs::copy(old.join("exact/a.sqlite3"), &source).unwrap();
            import_exact(&source).unwrap();
            let saved = root.join("parked.sqlite3");
            fs::rename(&source, &saved).unwrap();
            assert!(route::bootstrap().is_err());
            assert!(!PathBuf::from(format!(
                "{}.initialized",
                route::container_path().unwrap().display()
            ))
            .exists());
            fs::rename(saved, &source).unwrap();
            let db = Connection::open(&source).unwrap();
            db.execute(
                "INSERT INTO metadata(key,value) VALUES('release097_late_source','observed')",
                [],
            )
            .unwrap();
            drop(db);
            import_exact(&source).unwrap();
            route::bootstrap().unwrap();
            verify_export(
                &source,
                &exact_spec(&source).unwrap(),
                &root.join("recovered.sqlite3"),
            )
            .unwrap();
            println!("V097_RUST_PENDING_RETRY_OK");
        });
    }

    #[test]
    #[ignore = "dedicated workflow provides actual public-release inputs"]
    fn actual_v097_quota_initializer_rows_and_sequence_reach_a() {
        isolated(|root, old| {
            let source = app_paths::quota_history_database_path().unwrap();
            fs::copy(old.join("support/quota-history.sqlite"), &source).unwrap();
            route::bootstrap().unwrap();
            let identity = route::source_identity("quota_history_legacy", &source).unwrap();
            let spec = StoreSpec::new(
                "quota_history_legacy",
                &identity,
                format!("legacy/quota-history/{identity}"),
            )
            .unwrap();
            verify_export(&source, &spec, &root.join("quota-proof.sqlite")).unwrap();
            let db = route::open_registered_store(
                &spec.module,
                &spec.source_identity,
                &spec.logical_path,
            )
            .unwrap()
            .unwrap();
            assert_eq!(
                db.query_row("SELECT id FROM quota_snapshots", [], |r| r.get::<_, i64>(0))
                    .unwrap(),
                42
            );
            assert_eq!(
                db.query_row(
                    "SELECT seq FROM sqlite_sequence WHERE name='quota_snapshots'",
                    [],
                    |r| r.get::<_, i64>(0)
                )
                .unwrap(),
                12345
            );
            println!("V097_RUST_QUOTA_PROOF_OK");
        });
    }
}
