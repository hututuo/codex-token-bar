//! Bounded, metadata-only model lookup for observed-speed samples.
//!
//! Lookups are keyed by the exact `(thread, turn)` pair from a rollout
//! `turn_context` record. Neighboring records are never used as a fallback.

use crate::core::shared_source_io::SourceReader;
use serde_json::Value;
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::{self, File, Metadata};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Instant, SystemTime};

const MAX_THREADS_PER_LOOKUP: usize = 8;
const MAX_FILES_PER_LOOKUP: usize = 16;
const MAX_BYTES_PER_LOOKUP: usize = 64 * 1024 * 1024;
const MAX_INITIAL_TAIL_PER_FILE: usize = 32 * 1024 * 1024;
const MAX_BYTES_PER_FILE_PER_LOOKUP: usize = 32 * 1024 * 1024;
const MAX_LINE_BYTES: usize = 1024 * 1024;
const MAX_MODELS_PER_FILE: usize = 256;
const MAX_TURNS_PER_THREAD: usize = 64;
const MAX_INDEXED_FILES: usize = 50_000;
const MAX_DIRECTORY_DEPTH: usize = 8;
const MAX_CACHED_HOMES: usize = 8;
const MAX_CACHED_FILES: usize = 128;
const DIRECTORY_INDEX_TTL_SECONDS: u64 = 10;
const MAX_SOURCE_JOBS: usize = 8;
const RETRY_AFTER_SECONDS: u64 = 30;

static MODEL_RESOLVER: OnceLock<Mutex<ModelResolver>> = OnceLock::new();
static JOB_MANAGER: OnceLock<Mutex<JobManager>> = OnceLock::new();

type Resolution = HashMap<String, HashMap<String, String>>;

#[derive(Default)]
struct ModelResolver {
    homes: HashMap<PathBuf, DirectoryIndex>,
    files: HashMap<PathBuf, FileCache>,
}

struct DirectoryIndex {
    refreshed_at: Instant,
    files: Vec<CandidateFile>,
}

#[derive(Clone)]
struct CandidateFile {
    path: PathBuf,
    modified: Option<SystemTime>,
}

#[derive(Clone)]
struct FileCache {
    identity: String,
    offset: u64,
    observed_size: u64,
    modified: Option<SystemTime>,
    carry: Vec<u8>,
    dropping_line: bool,
    models: HashMap<String, String>,
    model_order: VecDeque<String>,
}

#[derive(Default)]
struct JobManager {
    sources: HashMap<String, SourceJob>,
}

struct SourceJob {
    last_started: Option<Instant>,
    last_access: Instant,
    in_flight: bool,
    generation: u64,
    result: Option<Resolution>,
}

impl Default for SourceJob {
    fn default() -> Self {
        Self {
            last_started: None,
            last_access: Instant::now(),
            in_flight: false,
            generation: 0,
            result: None,
        }
    }
}

impl FileCache {
    fn new(identity: String) -> Self {
        Self {
            identity,
            offset: 0,
            observed_size: 0,
            modified: None,
            carry: Vec::new(),
            dropping_line: false,
            models: HashMap::new(),
            model_order: VecDeque::new(),
        }
    }

    fn remember(&mut self, turn: String, model: String) {
        if !self.models.contains_key(&turn) {
            self.model_order.push_back(turn.clone());
        }
        self.models.insert(turn, model);
        while self.model_order.len() > MAX_MODELS_PER_FILE {
            if let Some(oldest) = self.model_order.pop_front() {
                self.models.remove(&oldest);
            }
        }
    }
}

/// Polls a bounded worker for one physical source. Results arrive on a later
/// live-rate poll, so rollout IO never holds the live-rate store lock.
pub(super) fn poll(
    source_key: String,
    home: &Path,
    requested: &[(String, Vec<String>)],
) -> Resolution {
    if requested.is_empty() {
        return HashMap::new();
    }

    let manager = JOB_MANAGER.get_or_init(|| Mutex::new(JobManager::default()));
    let (result, generation) = {
        let mut manager = manager
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if !manager.sources.contains_key(&source_key) && manager.sources.len() >= MAX_SOURCE_JOBS {
            if let Some(oldest_idle) = manager
                .sources
                .iter()
                .filter(|(_, job)| !job.in_flight)
                .min_by_key(|(_, job)| job.last_access)
                .map(|(key, _)| key.clone())
            {
                manager.sources.remove(&oldest_idle);
            } else {
                return HashMap::new();
            }
        }
        let job = manager.sources.entry(source_key.clone()).or_default();
        job.last_access = Instant::now();
        let result = job.result.take().unwrap_or_default();
        let can_start = !job.in_flight
            && job
                .last_started
                .is_none_or(|started| started.elapsed().as_secs() >= RETRY_AFTER_SECONDS);
        let generation = if can_start {
            job.in_flight = true;
            job.generation = job.generation.saturating_add(1);
            job.last_started = Some(Instant::now());
            Some(job.generation)
        } else {
            None
        };
        (result, generation)
    };

    if let Some(generation) = generation {
        let key = source_key.clone();
        let home = home.to_path_buf();
        let requested = requested.to_vec();
        let spawn = thread::Builder::new()
            .name("speed-model-resolver".into())
            .spawn(move || {
                let result = resolve_now(&home, &requested);
                let manager = JOB_MANAGER.get().expect("job manager initialized");
                let mut manager = manager
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                if let Some(job) = manager.sources.get_mut(&key) {
                    if job.generation == generation {
                        job.in_flight = false;
                        job.result = Some(result);
                        job.last_access = Instant::now();
                    }
                }
            });
        if spawn.is_err() {
            let mut manager = manager
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if let Some(job) = manager.sources.get_mut(&source_key) {
                if job.generation == generation {
                    job.in_flight = false;
                }
            }
        }
    }

    result
}

pub(super) fn source_key(canonical_home: &str, physical_home: &str) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in format!("{canonical_home}\n{physical_home}").bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("speed-source-{hash:016x}")
}

fn resolve_now(home: &Path, requested: &[(String, Vec<String>)]) -> Resolution {
    let resolver = MODEL_RESOLVER.get_or_init(|| Mutex::new(ModelResolver::default()));
    resolver
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .resolve_inner(home, requested)
}

impl ModelResolver {
    fn resolve_inner(
        &mut self,
        home: &Path,
        requested: &[(String, Vec<String>)],
    ) -> HashMap<String, HashMap<String, String>> {
        let requests = requested
            .iter()
            .take(MAX_THREADS_PER_LOOKUP)
            .map(|(thread, turns)| {
                (
                    thread.clone(),
                    turns
                        .iter()
                        .filter(|turn| !turn.is_empty() && turn.len() <= 512)
                        .take(MAX_TURNS_PER_THREAD)
                        .cloned()
                        .collect::<HashSet<_>>(),
                )
            })
            .filter(|(thread, turns)| !thread.is_empty() && !turns.is_empty())
            .collect::<Vec<_>>();
        if requests.is_empty() {
            return HashMap::new();
        }

        let index_is_stale = self.homes.get(home).is_none_or(|index| {
            index.refreshed_at.elapsed().as_secs() >= DIRECTORY_INDEX_TTL_SECONDS
        });
        if index_is_stale {
            self.homes.insert(
                home.to_path_buf(),
                DirectoryIndex {
                    refreshed_at: Instant::now(),
                    files: collect_rollout_files(home),
                },
            );
        }
        if self.homes.len() > MAX_CACHED_HOMES {
            if let Some(oldest_other_home) = self
                .homes
                .iter()
                .filter(|(path, _)| path.as_path() != home)
                .min_by_key(|(_, index)| index.refreshed_at)
                .map(|(path, _)| path.clone())
            {
                self.homes.remove(&oldest_other_home);
            }
        }

        let indexed_files = self
            .homes
            .get(home)
            .map(|index| index.files.clone())
            .unwrap_or_default();
        let mut per_thread = Vec::<Vec<CandidateFile>>::with_capacity(requests.len());
        for (thread, _) in &requests {
            let mut candidates = indexed_files
                .iter()
                .filter(|candidate| {
                    candidate
                        .path
                        .file_name()
                        .is_some_and(|name| name.to_string_lossy().contains(thread))
                })
                .cloned()
                .collect::<Vec<_>>();
            candidates.sort_by(|left, right| {
                right
                    .modified
                    .cmp(&left.modified)
                    .then_with(|| left.path.cmp(&right.path))
            });
            per_thread.push(candidates);
        }

        // Take the newest file for each requested thread before considering an
        // older physical continuation file from any one thread.
        let mut next = vec![0usize; requests.len()];
        let mut selected_paths = HashSet::<PathBuf>::new();
        let mut selected = Vec::<(usize, CandidateFile)>::new();
        while selected.len() < MAX_FILES_PER_LOOKUP {
            let mut added = false;
            for (thread_index, candidates) in per_thread.iter().enumerate() {
                while next[thread_index] < candidates.len() {
                    let candidate = candidates[next[thread_index]].clone();
                    next[thread_index] += 1;
                    if selected_paths.insert(candidate.path.clone()) {
                        selected.push((thread_index, candidate));
                        added = true;
                        break;
                    }
                }
                if selected.len() >= MAX_FILES_PER_LOOKUP {
                    break;
                }
            }
            if !added {
                break;
            }
        }

        let per_thread_budget = (MAX_BYTES_PER_LOOKUP / requests.len()).max(1);
        let mut remaining = MAX_BYTES_PER_LOOKUP;
        let mut observed = HashMap::<(String, String), HashSet<String>>::new();
        for (thread_index, candidate) in &selected {
            if remaining == 0 {
                break;
            }
            let budget = remaining
                .min(per_thread_budget)
                .min(MAX_BYTES_PER_FILE_PER_LOOKUP);
            let Some(bytes_read) = self.scan_file(candidate, budget) else {
                continue;
            };
            remaining = remaining.saturating_sub(bytes_read);
            let (thread, turns) = &requests[*thread_index];
            if let Some(cache) = self.files.get(&candidate.path) {
                for turn in turns {
                    if let Some(model) = cache.models.get(turn) {
                        observed
                            .entry((thread.clone(), turn.clone()))
                            .or_default()
                            .insert(model.clone());
                    }
                }
            }
        }

        let mut resolved = HashMap::new();
        for ((thread, turn), models) in observed {
            // Continuation/fork files occasionally contain conflicting copies
            // of a turn. Leave those unresolved instead of picking one file.
            if models.len() == 1 {
                if let Some(model) = models.into_iter().next() {
                    resolved
                        .entry(thread)
                        .or_insert_with(HashMap::new)
                        .insert(turn, model);
                }
            }
        }

        if self.files.len() > MAX_CACHED_FILES {
            self.files.retain(|path, _| selected_paths.contains(path));
        }
        resolved
    }

    fn scan_file(&mut self, candidate: &CandidateFile, byte_budget: usize) -> Option<usize> {
        if byte_budget == 0 {
            return Some(0);
        }
        let Ok(file) = open_readonly(candidate.path.as_path()) else {
            return None;
        };
        let Ok(metadata) = file.metadata() else {
            return None;
        };
        if !metadata.is_file() {
            self.files.remove(&candidate.path);
            return None;
        }
        let size = metadata.len();
        let modified = metadata.modified().ok();
        let identity = file_identity(&file, &metadata);
        let mut entry = self
            .files
            .remove(&candidate.path)
            .unwrap_or_else(|| FileCache::new(identity.clone()));
        let original_entry = entry.clone();
        if entry.identity != identity
            || size < entry.offset
            || (size == entry.observed_size && modified != entry.modified)
        {
            entry = FileCache::new(identity);
        }
        if entry.offset == 0 && size > 0 {
            let initial_window = byte_budget.min(MAX_INITIAL_TAIL_PER_FILE) as u64;
            entry.offset = size.saturating_sub(initial_window);
            entry.dropping_line = entry.offset > 0;
        }
        if entry.offset > size {
            self.files.insert(candidate.path.clone(), original_entry);
            return None;
        }
        let mut source = match SourceReader::new(&file) {
            Ok(source) => source,
            Err(_) => {
                self.files.insert(candidate.path.clone(), original_entry);
                return None;
            }
        };
        if source.seek(SeekFrom::Start(entry.offset)).is_err() {
            self.files.insert(candidate.path.clone(), original_entry);
            return None;
        }

        let mut remaining = byte_budget.min(MAX_BYTES_PER_FILE_PER_LOOKUP);
        let mut bytes_read = 0usize;
        let mut chunk = [0u8; 64 * 1024];
        let mut read_failed = false;
        while remaining > 0 {
            let requested = chunk.len().min(remaining);
            let count = match source.read(&mut chunk[..requested]) {
                Ok(count) => count,
                Err(_) => {
                    read_failed = true;
                    break;
                }
            };
            if count == 0 {
                break;
            }
            bytes_read += count;
            remaining -= count;
            entry.offset = entry.offset.saturating_add(count as u64);
            entry.carry.extend_from_slice(&chunk[..count]);
            consume_lines(&mut entry);
        }
        if read_failed {
            self.files.insert(candidate.path.clone(), original_entry);
            return None;
        }
        entry.observed_size = size;
        entry.modified = modified;
        self.files.insert(candidate.path.clone(), entry);
        Some(bytes_read)
    }
}

fn collect_rollout_files(home: &Path) -> Vec<CandidateFile> {
    let mut files = Vec::new();
    for folder in ["sessions", "archived_sessions"] {
        let root = home.join(folder);
        walk_directory(&root, 0, &mut files);
        if files.len() >= MAX_INDEXED_FILES {
            break;
        }
    }
    files.sort_by(|left, right| {
        right
            .modified
            .cmp(&left.modified)
            .then_with(|| left.path.cmp(&right.path))
    });
    files
}

fn walk_directory(directory: &Path, depth: usize, files: &mut Vec<CandidateFile>) {
    if depth > MAX_DIRECTORY_DEPTH || files.len() >= MAX_INDEXED_FILES {
        return;
    }
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        if files.len() >= MAX_INDEXED_FILES {
            break;
        }
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_symlink() {
            continue;
        }
        let path = entry.path();
        if file_type.is_dir() {
            walk_directory(&path, depth + 1, files);
        } else if file_type.is_file()
            && path
                .extension()
                .is_some_and(|extension| extension == "jsonl")
        {
            let modified = entry
                .metadata()
                .ok()
                .and_then(|metadata| metadata.modified().ok());
            files.push(CandidateFile { path, modified });
        }
    }
}

fn consume_lines(entry: &mut FileCache) {
    while let Some(newline) = entry.carry.iter().position(|byte| *byte == b'\n') {
        if entry.dropping_line {
            entry.carry.drain(..=newline);
            entry.dropping_line = false;
            continue;
        }
        if newline <= MAX_LINE_BYTES
            && entry.carry[..newline]
                .windows(b"turn_context".len())
                .any(|window| window == b"turn_context")
        {
            if let Some((turn, model)) = parse_turn_context(&entry.carry[..newline]) {
                entry.remember(turn, model);
            }
        }
        entry.carry.drain(..=newline);
    }
    if entry.carry.len() > MAX_LINE_BYTES {
        entry.carry.clear();
        entry.dropping_line = true;
    }
}

fn parse_turn_context(line: &[u8]) -> Option<(String, String)> {
    let value = serde_json::from_slice::<Value>(line).ok()?;
    if value.get("type").and_then(Value::as_str) != Some("turn_context") {
        return None;
    }
    let payload = value.get("payload")?.as_object()?;
    let turn = payload.get("turn_id")?.as_str()?;
    let model = payload.get("model")?.as_str()?;
    if turn.is_empty()
        || turn.len() > 512
        || model.is_empty()
        || model.len() > 256
        || model == "unknown"
    {
        return None;
    }
    Some((turn.to_owned(), model.to_owned()))
}

fn open_readonly(path: &Path) -> std::io::Result<File> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        return fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        let file = fs::OpenOptions::new()
            .read(true)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .open(path)?;
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
        if file.metadata()?.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "rollout path is a reparse point",
            ));
        }
        return Ok(file);
    }
    #[cfg(not(any(unix, windows)))]
    {
        File::open(path)
    }
}

#[cfg(unix)]
fn file_identity(_file: &File, metadata: &Metadata) -> String {
    use std::os::unix::fs::MetadataExt;
    format!("unix:{}:{}", metadata.dev(), metadata.ino())
}

#[cfg(windows)]
fn file_identity(file: &File, _metadata: &Metadata) -> String {
    use std::{ffi::c_void, mem::MaybeUninit, os::windows::io::AsRawHandle};

    #[repr(C)]
    struct FileTime {
        low_date_time: u32,
        high_date_time: u32,
    }
    #[repr(C)]
    struct ByHandleFileInformation {
        file_attributes: u32,
        creation_time: FileTime,
        last_access_time: FileTime,
        last_write_time: FileTime,
        volume_serial_number: u32,
        file_size_high: u32,
        file_size_low: u32,
        number_of_links: u32,
        file_index_high: u32,
        file_index_low: u32,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GetFileInformationByHandle(
            file: *mut c_void,
            information: *mut ByHandleFileInformation,
        ) -> i32;
    }

    let mut information = MaybeUninit::<ByHandleFileInformation>::uninit();
    let result = unsafe {
        GetFileInformationByHandle(file.as_raw_handle().cast(), information.as_mut_ptr())
    };
    if result == 0 {
        return "windows:identity-unavailable".into();
    }
    let information = unsafe { information.assume_init() };
    let file_id =
        (u64::from(information.file_index_high) << 32) | u64::from(information.file_index_low);
    format!("windows:{}:{file_id}", information.volume_serial_number)
}

#[cfg(not(any(unix, windows)))]
fn file_identity(_file: &File, metadata: &Metadata) -> String {
    format!("fallback:{}:{:?}", metadata.len(), metadata.modified().ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::thread;
    use std::time::Duration;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_home(label: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let home = std::env::temp_dir().join(format!(
            "codex-speed-model-{label}-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(home.join("sessions/2026/10/20")).unwrap();
        fs::create_dir_all(home.join("archived_sessions/2026/10/20")).unwrap();
        home
    }

    fn rollout_path(home: &Path, folder: &str, file: &str) -> PathBuf {
        home.join(folder).join("2026/10/20").join(file)
    }

    fn context(turn: &str, model: &str) -> String {
        format!(
            "{{\"type\":\"turn_context\",\"payload\":{{\"turn_id\":\"{turn}\",\"model\":\"{model}\"}}}}\n"
        )
    }

    #[test]
    fn resolves_only_requested_exact_turn_context() {
        let home = temp_home("exact");
        let path = rollout_path(&home, "sessions", "rollout-thread-a.jsonl");
        fs::write(
            &path,
            format!(
                "{}{}",
                context("turn-a", "model-a"),
                context("turn-b", "model-b")
            ),
        )
        .unwrap();
        let mut resolver = ModelResolver::default();
        let found = resolver.resolve_inner(
            &home,
            &[("thread-a".into(), vec!["turn-b".into(), "missing".into()])],
        );
        assert_eq!(found["thread-a"]["turn-b"], "model-b");
        assert!(!found["thread-a"].contains_key("missing"));
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn conflicting_models_across_physical_files_remain_unresolved() {
        let home = temp_home("conflict");
        fs::write(
            rollout_path(&home, "sessions", "rollout-thread-a.jsonl"),
            context("turn-a", "model-new"),
        )
        .unwrap();
        fs::write(
            rollout_path(&home, "archived_sessions", "continuation-thread-a.jsonl"),
            context("turn-a", "model-old"),
        )
        .unwrap();
        let mut resolver = ModelResolver::default();
        let found = resolver.resolve_inner(&home, &[("thread-a".into(), vec!["turn-a".into()])]);
        assert!(!found
            .get("thread-a")
            .is_some_and(|turns| turns.contains_key("turn-a")));
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn appended_context_is_read_from_cached_offset() {
        let home = temp_home("append");
        let path = rollout_path(&home, "sessions", "rollout-thread-a.jsonl");
        fs::write(&path, context("turn-old", "model-old")).unwrap();
        let mut resolver = ModelResolver::default();
        let first = resolver.resolve_inner(&home, &[("thread-a".into(), vec!["turn-new".into()])]);
        assert!(!first.contains_key("thread-a"));
        {
            let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
            file.write_all(context("turn-new", "model-new").as_bytes())
                .unwrap();
        }
        let second = resolver.resolve_inner(&home, &[("thread-a".into(), vec!["turn-new".into()])]);
        assert_eq!(second["thread-a"]["turn-new"], "model-new");
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn asynchronous_lookup_is_exact_and_fenced_by_physical_source() {
        let home = temp_home("async");
        let path = rollout_path(&home, "sessions", "rollout-thread-a.jsonl");
        fs::write(
            &path,
            format!(
                "{}{}",
                context("turn-a", "model-a"),
                context("neighbor-turn", "neighbor-model")
            ),
        )
        .unwrap();
        let key_a = source_key(&home.display().to_string(), "physical-a");
        let key_b = source_key(&home.display().to_string(), "physical-b");
        let requested = vec![("thread-a".into(), vec!["turn-a".into(), "missing".into()])];
        assert!(poll(key_a.clone(), &home, &requested).is_empty());

        let mut first_result = HashMap::new();
        for _ in 0..200 {
            thread::sleep(Duration::from_millis(5));
            first_result = poll(key_a.clone(), &home, &requested);
            if first_result.contains_key("thread-a") {
                break;
            }
        }
        assert_eq!(first_result["thread-a"]["turn-a"], "model-a");
        assert!(!first_result["thread-a"].contains_key("missing"));

        // The same logical home under another physical source gets its own
        // resolver result. Remove the file so a leaked result would be visible.
        fs::remove_file(&path).unwrap();
        assert!(poll(key_b.clone(), &home, &requested).is_empty());
        let mut completed = false;
        for _ in 0..200 {
            thread::sleep(Duration::from_millis(5));
            let manager = JOB_MANAGER.get().unwrap();
            completed = manager
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .sources
                .get(&key_b)
                .is_some_and(|job| !job.in_flight && job.result.is_some());
            if completed {
                break;
            }
        }
        assert!(completed, "physical-source lookup should finish");
        assert!(poll(key_b, &home, &requested).is_empty());
        fs::remove_dir_all(home).unwrap();
    }
}
