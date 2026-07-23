use super::session_files::session_id_from_file;
use super::token_event_cache::{
    cached_event_count, cached_reusable_event_count, cached_source_bytes_needed,
    codex_home_cache_key, file_cache_key, file_signature, parse_session_file_cached_limited,
    token_cache_warning, TokenEventCache,
};
use super::{
    TokenEvent, UsageScanLimitError, MAX_JSONL_LINE_BYTES, MAX_REFRESH_EVENT_COUNT,
    MAX_REFRESH_READ_BYTES, MAX_SESSION_READ_BYTES,
};
use crate::models::LocalDataWarning;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

static TOKEN_EVENT_CACHE_IO_GATE: OnceLock<Mutex<()>> = OnceLock::new();

#[derive(Default)]
struct UsageScanBudget {
    source_bytes: u64,
    events: usize,
}

impl UsageScanBudget {
    fn reserve_source_bytes(
        &mut self,
        file: &Path,
        bytes: u64,
    ) -> Result<(), UsageScanLimitError> {
        if bytes > MAX_SESSION_READ_BYTES {
            return Err(UsageScanLimitError::new(format!(
                "会话增量超过单会话上限（{}，上限 128 MiB）",
                file.display()
            )));
        }
        let next = self.source_bytes.saturating_add(bytes);
        if next > MAX_REFRESH_READ_BYTES {
            return Err(UsageScanLimitError::new(format!(
                "本次历史刷新超过总读取上限（{} MiB，下一文件：{}）",
                MAX_REFRESH_READ_BYTES / 1024 / 1024,
                file.display()
            )));
        }
        self.source_bytes = next;
        Ok(())
    }

    fn reserve_events(&mut self, count: usize) -> Result<(), UsageScanLimitError> {
        let next = self.events.saturating_add(count);
        if next > MAX_REFRESH_EVENT_COUNT {
            return Err(UsageScanLimitError::new(format!(
                "本次历史刷新超过事件保留上限（{} 条）",
                MAX_REFRESH_EVENT_COUNT
            )));
        }
        self.events = next;
        Ok(())
    }
}

pub(super) fn load_token_events_from_files(
    codex_home: &Path,
    session_files: Vec<PathBuf>,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<Vec<TokenEvent>, UsageScanLimitError> {
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
        TokenEventCache::load_for_home(codex_home, warnings)
    } else {
        TokenEventCache::default()
    };
    let home_cache_key = codex_home_cache_key(codex_home);
    let home_cache = cache.home_cache_mut(&home_cache_key, codex_home);
    let mut seen_cache_keys = HashSet::new();
    let mut dirty_shards = HashSet::new();
    let mut events = Vec::new();
    let mut budget = UsageScanBudget::default();

    for file in session_files {
        let session_id = session_id_from_file(&file);
        let cache_key = file_cache_key(codex_home, &file);
        seen_cache_keys.insert(cache_key.clone());
        let signature = file_signature(&file).ok_or_else(|| {
            UsageScanLimitError::new(format!("无法确认会话文件大小：{}", file.display()))
        })?;
        let source_bytes = cached_source_bytes_needed(
            home_cache.files.get(&cache_key),
            signature.clone(),
        );
        budget.reserve_source_bytes(&file, source_bytes)?;
        let reusable_event_count = cached_reusable_event_count(
            home_cache.files.get(&cache_key),
            signature.clone(),
        );
        if let Some(event_count) = reusable_event_count {
            budget.reserve_events(event_count)?;
        }
        let cached_event_count = cached_event_count(home_cache.files.get(&cache_key));
        let event_limit = MAX_REFRESH_EVENT_COUNT
            .saturating_sub(budget.events)
            .saturating_sub(cached_event_count);
        if reusable_event_count.is_none()
            && cached_event_count > MAX_REFRESH_EVENT_COUNT.saturating_sub(budget.events)
        {
            return Err(UsageScanLimitError::new(format!(
                "会话缓存超过本次历史刷新事件上限（{} 条）：{}",
                MAX_REFRESH_EVENT_COUNT,
                file.display()
            )));
        }
        let mut shard_changed = false;
        let parsed_events = parse_session_file_cached_limited(
            &file,
            &session_id,
            &mut home_cache.files,
            &mut shard_changed,
            codex_home,
            signature,
            source_bytes,
            MAX_JSONL_LINE_BYTES,
            event_limit,
            warnings,
        )?;
        if reusable_event_count.is_none() {
            budget.reserve_events(parsed_events.len())?;
        }
        events.extend(parsed_events);
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

    Ok(events)
}
