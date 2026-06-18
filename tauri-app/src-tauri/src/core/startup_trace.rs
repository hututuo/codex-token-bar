use super::app_paths;
use std::{
    fs::{self, OpenOptions},
    io::Write,
    sync::OnceLock,
    time::Instant,
};

static START: OnceLock<Instant> = OnceLock::new();

pub fn mark(label: &str) {
    let start = START.get_or_init(Instant::now);
    let elapsed_ms = start.elapsed().as_millis();
    let Some(path) = app_paths::startup_trace_log_path() else {
        return;
    };

    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    let mut options = OpenOptions::new();
    options.create(true).write(true);
    if label == "rust setup start" {
        options.truncate(true);
    } else {
        options.append(true);
    }

    let Ok(mut file) = options.open(path) else {
        return;
    };

    let _ = writeln!(file, "{elapsed_ms:>6}ms {label}");
}
