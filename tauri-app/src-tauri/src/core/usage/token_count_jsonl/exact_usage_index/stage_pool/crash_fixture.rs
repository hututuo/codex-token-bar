//! Offline fixture only. Real A/pool transactions are interrupted by process
//! exit; no test SQL implementation replaces the production storage bridge.
use super::*;
use serde_json::json;

pub(super) const PHASES: [&str; 8] = [
    "initialize-before-commit",
    "chunk-committed",
    "seal-before-commit",
    "seal-committed",
    "publication-before-commit",
    "publication-committed",
    "cleanup-before-commit",
    "cleanup-committed",
];
const MARKER: &[u8] = b"tokenbar-pool-crash-fixture-v1\n";

pub(super) fn process_fault(point: &str, container: &Path) {
    static CONFIG: OnceLock<Option<(String, PathBuf)>> = OnceLock::new();
    let Some((wanted, root)) = CONFIG.get_or_init(|| {
        Some((
            std::env::var("TOKENBAR_POOL_CRASH_POINT").ok()?,
            std::fs::canonicalize(std::env::var_os("TOKENBAR_POOL_CRASH_ROOT")?).ok()?,
        ))
    }) else {
        return;
    };
    if wanted != point || !PHASES.contains(&point) {
        return;
    }
    if root
        .file_name()
        .and_then(|s| s.to_str())
        .is_none_or(|s| !s.starts_with("pool-crash-"))
    {
        return;
    }
    if !container.starts_with(root) {
        return;
    }
    let marker = root.join(".tokenbar-pool-crash-fixture");
    if std::fs::symlink_metadata(&marker).is_ok_and(|m| m.is_file() && !m.file_type().is_symlink())
        && std::fs::read(marker).is_ok_and(|bytes| bytes == MARKER)
    {
        std::process::exit(86);
    }
}

fn publish(
    pool: &Pool,
    job: &Job,
    writer: &mut crate::core::business_store_connection::StoreConnection,
    point: Option<&str>,
) -> Result<()> {
    let seal = pool.seal(job)?.ok_or("fault fixture job has no seal")?;
    let tx = writer.transaction().map_err(|e| e.to_string())?;
    tx.mark_exact_stage_pending(&job.owner, &job.id, &seal.digest, 2)?;
    tx.execute(
        "UPDATE metadata SET value='134' WHERE key='fixture_tokens'",
        [],
    )
    .map_err(|e| e.to_string())?;
    tx.execute(
        "UPDATE metadata SET value='2' WHERE key='published_generation'",
        [],
    )
    .map_err(|e| e.to_string())?;
    tx.consume_exact_stage_generation(2)?;
    if point == Some("publication-before-commit") {
        std::process::exit(86);
    }
    tx.commit().map_err(|e| e.to_string())
}

pub(super) fn run(root: &Path, point: &str, resume: bool) -> Result<serde_json::Value> {
    if !PHASES.contains(&point)
        || std::fs::read(root.join(".tokenbar-pool-crash-fixture")).map_err(|e| e.to_string())?
            != MARKER
    {
        return Err("fault fixture refused an unknown or unowned operation".into());
    }
    let path = crate::core::business_store_route::container_path()?;
    if !path.starts_with(root) {
        return Err("fault fixture A escaped its disposable root".into());
    }
    let target = StoreSpec::new(
        "exact",
        "process-fault-fixture",
        "exact/testing/process-faults",
    )
    .map_err(|e| e.to_string())?;
    let container = Container::open_existing(&path).map_err(|e| e.to_string())?;
    if !resume {
        container.register(&target).map_err(|e| e.to_string())?;
    } else if !container
        .is_registered(&target)
        .map_err(|e| e.to_string())?
    {
        return Err("crash discarded the already-published owner".into());
    }
    let mut writer = container
        .into_store_connection(&target)
        .map_err(|e| e.to_string())?;
    if !resume {
        writer.execute_batch("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL); INSERT INTO metadata VALUES('published_generation','1'),('fixture_tokens','123')").map_err(|e|e.to_string())?;
    }
    let pool = Pool::current()?;
    let source = root.join("source.jsonl").to_string_lossy().into_owned();
    if !resume {
        let job = pool.job(&target, &source, b"process-crash")?;
        let work = seed_fixture_stage(&source)?;
        pool.persist(&job, &work)?;
        if point == "seal-committed" {
            std::process::exit(86);
        }
        publish(&pool, &job, &mut writer, Some(point))?;
        if point == "publication-committed" {
            std::process::exit(86);
        }
        pool.reclaim(&job)?;
        if point == "cleanup-committed" {
            std::process::exit(86);
        }
        return Err(format!("crash point was not reached: {point}"));
    }
    let paths = pool.with(|c| {
        let mut query = c
            .connection()
            .prepare(&format!("SELECT logical_path FROM {}", pool.table("jobs")))
            .map_err(|e| e.to_string())?;
        let result = query
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(|e| e.to_string())?
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;
        Ok(result)
    })?;
    if paths.len() > 1 {
        return Err("restart created duplicate jobs".into());
    }
    let job = if let Some(path) = paths.first() {
        pool.lookup(Path::new(path))?
            .ok_or("persisted crash job identity missing")?
    } else {
        pool.job(&target, &source, b"process-crash")?
    };
    let initially_committed = matches!(
        point,
        "publication-committed" | "cleanup-before-commit" | "cleanup-committed"
    );
    let tokens: String = writer
        .query_row(
            "SELECT value FROM metadata WHERE key='fixture_tokens'",
            [],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())?;
    let receipts = pool.with(|c| {
        c.connection()
            .query_row(
                &format!(
                    "SELECT COUNT(*) FROM {}",
                    pool.table("publication_receipts")
                ),
                [],
                |r| r.get::<_, i64>(0),
            )
            .map_err(|e| e.to_string())
    })?;
    let reclaimed = pool.with(|c| {
        c.connection()
            .query_row(
                &format!(
                    "SELECT EXISTS(SELECT 1 FROM {} WHERE job_id=?1 AND state='reclaimed')",
                    pool.table("jobs")
                ),
                [&job.id],
                |r| r.get::<_, bool>(0),
            )
            .map_err(|e| e.to_string())
    })?;
    let already_recovered = reclaimed && tokens == "134" && receipts == 1;
    let committed = initially_committed || already_recovered;
    if tokens != if committed { "134" } else { "123" } || receipts != i64::from(committed) {
        return Err("facts and receipts crossed the atomic publication boundary".into());
    }
    if !committed {
        if pool.seal(&job)?.is_none() {
            if pool.restore(&job).is_ok() {
                return Err("unsealed crash payload became readable facts".into());
            }
            pool.persist(&job, &seed_fixture_stage(&source)?)?;
        }
        let restored = pool.restore(&job)?;
        if restored
            .query_row("SELECT tokens FROM events", [], |r| r.get::<_, i64>(0))
            .map_err(|e| e.to_string())?
            != 11
        {
            return Err("crash retry changed typed usage".into());
        }
        publish(&pool, &job, &mut writer, None)?;
    }
    pool.reclaim(&job)?;
    pool.reclaim(&job)?;
    if pool.restore(&job).is_ok() {
        return Err("reclaimed payload remained reusable".into());
    }
    let final_tokens: String = writer
        .query_row(
            "SELECT value FROM metadata WHERE key='fixture_tokens'",
            [],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())?;
    let receipts = pool.with(|c| {
        c.connection()
            .query_row(
                &format!(
                    "SELECT COUNT(*) FROM {}",
                    pool.table("publication_receipts")
                ),
                [],
                |r| r.get::<_, i64>(0),
            )
            .map_err(|e| e.to_string())
    })?;
    if final_tokens != "134" || receipts != 1 {
        return Err("crash recovery lost or duplicated published usage".into());
    }
    Ok(
        json!({"status":"PASS","phase":point,"oldTokens":123,"publishedTokens":134,"publicationReceipts":1,"reclaimIdempotent":true,"alreadyRecovered":already_recovered}),
    )
}
