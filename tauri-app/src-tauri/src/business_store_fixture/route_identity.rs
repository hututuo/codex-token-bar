//! Separate-process, non-test exercise of the active A physical identity fence.
//! Only the validated disposable fixture root is used; both file images survive.

use super::{digest, validate_root, Paths};
use crate::core::{business_startup, business_store_container::Container,
    business_store_route as route};
use rusqlite::Connection;
use serde_json::{json, Value};
use std::{fs, path::Path, time::Duration};

const MODULE: &str = "fixture_identity";
const IDENTITY: &str = "route-identity-control";
const LOGICAL: &str = "fixture/physical-identity";

fn required(ok: bool, message: &str) -> Result<(), String> {
    if ok { Ok(()) } else { Err(message.into()) }
}

fn read_canaries(exact: &Path) -> Result<(), String> {
    let generic = route::open_registered_store_read_only(
        MODULE, IDENTITY, LOGICAL, Duration::from_secs(1))?
        .ok_or("generic identity canary namespace missing")?;
    let value: i64 = generic.query_row("SELECT value FROM observations", [], |row| row.get(0))
        .map_err(|error| error.to_string())?;
    required(value == 123, "generic identity canary changed")?;
    let exact_reader = route::open_exact_registered_read_only(exact, Duration::from_secs(1))?
        .ok_or("Exact identity canary namespace missing")?;
    let value: i64 = exact_reader.query_row("SELECT value FROM observations", [], |row| row.get(0))
        .map_err(|error| error.to_string())?;
    required(value == 175, "Exact identity canary changed")?;
    route::validate_exact_stage_container(&route::container_path()?)
}

pub fn run(input: &Path) -> Result<Value, String> {
    required(!cfg!(test), "route identity fixture requires the production configuration")?;
    let root = validate_root(input)?;
    let paths = Paths::resolve(&root)?;
    required(!paths.a.exists() && !paths.marker.exists(), "route identity fixture refuses existing A")?;
    let coordinator = business_startup::process_coordinator();
    required(coordinator.begin_initial(), "route identity startup already claimed")?;
    let started = route::bootstrap();
    coordinator.finish(started.clone());
    started?;

    {
        let writer = route::open_store(MODULE, IDENTITY, LOGICAL, &[])?;
        writer.execute_batch("CREATE TABLE observations(value INTEGER NOT NULL); INSERT INTO observations VALUES(123);")
            .map_err(|error| error.to_string())?;
    }
    let exact = paths.exact_root.join("physical-identity.sqlite3");
    {
        let writer = route::open_exact_store(&exact, &[])?;
        writer.execute_batch("CREATE TABLE observations(value INTEGER NOT NULL); INSERT INTO observations VALUES(175);")
            .map_err(|error| error.to_string())?;
    }
    read_canaries(&exact)?;
    // All SQLite handles are dropped before physical replacement, including on
    // Windows. Make the copied valid image self-contained, with no live WAL.
    {
        let db = Connection::open(&paths.a).map_err(|error| error.to_string())?;
        db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;")
            .map_err(|error| error.to_string())?;
    }
    for suffix in ["-wal", "-shm", "-journal"] {
        let sidecar = std::path::PathBuf::from(format!("{}{suffix}", paths.a.display()));
        required(!sidecar.exists(), "identity fixture still has a live SQLite sidecar")?;
    }
    let before = digest(&paths.a)?;
    let marker = digest(&paths.marker)?;
    let replacement = root.join("replacement-valid-a.sqlite");
    let original = root.join("retained-original-a.sqlite");
    let rejected = root.join("retained-rejected-a.sqlite");
    for path in [&replacement, &original, &rejected] {
        required(!path.exists(), "identity fixture refuses an existing retained image")?;
    }
    fs::copy(&paths.a, &replacement).map_err(|error| error.to_string())?;
    required(digest(&replacement)? == before, "replacement is not the exact valid A image")?;
    {
        let copied = Container::open_read_only_existing(&replacement, Duration::from_secs(1))
            .map_err(|error| error.to_string())?;
        copied.validate_catalog().map_err(|error| error.to_string())?;
        let integrity: String = copied.connection().query_row("PRAGMA quick_check", [], |row| row.get(0))
            .map_err(|error| error.to_string())?;
        required(integrity == "ok", "replacement A is not a valid SQLite container")?;
    }
    fs::rename(&paths.a, &original).map_err(|error| error.to_string())?;
    if let Err(error) = fs::rename(&replacement, &paths.a) {
        fs::rename(&original, &paths.a).map_err(|restore| format!("replacement failed: {error}; restore: {restore}"))?;
        return Err(error.to_string());
    }
    // Exact copies cannot share an inode/file ID while both files exist. No
    // malformed marker/schema is involved; the cached physical owner is stale.
    let results = [
        ("generic-writer", route::open_store(MODULE, IDENTITY, LOGICAL, &[]).map(|_| ())),
        ("generic-reader", route::open_registered_store_read_only(MODULE, IDENTITY, LOGICAL, Duration::from_secs(1)).map(|_| ())),
        ("exact-writer", route::open_exact_store(&exact, &[]).map(|_| ())),
        ("exact-reader", route::open_exact_registered_read_only(&exact, Duration::from_secs(1)).map(|_| ())),
        ("stage-admission", route::validate_exact_stage_container(&paths.a)),
        ("published-read-admission", route::admit_published_reads()),
    ];
    let preserved = digest(&paths.a)? == before && digest(&original)? == before
        && digest(&paths.marker)? == marker;
    // Restore without deleting either image, even when the deliberately broken
    // identity implementation accepts an operation in the cloud negative run.
    fs::rename(&paths.a, &rejected).map_err(|error| error.to_string())?;
    fs::rename(&original, &paths.a).map_err(|error| error.to_string())?;
    required(preserved, "route identity checks changed the valid images or marker")?;
    read_canaries(&exact)?;
    let mut checks = Vec::new();
    for (name, result) in results {
        let error = result.err().ok_or_else(|| format!("route identity fence accepted replaced A: {name}"))?;
        required(error.contains("容器文件") && (error.contains("替换") || error.contains("变化")),
            "route identity fixture rejected for a different reason")?;
        checks.push(json!({"name": name, "rejected": true, "error": error}));
    }
    Ok(json!({"status":"PASS", "cfgTest":false, "replacementCatalogValid":true,
        "replacementBytesIdentical":true, "markerUnchanged":true,
        "originalAndReplacementPreserved":true, "restoredReads":[123,175],
        "originalSHA256":before, "retainedReplacement":rejected,
        "fixtureRoot":root, "checks":checks}))
}
