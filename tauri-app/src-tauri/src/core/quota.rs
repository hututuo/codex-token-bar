use crate::core::quota_history;
use crate::models::{
    AccountInfo, AccountQuotaBundle, LocalDataWarning, QuotaDiagnostic, QuotaSnapshot,
    ResetCreditSummary,
};
use auth::read_local_account_name;
use codex_binary::find_codex_binary_with_report;
use rate_limits::{parse_rate_limits, placeholder_quota};
use reset_credit::read_reset_credits;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::{mpsc, Mutex, OnceLock, TryLockError};
use std::thread;
use std::time::{Duration, Instant};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

const SUCCESS_CACHE_TTL: Duration = Duration::from_secs(5 * 60);
const FAILURE_CACHE_TTL: Duration = Duration::from_secs(15);
const HISTORY_CACHE_TTL: Duration = Duration::from_secs(5 * 60);
const FORCED_REFRESH_COALESCE_TTL: Duration = Duration::from_secs(5);
const RATE_LIMIT_READ_ATTEMPTS: usize = 3;
const RATE_LIMIT_READ_TIMEOUT: Duration = Duration::from_secs(12);
const RATE_LIMIT_RETRY_DELAY: Duration = Duration::from_millis(350);
pub(super) const RESET_CREDIT_READ_ATTEMPTS: usize = 3;
pub(super) const RESET_CREDIT_TIMEOUT: Duration = Duration::from_secs(14);

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
    let _read_guard = match gate.try_lock() {
        Ok(guard) => guard,
        Err(TryLockError::WouldBlock) => {
            let guard = gate.lock().map_err(|error| error.to_string())?;
            if let Some(cached) = cached_quota_result_after_inflight(codex_home, force_refresh)? {
                return resolve_cached_quota(cached);
            }
            guard
        }
        Err(TryLockError::Poisoned(error)) => return Err(error.to_string()),
    };
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
    cached_quota_result_with_policy(codex_home, force_refresh, false)
}

fn cached_quota_result_after_inflight(
    codex_home: &Path,
    force_refresh: bool,
) -> Result<Option<Result<AccountQuotaBundle, String>>, String> {
    cached_quota_result_with_policy(codex_home, force_refresh, true)
}

fn cached_quota_result_with_policy(
    codex_home: &Path,
    force_refresh: bool,
    after_inflight: bool,
) -> Result<Option<Result<AccountQuotaBundle, String>>, String> {
    let cache = QUOTA_READ_CACHE.get_or_init(|| Mutex::new(None));
    let guard = cache.lock().map_err(|error| error.to_string())?;
    Ok(guard
        .as_ref()
        .filter(|entry| {
            entry.codex_home == codex_home
                && reusable_cached_quota(entry, force_refresh, after_inflight)
        })
        .map(|entry| entry.result.clone()))
}

fn reusable_cached_quota(
    entry: &QuotaCacheEntry,
    force_refresh: bool,
    after_inflight: bool,
) -> bool {
    if !force_refresh {
        return entry.cached_at.elapsed() <= cache_ttl(&entry.result);
    }
    if entry.cached_at.elapsed() > FORCED_REFRESH_COALESCE_TTL {
        return false;
    }
    after_inflight || cache_result_has_real_quota(&entry.result)
}

fn cache_result_has_real_quota(result: &Result<AccountQuotaBundle, String>) -> bool {
    result
        .as_ref()
        .is_ok_and(|bundle| quota_available(&bundle.quota))
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
    if cache_result_has_real_quota(result) {
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
            let mut diagnostics = Vec::new();
            quota.reset_credit = read_reset_credits(codex_home).unwrap_or_else(|error| {
                let diagnostic = reset_credit_diagnostic(&error);
                warnings.push(warning_from_diagnostic(&diagnostic));
                diagnostics.push(diagnostic);
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
                diagnostics,
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
            let diagnostic = reset_credit_diagnostic(&error);
            bundle.warnings.push(warning_from_diagnostic(&diagnostic));
            bundle.diagnostics.push(diagnostic);
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
    let mut diagnostics = vec![classify_quota_error("account_quota", &error)];
    quota.reset_credit = read_reset_credits(codex_home).unwrap_or_else(|reset_error| {
        diagnostics.push(reset_credit_diagnostic(&reset_error));
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
        warnings: diagnostics_to_warnings(&diagnostics),
        diagnostics,
    };
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

fn warning_from_diagnostic(diagnostic: &QuotaDiagnostic) -> LocalDataWarning {
    quota_warning(&diagnostic.source, diagnostic.message.clone())
}

fn diagnostics_to_warnings(diagnostics: &[QuotaDiagnostic]) -> Vec<LocalDataWarning> {
    diagnostics.iter().map(warning_from_diagnostic).collect()
}

fn reset_credit_failure_status(error: &str) -> String {
    reset_credit_diagnostic(error).message
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
    let category = diagnostic_category(&compact);
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

fn diagnostic_category(compact: &str) -> String {
    let lower = compact.to_lowercase();

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
    if lower.contains("json") || compact.contains("解析") || compact.contains("响应为空") || lower.contains("expected") {
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

fn read_rate_limits() -> Result<QuotaSnapshot, String> {
    let mut errors = Vec::new();
    for attempt in 1..=RATE_LIMIT_READ_ATTEMPTS {
        match read_rate_limits_once(RATE_LIMIT_READ_TIMEOUT) {
            Ok(snapshot) => return Ok(snapshot),
            Err(error) => errors.push(format!("第 {attempt} 次：{}", compact_error_message(&error))),
        }
        if attempt < RATE_LIMIT_READ_ATTEMPTS {
            thread::sleep(RATE_LIMIT_RETRY_DELAY);
        }
    }
    Err(format!(
        "额度读取失败，已重试 {RATE_LIMIT_READ_ATTEMPTS} 次：{}",
        errors.join("；")
    ))
}

fn read_rate_limits_once(timeout: Duration) -> Result<QuotaSnapshot, String> {
    let codex = find_codex_binary_with_report()?.path;
    let mut command = Command::new(codex);
    configure_quota_child_process(&mut command);
    let child = command
        .args(["app-server", "--listen", "stdio://"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("启动 Codex 失败：{error}"))?;
    let mut child = QuotaChildGuard::new(child);

    let stdout = child
        .child_mut()
        .stdout
        .take()
        .ok_or_else(|| "Codex stdout 不可用".to_string())?;
    let mut stdin = child
        .child_mut()
        .stdin
        .take()
        .ok_or_else(|| "Codex stdin 不可用".to_string())?;
    let stderr = child.child_mut().stderr.take();
    let (sender, receiver) = mpsc::channel();

    thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if let Ok(value) = serde_json::from_str::<Value>(&line) {
                let _ = sender.send(value);
            }
        }
    });

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

    let deadline = Instant::now() + timeout;
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
            child.cleanup();
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

    child.cleanup();
    if let Some(mut stderr) = stderr {
        let mut text = String::new();
        let _ = std::io::Read::read_to_string(&mut stderr, &mut text);
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            return Err(trimmed.to_string());
        }
    }
    Err(format!("额度读取超时（{} 秒）", timeout.as_secs()))
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
}

impl<C: QuotaChildProcess> QuotaChildGuard<C> {
    fn new(child: C) -> Self {
        Self {
            child,
            cleaned: false,
        }
    }

    fn cleanup(&mut self) {
        if self.cleaned {
            return;
        }
        self.child.kill_for_cleanup();
        self.child.wait_for_cleanup();
        self.cleaned = true;
    }
}

impl QuotaChildGuard<Child> {
    fn child_mut(&mut self) -> &mut Child {
        &mut self.child
    }
}

impl<C: QuotaChildProcess> Drop for QuotaChildGuard<C> {
    fn drop(&mut self) {
        self.cleanup();
    }
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
            diagnostics: Vec::new(),
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
    fn quota_read_timeouts_match_swift_retry_budget() {
        assert_eq!(RATE_LIMIT_READ_ATTEMPTS, 3);
        assert_eq!(RATE_LIMIT_READ_TIMEOUT, Duration::from_secs(12));
        assert_eq!(RATE_LIMIT_RETRY_DELAY, Duration::from_millis(350));
        assert_eq!(RESET_CREDIT_READ_ATTEMPTS, 3);
        assert_eq!(RESET_CREDIT_TIMEOUT, Duration::from_secs(14));
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

        assert!(bundle
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.source == "account_quota"
                && diagnostic.category == "http_rate_limited"
                && diagnostic.raw_cause.as_deref() == Some("HTTP 429 Too Many Requests")
                && diagnostic.http_status == Some(429)
                && diagnostic.retryable));
        assert!(bundle
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.source == "reset_credit"
                && diagnostic.category == "reset_credit_failure"
                && diagnostic.underlying_category.is_some()));
        assert!(bundle.warnings.iter().any(|warning| {
            warning.source == "account_quota"
                && warning.message.contains("请求过于频繁")
        }));
        assert!(bundle.warnings.iter().any(|warning| {
            warning.source == "reset_credit"
                && warning.message.contains("重置卡读取失败")
        }));
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
            diagnostics: Vec::new(),
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

    #[test]
    fn explicit_quota_retry_bypasses_cached_failure_placeholders() {
        let codex_home = std::env::temp_dir().join(format!(
            "codex-token-bar-quota-cache-failure-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let cache = QUOTA_READ_CACHE.get_or_init(|| Mutex::new(None));
        {
            let mut guard = cache.lock().unwrap();
            *guard = Some(QuotaCacheEntry {
                codex_home: codex_home.clone(),
                result: Ok(quota_failure_bundle(
                    &codex_home,
                    "error sending request for url: dns error".to_string(),
                )),
                cached_at: Instant::now(),
            });
        }

        assert!(cached_quota_result(&codex_home, false).unwrap().is_some());
        assert!(cached_quota_result(&codex_home, true).unwrap().is_none());
        assert!(
            cached_quota_result_after_inflight(&codex_home, true)
                .unwrap()
                .is_some()
        );

        let mut guard = cache.lock().unwrap();
        *guard = None;
    }
}
