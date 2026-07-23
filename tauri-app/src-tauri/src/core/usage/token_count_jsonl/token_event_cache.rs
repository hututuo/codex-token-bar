use super::{
    session_parser::{
        parse_session_file_full_result_limited, parse_session_file_range_limited,
        ForkReplayState, UsageSnapshotFingerprint, RECENT_USAGE_FINGERPRINT_LIMIT,
    },
    TokenEvent, UsageScanLimitError, MAX_REFRESH_EVENT_COUNT,
};
use crate::core::app_paths;
use crate::core::atomic_file;
use crate::models::LocalDataWarning;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use time::OffsetDateTime;

// Version 11 invalidates shards written before bounded fingerprint retention.
const TOKEN_EVENT_CACHE_VERSION: u32 = 11;
const STALE_TEMP_MIN_AGE: Duration = Duration::from_secs(24 * 60 * 60);
const SHARD_CHECKPOINT_INTERVAL: Duration = Duration::from_secs(15 * 60);
const SHARD_TARGET_DAILY_WRITE_BYTES: u64 = 256 * 1024 * 1024;
const MAX_CACHE_SHARD_BYTES: u64 = 32 * 1024 * 1024;
const MAX_CACHE_SHARD_COUNT: usize = 10_000;
const MAX_CACHE_FINGERPRINT_COUNT: usize = MAX_REFRESH_EVENT_COUNT;

pub(super) type SessionShardKey = (String, String);

pub(super) struct TokenEventCacheIoLock {
    _file: File,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct TokenEventCache {
    version: u32,
    pub(super) homes: HashMap<String, CachedCodexHome>,
}

impl Default for TokenEventCache {
    fn default() -> Self {
        Self {
            version: TOKEN_EVENT_CACHE_VERSION,
            homes: HashMap::new(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct CachedCodexHome {
    pub(super) codex_home: String,
    pub(super) files: HashMap<String, CachedSessionFile>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(super) struct CachedFileSignature {
    pub(super) size: u64,
    pub(super) modified_millis: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct CachedSessionFile {
    pub(super) signature: CachedFileSignature,
    #[serde(default)]
    pub(super) parsed_size: u64,
    #[serde(default = "default_true")]
    pub(super) ended_with_newline: bool,
    #[serde(default)]
    pub(super) previous_total_tokens: Option<u64>,
    #[serde(default)]
    pub(super) fork_replay_active: bool,
    #[serde(default)]
    pub(super) last_skipped_fork_replay_token_at: Option<i64>,
    #[serde(default)]
    pub(super) recent_usage_fingerprints: Vec<UsageSnapshotFingerprint>,
    pub(super) events: Vec<CachedTokenEvent>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PersistentSessionShard {
    version: u32,
    home_key: String,
    codex_home: String,
    cache_key: String,
    session: CachedSessionFile,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct CachedTokenEvent {
    pub(super) timestamp_unix: i64,
    pub(super) tokens: u64,
    pub(super) input_tokens: u64,
    pub(super) cached_input_tokens: u64,
    #[serde(default)]
    pub(super) output_tokens: u64,
}

impl TokenEventCache {
    pub(super) fn acquire_io_lock() -> Result<Option<TokenEventCacheIoLock>, String> {
        let Some(directory) = app_paths::token_event_cache_directory() else {
            return Ok(None);
        };
        let parent = directory
            .parent()
            .ok_or_else(|| format!("精确 token 缓存目录缺少父目录：{}", directory.display()))?;
        fs::create_dir_all(parent).map_err(|error| {
            format!(
                "创建精确 token 缓存锁目录失败：{}（{}）",
                parent.display(),
                error
            )
        })?;
        let lock_path = parent.join("session-token-events.lock");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .open(&lock_path)
            .map_err(|error| {
                format!(
                    "打开精确 token 缓存锁失败：{}（{}）",
                    lock_path.display(),
                    error
                )
            })?;
        lock_file_exclusive(&file).map_err(|error| {
            format!(
                "获取精确 token 缓存跨进程锁失败：{}（{}）",
                lock_path.display(),
                error
            )
        })?;
        Ok(Some(TokenEventCacheIoLock { _file: file }))
    }

    pub(super) fn cleanup_stale_temps() {
        if let Some(directory) = app_paths::token_event_cache_directory() {
            cleanup_stale_legacy_temp_directories(&directory);
        }
    }

    pub(super) fn load(warnings: &mut Vec<LocalDataWarning>) -> Self {
        if let Some(cache) = Self::load_sharded(warnings) {
            return cache;
        }

        Self::default()
    }

    pub(super) fn load_for_home(codex_home: &Path, warnings: &mut Vec<LocalDataWarning>) -> Self {
        if let Some(cache) = Self::load_sharded_for_home(codex_home, warnings) {
            return cache;
        }

        Self::default()
    }

    pub(super) fn save(&self) -> Result<(), String> {
        if let Some(directory) = app_paths::token_event_cache_directory() {
            let dirty = self
                .homes
                .iter()
                .flat_map(|(home_key, home)| {
                    home.files
                        .keys()
                        .map(|cache_key| (home_key.clone(), cache_key.clone()))
                })
                .collect::<HashSet<_>>();
            let deleted = self.persisted_shards_missing_from_memory(&directory);
            return self.save_sharded_changes(&directory, &dirty, &deleted, false);
        }

        let Some(path) = app_paths::token_event_cache_path() else {
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                format!(
                    "创建精确 token 缓存目录失败：{}（{}）",
                    parent.display(),
                    error
                )
            })?;
        }
        let data = serde_json::to_vec(self)
            .map_err(|error| format!("序列化精确 token 缓存失败：{error}"))?;
        let temp_path = unique_temp_path(&path, "json.tmp");
        fs::write(&temp_path, data).map_err(|error| {
            format!(
                "写入精确 token 缓存失败：{}（{}）",
                temp_path.display(),
                error
            )
        })?;
        fs::rename(&temp_path, &path)
            .map_err(|error| format!("替换精确 token 缓存失败：{}（{}）", path.display(), error))
    }

    fn load_sharded(warnings: &mut Vec<LocalDataWarning>) -> Option<Self> {
        let directory = app_paths::token_event_cache_directory()?;
        Self::load_sharded_from(&directory, None, warnings)
    }

    fn load_sharded_for_home(codex_home: &Path, warnings: &mut Vec<LocalDataWarning>) -> Option<Self> {
        let directory = app_paths::token_event_cache_directory()?;
        let home_key = codex_home_cache_key(codex_home);
        Self::load_sharded_from(&directory, Some(&home_key), warnings)
    }

    fn load_sharded_from(
        directory: &Path,
        home_key_filter: Option<&str>,
        warnings: &mut Vec<LocalDataWarning>,
    ) -> Option<Self> {
        let root = home_key_filter
            .map(|home_key| directory.join(home_key))
            .unwrap_or_else(|| directory.to_path_buf());
        let mut shards = Vec::new();
        if !collect_json_files_bounded(&root, &mut shards, MAX_CACHE_SHARD_COUNT) {
            warnings.push(token_cache_warning(format!(
                "精确 token 分片缓存数量超过安全上限（{} 个），本次忽略缓存并重新建立",
                MAX_CACHE_SHARD_COUNT
            )));
            return Some(Self::default());
        }
        if shards.is_empty() {
            return None;
        }

        let mut cache = Self::default();
        let mut cached_event_count = 0usize;
        let mut cached_fingerprint_count = 0usize;
        for shard in shards {
            let metadata = match fs::metadata(&shard) {
                Ok(metadata) => metadata,
                Err(error) => {
                    warnings.push(token_cache_warning(format!(
                        "读取精确 token 分片缓存元数据失败：{}（{}）",
                        shard.display(),
                        error
                    )));
                    continue;
                }
            };
            if metadata.len() > MAX_CACHE_SHARD_BYTES {
                warnings.push(token_cache_warning(format!(
                    "精确 token 分片缓存超过单分片安全上限（{} MiB）：{}，已忽略",
                    MAX_CACHE_SHARD_BYTES / 1024 / 1024,
                    shard.display()
                )));
                continue;
            }
            if !shard_file_has_current_version(&shard) {
                continue;
            }
            let data = match fs::read(&shard) {
                Ok(data) => data,
                Err(error) => {
                    warnings.push(token_cache_warning(format!(
                        "读取精确 token 分片缓存失败：{}（{}）",
                        shard.display(),
                        error
                    )));
                    continue;
                }
            };
            let shard = match serde_json::from_slice::<PersistentSessionShard>(&data) {
                Ok(shard) if shard.version == TOKEN_EVENT_CACHE_VERSION => shard,
                Ok(_) => continue,
                Err(error) => {
                    warnings.push(token_cache_warning(format!(
                        "精确 token 分片缓存不是有效 JSON：{}（{}）",
                        shard.display(),
                        error
                    )));
                    continue;
                }
            };
            if home_key_filter.is_some_and(|home_key| shard.home_key != home_key) {
                continue;
            }
            let shard_event_count = shard.session.events.len();
            let next_event_count = cached_event_count.saturating_add(shard_event_count);
            if next_event_count > MAX_REFRESH_EVENT_COUNT {
                warnings.push(token_cache_warning(format!(
                    "精确 token 分片缓存超过事件保留上限（{} 条），本次忽略缓存并重新建立",
                    MAX_REFRESH_EVENT_COUNT
                )));
                return Some(Self::default());
            }
            cached_event_count = next_event_count;
            let shard_fingerprint_count = shard.session.recent_usage_fingerprints.len();
            let next_fingerprint_count =
                cached_fingerprint_count.saturating_add(shard_fingerprint_count);
            if shard_fingerprint_count > RECENT_USAGE_FINGERPRINT_LIMIT
                || next_fingerprint_count > MAX_CACHE_FINGERPRINT_COUNT
            {
                warnings.push(token_cache_warning(format!(
                    "精确 token 分片缓存超过指纹保留上限（单会话 {} 条、总计 {} 条），本次忽略缓存并重新建立",
                    RECENT_USAGE_FINGERPRINT_LIMIT,
                    MAX_CACHE_FINGERPRINT_COUNT
                )));
                return Some(Self::default());
            }
            cached_fingerprint_count = next_fingerprint_count;
            let home = cache
                .homes
                .entry(shard.home_key)
                .or_insert_with(|| CachedCodexHome {
                    codex_home: shard.codex_home.clone(),
                    files: HashMap::new(),
                });
            home.codex_home = shard.codex_home;
            home.files.insert(shard.cache_key, shard.session);
        }

        Some(cache)
    }

    pub(super) fn save_changes(
        &self,
        dirty: &HashSet<SessionShardKey>,
        deleted: &HashSet<SessionShardKey>,
    ) -> Result<(), String> {
        let Some(directory) = app_paths::token_event_cache_directory() else {
            return Ok(());
        };
        self.save_sharded_changes(&directory, dirty, deleted, true)
    }

    fn save_sharded_changes(
        &self,
        directory: &Path,
        dirty: &HashSet<SessionShardKey>,
        deleted: &HashSet<SessionShardKey>,
        throttle_existing_shards: bool,
    ) -> Result<(), String> {
        fs::create_dir_all(directory).map_err(|error| {
            format!(
                "创建精确 token 分片缓存目录失败：{}（{}）",
                directory.display(),
                error
            )
        })?;

        for (home_key, cache_key) in dirty {
            let Some(home) = self.homes.get(home_key) else {
                continue;
            };
            let Some(session) = home.files.get(cache_key) else {
                continue;
            };
            let home_directory = directory.join(home_key);
            fs::create_dir_all(&home_directory).map_err(|error| {
                format!(
                    "创建精确 token 分片缓存目录失败：{}（{}）",
                    home_directory.display(),
                    error
                )
            })?;
            let path = shard_path(directory, home_key, cache_key);
            if throttle_existing_shards && !shard_checkpoint_due(&path, SystemTime::now()) {
                continue;
            }
            let shard = PersistentSessionShard {
                version: TOKEN_EVENT_CACHE_VERSION,
                home_key: home_key.clone(),
                codex_home: home.codex_home.clone(),
                cache_key: cache_key.clone(),
                session: session.clone(),
            };
            let data = serde_json::to_vec(&shard)
                .map_err(|error| format!("序列化精确 token 分片缓存失败：{error}"))?;
            atomic_file::write_atomically(&path, &data).map_err(|error| error.to_string())?;
        }

        for (home_key, cache_key) in deleted {
            remove_shard_if_identity_matches(directory, home_key, cache_key)?;
        }

        if let Some(legacy_path) = app_paths::token_event_cache_path() {
            let _ = fs::remove_file(legacy_path);
        }
        Ok(())
    }

    fn persisted_shards_missing_from_memory(&self, directory: &Path) -> HashSet<SessionShardKey> {
        let mut shard_paths = Vec::new();
        if !collect_json_files_bounded(directory, &mut shard_paths, MAX_CACHE_SHARD_COUNT) {
            return HashSet::new();
        }
        shard_paths
            .into_iter()
            .filter(|path| {
                fs::metadata(path)
                    .map(|metadata| metadata.len() <= MAX_CACHE_SHARD_BYTES)
                    .unwrap_or(false)
            })
            .filter(|path| shard_file_has_current_version(path))
            .filter_map(|path| fs::read(path).ok())
            .filter_map(|data| serde_json::from_slice::<PersistentSessionShard>(&data).ok())
            .filter(|shard| shard.version == TOKEN_EVENT_CACHE_VERSION)
            .filter_map(|shard| {
                (!self
                    .homes
                    .get(&shard.home_key)
                    .is_some_and(|home| home.files.contains_key(&shard.cache_key)))
                .then_some((shard.home_key, shard.cache_key))
            })
            .collect()
    }

    pub(super) fn home_cache_mut(
        &mut self,
        home_key: &str,
        codex_home: &Path,
    ) -> &mut CachedCodexHome {
        let identity = codex_home_identity(codex_home);
        let home = self
            .homes
            .entry(home_key.to_string())
            .or_insert_with(|| CachedCodexHome {
                codex_home: identity.clone(),
                files: HashMap::new(),
            });
        if home.codex_home != identity {
            home.codex_home = identity;
        }
        home
    }
}

impl CachedCodexHome {
    pub(super) fn remove_unseen(&mut self, seen: &HashSet<String>) -> HashSet<String> {
        let removed = self
            .files
            .keys()
            .filter(|path| !seen.contains(*path))
            .cloned()
            .collect::<HashSet<_>>();
        self.files.retain(|path, _| seen.contains(path));
        removed
    }

    pub(super) fn retain_seen(&mut self, seen: &HashSet<String>) -> bool {
        !self.remove_unseen(seen).is_empty()
    }
}

pub(super) fn parse_session_file_cached(
    file: &Path,
    session_id: &str,
    files: &mut HashMap<String, CachedSessionFile>,
    cache_changed: &mut bool,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Vec<TokenEvent> {
    parse_session_file_cached_limited(
        file,
        session_id,
        files,
        cache_changed,
        codex_home,
        match file_signature(file) {
            Some(signature) => signature,
            None => {
                warnings.push(token_cache_warning(format!(
                    "无法确认会话文件大小：{}",
                    file.display()
                )));
                return Vec::new();
            }
        },
        u64::MAX,
        usize::MAX,
        usize::MAX,
        warnings,
    )
    .unwrap_or_else(|error| {
        warnings.push(token_cache_warning(error.message));
        Vec::new()
    })
}

pub(super) fn parse_session_file_cached_limited(
    file: &Path,
    session_id: &str,
    files: &mut HashMap<String, CachedSessionFile>,
    cache_changed: &mut bool,
    codex_home: &Path,
    expected_signature: CachedFileSignature,
    source_read_limit: u64,
    line_limit: usize,
    event_limit: usize,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<Vec<TokenEvent>, UsageScanLimitError> {
    let cache_key = file_cache_key(codex_home, file);

    if let Some(entry) = files.get(&cache_key) {
        if entry.signature == expected_signature && entry.is_complete_and_safe_to_reuse() {
            return Ok(entry.to_events(session_id));
        }
    }

    if let Some(entry) = files.get_mut(&cache_key) {
        let parsed_size = entry.effective_parsed_size();
        if expected_signature.size >= parsed_size
            && expected_signature.size >= entry.signature.size
            && parsed_size > 0
            && entry.ended_with_newline
            && entry.has_plausible_token_events()
        {
            let previous_total_tokens = entry.effective_previous_total_tokens();
            let parsed = parse_session_file_range_limited(
                file,
                session_id,
                parsed_size,
                previous_total_tokens,
                entry.fork_replay_state(),
                Some(&entry.recent_usage_fingerprints),
                source_read_limit,
                line_limit,
                event_limit,
                warnings,
            );
            if let Some(error) = parsed.limit_exceeded {
                return Err(UsageScanLimitError::new(error));
            }
            ensure_file_signature_matches(file, &expected_signature)?;
            if parsed.consumed_size > parsed_size || expected_signature.size == parsed_size {
                let overlaps_cached_events = parsed.events.first().is_some_and(|first| {
                    entry
                        .events
                        .last()
                        .is_some_and(|last| first.timestamp.unix_timestamp() <= last.timestamp_unix)
                });
                if !overlaps_cached_events {
                    entry
                        .events
                        .extend(parsed.events.iter().map(CachedTokenEvent::from_event));
                    entry.signature = expected_signature;
                    entry.parsed_size = parsed.consumed_size;
                    entry.ended_with_newline = parsed.ended_with_newline;
                    entry.previous_total_tokens = parsed.previous_total_tokens;
                    entry.fork_replay_active = parsed.fork_replay_active;
                    entry.last_skipped_fork_replay_token_at = parsed
                        .last_skipped_fork_replay_token_at
                        .map(|timestamp| timestamp.unix_timestamp());
                    entry.recent_usage_fingerprints = parsed.recent_usage_fingerprints;
                    *cache_changed = true;
                    return Ok(entry.to_events(session_id));
                }
            } else if !parsed.ended_with_newline {
                return Ok(entry.to_events(session_id));
            }
        }
    }

    reparse_session_file(
        file,
        session_id,
        files,
        cache_key,
        expected_signature,
        cache_changed,
        source_read_limit,
        line_limit,
        event_limit,
        warnings,
    )
}

fn reparse_session_file(
    file: &Path,
    session_id: &str,
    files: &mut HashMap<String, CachedSessionFile>,
    cache_key: String,
    signature: CachedFileSignature,
    cache_changed: &mut bool,
    source_read_limit: u64,
    line_limit: usize,
    event_limit: usize,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<Vec<TokenEvent>, UsageScanLimitError> {
    let parsed = parse_session_file_full_result_limited(
        file,
        session_id,
        source_read_limit,
        line_limit,
        event_limit,
        warnings,
    );
    if let Some(error) = parsed.limit_exceeded {
        return Err(UsageScanLimitError::new(error));
    }
    ensure_file_signature_matches(file, &signature)?;
    let events = parsed.events;
    files.insert(
        cache_key,
        CachedSessionFile {
            signature,
            parsed_size: parsed.consumed_size,
            ended_with_newline: parsed.ended_with_newline,
            previous_total_tokens: parsed.previous_total_tokens,
            fork_replay_active: parsed.fork_replay_active,
            last_skipped_fork_replay_token_at: parsed
                .last_skipped_fork_replay_token_at
                .map(|timestamp| timestamp.unix_timestamp()),
            recent_usage_fingerprints: parsed.recent_usage_fingerprints,
            events: events.iter().map(CachedTokenEvent::from_event).collect(),
        },
    );
    *cache_changed = true;
    Ok(events)
}

impl CachedSessionFile {
    fn source_bytes_needed(&self, signature: CachedFileSignature) -> u64 {
        if self.signature == signature && self.is_complete_and_safe_to_reuse() {
            return 0;
        }
        let parsed_size = self.effective_parsed_size();
        if signature.size >= parsed_size
            && signature.size >= self.signature.size
            && parsed_size > 0
            && self.ended_with_newline
            && self.has_plausible_token_events()
        {
            return signature.size.saturating_sub(parsed_size);
        }
        signature.size
    }

    fn to_events(&self, session_id: &str) -> Vec<TokenEvent> {
        self.events
            .iter()
            .filter_map(|event| event.to_event(session_id))
            .collect()
    }

    fn effective_parsed_size(&self) -> u64 {
        if self.parsed_size > 0 {
            self.parsed_size
        } else {
            self.signature.size
        }
    }

    fn effective_previous_total_tokens(&self) -> Option<u64> {
        self.previous_total_tokens.or_else(|| {
            Some(
                self.events
                    .iter()
                    .fold(0u64, |total, event| total.saturating_add(event.tokens)),
            )
        })
    }

    fn fork_replay_state(&self) -> Option<ForkReplayState> {
        Some(ForkReplayState {
            active: self.fork_replay_active,
            last_skipped_token_at: self
                .last_skipped_fork_replay_token_at
                .and_then(|timestamp| OffsetDateTime::from_unix_timestamp(timestamp).ok()),
        })
    }

    fn is_complete_and_safe_to_reuse(&self) -> bool {
        self.parsed_size > 0
            && self.parsed_size >= self.signature.size
            && self.has_plausible_token_events()
    }

    fn has_plausible_token_events(&self) -> bool {
        self.parsed_size > 0
            && self
                .events
                .iter()
                .all(CachedTokenEvent::has_plausible_token_total)
    }
}

pub(super) fn cached_source_bytes_needed(
    entry: Option<&CachedSessionFile>,
    signature: CachedFileSignature,
) -> u64 {
    entry
        .map(|entry| entry.source_bytes_needed(signature.clone()))
        .unwrap_or(signature.size)
}

pub(super) fn cached_reusable_event_count(
    entry: Option<&CachedSessionFile>,
    signature: CachedFileSignature,
) -> Option<usize> {
    entry
        .filter(|entry| entry.signature == signature && entry.is_complete_and_safe_to_reuse())
        .map(|entry| entry.events.len())
}

pub(super) fn cached_event_count(entry: Option<&CachedSessionFile>) -> usize {
    entry.map_or(0, |entry| entry.events.len())
}

fn ensure_file_signature_matches(
    file: &Path,
    expected_signature: &CachedFileSignature,
) -> Result<(), UsageScanLimitError> {
    if file_signature(file).as_ref() != Some(expected_signature) {
        return Err(UsageScanLimitError::new(format!(
            "会话文件在读取期间发生变化：{}",
            file.display()
        )));
    }
    Ok(())
}

impl CachedTokenEvent {
    fn from_event(event: &TokenEvent) -> Self {
        Self {
            timestamp_unix: event.timestamp.unix_timestamp(),
            tokens: event.tokens,
            input_tokens: event.input_tokens,
            cached_input_tokens: event.cached_input_tokens,
            output_tokens: event.output_tokens,
        }
    }

    fn to_event(&self, session_id: &str) -> Option<TokenEvent> {
        Some(TokenEvent {
            timestamp: OffsetDateTime::from_unix_timestamp(self.timestamp_unix).ok()?,
            session_id: session_id.to_string(),
            tokens: self.tokens,
            input_tokens: self.input_tokens,
            cached_input_tokens: self.cached_input_tokens,
            output_tokens: self.output_tokens,
            user_prompt: String::new(),
            assistant_response: String::new(),
        })
    }

    fn has_plausible_token_total(&self) -> bool {
        let visible_total = self.input_tokens.saturating_add(self.output_tokens);
        let slack = visible_total.saturating_mul(4).max(1_000_000);
        self.tokens <= visible_total.saturating_add(slack)
    }
}

pub(super) fn file_signature(file: &Path) -> Option<CachedFileSignature> {
    let metadata = fs::metadata(file).ok()?;
    let modified = metadata.modified().ok()?;
    let modified_millis = modified.duration_since(UNIX_EPOCH).ok()?.as_millis();
    Some(CachedFileSignature {
        size: metadata.len(),
        modified_millis: u64::try_from(modified_millis).unwrap_or(u64::MAX),
    })
}

pub(super) fn file_cache_key(codex_home: &Path, file: &Path) -> String {
    file.strip_prefix(codex_home)
        .unwrap_or(file)
        .to_string_lossy()
        .into_owned()
}

pub(super) fn codex_home_cache_key(codex_home: &Path) -> String {
    stable_path_fingerprint(&codex_home_identity(codex_home))
}

fn codex_home_identity(codex_home: &Path) -> String {
    fs::canonicalize(codex_home)
        .unwrap_or_else(|_| codex_home.to_path_buf())
        .to_string_lossy()
        .into_owned()
}

fn stable_path_fingerprint(value: &str) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

fn unique_temp_path(path: &Path, label: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let suffix = format!("{label}-{}-{nanos}", std::process::id());
    path.with_extension(suffix)
}

fn shard_path(directory: &Path, home_key: &str, cache_key: &str) -> PathBuf {
    directory
        .join(home_key)
        .join(format!("{}.json", stable_path_fingerprint(cache_key)))
}

fn shard_checkpoint_due(path: &Path, now: SystemTime) -> bool {
    if !shard_file_has_current_version(path) {
        return true;
    }
    let Some(metadata) = fs::metadata(path).ok() else {
        return true;
    };
    let Some(modified) = metadata.modified().ok() else {
        return true;
    };
    now.duration_since(modified)
        .is_ok_and(|age| age >= shard_checkpoint_interval(metadata.len()))
}

pub(super) fn shard_checkpoint_interval(persisted_bytes: u64) -> Duration {
    let proportional_seconds = persisted_bytes
        .saturating_mul(24 * 60 * 60)
        .saturating_add(SHARD_TARGET_DAILY_WRITE_BYTES - 1)
        / SHARD_TARGET_DAILY_WRITE_BYTES;
    SHARD_CHECKPOINT_INTERVAL.max(Duration::from_secs(proportional_seconds))
}

fn shard_file_has_current_version(path: &Path) -> bool {
    let Ok(file) = File::open(path) else {
        return false;
    };
    let mut prefix = Vec::with_capacity(256);
    if file.take(256).read_to_end(&mut prefix).is_err() {
        return false;
    }
    let needle = format!(r#""version":{TOKEN_EVENT_CACHE_VERSION}"#);
    String::from_utf8_lossy(&prefix).contains(&needle)
}

fn remove_shard_if_identity_matches(
    directory: &Path,
    home_key: &str,
    cache_key: &str,
) -> Result<(), String> {
    let path = shard_path(directory, home_key, cache_key);
    let metadata = match fs::metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(format!(
                "读取待删除精确 token 分片元数据失败：{}（{}）",
                path.display(),
                error
            ))
        }
    };
    if metadata.len() > MAX_CACHE_SHARD_BYTES {
        return Err(format!(
            "待删除精确 token 分片超过安全上限（{} MiB）：{}",
            MAX_CACHE_SHARD_BYTES / 1024 / 1024,
            path.display()
        ));
    }
    let data = match fs::read(&path) {
        Ok(data) => data,
        Err(error) => {
            return Err(format!(
                "读取待删除精确 token 分片失败：{}（{}）",
                path.display(),
                error
            ))
        }
    };
    let matches = serde_json::from_slice::<PersistentSessionShard>(&data).is_ok_and(|shard| {
        shard.version == TOKEN_EVENT_CACHE_VERSION
            && shard.home_key == home_key
            && shard.cache_key == cache_key
    });
    if !matches {
        return Ok(());
    }
    fs::remove_file(&path).map_err(|error| {
        format!(
            "删除过期精确 token 分片失败：{}（{}）",
            path.display(),
            error
        )
    })
}

fn cleanup_stale_legacy_temp_directories(directory: &Path) {
    let Some(parent) = directory.parent() else {
        return;
    };
    let Some(directory_name) = directory.file_name().and_then(|name| name.to_str()) else {
        return;
    };
    let prefix = format!("{directory_name}.tmp-");
    let Ok(entries) = fs::read_dir(parent) else {
        return;
    };
    let now = SystemTime::now();
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        let Some(owner_pid) = owned_legacy_temp_pid(name, &prefix) else {
            continue;
        };
        let is_stale_directory = fs::symlink_metadata(&path)
            .ok()
            .filter(|metadata| metadata.file_type().is_dir())
            .and_then(|metadata| metadata.modified().ok())
            .and_then(|modified| now.duration_since(modified).ok())
            .is_some_and(|age| age >= STALE_TEMP_MIN_AGE);
        if is_stale_directory && !process_is_alive(owner_pid) {
            let _ = fs::remove_dir_all(path);
        }
    }
}

fn owned_legacy_temp_pid(name: &str, prefix: &str) -> Option<u32> {
    let Some(suffix) = name.strip_prefix(prefix) else {
        return None;
    };
    let Some((pid, nanos)) = suffix.split_once('-') else {
        return None;
    };
    let valid = !pid.is_empty()
        && !nanos.is_empty()
        && pid.bytes().all(|byte| byte.is_ascii_digit())
        && nanos.bytes().all(|byte| byte.is_ascii_digit());
    valid.then(|| pid.parse().ok()).flatten()
}

#[cfg(unix)]
fn process_is_alive(pid: u32) -> bool {
    unsafe extern "C" {
        fn kill(pid: i32, signal: i32) -> i32;
    }
    let Ok(pid) = i32::try_from(pid) else {
        return false;
    };
    let result = unsafe { kill(pid, 0) };
    result == 0 || std::io::Error::last_os_error().raw_os_error() != Some(3)
}

#[cfg(windows)]
fn process_is_alive(pid: u32) -> bool {
    use windows_sys::Win32::Foundation::{CloseHandle, STILL_ACTIVE};
    use windows_sys::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if process.is_null() {
        return std::io::Error::last_os_error().raw_os_error()
            != Some(windows_sys::Win32::Foundation::ERROR_INVALID_PARAMETER as i32);
    }
    let mut exit_code = 0;
    let queried = unsafe { GetExitCodeProcess(process, &mut exit_code) } != 0;
    let alive = !queried || exit_code == STILL_ACTIVE as u32;
    unsafe {
        CloseHandle(process);
    }
    alive
}

#[cfg(not(any(unix, windows)))]
fn process_is_alive(_pid: u32) -> bool {
    true
}

#[cfg(unix)]
fn lock_file_exclusive(file: &File) -> std::io::Result<()> {
    rustix::fs::flock(file, rustix::fs::FlockOperation::NonBlockingLockExclusive)
        .map_err(std::io::Error::from)
}

#[cfg(windows)]
fn lock_file_exclusive(file: &File) -> std::io::Result<()> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        LockFileEx, LOCKFILE_EXCLUSIVE_LOCK, LOCKFILE_FAIL_IMMEDIATELY,
    };
    use windows_sys::Win32::System::IO::OVERLAPPED;
    let mut overlapped = OVERLAPPED::default();
    let ok = unsafe {
        LockFileEx(
            file.as_raw_handle() as _,
            LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
            0,
            u32::MAX,
            u32::MAX,
            &mut overlapped,
        )
    };
    if ok == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(not(any(unix, windows)))]
fn lock_file_exclusive(_file: &File) -> std::io::Result<()> {
    Ok(())
}

fn collect_json_files_bounded(root: &Path, files: &mut Vec<PathBuf>, limit: usize) -> bool {
    let mut visited_directories = HashSet::new();
    collect_json_files_bounded_inner(root, files, limit, &mut visited_directories)
}

fn collect_json_files_bounded_inner(
    root: &Path,
    files: &mut Vec<PathBuf>,
    limit: usize,
    visited_directories: &mut HashSet<PathBuf>,
) -> bool {
    let directory_key = fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
    if !visited_directories.insert(directory_key) {
        return true;
    }
    let Ok(entries) = fs::read_dir(root) else {
        return true;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if metadata.file_type().is_dir() {
            if !collect_json_files_bounded_inner(&path, files, limit, visited_directories) {
                return false;
            }
        } else if path
            .extension()
            .is_some_and(|extension| extension == "json")
        {
            if files.len() >= limit {
                return false;
            }
            files.push(path);
        }
    }
    true
}

fn default_true() -> bool {
    true
}

pub(super) fn token_cache_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "token_event_cache".into(),
        message,
    }
}
