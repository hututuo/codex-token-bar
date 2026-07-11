use super::{acknowledge_current_unread, read_unread_summary};
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

    for step in sequence.steps {
        write_unread_state(&root, &step.native_thread_ids);
        for completion in &step.append_completions {
            assert_eq!(completion.thread_id, thread_id, "{}", step.name);
            assert_eq!(
                completion.event_id,
                format!("{}:{}", completion.thread_id, completion.turn_id),
                "{}",
                step.name
            );
            append_task_complete(&session, current_time_seconds(), &completion.turn_id);
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
    #[serde(rename = "eventID")]
    event_id: String,
    #[serde(rename = "threadID")]
    thread_id: String,
    #[serde(rename = "turnID")]
    turn_id: String,
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

fn current_time_seconds() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64()
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
