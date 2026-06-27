use crate::core::quota_history;
use crate::models::{AccountInfo, AccountQuotaBundle, QuotaSnapshot, ResetCreditSummary};
use auth::read_local_account_name;
use codex_binary::find_codex_binary_with_report;
use rate_limits::parse_rate_limits;
use reset_credit::read_reset_credits;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{mpsc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

const SUCCESS_CACHE_TTL: Duration = Duration::from_secs(5 * 60);
const FAILURE_CACHE_TTL: Duration = Duration::from_secs(15);
const HISTORY_CACHE_TTL: Duration = Duration::from_secs(5 * 60);
const FORCED_REFRESH_COALESCE_TTL: Duration = Duration::from_secs(5);

mod auth;
mod codex_binary;
mod rate_limits;
mod reset_credit;

static QUOTA_READ_CACHE: OnceLock<Mutex<Option<QuotaCacheEntry>>> = OnceLock::new();
static QUOTA_HISTORY_CACHE: OnceLock<Mutex<QuotaHistoryMemoryCache>> = OnceLock::new();
static QUOTA_READ_GATE: OnceLock<Mutex<()>> = OnceLock::new();

#[derive(Clone)]
struct QuotaCacheEntry {
    codex_home: std::path::PathBuf,
    result: Result<AccountQuotaBundle, String>,
    cached_at: Instant,
}

#[derive(Clone)]
struct QuotaHistoryCacheEntry {
    bundle: quota_history::QuotaHistoryBundle,
    cached_at: Instant,
}

#[derive(Default)]
struct QuotaHistoryMemoryCache {
    entry: Option<QuotaHistoryCacheEntry>,
}

impl QuotaHistoryMemoryCache {
    fn load_or_refresh<F>(
        &mut self,
        force_refresh: bool,
        mut loader: F,
    ) -> Result<quota_history::QuotaHistoryBundle, String>
    where
        F: FnMut() -> Result<quota_history::QuotaHistoryBundle, String>,
    {
        if !force_refresh {
            if let Some(entry) = &self.entry {
                if entry.cached_at.elapsed() <= HISTORY_CACHE_TTL {
                    return Ok(entry.bundle.clone());
                }
            }
        }

        let bundle = loader()?;
        self.entry = Some(QuotaHistoryCacheEntry {
            bundle: bundle.clone(),
            cached_at: Instant::now(),
        });
        Ok(bundle)
    }
}

pub fn read_account_quota(codex_home: &Path, force_refresh: bool) -> Result<AccountQuotaBundle, String> {
    if let Some(cached) = cached_quota_result(codex_home, force_refresh)? {
        return resolve_cached_quota(cached);
    }

    let gate = QUOTA_READ_GATE.get_or_init(|| Mutex::new(()));
    let _read_guard = gate.lock().map_err(|error| error.to_string())?;
    if let Some(cached) = cached_quota_result(codex_home, force_refresh)? {
        return resolve_cached_quota(cached);
    }

    let result = read_account_quota_uncached(codex_home);
    let cache = QUOTA_READ_CACHE.get_or_init(|| Mutex::new(None));
    let mut guard = cache.lock().map_err(|error| error.to_string())?;
    *guard = Some(QuotaCacheEntry {
        codex_home: codex_home.to_path_buf(),
        cached_at: Instant::now(),
        result: result.clone(),
    });
    result
}

fn cached_quota_result(
    codex_home: &Path,
    force_refresh: bool,
) -> Result<Option<Result<AccountQuotaBundle, String>>, String> {
    let cache = QUOTA_READ_CACHE.get_or_init(|| Mutex::new(None));
    let guard = cache.lock().map_err(|error| error.to_string())?;
    Ok(guard
        .as_ref()
        .filter(|entry| {
            entry.codex_home == codex_home
                && entry.cached_at.elapsed()
                    <= if force_refresh {
                        FORCED_REFRESH_COALESCE_TTL
                    } else {
                        cache_ttl(&entry.result)
                    }
        })
        .map(|entry| entry.result.clone()))
}

fn resolve_cached_quota(cached: Result<AccountQuotaBundle, String>) -> Result<AccountQuotaBundle, String> {
    match cached {
        Ok(mut bundle) => {
            refresh_quota_histories(&mut bundle, false);
            Ok(bundle)
        }
        Err(error) => Err(error),
    }
}

fn cache_ttl(result: &Result<AccountQuotaBundle, String>) -> Duration {
    if result
        .as_ref()
        .is_ok_and(|bundle| quota_available(&bundle.quota))
    {
        SUCCESS_CACHE_TTL
    } else {
        FAILURE_CACHE_TTL
    }
}

fn quota_available(quota: &QuotaSnapshot) -> bool {
    quota.five_hour.resets_at_unix.is_some() || quota.seven_day.resets_at_unix.is_some()
}

fn read_account_quota_uncached(codex_home: &Path) -> Result<AccountQuotaBundle, String> {
    let mut bundle = match read_rate_limits() {
        Ok(mut quota) => {
            quota.reset_credit = read_reset_credits(codex_home).unwrap_or_else(|_| ResetCreditSummary {
                available_count: 0,
                status: "重置卡获取失败".into(),
                credits: Vec::new(),
            });
            let mut bundle = AccountQuotaBundle {
                account: account_info(codex_home, Some(&quota)),
                quota,
                quota_history_daily: Vec::new(),
                quota_history_24h: Vec::new(),
                quota_history_7d: Vec::new(),
                quota_history_30d: Vec::new(),
                warnings: Vec::new(),
            };
            if let Err(error) = quota_history::record_bundle(&bundle) {
                bundle.warnings.push(quota_history::warning(error));
            }
            refresh_quota_histories(&mut bundle, true);
            bundle
        }
        Err(error) => return Err(format!("额度读取失败：{error}")),
    };

    if bundle.quota.reset_credit.status == "重置卡待读取" {
        bundle.quota.reset_credit =
            read_reset_credits(codex_home).unwrap_or_else(|_| ResetCreditSummary {
                available_count: 0,
                status: "重置卡获取失败".into(),
                credits: Vec::new(),
            });
    }

    Ok(bundle)
}

fn refresh_quota_histories(bundle: &mut AccountQuotaBundle, force_refresh: bool) {
    let cache = QUOTA_HISTORY_CACHE.get_or_init(|| Mutex::new(QuotaHistoryMemoryCache::default()));
    let history = cache
        .lock()
        .map_err(|error| error.to_string())
        .and_then(|mut cache| {
            cache.load_or_refresh(force_refresh, || quota_history::history_bundle(365))
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

pub fn account_info(codex_home: &Path, quota: Option<&QuotaSnapshot>) -> AccountInfo {
    AccountInfo {
        display_name: read_local_account_name(codex_home).unwrap_or_else(|| "Codex Token Bar".into()),
        plan_label: quota
            .and_then(plan_label_from_quota)
            .unwrap_or_else(|| "Pro".into()),
    }
}

fn plan_label_from_quota(quota: &QuotaSnapshot) -> Option<String> {
    if quota.five_hour.resets_at != "待读取" || quota.seven_day.resets_at != "待读取" {
        Some("Pro".into())
    } else {
        None
    }
}

fn read_rate_limits() -> Result<QuotaSnapshot, String> {
    let codex = find_codex_binary_with_report()?.path;
    let mut child = Command::new(codex)
        .args(["app-server", "--listen", "stdio://"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("启动 Codex 失败：{error}"))?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "Codex stdout 不可用".to_string())?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| "Codex stdin 不可用".to_string())?;
    let stderr = child.stderr.take();
    let (sender, receiver) = mpsc::channel();

    thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if let Ok(value) = serde_json::from_str::<Value>(&line) {
                let _ = sender.send(value);
            }
        }
    });

    let cleanup = |child: &mut std::process::Child| {
        let _ = child.kill();
        let _ = child.wait();
    };

    write_json_line(
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
    )?;

    let deadline = Instant::now() + Duration::from_secs(8);
    let mut read_sent = false;
    while Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let Ok(message) = receiver.recv_timeout(remaining.min(Duration::from_millis(500))) else {
            continue;
        };

        if message.get("id").and_then(Value::as_i64) == Some(1)
            && message.get("result").is_some()
            && !read_sent
        {
            write_json_line(&mut stdin, &json!({"jsonrpc": "2.0", "method": "initialized"}))?;
            write_json_line(
                &mut stdin,
                &json!({"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"}),
            )?;
            read_sent = true;
            continue;
        }

        if message.get("id").and_then(Value::as_i64) == Some(2) {
            cleanup(&mut child);
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
            return parse_rate_limits(result);
        }
    }

    cleanup(&mut child);
    if let Some(mut stderr) = stderr {
        let mut text = String::new();
        let _ = std::io::Read::read_to_string(&mut stderr, &mut text);
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            return Err(trimmed.to_string());
        }
    }
    Err("额度读取超时".into())
}

fn write_json_line(stdin: &mut std::process::ChildStdin, value: &Value) -> Result<(), String> {
    serde_json::to_writer(&mut *stdin, value).map_err(|error| error.to_string())?;
    stdin.write_all(b"\n").map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quota_history_cache_reuses_recent_bundle_until_forced() {
        use std::cell::Cell;

        let mut cache = QuotaHistoryMemoryCache::default();
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
                }],
                ..Default::default()
            })
        };

        let first = cache.load_or_refresh(false, &mut loader).unwrap();
        let second = cache.load_or_refresh(false, &mut loader).unwrap();
        assert_eq!(load_count.get(), 1);
        assert_eq!(first.recent_24h[0].label, "load-1");
        assert_eq!(second.recent_24h[0].label, "load-1");

        let forced = cache.load_or_refresh(true, &mut loader).unwrap();
        assert_eq!(load_count.get(), 2);
        assert_eq!(forced.recent_24h[0].label, "load-2");
    }

    #[test]
    fn quota_cache_uses_short_ttl_for_failures() {
        let failure = Err("network unavailable".to_string());
        assert_eq!(cache_ttl(&failure), FAILURE_CACHE_TTL);

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
        });
        assert_eq!(cache_ttl(&success), SUCCESS_CACHE_TTL);
    }

    #[test]
    fn quota_success_cache_covers_dashboard_refresh_window() {
        assert_eq!(SUCCESS_CACHE_TTL, Duration::from_secs(5 * 60));
        assert_eq!(HISTORY_CACHE_TTL, Duration::from_secs(5 * 60));
        assert_eq!(FAILURE_CACHE_TTL, Duration::from_secs(15));
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
        };
        let cache = QUOTA_READ_CACHE.get_or_init(|| Mutex::new(None));

        {
            let mut guard = cache.lock().unwrap();
            *guard = Some(QuotaCacheEntry {
                codex_home: codex_home.clone(),
                result: Ok(bundle.clone()),
                cached_at: Instant::now(),
            });
        }
        assert!(cached_quota_result(&codex_home, true).unwrap().is_some());

        {
            let mut guard = cache.lock().unwrap();
            *guard = Some(QuotaCacheEntry {
                codex_home: codex_home.clone(),
                result: Ok(bundle),
                cached_at: Instant::now()
                    .checked_sub(FORCED_REFRESH_COALESCE_TTL + Duration::from_millis(1))
                    .unwrap(),
            });
        }
        assert!(cached_quota_result(&codex_home, true).unwrap().is_none());

        let mut guard = cache.lock().unwrap();
        *guard = None;
    }
}
