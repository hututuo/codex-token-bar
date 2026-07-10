use super::safe_fs::PinnedHome;
use super::sqlite_state::{latest_thread_index_entry, scan_sqlite, SQLiteScan};
use serde_json::Value;
use std::collections::HashSet;
use std::fs;
use std::io::Write;
use std::path::Path;

#[derive(Default)]
pub(super) struct SessionIndexScan {
    ids: HashSet<String>,
    pub(super) rows: u32,
}

pub(super) fn scan_session_index(codex_home: &Path) -> SessionIndexScan {
    let path = codex_home.join("session_index.jsonl");
    let Ok(text) = fs::read_to_string(path) else {
        return SessionIndexScan::default();
    };

    let mut ids = HashSet::new();
    let mut rows = 0;
    for line in text.lines().filter(|line| !line.trim().is_empty()) {
        rows += 1;
        if let Ok(value) = serde_json::from_str::<Value>(line) {
            if let Some(id) = value.get("id").and_then(Value::as_str) {
                ids.insert(id.to_string());
            }
        }
    }
    SessionIndexScan { ids, rows }
}

pub(super) fn latest_thread_index_missing(
    sqlite_scan: &SQLiteScan,
    session_index: &SessionIndexScan,
) -> bool {
    sqlite_scan
        .latest_unarchived_thread_id
        .as_ref()
        .is_some_and(|thread_id| !session_index.ids.contains(thread_id))
}

#[cfg(test)]
pub(super) fn repair_session_index(codex_home: &Path) -> Result<bool, String> {
    let pinned_home = PinnedHome::open(codex_home)?;
    repair_session_index_in(&pinned_home)
}

pub(super) fn repair_session_index_in(pinned_home: &PinnedHome) -> Result<bool, String> {
    pinned_home.ensure_canonical_path_identity()?;
    let access_path = pinned_home.access_path();
    let sqlite = scan_sqlite(&access_path).map_err(|error| error.to_string())?;
    let Some(thread_id) = sqlite.latest_unarchived_thread_id else {
        return Ok(false);
    };
    let session_index = scan_session_index(&access_path);
    if session_index.ids.contains(&thread_id) {
        return Ok(false);
    }
    let entry = latest_thread_index_entry(&access_path, &thread_id)?;
    let relative = Path::new("session_index.jsonl");
    let mut bytes = match pinned_home.open_file(relative)? {
        Some(_) => pinned_home.read(relative)?,
        None => Vec::new(),
    };
    if !bytes.is_empty() && !bytes.ends_with(b"\n") {
        bytes.push(b'\n');
    }
    writeln!(
        bytes,
        "{}",
        serde_json::to_string(&entry).map_err(|error| error.to_string())?
    )
    .map_err(|error| error.to_string())?;
    pinned_home.ensure_canonical_path_identity()?;
    pinned_home.install_atomically(
        relative,
        None,
        None,
        |target| target.write_all(&bytes).map_err(|error| error.to_string()),
        |_, _| Ok(()),
    )?;
    Ok(true)
}
