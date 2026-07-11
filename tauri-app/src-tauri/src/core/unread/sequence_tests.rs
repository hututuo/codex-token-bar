use super::recent_completion::{
    current_time_seconds, lookback_seconds, recent_completion_markers,
};
use super::{acknowledge_current_unread, read_unread_summary, read_unread_summary_at};
use serde::Deserialize;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[test]
fn shared_unread_correctness_sequence() {
    let sequence: UnreadCorrectnessSequence = serde_json::from_str(include_str!(
        "../../../../../TestFixtures/unread-correctness-sequence.json"
    ))
    .unwrap();
    let root = temp_root();
    let support = root.join("tauri-support");
    let sessions = root.join("sessions");
    fs::create_dir_all(&sessions).unwrap();
    let _support_env = TauriSupportEnvGuard::new(&support);
    let session = sessions.join("sequence.jsonl");
    let thread_id = "019eaaaa-0000-0000-0000-0000000000aa";
    write_session_meta(&session, thread_id);
    let base_completed_at = current_time_seconds();

    for step in sequence.steps {
        write_unread_state(&root, &step.native_thread_ids);
        for completion in &step.append_completions {
            assert_eq!(completion.thread_id, thread_id, "{}", step.name);
            assert!(!completion.title.is_empty(), "{}", step.name);
            append_task_complete(
                &session,
                base_completed_at + completion.completed_at_offset_seconds,
                &completion.turn_id,
            );
            let parsed_ids = recent_completion_markers(&root);
            assert!(
                parsed_ids.contains(&completion.expected_canonical_id),
                "{}",
                step.name
            );
        }

        let summary = if step.action == "markAllRead" {
            acknowledge_current_unread(&root).unwrap()
        } else {
            read_unread_summary(&root)
        };
        assert_eq!(summary.count, step.expected_count, "{}", step.name);
    }

    let _ = fs::remove_dir_all(root);
}

#[test]
fn completion_rearm_persists_after_lookback_until_next_acknowledgement() {
    let root = temp_root();
    let support = root.join("tauri-support");
    let sessions = root.join("sessions");
    fs::create_dir_all(&sessions).unwrap();
    let _support_env = TauriSupportEnvGuard::new(&support);
    let session = sessions.join("persistent-rearm.jsonl");
    let thread_id = "019eaaaa-0000-0000-0000-0000000000dd";
    let now = current_time_seconds();
    write_session_meta(&session, thread_id);
    write_unread_state(&root, &[thread_id.to_string()]);

    assert_eq!(read_unread_summary_at(&root, now).count, 1);
    assert_eq!(acknowledge_current_unread(&root).unwrap().count, 0);

    append_task_complete(&session, now + 1.0, "turn-rearm");
    assert_eq!(read_unread_summary_at(&root, now + 1.0).count, 1);
    let persisted = fs::read_to_string(support.join("unread-acknowledgement.json")).unwrap();
    assert!(!persisted.contains(thread_id));

    let after_lookback = now + lookback_seconds() + 5.0;
    assert_eq!(read_unread_summary_at(&root, after_lookback).count, 1);

    assert_eq!(acknowledge_current_unread(&root).unwrap().count, 0);
    assert_eq!(read_unread_summary_at(&root, after_lookback).count, 0);

    let _ = fs::remove_dir_all(root);
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UnreadCorrectnessSequence {
    steps: Vec<UnreadCorrectnessStep>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UnreadCorrectnessStep {
    name: String,
    #[serde(rename = "nativeThreadIDs")]
    native_thread_ids: Vec<String>,
    append_completions: Vec<UnreadCorrectnessCompletion>,
    action: String,
    expected_count: u32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UnreadCorrectnessCompletion {
    #[serde(rename = "expectedCanonicalID")]
    expected_canonical_id: String,
    #[serde(rename = "threadID")]
    thread_id: String,
    #[serde(rename = "turnID")]
    turn_id: String,
    completed_at_offset_seconds: f64,
    title: String,
}

fn temp_root() -> PathBuf {
    let sequence = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "codex-token-bar-unread-sequence-{}-{sequence}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

fn write_unread_state(root: &Path, ids: &[String]) {
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

fn write_session_meta(path: &Path, thread_id: &str) {
    let mut file = fs::File::create(path).unwrap();
    writeln!(
        file,
        r#"{{"type":"session_meta","payload":{{"id":"{thread_id}","thread_source":"user","source":"desktop"}}}}"#
    )
    .unwrap();
}

fn append_task_complete(path: &Path, completed_at: f64, turn_id: &str) {
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
