use super::{session_parser::parse_session_file, TokenEvent};
use crate::core::app_paths;
use crate::models::LocalDataWarning;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::ErrorKind;
use std::path::Path;
use std::time::UNIX_EPOCH;
use time::OffsetDateTime;

const TOKEN_EVENT_CACHE_VERSION: u32 = 3;

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
    pub(super) events: Vec<CachedTokenEvent>,
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
        let Some(path) = app_paths::token_event_cache_path() else {
            return Self::default();
        };
        let data = match fs::read(&path) {
            Ok(data) => data,
            Err(error) if error.kind() == ErrorKind::NotFound => return Self::default(),
            Err(error) => {
                warnings.push(token_cache_warning(format!(
                    "读取精确 token 缓存失败：{}（{}）",
                    path.display(),
                    error
                )));
                return Self::default();
            }
        };
        let cache = match serde_json::from_slice::<Self>(&data) {
            Ok(cache) => cache,
            Err(error) => {
                warnings.push(token_cache_warning(format!(
                    "精确 token 缓存不是有效 JSON：{}（{}）",
                    path.display(),
                    error
                )));
                return Self::default();
            }
        };
        if cache.version == TOKEN_EVENT_CACHE_VERSION {
            cache
        } else {
            Self::default()
        }
    }

    pub(super) fn save(&self) -> Result<(), String> {
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
        if entry.signature == signature {
            return entry.to_events(session_id);
        }
    }

    let events = parse_session_file(file, session_id, warnings);
    files.insert(
        cache_key,
        CachedSessionFile {
            signature,
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

pub(super) fn token_cache_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "token_event_cache".into(),
        message,
    }
}
