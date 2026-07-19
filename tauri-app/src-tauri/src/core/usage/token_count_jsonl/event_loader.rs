use super::session_files::session_id_from_file;
use super::token_event_cache::{
    codex_home_cache_key, file_cache_key, parse_session_file_cached, token_cache_warning,
    TokenEventCache,
};
use super::TokenEvent;
use crate::models::LocalDataWarning;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

static TOKEN_EVENT_CACHE_IO_GATE: OnceLock<Mutex<()>> = OnceLock::new();

pub(super) fn load_token_events_from_files(
    codex_home: &Path,
    session_files: Vec<PathBuf>,
    warnings: &mut Vec<LocalDataWarning>,
) -> Vec<TokenEvent> {
    let cache_gate = TOKEN_EVENT_CACHE_IO_GATE.get_or_init(|| Mutex::new(()));
    let _cache_guard = cache_gate
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let io_lock = match TokenEventCache::acquire_io_lock() {
        Ok(lock) => lock,
        Err(error) => {
            warnings.push(token_cache_warning(error));
            None
        }
    };
    let persistence_allowed = io_lock.is_some();
    if persistence_allowed {
        TokenEventCache::cleanup_stale_temps();
    }
    let mut cache = if persistence_allowed {
        TokenEventCache::load(warnings)
    } else {
        TokenEventCache::default()
    };
    let home_cache_key = codex_home_cache_key(codex_home);
    let home_cache = cache.home_cache_mut(&home_cache_key, codex_home);
    let mut seen_cache_keys = HashSet::new();
    let mut dirty_shards = HashSet::new();
    let mut events = Vec::new();

    for file in session_files {
        let session_id = session_id_from_file(&file);
        let cache_key = file_cache_key(codex_home, &file);
        seen_cache_keys.insert(cache_key.clone());
        let mut shard_changed = false;
        events.extend(parse_session_file_cached(
            &file,
            &session_id,
            &mut home_cache.files,
            &mut shard_changed,
            codex_home,
            warnings,
        ));
        if shard_changed {
            dirty_shards.insert((home_cache_key.clone(), cache_key));
        }
    }

    let deleted_shards = home_cache
        .remove_unseen(&seen_cache_keys)
        .into_iter()
        .map(|cache_key| (home_cache_key.clone(), cache_key))
        .collect::<HashSet<_>>();
    if persistence_allowed && (!dirty_shards.is_empty() || !deleted_shards.is_empty()) {
        if let Err(error) = cache.save_changes(&dirty_shards, &deleted_shards) {
            warnings.push(token_cache_warning(error));
        }
    }

    events
}
