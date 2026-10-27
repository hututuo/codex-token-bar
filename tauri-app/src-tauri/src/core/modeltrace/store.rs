use super::Run;
use rusqlite::{params, OptionalExtension};
#[cfg(test)]
use rusqlite::Connection;
#[cfg(not(test))]
use crate::core::business_store_connection::StoreConnection as Connection;
use std::path::Path;

fn open_active(path: &Path, source_identity: &str) -> Result<Connection, String> {
    #[cfg(test)]
    let db = {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let _ = source_identity;
        Connection::open(path).map_err(|e| e.to_string())?
    };
    #[cfg(not(test))]
    let db = {
        let logical_path = format!("modeltrace/home/{source_identity}");
        crate::core::business_store_route::open_store(
            "modeltrace",
            source_identity,
            &logical_path,
            &[],
        )?
    };
    db.busy_timeout(std::time::Duration::from_secs(2))
        .map_err(|e| e.to_string())?;
    db.execute_batch(
        "CREATE TABLE IF NOT EXISTS modeltrace_runs(scope TEXT NOT NULL,id TEXT PRIMARY KEY,started_at INTEGER NOT NULL,payload TEXT NOT NULL); CREATE INDEX IF NOT EXISTS modeltrace_scope_time ON modeltrace_runs(scope,started_at DESC); CREATE TABLE IF NOT EXISTS modeltrace_settings(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT NOT NULL);",
    )
    .map_err(|e| e.to_string())?;
    Ok(db)
}

fn open_legacy(path: &Path) -> Result<Option<Connection>, String> {
    #[cfg(test)]
    {
        if !path.is_file() {
            return Ok(None);
        }
        Ok(Some(Connection::open(path).map_err(|error| error.to_string())?))
    }
    #[cfg(not(test))]
    {
        let source_identity = crate::core::business_store_route::source_identity(
            "modeltrace_legacy",
            path,
        )?;
        let logical_path = format!("legacy/modeltrace/{source_identity}");
        if path.is_file() {
            crate::core::business_store_route::open_store(
                "modeltrace_legacy",
                &source_identity,
                &logical_path,
                &[path.to_path_buf()],
            )
            .map(Some)
        } else {
            crate::core::business_store_route::open_registered_store(
                "modeltrace_legacy",
                &source_identity,
                &logical_path,
            )
        }
    }
}

pub fn save(
    path: &Path,
    source_identity: &str,
    scope: &str,
    run: &Run,
) -> Result<(), String> {
    open_active(path, source_identity)?
        .execute(
            "INSERT INTO modeltrace_runs(scope,id,started_at,payload) VALUES(?1,?2,?3,?4) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload WHERE scope=excluded.scope",
            params![scope, run.id, run.started_at, serde_json::to_string(run).map_err(|e| e.to_string())?],
        )
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn history(path: &Path, source_identity: &str, scope: &str) -> Result<Vec<Run>, String> {
    let active = open_active(path, source_identity)?;
    let mut runs_by_id = read_history(&active, scope)?
        .into_iter()
        .map(|run| (run.id.clone(), run))
        .collect::<std::collections::HashMap<_, _>>();
    if let Some(legacy) = open_legacy(path)? {
        for run in read_history(&legacy, scope)? {
            // The active per-home namespace wins if the same run was later
            // resumed or marked interrupted after importing legacy history.
            runs_by_id.entry(run.id.clone()).or_insert(run);
        }
    }
    let mut runs = runs_by_id.into_values().collect::<Vec<_>>();
    runs.sort_by(|left, right| {
        right
            .started_at
            .cmp(&left.started_at)
            .then_with(|| right.id.cmp(&left.id))
    });
    runs.truncate(100);
    Ok(runs)
}

fn read_history(db: &Connection, scope: &str) -> Result<Vec<Run>, String> {
    let mut statement = db
        .prepare("SELECT payload FROM modeltrace_runs WHERE scope=?1 ORDER BY started_at DESC,id DESC LIMIT 100")
        .map_err(|e| e.to_string())?;
    let rows = statement
        .query_map([scope], |row| row.get::<_, String>(0))
        .map_err(|e| e.to_string())?;
    rows.map(|row| serde_json::from_str(&row.map_err(|e| e.to_string())?).map_err(|e| e.to_string()))
        .collect()
}

pub fn auto_settings(path: &Path, source_identity: &str) -> Result<super::AutoSettings, String> {
    let active = open_active(path, source_identity)?;
    if let Some(value) = read_setting_payload(&active, true)? {
        return serde_json::from_str(&value).map_err(|e| e.to_string());
    }
    if let Some(legacy) = open_legacy(path)? {
        if let Some(value) = read_setting_payload(&legacy, false)? {
            let settings: super::AutoSettings =
                serde_json::from_str(&value).map_err(|e| e.to_string())?;
            if settings.scope_key.as_deref() == Some(source_identity) {
                return Ok(settings);
            }
        }
    }
    Ok(super::AutoSettings::default())
}

fn read_setting_payload(db: &Connection, ensure_table: bool) -> Result<Option<String>, String> {
    if ensure_table {
        db.execute_batch("CREATE TABLE IF NOT EXISTS modeltrace_settings(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT NOT NULL)")
            .map_err(|e| e.to_string())?;
    } else {
        #[cfg(test)]
        let exists: bool = db
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='modeltrace_settings')",
                [],
                |row| row.get(0),
            )
            .map_err(|e| e.to_string())?;
        #[cfg(not(test))]
        let exists = db
            .has_logical_object("modeltrace_settings")
            .map_err(|e| e.to_string())?;
        if !exists {
            return Ok(None);
        }
    }
    db.query_row(
        "SELECT payload FROM modeltrace_settings WHERE id=1",
        [],
        |row| row.get(0),
    )
    .optional()
    .map_err(|e| e.to_string())
}

pub fn save_auto_settings(
    path: &Path,
    source_identity: &str,
    settings: &super::AutoSettings,
) -> Result<(), String> {
    open_active(path, source_identity)?
        .execute(
            "INSERT INTO modeltrace_settings(id,payload) VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
            [serde_json::to_string(settings).map_err(|e| e.to_string())?],
        )
        .map_err(|e| e.to_string())?;
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
        save(&path, "home-a", "a", &run).unwrap();
        run.status = "cancelled".into();
        save(&path, "home-a", "a", &run).unwrap();
        assert_eq!(history(&path, "home-a", "a").unwrap().len(), 1);
        assert_eq!(history(&path, "home-a", "a").unwrap()[0].status, "cancelled");
        assert!(history(&path, "home-a", "b").unwrap().is_empty());
        let _ = std::fs::remove_dir_all(temp);
    }
}
