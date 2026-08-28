use crate::core::process_tail::ProcessPipeTail;
use crate::core::quota_history;
use crate::models::{
    AccountInfo, AccountQuotaBundle, LocalDataWarning, QuotaDiagnostic, QuotaSnapshot,
    ResetCreditBundle, ResetCreditSummary,
};
use auth::{read_local_account_name, read_local_auth_observation};
#[cfg(test)]
use auth::read_local_account_key;
use codex_binary::find_codex_binary_with_report;
#[cfg(test)]
use rate_limits::parse_rate_limits;
use rate_limits::{parse_rate_limits_with_plan, placeholder_quota, ParsedRateLimits};
use reset_credit::read_reset_credits;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{mpsc, Arc, Mutex, OnceLock, TryLockError};
use std::thread;
use std::time::{Duration, Instant};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

const DEFAULT_QUOTA_REFRESH_CADENCE_MS: u64 = 60_000;
const MAX_SUCCESS_FRESHNESS: Duration = Duration::from_secs(30);
const FAILURE_CACHE_TTL: Duration = Duration::from_secs(15);
const HISTORY_CACHE_TTL: Duration = Duration::from_secs(5 * 60);
const FORCED_REFRESH_COALESCE_TTL: Duration = Duration::from_secs(5);
const RATE_LIMIT_READ_TIMEOUT: Duration = Duration::from_secs(12);
const STDERR_TAIL_LIMIT_BYTES: usize = 16 * 1024;
const STDERR_DRAIN_GRACE: Duration = Duration::from_millis(500);
pub(super) const RESET_CREDIT_TIMEOUT: Duration = Duration::from_secs(14);
const RESET_CREDIT_SUCCESS_CACHE_TTL: Duration = Duration::from_secs(30);
const RESET_CREDIT_FAILURE_CACHE_TTL: Duration = Duration::from_secs(5);
const RESET_CREDIT_CACHE_RETENTION: Duration = Duration::from_secs(10 * 60);
const RESET_CREDIT_CACHE_LIMIT: usize = 32;
const QUOTA_CHILD_ENV_REMOVE: &[&str] = &[
    "ELECTRON_RUN_AS_NODE",
    "NODE_OPTIONS",
    "TAURI_SIGNING_PRIVATE_KEY",
    "TAURI_SIGNING_PRIVATE_KEY_PATH",
];

mod auth;
pub(crate) mod codex_binary;
mod rate_limits;
mod reset_credit;

static QUOTA_READ_CACHE: OnceLock<Mutex<HashMap<PathBuf, QuotaCacheEntry>>> = OnceLock::new();
static QUOTA_HISTORY_CACHE: OnceLock<QuotaHistoryCacheCoordinator> = OnceLock::new();
static QUOTA_READ_GATES: OnceLock<Mutex<HashMap<PathBuf, Arc<Mutex<()>>>>> = OnceLock::new();
static RESET_CREDIT_READ_CACHE: OnceLock<Mutex<HashMap<PathBuf, ResetCreditCacheEntry>>> =
    OnceLock::new();
static RESET_CREDIT_READ_GATES: OnceLock<Mutex<HashMap<PathBuf, Arc<Mutex<()>>>>> =
    OnceLock::new();

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct QuotaCacheScope {
    codex_home: PathBuf,
    account_key: Option<String>,
    flight_fingerprint: [u8; 32],
}

impl QuotaCacheScope {
    fn allows_success_reuse(&self, current: &Self) -> bool {
        self.codex_home == current.codex_home
            && self.account_key.is_some()
            && self.account_key == current.account_key
    }

    fn allows_flight_reuse(&self, current: &Self) -> bool {
        if self.codex_home != current.codex_home {
            return false;
        }

        match (&self.account_key, &current.account_key) {
            // A stable account key is the identity boundary. Access/refresh token
            // rotation, last_refresh updates, and an atomic auth.json rewrite are
            // expected within the same account and must not invalidate a read.
            (Some(before), Some(after)) => before == after,
            // Without a reliable account key, keep the old fail-closed behavior:
            // only an unchanged auth snapshot may be shared across a flight.
            _ => self.account_key == current.account_key
                && self.flight_fingerprint == current.flight_fingerprint,
        }
    }

    fn history_identity(
        &self,
        bundle: &AccountQuotaBundle,
        limit_id: Option<&str>,
    ) -> Option<quota_history::QuotaHistoryIdentity> {
        quota_history::QuotaHistoryIdentity::from_bundle(
            &self.codex_home,
            self.account_key.as_deref(),
            bundle,
            limit_id,
        )
    }
}

struct LoadedAccountQuota {
    bundle: AccountQuotaBundle,
    history_limit_id: Option<String>,
}

#[derive(Clone)]
struct QuotaCacheEntry {
    scope: QuotaCacheScope,
    result: Result<AccountQuotaBundle, String>,
    cached_at: Instant,
}

#[derive(Clone)]
struct ResetCreditCacheEntry {
    scope: QuotaCacheScope,
    bundle: ResetCreditBundle,
    last_success: Option<ResetCreditSummary>,
    cached_at: Instant,
}

#[derive(Clone)]
struct QuotaHistoryCacheEntry {
    bundle: quota_history::QuotaHistoryBundle,
    cached_at: Instant,
}

#[derive(Default)]
struct QuotaHistoryMemoryCache {
    entries: HashMap<quota_history::QuotaHistoryIdentity, QuotaHistoryCacheEntry>,
}

#[derive(Default)]
struct QuotaHistoryCacheCoordinator {
    cache: Mutex<QuotaHistoryMemoryCache>,
    gates: Mutex<HashMap<quota_history::QuotaHistoryIdentity, Arc<Mutex<()>>>>,
}

impl QuotaHistoryCacheCoordinator {
    fn load_or_refresh<F>(
        &self,
        identity: &quota_history::QuotaHistoryIdentity,
        force_refresh: bool,
        loader: F,
    ) -> Result<quota_history::QuotaHistoryBundle, String>
    where
        F: FnOnce() -> Result<quota_history::QuotaHistoryBundle, String>,
    {
        let requested_at = Instant::now();
        if !force_refresh {
            let cache = self.cache.lock().map_err(|error| error.to_string())?;
            if let Some(entry) = cache.entries.get(identity) {
                if entry.cached_at.elapsed() <= HISTORY_CACHE_TTL {
                    return Ok(entry.bundle.clone());
                }
            }
        }

        let gate = {
            let mut gates = self.gates.lock().map_err(|error| error.to_string())?;
            gates.retain(|key, gate| key == identity || Arc::strong_count(gate) > 1);
            gates
                .entry(identity.clone())
                .or_insert_with(|| Arc::new(Mutex::new(())))
                .clone()
        };
        let _refresh_owner = gate.lock().map_err(|error| error.to_string())?;

        {
            let cache = self.cache.lock().map_err(|error| error.to_string())?;
            if let Some(entry) = cache.entries.get(identity) {
                let fresh = entry.cached_at.elapsed() <= HISTORY_CACHE_TTL;
                let completed_for_request = entry.cached_at >= requested_at;
                if (!force_refresh && fresh) || completed_for_request {
                    return Ok(entry.bundle.clone());
                }
            }
        }

        let bundle = loader()?;
        self.cache
            .lock()
            .map_err(|error| error.to_string())?
            .entries
            .insert(
                identity.clone(),
                QuotaHistoryCacheEntry {
                    bundle: bundle.clone(),
                    cached_at: Instant::now(),
                },
            );
        Ok(bundle)
    }
}

pub fn read_account_quota(
    codex_home: &Path,
    force_refresh: bool,
) -> Result<AccountQuotaBundle, String> {
    if force_refresh {
        // Startup/manual/wake refreshes begin a fresh five-minute stability
        // proof; elapsed sleep time must never count as observation evidence.
        quota_history::reset_stability_tracking();
    }
    read_account_quota_with_policy(codex_home, force_refresh, || {
        crate::platform::read_app_settings()
            .map(|settings| settings.quota_refresh_interval_ms)
            .unwrap_or(DEFAULT_QUOTA_REFRESH_CADENCE_MS)
    })
}

pub fn read_account_reset_credits(
    codex_home: &Path,
    force_refresh: bool,
) -> Result<ResetCreditBundle, String> {
    read_account_reset_credits_with_loader(codex_home, force_refresh, read_reset_credits)
}

fn read_account_reset_credits_with_loader<L>(
    codex_home: &Path,
    force_refresh: bool,
    loader: L,
) -> Result<ResetCreditBundle, String>
where
    L: FnOnce(&Path) -> Result<ResetCreditSummary, String>,
{
    let requested_at = Instant::now();
    let initial_scope = observed_quota_cache_scope(codex_home);
    if let Some(cached) = cached_reset_credit_bundle(&initial_scope, force_refresh, false, requested_at)? {
        return Ok(cached);
    }

    let gate = reset_credit_read_gate(&initial_scope.codex_home)?;
    let _read_guard = match gate.try_lock() {
        Ok(guard) => guard,
        Err(TryLockError::WouldBlock) => {
            let guard = gate.lock().map_err(|error| error.to_string())?;
            let joined_scope = observed_quota_cache_scope(codex_home);
            if !initial_scope.allows_flight_reuse(&joined_scope) {
                return Ok(identity_changed_reset_credit_bundle());
            }
            if let Some(cached) =
                cached_reset_credit_bundle(&joined_scope, force_refresh, true, requested_at)?
            {
                return Ok(cached);
            }
            guard
        }
        Err(TryLockError::Poisoned(error)) => return Err(error.to_string()),
    };

    let scope = observed_quota_cache_scope(codex_home);
    if !initial_scope.allows_flight_reuse(&scope) {
        return Ok(identity_changed_reset_credit_bundle());
    }
    if let Some(cached) = cached_reset_credit_bundle(&scope, force_refresh, false, requested_at)? {
        return Ok(cached);
    }

    let previous_success = cached_successful_reset_credit(&scope)?;
    let had_previous_success = previous_success.is_some();
    let loaded = loader(codex_home);
    let completed_scope = observed_quota_cache_scope(codex_home);
    if !scope.allows_flight_reuse(&completed_scope) {
        return Ok(identity_changed_reset_credit_bundle());
    }
    let bundle = match loaded {
        Ok(reset_credit) => ResetCreditBundle {
            updated_at: diagnostic_timestamp(),
            reset_credit,
            warnings: Vec::new(),
            diagnostics: Vec::new(),
            successful: true,
        },
        Err(error) => reset_credit_failure_bundle(&error, had_previous_success),
    };

    let cache = RESET_CREDIT_READ_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut guard = cache.lock().map_err(|error| error.to_string())?;
    guard.retain(|path, entry| {
        path == &completed_scope.codex_home || entry.cached_at.elapsed() <= RESET_CREDIT_CACHE_RETENTION
    });
    guard.insert(
        completed_scope.codex_home.clone(),
        ResetCreditCacheEntry {
            scope: completed_scope,
            last_success: if bundle.successful {
                Some(bundle.reset_credit.clone())
            } else {
                previous_success
            },
            bundle: bundle.clone(),
            cached_at: Instant::now(),
        },
    );
    while guard.len() > RESET_CREDIT_CACHE_LIMIT {
        let Some(oldest) = guard
            .iter()
            .min_by_key(|(_, entry)| entry.cached_at)
            .map(|(path, _)| path.clone())
        else {
            break;
        };
        guard.remove(&oldest);
    }
    Ok(bundle)
}

fn reset_credit_read_gate(canonical_home: &Path) -> Result<Arc<Mutex<()>>, String> {
    let gates = RESET_CREDIT_READ_GATES.get_or_init(|| Mutex::new(HashMap::new()));
    let mut gates = gates.lock().map_err(|error| error.to_string())?;
    gates.retain(|path, gate| path == canonical_home || Arc::strong_count(gate) > 1);
    Ok(gates
        .entry(canonical_home.to_path_buf())
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone())
}

fn cached_reset_credit_bundle(
    scope: &QuotaCacheScope,
    force_refresh: bool,
    after_inflight: bool,
    requested_at: Instant,
) -> Result<Option<ResetCreditBundle>, String> {
    let cache = RESET_CREDIT_READ_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let guard = cache.lock().map_err(|error| error.to_string())?;
    let Some(entry) = guard.get(&scope.codex_home) else {
        return Ok(None);
    };
    if !entry.scope.allows_success_reuse(scope) {
        return Ok(None);
    }
    let completed_for_request = entry.cached_at >= requested_at;
    if after_inflight && completed_for_request {
        return Ok(Some(entry.bundle.clone()));
    }
    if force_refresh {
        return Ok(None);
    }
    let ttl = if entry.bundle.successful {
        RESET_CREDIT_SUCCESS_CACHE_TTL
    } else {
        RESET_CREDIT_FAILURE_CACHE_TTL
    };
    Ok((entry.cached_at.elapsed() <= ttl).then(|| entry.bundle.clone()))
}

fn cached_successful_reset_credit(
    scope: &QuotaCacheScope,
) -> Result<Option<ResetCreditSummary>, String> {
    let cache = RESET_CREDIT_READ_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let guard = cache.lock().map_err(|error| error.to_string())?;
    Ok(guard
        .get(&scope.codex_home)
        .filter(|entry| entry.scope.allows_success_reuse(scope))
        .and_then(|entry| entry.last_success.clone()))
}

fn read_account_quota_with_policy<F>(
    codex_home: &Path,
    force_refresh: bool,
    cadence_loader: F,
) -> Result<AccountQuotaBundle, String>
where
    F: FnOnce() -> u64,
{
    read_account_quota_with_policy_loader_and_finalizer(
        codex_home,
        force_refresh,
        cadence_loader,
        read_account_quota_raw,
        finalize_account_quota,
    )
}

#[cfg(test)]
fn read_account_quota_with_policy_and_loader<F, L>(
    codex_home: &Path,
    force_refresh: bool,
    cadence_loader: F,
    loader: L,
) -> Result<AccountQuotaBundle, String>
where
    F: FnOnce() -> u64,
    L: FnOnce(&Path) -> Result<AccountQuotaBundle, String>,
{
    read_account_quota_with_policy_loader_and_finalizer(
        codex_home,
        force_refresh,
        cadence_loader,
        |path| {
            loader(path).map(|bundle| LoadedAccountQuota {
                bundle,
                history_limit_id: None,
            })
        },
        |_, bundle, _| Ok(bundle),
    )
}

fn read_account_quota_with_policy_loader_and_finalizer<F, L, Finalize>(
    codex_home: &Path,
    force_refresh: bool,
    cadence_loader: F,
    loader: L,
    finalizer: Finalize,
) -> Result<AccountQuotaBundle, String>
where
    F: FnOnce() -> u64,
    L: FnOnce(&Path) -> Result<LoadedAccountQuota, String>,
    Finalize: FnOnce(
        &QuotaCacheScope,
        AccountQuotaBundle,
        Option<&str>,
    ) -> Result<AccountQuotaBundle, String>,
{
    let success_freshness = success_freshness_for_cadence_ms(cadence_loader());
    let initial_scope = observed_quota_cache_scope(codex_home);
    if let Some(cached) = cached_quota_result(&initial_scope, force_refresh, success_freshness)? {
        return resolve_cached_quota(cached);
    }

    let gate = quota_read_gate(&initial_scope.codex_home)?;
    let _read_guard = match gate.try_lock() {
        Ok(guard) => guard,
        Err(TryLockError::WouldBlock) => {
            let guard = gate.lock().map_err(|error| error.to_string())?;
            let joined_scope = observed_quota_cache_scope(codex_home);
            if !initial_scope.allows_flight_reuse(&joined_scope) {
                return Ok(identity_changed_quota_bundle(codex_home));
            }
            if let Some(cached) =
                cached_quota_result_after_inflight(&joined_scope, force_refresh, success_freshness)?
            {
                return resolve_cached_quota(cached);
            }
            guard
        }
        Err(TryLockError::Poisoned(error)) => return Err(error.to_string()),
    };
    let scope = observed_quota_cache_scope(codex_home);
    if !initial_scope.allows_flight_reuse(&scope) {
        return Ok(identity_changed_quota_bundle(codex_home));
    }
    if let Some(cached) = cached_quota_result(&scope, force_refresh, success_freshness)? {
        return resolve_cached_quota(cached);
    }

    let previous_success = cached_successful_quota(&scope)?;
    let loaded = loader(codex_home);
    if loaded.is_err() {
        quota_history::reset_stability_tracking();
    }
    let completed_scope = observed_quota_cache_scope(codex_home);
    if !scope.allows_flight_reuse(&completed_scope) {
        return Ok(identity_changed_quota_bundle(codex_home));
    }
    let result = loaded.and_then(|loaded| {
        let LoadedAccountQuota {
            bundle,
            history_limit_id,
        } = loaded;
        if account_quota_failed(&bundle) {
            quota_history::reset_stability_tracking();
            if let Some(previous) = previous_success {
                return Ok(stale_quota_bundle(previous, bundle));
            }
        }
        if quota_available(&bundle.quota) {
            return finalizer(&completed_scope, bundle, history_limit_id.as_deref());
        }
        Ok(bundle)
    });
    let cache = QUOTA_READ_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut guard = cache.lock().map_err(|error| error.to_string())?;
    guard.insert(
        completed_scope.codex_home.clone(),
        QuotaCacheEntry {
            scope: completed_scope,
            cached_at: Instant::now(),
            result: result.clone(),
        },
    );
    result
}

fn quota_read_gate(canonical_home: &Path) -> Result<Arc<Mutex<()>>, String> {
    let gates = QUOTA_READ_GATES.get_or_init(|| Mutex::new(HashMap::new()));
    let mut gates = gates.lock().map_err(|error| error.to_string())?;
    Ok(gates
        .entry(canonical_home.to_path_buf())
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone())
}

#[cfg(test)]
fn quota_cache_scope(codex_home: &Path, account_key: Option<String>) -> QuotaCacheScope {
    let observation = read_local_auth_observation(codex_home);
    QuotaCacheScope {
        codex_home: std::fs::canonicalize(codex_home).unwrap_or_else(|_| codex_home.to_path_buf()),
        account_key,
        flight_fingerprint: observation.flight_fingerprint,
    }
}

fn observed_quota_cache_scope(codex_home: &Path) -> QuotaCacheScope {
    let observation = read_local_auth_observation(codex_home);
    QuotaCacheScope {
        codex_home: std::fs::canonicalize(codex_home).unwrap_or_else(|_| codex_home.to_path_buf()),
        account_key: observation.stable_account_key,
        flight_fingerprint: observation.flight_fingerprint,
    }
}

fn success_freshness_for_cadence_ms(cadence_ms: u64) -> Duration {
    let sanitized = match cadence_ms {
        30_000 | 60_000 | 120_000 | 180_000 | 300_000 | 600_000 => cadence_ms,
        _ => DEFAULT_QUOTA_REFRESH_CADENCE_MS,
    };
    Duration::from_millis(sanitized / 2).min(MAX_SUCCESS_FRESHNESS)
}

fn cached_quota_result(
    scope: &QuotaCacheScope,
    force_refresh: bool,
    success_freshness: Duration,
) -> Result<Option<Result<AccountQuotaBundle, String>>, String> {
    cached_quota_result_with_policy(scope, force_refresh, false, success_freshness)
}

fn cached_quota_result_after_inflight(
    scope: &QuotaCacheScope,
    force_refresh: bool,
    success_freshness: Duration,
) -> Result<Option<Result<AccountQuotaBundle, String>>, String> {
    cached_quota_result_with_policy(scope, force_refresh, true, success_freshness)
}

fn cached_successful_quota(scope: &QuotaCacheScope) -> Result<Option<AccountQuotaBundle>, String> {
    let cache = QUOTA_READ_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let guard = cache.lock().map_err(|error| error.to_string())?;
    Ok(guard
        .get(&scope.codex_home)
        .filter(|entry| entry.scope.allows_success_reuse(scope))
        .and_then(|entry| entry.result.as_ref().ok())
        .filter(|bundle| quota_available(&bundle.quota))
        .cloned())
}

fn cached_quota_result_with_policy(
    scope: &QuotaCacheScope,
    force_refresh: bool,
    after_inflight: bool,
    success_freshness: Duration,
) -> Result<Option<Result<AccountQuotaBundle, String>>, String> {
    let cache = QUOTA_READ_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let guard = cache.lock().map_err(|error| error.to_string())?;
    Ok(guard
        .get(&scope.codex_home)
        .filter(|entry| {
            cache_scope_matches(entry, scope, after_inflight)
                && reusable_cached_quota(entry, force_refresh, after_inflight, success_freshness)
        })
        .map(|entry| entry.result.clone()))
}

fn reusable_cached_quota(
    entry: &QuotaCacheEntry,
    force_refresh: bool,
    after_inflight: bool,
    success_freshness: Duration,
) -> bool {
    if !force_refresh {
        return entry.cached_at.elapsed() <= cache_ttl(&entry.result, success_freshness);
    }
    after_inflight && entry.cached_at.elapsed() <= FORCED_REFRESH_COALESCE_TTL
}

fn cache_scope_matches(
    entry: &QuotaCacheEntry,
    scope: &QuotaCacheScope,
    after_inflight: bool,
) -> bool {
    if after_inflight {
        return entry.scope.allows_flight_reuse(scope);
    }
    if cache_result_has_real_quota(&entry.result) {
        entry.scope.allows_success_reuse(scope)
    } else {
        entry.scope == *scope
    }
}

fn cache_result_has_real_quota(result: &Result<AccountQuotaBundle, String>) -> bool {
    result
        .as_ref()
        .is_ok_and(|bundle| quota_available(&bundle.quota))
}

fn resolve_cached_quota(cached: Result<AccountQuotaBundle, String>) -> Result<AccountQuotaBundle, String> {
    match cached {
        Ok(mut bundle) => {
            if !quota_available(&bundle.quota) {
                bundle.quota_history_daily.clear();
                bundle.quota_history_24h.clear();
                bundle.quota_history_7d.clear();
                bundle.quota_history_30d.clear();
            }
            Ok(bundle)
        }
        Err(error) => Err(error),
    }
}

fn cache_ttl(result: &Result<AccountQuotaBundle, String>, success_freshness: Duration) -> Duration {
    if result.as_ref().is_ok_and(bundle_has_stale_data) {
        return FAILURE_CACHE_TTL;
    }
    if cache_result_has_real_quota(result) {
        success_freshness
    } else {
        FAILURE_CACHE_TTL
    }
}

fn quota_available(quota: &QuotaSnapshot) -> bool {
    use crate::models::QuotaAvailability::Measured;
    quota.five_hour.availability == Measured || quota.seven_day.availability == Measured
}

fn account_quota_failed(bundle: &AccountQuotaBundle) -> bool {
    !quota_available(&bundle.quota)
        && bundle
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.source == "account_quota")
}

fn bundle_has_stale_data(bundle: &AccountQuotaBundle) -> bool {
    bundle
        .diagnostics
        .iter()
        .any(|diagnostic| diagnostic.stale_data_displayed)
}

fn read_account_quota_raw(codex_home: &Path) -> Result<LoadedAccountQuota, String> {
    let (bundle, history_limit_id) = match read_rate_limits(codex_home) {
        Ok(ParsedRateLimits {
            quota,
            plan_label,
            limit_id,
        }) => {
            // Capture the rate-limit snapshot time immediately after the provider read.
            // Later history work must not make a cached snapshot look newer.
            let updated_at = diagnostic_timestamp();
            (
                AccountQuotaBundle {
                    updated_at,
                    attribution_identity: None,
                    account: account_info(codex_home, plan_label.as_deref()),
                    quota,
                    quota_history_daily: Vec::new(),
                    quota_history_24h: Vec::new(),
                    quota_history_7d: Vec::new(),
                    quota_history_30d: Vec::new(),
                    warnings: Vec::new(),
                    diagnostics: Vec::new(),
                },
                Some(limit_id),
            )
        }
        Err(error) => (quota_failure_bundle(codex_home, error), None),
    };

    Ok(LoadedAccountQuota {
        bundle,
        history_limit_id,
    })
}

fn finalize_account_quota(
    scope: &QuotaCacheScope,
    mut bundle: AccountQuotaBundle,
    history_limit_id: Option<&str>,
) -> Result<AccountQuotaBundle, String> {
    let Some(history_identity) = scope.history_identity(&bundle, history_limit_id) else {
        return Ok(bundle);
    };
    bundle.attribution_identity = Some(history_identity.attribution_identity());
    if let Err(error) = quota_history::record_bundle(&history_identity, &bundle) {
        bundle.warnings.push(quota_history::warning(error));
        return Ok(bundle);
    }
    refresh_quota_histories(&mut bundle, &history_identity, true);
    if let Some(latest) = bundle.quota_history_24h.last() {
        // The history builder replays the merged Swift + Tauri timeline, so
        // these ids share the exact canonical generation used by chart points
        // instead of leaking either database's local generation counter.
        bundle.quota.five_hour.cycle_id = latest.five_hour_cycle_id.clone();
        bundle.quota.seven_day.cycle_id = latest.seven_day_cycle_id.clone();
    }
    Ok(bundle)
}

fn identity_changed_quota_bundle(codex_home: &Path) -> AccountQuotaBundle {
    let updated_at = diagnostic_timestamp();
    let mut quota = placeholder_quota();
    quota.pace_label = "额度身份已变化".into();
    let diagnostic = QuotaDiagnostic {
        source: "account_quota".into(),
        category: "identity_changed".into(),
        severity: "warning".into(),
        message: "额度读取期间登录身份发生变化，本次结果已丢弃，请重新刷新。".into(),
        raw_cause: None,
        underlying_category: None,
        attempts: None,
        http_status: None,
        retryable: true,
        occurred_at: updated_at.clone(),
        stale_data_displayed: false,
    };
    AccountQuotaBundle {
        updated_at,
        attribution_identity: None,
        account: account_info(codex_home, None),
        quota,
        quota_history_daily: Vec::new(),
        quota_history_24h: Vec::new(),
        quota_history_7d: Vec::new(),
        quota_history_30d: Vec::new(),
        warnings: diagnostics_to_warnings(std::slice::from_ref(&diagnostic)),
        diagnostics: vec![diagnostic],
    }
}

fn identity_changed_reset_credit_bundle() -> ResetCreditBundle {
    let diagnostic = QuotaDiagnostic {
        source: "reset_credit".into(),
        category: "identity_changed".into(),
        severity: "warning".into(),
        message: "重置卡读取期间登录身份发生变化，本次结果已丢弃，请重新刷新。".into(),
        raw_cause: None,
        underlying_category: None,
        attempts: None,
        http_status: None,
        retryable: true,
        occurred_at: diagnostic_timestamp(),
        stale_data_displayed: false,
    };
    ResetCreditBundle {
        updated_at: diagnostic_timestamp(),
        reset_credit: ResetCreditSummary {
            available_count: 0,
            status: diagnostic.message.clone(),
            credits: Vec::new(),
        },
        warnings: diagnostics_to_warnings(std::slice::from_ref(&diagnostic)),
        diagnostics: vec![diagnostic],
        successful: false,
    }
}

fn reset_credit_failure_bundle(error: &str, stale_data_displayed: bool) -> ResetCreditBundle {
    let mut diagnostic = reset_credit_diagnostic(error);
    diagnostic.stale_data_displayed = stale_data_displayed;
    let mut diagnostics = vec![diagnostic.clone()];
    if stale_data_displayed {
        diagnostics.push(stale_cached_reset_credit_diagnostic(
            diagnostic.raw_cause.clone(),
        ));
    }
    ResetCreditBundle {
        updated_at: diagnostic_timestamp(),
        reset_credit: ResetCreditSummary {
            available_count: 0,
            status: diagnostic.message.clone(),
            credits: Vec::new(),
        },
        warnings: diagnostics_to_warnings(&diagnostics),
        diagnostics,
        successful: false,
    }
}

fn quota_failure_bundle(codex_home: &Path, error: String) -> AccountQuotaBundle {
    let updated_at = diagnostic_timestamp();
    let mut quota = placeholder_quota();
    quota.pace_label = "额度读取失败".into();
    let diagnostics = vec![classify_quota_error("account_quota", &error)];

    let bundle = AccountQuotaBundle {
        updated_at,
        attribution_identity: None,
        account: account_info(codex_home, None),
        quota,
        quota_history_daily: Vec::new(),
        quota_history_24h: Vec::new(),
        quota_history_7d: Vec::new(),
        quota_history_30d: Vec::new(),
        warnings: diagnostics_to_warnings(&diagnostics),
        diagnostics,
    };
    bundle
}

fn stale_quota_bundle(
    mut previous: AccountQuotaBundle,
    failure: AccountQuotaBundle,
) -> AccountQuotaBundle {
    let previous_reset_diagnostics = previous
        .diagnostics
        .iter()
        .filter(|diagnostic| diagnostic.source == "reset_credit")
        .cloned()
        .collect::<Vec<_>>();
    let raw_cause = failure
        .diagnostics
        .iter()
        .find(|diagnostic| diagnostic.source == "account_quota")
        .and_then(|diagnostic| diagnostic.raw_cause.clone());
    let mut diagnostics = failure.diagnostics;
    for diagnostic in diagnostics
        .iter_mut()
        .filter(|diagnostic| diagnostic.source == "account_quota")
    {
        diagnostic.stale_data_displayed = true;
    }
    diagnostics.push(stale_cached_quota_diagnostic(raw_cause));
    diagnostics.extend(previous_reset_diagnostics);
    previous.diagnostics = diagnostics;
    previous.warnings = diagnostics_to_warnings(&previous.diagnostics);
    previous
}

fn refresh_quota_histories(
    bundle: &mut AccountQuotaBundle,
    identity: &quota_history::QuotaHistoryIdentity,
    force_refresh: bool,
) {
    let cache = QUOTA_HISTORY_CACHE.get_or_init(QuotaHistoryCacheCoordinator::default);
    let history_request = bundle.clone();
    let history = cache.load_or_refresh(identity, force_refresh, || {
        quota_history::history_bundle_for(identity, &history_request, 365)
    });

    match history {
        Ok(history) => {
            bundle.quota_history_daily = history.daily;
            bundle.quota_history_24h = history.recent_24h;
            bundle.quota_history_7d = history.recent_7d;
            bundle.quota_history_30d = history.recent_30d;
        }
        Err(error) => bundle.warnings.push(quota_history::warning(error)),
    }
}

pub fn account_info(codex_home: &Path, plan_label: Option<&str>) -> AccountInfo {
    AccountInfo {
        display_name: read_local_account_name(codex_home).unwrap_or_else(|| "Codex Token Bar".into()),
        plan_label: plan_label
            .map(str::trim)
            .filter(|label| !label.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| "计划待读取".into()),
    }
}

fn quota_warning(source: &str, message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: source.into(),
        message,
    }
}

fn warning_from_diagnostic(diagnostic: &QuotaDiagnostic) -> LocalDataWarning {
    quota_warning(&diagnostic.source, diagnostic.message.clone())
}

fn diagnostics_to_warnings(diagnostics: &[QuotaDiagnostic]) -> Vec<LocalDataWarning> {
    diagnostics.iter().map(warning_from_diagnostic).collect()
}

fn compact_error_message(error: &str) -> String {
    let text = error.split_whitespace().collect::<Vec<_>>().join(" ");
    let text = text.trim();
    if text.chars().count() <= 720 {
        return text.to_string();
    }
    let mut truncated = text.chars().take(720).collect::<String>();
    truncated.push('…');
    truncated
}

#[cfg(test)]
fn explain_quota_error(error: &str) -> String {
    let compact = compact_error_message(error);
    diagnostic_message(&compact, &diagnostic_category(&compact))
}

fn classify_quota_error(source: &str, error: &str) -> QuotaDiagnostic {
    let compact = compact_error_message(error);
    let category = diagnostic_category(error);
    QuotaDiagnostic {
        source: source.into(),
        category: category.clone(),
        severity: diagnostic_severity(&category).into(),
        message: diagnostic_message(&compact, &category),
        raw_cause: Some(compact.clone()),
        underlying_category: None,
        attempts: retry_attempts(&compact),
        http_status: http_status(&compact),
        retryable: diagnostic_retryable(&category),
        occurred_at: diagnostic_timestamp(),
        stale_data_displayed: false,
    }
}

fn reset_credit_diagnostic(error: &str) -> QuotaDiagnostic {
    let underlying = classify_quota_error("reset_credit", error);
    QuotaDiagnostic {
        source: "reset_credit".into(),
        category: "reset_credit_failure".into(),
        severity: "warning".into(),
        message: format!("重置卡读取失败：{}", underlying.message),
        raw_cause: underlying.raw_cause,
        underlying_category: Some(underlying.category),
        attempts: underlying.attempts,
        http_status: underlying.http_status,
        retryable: underlying.retryable,
        occurred_at: diagnostic_timestamp(),
        stale_data_displayed: false,
    }
}

fn stale_cached_quota_diagnostic(raw_cause: Option<String>) -> QuotaDiagnostic {
    QuotaDiagnostic {
        source: "account_quota".into(),
        category: "stale_cached_data".into(),
        severity: "warning".into(),
        message: "额度刷新失败，暂时显示上次成功额度。请稍后点立即刷新重试。".into(),
        raw_cause,
        underlying_category: None,
        attempts: None,
        http_status: None,
        retryable: true,
        occurred_at: diagnostic_timestamp(),
        stale_data_displayed: true,
    }
}

fn stale_cached_reset_credit_diagnostic(raw_cause: Option<String>) -> QuotaDiagnostic {
    QuotaDiagnostic {
        source: "reset_credit".into(),
        category: "stale_cached_data".into(),
        severity: "warning".into(),
        message: "重置卡刷新失败，暂时显示上次成功结果。".into(),
        raw_cause,
        underlying_category: None,
        attempts: None,
        http_status: None,
        retryable: true,
        occurred_at: diagnostic_timestamp(),
        stale_data_displayed: true,
    }
}

fn diagnostic_category(compact: &str) -> String {
    let lower = compact.to_lowercase();

    if compact.contains("Codex app-server 不可用") {
        return "app_server_unavailable".into();
    }
    if lower.contains("未找到 access token") || lower.contains("access token") {
        return "auth_missing".into();
    }
    if compact.contains("未找到 Codex") || lower.contains("codex_cli_path") {
        return "app_server_unavailable".into();
    }
    if compact.contains("启动 Codex 失败") || compact.contains("Codex stdout 不可用") || compact.contains("Codex stdin 不可用") {
        return "app_server_unavailable".into();
    }
    if compact.contains("额度读取超时") || lower.contains("timed out") || lower.contains("timeout") || compact.contains("超时") {
        return "timeout".into();
    }
    if lower.contains("error sending request")
        || lower.contains("failed to fetch")
        || lower.contains("request error")
        || lower.contains("dns")
        || lower.contains("network")
        || lower.contains("connection")
        || lower.contains("connect")
        || compact.contains("网络")
        || compact.contains("连接")
    {
        return "network_send_fetch".into();
    }
    if lower.contains("http 401") || lower.contains("http 403") {
        return "http_auth".into();
    }
    if lower.contains("http 429") {
        return "http_rate_limited".into();
    }
    if http_status(compact).is_some_and(|status| (500..=599).contains(&status)) {
        return "http_server".into();
    }
    if lower.contains("http ") {
        return "http_other".into();
    }
    if lower.contains("invalid json")
        || lower.contains("json response")
        || lower.contains("json parse")
        || lower.contains("json decode")
        || lower.contains("failed to parse")
        || lower.contains("parse error")
        || compact.contains("解析")
        || compact.contains("响应为空")
        || lower.contains("expected")
    {
        return "parse_failure".into();
    }
    if compact.contains("额度暂无数据") {
        return "empty_quota".into();
    }

    "unknown".into()
}

fn diagnostic_message(compact: &str, category: &str) -> String {
    match category {
        "auth_missing" => "登录凭证缺失：没有从 Codex 目录的 auth.json 读到 access token。请确认 Codex 已登录，且 Codex 目录选对。".into(),
        "app_server_unavailable" => "Codex 本地服务启动失败：无法通过本机 Codex app-server 读取额度。请重启 Codex 后再点立即刷新。".into(),
        "timeout" => "读取超时：本地 Codex 或网络接口在限定时间内没有返回。请稍后点立即刷新重试。".into(),
        "network_send_fetch" => "网络连接失败：请求 ChatGPT 额度接口时网络不可用、DNS 失败或连接被中断。".into(),
        "http_auth" => format!("登录或权限失败：额度接口返回 {compact}，可能是登录过期、账号无权限或 access token 已失效。请重新登录 Codex/ChatGPT 后刷新。"),
        "http_rate_limited" => format!("请求过于频繁：额度接口返回 {compact}。请稍等一会儿再刷新。"),
        "http_server" => format!("服务端错误：额度接口返回 {compact}。这通常是 ChatGPT 服务临时异常，稍后刷新即可。"),
        "http_other" => format!("接口返回异常：额度接口返回 {compact}。如果持续出现，请截图这个原因。"),
        "parse_failure" => "接口响应解析失败：本地收到了额度响应，但格式不是当前版本能识别的结构。".into(),
        "empty_quota" => "本地读取成功但响应里没有可展示的额度。请稍后刷新。".into(),
        _ => format!("未知原因：{compact}"),
    }
}

fn diagnostic_retryable(category: &str) -> bool {
    !matches!(category, "auth_missing" | "http_auth")
}

fn diagnostic_severity(category: &str) -> &'static str {
    match category {
        "auth_missing" | "http_auth" => "error",
        _ => "warning",
    }
}

fn diagnostic_timestamp() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into())
}

fn http_status(text: &str) -> Option<u16> {
    let lower = text.to_lowercase();
    let start = lower.find("http ")? + "http ".len();
    let digits = lower[start..]
        .chars()
        .skip_while(|ch| !ch.is_ascii_digit())
        .take_while(|ch| ch.is_ascii_digit())
        .collect::<String>();
    digits.parse().ok()
}

fn retry_attempts(text: &str) -> Option<u32> {
    let marker = "已重试 ";
    let start = text.find(marker)? + marker.len();
    text[start..]
        .chars()
        .take_while(|ch| ch.is_ascii_digit())
        .collect::<String>()
        .parse()
        .ok()
}

fn quota_deadline_error(timeout: Duration, stderr: Option<&str>) -> String {
    let timeout_message = format!("额度读取超时（{} 秒）", timeout.as_secs());
    let stderr = stderr
        .map(str::trim)
        .filter(|stderr| !stderr.is_empty())
        .map(compact_error_message);
    match stderr {
        Some(stderr) => format!("{timeout_message}；Codex app-server stderr：{stderr}"),
        None => timeout_message,
    }
}

fn quota_app_server_unavailable_error(
    child: &mut QuotaChildGuard<Child>,
    reason: impl Into<String>,
) -> String {
    let exit_info = match child.child_mut().try_wait() {
        Ok(Some(status)) => Some(format!("退出状态：{status}")),
        Ok(None) => None,
        Err(error) => Some(format!("读取退出状态失败：{error}")),
    };
    let stderr_tail = child.cleanup();
    let mut details = vec![reason.into()];
    if let Some(exit_info) = exit_info {
        details.push(exit_info);
    }
    if let Some(stderr) =
        (!stderr_tail.trim().is_empty()).then(|| compact_error_message(&stderr_tail))
    {
        details.push(format!("Codex app-server stderr：{stderr}"));
    }
    format!("Codex app-server 不可用：{}", details.join("；"))
}

enum QuotaStdoutEvent {
    Message(Value),
    Eof,
    IoError(String),
}

fn read_rate_limits(codex_home: &Path) -> Result<ParsedRateLimits, String> {
    read_rate_limits_once(codex_home, RATE_LIMIT_READ_TIMEOUT)
}

fn read_rate_limits_once(codex_home: &Path, timeout: Duration) -> Result<ParsedRateLimits, String> {
    let codex = find_codex_binary_with_report()?.path;
    let mut command = Command::new(codex);
    configure_quota_app_server_command(&mut command, Some(codex_home));
    read_rate_limits_from_command(command, timeout)
}

fn read_rate_limits_from_command(
    mut command: Command,
    timeout: Duration,
) -> Result<ParsedRateLimits, String> {
    let child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("启动 Codex 失败：{error}"))?;
    let mut child = QuotaChildGuard::new(child);

    let stderr = match child.child_mut().stderr.take() {
        Some(stderr) => stderr,
        None => {
            return Err(quota_app_server_unavailable_error(
                &mut child,
                "Codex stderr 不可用",
            ));
        }
    };
    child.collect_stderr(stderr);
    let stdout = match child.child_mut().stdout.take() {
        Some(stdout) => stdout,
        None => {
            return Err(quota_app_server_unavailable_error(
                &mut child,
                "Codex stdout 不可用",
            ));
        }
    };
    let mut stdin = match child.child_mut().stdin.take() {
        Some(stdin) => stdin,
        None => {
            return Err(quota_app_server_unavailable_error(
                &mut child,
                "Codex stdin 不可用",
            ));
        }
    };
    let (sender, receiver) = mpsc::channel();

    thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        loop {
            let mut line = String::new();
            match reader.read_line(&mut line) {
                Ok(0) => {
                    let _ = sender.send(QuotaStdoutEvent::Eof);
                    break;
                }
                Ok(_) => {
                    if let Ok(value) = serde_json::from_str::<Value>(&line) {
                        if sender.send(QuotaStdoutEvent::Message(value)).is_err() {
                            break;
                        }
                    }
                }
                Err(error) => {
                    let _ = sender.send(QuotaStdoutEvent::IoError(error.to_string()));
                    break;
                }
            }
        }
    });

    if let Err(error) = write_json_line(
        &mut stdin,
        &json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "codex-token-bar-tauri",
                    "title": "Codex Token Bar",
                    "version": env!("CARGO_PKG_VERSION")
                },
                "capabilities": {
                    "experimentalApi": false,
                    "requestAttestation": false
                }
            }
        }),
    ) {
        return Err(quota_app_server_unavailable_error(
            &mut child,
            format!("写入 initialize 请求失败：{error}"),
        ));
    }

    let deadline = Instant::now() + timeout;
    let mut read_sent = false;
    while Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let event = match receiver.recv_timeout(remaining.min(Duration::from_millis(100))) {
            Ok(event) => event,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if Instant::now() >= deadline {
                    break;
                }
                match child.child_mut().try_wait() {
                    Ok(Some(_)) => {
                        let grace = deadline
                            .saturating_duration_since(Instant::now())
                            .min(Duration::from_millis(25));
                        if grace.is_zero() {
                            break;
                        }
                        match receiver.recv_timeout(grace) {
                            Ok(event) => event,
                            Err(mpsc::RecvTimeoutError::Timeout)
                                if Instant::now() >= deadline => break,
                            Err(mpsc::RecvTimeoutError::Timeout) => {
                                return Err(quota_app_server_unavailable_error(
                                    &mut child,
                                    "app-server 在额度响应前提前退出".to_string(),
                                ));
                            }
                            Err(mpsc::RecvTimeoutError::Disconnected) => {
                                return Err(quota_app_server_unavailable_error(
                                    &mut child,
                                    "stdout 读取线程提前结束".to_string(),
                                ));
                            }
                        }
                    }
                    Ok(None) => continue,
                    Err(error) => {
                        return Err(quota_app_server_unavailable_error(
                            &mut child,
                            format!("无法确认 app-server 进程状态：{error}"),
                        ));
                    }
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err(quota_app_server_unavailable_error(
                    &mut child,
                    "stdout 读取线程提前结束".to_string(),
                ));
            }
        };

        let message = match event {
            QuotaStdoutEvent::Message(message) => message,
            QuotaStdoutEvent::Eof => {
                return Err(quota_app_server_unavailable_error(
                    &mut child,
                    "stdout EOF：app-server 在额度响应前结束".to_string(),
                ));
            }
            QuotaStdoutEvent::IoError(error) => {
                return Err(quota_app_server_unavailable_error(
                    &mut child,
                    format!("stdout 读取失败：{error}"),
                ));
            }
        };

        if message.get("id").and_then(Value::as_i64) == Some(1) {
            if let Some(error) = message.get("error") {
                let detail = error
                    .get("message")
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .unwrap_or_else(|| error.to_string());
                return Err(quota_app_server_unavailable_error(
                    &mut child,
                    format!("initialize 返回 error：{detail}"),
                ));
            }
            if message.get("result").is_none() {
                return Err(quota_app_server_unavailable_error(
                    &mut child,
                    "initialize 响应缺少 result".to_string(),
                ));
            }
            if !read_sent {
                if let Err(error) = write_json_line(
                    &mut stdin,
                    &json!({"jsonrpc": "2.0", "method": "initialized"}),
                ) {
                    return Err(quota_app_server_unavailable_error(
                        &mut child,
                        format!("写入 initialized 通知失败：{error}"),
                    ));
                }
                if let Err(error) = write_json_line(
                    &mut stdin,
                    &json!({"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"}),
                ) {
                    return Err(quota_app_server_unavailable_error(
                        &mut child,
                        format!("写入额度读取请求失败：{error}"),
                    ));
                }
                read_sent = true;
            }
            continue;
        }

        if message.get("id").and_then(Value::as_i64) == Some(2) {
            let _ = child.cleanup();
            if let Some(error) = message
                .get("error")
                .and_then(|value| value.get("message"))
                .and_then(Value::as_str)
            {
                return Err(error.to_string());
            }
            let result = message
                .get("result")
                .ok_or_else(|| "额度响应为空".to_string())?;
            return parse_rate_limits_with_plan(result);
        }
    }

    let stderr_tail = child.cleanup();
    Err(quota_deadline_error(timeout, Some(&stderr_tail)))
}

trait QuotaChildProcess {
    fn kill_for_cleanup(&mut self);
    fn wait_for_cleanup(&mut self);
}

impl QuotaChildProcess for Child {
    fn kill_for_cleanup(&mut self) {
        let _ = self.kill();
    }

    fn wait_for_cleanup(&mut self) {
        let _ = self.wait();
    }
}

struct QuotaChildGuard<C: QuotaChildProcess> {
    child: C,
    cleaned: bool,
    stderr: Option<ProcessPipeTail>,
}

impl<C: QuotaChildProcess> QuotaChildGuard<C> {
    fn new(child: C) -> Self {
        Self {
            child,
            cleaned: false,
            stderr: None,
        }
    }

    fn cleanup(&mut self) -> String {
        if !self.cleaned {
            self.child.kill_for_cleanup();
            self.child.wait_for_cleanup();
            self.cleaned = true;
        }
        self.stderr
            .take()
            .map(ProcessPipeTail::finish)
            .unwrap_or_default()
    }
}

impl QuotaChildGuard<Child> {
    fn collect_stderr(&mut self, stderr: std::process::ChildStderr) {
        self.stderr = Some(ProcessPipeTail::spawn(
            Some(stderr),
            STDERR_TAIL_LIMIT_BYTES,
            STDERR_DRAIN_GRACE,
        ));
    }

    fn child_mut(&mut self) -> &mut Child {
        &mut self.child
    }
}

impl<C: QuotaChildProcess> Drop for QuotaChildGuard<C> {
    fn drop(&mut self) {
        let _ = self.cleanup();
    }
}

fn configure_quota_child_process(command: &mut Command, codex_home: Option<&Path>) {
    strip_quota_child_environment(command);
    if let Some(codex_home) = codex_home {
        command.env("CODEX_HOME", codex_home);
    }

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }

    #[cfg(not(windows))]
    {
        let _ = command;
    }
}

fn configure_quota_app_server_command(command: &mut Command, codex_home: Option<&Path>) {
    configure_quota_child_process(command, codex_home);
    // This transient process only calls account/rateLimits/read. Suggested-plugin
    // discovery is unrelated startup work and can add a failing network request.
    command.args(["app-server", "--disable", "plugins", "--listen", "stdio://"]);
}

fn strip_quota_child_environment(command: &mut Command) {
    for key in QUOTA_CHILD_ENV_REMOVE {
        command.env_remove(key);
    }
}

fn write_json_line(stdin: &mut std::process::ChildStdin, value: &Value) -> Result<(), String> {
    serde_json::to_writer(&mut *stdin, value).map_err(|error| error.to_string())?;
    stdin.write_all(b"\n").map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsStr;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn automatic_success_freshness_uses_half_cadence_capped_at_thirty_seconds() {
        let cases = [
            (30_000, Duration::from_secs(15)),
            (60_000, Duration::from_secs(30)),
            (120_000, Duration::from_secs(30)),
            (180_000, Duration::from_secs(30)),
            (300_000, Duration::from_secs(30)),
            (600_000, Duration::from_secs(30)),
        ];

        for (cadence_ms, expected) in cases {
            assert_eq!(success_freshness_for_cadence_ms(cadence_ms), expected);
        }
        assert_eq!(
            success_freshness_for_cadence_ms(31_000),
            Duration::from_secs(30)
        );
    }

    #[test]
    fn automatic_cache_reuse_obeys_each_supported_cadence_freshness() {
        let bundle = quota_bundle_fixture(
            "freshness",
            parse_rate_limits(&json!({
                "rateLimits": {
                    "primary": { "usedPercent": 20, "resetsAt": 1781715600 },
                    "secondary": { "usedPercent": 40, "resetsAt": 1782144492 }
                }
            }))
            .unwrap(),
            Vec::new(),
            Vec::new(),
        );

        for cadence_ms in [30_000, 60_000, 120_000, 180_000, 300_000, 600_000] {
            let freshness = success_freshness_for_cadence_ms(cadence_ms);
            let fresh = QuotaCacheEntry {
                scope: quota_cache_scope(Path::new("freshness-home"), Some("sub:freshness".into())),
                result: Ok(bundle.clone()),
                cached_at: Instant::now()
                    .checked_sub(freshness - Duration::from_millis(1))
                    .unwrap(),
            };
            let expired = QuotaCacheEntry {
                cached_at: Instant::now()
                    .checked_sub(freshness + Duration::from_millis(1))
                    .unwrap(),
                ..fresh.clone()
            };

            assert!(reusable_cached_quota(&fresh, false, false, freshness));
            assert!(!reusable_cached_quota(&expired, false, false, freshness));
        }
    }

    #[test]
    fn cache_scope_requires_canonical_home_and_established_matching_identity_for_success() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-quota-scope-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let real_home = root.join("home");
        std::fs::create_dir_all(&real_home).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&real_home, root.join("alias")).unwrap();

        let scope = quota_cache_scope(&real_home, Some("sub:account-a".into()));
        #[cfg(unix)]
        assert_eq!(
            scope.codex_home,
            quota_cache_scope(&root.join("alias"), Some("sub:account-a".into())).codex_home
        );
        assert!(scope
            .allows_success_reuse(&quota_cache_scope(&real_home, Some("sub:account-a".into()))));
        assert!(!scope
            .allows_success_reuse(&quota_cache_scope(&real_home, Some("sub:account-b".into()))));
        assert!(!scope.allows_success_reuse(&quota_cache_scope(&real_home, None)));

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn simultaneous_forced_callers_join_one_inflight_loader() {
        assert_simultaneous_callers_join_one_inflight_loader(true);
    }

    #[test]
    fn independently_phased_automatic_callers_join_one_inflight_loader() {
        assert_simultaneous_callers_join_one_inflight_loader(false);
    }

    #[test]
    fn callers_without_stable_account_ids_join_the_same_unchanged_auth_flight() {
        for auth in [None, Some(r#"{"tokens":{"id_token":"header.eyJuYW1lIjoibG9jYWwifQ.signature"}}"#)] {
            for forces in [[false, false], [true, true], [true, false]] {
                assert_unstable_identity_callers_join_one_inflight_loader(auth, forces);
            }
        }
    }

    #[test]
    fn auth_change_during_unkeyed_successful_flight_is_rejected() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-quota-unkeyed-transition-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(
            root.join("auth.json"),
            r#"{"tokens":{"id_token":"header.eyJuYW1lIjoiYSJ9.signature"}}"#,
        )
        .unwrap();

        let result = read_account_quota_with_policy_and_loader(
            &root,
            true,
            || 30_000,
            |home| {
                std::fs::write(
                    home.join("auth.json"),
                    r#"{"tokens":{"id_token":"header.eyJuYW1lIjoiYiJ9.signature"}}"#,
                )
                .unwrap();
                Ok(measured_quota_bundle("account-b"))
            },
        )
        .unwrap();

        assert!(!quota_available(&result.quota));
        assert_eq!(result.account.display_name, "b");
        assert!(result.quota_history_24h.is_empty());
        assert!(!bundle_has_stale_data(&result));
        assert!(QUOTA_READ_CACHE
            .get_or_init(|| Mutex::new(HashMap::new()))
            .lock()
            .unwrap()
            .get(&quota_cache_scope(&root, None).codex_home)
            .is_none());

        let _ = std::fs::remove_dir_all(root);
    }

    fn assert_simultaneous_callers_join_one_inflight_loader(force_refresh: bool) {
        use base64::Engine as _;
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Barrier;

        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-quota-inflight-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(r#"{"sub":"inflight-account"}"#);
        std::fs::write(
            root.join("auth.json"),
            format!(r#"{{"tokens":{{"id_token":"header.{payload}.signature"}}}}"#),
        )
        .unwrap();
        let bundle = quota_bundle_fixture(
            "inflight",
            parse_rate_limits(&json!({
                "rateLimits": {
                    "primary": { "usedPercent": 20, "resetsAt": 1781715600 },
                    "secondary": { "usedPercent": 40, "resetsAt": 1782144492 }
                }
            }))
            .unwrap(),
            Vec::new(),
            Vec::new(),
        );
        let calls = Arc::new(AtomicUsize::new(0));
        let start = Arc::new(Barrier::new(3));
        let handles = (0..2)
            .map(|_| {
                let home = root.clone();
                let calls = calls.clone();
                let start = start.clone();
                let bundle = bundle.clone();
                std::thread::spawn(move || {
                    start.wait();
                    read_account_quota_with_policy_and_loader(
                        &home,
                        force_refresh,
                        || 30_000,
                        |_| {
                            calls.fetch_add(1, Ordering::SeqCst);
                            std::thread::sleep(Duration::from_millis(100));
                            Ok(bundle)
                        },
                    )
                    .unwrap()
                })
            })
            .collect::<Vec<_>>();
        start.wait();
        for handle in handles {
            assert!(quota_available(&handle.join().unwrap().quota));
        }

        assert_eq!(calls.load(Ordering::SeqCst), 1);
        let _ = std::fs::remove_dir_all(root);
    }

    fn assert_unstable_identity_callers_join_one_inflight_loader(
        auth_json: Option<&str>,
        force_refresh: [bool; 2],
    ) {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Barrier;

        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-quota-unkeyed-inflight-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        if let Some(auth_json) = auth_json {
            std::fs::write(root.join("auth.json"), auth_json).unwrap();
        }
        let calls = Arc::new(AtomicUsize::new(0));
        let start = Arc::new(Barrier::new(3));
        let handles = force_refresh
            .into_iter()
            .map(|force_refresh| {
                let home = root.clone();
                let calls = calls.clone();
                let start = start.clone();
                std::thread::spawn(move || {
                    start.wait();
                    read_account_quota_with_policy_and_loader(
                        &home,
                        force_refresh,
                        || 30_000,
                        |_| {
                            calls.fetch_add(1, Ordering::SeqCst);
                            std::thread::sleep(Duration::from_millis(100));
                            Ok(measured_quota_bundle("unkeyed"))
                        },
                    )
                    .unwrap()
                })
            })
            .collect::<Vec<_>>();
        start.wait();
        for handle in handles {
            assert!(quota_available(&handle.join().unwrap().quota));
        }

        assert_eq!(calls.load(Ordering::SeqCst), 1, "forces={force_refresh:?}");
        QUOTA_READ_CACHE
            .get_or_init(|| Mutex::new(HashMap::new()))
            .lock()
            .unwrap()
            .remove(&quota_cache_scope(&root, None).codex_home);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn failed_new_source_keeps_all_history_empty() {
        let codex_home = std::env::temp_dir().join(format!(
            "codex-token-bar-quota-empty-history-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let bundle = quota_failure_bundle(&codex_home, "auth missing".into());

        assert!(bundle.quota_history_daily.is_empty());
        assert!(bundle.quota_history_24h.is_empty());
        assert!(bundle.quota_history_7d.is_empty());
        assert!(bundle.quota_history_30d.is_empty());
        assert!(!quota_available(&bundle.quota));
    }

    #[test]
    fn identity_change_during_read_does_not_reuse_previous_success() {
        use base64::Engine as _;

        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-quota-identity-transition-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        write_test_auth_subject(&root, "account-a");
        let scope_a = quota_cache_scope(&root, read_local_account_key(&root));
        let previous = quota_bundle_fixture(
            "account-a",
            parse_rate_limits(&json!({
                "rateLimits": {
                    "primary": { "usedPercent": 20, "resetsAt": 1781715600 },
                    "secondary": { "usedPercent": 40, "resetsAt": 1782144492 }
                }
            }))
            .unwrap(),
            Vec::new(),
            Vec::new(),
        );
        let cache = QUOTA_READ_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
        cache.lock().unwrap().insert(
            scope_a.codex_home.clone(),
            QuotaCacheEntry {
                scope: scope_a.clone(),
                result: Ok(previous),
                cached_at: Instant::now(),
            },
        );

        let result = read_account_quota_with_policy_and_loader(
            &root,
            true,
            || 30_000,
            |home| {
                write_test_auth_subject(home, "account-b");
                Ok(quota_failure_bundle(home, "new account read failed".into()))
            },
        )
        .unwrap();

        assert!(!quota_available(&result.quota));
        assert!(result.quota_history_24h.is_empty());
        assert!(!bundle_has_stale_data(&result));
        cache.lock().unwrap().remove(&scope_a.codex_home);
        let _ = std::fs::remove_dir_all(root);

        fn write_test_auth_subject(home: &Path, subject: &str) {
            let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
                .encode(format!(r#"{{"sub":"{subject}"}}"#));
            std::fs::write(
                home.join("auth.json"),
                format!(r#"{{"tokens":{{"id_token":"header.{payload}.signature"}}}}"#),
            )
            .unwrap();
        }
    }

    #[test]
    fn successful_identity_change_is_not_published_or_cached() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-quota-success-identity-transition-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        write_test_auth_subject(&root, "account-a");
        let scope_a = quota_cache_scope(&root, read_local_account_key(&root));
        QUOTA_READ_CACHE
            .get_or_init(|| Mutex::new(HashMap::new()))
            .lock()
            .unwrap()
            .remove(&scope_a.codex_home);

        let result = read_account_quota_with_policy_and_loader(
            &root,
            true,
            || 30_000,
            |home| {
                write_test_auth_subject(home, "account-b");
                let mut bundle = measured_quota_bundle("account-b");
                bundle.quota_history_24h.push(crate::models::QuotaHistoryPoint {
                    label: "must-not-publish".into(),
                    start_unix: 1,
                    five_hour_remaining_percent: Some(0.8),
                    seven_day_remaining_percent: Some(0.6),
                    five_hour_cycle_id: None,
                    seven_day_cycle_id: None,
                });
                Ok(bundle)
            },
        )
        .unwrap();

        assert!(!quota_available(&result.quota));
        assert_eq!(result.account.display_name, "Codex Token Bar");
        assert!(result.quota_history_daily.is_empty());
        assert!(result.quota_history_24h.is_empty());
        assert!(result.quota_history_7d.is_empty());
        assert!(result.quota_history_30d.is_empty());
        assert!(!bundle_has_stale_data(&result));
        assert!(QUOTA_READ_CACHE
            .get_or_init(|| Mutex::new(HashMap::new()))
            .lock()
            .unwrap()
            .get(&scope_a.codex_home)
            .is_none());

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn successful_identity_change_skips_history_finalization_side_effects() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-quota-finalize-identity-transition-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        write_test_auth_subject(&root, "account-a");
        let record_calls = AtomicUsize::new(0);
        let history_load_calls = AtomicUsize::new(0);

        let result = read_account_quota_with_policy_loader_and_finalizer(
            &root,
            true,
            || 30_000,
            |home| {
                write_test_auth_subject(home, "account-b");
                Ok(LoadedAccountQuota {
                    bundle: measured_quota_bundle("account-b"),
                    history_limit_id: Some("codex".into()),
                })
            },
            |_, bundle, _| {
                record_calls.fetch_add(1, Ordering::SeqCst);
                history_load_calls.fetch_add(1, Ordering::SeqCst);
                Ok(bundle)
            },
        )
        .unwrap();

        assert!(!quota_available(&result.quota));
        assert_eq!(record_calls.load(Ordering::SeqCst), 0);
        assert_eq!(history_load_calls.load(Ordering::SeqCst), 0);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn selected_limit_id_reaches_history_finalizer() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-quota-limit-finalizer-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        write_test_auth_subject(&root, "limit-account");
        let canonical_root = std::fs::canonicalize(&root).unwrap();
        let expected = quota_history::QuotaHistoryIdentity::from_canonical_parts(
            &canonical_root,
            Some("sub:limit-account"),
            "Pro",
            "gpt-5.3-codex-spark",
        )
        .unwrap();
        let mut observed = None;

        let result = read_account_quota_with_policy_loader_and_finalizer(
            &root,
            true,
            || 30_000,
            |_| {
                Ok(LoadedAccountQuota {
                    bundle: measured_quota_bundle("Limit User"),
                    history_limit_id: Some("gpt-5.3-codex-spark".into()),
                })
            },
            |scope, bundle, limit_id| {
                observed = scope.history_identity(&bundle, limit_id);
                Ok(bundle)
            },
        )
        .unwrap();

        assert!(quota_available(&result.quota));
        assert_eq!(observed, Some(expected));
        QUOTA_READ_CACHE
            .get_or_init(|| Mutex::new(HashMap::new()))
            .lock()
            .unwrap()
            .remove(&canonical_root);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn quota_history_cache_reuses_recent_bundle_until_forced() {
        use std::cell::Cell;

        let cache = QuotaHistoryCacheCoordinator::default();
        let identity = quota_cache_scope(Path::new("history-home"), Some("sub:history".into()))
            .history_identity(&measured_quota_bundle("History User"), Some("codex"))
            .unwrap();
        let load_count = Cell::new(0);
        let mut loader = || {
            let next_count = load_count.get() + 1;
            load_count.set(next_count);
            Ok(quota_history::QuotaHistoryBundle {
                recent_24h: vec![crate::models::QuotaHistoryPoint {
                    label: format!("load-{next_count}"),
                    start_unix: next_count,
                    five_hour_remaining_percent: Some(0.8),
                    seven_day_remaining_percent: Some(0.6),
                    five_hour_cycle_id: None,
                    seven_day_cycle_id: None,
                }],
                ..Default::default()
            })
        };

        let first = cache
            .load_or_refresh(&identity, false, &mut loader)
            .unwrap();
        let second = cache
            .load_or_refresh(&identity, false, &mut loader)
            .unwrap();
        assert_eq!(load_count.get(), 1);
        assert_eq!(first.recent_24h[0].label, "load-1");
        assert_eq!(second.recent_24h[0].label, "load-1");

        let forced = cache
            .load_or_refresh(&identity, true, &mut loader)
            .unwrap();
        assert_eq!(load_count.get(), 2);
        assert_eq!(forced.recent_24h[0].label, "load-2");

        let failed = cache.load_or_refresh(&identity, true, || Err("history failed".into()));
        assert!(failed.is_err());
        let preserved = cache
            .load_or_refresh(&identity, false, || {
                panic!("failed refresh must preserve the stable identity cache")
            })
            .unwrap();
        assert_eq!(preserved.recent_24h[0].label, "load-2");
    }

    #[test]
    fn quota_history_loader_runs_outside_the_memory_cache_mutex() {
        let cache = Arc::new(QuotaHistoryCacheCoordinator::default());
        let identity = quota_cache_scope(Path::new("history-unlocked"), Some("sub:unlocked".into()))
            .history_identity(&measured_quota_bundle("Unlocked User"), Some("codex"))
            .unwrap();
        let observed = cache.clone();

        let loaded = cache
            .load_or_refresh(&identity, false, || {
                let memory = observed
                    .cache
                    .try_lock()
                    .expect("history loader must run outside the memory cache mutex");
                assert!(memory.entries.is_empty());
                drop(memory);
                Ok(history_bundle_fixture("unlocked"))
            })
            .unwrap();

        assert_eq!(loaded.recent_24h[0].label, "unlocked");
    }

    #[test]
    fn concurrent_quota_history_loads_are_single_flight_per_identity() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Barrier;

        let cache = Arc::new(QuotaHistoryCacheCoordinator::default());
        let identity = quota_cache_scope(
            Path::new("history-single-flight"),
            Some("sub:single-flight".into()),
        )
        .history_identity(
            &measured_quota_bundle("Single Flight User"),
            Some("codex"),
        )
        .unwrap();
        let attempts = Arc::new(AtomicUsize::new(0));
        let barrier = Arc::new(Barrier::new(3));
        let handles = [(), ()].map(|_| {
            let cache = cache.clone();
            let identity = identity.clone();
            let attempts = attempts.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                cache
                    .load_or_refresh(&identity, false, || {
                        attempts.fetch_add(1, Ordering::SeqCst);
                        std::thread::sleep(Duration::from_millis(30));
                        Ok(history_bundle_fixture("single-flight"))
                    })
                    .unwrap()
            })
        });
        barrier.wait();

        for handle in handles {
            assert_eq!(
                handle.join().unwrap().recent_24h[0].label,
                "single-flight"
            );
        }
        assert_eq!(attempts.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn stable_account_token_rotation_keeps_history_identity_owned() {
        let cache = QuotaHistoryCacheCoordinator::default();
        let codex_home = PathBuf::from("rotation-home");
        let bundle = measured_quota_bundle("Stable User");
        let before_rotation = QuotaCacheScope {
            codex_home: codex_home.clone(),
            account_key: Some("sub:stable-account".into()),
            flight_fingerprint: [1; 32],
        };
        let after_rotation = QuotaCacheScope {
            codex_home,
            account_key: Some("sub:stable-account".into()),
            flight_fingerprint: [2; 32],
        };
        let before_history_identity = before_rotation
            .history_identity(&bundle, Some("codex"))
            .unwrap();
        let after_history_identity = after_rotation
            .history_identity(&bundle, Some("codex"))
            .unwrap();

        let first = cache
            .load_or_refresh(&before_history_identity, true, || {
                Ok(history_bundle_fixture("before-rotation"))
            })
            .unwrap();
        let second = cache
            .load_or_refresh(&after_history_identity, true, || {
                Ok(history_bundle_fixture("after-rotation"))
            })
            .unwrap();

        assert!(before_rotation.allows_flight_reuse(&after_rotation));
        assert_eq!(before_history_identity, after_history_identity);
        assert_eq!(first.recent_24h[0].label, "before-rotation");
        assert_eq!(
            second.recent_24h.first().map(|point| point.label.as_str()),
            Some("after-rotation")
        );
    }

    #[test]
    fn different_stable_accounts_do_not_share_history_identity() {
        let cache = QuotaHistoryCacheCoordinator::default();
        let codex_home = PathBuf::from("shared-home");
        let bundle = measured_quota_bundle("Shared User");
        let account_a = QuotaCacheScope {
            codex_home: codex_home.clone(),
            account_key: Some("sub:account-a".into()),
            flight_fingerprint: [3; 32],
        };
        let account_b = QuotaCacheScope {
            codex_home,
            account_key: Some("sub:account-b".into()),
            flight_fingerprint: [4; 32],
        };
        let identity_a = account_a
            .history_identity(&bundle, Some("codex"))
            .unwrap();
        let identity_b = account_b
            .history_identity(&bundle, Some("codex"))
            .unwrap();

        let a = cache
            .load_or_refresh(&identity_a, true, || {
                Ok(history_bundle_fixture("account-a"))
            })
            .unwrap();
        let b = cache
            .load_or_refresh(&identity_b, true, || {
                Ok(history_bundle_fixture("account-b"))
            })
            .unwrap();

        assert_ne!(identity_a, identity_b);
        assert_eq!(a.recent_24h[0].label, "account-a");
        assert_eq!(b.recent_24h[0].label, "account-b");
    }

    #[test]
    fn different_selected_limits_do_not_share_history_identity() {
        let scope = quota_cache_scope(
            Path::new("shared-limit-home"),
            Some("sub:shared-limit-account".into()),
        );
        let bundle = measured_quota_bundle("Shared Limit User");

        let codex = scope.history_identity(&bundle, Some("codex")).unwrap();
        let spark = scope
            .history_identity(&bundle, Some("gpt-5.3-codex-spark"))
            .unwrap();

        assert_ne!(codex, spark);
    }

    #[test]
    fn missing_stable_account_key_or_plan_cannot_create_history_identity() {
        let scope = QuotaCacheScope {
            codex_home: PathBuf::from("unkeyed-home"),
            account_key: None,
            flight_fingerprint: [5; 32],
        };
        assert!(scope
            .history_identity(&measured_quota_bundle("Unknown User"), Some("codex"))
            .is_none());

        let keyed_scope = QuotaCacheScope {
            codex_home: PathBuf::from("unknown-plan-home"),
            account_key: Some("sub:unknown-plan".into()),
            flight_fingerprint: [6; 32],
        };
        let mut unknown_plan = measured_quota_bundle("Unknown User");
        unknown_plan.account.plan_label = "计划待读取".into();
        assert!(keyed_scope
            .history_identity(&unknown_plan, Some("codex"))
            .is_none());
        assert!(keyed_scope
            .history_identity(&measured_quota_bundle("Unknown User"), None)
            .is_none());
    }

    #[test]
    fn quota_child_process_removes_inherited_node_and_signing_env_overrides() {
        let mut command = Command::new("codex");

        configure_quota_child_process(&mut command, None);

        let envs = command.get_envs().collect::<Vec<_>>();
        for key in QUOTA_CHILD_ENV_REMOVE {
            assert!(envs
                .iter()
                .any(|(name, value)| *name == OsStr::new(key) && value.is_none()));
        }
    }

    #[test]
    fn quota_child_process_receives_selected_codex_home() {
        let mut command = Command::new("codex");
        let codex_home = std::env::temp_dir().join("codex-token-bar-selected-home");

        configure_quota_child_process(&mut command, Some(&codex_home));

        let envs = command.get_envs().collect::<Vec<_>>();
        assert!(envs.iter().any(|(name, value)| {
            *name == OsStr::new("CODEX_HOME")
                && value.is_some_and(|value| value == codex_home.as_os_str())
        }));
    }

    #[test]
    fn quota_app_server_disables_unrelated_plugin_startup_fetch() {
        let mut command = Command::new("codex");

        configure_quota_app_server_command(&mut command, None);

        let arguments = command
            .get_args()
            .map(|argument| argument.to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        assert_eq!(
            arguments,
            ["app-server", "--disable", "plugins", "--listen", "stdio://"]
        );
    }

    #[test]
    fn account_info_uses_read_plan_label_and_does_not_invent_pro() {
        let codex_home = std::env::temp_dir().join(format!(
            "codex-token-bar-account-info-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));

        assert_eq!(account_info(&codex_home, Some("Plus")).plan_label, "Plus");
        assert_eq!(account_info(&codex_home, None).plan_label, "计划待读取");
    }

    #[test]
    fn quota_cache_uses_short_ttl_for_failures() {
        let failure = Err("network unavailable".to_string());
        assert_eq!(
            cache_ttl(&failure, Duration::from_secs(30)),
            FAILURE_CACHE_TTL
        );

        let quota = parse_rate_limits(&json!({
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "limitName": "Codex",
                    "primary": { "usedPercent": 20, "resetsAt": 1781715600 },
                    "secondary": { "usedPercent": 0.4, "resetsAt": 1782144492 }
                }
            }
        }))
        .unwrap();
        let success = Ok(AccountQuotaBundle {
            updated_at: "2026-07-31T00:00:00Z".into(),
            attribution_identity: None,
            account: AccountInfo {
                display_name: "本地用户".into(),
                plan_label: "Pro".into(),
            },
            quota,
            quota_history_daily: Vec::new(),
            quota_history_24h: Vec::new(),
            quota_history_7d: Vec::new(),
            quota_history_30d: Vec::new(),
            warnings: Vec::new(),
            diagnostics: Vec::new(),
        });
        assert_eq!(
            cache_ttl(&success, Duration::from_secs(15)),
            Duration::from_secs(15)
        );
    }

    #[test]
    fn quota_history_and_failure_cache_keep_their_bounded_windows() {
        assert_eq!(HISTORY_CACHE_TTL, Duration::from_secs(5 * 60));
        assert_eq!(FAILURE_CACHE_TTL, Duration::from_secs(15));
    }

    #[test]
    fn quota_reads_are_single_bounded_attempts_with_frontend_owned_retry() {
        assert_eq!(RATE_LIMIT_READ_TIMEOUT, Duration::from_secs(12));
        assert_eq!(RESET_CREDIT_TIMEOUT, Duration::from_secs(14));
    }

    #[cfg(unix)]
    #[test]
    fn quota_stderr_large_output_does_not_block_successful_json_rpc() {
        let response = r#"{"jsonrpc":"2.0","id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":"Codex","primary":{"usedPercent":20,"resetsAt":1781715600},"secondary":{"usedPercent":40,"resetsAt":1782144492}}}}}"#;
        let command = quota_stderr_fixture_command(response, 4_096);

        let result = read_rate_limits_from_command(command, Duration::from_secs(3));

        assert!(result.is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn quota_stderr_json_rpc_error_path_still_terminates_reader() {
        let response = r#"{"jsonrpc":"2.0","id":2,"error":{"message":"fixture rpc error"}}"#;
        let command = quota_stderr_fixture_command(response, 4_096);

        let error = match read_rate_limits_from_command(command, Duration::from_secs(3)) {
            Ok(_) => panic!("fixture JSON-RPC error unexpectedly succeeded"),
            Err(error) => error,
        };

        assert_eq!(error, "fixture rpc error");
    }

    #[cfg(unix)]
    #[test]
    fn quota_initialize_rpc_error_returns_immediately_as_app_server_unavailable() {
        let mut command = Command::new("sh");
        command.arg("-c").arg(
            r#"
IFS= read -r _
printf '%s\n' '{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"fixture initialize failure"}}'
printf 'initialize-stderr-marker\n' >&2
"#,
        );
        let started = Instant::now();
        let error = match read_rate_limits_from_command(command, Duration::from_secs(3)) {
            Ok(_) => panic!("fixture initialize error unexpectedly succeeded"),
            Err(error) => error,
        };

        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(error.contains("fixture initialize failure"));
        assert!(error.contains("initialize-stderr-marker"));
        assert_eq!(
            classify_quota_error("account_quota", &error).category,
            "app_server_unavailable"
        );
    }

    #[cfg(unix)]
    #[test]
    fn quota_initialize_response_without_result_returns_structured_app_server_error() {
        let mut command = Command::new("sh");
        command.arg("-c").arg(
            r#"
IFS= read -r _
printf '%s\n' '{"jsonrpc":"2.0","id":1}'
"#,
        );
        let started = Instant::now();
        let error = match read_rate_limits_from_command(command, Duration::from_secs(3)) {
            Ok(_) => panic!("fixture initialize response unexpectedly succeeded"),
            Err(error) => error,
        };

        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(error.contains("initialize 响应缺少 result"));
        assert_eq!(
            classify_quota_error("account_quota", &error).category,
            "app_server_unavailable"
        );
    }

    #[cfg(unix)]
    #[test]
    fn quota_stdout_eof_before_response_returns_immediately_with_exit_details() {
        let mut command = Command::new("sh");
        command.arg("-c").arg(
            r#"
IFS= read -r _
printf 'early-exit-stderr-marker\n' >&2
exit 17
"#,
        );
        let started = Instant::now();
        let error = match read_rate_limits_from_command(command, Duration::from_secs(3)) {
            Ok(_) => panic!("fixture early exit unexpectedly succeeded"),
            Err(error) => error,
        };

        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(error.contains("stdout EOF"));
        assert!(error.contains("early-exit-stderr-marker"));
        assert!(error.contains("17"));
        assert_eq!(
            classify_quota_error("account_quota", &error).category,
            "app_server_unavailable"
        );
    }

    #[cfg(unix)]
    #[test]
    fn quota_stderr_timeout_remains_primary_and_includes_bounded_tail() {
        let mut command = Command::new("sh");
        command
            .arg("-c")
            .arg("IFS= read -r _; printf 'timeout-tail-marker\\n' >&2; IFS= read -r _");

        let error = match read_rate_limits_from_command(command, Duration::from_millis(100)) {
            Ok(_) => panic!("fixture timeout unexpectedly succeeded"),
            Err(error) => error,
        };

        assert!(error.starts_with("额度读取超时"));
        assert!(error.contains("timeout-tail-marker"));
        assert_eq!(classify_quota_error("account_quota", &error).category, "timeout");
    }

    #[test]
    fn quota_child_guard_cleans_child_when_dropped() {
        use std::sync::atomic::{AtomicBool, Ordering};

        struct ProbeChild {
            killed: Arc<AtomicBool>,
            waited: Arc<AtomicBool>,
        }

        impl QuotaChildProcess for ProbeChild {
            fn kill_for_cleanup(&mut self) {
                self.killed.store(true, Ordering::Relaxed);
            }

            fn wait_for_cleanup(&mut self) {
                self.waited.store(true, Ordering::Relaxed);
            }
        }

        let killed = Arc::new(AtomicBool::new(false));
        let waited = Arc::new(AtomicBool::new(false));
        {
            let _guard = QuotaChildGuard::new(ProbeChild {
                killed: killed.clone(),
                waited: waited.clone(),
            });
        }

        assert!(killed.load(Ordering::Relaxed));
        assert!(waited.load(Ordering::Relaxed));
    }

    #[cfg(unix)]
    fn quota_stderr_fixture_command(response: &str, stderr_lines: usize) -> Command {
        let mut command = Command::new("sh");
        command
            .arg("-c")
            .arg(
                r#"
i=0
while [ "$i" -lt "$2" ]; do
  printf 'stderr-padding-0123456789abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMN\n' >&2
  i=$((i + 1))
done
printf 'stderr-final-marker\n' >&2
IFS= read -r _
printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
IFS= read -r _
IFS= read -r _
printf '%s\n' "$1"
"#,
            )
            .arg("quota-stderr-fixture")
            .arg(response)
            .arg(stderr_lines.to_string());
        command
    }

    #[test]
    fn quota_child_guard_cleans_up_on_early_drop() {
        use std::sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        };

        #[derive(Clone)]
        struct ProbeChild {
            killed: Arc<AtomicBool>,
            waited: Arc<AtomicBool>,
        }

        impl QuotaChildProcess for ProbeChild {
            fn kill_for_cleanup(&mut self) {
                self.killed.store(true, Ordering::Relaxed);
            }

            fn wait_for_cleanup(&mut self) {
                self.waited.store(true, Ordering::Relaxed);
            }
        }

        let child = ProbeChild {
            killed: Arc::new(AtomicBool::new(false)),
            waited: Arc::new(AtomicBool::new(false)),
        };
        let killed = child.killed.clone();
        let waited = child.waited.clone();

        {
            let _guard = QuotaChildGuard::new(child);
        }

        assert!(killed.load(Ordering::Relaxed));
        assert!(waited.load(Ordering::Relaxed));
    }

    #[test]
    fn quota_failure_bundle_keeps_failure_reason_visible() {
        let codex_home = std::env::temp_dir().join(format!(
            "codex-token-bar-quota-failure-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));

        let bundle = quota_failure_bundle(
            &codex_home,
            "Codex stdout 不可用\n请确认 Codex Desktop 已启动".to_string(),
        );

        assert_eq!(bundle.quota.pace_label, "额度读取失败");
        assert!(bundle.warnings.iter().any(|warning| {
            warning.source == "account_quota"
                && warning.message.contains("Codex 本地服务启动失败")
        }));
        assert!(bundle.diagnostics.iter().any(|diagnostic| {
            diagnostic.source == "account_quota"
                && diagnostic.category == "app_server_unavailable"
                && diagnostic
                    .raw_cause
                    .as_deref()
                    .is_some_and(|raw| raw.contains("Codex stdout 不可用 请确认 Codex Desktop 已启动"))
        }));
        assert!(!bundle.warnings.iter().any(|warning| warning.source == "reset_credit"));
        assert_eq!(bundle.quota.reset_credit.status, "重置卡待读取");
    }

    #[test]
    fn compact_error_message_keeps_long_diagnostics_visible() {
        let compact = compact_error_message(" first line\n\nsecond\tline ");
        assert_eq!(compact, "first line second line");

        let long = "错".repeat(900);
        let compact = compact_error_message(&long);
        assert_eq!(compact.chars().count(), 721);
        assert!(compact.ends_with('…'));
    }

    #[test]
    fn quota_error_explanation_names_common_failure_types() {
        assert!(explain_quota_error("未找到 access token").contains("登录凭证缺失"));
        assert!(explain_quota_error("error sending request for url: dns error").contains("网络连接失败"));
        assert!(explain_quota_error("failed to fetch codex rate limits: error sending request for url (https://chatgpt.com/backend-api/wham/usage)").contains("网络连接失败"));
        assert!(explain_quota_error("HTTP 401 Unauthorized").contains("登录或权限失败"));
        assert!(explain_quota_error("额度读取超时").contains("读取超时"));
        assert!(explain_quota_error("invalid json response").contains("接口响应解析失败"));
    }

    #[test]
    fn quota_error_classifier_returns_structured_categories() {
        let cases = [
            ("未找到 access token", "auth_missing", None, false),
            ("未找到 Codex，可在 CODEX_CLI_PATH 指定 codex.exe", "app_server_unavailable", None, true),
            (
                "Codex app-server 不可用：initialize 返回 error：network unavailable",
                "app_server_unavailable",
                None,
                true,
            ),
            ("额度读取超时（12 秒）", "timeout", None, true),
            ("error sending request for url: dns error", "network_send_fetch", None, true),
            ("HTTP 401 Unauthorized", "http_auth", Some(401), false),
            ("HTTP 429 Too Many Requests", "http_rate_limited", Some(429), true),
            ("HTTP 503 Service Unavailable", "http_server", Some(503), true),
            ("HTTP 418 I'm a teapot", "http_other", Some(418), true),
            ("invalid json response", "parse_failure", None, true),
            ("额度暂无数据", "empty_quota", None, true),
        ];

        for (raw, category, status, retryable) in cases {
            let diagnostic = classify_quota_error("account_quota", raw);
            assert_eq!(diagnostic.category, category);
            assert_eq!(diagnostic.raw_cause.as_deref(), Some(raw));
            assert_eq!(diagnostic.http_status, status);
            assert_eq!(diagnostic.retryable, retryable);
            assert_eq!(diagnostic.source, "account_quota");
            assert!(!diagnostic.message.contains(raw) || raw.starts_with("HTTP "));
        }
    }

    #[test]
    fn quota_error_classifier_uses_full_raw_error_before_compaction() {
        let warn = r#"{"timestamp":"2026-07-02T09:14:44.104640Z","level":"WARN","fields":{"message":"ignoring interface.defaultPrompt[0]: prompt must be at most 128 characters","path":"/Users/example/.codex/.tmp/plugins/plugins/ngs-analysis/.codex-plugin/plugin.json"},"target":"codex_core_plugins::manifest"}"#;
        let error = r#"{"timestamp":"2026-07-02T09:14:48.241751Z","level":"ERROR","fields":{"message":"failed to refresh available models: timeout while fetching models"},"target":"codex_core::model_provider"}"#;
        let raw = format!("{warn} {} {error}", "noise ".repeat(140));

        let diagnostic = classify_quota_error("account_quota", &raw);

        assert_eq!(diagnostic.category, "timeout");
        assert!(diagnostic.message.contains("读取超时"));
        assert!(diagnostic
            .raw_cause
            .as_deref()
            .is_some_and(|raw| raw.chars().count() <= 721));
    }

    #[test]
    fn quota_deadline_error_keeps_timeout_primary_with_noisy_stderr() {
        let stderr = r#"{"timestamp":"2026-07-06T01:00:00Z","level":"WARN","fields":{"message":"ignoring plugin manifest","path":"/tmp/plugin.json"},"target":"codex_core_plugins::manifest"}
{"timestamp":"2026-07-06T01:00:01Z","level":"ERROR","fields":{"message":"failed to refresh available models: timeout while fetching models"},"target":"codex_core::model_provider"}"#;

        let raw = quota_deadline_error(Duration::from_secs(12), Some(stderr));
        let diagnostic = classify_quota_error("account_quota", &raw);

        assert_eq!(diagnostic.category, "timeout");
        assert!(diagnostic.message.contains("读取超时"));
        assert!(diagnostic
            .raw_cause
            .as_deref()
            .is_some_and(|raw| raw.contains("额度读取超时（12 秒）")));
        assert!(diagnostic
            .raw_cause
            .as_deref()
            .is_some_and(|raw| raw.contains("failed to refresh available models")));
    }

    #[test]
    fn quota_deadline_error_is_timeout_even_when_stderr_has_only_plugin_noise() {
        let stderr = r#"{"timestamp":"2026-07-06T01:00:00Z","level":"WARN","fields":{"message":"ignoring plugin manifest","path":"/tmp/plugin.json"},"target":"codex_core_plugins::manifest"}"#;

        let raw = quota_deadline_error(Duration::from_secs(12), Some(stderr));
        let diagnostic = classify_quota_error("account_quota", &raw);

        assert_eq!(diagnostic.category, "timeout");
        assert!(diagnostic.message.contains("读取超时"));
        assert!(diagnostic
            .raw_cause
            .as_deref()
            .is_some_and(|raw| raw.contains("ignoring plugin manifest")));
    }

    #[test]
    fn quota_error_classifier_does_not_treat_json_file_paths_as_parse_failures() {
        let diagnostic = classify_quota_error(
            "account_quota",
            r#"{"fields":{"message":"ignoring plugin manifest","path":"/tmp/plugin.json"}}"#,
        );

        assert_eq!(diagnostic.category, "unknown");
    }

    #[test]
    fn reset_credit_diagnostic_wraps_underlying_category() {
        let diagnostic = reset_credit_diagnostic("error sending request for url: dns error");

        assert_eq!(diagnostic.source, "reset_credit");
        assert_eq!(diagnostic.category, "reset_credit_failure");
        assert_eq!(diagnostic.underlying_category.as_deref(), Some("network_send_fetch"));
        assert_eq!(
            diagnostic.raw_cause.as_deref(),
            Some("error sending request for url: dns error")
        );
        assert!(diagnostic.message.contains("重置卡读取失败"));
        assert!(diagnostic.message.contains("网络连接失败"));
        assert!(diagnostic.retryable);
    }

    #[test]
    fn reset_credit_channel_failure_is_structured_without_mutating_main_quota() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-reset-failure-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        write_test_auth_subject(&root, "reset-failure");

        let bundle = read_account_reset_credits_with_loader(&root, true, |_| {
            Err("error sending request for url: dns error".into())
        })
        .unwrap();

        assert!(!bundle.successful);
        assert_eq!(bundle.reset_credit.available_count, 0);
        assert!(bundle.diagnostics.iter().any(|diagnostic| {
            diagnostic.source == "reset_credit"
                && diagnostic.category == "reset_credit_failure"
                && diagnostic.underlying_category.as_deref() == Some("network_send_fetch")
        }));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn reset_credit_cache_reuses_success_and_force_refresh_bypasses_it() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-reset-cache-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        write_test_auth_subject(&root, "reset-cache");
        let calls = Arc::new(AtomicUsize::new(0));

        let first_calls = calls.clone();
        let first = read_account_reset_credits_with_loader(&root, false, move |_| {
            first_calls.fetch_add(1, Ordering::SeqCst);
            Ok(reset_credit_summary_fixture(1))
        })
        .unwrap();
        let cached_calls = calls.clone();
        let cached = read_account_reset_credits_with_loader(&root, false, move |_| {
            cached_calls.fetch_add(1, Ordering::SeqCst);
            Ok(reset_credit_summary_fixture(99))
        })
        .unwrap();
        let forced_calls = calls.clone();
        let forced = read_account_reset_credits_with_loader(&root, true, move |_| {
            forced_calls.fetch_add(1, Ordering::SeqCst);
            Ok(reset_credit_summary_fixture(2))
        })
        .unwrap();

        assert_eq!(first.reset_credit.available_count, 1);
        assert_eq!(cached.reset_credit.available_count, 1);
        assert_eq!(forced.reset_credit.available_count, 2);
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn concurrent_forced_reset_credit_reads_join_one_flight() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-reset-flight-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        write_test_auth_subject(&root, "reset-flight");
        let calls = Arc::new(AtomicUsize::new(0));
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();

        let first_root = root.clone();
        let first_calls = calls.clone();
        let first = thread::spawn(move || {
            read_account_reset_credits_with_loader(&first_root, true, move |_| {
                first_calls.fetch_add(1, Ordering::SeqCst);
                entered_tx.send(()).unwrap();
                release_rx.recv().unwrap();
                Ok(reset_credit_summary_fixture(1))
            })
            .unwrap()
        });
        entered_rx.recv().unwrap();

        let second_root = root.clone();
        let second_calls = calls.clone();
        let second = thread::spawn(move || {
            read_account_reset_credits_with_loader(&second_root, true, move |_| {
                second_calls.fetch_add(1, Ordering::SeqCst);
                Ok(reset_credit_summary_fixture(2))
            })
            .unwrap()
        });
        thread::sleep(Duration::from_millis(30));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        release_tx.send(()).unwrap();

        let first_bundle = first.join().unwrap();
        let second_bundle = second.join().unwrap();
        assert_eq!(first_bundle.reset_credit.available_count, 1);
        assert_eq!(second_bundle.reset_credit.available_count, 1);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn quota_failure_bundle_projects_structured_diagnostics_to_warnings() {
        let codex_home = std::env::temp_dir().join(format!(
            "codex-token-bar-quota-diagnostic-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));

        let bundle = quota_failure_bundle(
            &codex_home,
            "HTTP 429 Too Many Requests".to_string(),
        );

        assert!(OffsetDateTime::parse(&bundle.updated_at, &Rfc3339).is_ok());
        assert!(bundle.attribution_identity.is_none());

        assert!(bundle
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.source == "account_quota"
                && diagnostic.category == "http_rate_limited"
                && diagnostic.raw_cause.as_deref() == Some("HTTP 429 Too Many Requests")
                && diagnostic.http_status == Some(429)
                && diagnostic.retryable));
        assert!(!bundle
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.source == "reset_credit"));
        assert!(bundle.warnings.iter().any(|warning| {
            warning.source == "account_quota"
                && warning.message.contains("请求过于频繁")
        }));
        assert!(!bundle
            .warnings
            .iter()
            .any(|warning| warning.source == "reset_credit"));
    }

    #[test]
    fn stale_quota_bundle_preserves_previous_success_after_timeout_failure() {
        let mut previous = quota_bundle_fixture(
            "current",
            parse_rate_limits(&json!({
                "rateLimitsByLimitId": {
                    "codex": {
                        "limitId": "codex",
                        "limitName": "Codex",
                        "primary": { "usedPercent": 20, "resetsAt": 1781715600 },
                        "secondary": { "usedPercent": 40, "resetsAt": 1782144492 }
                    }
                }
            }))
            .unwrap(),
            Vec::new(),
            Vec::new(),
        );
        previous.updated_at = "2026-07-30T08:20:35Z".into();
        previous.attribution_identity = Some(crate::models::QuotaAttributionIdentity {
            scope_key: format!("sha256:{}", "a".repeat(64)),
            plan: "Pro".into(),
            limit: "codex".into(),
        });
        previous
            .quota_history_24h
            .push(crate::models::QuotaHistoryPoint {
                label: "trusted".into(),
                start_unix: 1,
                five_hour_remaining_percent: Some(0.8),
                seven_day_remaining_percent: Some(0.6),
                five_hour_cycle_id: None,
                seven_day_cycle_id: None,
            });
        let mut failed_quota = placeholder_quota();
        failed_quota.pace_label = "额度读取失败".into();
        let timeout = classify_quota_error(
            "account_quota",
            &quota_deadline_error(Duration::from_secs(12), Some("plugin manifest WARN")),
        );
        let mut failed = quota_bundle_fixture(
            "failed",
            failed_quota,
            diagnostics_to_warnings(&[timeout.clone()]),
            vec![timeout],
        );
        failed.updated_at = "2026-07-31T08:20:35Z".into();

        let stale = stale_quota_bundle(previous.clone(), failed);

        assert_eq!(stale.updated_at, previous.updated_at);
        assert_eq!(stale.attribution_identity, previous.attribution_identity);
        assert_eq!(stale.quota.five_hour.resets_at_unix, previous.quota.five_hour.resets_at_unix);
        assert_eq!(stale.quota.seven_day.resets_at_unix, previous.quota.seven_day.resets_at_unix);
        assert_eq!(stale.quota.pace_label, previous.quota.pace_label);
        assert_eq!(stale.quota_history_24h[0].label, "trusted");
        assert!(stale.diagnostics.iter().any(|diagnostic| {
            diagnostic.source == "account_quota"
                && diagnostic.category == "timeout"
                && diagnostic.stale_data_displayed
        }));
        assert!(stale.diagnostics.iter().any(|diagnostic| {
            diagnostic.source == "account_quota"
                && diagnostic.category == "stale_cached_data"
                && diagnostic.stale_data_displayed
        }));
        assert!(stale
            .warnings
            .iter()
            .any(|warning| warning.message.contains("显示上次成功额度")));
    }

    #[test]
    fn forced_quota_refresh_coalesces_only_recent_cache_entries() {
        let codex_home = std::env::temp_dir().join(format!(
            "codex-token-bar-quota-cache-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let bundle = AccountQuotaBundle {
            updated_at: "2026-07-31T00:00:00Z".into(),
            attribution_identity: None,
            account: AccountInfo {
                display_name: "本地用户".into(),
                plan_label: "Pro".into(),
            },
            quota: parse_rate_limits(&json!({
                "rateLimitsByLimitId": {
                    "codex": {
                        "limitId": "codex",
                        "limitName": "Codex",
                        "primary": { "usedPercent": 20, "resetsAt": 1781715600 },
                        "secondary": { "usedPercent": 40, "resetsAt": 1782144492 }
                    }
                }
            }))
            .unwrap(),
            quota_history_daily: Vec::new(),
            quota_history_24h: Vec::new(),
            quota_history_7d: Vec::new(),
            quota_history_30d: Vec::new(),
            warnings: Vec::new(),
            diagnostics: Vec::new(),
        };
        let cache = QUOTA_READ_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
        let scope = quota_cache_scope(&codex_home, Some("sub:test".into()));

        {
            let mut guard = cache.lock().unwrap();
            guard.insert(
                scope.codex_home.clone(),
                QuotaCacheEntry {
                    scope: scope.clone(),
                    result: Ok(bundle.clone()),
                    cached_at: Instant::now(),
                },
            );
        }
        assert!(cached_quota_result(&scope, true, Duration::from_secs(30))
            .unwrap()
            .is_none());
        assert!(
            cached_quota_result_after_inflight(&scope, true, Duration::from_secs(30))
                .unwrap()
                .is_some()
        );

        {
            let mut guard = cache.lock().unwrap();
            guard.insert(
                scope.codex_home.clone(),
                QuotaCacheEntry {
                    scope: scope.clone(),
                    result: Ok(bundle),
                    cached_at: Instant::now()
                        .checked_sub(FORCED_REFRESH_COALESCE_TTL + Duration::from_millis(1))
                        .unwrap(),
                },
            );
        }
        assert!(
            cached_quota_result_after_inflight(&scope, true, Duration::from_secs(30))
                .unwrap()
                .is_none()
        );

        let mut guard = cache.lock().unwrap();
        guard.remove(&scope.codex_home);
    }

    #[test]
    fn explicit_quota_retry_bypasses_cached_failure_placeholders() {
        let codex_home = std::env::temp_dir().join(format!(
            "codex-token-bar-quota-cache-failure-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let cache = QUOTA_READ_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
        let scope = quota_cache_scope(&codex_home, None);
        {
            let mut guard = cache.lock().unwrap();
            guard.insert(
                scope.codex_home.clone(),
                QuotaCacheEntry {
                    scope: scope.clone(),
                    result: Ok(quota_failure_bundle(
                        &codex_home,
                        "error sending request for url: dns error".to_string(),
                    )),
                    cached_at: Instant::now(),
                },
            );
        }

        assert!(cached_quota_result(&scope, false, Duration::from_secs(30))
            .unwrap()
            .is_some());
        assert!(cached_quota_result(&scope, true, Duration::from_secs(30))
            .unwrap()
            .is_none());
        assert!(
            cached_quota_result_after_inflight(&scope, true, Duration::from_secs(30))
                .unwrap()
                .is_some()
        );

        let mut guard = cache.lock().unwrap();
        guard.remove(&scope.codex_home);
    }

    fn quota_bundle_fixture(
        name: &str,
        quota: QuotaSnapshot,
        warnings: Vec<LocalDataWarning>,
        diagnostics: Vec<QuotaDiagnostic>,
    ) -> AccountQuotaBundle {
        AccountQuotaBundle {
            updated_at: "2026-07-31T00:00:00Z".into(),
            attribution_identity: None,
            account: AccountInfo {
                display_name: name.into(),
                plan_label: "Pro".into(),
            },
            quota,
            quota_history_daily: Vec::new(),
            quota_history_24h: Vec::new(),
            quota_history_7d: Vec::new(),
            quota_history_30d: Vec::new(),
            warnings,
            diagnostics,
        }
    }

    fn measured_quota_bundle(name: &str) -> AccountQuotaBundle {
        quota_bundle_fixture(
            name,
            parse_rate_limits(&json!({
                "rateLimits": {
                    "primary": { "usedPercent": 20, "resetsAt": 1781715600 },
                    "secondary": { "usedPercent": 40, "resetsAt": 1782144492 }
                }
            }))
            .unwrap(),
            Vec::new(),
            Vec::new(),
        )
    }

    fn history_bundle_fixture(label: &str) -> quota_history::QuotaHistoryBundle {
        quota_history::QuotaHistoryBundle {
            recent_24h: vec![crate::models::QuotaHistoryPoint {
                label: label.into(),
                start_unix: 1,
                five_hour_remaining_percent: Some(0.8),
                seven_day_remaining_percent: Some(0.6),
                five_hour_cycle_id: None,
                seven_day_cycle_id: None,
            }],
            ..Default::default()
        }
    }

    fn write_test_auth_subject(home: &Path, subject: &str) {
        use base64::Engine as _;

        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(format!(r#"{{"sub":"{subject}"}}"#));
        std::fs::write(
            home.join("auth.json"),
            format!(r#"{{"tokens":{{"id_token":"header.{payload}.signature"}}}}"#),
        )
        .unwrap();
    }

    fn reset_credit_summary_fixture(available_count: u32) -> ResetCreditSummary {
        ResetCreditSummary {
            available_count,
            status: "重置卡已更新".into(),
            credits: Vec::new(),
        }
    }
}
