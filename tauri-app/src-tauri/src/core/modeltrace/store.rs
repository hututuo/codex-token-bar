use super::{History, Plan, Run};
use crate::commands::dashboard::CodexHomeSourceToken;
use crate::core::app_paths;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct StoredPlan {
    pub plan: Plan,
    #[serde(default)]
    pub round_started_at: Option<i64>,
    pub scope_key: String,
    pub account_key: String,
    pub source_token: CodexHomeSourceToken,
    pub home: PathBuf,
}

pub fn root() -> Result<PathBuf, String> {
    app_paths::modeltrace_data_dir().ok_or_else(|| "无法定位模型检测数据目录".into())
}
fn open() -> Result<Connection, String> {
    let root = root()?;
    std::fs::create_dir_all(&root).map_err(|e| e.to_string())?;
    let db = Connection::open(root.join("modeltrace.sqlite")).map_err(|e| e.to_string())?;
    db.busy_timeout(std::time::Duration::from_secs(3))
        .map_err(|e| e.to_string())?;
    ensure_schema(&db)?;
    Ok(db)
}
fn ensure_schema(db: &Connection) -> Result<(), String> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS plans (id TEXT PRIMARY KEY, scope_key TEXT NOT NULL, started_at INTEGER NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, scope_key TEXT NOT NULL, model TEXT NOT NULL, started_at INTEGER NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS cancellations (plan_id TEXT PRIMARY KEY);
        CREATE INDEX IF NOT EXISTS runs_scope_date ON runs(scope_key, started_at);
        CREATE INDEX IF NOT EXISTS plans_scope_date ON plans(scope_key, started_at);").map_err(|e| e.to_string())
}
fn write_plan(db: &Connection, value: &StoredPlan) -> Result<(), String> {
    db.execute("INSERT INTO plans VALUES (?1,?2,?3,?4) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
        params![value.plan.id, value.scope_key, value.plan.started_at, serde_json::to_string(value).map_err(|e|e.to_string())?]).map_err(|e|e.to_string())?;
    Ok(())
}
pub fn save_plan(value: &StoredPlan) -> Result<(), String> {
    write_plan(&open()?, value)
}
pub fn request_cancel(plan_id: &str) -> Result<(), String> {
    record_cancel(&open()?, plan_id)
}
fn record_cancel(db: &Connection, plan_id: &str) -> Result<(), String> {
    db.execute("INSERT OR IGNORE INTO cancellations VALUES (?1)", [plan_id])
        .map_err(|e| e.to_string())?;
    Ok(())
}
pub fn cancel_requested(plan_id: &str) -> Result<bool, String> {
    open()?
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM cancellations WHERE plan_id=?1)",
            [plan_id],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())
}
pub fn finish_run(plan: &StoredPlan, run: &Run) -> Result<(), String> {
    let mut db = open()?;
    finish_run_in(&mut db, plan, run)
}
fn finish_run_in(db: &mut Connection, plan: &StoredPlan, run: &Run) -> Result<(), String> {
    let tx = db.transaction().map_err(|e| e.to_string())?;
    tx.execute(
        "INSERT INTO runs VALUES (?1,?2,?3,?4,?5) ON CONFLICT(id) DO NOTHING",
        params![
            run.id,
            plan.scope_key,
            run.model,
            run.started_at,
            serde_json::to_string(run).map_err(|e| e.to_string())?
        ],
    )
    .map_err(|e| e.to_string())?;
    write_plan(&tx, plan)?;
    tx.commit().map_err(|e| e.to_string())
}
pub fn last_plan(scope: &str) -> Result<Option<StoredPlan>, String> {
    let text: Option<String> = open()?.query_row("SELECT payload FROM plans WHERE scope_key=?1 ORDER BY started_at DESC, id DESC LIMIT 1", [scope], |row|row.get(0)).optional().map_err(|e|e.to_string())?;
    text.map(|s| serde_json::from_str(&s).map_err(|e| e.to_string()))
        .transpose()
}
pub fn history(
    scope: &str,
    since: i64,
    until: i64,
    model: Option<&str>,
    limit: usize,
    offset: usize,
) -> Result<History, String> {
    let db = open()?;
    read_history(&db, scope, since, until, model, limit, offset)
}
fn read_history(
    db: &Connection,
    scope: &str,
    since: i64,
    until: i64,
    model: Option<&str>,
    limit: usize,
    offset: usize,
) -> Result<History, String> {
    let mut stmt = db.prepare("SELECT payload FROM runs WHERE scope_key=?1 AND started_at>=?2 AND started_at<?3 AND (?4 IS NULL OR model=?4) ORDER BY started_at DESC, id DESC LIMIT ?5 OFFSET ?6").map_err(|e|e.to_string())?;
    let rows = stmt
        .query_map(
            params![scope, since, until, model, limit + 1, offset],
            |row| row.get::<_, String>(0),
        )
        .map_err(|e| e.to_string())?;
    let mut runs = Vec::new();
    for row in rows {
        runs.push(
            serde_json::from_str(&row.map_err(|e| e.to_string())?).map_err(|e| e.to_string())?,
        );
    }
    let has_more = runs.len() > limit;
    runs.truncate(limit);
    Ok(History {
        scope_key: scope.into(),
        runs,
        has_more,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn duplicate_run_is_idempotent_and_scope_is_separate() {
        let mut db = Connection::open_in_memory().unwrap();
        ensure_schema(&db).unwrap();
        let mut stored = StoredPlan {
            round_started_at: None,
            plan: Plan {
                id: "plan-a".into(),
                model: "gpt-5.6-sol".into(),
                started_at: 100,
                status: "waiting".into(),
                total_rounds: 3,
                completed_rounds: 1,
                current_attempt: 0,
                valid_samples: 0,
                next_run_at: Some(3700),
                error: None,
            },
            scope_key: "account-a".into(),
            account_key: "a".into(),
            source_token: CodexHomeSourceToken {
                canonical_home_key: "home".into(),
                physical_home_key: "physical".into(),
                transition_generation: 0,
            },
            home: PathBuf::from("home"),
        };
        let mut run = Run {
            id: "run-a".into(),
            plan_id: "plan-a".into(),
            model: "gpt-5.6-sol".into(),
            started_at: 100,
            completed_at: 101,
            status: "sampling_failed".into(),
            attempts: 6,
            valid_samples: 2,
            message: None,
            attribution: None,
        };
        finish_run_in(&mut db, &stored, &run).unwrap();
        finish_run_in(&mut db, &stored, &run).unwrap();
        record_cancel(&db, "plan-a").unwrap();
        // A racing progress write cannot erase a durable cancellation.
        write_plan(&db, &stored).unwrap();
        assert_eq!(
            db.query_row(
                "SELECT COUNT(*) FROM cancellations WHERE plan_id='plan-a'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            1
        );
        stored.scope_key = "account-b".into();
        stored.plan.id = "plan-b".into();
        run.id = "run-b".into();
        finish_run_in(&mut db, &stored, &run).unwrap();
        let history = read_history(&db, "account-a", 100, 102, None, 1, 0).unwrap();
        assert_eq!(history.runs.len(), 1);
        assert_eq!(history.runs[0].id, "run-a");
        assert!(!history.has_more);
        assert!(read_history(&db, "account-a", 0, 100, None, 10, 0)
            .unwrap()
            .runs
            .is_empty());
        assert!(
            read_history(&db, "account-a", 0, 102, Some("gpt-6-astra"), 10, 0)
                .unwrap()
                .runs
                .is_empty()
        );
        assert!(read_history(&db, "account-a", 0, 102, None, 10, 1)
            .unwrap()
            .runs
            .is_empty());
    }
}
