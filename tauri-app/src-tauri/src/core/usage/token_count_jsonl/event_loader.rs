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

    let mut cache = TokenEventCache::load(warnings);
    let home_cache_key = codex_home_cache_key(codex_home);
    let home_cache = cache.home_cache_mut(&home_cache_key, codex_home);
    let mut seen_cache_keys = HashSet::new();
    let mut cache_changed = false;
    let mut events = Vec::new();

    for file in session_files {
        let session_id = session_id_from_file(&file);
        let cache_key = file_cache_key(codex_home, &file);
        seen_cache_keys.insert(cache_key);
        events.extend(parse_session_file_cached(
            &file,
            &session_id,
            &mut home_cache.files,
            &mut cache_changed,
            codex_home,
            warnings,
        ));
    }

    if home_cache.retain_seen(&seen_cache_keys) {
        cache_changed = true;
    }
    if cache_changed {
        if let Err(error) = cache.save() {
            warnings.push(token_cache_warning(error));
        }
    }

    events
}
