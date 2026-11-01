//! Append-only, per-attempt diagnostics, deliberately outside both business DBs.
//! No time-window cutoff, source rows, credentials, or automatic upload. A failed
//! diagnostic write never becomes permission to mutate or discard a ledger.
use serde::Serialize;
use serde_json::{json, Value};
use std::{cell::RefCell, collections::VecDeque, fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write}, path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock}, time::{Instant, SystemTime, UNIX_EPOCH}};

const PREVIEW_LINES: usize = 100;
const PREVIEW_BYTES: u64 = 64 * 1024;
type Shared = Arc<Mutex<Journal>>;
thread_local! { static ACTIVE: RefCell<Option<Shared>> = const { RefCell::new(None) }; }
static LATEST: OnceLock<Mutex<Option<Shared>>> = OnceLock::new();

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Snapshot {
    pub attempt_id: Option<String>,
    pub path: Option<String>,
    pub persistence_error: Option<String>,
    pub total_events: u64,
    pub preview: Vec<String>,
}
struct Journal { file: Option<File>, state: Snapshot, tail: VecDeque<String>, start: Instant }
impl Journal {
    fn new(root: &Path, operation: &str) -> Self {
        let id = uuid::Uuid::new_v4().to_string();
        let path = root.join(format!("attempt-{id}.jsonl"));
        let opened = secure_directory(root).and_then(|_| {
            let file = private_options().create_new(true).write(true).open(&path).map_err(|e| e.to_string())?;
            super::atomic_file::sync_parent(root).map_err(|e| e.to_string())?;
            Ok(file)
        });
        let mut journal = Self { file: None, state: Snapshot {
            attempt_id: Some(id), path: Some(path.display().to_string()), ..Snapshot::default()
        }, tail: VecDeque::new(), start: Instant::now() };
        match opened { Ok(file) => journal.file = Some(file), Err(error) => journal.state.persistence_error = Some(error) }
        journal.record("attempt", "started", json!({"operation":operation,
            "appVersion":env!("CARGO_PKG_VERSION"),"platform":std::env::consts::OS}));
        journal
    }
    fn record(&mut self, stage: &str, status: &str, details: Value) {
        self.state.total_events += 1;
        let line = json!({"schemaVersion":1,"attemptId":self.state.attempt_id,
            "sequence":self.state.total_events,"timestampMs":SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis(),
            "elapsedMs":self.start.elapsed().as_millis(),"stage":stage,"status":status,"details":details}).to_string();
        if let Some(file) = self.file.as_mut() {
            // Each record is durable, including the last started stage before a
            // crash. There is intentionally no 15-second startup-log window.
            if let Err(error) = writeln!(file, "{line}").and_then(|_| file.sync_data()) {
                self.state.persistence_error = Some(error.to_string()); self.file = None;
            }
        }
        self.tail.push_back(line);
        while self.tail.len() > PREVIEW_LINES { self.tail.pop_front(); }
    }
    fn snapshot(&self) -> Snapshot {
        let mut state = self.state.clone(); state.preview = self.tail.iter().cloned().collect(); state
    }
}
fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600).custom_flags(libc::O_NOFOLLOW); }
    options
}
fn secure_directory(root: &Path) -> Result<(), String> {
    match fs::symlink_metadata(root) {
        Ok(meta) if meta.is_dir() && !meta.file_type().is_symlink() => Ok(()),
        Ok(_) => Err("诊断目录不是普通目录，已拒绝写入".into()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            fs::create_dir_all(root).map_err(|e| e.to_string())?;
            #[cfg(unix)] { use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(root, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?; }
            secure_directory(root)
        },
        Err(e) => Err(e.to_string()),
    }
}
pub(crate) fn directory() -> Result<PathBuf, String> {
    Ok(super::business_store_route::container_path()?.with_file_name("migration-diagnostics"))
}
struct Scope(Option<Shared>);
impl Drop for Scope { fn drop(&mut self) { ACTIVE.with(|active| *active.borrow_mut() = self.0.take()); } }
pub(crate) fn run<T>(root: &Path, operation: &str, work: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    let journal = Arc::new(Mutex::new(Journal::new(root, operation)));
    let _scope = Scope(ACTIVE.with(|active| active.replace(Some(journal.clone()))));
    *LATEST.get_or_init(|| Mutex::new(None)).lock().unwrap_or_else(|e| e.into_inner()) = Some(journal);
    let result = work();
    event("attempt", if result.is_ok() { "succeeded" } else { "failed" },
        result.as_ref().err().map_or_else(|| json!({}), |e| json!({"error":e})));
    result
}
pub(crate) fn event(stage: &str, status: &str, details: Value) {
    ACTIVE.with(|active| {
        if let Some(journal) = active.borrow().as_ref() {
            journal.lock().unwrap_or_else(|e| e.into_inner()).record(stage, status, details);
        }
    });
}
pub(crate) fn step<T>(stage: &str, subject: &str, work: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    let start = Instant::now();
    event(stage, "started", json!({"subject":subject}));
    let result = work();
    event(stage, if result.is_ok() { "succeeded" } else { "failed" },
        json!({"subject":subject,"durationMs":start.elapsed().as_millis(),"error":result.as_ref().err()}));
    result
}
/// Advisory read-only inventory: report all independently observable faults,
/// never stop at the first bad source or treat a successful probe as a proof.
pub(crate) fn inspect_inputs(paths: &[PathBuf]) {
    for path in paths {
        let result = (|| -> Result<Value, String> {
            let meta = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
            if !meta.is_file() || meta.file_type().is_symlink() { return Err("输入不是普通文件".into()); }
            let db = rusqlite::Connection::open_with_flags(path,
                rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX)
                .map_err(|e| e.to_string())?;
            db.busy_timeout(std::time::Duration::from_millis(500)).map_err(|e| e.to_string())?;
            let version: i64 = db.query_row("PRAGMA user_version", [], |row| row.get(0)).map_err(|e| e.to_string())?;
            let objects: i64 = db.query_row("SELECT COUNT(*) FROM sqlite_master", [], |row| row.get(0)).map_err(|e| e.to_string())?;
            Ok(json!({"path":path,"sizeBytes":meta.len(),"userVersion":version,"schemaObjects":objects,
                "scope":"metadata-only; import still requires complete content proofs"}))
        })();
        match result { Ok(details) => event("input-preflight", "succeeded", details),
            Err(error) => event("input-preflight", "failed", json!({"path":path,"error":error})) }
    }
}
fn log_paths(root: &Path) -> Result<Vec<PathBuf>, String> {
    if !root.exists() { return Ok(Vec::new()); }
    secure_directory(root)?;
    let mut paths = Vec::new();
    for entry in fs::read_dir(root).map_err(|e| e.to_string())? {
        let path = entry.map_err(|e| e.to_string())?.path();
        let name = path.file_name().and_then(|v| v.to_str()).unwrap_or("");
        if !name.strip_prefix("attempt-").and_then(|v| v.strip_suffix(".jsonl"))
            .is_some_and(|v| uuid::Uuid::parse_str(v).is_ok()) { continue; }
        let meta = fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
        if !meta.is_file() || meta.file_type().is_symlink() { return Err("诊断日志不是普通文件，未导出".into()); }
        paths.push(path);
    }
    paths.sort_by_key(|p| fs::metadata(p).and_then(|m| m.modified()).ok());
    Ok(paths)
}
fn preview_at(root: &Path) -> Result<Snapshot, String> {
    let Some(path) = log_paths(root)?.pop() else { return Ok(Snapshot::default()); };
    let mut file = private_options().read(true).open(&path).map_err(|e| e.to_string())?;
    let len = file.metadata().map_err(|e| e.to_string())?.len();
    let offset = len.saturating_sub(PREVIEW_BYTES);
    file.seek(SeekFrom::Start(offset)).map_err(|e| e.to_string())?;
    let mut bytes = Vec::new(); file.take(PREVIEW_BYTES).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&bytes);
    let lines: Vec<_> = text.lines().skip(usize::from(offset > 0)).collect();
    let preview: Vec<_> = lines.into_iter().rev().take(PREVIEW_LINES).collect::<Vec<_>>().into_iter().rev().map(str::to_string).collect();
    let last = preview.iter().rev().find_map(|s| serde_json::from_str::<Value>(s).ok());
    Ok(Snapshot { attempt_id: last.as_ref().and_then(|v| v["attemptId"].as_str()).map(str::to_owned),
        total_events: last.as_ref().and_then(|v| v["sequence"].as_u64()).unwrap_or(0),
        path: Some(path.display().to_string()), preview, persistence_error: None })
}
pub(crate) fn snapshot() -> Result<Snapshot, String> {
    if let Some(journal) = LATEST.get_or_init(|| Mutex::new(None)).lock().unwrap_or_else(|e| e.into_inner()).clone() {
        let state = journal.lock().unwrap_or_else(|e| e.into_inner()).snapshot();
        return Ok(state);
    }
    preview_at(&directory()?)
}
/// Export every retained attempt, streaming instead of loading an unbounded
/// journal into the webview. Caller supplies no filesystem path. Original logs
/// are never removed; a live attempt is copied through a stable byte boundary.
pub(crate) fn export_at(root: &Path) -> Result<PathBuf, String> {
    let paths = log_paths(root)?;
    if paths.is_empty() { return Err("尚无已保存的迁移日志；请查看页面中的日志写入错误".into()); }
    let out = root.join("exports"); secure_directory(&out)?;
    let target = out.join(format!("TokenBar_migration_{}.zip", uuid::Uuid::new_v4()));
    let file = private_options().write(true).create_new(true).open(&target).map_err(|e| e.to_string())?;
    let result = (|| -> Result<(), String> {
        let mut zip = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default().unix_permissions(0o600);
        zip.start_file("README.txt", options).map_err(|e| e.to_string())?;
        zip.write_all(b"Migration diagnostics v1. Local paths and errors may be included; inspect before sharing. No database rows or credentials are intentionally collected. Logs from unfinished/crashed attempts end without an attempt/succeeded or failed event. Active files are exported through a fixed byte boundary.\n").map_err(|e| e.to_string())?;
        for path in paths {
            let file = private_options().read(true).open(&path).map_err(|e| e.to_string())?;
            let len = file.metadata().map_err(|e| e.to_string())?.len();
            zip.start_file(path.file_name().unwrap().to_string_lossy(), options).map_err(|e| e.to_string())?;
            std::io::copy(&mut file.take(len), &mut zip).map_err(|e| e.to_string())?;
        }
        // Include current persistence errors and in-memory tail if disk logging
        // stopped mid-attempt; never label that attempt a complete disk log.
        zip.start_file("current-status.json", options).map_err(|e| e.to_string())?;
        serde_json::to_writer(&mut zip, &snapshot().unwrap_or_default()).map_err(|e| e.to_string())?;
        zip.finish().map_err(|e| e.to_string())?.sync_all().map_err(|e| e.to_string())?;
        super::atomic_file::sync_parent(&out).map_err(|e| e.to_string())?;
        Ok(())
    })();
    if let Err(error) = result { let _ = fs::remove_file(&target); return Err(error); }
    Ok(target)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn retries_have_separate_files_and_full_events_outlive_preview_and_time_window() {
        let root = tempfile::tempdir().unwrap();
        let journal = run(root.path(), "test", || {
            ACTIVE.with(|active| active.borrow().as_ref().unwrap().lock().unwrap().start = Instant::now() - std::time::Duration::from_secs(30));
            for n in 0..130 { event("proof", "succeeded", json!({"n":n})); }
            Ok(())
        }); assert!(journal.is_ok());
        run(root.path(), "retry", || -> Result<(),String> { Err("a\nb\"c".into()) }).unwrap_err();
        let paths = log_paths(root.path()).unwrap(); assert_eq!(paths.len(),2);
        let all: Vec<Value> = fs::read_to_string(&paths[0]).unwrap().lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        assert_eq!(all.len(),132); assert!(all[1]["elapsedMs"].as_u64().unwrap() >= 30_000);
        assert_eq!(all.last().unwrap()["status"],"succeeded");
        assert_eq!(preview_at(root.path()).unwrap().total_events,2);
        let exported = export_at(root.path()).unwrap();
        let mut archive = zip::ZipArchive::new(File::open(exported).unwrap()).unwrap();
        assert_eq!(archive.len(),4);
        assert!(archive.by_name(paths[0].file_name().unwrap().to_str().unwrap()).unwrap().size() > 1000);
    }
    #[test]
    fn diagnostic_failure_does_not_authorize_or_fail_business_work() {
        let root = tempfile::tempdir().unwrap(); let blocked = root.path().join("blocked"); fs::write(&blocked,b"keep").unwrap();
        let result = run(&blocked,"test",|| { ACTIVE.with(|a| assert!(a.borrow().as_ref().unwrap().lock().unwrap().state.persistence_error.is_some())); Ok(42) });
        assert_eq!(result.unwrap(),42); assert_eq!(fs::read(&blocked).unwrap(),b"keep");
    }
    #[test]
    fn preflight_records_every_bad_input_without_mutating_any_source() {
        let root = tempfile::tempdir().unwrap();
        let a=root.path().join("a.sqlite"); let b=root.path().join("b.sqlite");
        fs::write(&a,b"broken-a").unwrap(); fs::write(&b,b"broken-b").unwrap();
        run(&root.path().join("logs"),"preflight",|| { inspect_inputs(&[a.clone(),b.clone()]); Ok(()) }).unwrap();
        let state=snapshot().unwrap();
        let failures=state.preview.iter().filter(|line| {
            let row:Value=serde_json::from_str(line).unwrap();row["stage"]=="input-preflight" && row["status"]=="failed"
        }).count();
        assert_eq!(failures,2);assert_eq!(fs::read(a).unwrap(),b"broken-a");assert_eq!(fs::read(b).unwrap(),b"broken-b");
    }
    #[cfg(unix)]
    #[test]
    fn export_refuses_symlinked_log_and_keeps_its_target() {
        let root=tempfile::tempdir().unwrap(); let outside=root.path().join("private"); fs::write(&outside,b"never export").unwrap();
        std::os::unix::fs::symlink(&outside,root.path().join(format!("attempt-{}.jsonl",uuid::Uuid::new_v4()))).unwrap();
        assert!(export_at(root.path()).is_err()); assert_eq!(fs::read(outside).unwrap(),b"never export");
    }
}
