use crate::core::{live_rate, provider_repair, quota, quota_history, unread, usage};
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
        let mut snapshot = usage::state_sqlite::dashboard_snapshot(self.codex_home())
            .map_err(|error| error.to_string())?;
        if let Err(error) = quota_history::apply_recent_history(&mut snapshot.recent_usage_24h) {
            snapshot.warnings.push(quota_history::warning(error));
        }
        Ok(snapshot)
    }

    fn read_precise_dashboard_snapshot(&self) -> Result<DashboardSnapshot, String> {
        let mut snapshot = usage::token_count_jsonl::dashboard_snapshot(self.codex_home())?;
        if let Err(error) = quota_history::apply_recent_history(&mut snapshot.recent_usage_24h) {
            snapshot.warnings.push(quota_history::warning(error));
        }
        Ok(snapshot)
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
