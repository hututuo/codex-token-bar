use crate::models::UnreadSummary;
use std::path::Path;

mod recent_completion;
mod session_files;
mod state;

use state::read_unread_thread_ids;

pub fn read_unread_summary(codex_home: &Path) -> UnreadSummary {
    match read_unread_thread_ids(codex_home) {
        Some(thread_ids) => unread_state_summary(thread_ids.len()),
        None => recent_completion::recent_completion_summary(codex_home),
    }
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
            r#"{{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{{"type":"task_complete","turn_id":"turn-{id}","completed_at":{completed_at},"duration_ms":2000}}}}"#
        )
        .unwrap();
    }
}
