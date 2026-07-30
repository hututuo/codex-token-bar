use super::app_paths;
use std::{
    collections::HashSet,
    fs::{self, OpenOptions},
    io::Write,
    sync::{Mutex, OnceLock},
    time::{Instant, SystemTime, UNIX_EPOCH},
};

const TRACE_WINDOW_MS: u128 = 15_000;
const PERFORMANCE_TRACE_MAX_BYTES: u64 = 96 * 1024;

static START: OnceLock<Instant> = OnceLock::new();
static SEEN_ONCE: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
static STARTUP_TRACE_WRITE_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static PERFORMANCE_TRACE_WRITE_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

pub fn begin(label: &str) {
    let start = START.get_or_init(Instant::now);
    clear_once_marks();
    let _write = STARTUP_TRACE_WRITE_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(path) = app_paths::startup_trace_log_path() else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let Ok(mut file) = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(path)
    else {
        return;
    };
    let _ = writeln!(file, "{:>6}ms {label}", start.elapsed().as_millis());
}

pub fn mark(label: &str) {
    write_mark(label, false);
}

pub fn mark_once(label: &'static str) {
    write_mark(label, true);
}

pub fn mark_performance(label: impl AsRef<str>) {
    let _write = PERFORMANCE_TRACE_WRITE_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(path) = app_paths::performance_trace_log_path() else {
        return;
    };

    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if fs::metadata(&path)
        .map(|metadata| metadata.len() > PERFORMANCE_TRACE_MAX_BYTES)
        .unwrap_or(false)
    {
        let _ = fs::remove_file(&path);
    }

    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) else {
        return;
    };
    let _ = writeln!(file, "{timestamp} {}", label.as_ref());
}

fn write_mark(label: &str, once: bool) {
    let start = START.get_or_init(Instant::now);
    let elapsed_ms = start.elapsed().as_millis();
    if elapsed_ms > TRACE_WINDOW_MS {
        return;
    }
    if once && !remember_once(label) {
        return;
    }

    let _write = STARTUP_TRACE_WRITE_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(path) = app_paths::startup_trace_log_path() else {
        return;
    };

    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    let mut options = OpenOptions::new();
    options.create(true).write(true).append(true);

    let Ok(mut file) = options.open(path) else {
        return;
    };

    let _ = writeln!(file, "{elapsed_ms:>6}ms {label}");
}

fn remember_once(label: &str) -> bool {
    let seen = SEEN_ONCE.get_or_init(|| Mutex::new(HashSet::new()));
    seen.lock()
        .map(|mut labels| labels.insert(label.to_string()))
        .unwrap_or(false)
}

fn clear_once_marks() {
    if let Some(seen) = SEEN_ONCE.get() {
        if let Ok(mut labels) = seen.lock() {
            labels.clear();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        collections::HashSet,
        sync::{Arc, Barrier},
        thread,
    };

    #[test]
    fn concurrent_performance_marks_keep_each_record_intact() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-startup-trace-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        let _environment = app_paths::app_path_test_env_guard(&[
            ("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", root.clone()),
            ("CODEX_TOKEN_BAR_TAURI_CACHE_DIR", root.clone()),
        ]);
        fs::create_dir_all(&root).unwrap();

        let worker_count = 8;
        let records_per_worker = 40;
        let barrier = Arc::new(Barrier::new(worker_count));
        let expected = (0..worker_count)
            .flat_map(|worker| {
                (0..records_per_worker)
                    .map(move |record| format!("parallel-{worker:02}-{record:02}-{}", "x".repeat(96)))
            })
            .collect::<HashSet<_>>();
        let workers = (0..worker_count)
            .map(|worker| {
                let barrier = Arc::clone(&barrier);
                thread::spawn(move || {
                    barrier.wait();
                    for record in 0..records_per_worker {
                        mark_performance(format!(
                            "parallel-{worker:02}-{record:02}-{}",
                            "x".repeat(96)
                        ));
                    }
                })
            })
            .collect::<Vec<_>>();
        for worker in workers {
            worker.join().unwrap();
        }

        let contents = fs::read_to_string(root.join("performance-trace.log")).unwrap();
        let actual = contents
            .lines()
            .filter_map(|line| line.split_once(' ').map(|(_, label)| label.to_string()))
            .filter(|label| label.starts_with("parallel-"))
            .collect::<HashSet<_>>();
        assert_eq!(actual, expected);

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn explicit_begin_owns_truncation_before_setup_marks() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-startup-begin-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        let _environment = app_paths::app_path_test_env_guard(&[
            ("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", root.clone()),
            ("CODEX_TOKEN_BAR_TAURI_CACHE_DIR", root.clone()),
        ]);
        fs::create_dir_all(&root).unwrap();

        begin("first process");
        mark("provider recovery start");
        begin("second process");
        mark("rust setup start");

        let contents = fs::read_to_string(root.join("startup-trace.log")).unwrap();
        assert!(!contents.contains("first process"));
        assert!(!contents.contains("provider recovery start"));
        assert!(contents.contains("second process"));
        assert!(contents.contains("rust setup start"));

        fs::remove_dir_all(root).unwrap();
    }
}
