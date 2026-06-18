use crate::core::{live_rate, provider_repair, quota, quota_history, usage};
use crate::models::{
    AccountQuotaBundle, DashboardSnapshot, FloatingPanelSnapshot, LiveRateSnapshot,
    LiveThreadOption, ProviderRepairSnapshot,
};
use std::path::{Path, PathBuf};

pub trait DashboardDataSource {
    fn codex_home(&self) -> &Path;
    fn read_dashboard_snapshot(&self) -> Result<DashboardSnapshot, String>;
    fn read_precise_dashboard_snapshot(&self) -> Result<DashboardSnapshot, String>;
    fn read_account_quota(&self, force_refresh: bool) -> Result<AccountQuotaBundle, String>;
    fn read_live_rate_snapshot(&self, selected_thread_id: Option<&str>) -> LiveRateSnapshot;
    fn try_read_live_rate_snapshot(
        &self,
        selected_thread_id: Option<&str>,
    ) -> Result<LiveRateSnapshot, String>;
    fn try_read_live_thread_options(&self) -> Result<Vec<LiveThreadOption>, String>;
    fn read_floating_snapshot(&self) -> FloatingPanelSnapshot;
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
        quota_history::apply_recent_history(&mut snapshot.recent_usage_24h);
        Ok(snapshot)
    }

    fn read_precise_dashboard_snapshot(&self) -> Result<DashboardSnapshot, String> {
        let mut snapshot = usage::token_count_jsonl::dashboard_snapshot(self.codex_home())?;
        quota_history::apply_recent_history(&mut snapshot.recent_usage_24h);
        Ok(snapshot)
    }

    fn read_account_quota(&self, force_refresh: bool) -> Result<AccountQuotaBundle, String> {
        quota::read_account_quota(self.codex_home(), force_refresh)
    }

    fn read_live_rate_snapshot(&self, selected_thread_id: Option<&str>) -> LiveRateSnapshot {
        live_rate::read_snapshot(self.codex_home(), selected_thread_id)
    }

    fn try_read_live_rate_snapshot(
        &self,
        selected_thread_id: Option<&str>,
    ) -> Result<LiveRateSnapshot, String> {
        live_rate::try_read_snapshot(self.codex_home(), selected_thread_id)
            .map_err(|error| error.to_string())
    }

    fn try_read_live_thread_options(&self) -> Result<Vec<LiveThreadOption>, String> {
        live_rate::try_read_thread_options(self.codex_home()).map_err(|error| error.to_string())
    }

    fn read_floating_snapshot(&self) -> FloatingPanelSnapshot {
        live_rate::read_floating_snapshot(self.codex_home())
    }

    fn scan_provider_repair(&self) -> ProviderRepairSnapshot {
        provider_repair::scan_provider_repair(self.codex_home())
    }
}
