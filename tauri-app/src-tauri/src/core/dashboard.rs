use crate::core::{live_rate, provider_repair, quota, quota_history, usage};
use crate::models::{
    AccountQuotaBundle, DashboardSnapshot, FloatingPanelSnapshot, LiveRateSnapshot,
    ProviderRepairSnapshot,
};
use std::path::{Path, PathBuf};

pub trait DashboardDataSource {
    fn codex_home(&self) -> &Path;
    fn read_dashboard_snapshot(&self) -> DashboardSnapshot;
    fn read_precise_dashboard_snapshot(&self) -> DashboardSnapshot;
    fn read_account_quota(&self) -> Result<AccountQuotaBundle, String>;
    fn read_live_rate_snapshot(&self) -> LiveRateSnapshot;
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

    fn read_dashboard_snapshot(&self) -> DashboardSnapshot {
        let mut snapshot = usage::state_sqlite::dashboard_snapshot(self.codex_home())
            .unwrap_or_else(|_| usage::state_sqlite::empty_dashboard_snapshot());
        quota_history::apply_recent_history(&mut snapshot.recent_usage_24h);
        snapshot
    }

    fn read_precise_dashboard_snapshot(&self) -> DashboardSnapshot {
        let mut snapshot = usage::token_count_jsonl::dashboard_snapshot(self.codex_home())
            .or_else(|_| usage::state_sqlite::dashboard_snapshot(self.codex_home()))
            .unwrap_or_else(|_| usage::state_sqlite::empty_dashboard_snapshot());
        quota_history::apply_recent_history(&mut snapshot.recent_usage_24h);
        snapshot
    }

    fn read_account_quota(&self) -> Result<AccountQuotaBundle, String> {
        quota::read_account_quota(self.codex_home())
    }

    fn read_live_rate_snapshot(&self) -> LiveRateSnapshot {
        live_rate::read_snapshot(self.codex_home())
    }

    fn read_floating_snapshot(&self) -> FloatingPanelSnapshot {
        live_rate::read_floating_snapshot(self.codex_home())
    }

    fn scan_provider_repair(&self) -> ProviderRepairSnapshot {
        provider_repair::scan_provider_repair(self.codex_home())
    }
}
