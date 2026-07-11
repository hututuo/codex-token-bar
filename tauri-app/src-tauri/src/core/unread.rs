use crate::core::app_paths;
use crate::models::UnreadSummary;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

mod recent_completion;
#[cfg(test)]
mod sequence_tests;
mod session_files;
mod state;

use state::read_unread_thread_ids;

static ACKNOWLEDGEMENT_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static TRUSTED_SUMMARIES: OnceLock<Mutex<HashMap<String, UnreadSummary>>> = OnceLock::new();
static TEMP_FILE_COUNTER: AtomicU64 = AtomicU64::new(0);

pub fn read_unread_summary(codex_home: &Path) -> UnreadSummary {
    let source_scope_key = codex_home_key(codex_home);
    match try_read_unread_summary(codex_home) {
        Ok(summary) => summary,
        Err(error) => retained_or_failed_summary(&source_scope_key, &error),
    }
}

pub fn try_read_unread_summary(codex_home: &Path) -> Result<UnreadSummary, String> {
    let source_scope_key = codex_home_key(codex_home);
    let summary = try_read_unread_summary_for_source_at(
        codex_home,
        &source_scope_key,
        recent_completion::current_time_seconds(),
        &write_acknowledgement_at,
    )?;
    remember_trusted_summary(&source_scope_key, &summary);
    Ok(summary)
}

#[cfg(test)]
fn read_unread_summary_at(codex_home: &Path, now: f64) -> Result<UnreadSummary, String> {
    try_read_unread_summary_at_with_writer(codex_home, now, &write_acknowledgement_at)
}

#[cfg(test)]
fn try_read_unread_summary_at_with_writer<W>(
    codex_home: &Path,
    now: f64,
    writer: &W,
) -> Result<UnreadSummary, String>
where
    W: Fn(&Path, &UnreadAcknowledgement) -> Result<(), String> + ?Sized,
{
    let source_scope_key = codex_home_key(codex_home);
    try_read_unread_summary_for_source_at(codex_home, &source_scope_key, now, writer)
}

fn try_read_unread_summary_for_source_at<W>(
    codex_home: &Path,
    source_scope_key: &str,
    now: f64,
    writer: &W,
) -> Result<UnreadSummary, String>
where
    W: Fn(&Path, &UnreadAcknowledgement) -> Result<(), String> + ?Sized,
{
    let native_thread_ids = read_unread_thread_ids(codex_home);
    acknowledgement_transaction(writer, || Ok(()), |acknowledgement| {
        let home_acknowledgement = acknowledgement
            .by_codex_home
            .entry(source_scope_key.to_string())
            .or_default();
        let previous = home_acknowledgement.clone();
        let summary = match native_thread_ids.as_ref() {
            Some(thread_ids) => {
                home_acknowledgement
                    .unread_thread_ids
                    .retain(|thread_id| thread_ids.contains(thread_id));
                let completion_thread_ids = recent_completion::recent_completion_thread_ids_at(
                    codex_home,
                    &home_acknowledgement.completion_markers,
                    now,
                );
                let reactivated_thread_ids: HashSet<String> = completion_thread_ids
                    .intersection(thread_ids)
                    .cloned()
                    .collect();
                home_acknowledgement
                    .unread_thread_ids
                    .retain(|thread_id| !reactivated_thread_ids.contains(thread_id));
                let mut active_ids: HashSet<String> = thread_ids
                    .difference(&home_acknowledgement.unread_thread_ids)
                    .cloned()
                    .collect();
                active_ids.extend(completion_thread_ids.intersection(thread_ids).cloned());
                unread_state_summary(active_ids.len())
            }
            None => recent_completion::recent_completion_summary_at(
                codex_home,
                &home_acknowledgement.completion_markers,
                now,
            ),
        };
        Ok((summary, *home_acknowledgement != previous))
    })
}

#[cfg(test)]
pub fn acknowledge_current_unread(codex_home: &Path) -> Result<UnreadSummary, String> {
    let home_key = codex_home_key(codex_home);
    acknowledge_current_unread_for_source(codex_home, &home_key, || Ok(()))
}

pub fn acknowledge_current_unread_for_source(
    observation_home: &Path,
    source_scope_key: &str,
    validate_before_write: impl FnOnce() -> Result<(), String>,
) -> Result<UnreadSummary, String> {
    let completion_markers = recent_completion::recent_completion_markers(observation_home);
    let native_thread_ids = read_unread_thread_ids(observation_home);
    let summary = acknowledgement_transaction(
        &write_acknowledgement_at,
        validate_before_write,
        |acknowledgement| {
            let home_acknowledgement = acknowledgement
                .by_codex_home
                .entry(source_scope_key.to_string())
                .or_default();
            let previous = home_acknowledgement.clone();
            match native_thread_ids.as_ref() {
                Some(thread_ids) => {
                    home_acknowledgement
                        .unread_thread_ids
                        .extend(thread_ids.iter().cloned());
                    home_acknowledgement
                        .completion_markers
                        .extend(completion_markers.iter().cloned());
                }
                None => home_acknowledgement
                    .completion_markers
                    .extend(completion_markers.iter().cloned()),
            }
            Ok((
                unread_state_summary(0),
                *home_acknowledgement != previous,
            ))
        },
    )?;
    remember_trusted_summary(source_scope_key, &summary);
    Ok(summary)
}

fn unread_state_summary(count: usize) -> UnreadSummary {
    let active = count > 0;
    UnreadSummary {
        active,
        count: count as u32,
        label: if active {
            "有未读完成会话".into()
        } else {
            "暂无未读完成会话".into()
        },
        detail: if active {
            format!("{count} 个会话等待查看")
        } else {
            "Codex 未读列表为空。".into()
        },
        source: "codex_unread_state".into(),
    }
}

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct UnreadAcknowledgement {
    #[serde(default)]
    by_codex_home: HashMap<String, HomeUnreadAcknowledgement>,
}

#[derive(Clone, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct HomeUnreadAcknowledgement {
    #[serde(default)]
    unread_thread_ids: HashSet<String>,
    #[serde(default)]
    completion_markers: HashSet<String>,
}

fn acknowledgement_transaction<T, W, V, F>(
    writer: &W,
    validate_before_write: V,
    operation: F,
) -> Result<T, String>
where
    W: Fn(&Path, &UnreadAcknowledgement) -> Result<(), String> + ?Sized,
    V: FnOnce() -> Result<(), String>,
    F: FnOnce(&mut UnreadAcknowledgement) -> Result<(T, bool), String>,
{
    let lock = ACKNOWLEDGEMENT_LOCK.get_or_init(|| Mutex::new(()));
    let _guard = lock
        .lock()
        .map_err(|_| "未读基线事务锁已损坏".to_string())?;
    let Some(path) = app_paths::unread_acknowledgement_path() else {
        return Err("无法定位 Tauri 应用支持目录，不能记录未读基线".into());
    };
    let mut acknowledgement = read_acknowledgement_at(&path)?;
    let (result, changed) = operation(&mut acknowledgement)?;
    if changed {
        validate_before_write()?;
        writer(&path, &acknowledgement)?;
    }
    Ok(result)
}

fn read_acknowledgement_at(path: &Path) -> Result<UnreadAcknowledgement, String> {
    let data = match fs::read(path) {
        Ok(data) => data,
        Err(error) if error.kind() == ErrorKind::NotFound => {
            return Ok(UnreadAcknowledgement::default());
        }
        Err(error) => {
            return Err(format!("读取未读基线失败：{error}"));
        }
    };
    serde_json::from_slice(&data).map_err(|error| format!("未读基线 JSON 损坏：{error}"))
}

fn write_acknowledgement_at(
    path: &Path,
    acknowledgement: &UnreadAcknowledgement,
) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| format!("创建未读基线目录失败：{error}"))?;
    }
    let data = serde_json::to_vec_pretty(acknowledgement).map_err(|error| error.to_string())?;
    let parent = path
        .parent()
        .ok_or_else(|| "未读基线路径缺少父目录".to_string())?;
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("unread-acknowledgement.json");
    let sequence = TEMP_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let temp_path = parent.join(format!(
        ".{file_name}.tmp-{}-{sequence}-{timestamp}",
        std::process::id(),
    ));

    let write_result = (|| {
        let mut temp_file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temp_path)
            .map_err(|error| format!("创建未读基线临时文件失败：{error}"))?;
        temp_file
            .write_all(&data)
            .map_err(|error| format!("写入未读基线临时文件失败：{error}"))?;
        temp_file
            .sync_all()
            .map_err(|error| format!("同步未读基线临时文件失败：{error}"))?;
        fs::rename(&temp_path, path).map_err(|error| format!("替换未读基线失败：{error}"))?;
        fs::File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| format!("同步未读基线目录失败：{error}"))
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&temp_path);
    }
    write_result
}

fn remember_trusted_summary(source_scope_key: &str, summary: &UnreadSummary) {
    let cache = TRUSTED_SUMMARIES.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(mut guard) = cache.lock() {
        guard.insert(source_scope_key.to_string(), summary.clone());
    }
}

fn retained_or_failed_summary(source_scope_key: &str, error: &str) -> UnreadSummary {
    let cache = TRUSTED_SUMMARIES.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(guard) = cache.lock() {
        if let Some(summary) = guard.get(source_scope_key) {
            let mut retained = summary.clone();
            retained.detail = format!("{} · 读取失败，保留上次可信结果：{error}", retained.detail);
            retained.source = format!("{}_stale", retained.source);
            return retained;
        }
    }
    UnreadSummary {
        active: false,
        count: 0,
        label: "未读状态读取失败".into(),
        detail: error.into(),
        source: "unread_error".into(),
    }
}

fn codex_home_key(codex_home: &Path) -> String {
    normalized_codex_home(codex_home).to_string_lossy().into_owned()
}

fn normalized_codex_home(codex_home: &Path) -> PathBuf {
    fs::canonicalize(codex_home).unwrap_or_else(|_| codex_home.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;
    use recent_completion::{current_time_seconds, lookback_seconds};
    use rusqlite::Connection;
    use std::collections::HashSet;
    use std::fs;
    use std::io::Write;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn reads_unread_state_and_filters_non_user_visible_threads() {
        let root = temp_root("sqlite-filter");
        fs::create_dir_all(&root).unwrap();
        let visible = "019eaaaa-0000-0000-0000-000000000001";
        let archived = "019eaaaa-0000-0000-0000-000000000002";
        let subagent = "019eaaaa-0000-0000-0000-000000000003";
        let empty_preview = "019eaaaa-0000-0000-0000-000000000004";
        write_unread_state(&root, &[visible, archived, subagent, empty_preview]);
        create_state_database(&root, visible, archived, subagent, empty_preview);

        let ids = read_unread_thread_ids(&root).unwrap();
        assert_eq!(ids, HashSet::from([visible.to_string()]));
        let summary = read_unread_summary(&root);
        assert!(summary.active);
        assert_eq!(summary.count, 1);
        assert_eq!(summary.source, "codex_unread_state");

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn falls_back_to_session_meta_visibility_when_sqlite_is_missing() {
        let root = temp_root("session-fallback");
        let sessions = root.join("sessions");
        let archived_sessions = root.join("archived_sessions");
        fs::create_dir_all(&sessions).unwrap();
        fs::create_dir_all(&archived_sessions).unwrap();
        let visible = "019eaaaa-0000-0000-0000-000000000005";
        let subagent = "019eaaaa-0000-0000-0000-000000000006";
        let archived = "019eaaaa-0000-0000-0000-000000000007";
        write_unread_state(&root, &[visible, subagent, archived]);
        write_session_meta(&sessions.join("visible.jsonl"), visible, false);
        write_session_meta(&sessions.join("subagent.jsonl"), subagent, true);
        write_session_meta(&archived_sessions.join("archived.jsonl"), archived, false);

        let ids = read_unread_thread_ids(&root).unwrap();
        assert_eq!(ids, HashSet::from([visible.to_string()]));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn falls_back_to_recent_task_complete_when_unread_state_is_unavailable() {
        let root = temp_root("task-complete-fallback");
        let sessions = root.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        let visible = "019eaaaa-0000-0000-0000-000000000008";
        write_session_complete(
            &sessions.join("visible.jsonl"),
            visible,
            false,
            current_time_seconds() - 3.0,
        );

        let summary = read_unread_summary(&root);
        assert!(summary.active);
        assert_eq!(summary.count, 1);
        assert_eq!(summary.source, "recent_task_complete");

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn does_not_use_task_complete_fallback_when_unread_state_is_available() {
        let root = temp_root("task-complete-state-priority");
        let sessions = root.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        let visible = "019eaaaa-0000-0000-0000-000000000009";
        write_unread_state(&root, &[]);
        write_session_complete(
            &sessions.join("visible.jsonl"),
            visible,
            false,
            current_time_seconds() - 3.0,
        );

        assert!(!read_unread_summary(&root).active);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn task_complete_fallback_filters_subagents_and_old_completions() {
        let root = temp_root("task-complete-filter");
        let sessions = root.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        write_session_complete(
            &sessions.join("subagent.jsonl"),
            "019eaaaa-0000-0000-0000-000000000010",
            true,
            current_time_seconds() - 3.0,
        );
        write_session_complete(
            &sessions.join("old.jsonl"),
            "019eaaaa-0000-0000-0000-000000000011",
            false,
            current_time_seconds() - lookback_seconds() - 10.0,
        );

        assert!(!read_unread_summary(&root).active);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn acknowledging_current_unread_state_filters_only_existing_threads_without_touching_codex_state() {
        let root = temp_root("ack-unread-state");
        let support = root.join("tauri-support");
        fs::create_dir_all(&root).unwrap();
        let _support_env = TauriSupportEnvGuard::new(&support);
        let existing = "019eaaaa-0000-0000-0000-000000000012";
        let later = "019eaaaa-0000-0000-0000-000000000013";
        write_unread_state(&root, &[existing]);

        assert!(read_unread_summary(&root).active);
        let acknowledged = acknowledge_current_unread(&root).unwrap();
        assert!(!acknowledged.active);
        assert!(!read_unread_summary(&root).active);
        assert!(
            fs::read_to_string(root.join(".codex-global-state.json"))
                .unwrap()
                .contains(existing),
            "acknowledgement must not modify Codex unread state"
        );

        write_unread_state(&root, &[existing, later]);
        let summary = read_unread_summary(&root);
        assert!(summary.active);
        assert_eq!(summary.count, 1);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn source_validation_failure_cannot_write_an_observed_baseline() {
        let root = temp_root("ack-source-swap");
        let support = root.join("tauri-support");
        fs::create_dir_all(&root).unwrap();
        let _support_env = TauriSupportEnvGuard::new(&support);
        write_unread_state(&root, &["019eaaaa-0000-0000-0000-000000000099"]);

        let result = acknowledge_current_unread_for_source(
            &root,
            "canonical-a|physical-a",
            || Err("injected physical source replacement".into()),
        );

        assert_eq!(result.unwrap_err(), "injected physical source replacement");
        assert!(
            !support.join("unread-acknowledgement.json").exists(),
            "validation must run before any baseline write"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn acknowledging_one_codex_home_does_not_filter_another_home() {
        let support = temp_root("ack-home-scope-support");
        let home_a = temp_root("ack-home-scope-a");
        let home_b = temp_root("ack-home-scope-b");
        fs::create_dir_all(&home_a).unwrap();
        fs::create_dir_all(&home_b).unwrap();
        let _support_env = TauriSupportEnvGuard::new(&support);
        let shared_thread_id = "019eaaaa-0000-0000-0000-000000000020";
        write_unread_state(&home_a, &[shared_thread_id]);
        write_unread_state(&home_b, &[shared_thread_id]);

        assert!(read_unread_summary(&home_a).active);
        assert!(read_unread_summary(&home_b).active);

        let acknowledged = acknowledge_current_unread(&home_a).unwrap();
        assert!(!acknowledged.active);

        assert!(!read_unread_summary(&home_a).active);
        let home_b_summary = read_unread_summary(&home_b);
        assert!(home_b_summary.active);
        assert_eq!(home_b_summary.count, 1);

        let _ = fs::remove_dir_all(support);
        let _ = fs::remove_dir_all(home_a);
        let _ = fs::remove_dir_all(home_b);
    }

    #[test]
    fn acknowledging_recent_completion_filters_current_completion_but_not_later_completion() {
        let root = temp_root("ack-recent-completion");
        let support = root.join("tauri-support");
        let sessions = root.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        let _support_env = TauriSupportEnvGuard::new(&support);
        let thread_id = "019eaaaa-0000-0000-0000-000000000014";
        write_session_complete_with_turn(
            &sessions.join("visible.jsonl"),
            thread_id,
            false,
            current_time_seconds() - 3.0,
            "turn-before-ack",
        );

        assert!(read_unread_summary(&root).active);
        let acknowledged = acknowledge_current_unread(&root).unwrap();
        assert!(!acknowledged.active);
        assert!(!read_unread_summary(&root).active);

        append_task_complete(
            &sessions.join("visible.jsonl"),
            thread_id,
            current_time_seconds(),
            "turn-after-ack",
        );
        let summary = read_unread_summary(&root);
        assert!(summary.active);
        assert_eq!(summary.count, 1);

        let _ = fs::remove_dir_all(root);
    }

    fn temp_root(label: &str) -> PathBuf {
        let sequence = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "codex-token-bar-unread-{label}-{}-{sequence}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn write_unread_state(root: &Path, ids: &[&str]) {
        let values = ids
            .iter()
            .map(|id| format!(r#""{id}""#))
            .collect::<Vec<_>>()
            .join(",");
        fs::write(
            root.join(".codex-global-state.json"),
            format!(
                r#"{{"electron-persisted-atom-state":{{"unread-thread-ids-by-host-v1":{{"localhost":[{values}]}}}}}}"#
            ),
        )
        .unwrap();
    }

    fn create_state_database(
        root: &Path,
        visible: &str,
        archived: &str,
        subagent: &str,
        empty_preview: &str,
    ) {
        let connection = Connection::open(root.join("state_5.sqlite")).unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    archived INTEGER,
                    thread_source TEXT,
                    source TEXT,
                    preview TEXT
                );
                "#,
            )
            .unwrap();
        insert_thread(&connection, visible, 0, "user", "desktop", "hello");
        insert_thread(&connection, archived, 1, "user", "desktop", "archived");
        insert_thread(&connection, subagent, 0, "subagent", "desktop", "subagent");
        insert_thread(&connection, empty_preview, 0, "user", "desktop", "");
    }

    fn insert_thread(
        connection: &Connection,
        id: &str,
        archived: i64,
        thread_source: &str,
        source: &str,
        preview: &str,
    ) {
        connection
            .execute(
                "INSERT INTO threads (id, archived, thread_source, source, preview) VALUES (?1, ?2, ?3, ?4, ?5);",
                (id, archived, thread_source, source, preview),
            )
            .unwrap();
    }

    fn write_session_meta(path: &Path, id: &str, subagent: bool) {
        let mut file = fs::File::create(path).unwrap();
        let source = if subagent { r#""subagent""# } else { r#""desktop""# };
        writeln!(
            file,
            r#"{{"type":"session_meta","payload":{{"id":"{id}","thread_source":{},"source":{source}}}}}"#,
            if subagent { r#""subagent""# } else { r#""user""# }
        )
        .unwrap();
    }

    fn write_session_complete(path: &Path, id: &str, subagent: bool, completed_at: f64) {
        write_session_complete_with_turn(path, id, subagent, completed_at, &format!("turn-{id}"));
    }

    fn write_session_complete_with_turn(
        path: &Path,
        id: &str,
        subagent: bool,
        completed_at: f64,
        turn_id: &str,
    ) {
        let mut file = fs::File::create(path).unwrap();
        let source = if subagent { r#""subagent""# } else { r#""desktop""# };
        writeln!(
            file,
            r#"{{"type":"session_meta","payload":{{"id":"{id}","thread_source":{},"source":{source}}}}}"#,
            if subagent { r#""subagent""# } else { r#""user""# }
        )
        .unwrap();
        writeln!(
            file,
            r#"{{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{{"type":"task_complete","turn_id":"{turn_id}","completed_at":{completed_at},"duration_ms":2000}}}}"#
        )
        .unwrap();
    }

    fn append_task_complete(path: &Path, _id: &str, completed_at: f64, turn_id: &str) {
        let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
        writeln!(
            file,
            r#"{{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{{"type":"task_complete","turn_id":"{turn_id}","completed_at":{completed_at},"duration_ms":2000}}}}"#
        )
        .unwrap();
    }

    struct TauriSupportEnvGuard;

    impl TauriSupportEnvGuard {
        fn new(path: &Path) -> Self {
            std::env::set_var("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", path);
            Self
        }
    }

    impl Drop for TauriSupportEnvGuard {
        fn drop(&mut self) {
            std::env::remove_var("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR");
        }
    }
}
