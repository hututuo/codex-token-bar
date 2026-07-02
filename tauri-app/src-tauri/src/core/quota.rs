use crate::core::quota_history;
use crate::models::{
    AccountInfo, AccountQuotaBundle, LocalDataWarning, QuotaSnapshot, ResetCreditSummary,
};
use auth::read_local_account_name;
use codex_binary::find_codex_binary_with_report;
use rate_limits::{parse_rate_limits, placeholder_quota};
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
            let mut warnings = Vec::new();
            quota.reset_credit = read_reset_credits(codex_home).unwrap_or_else(|error| {
                warnings.push(quota_warning(
                    "reset_credit",
                    format!("重置卡读取失败：{}", explain_quota_error(&error)),
                ));
                ResetCreditSummary {
                    available_count: 0,
                    status: reset_credit_failure_status(&error),
                    credits: Vec::new(),
                }
            });
            let mut bundle = AccountQuotaBundle {
                account: account_info(codex_home, Some(&quota)),
                quota,
                quota_history_daily: Vec::new(),
                quota_history_24h: Vec::new(),
                quota_history_7d: Vec::new(),
                quota_history_30d: Vec::new(),
                warnings,
            };
            if let Err(error) = quota_history::record_bundle(&bundle) {
                bundle.warnings.push(quota_history::warning(error));
            }
            refresh_quota_histories(&mut bundle, true);
            bundle
        }
        Err(error) => quota_failure_bundle(codex_home, error),
    };

    if bundle.quota.reset_credit.status == "重置卡待读取" {
        bundle.quota.reset_credit = read_reset_credits(codex_home).unwrap_or_else(|error| {
            bundle.warnings.push(quota_warning(
                "reset_credit",
                format!("重置卡读取失败：{}", explain_quota_error(&error)),
            ));
            ResetCreditSummary {
                available_count: 0,
                status: reset_credit_failure_status(&error),
                credits: Vec::new(),
            }
        });
    }

    Ok(bundle)
}

fn quota_failure_bundle(codex_home: &Path, error: String) -> AccountQuotaBundle {
    let mut quota = placeholder_quota();
    quota.pace_label = "额度读取失败".into();
    quota.reset_credit = read_reset_credits(codex_home).unwrap_or_else(|reset_error| {
        ResetCreditSummary {
            available_count: 0,
            status: reset_credit_failure_status(&reset_error),
            credits: Vec::new(),
        }
    });

    let mut bundle = AccountQuotaBundle {
        account: account_info(codex_home, Some(&quota)),
        quota,
        quota_history_daily: Vec::new(),
        quota_history_24h: Vec::new(),
        quota_history_7d: Vec::new(),
        quota_history_30d: Vec::new(),
        warnings: vec![quota_warning(
            "account_quota",
            format!("额度读取失败：{}", explain_quota_error(&error)),
        )],
    };
    if bundle.quota.reset_credit.status.starts_with("重置卡读取失败") {
        bundle.warnings.push(quota_warning(
            "reset_credit",
            bundle.quota.reset_credit.status.clone(),
        ));
    }
    refresh_quota_histories(&mut bundle, true);
    bundle
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

fn quota_warning(source: &str, message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: source.into(),
        message,
    }
}

fn reset_credit_failure_status(error: &str) -> String {
    format!("重置卡读取失败：{}", explain_quota_error(error))
}

fn compact_error_message(error: &str) -> String {
    let text = error.split_whitespace().collect::<Vec<_>>().join(" ");
    let text = text.trim();
    if text.chars().count() <= 180 {
        return text.to_string();
    }
    let mut truncated = text.chars().take(180).collect::<String>();
    truncated.push('…');
    truncated
}

fn explain_quota_error(error: &str) -> String {
    let compact = compact_error_message(error);
    let lower = compact.to_lowercase();

    if lower.contains("未找到 access token") || lower.contains("access token") {
        return format!(
            "登录凭证缺失：没有从 Codex 目录的 auth.json 读到 access token。请确认 Codex 已登录，且 Codex 目录选对。原始信息：{compact}"
        );
    }
    if compact.contains("未找到 Codex") || lower.contains("codex_cli_path") {
        return format!(
            "Codex 命令不可用：没有找到可用的 Codex app-server。请确认 Codex Desktop 已安装，或设置 CODEX_CLI_PATH。原始信息：{compact}"
        );
    }
    if compact.contains("启动 Codex 失败") || compact.contains("Codex stdout 不可用") || compact.contains("Codex stdin 不可用") {
        return format!(
            "Codex 本地服务启动失败：无法通过本机 Codex app-server 读取额度。请重启 Codex 后再点立即刷新。原始信息：{compact}"
        );
    }
    if compact.contains("额度读取超时") || lower.contains("timed out") || lower.contains("timeout") || compact.contains("超时") {
        return format!(
            "读取超时：本地 Codex 或网络接口在限定时间内没有返回。请稍后点立即刷新重试。原始信息：{compact}"
        );
    }
    if lower.contains("dns")
        || lower.contains("network")
        || lower.contains("connection")
        || lower.contains("connect")
        || compact.contains("网络")
        || compact.contains("连接")
    {
        return format!(
            "网络连接失败：请求 ChatGPT 额度接口时网络不可用、DNS 失败或连接被中断。原始信息：{compact}"
        );
    }
    if lower.contains("http 401") || lower.contains("http 403") {
        return format!(
            "登录或权限失败：额度接口返回 {compact}，可能是登录过期、账号无权限或 access token 已失效。请重新登录 Codex/ChatGPT 后刷新。"
        );
    }
    if lower.contains("http 429") {
        return format!(
            "请求过于频繁：额度接口返回 {compact}。请稍等一会儿再刷新。"
        );
    }
    if lower.contains("http 5") {
        return format!(
            "服务端错误：额度接口返回 {compact}。这通常是 ChatGPT 服务临时异常，稍后刷新即可。"
        );
    }
    if lower.contains("http ") {
        return format!(
            "接口返回异常：额度接口返回 {compact}。如果持续出现，请截图这个原因。"
        );
    }
    if lower.contains("json") || compact.contains("解析") || compact.contains("响应为空") || lower.contains("expected") {
        return format!(
            "接口响应解析失败：本地收到了额度响应，但格式不是当前版本能识别的结构。原始信息：{compact}"
        );
    }

    format!("未知原因：{compact}")
}

fn read_rate_limits() -> Result<QuotaSnapshot, String> {
    let codex = find_codex_binary_with_report()?.path;
    let mut command = Command::new(codex);
    configure_quota_child_process(&mut command);
    let mut child = command
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

fn configure_quota_child_process(command: &mut Command) {
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
                && warning.message.contains("Codex stdout 不可用 请确认 Codex Desktop 已启动")
        }));
        assert!(bundle
            .warnings
            .iter()
            .any(|warning| warning.source == "reset_credit" && warning.message.contains("重置卡读取失败")));
        assert!(bundle
            .quota
            .reset_credit
            .status
            .starts_with("重置卡读取失败"));
    }

    #[test]
    fn compact_error_message_normalizes_and_truncates() {
        let compact = compact_error_message(" first line\n\nsecond\tline ");
        assert_eq!(compact, "first line second line");

        let long = "错".repeat(220);
        let compact = compact_error_message(&long);
        assert_eq!(compact.chars().count(), 181);
        assert!(compact.ends_with('…'));
    }

    #[test]
    fn quota_error_explanation_names_common_failure_types() {
        assert!(explain_quota_error("未找到 access token").contains("登录凭证缺失"));
        assert!(explain_quota_error("error sending request for url: dns error").contains("网络连接失败"));
        assert!(explain_quota_error("HTTP 401 Unauthorized").contains("登录或权限失败"));
        assert!(explain_quota_error("额度读取超时").contains("读取超时"));
        assert!(explain_quota_error("invalid json response").contains("接口响应解析失败"));
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
