use super::app_paths;
use std::{
    collections::HashSet,
    fs::{self, OpenOptions},
    io::Write,
    sync::{Mutex, OnceLock},
    time::Instant,
};

const TRACE_WINDOW_MS: u128 = 15_000;

static START: OnceLock<Instant> = OnceLock::new();
static SEEN_ONCE: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();

pub fn mark(label: &str) {
    write_mark(label, false);
}

pub fn mark_once(label: &'static str) {
    write_mark(label, true);
}

fn write_mark(label: &str, once: bool) {
    let start = START.get_or_init(Instant::now);
    let elapsed_ms = start.elapsed().as_millis();
    let is_start = label == "rust setup start";
    if elapsed_ms > TRACE_WINDOW_MS && !is_start {
        return;
    }
    if once && !remember_once(label) {
        return;
    }

    let Some(path) = app_paths::startup_trace_log_path() else {
        return;
    };

    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    let mut options = OpenOptions::new();
    options.create(true).write(true);
    if is_start {
        clear_once_marks();
        options.truncate(true);
    } else {
        options.append(true);
    }

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
