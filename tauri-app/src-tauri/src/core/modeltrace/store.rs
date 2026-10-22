use super::Run;
use rusqlite::{params, Connection};
use std::path::Path;

fn open(path: &Path) -> Result<Connection, String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let db = Connection::open(path).map_err(|e| e.to_string())?;
    db.busy_timeout(std::time::Duration::from_secs(2))
        .map_err(|e| e.to_string())?;
    db.execute_batch("CREATE TABLE IF NOT EXISTS modeltrace_runs(scope TEXT NOT NULL,id TEXT PRIMARY KEY,started_at INTEGER NOT NULL,payload TEXT NOT NULL); CREATE INDEX IF NOT EXISTS modeltrace_scope_time ON modeltrace_runs(scope,started_at DESC);").map_err(|e| e.to_string())?;
    Ok(db)
}
pub fn save(path: &Path, scope: &str, run: &Run) -> Result<(), String> {
    open(path)?.execute("INSERT INTO modeltrace_runs(scope,id,started_at,payload) VALUES(?1,?2,?3,?4) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload WHERE scope=excluded.scope",params![scope,run.id,run.started_at,serde_json::to_string(run).map_err(|e| e.to_string())?]).map_err(|e| e.to_string())?;
    Ok(())
}
pub fn history(path: &Path, scope: &str) -> Result<Vec<Run>, String> {
    let db = open(path)?;
    let mut statement = db.prepare("SELECT payload FROM modeltrace_runs WHERE scope=?1 ORDER BY started_at DESC,id DESC LIMIT 100").map_err(|e| e.to_string())?;
    let rows = statement
        .query_map([scope], |row| row.get::<_, String>(0))
        .map_err(|e| e.to_string())?;
    rows.map(|r| serde_json::from_str(&r.map_err(|e| e.to_string())?).map_err(|e| e.to_string()))
        .collect()
}
pub fn auto_settings(path: &Path) -> Result<super::AutoSettings, String> {
    use rusqlite::OptionalExtension;
    let db = open(path)?;
    db.execute_batch("CREATE TABLE IF NOT EXISTS modeltrace_settings(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT NOT NULL)").map_err(|e|e.to_string())?;
    let value: Option<String> = db
        .query_row(
            "SELECT payload FROM modeltrace_settings WHERE id=1",
            [],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    value
        .map(|s| serde_json::from_str(&s).map_err(|e| e.to_string()))
        .unwrap_or_else(|| Ok(super::AutoSettings::default()))
}
pub fn save_auto_settings(path: &Path, settings: &super::AutoSettings) -> Result<(), String> {
    let _ = auto_settings(path)?;
    open(path)?.execute("INSERT INTO modeltrace_settings(id,payload) VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",[serde_json::to_string(settings).map_err(|e|e.to_string())?]).map_err(|e|e.to_string())?;
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn updates_are_idempotent_and_history_is_account_scoped() {
        let temp =
            std::env::temp_dir().join(format!("tokenbar-modeltrace-{}", uuid::Uuid::new_v4()));
        let path = temp.join("history.sqlite");
        let mut run = Run {
            id: "one".into(),
            model: super::super::DEFAULT_MODEL.into(),
            effort: "low".into(),
            started_at: 1,
            completed_at: None,
            status: "running".into(),
            attempts: 0,
            valid_samples: 0,
            message: None,
            attribution: None,
            samples: vec![],
        };
        save(&path, "a", &run).unwrap();
        run.status = "cancelled".into();
        save(&path, "a", &run).unwrap();
        assert_eq!(history(&path, "a").unwrap().len(), 1);
        assert_eq!(history(&path, "a").unwrap()[0].status, "cancelled");
        assert!(history(&path, "b").unwrap().is_empty());
        std::fs::remove_dir_all(temp).unwrap();
    }
}
