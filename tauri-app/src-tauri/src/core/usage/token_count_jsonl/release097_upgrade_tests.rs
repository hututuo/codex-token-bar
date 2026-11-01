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
fn resolved_destination(path: &Path) -> Result<PathBuf, String> {
    let mut existing = path.to_path_buf();
    let mut suffix = Vec::new();
    loop {
        match fs::symlink_metadata(&existing) {
            Ok(_) => break,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                suffix.push(
                    existing
                        .file_name()
                        .ok_or("No existing destination ancestor")?
                        .to_os_string(),
                );
                require!(existing.pop(), "Destination escaped its filesystem root");
            }
            Err(error) => return Err(error.to_string()),
        }
    }
    let mut resolved = checked!(fs::canonicalize(existing));
    for part in suffix.into_iter().rev() {
        resolved.push(part);
    }
    Ok(resolved)
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
    for derived in [
        support.clone(),
        app_paths::usage_history_dir().ok_or("Missing isolated Exact root")?,
        app_paths::multi_client_usage_database_path().ok_or("Missing isolated B")?,
        route::container_path()?,
    ] {
        require!(
            resolved_destination(&derived)?.starts_with(&root),
            "A production data-path resolver ignored its isolated override"
        );
    }
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
    body_check_with_b_initial_state(frozen, home, true)
}

#[cfg(not(test))]
fn incident_0910_body_check(frozen: &Path, home: &Path) -> Result<(), String> {
    body_check_with_b_initial_state(frozen, home, false)
}

#[cfg(not(test))]
fn body_check_with_b_initial_state(frozen: &Path, home: &Path, existing_b_canary: bool) -> Result<(), String> {
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
        sentinel == if existing_b_canary { 1 } else { 0 },
        if existing_b_canary {
            "Body migration erased an unrelated committed B module row"
        } else {
            "First B initialization unexpectedly created the pre-existing B canary"
        }
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
    if phase.starts_with("manifest-") {
        return run_legacy_manifest_probe(&root, &frozen, phase);
    }
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

/// Runs with cfg(test) disabled in a fresh, guarded process for each case.
/// Inputs are generated by the actual public v0.9.7 producer above. No user's
/// database, path override fallback, or provider connection is used.
#[cfg(not(test))]
fn run_legacy_manifest_probe(root: &Path, frozen: &Path, scenario: &str) -> Result<Value, String> {
    if let Some(stage) = scenario.strip_prefix("manifest-0910-combined-relocated-v13-pair-") {
        return run_incident_0910_probe(root, frozen, stage);
    }
    let (phase, expect_ready, current) = match scenario {
        "manifest-retained" => ("Retained", true, false),
        "manifest-current-retained" => ("Retained", true, true),
        "manifest-relocated-pair" => ("Retained", true, true),
        "manifest-late-relocated-pair" => ("Retained", true, true),
        "manifest-relocated-v13-pair" => ("Retained", true, true),
        "manifest-late-relocated-v13-pair" => ("Retained", true, true),
        "manifest-switched" => ("Switched", true, false),
        "manifest-switching" => ("Switching", true, false),
        "manifest-rollback" => ("Switching", true, false),
        "manifest-missing" => ("Retained", false, false),
        "manifest-unknown" => ("Retained", false, false),
        "manifest-stray-wal" => ("Switching", false, false),
        "manifest-existing-a" => ("Retained", true, true),
        "manifest-late-retained" => ("Retained", true, true),
        "manifest-late-switching" => ("Switching", true, true),
        "manifest-late-rollback" => ("Switching", true, false),
        "manifest-late-mixed" => ("Switching", true, true),
        _ => return Err("Unknown manifest probe scenario".into()),
    };
    let stores = paths(frozen)?;
    let (home, target) = &stores[0];
    let a = route::container_path()?;
    let marker = PathBuf::from(format!("{}.initialized", a.display()));
    require!(!a.exists() && !marker.exists(), "Probe refuses an existing A");
    // Recreate the partial A left before 0.9.8 hit its unconditional guard.
    // No initialized marker exists; the durable import journal must survive.
    let partial = root.join("partial-before-exact.sqlite");
    let db = checked!(Connection::open(&partial));
    checked!(db.execute_batch("CREATE TABLE canary(id INTEGER PRIMARY KEY, tokens INTEGER NOT NULL); INSERT INTO canary VALUES(1,77);"));
    drop(db);
    drop(route::open_store_during_bootstrap("fixture-partial", "fixture", "fixture/partial", &[partial.clone()])?);
    let coordinator = crate::core::business_startup::process_coordinator();
    require!(coordinator.begin_initial(), "Fresh probe startup already claimed");
    let late = scenario.starts_with("manifest-late-");
    if late {
        let initial = route::bootstrap();
        coordinator.finish(initial.clone());
        initial?;
    }
    let main = if current { target.clone() } else {
        app_paths::tauri_usage_cache_dir().ok_or("No guarded old cache")?
            .join("exact-token-index").join(target.file_name().ok_or("No Exact filename")?)
    };
    checked!(fs::create_dir_all(main.parent().ok_or("No old Exact parent")?));
    checked!(fs::copy(frozen.join("exact/a.sqlite3"), &main));
    let candidate = PathBuf::from(format!("{}.schema11-candidate", main.display()));
    let rollback = PathBuf::from(format!("{}.schema11-rollback", main.display()));
    let manifest = PathBuf::from(format!("{}.schema11-migration.json", main.display()));
    // A different candidate amount catches accidental candidate resurrection.
    checked!(fs::copy(frozen.join("exact/b.sqlite3"), &candidate));
    checked!(fs::copy(frozen.join("exact/a.sqlite3"), &rollback));
    if matches!(scenario, "manifest-rollback" | "manifest-missing" | "manifest-stray-wal" | "manifest-late-rollback") {
        checked!(fs::remove_file(&main));
    }
    let receipt = json!({
        "manifest_version": if scenario == "manifest-unknown" { 999 } else { 1 },
        "phase":phase,"source_path":main.to_string_lossy(),
        "candidate_path":candidate.to_string_lossy(),"rollback_path":rollback.to_string_lossy(),
        "source_receipt":{"schema_version":9,"revision":null,"dashboard_revision":null,
            "published_generation":1,"building_generation":null,
            "database":{"size":checked!(fs::metadata(&rollback)).len(),"modified_ns":"0"},"wal":null}
    });
    if scenario == "manifest-late-mixed" {
        let spec = route::exact_store_spec(target)?;
        drop(route::open_store("exact", &spec.source_identity, &spec.logical_path, &[main.clone()])?);
        route::clone_exact_store(target, &rollback)?;
    }
    if scenario != "manifest-existing-a" {
        checked!(fs::write(&manifest, checked!(serde_json::to_vec(&receipt))));
    }
    let stray = PathBuf::from(format!("{}-wal", main.display()));
    if scenario == "manifest-stray-wal" { checked!(fs::write(&stray, b"unmoved committed WAL")); }
    let relocated_pair = scenario.contains("relocated-") && scenario.ends_with("pair");
    let schema13_pair = scenario.ends_with("relocated-v13-pair");
    let mut extra_original = None;
    if relocated_pair {
        let old = app_paths::tauri_usage_cache_dir().ok_or("No guarded old cache")?
            .join("exact-token-index").join(target.file_name().ok_or("No old filename")?);
        checked!(fs::create_dir_all(old.parent().ok_or("No old parent")?));
        let prior = if schema13_pair {
            let inputs13 = root.join("inputs13");
            let provenance: Value = checked!(serde_json::from_slice(&checked!(fs::read(inputs13.join("provenance.json")))));
            let receipt: Value = checked!(serde_json::from_slice(&checked!(fs::read(inputs13.join("fixture-result.json")))));
            require!(provenance["release_sha"] == "ba4c59060c240af703e42d288c303a56cb0259e3"
                && provenance["synthetic"] == true && receipt["verified"] == true
                && receipt["release_sha"] == provenance["release_sha"], "Unverified public v0.9.3 fixture");
            let prior = inputs13.join("exact/a.sqlite3");
            require!(receipt["artifacts"]["exact/a.sqlite3"]["sha256"] == sha(&prior)?, "Public v0.9.3 fixture changed");
            require!(receipt["upgrade_release_sha"] == RELEASE_SHA, "The pair was not upgraded by public v0.9.7");
            let upgraded = inputs13.join("exact/a-upgraded.sqlite3");
            require!(receipt["artifacts"]["exact/a-upgraded.sqlite3"]["sha256"] == sha(&upgraded)?, "The released upgraded support fixture changed");
            checked!(fs::copy(&upgraded, &main));
            prior
        } else { frozen.join("exact/a.sqlite3") };
        checked!(fs::copy(prior, &old));
        let db = checked!(Connection::open(&main));
        let version = if schema13_pair { 13 } else { 14 };
        let copied = json!({"sourcePath":old.to_string_lossy(),
            "rollbackPath":format!("{}.schema11-rollback",old.display()),
            "manifestPath":format!("{}.schema11-migration.json",old.display()),
            "sourceSchema":version,"targetSchema":version,"status":"copied"});
        checked!(db.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('release_upgrade_retention_v1',?1)", [copied.to_string()]));
        drop(db);
        extra_original = Some((old.clone(), sha(&old)?));
        // v0.9.9 registers this Exact partition before rejecting divergent
        // sources. Recreate that failed-startup residue, not a clean install.
        if !late { checked!(checked!(Container::open_existing(&a)).register(&route::exact_store_spec(target)?)); }
    }
    let mut original_files: Vec<(PathBuf, String)> = [&main, &candidate, &rollback, &manifest, &stray]
        .iter().filter(|p| p.is_file()).map(|p| Ok((p.to_path_buf(), sha(p)?)))
        .collect::<Result<_, String>>()?;

    if let Some(original) = extra_original { original_files.push(original); }
    let prepared = if late { Ok(()) } else {
        coordinator.finish(Err("simulated previous 0.9.8/0.9.9 legacy startup failure".into()));
        coordinator.begin_retry()?;
        let prepared = route::bootstrap();
        coordinator.finish(prepared.clone());
        prepared
    };
    require!(prepared.is_ok() == expect_ready, format!("Unexpected startup result: {prepared:?}"));
    require!(marker.is_file() == expect_ready, "Startup marker published in the wrong state");
    if expect_ready {
        if scenario == "manifest-existing-a" {
            // Keep 0.9.8 canonical data and its derived A rollback, but never
            // rewrite its old physical receipt when preparing new work.
            route::clone_exact_store(target, &rollback)?;
            checked!(fs::write(&manifest, checked!(serde_json::to_vec(&receipt))));
            original_files.push((manifest.clone(), sha(&manifest)?));
        }
        let isolated = crate::core::usage::token_count_jsonl::verify_legacy_migration_fixture(home, target)?;
        let expected_isolated = !late || current;
        require!(isolated == expected_isolated, "A/legacy artifact ownership was not preserved");
        let spec = route::exact_store_spec(target)?;
        let exported = root.join("recovered-exact.sqlite");
        route::export_store_to_path(&spec.source_identity, "exact", &spec.logical_path, &exported)?;
        require!(checked!(Container::snapshot_digest_path(&exported)) ==
            checked!(Container::snapshot_digest_path(if relocated_pair { main.clone() } else { frozen.join("exact/a.sqlite3") })),
            "Schema, typed values, rows or usage changed during recovery");
        route::bootstrap()?;
        route::export_store_to_path(&spec.source_identity, "exact", &spec.logical_path, &root.join("repeated-exact.sqlite"))?;
        require!(checked!(Container::snapshot_digest_path(root.join("repeated-exact.sqlite"))) ==
            checked!(Container::snapshot_digest_path(&exported)), "Repeated startup replayed or duplicated old usage");
    }
    let partial_spec = checked!(StoreSpec::new("fixture-partial", "fixture", "fixture/partial"));
    let partial_store = checked!(checked!(Container::open_existing(&a)).into_store_connection(&partial_spec));
    let tokens: i64 = checked!(partial_store.query_row("SELECT tokens FROM canary WHERE id=1", [], |r| r.get(0)));
    require!(tokens == 77, "Partial A's earlier imported rows were lost");
    for (path, before) in original_files {
        require!(sha(&path)? == before, format!("Legacy evidence changed: {}", path.display()));
    }
    Ok(json!({"status":"PASS","scenario":scenario,"startupReady":expect_ready,
        "actualPublicRelease":RELEASE_SHA,"schema13PublicRelease":if schema13_pair { Some("ba4c59060c240af703e42d288c303a56cb0259e3") } else { None },"originalFilesUnchanged":true,
        "candidateNotImported":true,"existingPartialAPreserved":true}))
}

#[cfg(not(test))]
const INCIDENT_0910_SESSION_ID: &str = "019ff8b9-09e7-75c1-b9a5-14fe7b60065a";

#[cfg(not(test))]
const INCIDENT_0910_SCENARIO: &str = "manifest-0910-combined-relocated-v13-pair";

#[cfg(not(test))]
fn run_incident_0910_probe(root: &Path, frozen: &Path, stage: &str) -> Result<Value, String> {
    match stage {
        "prepare" => prepare_incident_0910_probe(root, frozen),
        "resume" => resume_incident_0910_probe(root, frozen, false),
        "reopen" => resume_incident_0910_probe(root, frozen, true),
        _ => Err("Unknown 0.9.10 incident probe phase".into()),
    }
}

#[cfg(not(test))]
fn incident_0910_state_path(root: &Path) -> PathBuf {
    root.join("incident-0910-combined-state.json")
}

#[cfg(not(test))]
fn incident_0910_file_record(path: &Path) -> Result<Value, String> {
    Ok(json!({ "path": path.to_string_lossy(), "sha256": sha(path)? }))
}

#[cfg(not(test))]
fn incident_0910_check_files(root: &Path, state: &Value) -> Result<(), String> {
    let records = state["immutableFiles"]
        .as_array()
        .ok_or("Combined incident fixture has no file evidence")?;
    for record in records {
        let path = PathBuf::from(record["path"].as_str().ok_or("Incident file has no path")?);
        require!(path.starts_with(root), "Incident evidence escaped its isolated root");
        require!(sha(&path)? == record["sha256"].as_str().ok_or("Incident file has no digest")?,
            format!("A source or frozen artifact changed: {}", path.display()));
    }
    Ok(())
}

#[cfg(not(test))]
fn incident_0910_read_state(root: &Path) -> Result<Value, String> {
    let state: Value = checked!(serde_json::from_slice(&checked!(fs::read(incident_0910_state_path(root)))));
    require!(state["scenario"] == INCIDENT_0910_SCENARIO, "Wrong combined incident state file");
    incident_0910_check_files(root, &state)?;
    Ok(state)
}

#[cfg(not(test))]
fn incident_0910_table_exists(connection: &Connection, table: &str) -> Result<bool, String> {
    checked!(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1)",
        [table],
        |row| row.get(0)
    ))
}

#[cfg(not(test))]
fn incident_0910_event_facts(connection: &Connection) -> Result<(i64, String), String> {
    let mut statement = checked!(connection.prepare(
        "SELECT id,source_id,ordinal,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,user_prompt_start,user_prompt_end,assistant_response_start,assistant_response_end,accounting_kind,reported_total_tokens,token_source_offset,legacy_tokens FROM event_rows ORDER BY id"
    ));
    let rows = checked!(statement.query_map([], |row| Ok(json!([
        row.get::<_, i64>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?,
        row.get::<_, i64>(3)?, row.get::<_, i64>(4)?, row.get::<_, i64>(5)?,
        row.get::<_, i64>(6)?, row.get::<_, i64>(7)?, row.get::<_, i64>(8)?,
        row.get::<_, Option<String>>(9)?, row.get::<_, Option<i64>>(10)?,
        row.get::<_, Option<i64>>(11)?, row.get::<_, Option<i64>>(12)?,
        row.get::<_, Option<i64>>(13)?, row.get::<_, i64>(14)?,
        row.get::<_, Option<i64>>(15)?, row.get::<_, Option<i64>>(16)?,
        row.get::<_, Option<i64>>(17)?
    ]))));
    let rows = rows.collect::<rusqlite::Result<Vec<_>>>().map_err(|error| error.to_string())?;
    let bytes = serde_json::to_vec(&rows).map_err(|error| error.to_string())?;
    Ok((rows.len() as i64, format!("{:x}", Sha256::digest(bytes))))
}

#[cfg(not(test))]
fn incident_0910_source_chunks(connection: &Connection, source_id: i64) -> Result<Vec<(i64, i64, Vec<u8>)>, String> {
    require!(incident_0910_table_exists(connection, "source_chunks")?,
        "Public schema13/14 fixture lacks persisted source_chunks");
    let mut statement = checked!(connection.prepare(
        "SELECT chunk_index,byte_count,sha256 FROM source_chunks WHERE source_id=?1 ORDER BY chunk_index"
    ));
    checked!(statement.query_map([source_id], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .map_err(|error| error.to_string())?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|error| error.to_string()))
}

#[cfg(not(test))]
fn incident_0910_source(connection: &Connection, session_id: &str) -> Result<(i64, String, String, bool), String> {
    let mut statement = checked!(connection.prepare(
        "SELECT source_id,path,session_id,is_explicit_subagent_fork FROM sources WHERE session_id=?1 ORDER BY source_id"
    ));
    let rows = checked!(statement.query_map([session_id], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get::<_, i64>(3)? != 0)))
        .map_err(|error| error.to_string())?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|error| error.to_string()));
    require!(rows.len() == 1, "Public Exact pair does not have one matching source identity");
    Ok(rows[0].clone())
}

#[cfg(not(test))]
#[derive(Clone)]
struct Incident0910Binding {
    event_id: i64,
    source_id: i64,
    ordinal: i64,
    timestamp: i64,
    tokens: i64,
    input_tokens: i64,
    cached_input_tokens: i64,
    output_tokens: i64,
    reasoning_output_tokens: i64,
    accounting_kind: i64,
    raw_generation: i64,
    raw_offset: Option<i64>,
    fingerprint: Option<Vec<u8>>,
    available: i64,
}

#[cfg(not(test))]
fn incident_0910_first_binding(connection: &Connection, source_id: i64) -> Result<Incident0910Binding, String> {
    require!(incident_0910_table_exists(connection, "usage_ledger_bindings")?,
        "Public schema13/14 fixture lacks persisted per-event ledger bindings");
    checked!(connection.query_row(
        "SELECT e.id,e.source_id,e.ordinal,e.timestamp,e.tokens,e.input_tokens,e.cached_input_tokens,e.output_tokens,e.reasoning_output_tokens,e.accounting_kind,b.raw_generation,b.raw_offset,b.fingerprint,b.available FROM event_rows e JOIN usage_ledger_bindings b ON b.event_id=e.id AND b.source_id=e.source_id WHERE e.source_id=?1 ORDER BY e.ordinal LIMIT 1",
        [source_id],
        |row| Ok(Incident0910Binding {
            event_id: row.get(0)?, source_id: row.get(1)?, ordinal: row.get(2)?,
            timestamp: row.get(3)?, tokens: row.get(4)?, input_tokens: row.get(5)?,
            cached_input_tokens: row.get(6)?, output_tokens: row.get(7)?,
            reasoning_output_tokens: row.get(8)?, accounting_kind: row.get(9)?,
            raw_generation: row.get(10)?, raw_offset: row.get(11)?,
            fingerprint: row.get(12)?, available: row.get(13)?,
        })
    ))
}

#[cfg(not(test))]
fn incident_0910_metadata(connection: &Connection, key: &str, value: &str) -> Result<(), String> {
    checked!(connection.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES(?1,?2)", rusqlite::params![key, value]));
    Ok(())
}

#[cfg(not(test))]
fn incident_0910_check_partial_canary(a: &Path) -> Result<(), String> {
    let spec = checked!(StoreSpec::new("fixture-partial", "fixture", "fixture/partial"));
    let store = checked!(checked!(Container::open_existing(a)).into_store_connection(&spec));
    let tokens: i64 = checked!(store.query_row("SELECT tokens FROM canary WHERE id=1", [], |row| row.get(0)));
    require!(tokens == 77, "The independent partial A canary was overwritten");
    Ok(())
}

#[cfg(not(test))]
fn stage_incident_0910_exact_transition(old_path: &Path, current_path: &Path, home: &Path) -> Result<Value, String> {
    let old = checked!(Connection::open(old_path));
    let current = checked!(Connection::open(current_path));
    let old_schema: String = checked!(old.query_row("SELECT value FROM metadata WHERE key='schema_version'", [], |row| row.get(0)));
    let current_schema: String = checked!(current.query_row("SELECT value FROM metadata WHERE key='schema_version'", [], |row| row.get(0)));
    require!(old_schema == "13" && current_schema == "14", "Incident requires the actual public schema13/14 pair");

    let old_source = incident_0910_source(&old, INCIDENT_0910_SESSION_ID)?;
    let current_source = incident_0910_source(&current, INCIDENT_0910_SESSION_ID)?;
    let raw_path = home.join("sessions").join(format!("rollout-{INCIDENT_0910_SESSION_ID}.jsonl"));
    require!(old_source.0 == current_source.0 && old_source.1 == current_source.1
        && old_source.2 == current_source.2
        && Path::new(&old_source.1).file_name() == raw_path.file_name(),
        "Schema13/14 pair does not identify the same raw source, path, and session");
    // The real public producer stores the fixture's original temporary path.
    // This isolated copy owns its own Home path, so rebind both copies to the
    // matching session file under this case root before the interrupted scan.
    checked!(old.execute("UPDATE sources SET path=?1 WHERE source_id=?2", rusqlite::params![raw_path.to_string_lossy(), old_source.0]));
    checked!(current.execute("UPDATE sources SET path=?1 WHERE source_id=?2", rusqlite::params![raw_path.to_string_lossy(), current_source.0]));
    require!(!old_source.3 && !current_source.3, "Synthetic fork transition must begin from a non-fork source");

    let old_chunks = incident_0910_source_chunks(&old, old_source.0)?;
    let current_chunks = incident_0910_source_chunks(&current, current_source.0)?;
    require!(!old_chunks.is_empty() && old_chunks == current_chunks, "Public schema13/14 source chunk prefixes differ");
    let old_facts = incident_0910_event_facts(&old)?;
    let current_facts = incident_0910_event_facts(&current)?;
    require!(old_facts == current_facts && old_facts.0 >= 2, "Public schema13/14 event rows differ before incident transitions");

    let old_binding = incident_0910_first_binding(&old, old_source.0)?;
    let current_binding = incident_0910_first_binding(&current, current_source.0)?;
    require!(old_binding.event_id == current_binding.event_id
        && old_binding.source_id == current_binding.source_id
        && old_binding.ordinal == current_binding.ordinal
        && old_binding.timestamp == current_binding.timestamp
        && old_binding.tokens == current_binding.tokens
        && old_binding.input_tokens == current_binding.input_tokens
        && old_binding.cached_input_tokens == current_binding.cached_input_tokens
        && old_binding.output_tokens == current_binding.output_tokens
        && old_binding.reasoning_output_tokens == current_binding.reasoning_output_tokens
        && old_binding.accounting_kind == current_binding.accounting_kind
        && old_binding.raw_offset == current_binding.raw_offset
        && old_binding.available == current_binding.available,
        "Public pair lacks one immutable, position-preserving per-event identity");
    let fingerprint = current_binding.fingerprint.clone().ok_or("Public schema14 event has no stored per-event fingerprint")?;
    let old_membership: i64 = checked!(old.query_row(
        "SELECT COUNT(*) FROM source_fingerprints WHERE source_id=?1 AND fingerprint=?2",
        rusqlite::params![old_source.0, &fingerprint], |row| row.get(0)));
    let current_membership: i64 = checked!(current.query_row(
        "SELECT COUNT(*) FROM source_fingerprints WHERE source_id=?1 AND fingerprint=?2",
        rusqlite::params![current_source.0, &fingerprint], |row| row.get(0)));
    require!(old_membership == 1 && current_membership == 1, "Known fingerprint is not retained in both same-source fingerprint sets");
    let semantic_matches: i64 = checked!(old.query_row(
        "SELECT COUNT(*) FROM event_rows WHERE source_id=?1 AND timestamp=?2 AND tokens=?3 AND input_tokens=?4 AND cached_input_tokens=?5 AND output_tokens=?6 AND reasoning_output_tokens=?7 AND accounting_kind=?8",
        rusqlite::params![old_source.0, old_binding.timestamp, old_binding.tokens, old_binding.input_tokens,
            old_binding.cached_input_tokens, old_binding.output_tokens, old_binding.reasoning_output_tokens,
            old_binding.accounting_kind], |row| row.get(0)));
    let current_semantic_matches: i64 = checked!(current.query_row(
        "SELECT COUNT(*) FROM event_rows WHERE source_id=?1 AND timestamp=?2 AND tokens=?3 AND input_tokens=?4 AND cached_input_tokens=?5 AND output_tokens=?6 AND reasoning_output_tokens=?7 AND accounting_kind=?8",
        rusqlite::params![current_source.0, current_binding.timestamp, current_binding.tokens, current_binding.input_tokens,
            current_binding.cached_input_tokens, current_binding.output_tokens, current_binding.reasoning_output_tokens,
            current_binding.accounting_kind], |row| row.get(0)));
    require!(semantic_matches == 1 && current_semantic_matches == 1, "Old/current event numeric identity is not unique within the source");
    let old_generation: i64 = checked!(old.query_row("SELECT raw_generation FROM usage_ledger_sources WHERE source_id=?1", [old_source.0], |row| row.get(0)));
    let current_generation: i64 = checked!(current.query_row("SELECT raw_generation FROM usage_ledger_sources WHERE source_id=?1", [current_source.0], |row| row.get(0)));
    require!(old_binding.raw_generation == old_generation && current_binding.raw_generation == current_generation,
        "Per-event binding generation does not match its source generation");
    let next_generation = old_generation
        .checked_add(1)
        .ok_or("Incident raw generation overflow")?
        .max(current_generation);

    incident_0910_metadata(&old, "parser_repair_verify_pending", "paginated-owned-turn-v6")?;
    incident_0910_metadata(&old, "fork_replay_boundary_revision", "paginated-owned-turn-v6")?;
    incident_0910_metadata(&current, "fork_replay_boundary_revision", "paginated-owned-turn-v6")?;
    checked!(current.execute("DELETE FROM metadata WHERE key='parser_repair_verify_pending'", []));
    for (key, old_value, new_value) in [
        ("state_size", "700", "701"),
        ("state_modified_ns", "1700000000000000000", "1700000000000000001"),
        ("storage_maintenance_last_checked_unix", "1700000000", "1700086400"),
        ("storage_maintenance_last_compacted_unix", "1700000000", "1700086400"),
    ] {
        incident_0910_metadata(&old, key, old_value)?;
        incident_0910_metadata(&current, key, new_value)?;
    }
    checked!(old.execute("UPDATE sources SET is_explicit_subagent_fork=1 WHERE source_id=?1", [old_source.0]));
    checked!(current.execute("UPDATE sources SET is_explicit_subagent_fork=0 WHERE source_id=?1", [current_source.0]));
    checked!(old.execute("UPDATE usage_ledger_bindings SET fingerprint=NULL WHERE event_id=?1 AND source_id=?2",
        rusqlite::params![old_binding.event_id, old_binding.source_id]));
    checked!(current.execute("UPDATE usage_ledger_sources SET raw_generation=?1 WHERE source_id=?2",
        rusqlite::params![next_generation, current_source.0]));
    checked!(current.execute("UPDATE usage_ledger_bindings SET raw_generation=?1 WHERE source_id=?2",
        rusqlite::params![next_generation, current_source.0]));
    checked!(current.execute("UPDATE usage_ledger_bindings SET fingerprint=?1 WHERE event_id=?2 AND source_id=?3",
        rusqlite::params![&fingerprint, current_binding.event_id, current_binding.source_id]));
    let unique_mapping: i64 = checked!(current.query_row(
        "SELECT COUNT(*) FROM usage_ledger_bindings WHERE source_id=?1 AND fingerprint=?2 AND available=1",
        rusqlite::params![current_source.0, &fingerprint], |row| row.get(0)));
    require!(unique_mapping == 1, "Current known fingerprint does not map to exactly one available event");
    require!(incident_0910_event_facts(&old)? == old_facts && incident_0910_event_facts(&current)? == current_facts,
        "Staging changed old published event rows");
    require!(incident_0910_source_chunks(&old, old_source.0)? == old_chunks
        && incident_0910_source_chunks(&current, current_source.0)? == current_chunks,
        "Staging changed persisted source chunk evidence");
    drop(old);
    drop(current);
    Ok(json!({
        "sessionId": INCIDENT_0910_SESSION_ID,
        "sourceId": old_source.0,
        "sourcePath": old_source.1,
        "chunkCount": old_chunks.len(),
        "eventCount": old_facts.0,
        "eventDigest": old_facts.1,
        "oldGeneration": old_generation,
        "currentGeneration": next_generation,
        "unknownOldFingerprint": true,
        "oldFingerprintMembership": old_membership,
        "uniqueCurrentFingerprintMapping": unique_mapping,
        "rawOffsetWasNull": old_binding.raw_offset.is_none(),
        "forkTransition": "1-to-0",
        "parserRepairPendingRemoved": true
    }))
}

#[cfg(not(test))]
fn prepare_incident_0910_probe(root: &Path, frozen: &Path) -> Result<Value, String> {
    let inputs13 = root.join("inputs13");
    let provenance: Value = checked!(serde_json::from_slice(&checked!(fs::read(inputs13.join("provenance.json")))));
    let pair_receipt: Value = checked!(serde_json::from_slice(&checked!(fs::read(inputs13.join("fixture-result.json")))));
    require!(provenance["release_sha"] == "ba4c59060c240af703e42d288c303a56cb0259e3"
        && provenance["synthetic"] == true && pair_receipt["verified"] == true
        && pair_receipt["release_sha"] == provenance["release_sha"]
        && pair_receipt["upgrade_release_sha"] == RELEASE_SHA,
        "Combined incident requires verified public v0.9.3/v0.9.7 schema13/14 inputs");
    let original13 = inputs13.join("exact/a.sqlite3");
    let upgraded14 = inputs13.join("exact/a-upgraded.sqlite3");
    require!(pair_receipt["artifacts"]["exact/a.sqlite3"]["sha256"] == sha(&original13)?, "Public schema13 evidence changed");
    require!(pair_receipt["artifacts"]["exact/a-upgraded.sqlite3"]["sha256"] == sha(&upgraded14)?, "Public schema14 evidence changed");

    let stores = paths(frozen)?;
    let (home, target) = &stores[0];
    let a = route::container_path()?;
    let marker = PathBuf::from(format!("{}.initialized", a.display()));
    let b = app_paths::multi_client_usage_database_path().ok_or("No isolated B")?;
    require!(!a.exists() && !marker.exists() && !b.exists(), "Combined incident requires fresh A, marker, and B");
    let prior_cache = app_paths::tauri_usage_cache_dir().ok_or("No guarded old cache")?;
    let old = prior_cache.join("exact-token-index").join(target.file_name().ok_or("No old Exact filename")?);
    let main = target.clone();
    for path in [&old, &main] {
        require!(!path.exists(), "Refusing an existing combined incident Exact source");
        checked!(fs::create_dir_all(path.parent().ok_or("No Exact parent")?));
    }
    checked!(fs::copy(&original13, &old));
    checked!(fs::copy(&upgraded14, &main));

    let candidate = PathBuf::from(format!("{}.schema11-candidate", main.display()));
    let rollback = PathBuf::from(format!("{}.schema11-rollback", main.display()));
    let manifest = PathBuf::from(format!("{}.schema11-migration.json", main.display()));
    checked!(fs::copy(frozen.join("exact/b.sqlite3"), &candidate));
    checked!(fs::copy(frozen.join("exact/a.sqlite3"), &rollback));
    let source_receipt = json!({
        "manifest_version": 1,
        "phase": "Retained",
        "source_path": main.to_string_lossy(),
        "candidate_path": candidate.to_string_lossy(),
        "rollback_path": rollback.to_string_lossy(),
        "source_receipt": {"schema_version":9,"revision":null,"dashboard_revision":null,
            "published_generation":1,"building_generation":null,
            "database":{"size":checked!(fs::metadata(&rollback)).len(),"modified_ns":"0"},"wal":null}
    });
    checked!(fs::write(&manifest, checked!(serde_json::to_vec(&source_receipt))));
    let retention = json!({
        "sourcePath": old.to_string_lossy(),
        "rollbackPath": format!("{}.schema11-rollback", old.display()),
        "manifestPath": format!("{}.schema11-migration.json", old.display()),
        "sourceSchema": 13,
        "targetSchema": 13,
        "status": "copied"
    });
    {
        let database = checked!(Connection::open(&main));
        checked!(database.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('release_upgrade_retention_v1',?1)", [retention.to_string()]));
    }
    let exact_transition = stage_incident_0910_exact_transition(&old, &main, home)?;

    let partial = root.join("partial-before-exact.sqlite");
    require!(!partial.exists(), "Refusing an existing partial A fixture");
    {
        let database = checked!(Connection::open(&partial));
        checked!(database.execute_batch("CREATE TABLE canary(id INTEGER PRIMARY KEY, tokens INTEGER NOT NULL); INSERT INTO canary VALUES(1,77);"));
    }
    drop(route::open_store_during_bootstrap("fixture-partial", "fixture", "fixture/partial", std::slice::from_ref(&partial))?);
    let exact_spec = route::exact_store_spec(target)?;
    checked!(checked!(Container::open_existing(&a)).register(&exact_spec));

    let quota = app_paths::quota_history_database_path().ok_or("No isolated quota path")?;
    require!(!quota.exists(), "Refusing an existing quota source in the incident root");
    checked!(fs::copy(frozen.join("support/quota-history.sqlite"), &quota));
    let last_compacted_before: String;
    {
        let database = checked!(Connection::open(&quota));
        checked!(database.execute("UPDATE quota_history_maintenance SET value='3' WHERE key='policy_version'", []));
        last_compacted_before = checked!(database.query_row(
            "SELECT value FROM quota_history_maintenance WHERE key='last_compacted_at'", [], |row| row.get(0)));
        checked!(database.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;"));
    }
    let quota_identity = route::source_identity("quota_history_legacy", &quota)?;
    let quota_logical = format!("legacy/quota-history/{quota_identity}");
    let quota_spec = checked!(StoreSpec::new("quota_history_legacy", &quota_identity, &quota_logical));
    let coordinator = crate::core::business_startup::process_coordinator();
    require!(coordinator.begin_initial(), "Combined incident preparation already claimed startup");
    drop(route::open_store_during_bootstrap("quota_history_legacy", &quota_identity, &quota_logical, std::slice::from_ref(&quota))?);

    let container = checked!(Container::open_existing(&a));
    let journal_key = format!("migration_pending_store_v1:{}", quota_spec.id);
    let journal_text: String = checked!(container.connection().query_row("SELECT value FROM tb_container_meta WHERE key=?1", [&journal_key], |row| row.get(0)));
    let journal: Value = checked!(serde_json::from_str(&journal_text));
    require!(journal["version"] == 2 && journal["bootstrap"] == true
        && journal["snapshots"].as_array().is_some_and(|items| items.len() == 1),
        "Initial quota import did not persist its bootstrap v2 snapshot journal");
    let snapshot = &journal["snapshots"][0];
    let quota_backup = PathBuf::from(snapshot["backup"].as_str().ok_or("Quota journal has no frozen backup")?);
    let original_snapshot_digest = snapshot["digest"].as_str().ok_or("Quota journal has no digest")?.to_owned();
    require!(Container::snapshot_digest_path(&quota_backup).map_err(|error| error.to_string())? == original_snapshot_digest,
        "Quota journal backup does not match its original source digest");
    let legacy_receipt = container.legacy_input_receipt(&quota).map_err(|error| error.to_string())?
        .ok_or("Quota import receipt was not persisted")?;
    require!(legacy_receipt.store_id == quota_spec.id && legacy_receipt.module == "quota_history_legacy"
        && legacy_receipt.source_digest == original_snapshot_digest
        && PathBuf::from(&legacy_receipt.backup_path) == quota_backup,
        "Quota import receipt does not bind the interrupted input and frozen backup");
    let public_v1_journal = json!({
        "sources": [quota.to_string_lossy()],
        "bootstrap": true,
        "replace_uncommitted": true
    });
    checked!(container.connection().execute(
        "UPDATE tb_container_meta SET value=?1 WHERE key=?2",
        rusqlite::params![public_v1_journal.to_string(), journal_key]
    ));
    let persisted_v1: String = checked!(container.connection().query_row(
        "SELECT value FROM tb_container_meta WHERE key=?1", [&journal_key], |row| row.get(0)
    ));
    let persisted_v1: Value = checked!(serde_json::from_str(&persisted_v1));
    require!(persisted_v1.get("version").is_none() && persisted_v1.get("snapshots").is_none()
        && persisted_v1["sources"].as_array().is_some_and(|items| items.len() == 1)
        && persisted_v1["sources"][0] == quota.to_string_lossy().as_ref()
        && persisted_v1["bootstrap"] == true && persisted_v1["replace_uncommitted"] == true,
        "Interrupted fixture did not retain the public v1 path-only journal shape");
    let imported_count: i64 = checked!(container.connection().query_row(
        &format!("SELECT COUNT(*) FROM {}quota_snapshots", quota_spec.prefix), [], |row| row.get(0)));
    let imported_id: i64 = checked!(container.connection().query_row(
        &format!("SELECT id FROM {}quota_snapshots", quota_spec.prefix), [], |row| row.get(0)));
    require!(imported_count == 1 && imported_id == 42, "Partial A did not retain the original quota row before interruption");
    drop(container);

    let advanced_at = last_compacted_before.parse::<f64>().map_err(|error| format!("Invalid quota maintenance timestamp: {error}"))? + 86_400.0;
    let appended_id: i64;
    {
        let database = checked!(Connection::open(&quota));
        let observed_at = time::OffsetDateTime::now_utc().unix_timestamp() as f64;
        checked!(database.execute("INSERT INTO quota_snapshots(created_at,account_key,status) VALUES(?1,'incident-0910-appended','ok')", [observed_at]));
        checked!(database.execute("UPDATE quota_history_maintenance SET value=?1 WHERE key='last_compacted_at'", [advanced_at.to_string()]));
        checked!(database.execute("UPDATE quota_history_maintenance SET value='3' WHERE key='policy_version'", []));
        appended_id = checked!(database.query_row("SELECT MAX(id) FROM quota_snapshots", [], |row| row.get(0)));
        checked!(database.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;"));
    }
    require!(appended_id > 12345, "Quota observation did not append after the released sequence");
    let changed_quota_digest = Container::snapshot_digest_path(&quota).map_err(|error| error.to_string())?;
    require!(changed_quota_digest != original_snapshot_digest, "Quota append and maintenance advance did not change the retry snapshot");

    let raw_path = home.join("sessions").join(format!("rollout-{INCIDENT_0910_SESSION_ID}.jsonl"));
    let old_raw_bytes = checked!(fs::read(&raw_path));
    let header: Value = checked!(serde_json::from_slice(old_raw_bytes.split(|byte| *byte == b'\n').next().ok_or("Session header is absent")?));
    require!(header["type"] == "session_meta" && header["payload"]["id"] == INCIDENT_0910_SESSION_ID
        && header["payload"]["history_mode"] == "paginated"
        && header["payload"]["forked_from_id"].as_str().unwrap_or("").is_empty(),
        "Incident raw header does not prove its matching paginated non-fork session");
    let header_timestamp = header["timestamp"].as_str().ok_or("Session header has no RFC3339 timestamp")?;
    time::OffsetDateTime::parse(header_timestamp, &time::format_description::well_known::Rfc3339)
        .map_err(|error| format!("Session header timestamp is not RFC3339: {error}"))?;
    let appended_timestamp = (time::OffsetDateTime::now_utc() + time::Duration::seconds(10))
        .format(&time::format_description::well_known::Rfc3339).map_err(|error| error.to_string())?;
    let usage = json!({"input_tokens":5,"output_tokens":2,"total_tokens":7});
    let line = json!({"timestamp":appended_timestamp,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":usage,"last_token_usage":usage}}}).to_string() + "\n";
    {
        use std::io::Write as _;
        let mut file = checked!(fs::OpenOptions::new().append(true).open(&raw_path));
        checked!(file.write_all(line.as_bytes()));
        checked!(file.sync_all());
    }
    let raw_after = checked!(fs::read(&raw_path));
    require!(raw_after.starts_with(&old_raw_bytes), "Synthetic usage append changed the stored raw source prefix");

    let body_scope = format!("{}\n{}", home.to_string_lossy(), home.to_string_lossy());
    let legacy_body = quota.with_file_name(format!("observed-speed-{}.json", fnv(&body_scope)));
    checked!(fs::copy(frozen.join("support/observed-speed-release097.json"), &legacy_body));
    require!(!b.exists(), "B was initialized before its first production use");
    let source_count: i64 = checked!(Connection::open(&quota).and_then(|database| database.query_row("SELECT COUNT(*) FROM quota_snapshots", [], |row| row.get(0))));
    require!(source_count == 2, "Quota source does not contain one appended observation");
    let marker = PathBuf::from(format!("{}.initialized", a.display()));
    require!(!marker.exists(), "Interrupted quota import published the ready marker");
    let interrupted = coordinator.finish(Err("simulated process interruption after committed quota import, before Exact activation".into()));
    require!(interrupted.phase == crate::core::business_startup::BusinessStartupPhase::Error
        && coordinator.ensure_ready().is_err() && !marker.exists(),
        "Interrupted import exposed startup readiness before Exact activation");

    let mut records = Vec::new();
    for path in [
        &original13, &upgraded14, &frozen.join("exact/a.sqlite3"), &frozen.join("exact/b.sqlite3"),
        &frozen.join("support/quota-history.sqlite"), &frozen.join("support/observed-speed-release097.json"),
        &old, &main, &candidate, &rollback, &manifest, &quota, &raw_path, &legacy_body, &quota_backup,
    ] {
        records.push(incident_0910_file_record(path)?);
    }
    let state = json!({
        "scenario": INCIDENT_0910_SCENARIO,
        "home": home.to_string_lossy(), "a": a.to_string_lossy(), "marker": marker.to_string_lossy(),
        "b": b.to_string_lossy(), "quota": quota.to_string_lossy(), "quotaIdentity": quota_identity,
        "quotaLogicalPath": quota_logical, "quotaStoreId": quota_spec.id,
        "quotaBackup": quota_backup.to_string_lossy(), "quotaBackupSha256": sha(&quota_backup)?,
        "quotaInitialSnapshotDigest": original_snapshot_digest, "quotaChangedSnapshotDigest": changed_quota_digest,
        "quotaExpectedLastCompactedAt": advanced_at.to_string(), "quotaAppendedId": appended_id,
        "rawPath": raw_path.to_string_lossy(), "legacyBody": legacy_body.to_string_lossy(),
        "oldExact": old.to_string_lossy(), "currentExact": main.to_string_lossy(),
        "exactTransition": exact_transition.clone(), "immutableFiles": records, "syntheticTransitionOnPublicPair": true
    });
    checked!(fs::write(incident_0910_state_path(root), checked!(serde_json::to_vec_pretty(&state))));
    Ok(json!({"status":"PASS","scenario":INCIDENT_0910_SCENARIO,"phase":"prepare","startupReady":false,
        "publicV1PathOnlyJournalRestored":true,"quotaReceiptAndFrozenBackupRetained":true,
        "quotaObservationAppended":true,"exactTransition":exact_transition,
        "rawPrefixPreserved":true,"frozenEvidenceRetained":true}))
}

#[cfg(not(test))]
fn incident_0910_check_quota(state: &Value) -> Result<(), String> {
    let quota = PathBuf::from(state["quota"].as_str().ok_or("Incident state has no quota source")?);
    let identity = state["quotaIdentity"].as_str().ok_or("Incident state has no quota identity")?;
    let logical = state["quotaLogicalPath"].as_str().ok_or("Incident state has no quota logical path")?;
    let active = route::open_store("quota_history_legacy", identity, logical, &[])?;
    let mut statement = checked!(active.prepare("SELECT id FROM quota_snapshots ORDER BY id"));
    let ids = checked!(statement.query_map([], |row| row.get(0))
        .map_err(|error| error.to_string())?
        .collect::<rusqlite::Result<Vec<i64>>>()
        .map_err(|error| error.to_string()));
    require!(ids == [42, state["quotaAppendedId"].as_i64().ok_or("Incident state has no appended quota id")?],
        "Retry lost, rewrote, or duplicated quota observations");
    let (policy, compacted): (String, String) = checked!(active.query_row(
        "SELECT (SELECT value FROM quota_history_maintenance WHERE key='policy_version'),(SELECT value FROM quota_history_maintenance WHERE key='last_compacted_at')",
        [], |row| Ok((row.get(0)?, row.get(1)?))));
    require!(policy == "3" && compacted == state["quotaExpectedLastCompactedAt"].as_str().ok_or("Incident state has no maintenance timestamp")?,
        "Retry failed to preserve policy3 maintenance metadata");
    let source_digest = Container::snapshot_digest_path(&quota).map_err(|error| error.to_string())?;
    let container = checked!(Container::open_existing(route::container_path()?));
    let receipt = container.legacy_input_receipt(&quota).map_err(|error| error.to_string())?
        .ok_or("Ready A has no quota source receipt")?;
    require!(receipt.source_digest == source_digest && !receipt.retired, "Ready quota receipt is stale or retired");
    require!(PathBuf::from(&receipt.backup_path).is_file(), "Ready quota receipt lost its frozen backup");
    Ok(())
}

#[cfg(not(test))]
fn incident_0910_check_exact(root: &Path, state: &Value, export_label: &str) -> Result<(), String> {
    use crate::core::usage::token_count_jsonl as token;
    let home = PathBuf::from(state["home"].as_str().ok_or("Incident state has no Home")?);
    let current = PathBuf::from(state["currentExact"].as_str().ok_or("Incident state has no current Exact")?);
    require!(token::dashboard_snapshot(&home)?.stats.total_tokens == 162,
        "Interrupted Exact recovery did not include the appended 7-token observation exactly once");
    require!(token::dashboard_snapshot(&home)?.stats.total_tokens == 162,
        "Repeated Exact refresh replayed the appended observation");
    require!(token::verify_legacy_migration_fixture(&home, &current)?,
        "Public schema13/14 Exact sources were not consumed by A");
    let spec = route::exact_store_spec(&current)?;
    let exported = root.join(format!("incident-0910-recovered-exact-{export_label}.sqlite3"));
    route::export_store_to_path(&spec.source_identity, "exact", &spec.logical_path, &exported)?;
    let database = read_only(&exported)?;
    let (count, total): (i64, i64) = checked!(database.query_row(
        "SELECT COUNT(*),COALESCE(SUM(tokens),0) FROM event_rows", [],
        |row| Ok((row.get(0)?, row.get(1)?))));
    let expected_count = state["exactTransition"]["eventCount"].as_i64().ok_or("Incident state has no original Exact event count")? + 1;
    require!(count == expected_count && total == 162,
        "Recovered Exact rows do not preserve all old events plus exactly one new observation");
    Ok(())
}

#[cfg(not(test))]
fn resume_incident_0910_probe(root: &Path, frozen: &Path, reopen: bool) -> Result<Value, String> {
    let state = incident_0910_read_state(root)?;
    let a = PathBuf::from(state["a"].as_str().ok_or("Incident state has no A")?);
    let marker = PathBuf::from(state["marker"].as_str().ok_or("Incident state has no ready marker")?);
    require!(a.starts_with(root) && marker.starts_with(root), "Incident A path escaped its isolated root");
    if reopen {
        require!(marker.is_file(), "Repeated startup began before the first complete migration");
        start()?;
        require!(crate::core::business_startup::process_coordinator().snapshot().phase
            == crate::core::business_startup::BusinessStartupPhase::Ready,
            "Repeated production startup did not reach ready");
    } else {
        require!(a.is_file() && !marker.exists(), "Resume did not start from an interrupted, unready A");
        let quota = PathBuf::from(state["quota"].as_str().ok_or("Incident state has no quota source")?);
        let quota_spec = checked!(StoreSpec::new(
            "quota_history_legacy",
            state["quotaIdentity"].as_str().ok_or("Incident state has no quota identity")?,
            state["quotaLogicalPath"].as_str().ok_or("Incident state has no quota logical path")?
        ));
        let container = checked!(Container::open_existing(&a));
        let journal: String = checked!(container.connection().query_row(
            "SELECT value FROM tb_container_meta WHERE key=?1",
            [format!("migration_pending_store_v1:{}", quota_spec.id)], |row| row.get(0)));
        let journal: Value = checked!(serde_json::from_str(&journal));
        require!(journal.get("version").map_or(true, |version| version.as_i64() == Some(1))
            && journal.get("snapshots").is_none()
            && journal["sources"].as_array().is_some_and(|items| items.len() == 1)
            && journal["sources"][0] == quota.to_string_lossy().as_ref()
            && journal["bootstrap"] == true && journal["replace_uncommitted"] == true,
            "Retry did not begin from the persisted public v1 path-only journal");
        require!(Container::snapshot_digest_path(&quota).map_err(|error| error.to_string())?
            == state["quotaChangedSnapshotDigest"].as_str().ok_or("Incident state has no changed quota digest")?,
            "Quota source changed after the interrupted fixture was frozen");
        let backup = PathBuf::from(state["quotaBackup"].as_str().ok_or("Incident state has no quota backup")?);
        require!(sha(&backup)? == state["quotaBackupSha256"].as_str().ok_or("Incident state has no quota backup hash")?,
            "Interrupted import backup was modified before retry");
        drop(container);
        incident_0910_check_partial_canary(&a)?;
        let coordinator = crate::core::business_startup::process_coordinator();
        require!(coordinator.ensure_ready().is_err(), "Interrupted process became ready before retry began");
        require!(coordinator.begin_initial(), "Combined incident resume already claimed startup");
        let result = route::bootstrap();
        let startup = coordinator.finish(result.clone());
        result?;
        require!(startup.phase == crate::core::business_startup::BusinessStartupPhase::Ready
            && coordinator.ensure_ready().is_ok() && marker.is_file(),
            "A became ready before the complete quota and Exact recovery finished");

        let resumed = checked!(Container::open_existing(&a));
        let v2_text: String = checked!(resumed.connection().query_row(
            "SELECT value FROM tb_container_meta WHERE key=?1",
            [format!("migration_pending_store_v1:{}", state["quotaStoreId"].as_str().ok_or("Incident state has no quota store id")?)],
            |row| row.get(0)
        ));
        let v2: Value = checked!(serde_json::from_str(&v2_text));
        require!(v2["version"] == 2 && v2["bootstrap"] == true
            && v2["snapshots"].as_array().is_some_and(|items| items.len() == 1)
            && v2["snapshots"][0]["digest"] == state["quotaChangedSnapshotDigest"],
            "Production retry did not upgrade the receipt-bound v1 journal to its current v2 snapshot");
        drop(resumed);

        let b = app_paths::multi_client_usage_database_path().ok_or("No isolated B")?;
        require!(!b.exists(), "B was unexpectedly opened before the combined incident resume");
        let home = PathBuf::from(state["home"].as_str().ok_or("Incident state has no Home")?);
        incident_0910_body_check(frozen, &home)?;
        require!(b.is_file(), "The first production Body import did not initialize B");
        let activity = crate::core::multi_client_usage::open_activity_module_connection()?;
        checked!(activity.execute("INSERT INTO activity_speed_samples(source_identity,id,display_mode,estimator_id,estimator_version,metric_kind,client,model,started_at,ended_at,output_rate,covered_seconds,weighted_output) VALUES('incident-0910','incident-0910-b-canary','model','fixture','1','output','codex','gpt-6.1-sol',1800000000,1800000010,12,10,120)", []));
        drop(activity);
        incident_0910_check_quota(&state)?;
        incident_0910_check_exact(root, &state, "resume-first")?;
        incident_0910_check_partial_canary(&a)?;
        route::bootstrap()?;
        incident_0910_check_exact(root, &state, "resume-repeat")?;
        incident_0910_check_quota(&state)?;
        incident_0910_check_files(root, &state)?;
        require!(sha(&backup)? == state["quotaBackupSha256"].as_str().ok_or("Incident state has no quota backup hash")?,
            "Successful retry discarded or rewrote the first frozen quota backup");
        return Ok(json!({"status":"PASS","scenario":INCIDENT_0910_SCENARIO,"phase":"resume",
            "startupReady":true,"legacyV1JournalUpgradedToV2":true,
            "quotaObservationsExactlyOnce":true,"exactTotalTokens":162,
            "partialACanaryPreserved":true,"bFirstInitialization":true,"frozenEvidenceRetained":true}));
    }

    require!(marker.is_file(), "Ready marker disappeared on repeated startup");
    incident_0910_check_partial_canary(&a)?;
    let b = app_paths::multi_client_usage_database_path().ok_or("No isolated B")?;
    require!(b.is_file(), "B was not initialized by the first completed startup");
    let activity = crate::core::multi_client_usage::open_activity_module_connection()?;
    let sentinel: i64 = checked!(activity.query_row(
        "SELECT COUNT(*) FROM activity_speed_samples WHERE id='incident-0910-b-canary'", [], |row| row.get(0)));
    require!(sentinel == 1, "Repeated startup erased or duplicated B's independent canary");
    drop(activity);
    let home = PathBuf::from(state["home"].as_str().ok_or("Incident state has no Home")?);
    incident_0910_body_check(frozen, &home)?;
    incident_0910_check_quota(&state)?;
    incident_0910_check_exact(root, &state, "reopen")?;
    incident_0910_check_files(root, &state)?;
    let backup = PathBuf::from(state["quotaBackup"].as_str().ok_or("Incident state has no quota backup")?);
    require!(sha(&backup)? == state["quotaBackupSha256"].as_str().ok_or("Incident state has no quota backup hash")?,
        "Repeated startup discarded or rewrote frozen quota evidence");
    Ok(json!({"status":"PASS","scenario":INCIDENT_0910_SCENARIO,"phase":"reopen",
        "startupReady":true,"quotaObservationsExactlyOnce":true,"exactTotalTokens":162,
        "partialACanaryPreserved":true,"bFirstInitializationRetained":true,"frozenEvidenceRetained":true}))
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
    fn actual_v097_pending_source_disappearance_recovers_verified_snapshot() {
        isolated(|root, old| {
            let source = root.join("old14.sqlite3");
            fs::copy(old.join("exact/a.sqlite3"), &source).unwrap();
            import_exact(&source).unwrap();
            // A changed but covering source is accepted while the batch is
            // unfinished, and its previous snapshot remains retained.
            let db = Connection::open(&source).unwrap();
            db.execute("INSERT INTO metadata(key,value) VALUES('release097_late_source','observed')", []).unwrap();
            drop(db);
            import_exact(&source).unwrap();
            let saved = root.join("parked.sqlite3");
            fs::rename(&source, &saved).unwrap();
            // Discovery cannot see the physical original now. The v2 batch
            // must resume using only its explicitly bound SQLite snapshot.
            route::bootstrap().unwrap();
            assert!(PathBuf::from(format!("{}.initialized", route::container_path().unwrap().display())).exists());
            assert!(!source.exists(), "Recovery must never recreate an old writer");
            verify_export(&saved, &exact_spec(&source).unwrap(), &root.join("recovered.sqlite3")).unwrap();
            route::bootstrap().unwrap();
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
