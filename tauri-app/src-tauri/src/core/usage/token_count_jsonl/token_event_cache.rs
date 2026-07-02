use super::{
    session_parser::{parse_session_file, parse_session_file_full_result, parse_session_file_range},
    TokenEvent,
};
use crate::core::app_paths;
use crate::models::LocalDataWarning;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;
use time::OffsetDateTime;

const TOKEN_EVENT_CACHE_VERSION: u32 = 4;

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
    pub(super) fn load(warnings: &mut Vec<LocalDataWarning>) -> Self {
        if let Some(cache) = Self::load_sharded(warnings) {
            return cache;
        }

        Self::default()
    }

    pub(super) fn save(&self) -> Result<(), String> {
        if let Some(directory) = app_paths::token_event_cache_directory() {
            return self.save_sharded(&directory);
        }

        let Some(path) = app_paths::token_event_cache_path() else {
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                format!("创建精确 token 缓存目录失败：{}（{}）", parent.display(), error)
            })?;
        }
        let data = serde_json::to_vec(self)
            .map_err(|error| format!("序列化精确 token 缓存失败：{error}"))?;
        let temp_path = path.with_extension("json.tmp");
        fs::write(&temp_path, data).map_err(|error| {
            format!("写入精确 token 缓存失败：{}（{}）", temp_path.display(), error)
        })?;
        fs::rename(&temp_path, &path).map_err(|error| {
            format!("替换精确 token 缓存失败：{}（{}）", path.display(), error)
        })
    }

    fn load_sharded(warnings: &mut Vec<LocalDataWarning>) -> Option<Self> {
        let directory = app_paths::token_event_cache_directory()?;
        let mut shards = Vec::new();
        collect_json_files(&directory, &mut shards);
        if shards.is_empty() {
            return None;
        }

        let mut cache = Self::default();
        for shard in shards {
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

    fn save_sharded(&self, directory: &Path) -> Result<(), String> {
        let temp_directory = directory.with_extension("tmp");
        let _ = fs::remove_dir_all(&temp_directory);
        fs::create_dir_all(&temp_directory).map_err(|error| {
            format!(
                "创建精确 token 分片缓存目录失败：{}（{}）",
                temp_directory.display(),
                error
            )
        })?;

        for (home_key, home) in &self.homes {
            let home_directory = temp_directory.join(home_key);
            fs::create_dir_all(&home_directory).map_err(|error| {
                format!(
                    "创建精确 token 分片缓存目录失败：{}（{}）",
                    home_directory.display(),
                    error
                )
            })?;
            for (cache_key, session) in &home.files {
                let shard = PersistentSessionShard {
                    version: TOKEN_EVENT_CACHE_VERSION,
                    home_key: home_key.clone(),
                    codex_home: home.codex_home.clone(),
                    cache_key: cache_key.clone(),
                    session: session.clone(),
                };
                let data = serde_json::to_vec(&shard)
                    .map_err(|error| format!("序列化精确 token 分片缓存失败：{error}"))?;
                let path =
                    home_directory.join(format!("{}.json", stable_path_fingerprint(cache_key)));
                fs::write(&path, data).map_err(|error| {
                    format!("写入精确 token 分片缓存失败：{}（{}）", path.display(), error)
                })?;
            }
        }

        if directory.exists() {
            fs::remove_dir_all(directory).map_err(|error| {
                format!("清理旧精确 token 分片缓存失败：{}（{}）", directory.display(), error)
            })?;
        }
        fs::rename(&temp_directory, directory).map_err(|error| {
            format!(
                "替换精确 token 分片缓存失败：{}（{}）",
                directory.display(),
                error
            )
        })?;

        if let Some(legacy_path) = app_paths::token_event_cache_path() {
            let _ = fs::remove_file(legacy_path);
        }
        Ok(())
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
    pub(super) fn retain_seen(&mut self, seen: &HashSet<String>) -> bool {
        let before = self.files.len();
        self.files.retain(|path, _| seen.contains(path));
        before != self.files.len()
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
    let cache_key = file_cache_key(codex_home, file);
    let Some(signature) = file_signature(file) else {
        return parse_session_file(file, session_id, warnings);
    };

    if let Some(entry) = files.get(&cache_key) {
        if entry.signature == signature && entry.is_complete_and_safe_to_reuse() {
            return entry.to_events(session_id);
        }
    }

    if let Some(entry) = files.get_mut(&cache_key) {
        let parsed_size = entry.effective_parsed_size();
        if signature.size >= parsed_size
            && signature.size >= entry.signature.size
            && parsed_size > 0
            && entry.ended_with_newline
            && entry.has_plausible_token_events()
        {
            let previous_total_tokens = entry.effective_previous_total_tokens();
            let parsed = parse_session_file_range(
                file,
                session_id,
                parsed_size,
                previous_total_tokens,
                warnings,
            );
            if parsed.consumed_size > parsed_size || signature.size == parsed_size {
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
                    entry.signature = signature;
                    entry.parsed_size = parsed.consumed_size;
                    entry.ended_with_newline = parsed.ended_with_newline;
                    entry.previous_total_tokens = parsed.previous_total_tokens;
                    *cache_changed = true;
                    return entry.to_events(session_id);
                }
            } else if !parsed.ended_with_newline {
                return entry.to_events(session_id);
            }
        }
    }

    reparse_session_file(
        file,
        session_id,
        files,
        cache_key,
        signature,
        cache_changed,
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
    warnings: &mut Vec<LocalDataWarning>,
) -> Vec<TokenEvent> {
    let parsed = parse_session_file_full_result(file, session_id, warnings);
    let events = parsed.events;
    files.insert(
        cache_key,
        CachedSessionFile {
            signature,
            parsed_size: parsed.consumed_size,
            ended_with_newline: parsed.ended_with_newline,
            previous_total_tokens: parsed.previous_total_tokens,
            events: events.iter().map(CachedTokenEvent::from_event).collect(),
        },
    );
    *cache_changed = true;
    events
}

impl CachedSessionFile {
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

    fn is_complete_and_safe_to_reuse(&self) -> bool {
        self.parsed_size > 0
            && self.parsed_size >= self.signature.size
            && self.has_plausible_token_events()
    }

    fn has_plausible_token_events(&self) -> bool {
        self.parsed_size > 0
            && self.events
                .iter()
                .all(CachedTokenEvent::has_plausible_token_total)
    }
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
        let slack = visible_total
            .saturating_mul(4)
            .max(1_000_000);
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

fn collect_json_files(root: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_json_files(&path, files);
        } else if path.extension().is_some_and(|extension| extension == "json") {
            files.push(path);
        }
    }
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
