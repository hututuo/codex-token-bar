use crate::core::cross_process_lock::CrossProcessFileLock;
use crate::core::quota::codex_binary::find_codex_binary_with_report;
use crate::core::process_tail::ProcessPipeTail;
use crate::models::{AutoResumeThreadOption, ConversationVisibilityRebuildResult};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, RwLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const APP_SERVER_STARTUP_TIMEOUT: Duration = Duration::from_secs(20);
const TURN_TIMEOUT: Duration = Duration::from_secs(6 * 60 * 60);
const INTERRUPT_GRACE_TIMEOUT: Duration = Duration::from_secs(5);
const STDERR_TAIL_LIMIT: usize = 16 * 1024;
const STDERR_DRAIN_GRACE: Duration = Duration::from_millis(500);
const THREAD_LEASE_DURATION: Duration = Duration::from_secs(2 * 60);
const THREAD_LEASE_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(20);
const LEDGER_LOCK_WAIT: Duration = Duration::from_secs(2);
const LEDGER_LOCK_RETRY: Duration = Duration::from_millis(25);
const LEDGER_VERSION: u32 = 1;
const LEDGER_MAX_CLAIMS: usize = 256;
const CHILD_ENV_REMOVE: &[&str] = &[
    "ELECTRON_RUN_AS_NODE",
    "NODE_OPTIONS",
    "TAURI_SIGNING_PRIVATE_KEY",
    "TAURI_SIGNING_PRIVATE_KEY_PATH",
];

static UNIQUE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AutoResumeRunOutcome {
    pub status: String,
    pub message: String,
    pub turn_id: Option<String>,
    pub quota_limited: bool,
}

impl AutoResumeRunOutcome {
    fn completed(turn_id: Option<String>) -> Self {
        Self {
            status: "succeeded".into(),
            message: "Codex 已完成本次自动续跑".into(),
            turn_id,
            quota_limited: false,
        }
    }

    fn failed(message: impl Into<String>, turn_id: Option<String>) -> Self {
        let message = message.into();
        let quota_limited = looks_like_quota_limit(&message);
        Self {
            status: if quota_limited {
                "waitingQuota"
            } else {
                "failed"
            }
            .into(),
            message,
            turn_id,
            quota_limited,
        }
    }

    fn needs_attention(message: impl Into<String>, turn_id: Option<String>) -> Self {
        Self {
            status: "needsAttention".into(),
            message: message.into(),
            turn_id,
            quota_limited: false,
        }
    }

    fn skipped(message: impl Into<String>) -> Self {
        Self {
            status: "skipped".into(),
            message: message.into(),
            turn_id: None,
            quota_limited: false,
        }
    }
}

/// Serializes an automatic trigger's final generation check with the actual
/// `turn/start` write. A settings update takes the write side of the same lock,
/// so either the old trigger starts first or the settings change invalidates it;
/// the change cannot land between validation and sending the request.
#[derive(Clone)]
pub struct AutoResumeStartGenerationGuard {
    generation: Arc<RwLock<u64>>,
    expected_generation: u64,
}

impl AutoResumeStartGenerationGuard {
    pub fn new(generation: Arc<RwLock<u64>>, expected_generation: u64) -> Self {
        Self {
            generation,
            expected_generation,
        }
    }

    fn run_if_current(&self, action: impl FnOnce() -> Result<(), String>) -> Result<bool, String> {
        let generation = self
            .generation
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if *generation != self.expected_generation {
            return Ok(false);
        }
        action()?;
        Ok(true)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct AutoResumeThreadLeaseRecord {
    #[serde(rename = "schemaVersion")]
    schema_version: u32,
    #[serde(rename = "threadID")]
    thread_id: String,
    #[serde(rename = "ownerID")]
    owner_id: String,
    #[serde(rename = "acquiredAtUnix")]
    acquired_at_unix: f64,
    #[serde(rename = "expiresAtUnix")]
    expires_at_unix: f64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct AutoResumeLedgerEntry {
    #[serde(rename = "threadID")]
    thread_id: String,
    #[serde(rename = "ownerID")]
    owner_id: String,
    #[serde(rename = "claimedAtUnix")]
    claimed_at_unix: f64,
    #[serde(rename = "completedAtUnix")]
    completed_at_unix: Option<f64>,
    outcome: String,
    message: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct AutoResumeLedger {
    #[serde(default = "ledger_version", rename = "schemaVersion")]
    schema_version: u32,
    #[serde(default)]
    entries: HashMap<String, AutoResumeLedgerEntry>,
}

impl Default for AutoResumeLedger {
    fn default() -> Self {
        Self {
            schema_version: LEDGER_VERSION,
            entries: HashMap::new(),
        }
    }
}

fn ledger_version() -> u32 {
    LEDGER_VERSION
}

pub struct AutoResumeClaim {
    codex_home: PathBuf,
    trigger_key: String,
    thread_id: String,
    owner_id: String,
    _thread_lease: ThreadLease,
}

impl AutoResumeClaim {
    pub fn complete(&self, outcome: &AutoResumeRunOutcome) -> Result<(), String> {
        update_ledger_claim(
            &self.codex_home,
            &self.trigger_key,
            &self.thread_id,
            &self.owner_id,
            &outcome.status,
            &outcome.message,
        )
    }
}

pub enum AutoResumeClaimResult {
    Claimed(AutoResumeClaim),
    Duplicate,
    Busy,
    DailyLimit,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AutoResumeAutomaticClaimLimit {
    pub day_start_unix: f64,
    pub max_runs: u8,
}

pub fn claim_trigger(
    codex_home: &Path,
    thread_id: &str,
    trigger_key: &str,
    minimum_interval: Duration,
    automatic_limit: Option<AutoResumeAutomaticClaimLimit>,
) -> Result<AutoResumeClaimResult, String> {
    let directory = support_directory(codex_home)?;
    let owner_id = unique_id();
    let thread_lease = match ThreadLease::acquire(&directory, thread_id, &owner_id)? {
        Some(lease) => lease,
        None => return Ok(AutoResumeClaimResult::Busy),
    };

    let Some(_ledger_lease) = acquire_ledger_lock(&directory, LEDGER_LOCK_WAIT)?
    else {
        return Ok(AutoResumeClaimResult::Busy);
    };
    let ledger_path = directory.join("trigger-ledger.json");
    let mut ledger = read_ledger(&ledger_path)?;
    if ledger.entries.contains_key(trigger_key) {
        return Ok(AutoResumeClaimResult::Duplicate);
    }
    let now = unix_now_f64();
    if minimum_interval > Duration::ZERO
        && ledger.entries.values().any(|entry| {
            entry.thread_id == thread_id
                && now - entry.completed_at_unix.unwrap_or(entry.claimed_at_unix)
                    < minimum_interval.as_secs_f64()
        })
    {
        return Ok(AutoResumeClaimResult::Busy);
    }
    if let Some(limit) = automatic_limit {
        let runs_today = ledger
            .entries
            .iter()
            .filter(|(key, entry)| {
                automatic_claim_counts_toward_daily_limit(key, entry, limit.day_start_unix)
            })
            .count();
        if runs_today >= usize::from(limit.max_runs.max(1)) {
            return Ok(AutoResumeClaimResult::DailyLimit);
        }
    }
    ledger.entries.insert(
        trigger_key.into(),
        AutoResumeLedgerEntry {
            thread_id: thread_id.into(),
            owner_id: owner_id.clone(),
            claimed_at_unix: now,
            completed_at_unix: None,
            outcome: "claimed".into(),
            message: None,
        },
    );
    trim_ledger(&mut ledger);
    write_ledger(&ledger_path, &ledger)?;
    Ok(AutoResumeClaimResult::Claimed(AutoResumeClaim {
        codex_home: codex_home.to_path_buf(),
        trigger_key: trigger_key.into(),
        thread_id: thread_id.into(),
        owner_id,
        _thread_lease: thread_lease,
    }))
}

fn automatic_claim_counts_toward_daily_limit(
    trigger_key: &str,
    entry: &AutoResumeLedgerEntry,
    day_start_unix: f64,
) -> bool {
    !trigger_key.starts_with("manual:")
        && entry.claimed_at_unix >= day_start_unix
        && !matches!(entry.outcome.as_str(), "skipped" | "satisfied")
}

pub fn list_threads(codex_home: &Path) -> Result<Vec<AutoResumeThreadOption>, String> {
    let mut session = AppServerSession::launch(codex_home)?;
    session.initialize(APP_SERVER_STARTUP_TIMEOUT)?;
    let mut threads = Vec::new();
    let mut cursor: Option<String> = None;
    for page in 0..20_i64 {
        let id = page + 2;
        let mut params = json!({
            "limit": 100,
            "archived": false,
            "sourceKinds": ["cli", "vscode", "exec", "appServer", "unknown"],
            "sortKey": "updated_at",
            "sortDirection": "desc"
        });
        if let Some(cursor) = cursor.as_deref() {
            params["cursor"] = Value::String(cursor.into());
        }
        session.send(json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "thread/list",
            "params": params
        }))?;
        let response = session.wait_for_response(id, APP_SERVER_STARTUP_TIMEOUT, None)?;
        let result = response_result(&response)?;
        let rows = result
            .get("data")
            .and_then(Value::as_array)
            .ok_or_else(|| "Codex thread/list 响应缺少 data".to_string())?;
        threads.extend(rows.iter().filter_map(parse_thread_option));
        cursor = result
            .get("nextCursor")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        if cursor.is_none() {
            break;
        }
    }
    threads.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
    Ok(threads)
}

pub fn rebuild_conversation_visibility_metadata(
    codex_home: &Path,
) -> Result<ConversationVisibilityRebuildResult, String> {
    let mut session = AppServerSession::launch(codex_home)?;
    session.initialize(APP_SERVER_STARTUP_TIMEOUT)?;
    let started_at = Instant::now();
    let deadline = started_at + VISIBILITY_REBUILD_TIME_BUDGET;
    let mut next_request_id = 2_i64;
    let active = collect_visibility_pages(false, deadline, |archived, cursor| {
        request_visibility_page(
            &mut session,
            &mut next_request_id,
            archived,
            cursor,
        )
    })?;
    let archived = collect_visibility_pages(true, deadline, |archived, cursor| {
        request_visibility_page(
            &mut session,
            &mut next_request_id,
            archived,
            cursor,
        )
    })?;
    let pages_scanned = active.pages.saturating_add(archived.pages);
    Ok(ConversationVisibilityRebuildResult {
        active_threads: active.threads,
        archived_threads: archived.threads,
        pages_scanned,
        status: format!(
            "官方会话索引重建完成：活动 {}，归档 {}，共 {} 页，耗时 {:.1} 秒。Token Bar 未改写 JSONL 或 session_index。",
            active.threads,
            archived.threads,
            pages_scanned,
            started_at.elapsed().as_secs_f64()
        ),
    })
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct VisibilityPageStats {
    threads: u64,
    pages: u64,
}

// 可见性重建的失控保护：seen-cursor 只能挡"重复"游标，服务端若返回无限多
// 的唯一游标，分页永不终止——前端超时只是客户端放弃，后台 spawn_blocking
// 线程会继续持有全局 Provider 操作租约直到重启。页数上限 + 总时限保证
// 后台自行退出。
const VISIBILITY_REBUILD_MAX_PAGES: u64 = 100_000;
const VISIBILITY_REBUILD_TIME_BUDGET: Duration = Duration::from_secs(30 * 60);

fn collect_visibility_pages(
    archived: bool,
    deadline: Instant,
    mut request: impl FnMut(bool, Option<&str>) -> Result<Value, String>,
) -> Result<VisibilityPageStats, String> {
    let mut stats = VisibilityPageStats::default();
    let mut cursor: Option<String> = None;
    let mut seen_cursors = HashSet::new();
    loop {
        if stats.pages >= VISIBILITY_REBUILD_MAX_PAGES {
            return Err(format!(
                "Codex thread/list 分页超过 {VISIBILITY_REBUILD_MAX_PAGES} 页上限仍未终止，已停止官方会话索引重建"
            ));
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "官方会话索引重建超过 {} 秒总时限，已停止",
                VISIBILITY_REBUILD_TIME_BUDGET.as_secs()
            ));
        }
        let result = request(archived, cursor.as_deref())?;
        let rows = result
            .get("data")
            .and_then(Value::as_array)
            .ok_or_else(|| "Codex thread/list 响应缺少 data".to_string())?;
        stats.threads = stats
            .threads
            .checked_add(u64::try_from(rows.len()).map_err(|_| "会话数量溢出".to_string())?)
            .ok_or_else(|| "会话数量溢出".to_string())?;
        stats.pages = stats
            .pages
            .checked_add(1)
            .ok_or_else(|| "分页数量溢出".to_string())?;

        let next_cursor = result
            .get("nextCursor")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        let Some(next_cursor) = next_cursor else {
            return Ok(stats);
        };
        if cursor.as_deref() == Some(next_cursor.as_str())
            || !seen_cursors.insert(next_cursor.clone())
        {
            return Err(format!(
                "Codex thread/list 返回重复游标，已停止官方会话索引重建：{next_cursor}"
            ));
        }
        cursor = Some(next_cursor);
    }
}

fn request_visibility_page(
    session: &mut AppServerSession,
    next_request_id: &mut i64,
    archived: bool,
    cursor: Option<&str>,
) -> Result<Value, String> {
    let request_id = *next_request_id;
    *next_request_id = next_request_id
        .checked_add(1)
        .ok_or_else(|| "Codex app-server 请求编号溢出".to_string())?;
    let mut params = json!({
        "limit": 100,
        "archived": archived,
        "useStateDbOnly": false,
        "sourceKinds": ["cli", "vscode", "exec", "appServer", "subAgent", "unknown"],
        "sortKey": "updated_at",
        "sortDirection": "desc"
    });
    if let Some(cursor) = cursor {
        params["cursor"] = Value::String(cursor.to_string());
    }
    session.send(json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "thread/list",
        "params": params
    }))?;
    let response =
        session.wait_for_response(request_id, APP_SERVER_STARTUP_TIMEOUT, None)?;
    response_result(&response).cloned()
}

pub fn run_turn(
    codex_home: &Path,
    thread_id: &str,
    prompt: &str,
    client_message_id: &str,
    freshness_not_before: Option<i64>,
    start_generation_guard: Option<AutoResumeStartGenerationGuard>,
    cancelled: Arc<AtomicBool>,
) -> Result<AutoResumeRunOutcome, String> {
    let mut session = AppServerSession::launch(codex_home)?;
    session.initialize(APP_SERVER_STARTUP_TIMEOUT)?;
    session.send(json!({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "thread/resume",
        "params": { "threadId": thread_id }
    }))?;
    let resumed = session.wait_for_response(2, APP_SERVER_STARTUP_TIMEOUT, Some(&cancelled))?;
    let result = response_result(&resumed)?;
    let thread = result
        .get("thread")
        .ok_or_else(|| "Codex thread/resume 响应缺少 thread".to_string())?;
    if freshness_not_before.is_some_and(|baseline| {
        thread_latest_progress_at(thread).is_some_and(|updated| updated > baseline)
    }) {
        return Ok(AutoResumeRunOutcome::skipped(
            "目标任务在等待期间已有新进展，本次自动续跑已视为满足",
        ));
    }
    if thread_is_busy(thread) {
        return Ok(AutoResumeRunOutcome::needs_attention(
            "目标任务仍在运行，已跳过本次自动续跑",
            None,
        ));
    }

    let start_request = json!({
        "jsonrpc": "2.0",
        "id": 3,
        "method": "turn/start",
        "params": {
            "threadId": thread_id,
            "clientUserMessageId": client_message_id,
            "input": [{ "type": "text", "text": prompt }]
        }
    });
    let started = if let Some(guard) = start_generation_guard.as_ref() {
        guard.run_if_current(|| session.send(start_request))?
    } else {
        session.send(start_request)?;
        true
    };
    if !started {
        return Ok(AutoResumeRunOutcome::skipped(
            "自动续跑设置已更改，旧触发已在发送前作废",
        ));
    }

    let deadline = Instant::now() + TURN_TIMEOUT;
    let mut turn_id: Option<String> = None;
    let mut needs_attention: Option<String> = None;
    let mut stop_requested_at: Option<Instant> = None;
    let mut interrupt_sent_at: Option<Instant> = None;
    let mut timed_out = false;
    let mut early_completions = Vec::new();
    loop {
        let now = Instant::now();
        if !timed_out && now >= deadline {
            timed_out = true;
            stop_requested_at = Some(now);
        }
        let cancellation_requested = cancelled.load(Ordering::Acquire);
        let human_stop_requested = needs_attention.is_some();
        if cancellation_requested || timed_out || human_stop_requested {
            let requested_at = stop_requested_at.get_or_insert(now);
            if let Some(active_turn_id) = turn_id.as_deref() {
                if interrupt_sent_at.is_none() {
                    session.send(json!({
                        "jsonrpc": "2.0",
                        "id": 4,
                        "method": "turn/interrupt",
                        "params": { "threadId": thread_id, "turnId": active_turn_id }
                    }))?;
                    interrupt_sent_at = Some(Instant::now());
                }
                if interrupt_sent_at
                    .is_some_and(|sent_at| sent_at.elapsed() >= INTERRUPT_GRACE_TIMEOUT)
                {
                    let message = if human_stop_requested {
                        "Codex 请求人工处理；已拒绝自动批准，但未在宽限期内确认中断"
                    } else if cancellation_requested {
                        "已请求停止，但 Codex 未在宽限期内确认中断"
                    } else {
                        "等待 Codex 完成续跑超时；已请求中断但未收到确认"
                    };
                    return Ok(AutoResumeRunOutcome::failed(message, turn_id));
                }
            } else if requested_at.elapsed() >= APP_SERVER_STARTUP_TIMEOUT {
                let message = if cancellation_requested {
                    "本次自动续跑已取消，但 Codex 未及时返回可中断的 turn ID"
                } else {
                    "等待 Codex 完成续跑超时，且未取得可中断的 turn ID"
                };
                return Ok(AutoResumeRunOutcome::failed(message, None));
            }
        }

        let Some(message) = session.recv(Duration::from_millis(500))? else {
            continue;
        };

        if message.get("id").and_then(Value::as_i64) == Some(3) {
            if let Some(error) = json_rpc_error_message(&message) {
                return Ok(AutoResumeRunOutcome::failed(error, turn_id));
            }
            let response_turn_id = message
                .pointer("/result/turn/id")
                .and_then(Value::as_str)
                .map(str::to_string);
            if let (Some(existing), Some(response)) =
                (turn_id.as_deref(), response_turn_id.as_deref())
            {
                if existing != response {
                    return Ok(AutoResumeRunOutcome::failed(
                        "Codex turn/start 与 turn/started 返回了不同的 turn ID",
                        turn_id,
                    ));
                }
            }
            turn_id = turn_id.or(response_turn_id);
            if let Some(outcome) = take_early_completion(
                &mut early_completions,
                thread_id,
                turn_id.as_deref(),
                needs_attention.as_deref(),
            ) {
                return Ok(outcome);
            }
            continue;
        }

        if message.get("id").is_some() && message.get("method").is_some() {
            let method = message
                .get("method")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            needs_attention = Some(format!(
                "Codex 请求人工处理（{method}），Token Bar 已拒绝自动批准"
            ));
            stop_requested_at.get_or_insert_with(Instant::now);
            session.reject_server_request(&message)?;
            let requested_turn_id = message
                .pointer("/params/turnId")
                .and_then(Value::as_str)
                .map(str::to_string)
                .or_else(|| turn_id.clone());
            if let Some(active_turn_id) = requested_turn_id.as_deref() {
                turn_id = Some(active_turn_id.to_string());
                if interrupt_sent_at.is_none() {
                    session.send(json!({
                        "jsonrpc": "2.0",
                        "id": 5,
                        "method": "turn/interrupt",
                        "params": { "threadId": thread_id, "turnId": active_turn_id }
                    }))?;
                    interrupt_sent_at = Some(Instant::now());
                }
            }
            continue;
        }

        if message.get("method").and_then(Value::as_str) == Some("turn/started") {
            if message.pointer("/params/threadId").and_then(Value::as_str) != Some(thread_id) {
                continue;
            }
            let started_turn_id = message
                .pointer("/params/turn/id")
                .and_then(Value::as_str)
                .map(str::to_string);
            if let (Some(existing), Some(started)) =
                (turn_id.as_deref(), started_turn_id.as_deref())
            {
                if existing != started {
                    continue;
                }
            }
            turn_id = turn_id.or(started_turn_id);
            if let Some(outcome) = take_early_completion(
                &mut early_completions,
                thread_id,
                turn_id.as_deref(),
                needs_attention.as_deref(),
            ) {
                return Ok(outcome);
            }
            continue;
        }

        if message.get("method").and_then(Value::as_str) == Some("turn/completed") {
            if let Some(expected_turn_id) = turn_id.as_deref() {
                if is_matching_turn_completion(&message, thread_id, expected_turn_id) {
                    return Ok(turn_completion_outcome(
                        &message,
                        needs_attention.as_deref(),
                    ));
                }
            } else if message.pointer("/params/threadId").and_then(Value::as_str) == Some(thread_id)
                && early_completions.len() < 4
            {
                early_completions.push(message);
            }
        }
    }
}

fn take_early_completion(
    completions: &mut Vec<Value>,
    thread_id: &str,
    turn_id: Option<&str>,
    needs_attention: Option<&str>,
) -> Option<AutoResumeRunOutcome> {
    let turn_id = turn_id?;
    let index = completions
        .iter()
        .position(|message| is_matching_turn_completion(message, thread_id, turn_id))?;
    let message = completions.remove(index);
    Some(turn_completion_outcome(&message, needs_attention))
}

fn is_matching_turn_completion(message: &Value, thread_id: &str, turn_id: &str) -> bool {
    message.get("method").and_then(Value::as_str) == Some("turn/completed")
        && message.pointer("/params/threadId").and_then(Value::as_str) == Some(thread_id)
        && message.pointer("/params/turn/id").and_then(Value::as_str) == Some(turn_id)
}

fn turn_completion_outcome(message: &Value, needs_attention: Option<&str>) -> AutoResumeRunOutcome {
    let completed_turn_id = message
        .pointer("/params/turn/id")
        .and_then(Value::as_str)
        .map(str::to_string);
    if let Some(detail) = needs_attention {
        return AutoResumeRunOutcome::needs_attention(detail, completed_turn_id);
    }
    let status = message
        .pointer("/params/turn/status")
        .and_then(Value::as_str)
        .unwrap_or("failed");
    match status {
        "completed" => AutoResumeRunOutcome::completed(completed_turn_id),
        "interrupted" => {
            AutoResumeRunOutcome::failed("Codex 已确认中断本次自动续跑", completed_turn_id)
        }
        _ => {
            let detail = message
                .pointer("/params/turn/error")
                .map(compact_json)
                .unwrap_or_else(|| "Codex 自动续跑失败".into());
            AutoResumeRunOutcome::failed(detail, completed_turn_id)
        }
    }
}

pub fn default_codex_home() -> PathBuf {
    crate::platform::read_app_settings()
        .ok()
        .and_then(|settings| settings.codex_home)
        .filter(|path| !path.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::core::app_paths::home_dir().join(".codex"))
}

fn parse_thread_option(value: &Value) -> Option<AutoResumeThreadOption> {
    let id = value.get("id")?.as_str()?.to_string();
    let preview = value.get("preview").and_then(Value::as_str).unwrap_or("");
    let title = value
        .get("name")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(preview)
        .trim();
    let title = if title.is_empty() {
        "未命名任务"
    } else {
        title
    };
    Some(AutoResumeThreadOption {
        id,
        title: truncate_chars(title, 240),
        cwd: value
            .get("cwd")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        updated_at: value.get("updatedAt").and_then(Value::as_i64).unwrap_or(0),
        status: value
            .pointer("/status/type")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string(),
        source: source_label(value.get("source")),
    })
}

fn thread_is_busy(thread: &Value) -> bool {
    if thread.pointer("/status/type").and_then(Value::as_str) == Some("active") {
        return true;
    }
    thread
        .get("turns")
        .and_then(Value::as_array)
        .and_then(|turns| turns.last())
        .and_then(|turn| turn.get("status"))
        .and_then(Value::as_str)
        == Some("inProgress")
}

fn thread_latest_progress_at(thread: &Value) -> Option<i64> {
    let turn_progress = thread
        .get("turns")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .flat_map(|turn| {
            [
                turn.get("completedAt").and_then(Value::as_i64),
                turn.get("startedAt").and_then(Value::as_i64),
            ]
            .into_iter()
            .flatten()
        })
        .max();
    turn_progress.or_else(|| thread.get("updatedAt").and_then(Value::as_i64))
}

fn source_label(source: Option<&Value>) -> String {
    match source {
        Some(Value::String(value)) => value.clone(),
        Some(Value::Object(value)) => value
            .keys()
            .next()
            .cloned()
            .unwrap_or_else(|| "unknown".into()),
        _ => "unknown".into(),
    }
}

fn truncate_chars(value: &str, limit: usize) -> String {
    let mut chars = value.chars();
    let prefix: String = chars.by_ref().take(limit).collect();
    if chars.next().is_some() {
        format!("{prefix}…")
    } else {
        prefix
    }
}

struct AppServerSession {
    child: Child,
    stdin: std::process::ChildStdin,
    messages: mpsc::Receiver<Value>,
    stderr: ProcessPipeTail,
}

impl AppServerSession {
    fn launch(codex_home: &Path) -> Result<Self, String> {
        let codex = find_codex_binary_with_report()?.path;
        let mut command = Command::new(codex);
        for key in CHILD_ENV_REMOVE {
            command.env_remove(key);
        }
        command.env("CODEX_HOME", codex_home);
        command.args(["app-server", "--listen", "stdio://"]);
        configure_hidden_child(&mut command);
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| format!("启动 Codex app-server 失败：{error}"))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "Codex stdin 不可用".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "Codex stdout 不可用".to_string())?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| "Codex stderr 不可用".to_string())?;
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if let Ok(message) = serde_json::from_str::<Value>(&line) {
                    let _ = sender.send(message);
                }
            }
        });
        Ok(Self {
            child,
            stdin,
            messages: receiver,
            stderr: ProcessPipeTail::spawn(
                Some(stderr),
                STDERR_TAIL_LIMIT,
                STDERR_DRAIN_GRACE,
            ),
        })
    }

    fn initialize(&mut self, timeout: Duration) -> Result<(), String> {
        self.send(json!({
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
        }))?;
        let response = self.wait_for_response(1, timeout, None)?;
        response_result(&response)?;
        self.send(json!({"jsonrpc": "2.0", "method": "initialized"}))
    }

    fn send(&mut self, value: Value) -> Result<(), String> {
        serde_json::to_writer(&mut self.stdin, &value).map_err(|error| error.to_string())?;
        self.stdin
            .write_all(b"\n")
            .map_err(|error| error.to_string())?;
        self.stdin.flush().map_err(|error| error.to_string())
    }

    fn recv(&mut self, timeout: Duration) -> Result<Option<Value>, String> {
        match self.messages.recv_timeout(timeout) {
            Ok(message) => Ok(Some(message)),
            Err(mpsc::RecvTimeoutError::Timeout) => Ok(None),
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                Err(format!("Codex app-server 提前退出{}", self.stderr_text()))
            }
        }
    }

    fn wait_for_response(
        &mut self,
        id: i64,
        timeout: Duration,
        cancelled: Option<&AtomicBool>,
    ) -> Result<Value, String> {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if cancelled.is_some_and(|value| value.load(Ordering::Acquire)) {
                return Err("操作已取消".into());
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if let Some(message) = self.recv(remaining.min(Duration::from_millis(250)))? {
                if message.get("id").and_then(Value::as_i64) == Some(id) {
                    return Ok(message);
                }
                if message.get("id").is_some() && message.get("method").is_some() {
                    self.reject_server_request(&message)?;
                }
            }
        }
        Err(format!("等待 Codex 响应超时{}", self.stderr_text()))
    }

    fn reject_server_request(&mut self, request: &Value) -> Result<(), String> {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let method = request.get("method").and_then(Value::as_str).unwrap_or("");
        self.send(server_request_rejection(id, method))
    }

    fn stderr_text(&self) -> String {
        let text = self.stderr.text();
        if text.is_empty() {
            String::new()
        } else {
            format!("；stderr：{}", truncate_chars(text.trim(), 500))
        }
    }
}

fn server_request_rejection(id: Value, method: &str) -> Value {
    match method {
        "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => {
            json!({"jsonrpc": "2.0", "id": id, "result": {"decision": "decline"}})
        }
        "execCommandApproval" | "applyPatchApproval" => {
            json!({"jsonrpc": "2.0", "id": id, "result": {"decision": "denied"}})
        }
        _ => json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": {
                "code": -32000,
                "message": "Codex Token Bar automatic continuation does not grant permissions or answer user input."
            }
        }),
    }
}

impl Drop for AppServerSession {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct ThreadLease {
    directory: PathBuf,
    owner_id: String,
    heartbeat_stop: Option<mpsc::Sender<()>>,
    heartbeat: Option<thread::JoinHandle<()>>,
}

impl ThreadLease {
    fn acquire(root: &Path, thread_id: &str, owner_id: &str) -> Result<Option<Self>, String> {
        let leases = root.join("leases");
        fs::create_dir_all(&leases).map_err(|error| error.to_string())?;
        let directory = leases.join(format!("thread-{}", stable_thread_key(thread_id)));
        for _ in 0..3 {
            match fs::create_dir(&directory) {
                Ok(()) => {
                    let now = unix_now_f64();
                    let record = AutoResumeThreadLeaseRecord {
                        schema_version: LEDGER_VERSION,
                        thread_id: thread_id.into(),
                        owner_id: owner_id.into(),
                        acquired_at_unix: now,
                        expires_at_unix: now + THREAD_LEASE_DURATION.as_secs_f64(),
                    };
                    let bytes =
                        serde_json::to_vec_pretty(&record).map_err(|error| error.to_string())?;
                    if let Err(error) = crate::core::atomic_file::write_atomically(
                        &directory.join("lease.json"),
                        &bytes,
                    ) {
                        let _ = fs::remove_dir_all(&directory);
                        return Err(error.to_string());
                    }
                    if let Err(error) = renew_thread_lease(&directory, owner_id) {
                        let _ = fs::remove_dir_all(&directory);
                        return Err(error);
                    }
                    let (heartbeat_stop, heartbeat_stopped) = mpsc::channel();
                    let heartbeat_directory = directory.clone();
                    let heartbeat_owner = owner_id.to_string();
                    let heartbeat = thread::spawn(move || loop {
                        match heartbeat_stopped.recv_timeout(THREAD_LEASE_HEARTBEAT_INTERVAL) {
                            Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                            Err(mpsc::RecvTimeoutError::Timeout) => {
                                match renew_thread_lease(
                                    &heartbeat_directory,
                                    &heartbeat_owner,
                                ) {
                                    Ok(true) | Err(_) => {}
                                    Ok(false) => break,
                                }
                            }
                        }
                    });
                    return Ok(Some(Self {
                        directory,
                        owner_id: owner_id.into(),
                        heartbeat_stop: Some(heartbeat_stop),
                        heartbeat: Some(heartbeat),
                    }));
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    if thread_lease_expired(&directory) {
                        let tombstone = leases.join(format!(".expired-{}", unique_id()));
                        if fs::rename(&directory, &tombstone).is_ok() {
                            let _ = fs::remove_dir_all(tombstone);
                            continue;
                        }
                    }
                    return Ok(None);
                }
                Err(error) => return Err(error.to_string()),
            }
        }
        Ok(None)
    }
}

impl Drop for ThreadLease {
    fn drop(&mut self) {
        if let Some(stop) = self.heartbeat_stop.take() {
            let _ = stop.send(());
        }
        if let Some(heartbeat) = self.heartbeat.take() {
            let _ = heartbeat.join();
        }
        let record = fs::read(self.directory.join("lease.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<AutoResumeThreadLeaseRecord>(&bytes).ok());
        if record
            .as_ref()
            .is_none_or(|record| record.owner_id != self.owner_id)
        {
            return;
        }
        let tombstone = self
            .directory
            .with_file_name(format!(".released-{}", unique_id()));
        if fs::rename(&self.directory, &tombstone).is_ok() {
            let _ = fs::remove_dir_all(tombstone);
        }
    }
}

fn renew_thread_lease(directory: &Path, owner_id: &str) -> Result<bool, String> {
    let bytes = match fs::read(directory.join("lease.json")) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error.to_string()),
    };
    let mut record = serde_json::from_slice::<AutoResumeThreadLeaseRecord>(&bytes)
        .map_err(|error| error.to_string())?;
    if record.owner_id != owner_id {
        return Ok(false);
    }
    record.expires_at_unix = unix_now_f64() + THREAD_LEASE_DURATION.as_secs_f64();
    let bytes = serde_json::to_vec_pretty(&record).map_err(|error| error.to_string())?;
    crate::core::atomic_file::write_atomically(
        &thread_lease_heartbeat_path(directory, owner_id),
        &bytes,
    )
        .map_err(|error| error.to_string())?;
    Ok(true)
}

fn thread_lease_expired(directory: &Path) -> bool {
    let record = fs::read(directory.join("lease.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<AutoResumeThreadLeaseRecord>(&bytes).ok());
    let Some(record) = record else {
        return directory_is_stale(directory, Duration::from_secs(60));
    };
    let heartbeat = fs::read(thread_lease_heartbeat_path(directory, &record.owner_id))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<AutoResumeThreadLeaseRecord>(&bytes).ok())
        .filter(|heartbeat| {
            heartbeat.owner_id == record.owner_id
                && heartbeat.thread_id == record.thread_id
                && heartbeat.acquired_at_unix == record.acquired_at_unix
        });
    heartbeat
        .map_or(record.expires_at_unix, |value| {
            value.expires_at_unix.max(record.expires_at_unix)
        })
        <= unix_now_f64()
}

fn thread_lease_heartbeat_path(directory: &Path, owner_id: &str) -> PathBuf {
    directory.join(format!("heartbeat-{}.json", stable_thread_key(owner_id)))
}

fn directory_is_stale(path: &Path, threshold: Duration) -> bool {
    fs::metadata(path)
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| SystemTime::now().duration_since(modified).ok())
        .is_some_and(|age| age >= threshold)
}

fn support_directory(codex_home: &Path) -> Result<PathBuf, String> {
    let directory = codex_home.join(".codex-token-bar-auto-resume").join("v1");
    fs::create_dir_all(&directory)
        .map_err(|error| format!("无法创建自动续跑状态目录 {}：{error}", directory.display()))?;
    Ok(directory)
}

fn acquire_ledger_lock(
    directory: &Path,
    wait: Duration,
) -> Result<Option<CrossProcessFileLock>, String> {
    let path = directory.join("trigger-ledger.flock");
    let deadline = Instant::now()
        .checked_add(wait)
        .unwrap_or_else(Instant::now);
    loop {
        if let Some(lock) =
            CrossProcessFileLock::try_acquire(&path, "自动续跑触发记录")?
        {
            return Ok(Some(lock));
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Ok(None);
        }
        thread::sleep(LEDGER_LOCK_RETRY.min(remaining));
    }
}

fn read_ledger(path: &Path) -> Result<AutoResumeLedger, String> {
    match fs::read(path) {
        Ok(bytes) => {
            let ledger: AutoResumeLedger = serde_json::from_slice(&bytes)
                .map_err(|error| format!("自动续跑 ledger 损坏：{error}"))?;
            if ledger.schema_version != LEDGER_VERSION {
                return Err("自动续跑 ledger 版本不兼容".into());
            }
            Ok(ledger)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            Ok(AutoResumeLedger::default())
        }
        Err(error) => Err(error.to_string()),
    }
}

fn write_ledger(path: &Path, ledger: &AutoResumeLedger) -> Result<(), String> {
    let bytes = serde_json::to_vec_pretty(ledger).map_err(|error| error.to_string())?;
    crate::core::atomic_file::write_atomically(path, &bytes).map_err(|error| error.to_string())
}

fn update_ledger_claim(
    codex_home: &Path,
    trigger_key: &str,
    thread_id: &str,
    owner_id: &str,
    status: &str,
    message: &str,
) -> Result<(), String> {
    let directory = support_directory(codex_home)?;
    let Some(_lease) = acquire_ledger_lock(&directory, LEDGER_LOCK_WAIT)?
    else {
        return Err("自动续跑 ledger 正由另一个进程更新".into());
    };
    let path = directory.join("trigger-ledger.json");
    let mut ledger = read_ledger(&path)?;
    if let Some(claim) = ledger.entries.get_mut(trigger_key) {
        if claim.thread_id == thread_id && claim.owner_id == owner_id {
            claim.outcome = status.into();
            claim.message = Some(message.into());
            claim.completed_at_unix = Some(unix_now_f64());
        }
    }
    trim_ledger(&mut ledger);
    write_ledger(&path, &ledger)
}

fn trim_ledger(ledger: &mut AutoResumeLedger) {
    let cutoff = unix_now_f64() - 30.0 * 24.0 * 60.0 * 60.0;
    ledger
        .entries
        .retain(|_, entry| entry.claimed_at_unix >= cutoff);
    if ledger.entries.len() > LEDGER_MAX_CLAIMS {
        let mut ordered = ledger
            .entries
            .iter()
            .map(|(key, entry)| (key.clone(), entry.claimed_at_unix))
            .collect::<Vec<_>>();
        ordered.sort_by(|left, right| left.1.total_cmp(&right.1));
        for (key, _) in ordered
            .into_iter()
            .take(ledger.entries.len() - LEDGER_MAX_CLAIMS)
        {
            ledger.entries.remove(&key);
        }
    }
}

fn response_result(message: &Value) -> Result<&Value, String> {
    if let Some(error) = json_rpc_error_message(message) {
        return Err(error);
    }
    message
        .get("result")
        .ok_or_else(|| "Codex JSON-RPC 响应缺少 result".into())
}

fn json_rpc_error_message(message: &Value) -> Option<String> {
    message
        .pointer("/error/message")
        .and_then(Value::as_str)
        .map(str::to_string)
}

fn compact_json(value: &Value) -> String {
    truncate_chars(&value.to_string(), 1_000)
}

fn looks_like_quota_limit(message: &str) -> bool {
    let normalized = message.to_ascii_lowercase();
    normalized.contains("usagelimitexceeded")
        || normalized.contains("usage limit")
        || normalized.contains("insufficient_quota")
        || message.contains("额度") && (message.contains("耗尽") || message.contains("上限"))
}

fn stable_thread_key(value: &str) -> String {
    let mut hash = 14_695_981_039_346_656_037_u64;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(1_099_511_628_211);
    }
    format!("{hash:016x}")
}

fn unique_id() -> String {
    format!(
        "{}-{}-{}",
        unix_now(),
        std::process::id(),
        UNIQUE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    )
}

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .min(i64::MAX as u64) as i64
}

fn unix_now_f64() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

#[cfg(windows)]
fn configure_hidden_child(command: &mut Command) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    command.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
fn configure_hidden_child(_command: &mut Command) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn automatic_start_guard_serializes_generation_change_with_start_write() {
        let generation = Arc::new(RwLock::new(7));
        let guard = AutoResumeStartGenerationGuard::new(generation.clone(), 7);
        let (entered_sender, entered_receiver) = mpsc::channel();
        let (release_sender, release_receiver) = mpsc::channel();
        let starter = thread::spawn(move || {
            guard
                .run_if_current(|| {
                    entered_sender.send(()).unwrap();
                    release_receiver.recv().unwrap();
                    Ok(())
                })
                .unwrap()
        });
        entered_receiver.recv().unwrap();

        let (writer_ready_sender, writer_ready_receiver) = mpsc::channel();
        let (updated_sender, updated_receiver) = mpsc::channel();
        let writer_generation = generation.clone();
        let writer = thread::spawn(move || {
            writer_ready_sender.send(()).unwrap();
            *writer_generation
                .write()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) = 8;
            updated_sender.send(()).unwrap();
        });
        writer_ready_receiver.recv().unwrap();
        assert!(updated_receiver
            .recv_timeout(Duration::from_millis(50))
            .is_err());

        release_sender.send(()).unwrap();
        assert!(starter.join().unwrap());
        updated_receiver
            .recv_timeout(Duration::from_secs(1))
            .unwrap();
        writer.join().unwrap();

        let stale_guard = AutoResumeStartGenerationGuard::new(generation, 7);
        let mut sent = false;
        assert!(!stale_guard
            .run_if_current(|| {
                sent = true;
                Ok(())
            })
            .unwrap());
        assert!(!sent);
    }

    #[test]
    fn visibility_rebuild_pages_freely_within_the_page_cap() {
        let mut requested = 0_u64;
        let deadline = Instant::now() + Duration::from_secs(60);
        let stats = collect_visibility_pages(false, deadline, |archived, cursor| {
            assert!(!archived);
            let expected = if requested == 0 {
                None
            } else {
                Some(format!("cursor-{requested}"))
            };
            assert_eq!(cursor, expected.as_deref());
            requested += 1;
            Ok(json!({
                "data": [{"id": format!("thread-{requested}")}],
                "nextCursor": if requested < 23 {
                    Value::String(format!("cursor-{requested}"))
                } else {
                    Value::Null
                }
            }))
        })
        .unwrap();
        assert_eq!(requested, 23);
        assert_eq!(
            stats,
            VisibilityPageStats {
                threads: 23,
                pages: 23
            }
        );
    }

    #[test]
    fn visibility_rebuild_rejects_cursor_cycles() {
        let mut requested = 0;
        let deadline = Instant::now() + Duration::from_secs(60);
        let error = collect_visibility_pages(true, deadline, |archived, _| {
            assert!(archived);
            requested += 1;
            Ok(json!({
                "data": [],
                "nextCursor": if requested == 1 { "a" } else { "a" }
            }))
        })
        .unwrap_err();
        assert!(error.contains("重复游标"));
        assert_eq!(requested, 2);
    }

    #[test]
    fn visibility_rebuild_stops_at_the_page_cap_on_endless_unique_cursors() {
        let mut requested = 0_u64;
        let deadline = Instant::now() + Duration::from_secs(600);
        let error = collect_visibility_pages(false, deadline, |_, _| {
            requested += 1;
            Ok(json!({
                "data": [],
                "nextCursor": format!("unique-{requested}")
            }))
        })
        .unwrap_err();
        assert!(error.contains("页上限"), "{error}");
        assert_eq!(requested, VISIBILITY_REBUILD_MAX_PAGES);
    }

    #[test]
    fn visibility_rebuild_stops_when_the_time_budget_is_exhausted() {
        let mut requested = 0_u64;
        let error = collect_visibility_pages(false, Instant::now(), |_, _| {
            requested += 1;
            Ok(json!({"data": [], "nextCursor": "x"}))
        })
        .unwrap_err();
        assert!(error.contains("总时限"), "{error}");
        assert_eq!(requested, 0, "超时后不得再发起分页请求");
    }

    #[test]
    fn busy_thread_detection_checks_runtime_and_last_turn() {
        assert!(thread_is_busy(
            &json!({"status":{"type":"active"},"turns":[]})
        ));
        assert!(thread_is_busy(&json!({
            "status":{"type":"idle"},
            "turns":[{"status":"inProgress"}]
        })));
        assert!(!thread_is_busy(&json!({
            "status":{"type":"idle"},
            "turns":[{"status":"completed"}]
        })));
    }

    #[test]
    fn completion_matching_requires_exact_thread_and_turn_identity() {
        let completion = json!({
            "method": "turn/completed",
            "params": {
                "threadId": "thread-1",
                "turn": {"id": "turn-1", "status": "completed"}
            }
        });
        assert!(is_matching_turn_completion(
            &completion,
            "thread-1",
            "turn-1"
        ));
        assert!(!is_matching_turn_completion(
            &completion,
            "thread-2",
            "turn-1"
        ));
        assert!(!is_matching_turn_completion(
            &completion,
            "thread-1",
            "turn-2"
        ));

        let mut early = vec![completion];
        assert!(take_early_completion(&mut early, "thread-1", None, None).is_none());
        let outcome = take_early_completion(&mut early, "thread-1", Some("turn-1"), None).unwrap();
        assert_eq!(outcome.status, "succeeded");
    }

    #[test]
    fn thread_freshness_prefers_real_turn_progress_for_manual_satisfaction() {
        assert_eq!(
            thread_latest_progress_at(&json!({
                "updatedAt": 100,
                "turns": [
                    {"startedAt": 120, "completedAt": 130},
                    {"startedAt": 140, "completedAt": null}
                ]
            })),
            Some(140)
        );
    }

    #[test]
    fn thread_options_preserve_multiple_threads_from_same_cwd() {
        let a = parse_thread_option(&json!({
            "id":"a","name":"A","preview":"","cwd":"/repo","updatedAt":2,
            "status":{"type":"idle"},"source":"vscode"
        }))
        .unwrap();
        let b = parse_thread_option(&json!({
            "id":"b","name":"B","preview":"","cwd":"/repo","updatedAt":1,
            "status":{"type":"idle"},"source":"vscode"
        }))
        .unwrap();
        assert_ne!(a.id, b.id);
        assert_eq!(a.cwd, b.cwd);
    }

    #[test]
    fn thread_option_keeps_long_picker_titles() {
        let title = "完整会话标题".repeat(30);
        let option = parse_thread_option(&json!({
            "id":"long-title","name":title.clone(),"preview":"","cwd":"/repo","updatedAt":1,
            "status":{"type":"idle"},"source":"vscode"
        }))
        .unwrap();
        assert_eq!(option.title, title);
    }

    #[test]
    fn deterministic_claim_is_at_most_once() {
        let root = std::env::temp_dir().join(format!("ctb-auto-resume-{}", unique_id()));
        fs::create_dir_all(&root).unwrap();
        let first = claim_trigger(&root, "thread-1", "quota:5h:123", Duration::ZERO, None).unwrap();
        let AutoResumeClaimResult::Claimed(first) = first else {
            panic!("first claim")
        };
        first
            .complete(&AutoResumeRunOutcome::completed(Some("turn-1".into())))
            .unwrap();
        drop(first);
        assert!(matches!(
            claim_trigger(&root, "thread-1", "quota:5h:123", Duration::ZERO, None,).unwrap(),
            AutoResumeClaimResult::Duplicate
        ));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn ledger_file_lock_excludes_concurrent_holder_and_releases() {
        let root = std::env::temp_dir().join(format!("ctb-ledger-lock-own-{}", unique_id()));
        fs::create_dir_all(&root).unwrap();
        let lease = acquire_ledger_lock(&root, Duration::ZERO)
            .unwrap()
            .expect("first acquire");
        assert!(
            acquire_ledger_lock(&root, Duration::ZERO).unwrap().is_none(),
            "持有中的内核锁必须挡住并发获取"
        );
        drop(lease);
        assert!(acquire_ledger_lock(&root, Duration::ZERO)
            .unwrap()
            .is_some());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn ledger_file_lock_preserves_claims_across_writers() {
        let root = std::env::temp_dir().join(format!("ctb-ledger-lock-ledger-{}", unique_id()));
        fs::create_dir_all(&root).unwrap();
        let first = claim_trigger(
            &root,
            "thread-lock",
            "daily:thread-lock:2026-07-16:0900",
            Duration::ZERO,
            None,
        )
        .unwrap();
        let AutoResumeClaimResult::Claimed(first) = first else {
            panic!("first claim")
        };
        drop(first);
        let second = claim_trigger(
            &root,
            "thread-lock",
            "daily:thread-lock:2026-07-16:1000",
            Duration::ZERO,
            None,
        )
        .unwrap();
        let AutoResumeClaimResult::Claimed(second) = second else {
            panic!("second claim")
        };
        drop(second);
        let ledger =
            read_ledger(&support_directory(&root).unwrap().join("trigger-ledger.json"))
                .unwrap();
        assert_eq!(ledger.entries.len(), 2);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn cross_runtime_hash_and_lease_json_match_the_swift_contract() {
        assert_eq!(
            stable_thread_key("thread-cross-runtime"),
            "016acc1c4b8fabb5"
        );
        let value = serde_json::to_value(AutoResumeThreadLeaseRecord {
            schema_version: 1,
            thread_id: "thread-cross-runtime".into(),
            owner_id: "tauri-tests".into(),
            acquired_at_unix: 100.0,
            expires_at_unix: 200.0,
        })
        .unwrap();
        let keys = value
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(
            keys,
            [
                "acquiredAtUnix",
                "expiresAtUnix",
                "ownerID",
                "schemaVersion",
                "threadID",
            ]
            .into_iter()
            .map(str::to_string)
            .collect()
        );
    }

    #[test]
    fn thread_lease_heartbeat_renews_only_the_current_owner() {
        let root = std::env::temp_dir().join(format!("ctb-auto-resume-heartbeat-{}", unique_id()));
        let support = support_directory(&root).unwrap();
        let lease = ThreadLease::acquire(&support, "thread-heartbeat", "owner-current")
            .unwrap()
            .expect("first owner should acquire the lease");
        let directory = support
            .join("leases")
            .join(format!("thread-{}", stable_thread_key("thread-heartbeat")));
        let read_record = || {
            serde_json::from_slice::<AutoResumeThreadLeaseRecord>(
                &fs::read(thread_lease_heartbeat_path(
                    &directory,
                    "owner-current",
                ))
                .unwrap(),
            )
            .unwrap()
        };
        let before = read_record();
        thread::sleep(Duration::from_millis(5));
        assert!(renew_thread_lease(&directory, "owner-current").unwrap());
        let after = read_record();
        assert!(after.expires_at_unix > before.expires_at_unix);
        let mut base: AutoResumeThreadLeaseRecord =
            serde_json::from_slice(&fs::read(directory.join("lease.json")).unwrap()).unwrap();
        base.expires_at_unix = unix_now_f64() - 1.0;
        crate::core::atomic_file::write_atomically(
            &directory.join("lease.json"),
            &serde_json::to_vec_pretty(&base).unwrap(),
        )
        .unwrap();
        assert!(!thread_lease_expired(&directory));
        assert!(!renew_thread_lease(&directory, "owner-stale").unwrap());
        let unchanged = read_record();
        assert_eq!(unchanged.owner_id, after.owner_id);
        assert_eq!(unchanged.expires_at_unix, after.expires_at_unix);

        drop(lease);
        assert!(!directory.exists());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn shared_ledger_enforces_cross_process_thread_cooldown() {
        let root = std::env::temp_dir().join(format!("ctb-auto-resume-cooldown-{}", unique_id()));
        fs::create_dir_all(&root).unwrap();
        let AutoResumeClaimResult::Claimed(first) = claim_trigger(
            &root,
            "thread-1",
            "schedule:first",
            Duration::from_secs(60),
            None,
        )
        .unwrap() else {
            panic!("first claim")
        };
        first
            .complete(&AutoResumeRunOutcome::completed(None))
            .unwrap();
        drop(first);
        assert!(matches!(
            claim_trigger(
                &root,
                "thread-1",
                "schedule:second",
                Duration::from_secs(60),
                None,
            )
            .unwrap(),
            AutoResumeClaimResult::Busy
        ));
        assert!(matches!(
            claim_trigger(&root, "thread-1", "manual:retry", Duration::ZERO, None,).unwrap(),
            AutoResumeClaimResult::Claimed(_)
        ));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn shared_cooldown_starts_when_a_long_turn_completes_not_when_it_was_claimed() {
        let root = std::env::temp_dir().join(format!("ctb-auto-resume-long-{}", unique_id()));
        fs::create_dir_all(&root).unwrap();
        let directory = support_directory(&root).unwrap();
        let now = unix_now_f64();
        let mut ledger = AutoResumeLedger::default();
        ledger.entries.insert(
            "long-turn".into(),
            AutoResumeLedgerEntry {
                thread_id: "thread-long".into(),
                owner_id: "finished-owner".into(),
                claimed_at_unix: now - 2.0 * 60.0 * 60.0,
                completed_at_unix: Some(now - 10.0),
                outcome: "succeeded".into(),
                message: None,
            },
        );
        write_ledger(&directory.join("trigger-ledger.json"), &ledger).unwrap();

        assert!(matches!(
            claim_trigger(
                &root,
                "thread-long",
                "next-trigger",
                Duration::from_secs(60),
                None,
            )
            .unwrap(),
            AutoResumeClaimResult::Busy
        ));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn shared_daily_limit_reserves_inflight_runs_and_ignores_manual_or_satisfied_claims() {
        let root = std::env::temp_dir().join(format!("ctb-auto-resume-daily-{}", unique_id()));
        fs::create_dir_all(&root).unwrap();
        let limit = AutoResumeAutomaticClaimLimit {
            day_start_unix: unix_now_f64() - 60.0 * 60.0,
            max_runs: 1,
        };
        let AutoResumeClaimResult::Claimed(first) = claim_trigger(
            &root,
            "thread-1",
            "schedule:first",
            Duration::ZERO,
            Some(limit),
        )
        .unwrap() else {
            panic!("first automatic claim")
        };
        assert!(matches!(
            claim_trigger(
                &root,
                "thread-2",
                "quota:second",
                Duration::ZERO,
                Some(limit),
            )
            .unwrap(),
            AutoResumeClaimResult::DailyLimit
        ));
        assert!(matches!(
            claim_trigger(&root, "thread-manual", "manual:retry", Duration::ZERO, None,).unwrap(),
            AutoResumeClaimResult::Claimed(_)
        ));

        first
            .complete(&AutoResumeRunOutcome::skipped(
                "manual progress satisfied trigger",
            ))
            .unwrap();
        drop(first);
        assert!(matches!(
            claim_trigger(
                &root,
                "thread-2",
                "quota:third",
                Duration::ZERO,
                Some(limit),
            )
            .unwrap(),
            AutoResumeClaimResult::Claimed(_)
        ));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn quota_errors_are_classified_without_retrying_unknown_failures() {
        assert!(looks_like_quota_limit("usageLimitExceeded"));
        assert!(looks_like_quota_limit("额度已到上限"));
        assert!(looks_like_quota_limit("insufficient_quota"));
        assert!(!looks_like_quota_limit(
            "temporary rate limit; retry shortly"
        ));
        assert!(!looks_like_quota_limit("working directory missing"));
    }

    #[test]
    fn unattended_server_requests_are_declined_never_approved() {
        assert_eq!(
            server_request_rejection(json!(7), "item/commandExecution/requestApproval")
                .pointer("/result/decision")
                .and_then(Value::as_str),
            Some("decline")
        );
        assert_eq!(
            server_request_rejection(json!(8), "execCommandApproval")
                .pointer("/result/decision")
                .and_then(Value::as_str),
            Some("denied")
        );
        assert!(
            server_request_rejection(json!(9), "item/tool/requestUserInput")
                .get("error")
                .is_some()
        );
    }

    #[test]
    #[ignore = "requires an explicitly created disposable Codex thread"]
    fn live_app_server_lists_disposable_thread_without_cwd_dedupe() {
        let thread_id = std::env::var("CODEX_TOKEN_BAR_LIVE_THREAD_ID")
            .expect("set CODEX_TOKEN_BAR_LIVE_THREAD_ID to a disposable thread");
        let home = std::env::var_os("CODEX_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(default_codex_home);
        let matches = list_threads(&home)
            .expect("live app-server thread/list should succeed")
            .into_iter()
            .filter(|thread| thread.id == thread_id)
            .count();
        assert_eq!(
            matches, 1,
            "the exact disposable thread should be selectable"
        );
    }

    #[test]
    #[ignore = "requires an explicitly created disposable Codex thread"]
    fn live_app_server_skips_a_pending_trigger_after_manual_progress() {
        let thread_id = std::env::var("CODEX_TOKEN_BAR_LIVE_THREAD_ID")
            .expect("set CODEX_TOKEN_BAR_LIVE_THREAD_ID to a disposable thread");
        let home = std::env::var_os("CODEX_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(default_codex_home);
        let outcome = run_turn(
            &home,
            &thread_id,
            "继续",
            &format!("freshness-test-{}", unique_id()),
            Some(unix_now().saturating_sub(24 * 60 * 60)),
            None,
            Arc::new(AtomicBool::new(false)),
        )
        .expect("live app-server freshness check should complete");
        assert_eq!(outcome.status, "skipped", "{}", outcome.message);
        assert!(outcome.turn_id.is_none());
    }

    #[test]
    #[ignore = "requires an explicitly created disposable Codex thread"]
    fn live_app_server_resumes_disposable_thread_with_continue() {
        let thread_id = std::env::var("CODEX_TOKEN_BAR_LIVE_THREAD_ID")
            .expect("set CODEX_TOKEN_BAR_LIVE_THREAD_ID to a disposable thread");
        let prompt = std::env::var("CODEX_TOKEN_BAR_LIVE_PROMPT").unwrap_or_else(|_| "继续".into());
        let home = std::env::var_os("CODEX_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(default_codex_home);
        let outcome = run_turn(
            &home,
            &thread_id,
            &prompt,
            &format!("live-test-{}", unique_id()),
            None,
            None,
            Arc::new(AtomicBool::new(false)),
        )
        .expect("live app-server resume should complete");
        assert_eq!(outcome.status, "succeeded", "{}", outcome.message);
        assert!(outcome.turn_id.is_some());
    }
}
