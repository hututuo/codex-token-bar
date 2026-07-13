use crate::core::{live_rate, provider_repair, quota, unread, usage};
use crate::models::{
    AccountQuotaBundle, DashboardSnapshot, LiveThreadOption, ProviderRepairSnapshot,
    UnreadSummary,
};
use std::path::{Path, PathBuf};

pub trait DashboardDataSource {
    fn codex_home(&self) -> &Path;
    fn read_dashboard_snapshot(&self) -> Result<DashboardSnapshot, String>;
    fn read_precise_dashboard_snapshot(&self) -> Result<DashboardSnapshot, String>;
    fn read_account_quota(&self, force_refresh: bool) -> Result<AccountQuotaBundle, String>;
    fn try_read_live_thread_options(&self) -> Result<Vec<LiveThreadOption>, String>;
    fn read_unread_summary(&self) -> UnreadSummary;
    fn scan_provider_repair(&self) -> ProviderRepairSnapshot;
}

pub struct LocalCodexDataSource {
    codex_home: PathBuf,
}

impl LocalCodexDataSource {
    pub fn new(codex_home: PathBuf) -> Self {
        Self { codex_home }
    }
}

impl DashboardDataSource for LocalCodexDataSource {
    fn codex_home(&self) -> &Path {
        &self.codex_home
    }

    fn read_dashboard_snapshot(&self) -> Result<DashboardSnapshot, String> {
        if let Some(snapshot) =
            usage::token_count_jsonl::cached_dashboard_snapshot_for_startup(self.codex_home())
        {
            return Ok(snapshot);
        }

        usage::state_sqlite::dashboard_snapshot(self.codex_home())
            .map_err(|error| error.to_string())
    }

    fn read_precise_dashboard_snapshot(&self) -> Result<DashboardSnapshot, String> {
        usage::token_count_jsonl::dashboard_snapshot(self.codex_home())
    }

    fn read_account_quota(&self, force_refresh: bool) -> Result<AccountQuotaBundle, String> {
        quota::read_account_quota(self.codex_home(), force_refresh)
    }

    fn try_read_live_thread_options(&self) -> Result<Vec<LiveThreadOption>, String> {
        live_rate::try_read_thread_options(self.codex_home()).map_err(|error| error.to_string())
    }

    fn read_unread_summary(&self) -> UnreadSummary {
        unread::read_unread_summary(self.codex_home())
    }

    fn scan_provider_repair(&self) -> ProviderRepairSnapshot {
        provider_repair::scan_provider_repair(self.codex_home())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use std::fs;
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn fast_dashboard_prefers_precise_cache_over_state_sqlite_token_sums() {
        let root = temp_root();
        let _test_state = crate::core::app_paths::app_path_test_env_guard(&[
            (
                "CODEX_TOKEN_BAR_AGGREGATE_CACHE_PATH",
                root.join("cache").join("aggregate.json"),
            ),
            (
                "CODEX_TOKEN_BAR_EVENT_CACHE_DIR",
                root.join("cache").join("events"),
            ),
        ]);
        let session_dir = root.join("sessions");
        fs::create_dir_all(&session_dir).unwrap();
        write_lines(
            &session_dir.join("rollout-019efast-0000-0000-0000-cache000001.jsonl"),
            &[r#"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20,"total_tokens":120}}}}"#],
        );
        create_state_database_with_tokens(&root, 12_982_002_513);

        let precise = usage::token_count_jsonl::dashboard_snapshot(&root).unwrap();
        assert_eq!(precise.stats.total_tokens, 120);

        let source = LocalCodexDataSource::new(root.clone());
        let fast = source.read_dashboard_snapshot().unwrap();
        assert_eq!(fast.stats.total_tokens, 120);

        fs::remove_dir_all(root).unwrap();
    }

    fn temp_root() -> PathBuf {
        let sequence = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "codex-token-bar-dashboard-fast-{}-{}-{}",
            std::process::id(),
            sequence,
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn write_lines<S: AsRef<str>>(path: &Path, lines: &[S]) {
        let mut file = fs::File::create(path).unwrap();
        for line in lines {
            writeln!(file, "{}", line.as_ref()).unwrap();
        }
    }

    fn create_state_database_with_tokens(root: &Path, tokens_used: i64) {
        let connection = Connection::open(root.join("state_5.sqlite")).unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    updated_at INTEGER NOT NULL,
                    updated_at_ms INTEGER,
                    tokens_used INTEGER NOT NULL
                );
                "#,
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO threads (id, updated_at, updated_at_ms, tokens_used) VALUES ('a', 1781715600, 1781715600000, ?1);",
                [tokens_used],
            )
            .unwrap();
    }

}
