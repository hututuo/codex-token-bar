use crate::core::{
    app_paths, atomic_file,
    multi_client_product::{self, ProductDetection, QuotaProviderSnapshot},
};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use rusqlite::backup::Backup;
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use time::format_description::well_known::Rfc3339;
use time::{Date, Duration as CalendarDuration, OffsetDateTime};

const SCHEMA_VERSION: i64 = 2;
const MAX_SCAN_DEPTH: usize = 6;
const MAX_SCANNED_ENTRIES: usize = 200_000;
const MAX_FILES_PER_CLIENT: usize = 20_000;
const MAX_SOURCE_FILE_BYTES: u64 = 16 * 1024 * 1024;
const MAX_OPENCODE_ROWS: usize = 500;
const MAX_OPENCODE_ROW_BYTES: usize = 1024 * 1024;
const MAX_COUNTER: u64 = 1_000_000_000_000;
const DATABASE_BUSY_TIMEOUT: Duration = Duration::from_secs(3);
type EventKey = (String, String, String);

static MULTI_CLIENT_USAGE_GATE: OnceLock<Mutex<()>> = OnceLock::new();
static MULTI_CLIENT_SCAN_CURSOR: OnceLock<Mutex<usize>> = OnceLock::new();
static MULTI_CLIENT_AGGREGATE_CACHE: OnceLock<Mutex<MultiClientAggregateCache>> = OnceLock::new();
static MULTI_CLIENT_PRICE_CACHE: OnceLock<Mutex<MultiClientPriceCache>> = OnceLock::new();
static MULTI_CLIENT_SCOPED_SUMMARY_CACHE: OnceLock<Mutex<MultiClientScopedSummaryCache>> =
    OnceLock::new();
static DEEPSEEK_SESSION_HINT_CACHE: OnceLock<Mutex<VecDeque<(String, String, String)>>> =
    OnceLock::new();
const MAX_DEEPSEEK_SESSION_HINT_CACHE: usize = 1_024;
const BUNDLED_PRICE_TABLE: &str =
    include_str!("../../../../Vendor/AgentSpeed/spec/assets/prices.json");
const MAX_SCOPED_SUMMARY_CACHE_ENTRIES: usize = 8;

#[derive(Clone, Debug, Eq, PartialEq)]
struct MultiClientAggregateCacheKey {
    database_path: PathBuf,
    revision: i64,
    minute: i64,
    local_day: Date,
    local_offset_seconds: i32,
}

#[derive(Clone, Debug)]
struct MultiClientAggregateArrays {
    summaries: Vec<MultiClientUsageSummary>,
    today_summaries: Vec<MultiClientUsageSummary>,
    seven_day_summaries: Vec<MultiClientUsageSummary>,
    trend_buckets: Vec<MultiClientUsageTrendBucket>,
    daily_buckets: Vec<MultiClientUsageTrendBucket>,
}

#[derive(Clone, Debug)]
struct MultiClientAggregateRead {
    arrays: MultiClientAggregateArrays,
    updated_at: Option<String>,
}

#[derive(Default)]
struct MultiClientAggregateCache {
    entry: Option<(MultiClientAggregateCacheKey, MultiClientAggregateArrays)>,
    hits: u64,
}

impl MultiClientAggregateCache {
    fn get(&mut self, key: &MultiClientAggregateCacheKey) -> Option<MultiClientAggregateArrays> {
        let (cached_key, arrays) = self.entry.as_ref()?;
        if cached_key != key {
            return None;
        }
        self.hits = self.hits.saturating_add(1);
        Some(arrays.clone())
    }

    fn put(&mut self, key: MultiClientAggregateCacheKey, arrays: MultiClientAggregateArrays) {
        self.entry = Some((key, arrays));
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct MultiClientPriceAggregateKey {
    database_path: PathBuf,
    revision: i64,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct MultiClientPriceModelKey {
    client: String,
    model: String,
}

#[derive(Clone, Debug, Default)]
struct MultiClientPriceTally {
    known_cost_micro_usd: Option<u128>,
    unpriced_requests: u64,
    has_known_request: bool,
    overflowed: bool,
}

impl MultiClientPriceTally {
    fn add(&mut self, cost_micro_usd: Option<i64>) {
        let Some(cost) = cost_micro_usd else {
            self.unpriced_requests = self.unpriced_requests.saturating_add(1);
            return;
        };
        self.has_known_request = true;
        if self.overflowed {
            return;
        }
        match self
            .known_cost_micro_usd
            .unwrap_or_default()
            .checked_add(cost.max(0) as u128)
        {
            Some(total) => self.known_cost_micro_usd = Some(total),
            None => {
                self.overflowed = true;
                self.known_cost_micro_usd = None;
            }
        }
    }
}

#[derive(Default)]
struct MultiClientPriceCache {
    entry: Option<(
        MultiClientPriceAggregateKey,
        HashMap<MultiClientPriceModelKey, MultiClientPriceTally>,
    )>,
    hits: u64,
}

impl MultiClientPriceCache {
    fn get(
        &mut self,
        key: &MultiClientPriceAggregateKey,
    ) -> Option<HashMap<MultiClientPriceModelKey, MultiClientPriceTally>> {
        let (cached_key, totals) = self.entry.as_ref()?;
        if cached_key != key {
            return None;
        }
        self.hits = self.hits.saturating_add(1);
        Some(totals.clone())
    }

    fn put(
        &mut self,
        key: MultiClientPriceAggregateKey,
        totals: HashMap<MultiClientPriceModelKey, MultiClientPriceTally>,
    ) {
        self.entry = Some((key, totals));
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct MultiClientScopedSummaryCacheKey {
    database_path: PathBuf,
    revision: i64,
    cutoff_unix: i64,
}

#[derive(Default)]
struct MultiClientScopedSummaryCache {
    entries: VecDeque<(
        MultiClientScopedSummaryCacheKey,
        Vec<MultiClientUsageSummary>,
    )>,
}

impl MultiClientScopedSummaryCache {
    fn get(
        &mut self,
        key: &MultiClientScopedSummaryCacheKey,
    ) -> Option<Vec<MultiClientUsageSummary>> {
        let index = self
            .entries
            .iter()
            .position(|(cached_key, _)| cached_key == key)?;
        let (cached_key, summaries) = self.entries.remove(index)?;
        self.entries.push_back((cached_key, summaries.clone()));
        Some(summaries)
    }

    fn put(
        &mut self,
        key: MultiClientScopedSummaryCacheKey,
        summaries: Vec<MultiClientUsageSummary>,
    ) {
        self.entries.retain(|(cached_key, _)| cached_key != &key);
        self.entries.push_back((key, summaries));
        while self.entries.len() > MAX_SCOPED_SUMMARY_CACHE_ENTRIES {
            self.entries.pop_front();
        }
    }
}

const CLIENTS: [&str; 5] = [
    "claudeCode",
    "claudeDesktop",
    "deepseek",
    "gemini",
    "opencode",
];

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MultiClientUsagePreference {
    pub client: String,
    pub enabled: bool,
    pub show_sidebar: bool,
    pub show_menu_bar: bool,
    #[serde(default)]
    pub show_quota: bool,
    pub color: String,
    pub order: u32,
    pub style: String,
    #[serde(default, deserialize_with = "deserialize_optional_path")]
    pub path: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MultiClientUsageSummary {
    pub client: String,
    pub model: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: Option<u64>,
    pub cache_write_tokens: Option<u64>,
    pub reasoning_tokens: Option<u64>,
    pub requests: u64,
    pub last_seen: Option<String>,
    pub incomplete_fields: bool,
    #[serde(default, rename = "apiCostUSD")]
    pub api_cost_usd: Option<f64>,
    #[serde(default)]
    pub unpriced_requests: u64,
    #[serde(default)]
    pub cache_read_complete: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MultiClientUsageSnapshot {
    pub preferences: Vec<MultiClientUsagePreference>,
    pub summaries: Vec<MultiClientUsageSummary>,
    #[serde(default)]
    pub today_summaries: Vec<MultiClientUsageSummary>,
    #[serde(default)]
    pub seven_day_summaries: Vec<MultiClientUsageSummary>,
    pub detections: Vec<ProductDetection>,
    pub trend_buckets: Vec<MultiClientUsageTrendBucket>,
    pub daily_buckets: Vec<MultiClientUsageTrendBucket>,
    pub quotas: Vec<QuotaProviderSnapshot>,
    pub diagnostics: Vec<String>,
    pub updated_at: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MultiClientUsageTrendBucket {
    pub client: String,
    pub start_unix: i64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: Option<u64>,
    pub cache_write_tokens: Option<u64>,
    pub reasoning_tokens: Option<u64>,
    pub requests: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeLocalQuotaWindow {
    pub used_percent: f64,
    pub resets_at: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeLocalQuotaSnapshot {
    pub state: String,
    pub captured_at: Option<String>,
    pub five_hour: Option<ClaudeLocalQuotaWindow>,
    pub seven_day: Option<ClaudeLocalQuotaWindow>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PreferencesFile {
    schema_version: u32,
    preferences: Vec<MultiClientUsagePreference>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct UsageEvent {
    client: String,
    session_id: String,
    event_id: String,
    model: String,
    timestamp_ms: i64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: Option<u64>,
    cache_write_tokens: Option<u64>,
    reasoning_tokens: Option<u64>,
    quality: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct ClientUsageEventPayload {
    client: String,
    #[serde(rename = "eventID")]
    event_id: String,
    #[serde(rename = "sessionID")]
    session_id: String,
    model: String,
    /// Swift JSONEncoder's `.millisecondsSince1970` Date representation.
    #[serde(deserialize_with = "deserialize_millis_timestamp")]
    timestamp: f64,
    input_tokens: u64,
    output_tokens: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    cache_read_tokens: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cache_write_tokens: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reasoning_tokens: Option<u64>,
    quality: String,
}

fn deserialize_millis_timestamp<'de, D>(deserializer: D) -> Result<f64, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Value::deserialize(deserializer)?;
    let millis = value
        .as_f64()
        .filter(|millis| {
            millis.is_finite() && *millis >= i64::MIN as f64 && *millis <= i64::MAX as f64
        })
        .ok_or_else(|| serde::de::Error::custom("timestamp must be finite milliseconds"))?;
    Ok(millis)
}

#[derive(Clone, Debug)]
struct Checkpoint {
    offset: u64,
    size: u64,
    modified: f64,
    fingerprint: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct OpenCodeDatabaseCursor {
    updated_at_milliseconds: i64,
    #[serde(rename = "messageID")]
    message_id: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct OpenCodeDatabaseContinuation {
    source_identity: String,
    source_fingerprint: String,
    cursor: OpenCodeDatabaseCursor,
}

pub fn default_preferences() -> Vec<MultiClientUsagePreference> {
    let colors = ["#D97757", "#D97757", "#4D6BFE", "#4796E4", "#B7B1B1"];
    CLIENTS
        .iter()
        .enumerate()
        .map(|(order, client)| MultiClientUsagePreference {
            client: (*client).to_string(),
            enabled: false,
            show_sidebar: false,
            show_menu_bar: false,
            show_quota: false,
            color: colors[order].to_string(),
            order: order as u32,
            style: "compact".into(),
            path: String::new(),
        })
        .collect()
}

/// Compact, quota-free lines for native tray tooltips. The Windows tray can reuse this projection
/// while the menu-bar preference remains stored in the shared cross-platform preference file.
pub fn configured_menu_bar_usage_lines(
    preferences: &[MultiClientUsagePreference],
    summaries: &[MultiClientUsageSummary],
) -> Vec<String> {
    let mut configured = preferences
        .iter()
        .filter(|preference| preference.show_menu_bar)
        .collect::<Vec<_>>();
    configured.sort_by_key(|preference| preference.order);
    configured
        .into_iter()
        .map(|preference| {
            let matching = summaries
                .iter()
                .filter(|summary| summary.client == preference.client)
                .collect::<Vec<_>>();
            if matching.is_empty() {
                return None;
            }
            let (input, output) =
                matching
                    .into_iter()
                    .fold((0u64, 0u64), |(input, output), summary| {
                        (
                            input.saturating_add(summary.input_tokens),
                            output.saturating_add(summary.output_tokens),
                        )
                    });
            let label = match preference.client.as_str() {
                "claudeCode" => "Claude Code",
                "claudeDesktop" => "Claude Desktop",
                "deepseek" => "DeepSeek",
                "gemini" => "Gemini",
                "opencode" => "OpenCode",
                _ => preference.client.as_str(),
            };
            Some(format!("{label}: {input} in · {output} out"))
        })
        .flatten()
        .collect()
}

pub fn read_multi_client_usage_snapshot() -> Result<MultiClientUsageSnapshot, String> {
    let settings_path = app_paths::multi_client_usage_settings_path()
        .ok_or_else(|| "无法定位多客户端用量设置目录".to_string())?;
    let database_path = app_paths::multi_client_usage_database_path()
        .ok_or_else(|| "无法定位多客户端用量数据库目录".to_string())?;
    read_multi_client_usage_snapshot_at(&settings_path, &database_path)
}

pub fn save_multi_client_usage_preferences(
    preferences: Vec<MultiClientUsagePreference>,
) -> Result<Vec<MultiClientUsagePreference>, String> {
    let _guard = usage_gate();
    let path = app_paths::multi_client_usage_settings_path()
        .ok_or_else(|| "无法定位多客户端用量设置目录".to_string())?;
    let normalized = normalize_preferences(preferences)?;
    let bytes = serde_json::to_vec_pretty(&PreferencesFile {
        schema_version: 1,
        preferences: normalized.clone(),
    })
    .map_err(|error| error.to_string())?;
    atomic_file::write_atomically(&path, &bytes).map_err(|error| error.to_string())?;
    Ok(normalized)
}

pub fn refresh_multi_client_usage() -> Result<MultiClientUsageSnapshot, String> {
    let _guard = usage_gate();
    let settings_path = app_paths::multi_client_usage_settings_path()
        .ok_or_else(|| "无法定位多客户端用量设置目录".to_string())?;
    let database_path = app_paths::multi_client_usage_database_path()
        .ok_or_else(|| "无法定位多客户端用量数据库目录".to_string())?;
    refresh_multi_client_usage_at(&settings_path, &database_path)
}

fn read_multi_client_usage_snapshot_at(
    settings_path: &Path,
    database_path: &Path,
) -> Result<MultiClientUsageSnapshot, String> {
    let (preferences, mut diagnostics) = load_preferences(settings_path);
    let (summaries, today_summaries, seven_day_summaries, updated_at, trend_buckets, daily_buckets) =
        if database_path.exists() {
            let connection = open_read_only(database_path).map_err(|error| error.to_string())?;
            let version = read_schema_version(&connection).map_err(|error| error.to_string())?;
            if version > SCHEMA_VERSION {
                return Err(format!(
                    "多客户端用量数据库版本 {version} 高于此程序支持的版本 {SCHEMA_VERSION}"
                ));
            }
            if version > 0 {
                let now = now_unix_seconds();
                let aggregates = read_cached_multi_client_aggregates(
                    &connection,
                    database_path,
                    now,
                    MULTI_CLIENT_AGGREGATE_CACHE.get_or_init(Default::default),
                )?;
                (
                    aggregates.arrays.summaries,
                    aggregates.arrays.today_summaries,
                    aggregates.arrays.seven_day_summaries,
                    aggregates.updated_at,
                    aggregates.arrays.trend_buckets,
                    aggregates.arrays.daily_buckets,
                )
            } else {
                (
                    Vec::new(),
                    Vec::new(),
                    Vec::new(),
                    None,
                    Vec::new(),
                    Vec::new(),
                )
            }
        } else {
            (
                Vec::new(),
                Vec::new(),
                Vec::new(),
                None,
                Vec::new(),
                Vec::new(),
            )
        };
    diagnostics.shrink_to_fit();
    Ok(make_snapshot(
        preferences,
        summaries,
        today_summaries,
        seven_day_summaries,
        diagnostics,
        updated_at,
        trend_buckets,
        daily_buckets,
    ))
}

fn make_snapshot(
    preferences: Vec<MultiClientUsagePreference>,
    summaries: Vec<MultiClientUsageSummary>,
    today_summaries: Vec<MultiClientUsageSummary>,
    seven_day_summaries: Vec<MultiClientUsageSummary>,
    diagnostics: Vec<String>,
    updated_at: Option<String>,
    trend_buckets: Vec<MultiClientUsageTrendBucket>,
    daily_buckets: Vec<MultiClientUsageTrendBucket>,
) -> MultiClientUsageSnapshot {
    let local_claude_quota = read_claude_local_quota();
    MultiClientUsageSnapshot {
        preferences,
        summaries,
        today_summaries,
        seven_day_summaries,
        detections: multi_client_product::detect_clients_cached(),
        trend_buckets,
        daily_buckets,
        quotas: multi_client_product::quota_provider_snapshots(&local_claude_quota),
        diagnostics,
        updated_at,
    }
}

fn refresh_multi_client_usage_at(
    settings_path: &Path,
    database_path: &Path,
) -> Result<MultiClientUsageSnapshot, String> {
    let (preferences, mut diagnostics) = load_preferences(settings_path);
    let enabled = preferences
        .iter()
        .filter(|preference| preference.enabled)
        .collect::<Vec<_>>();
    // First-run defaults must not create a database or read any provider logs.
    if enabled.is_empty() && !database_path.exists() {
        return Ok(make_snapshot(
            preferences,
            Vec::new(),
            Vec::new(),
            Vec::new(),
            diagnostics,
            None,
            Vec::new(),
            Vec::new(),
        ));
    }
    // Disabling all readers stops scanning but leaves the independent ledger intact.
    if enabled.is_empty() {
        let connection = Connection::open(database_path).map_err(|error| error.to_string())?;
        connection
            .busy_timeout(DATABASE_BUSY_TIMEOUT)
            .map_err(|error| error.to_string())?;
        ensure_schema(&connection, database_path).map_err(|error| error.to_string())?;
        let now = now_unix_seconds();
        let aggregates = read_cached_multi_client_aggregates(
            &connection,
            database_path,
            now,
            MULTI_CLIENT_AGGREGATE_CACHE.get_or_init(Default::default),
        )?;
        return Ok(make_snapshot(
            preferences,
            aggregates.arrays.summaries,
            aggregates.arrays.today_summaries,
            aggregates.arrays.seven_day_summaries,
            diagnostics,
            aggregates.updated_at,
            aggregates.arrays.trend_buckets,
            aggregates.arrays.daily_buckets,
        ));
    }
    if let Some(parent) = database_path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let mut connection = Connection::open(&database_path).map_err(|error| error.to_string())?;
    connection
        .busy_timeout(DATABASE_BUSY_TIMEOUT)
        .map_err(|error| error.to_string())?;
    ensure_schema(&connection, &database_path).map_err(|error| error.to_string())?;

    let mut work = Vec::<(String, PathBuf)>::new();
    for preference in enabled {
        if preference.client == "opencode" {
            let roots = source_roots("opencode", preference_path(preference));
            if roots.is_empty() {
                diagnostics.push("opencode: 找不到默认用户目录".into());
                continue;
            }
            for root in roots {
                match enumerate_source_files("opencode", &root) {
                    Ok((files, truncated)) => {
                        if files.is_empty() {
                            diagnostics.push("opencode: 未发现本地用量日志".into());
                        }
                        if truncated {
                            diagnostics
                                .push("opencode: 自动发现达到安全上限，本轮不是完整历史".into());
                        }
                        work.extend(
                            files
                                .into_iter()
                                .map(|path| (preference.client.clone(), path)),
                        );
                    }
                    Err(error) => {
                        diagnostics.push(format!("opencode: 无法枚举 {}: {error}", root.display()))
                    }
                }
            }
            continue;
        }
        let roots = source_roots(&preference.client, preference_path(preference));
        if roots.is_empty() {
            diagnostics.push(format!("{}: 找不到默认用户目录", preference.client));
            continue;
        }
        for root in roots {
            match enumerate_source_files(&preference.client, &root) {
                Ok((files, truncated)) => {
                    if truncated {
                        diagnostics.push(format!(
                            "{}: 文件扫描达到安全上限，未读取全部来源",
                            preference.client
                        ));
                    }
                    if files.is_empty() {
                        diagnostics.push(format!("{}: 未发现本地用量日志", preference.client));
                    }
                    work.extend(
                        files
                            .into_iter()
                            .map(|path| (preference.client.clone(), path)),
                    );
                }
                Err(error) => diagnostics.push(format!(
                    "{}: 无法枚举 {}: {error}",
                    preference.client,
                    root.display()
                )),
            }
        }
    }

    // Rotate through bounded work so one large history cannot monopolize a refresh. Per-file
    // checkpoints make every completed item durable before the next turn.
    work.sort_by(|left, right| left.0.cmp(&right.0).then_with(|| left.1.cmp(&right.1)));
    work.dedup();
    if !work.is_empty() {
        let start = {
            let cursor = MULTI_CLIENT_SCAN_CURSOR.get_or_init(|| Mutex::new(0));
            let cursor = cursor.lock().map_err(|error| error.to_string())?;
            *cursor % work.len()
        };
        let count = work.len().min(200);
        for step in 0..count {
            let (client, path) = &work[(start + step) % work.len()];
            let is_database = client == "opencode"
                && path
                    .extension()
                    .and_then(|extension| extension.to_str())
                    .is_some_and(|extension| {
                        matches!(extension.to_ascii_lowercase().as_str(), "db" | "sqlite")
                    });
            let result = if is_database {
                scan_opencode(&mut connection, path).map(|notices| {
                    diagnostics.extend(
                        notices
                            .into_iter()
                            .map(|notice| format!("opencode: {notice}")),
                    );
                })
            } else {
                scan_transcript_file(&mut connection, client, path)
            };
            if let Err(error) = result {
                diagnostics.push(format!("{client}: 无法读取 {}: {error}", path.display()));
            }
        }
        if let Ok(mut cursor) = MULTI_CLIENT_SCAN_CURSOR
            .get_or_init(|| Mutex::new(0))
            .lock()
        {
            *cursor = (start + count) % work.len();
        }
        if count < work.len() {
            diagnostics.push(format!(
                "本轮检查 {count}/{} 个文件，后续刷新继续；已入账数据保留",
                work.len()
            ));
        }
    }

    let refreshed_at = now_ms();
    connection
        .execute(
            "INSERT INTO multi_usage_metadata(key, value) VALUES ('updated_at_ms', ?1) \
             ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [refreshed_at.to_string()],
        )
        .map_err(|error| error.to_string())?;
    diagnostics.sort();
    diagnostics.dedup();
    let now = now_unix_seconds();
    let aggregates = read_cached_multi_client_aggregates(
        &connection,
        database_path,
        now,
        MULTI_CLIENT_AGGREGATE_CACHE.get_or_init(Default::default),
    )?;
    Ok(make_snapshot(
        preferences,
        aggregates.arrays.summaries,
        aggregates.arrays.today_summaries,
        aggregates.arrays.seven_day_summaries,
        diagnostics,
        aggregates.updated_at,
        aggregates.arrays.trend_buckets,
        aggregates.arrays.daily_buckets,
    ))
}

pub fn read_claude_local_quota() -> ClaudeLocalQuotaSnapshot {
    let path = app_paths::home_dir()
        .join(".claude-monitor")
        .join("statusline")
        .join("latest.json");
    read_claude_local_quota_at(&path, OffsetDateTime::now_utc().unix_timestamp() as f64)
}

fn read_claude_local_quota_at(path: &Path, now_epoch: f64) -> ClaudeLocalQuotaSnapshot {
    let metadata = match fs::metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return claude_quota_state("missing")
        }
        Err(_) => return claude_quota_state("invalid"),
    };
    if metadata.len() > 64 * 1024 {
        return claude_quota_state("invalid");
    }
    let bytes = match fs::File::open(path).and_then(|file| {
        let mut bytes = Vec::new();
        file.take(64 * 1024 + 1).read_to_end(&mut bytes)?;
        Ok(bytes)
    }) {
        Ok(bytes) if bytes.len() <= 64 * 1024 => bytes,
        Ok(_) => return claude_quota_state("invalid"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return claude_quota_state("missing")
        }
        Err(_) => return claude_quota_state("invalid"),
    };
    let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
        return claude_quota_state("invalid");
    };
    if value.is_null() {
        return claude_quota_state("missing");
    }
    let Some(captured_epoch) = value
        .get("captured_at_epoch")
        .and_then(value_as_f64)
        .filter(|value| value.is_finite() && *value >= 0.0)
    else {
        return claude_quota_state("invalid");
    };
    if captured_epoch > now_epoch + 60.0 {
        return claude_quota_state("invalid");
    }
    if now_epoch - captured_epoch > 600.0 {
        return ClaudeLocalQuotaSnapshot {
            state: "stale".into(),
            captured_at: epoch_seconds_iso(captured_epoch),
            five_hour: None,
            seven_day: None,
        };
    }
    let Some(rate_limits) = value.get("rate_limits").and_then(Value::as_object) else {
        return ClaudeLocalQuotaSnapshot {
            state: "missing".into(),
            captured_at: epoch_seconds_iso(captured_epoch),
            five_hour: None,
            seven_day: None,
        };
    };
    let five_hour = match parse_claude_quota_window(rate_limits.get("five_hour"), now_epoch) {
        Ok(value) => value,
        Err(()) => return claude_quota_state("invalid"),
    };
    let seven_day = match parse_claude_quota_window(rate_limits.get("seven_day"), now_epoch) {
        Ok(value) => value,
        Err(()) => return claude_quota_state("invalid"),
    };
    ClaudeLocalQuotaSnapshot {
        state: if five_hour.is_some() || seven_day.is_some() {
            "available"
        } else {
            "missing"
        }
        .into(),
        captured_at: epoch_seconds_iso(captured_epoch),
        five_hour,
        seven_day,
    }
}

fn claude_quota_state(state: &str) -> ClaudeLocalQuotaSnapshot {
    ClaudeLocalQuotaSnapshot {
        state: state.into(),
        captured_at: None,
        five_hour: None,
        seven_day: None,
    }
}

fn parse_claude_quota_window(
    value: Option<&Value>,
    now_epoch: f64,
) -> Result<Option<ClaudeLocalQuotaWindow>, ()> {
    let Some(value) = value else { return Ok(None) };
    if value.is_null() {
        return Ok(None);
    }
    let used_percent = value
        .get("used_percentage")
        .and_then(value_as_f64)
        .filter(|value| value.is_finite() && (0.0..=100.0).contains(value))
        .ok_or(())?;
    let resets_at = match value.get("resets_at") {
        None | Some(Value::Null) => None,
        Some(value) => {
            let epoch = value_as_f64(value)
                .filter(|value| value.is_finite() && *value >= 0.0)
                .ok_or(())?;
            if epoch > now_epoch {
                Some(epoch_seconds_iso(epoch).ok_or(())?)
            } else {
                None
            }
        }
    };
    Ok(Some(ClaudeLocalQuotaWindow {
        used_percent,
        resets_at,
    }))
}

fn value_as_f64(value: &Value) -> Option<f64> {
    value.as_f64()
}

fn epoch_seconds_iso(epoch: f64) -> Option<String> {
    let nanos = (epoch * 1_000_000_000.0).round();
    if !nanos.is_finite() || nanos < i128::MIN as f64 || nanos > i128::MAX as f64 {
        return None;
    }
    OffsetDateTime::from_unix_timestamp_nanos(nanos as i128)
        .ok()
        .and_then(|timestamp| timestamp.format(&Rfc3339).ok())
}

fn usage_gate() -> std::sync::MutexGuard<'static, ()> {
    MULTI_CLIENT_USAGE_GATE
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn normalize_preferences(
    supplied: Vec<MultiClientUsagePreference>,
) -> Result<Vec<MultiClientUsagePreference>, String> {
    let defaults = default_preferences();
    let mut by_client = HashMap::new();
    for preference in supplied {
        if !CLIENTS.contains(&preference.client.as_str()) {
            return Err(format!("不支持的多客户端用量来源: {}", preference.client));
        }
        by_client
            .entry(preference.client.clone())
            .or_insert(preference);
    }
    let mut normalized = defaults
        .into_iter()
        .map(|default| {
            let mut value = by_client
                .remove(&default.client)
                .unwrap_or_else(|| default.clone());
            if !valid_hex_color(&value.color) {
                value.color = default.color;
            }
            if value.style != "compact" && value.style != "detailed" {
                value.style = "compact".into();
            }
            value.path = value.path.trim().chars().take(4096).collect();
            value
        })
        .collect::<Vec<_>>();
    normalized.sort_by(|left, right| {
        left.order
            .cmp(&right.order)
            .then_with(|| left.client.cmp(&right.client))
    });
    for (order, preference) in normalized.iter_mut().enumerate() {
        preference.order = order as u32;
    }
    Ok(normalized)
}

fn valid_hex_color(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 7 && bytes[0] == b'#' && bytes[1..].iter().all(u8::is_ascii_hexdigit)
}

fn deserialize_optional_path<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(Option::<String>::deserialize(deserializer)?.unwrap_or_default())
}

fn preference_path(preference: &MultiClientUsagePreference) -> Option<&str> {
    let path = preference.path.trim();
    (!path.is_empty()).then_some(path)
}

fn load_preferences(path: &Path) -> (Vec<MultiClientUsagePreference>, Vec<String>) {
    let defaults = default_preferences();
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return (defaults, Vec::new())
        }
        Err(error) => return (defaults, vec![format!("读取多客户端用量设置失败: {error}")]),
    };
    let parsed: PreferencesFile = match serde_json::from_slice::<PreferencesFile>(&bytes) {
        Ok(parsed) if parsed.schema_version == 1 => parsed,
        Ok(parsed) => {
            return (
                defaults,
                vec![format!(
                    "不支持的多客户端用量设置版本: {}",
                    parsed.schema_version
                )],
            )
        }
        Err(error) => {
            return (
                defaults,
                vec![format!(
                    "多客户端用量设置格式错误，使用默认关闭设置: {error}"
                )],
            )
        }
    };
    match normalize_preferences(parsed.preferences) {
        Ok(preferences) => (preferences, Vec::new()),
        Err(error) => (
            defaults,
            vec![format!("多客户端用量设置无效，使用默认关闭设置: {error}")],
        ),
    }
}

fn source_roots(client: &str, override_path: Option<&str>) -> Vec<PathBuf> {
    if let Some(path) = override_path.map(str::trim).filter(|path| !path.is_empty()) {
        return vec![expand_path(path)];
    }
    let home = app_paths::home_dir();
    if client == "gemini" {
        let base = std::env::var_os("GEMINI_CLI_HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.clone());
        return vec![
            base.join(".gemini").join("tmp"),
            base.join(".cache").join(".gemini").join("tmp"),
        ];
    }
    let path = match client {
        "claudeCode" | "claudeDesktop" => std::env::var_os("CLAUDE_CONFIG_DIR")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".claude"))
            .join("projects"),
        "deepseek" => std::env::var_os("DSH_HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".dsh"))
            .join("sessions"),
        "opencode" => {
            let configured = std::env::var_os("OPENCODE_DATA_DIR")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from);
            if let Some(path) = configured {
                if path.file_name().is_some_and(|name| name == "opencode.db") {
                    return vec![path];
                }
                return vec![path];
            }
            std::env::var_os("XDG_DATA_HOME")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".local").join("share"))
                .join("opencode")
        }
        _ => return Vec::new(),
    };
    vec![path]
}

fn expand_path(path: &str) -> PathBuf {
    if path == "~" {
        return app_paths::home_dir();
    }
    if let Some(suffix) = path.strip_prefix("~/") {
        return app_paths::home_dir().join(suffix);
    }
    PathBuf::from(path)
}

fn enumerate_source_files(client: &str, root: &Path) -> Result<(Vec<PathBuf>, bool), String> {
    if !root.exists() {
        return Ok((Vec::new(), false));
    }
    if plain_file(root) {
        return Ok((vec![root.to_path_buf()], false));
    }
    if client == "opencode" {
        let mut files = Vec::new();
        let database = root.join("opencode.db");
        if plain_file(&database) {
            files.push(database);
        }
        let legacy_root = root.join("storage").join("message");
        let scan_root = if plain_directory(&legacy_root) {
            &legacy_root
        } else {
            root
        };
        let mut entries = 0usize;
        let mut truncated = false;
        collect_transcripts(
            scan_root,
            "opencode",
            0,
            &mut entries,
            &mut files,
            &mut truncated,
        )?;
        files.sort();
        files.dedup();
        if files.len() > MAX_FILES_PER_CLIENT {
            files.truncate(MAX_FILES_PER_CLIENT);
            truncated = true;
        }
        return Ok((files, truncated));
    }
    let mut files = Vec::new();
    let mut entries = 0usize;
    let mut truncated = false;
    if client == "gemini" {
        for project in safe_read_dir(root)? {
            if !plain_directory(&project) {
                continue;
            }
            let chats = project.join("chats");
            if !plain_directory(&chats) {
                continue;
            }
            for entry in safe_read_dir(&chats)? {
                entries += 1;
                if entries >= MAX_SCANNED_ENTRIES {
                    truncated = true;
                    break;
                }
                if plain_file(&entry) && is_gemini_name(&entry) {
                    files.push(entry);
                } else if plain_directory(&entry) {
                    for nested in safe_read_dir(&entry)? {
                        entries += 1;
                        if entries >= MAX_SCANNED_ENTRIES {
                            truncated = true;
                            break;
                        }
                        if plain_file(&nested) && is_gemini_name(&nested) {
                            files.push(nested);
                        }
                    }
                }
                if truncated {
                    break;
                }
            }
            if truncated {
                break;
            }
        }
    } else {
        collect_transcripts(root, client, 0, &mut entries, &mut files, &mut truncated)?;
    }
    files.sort();
    if files.len() > MAX_FILES_PER_CLIENT {
        files.truncate(MAX_FILES_PER_CLIENT);
        truncated = true;
    }
    Ok((files, truncated))
}

fn collect_transcripts(
    directory: &Path,
    client: &str,
    depth: usize,
    entries: &mut usize,
    files: &mut Vec<PathBuf>,
    truncated: &mut bool,
) -> Result<(), String> {
    if depth > MAX_SCAN_DEPTH {
        return Ok(());
    }
    for path in safe_read_dir(directory)? {
        *entries += 1;
        if *entries >= MAX_SCANNED_ENTRIES || files.len() >= MAX_FILES_PER_CLIENT {
            *truncated = true;
            return Ok(());
        }
        if plain_directory(&path) {
            collect_transcripts(&path, client, depth + 1, entries, files, truncated)?;
            if *truncated {
                return Ok(());
            }
        } else if plain_file(&path) && is_source_name(client, &path) {
            files.push(path);
        }
    }
    Ok(())
}

fn safe_read_dir(path: &Path) -> Result<Vec<PathBuf>, String> {
    let mut entries = Vec::new();
    let read_dir = fs::read_dir(path).map_err(|error| error.to_string())?;
    for entry in read_dir {
        match entry {
            Ok(entry) => entries.push(entry.path()),
            Err(error) => return Err(error.to_string()),
        }
    }
    entries.sort();
    Ok(entries)
}

fn plain_directory(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .map(|metadata| metadata.file_type().is_dir())
        .unwrap_or(false)
}

fn plain_file(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .map(|metadata| metadata.file_type().is_file())
        .unwrap_or(false)
}

fn is_source_name(client: &str, path: &Path) -> bool {
    let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
        return false;
    };
    match client {
        "claudeCode" | "claudeDesktop" => name.to_ascii_lowercase().ends_with(".jsonl"),
        "deepseek" => {
            let lowercase = name.to_ascii_lowercase();
            lowercase.starts_with("session.v")
                && (lowercase.ends_with(".jsonl") || lowercase.ends_with(".jsonl.zstd"))
        }
        "opencode" => {
            let lowercase = name.to_ascii_lowercase();
            lowercase.ends_with(".json")
                || lowercase.ends_with(".db")
                || lowercase.ends_with(".sqlite")
        }
        _ => false,
    }
}

fn is_gemini_name(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .map(|name| {
            let name = name.to_ascii_lowercase();
            name.ends_with(".jsonl") || name.ends_with(".json")
        })
        .unwrap_or(false)
}

fn scan_transcript_file(
    connection: &mut Connection,
    client: &str,
    path: &Path,
) -> Result<(), String> {
    let metadata = fs::metadata(path).map_err(|error| error.to_string())?;
    let source_modified_ns = modified_ns(&metadata);
    let path_key = path.to_string_lossy().to_string();
    let previous =
        read_checkpoint(connection, client, &path_key).map_err(|error| error.to_string())?;
    let lower_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if client == "deepseek" && lower_name.ends_with(".jsonl.zstd") {
        let modified = source_modified_ns as f64 / 1_000_000_000.0;
        let start = if let Some(saved) = &previous {
            let identity = file_prefix_identity(path, saved.offset.min(4_096) as usize)?;
            if saved.fingerprint.as_deref() == Some(identity.as_str())
                && saved.offset <= metadata.len()
                && (saved.size != metadata.len() || saved.modified == modified)
            {
                if saved.offset == metadata.len()
                    && saved.size == metadata.len()
                    && saved.modified == modified
                {
                    return Ok(());
                }
                saved.offset
            } else {
                0
            }
        } else {
            0
        };
        let mut source = fs::File::open(path).map_err(|error| error.to_string())?;
        use std::io::{Seek, SeekFrom};
        source
            .seek(SeekFrom::Start(start))
            .map_err(|error| error.to_string())?;
        let mut chunk = Vec::new();
        source
            .take(4 * 1024 * 1024)
            .read_to_end(&mut chunk)
            .map_err(|error| error.to_string())?;
        let (decoded, consumed) = decode_dsh_frames(&chunk, 16 * 1024 * 1024)?;
        if consumed == 0 {
            if chunk.len() >= 4 * 1024 * 1024 {
                return Err("压缩日志帧或未完成行超过安全上限，断点未前移".into());
            }
            return Ok(());
        }
        let events = parse_deepseek(&decoded, path);
        let offset = start.saturating_add(consumed as u64);
        let identity = file_prefix_identity(path, offset.min(4_096) as usize)?;
        persist_source_update(
            connection,
            client,
            &path_key,
            i64::try_from(offset).unwrap_or(i64::MAX),
            metadata.len(),
            source_modified_ns,
            &identity,
            events,
        )
        .map_err(|error| error.to_string())?;
        return Ok(());
    }
    if lower_name.ends_with(".jsonl") && client != "opencode" {
        let modified = source_modified_ns as f64 / 1_000_000_000.0;
        let start = if let Some(saved) = &previous {
            let width = saved.offset.min(4_096) as usize;
            let identity = file_prefix_identity(path, width)?;
            let unchanged_prefix = saved.fingerprint.as_deref() == Some(identity.as_str());
            if unchanged_prefix
                && saved.offset <= metadata.len()
                && (saved.size != metadata.len() || saved.modified == modified)
            {
                if saved.offset == metadata.len()
                    && saved.size == metadata.len()
                    && saved.modified == modified
                {
                    return Ok(());
                }
                saved.offset
            } else {
                0
            }
        } else {
            0
        };
        let mut source = fs::File::open(path).map_err(|error| error.to_string())?;
        use std::io::{Seek, SeekFrom};
        source
            .seek(SeekFrom::Start(start))
            .map_err(|error| error.to_string())?;
        let mut chunk = Vec::new();
        source
            .take(4 * 1024 * 1024)
            .read_to_end(&mut chunk)
            .map_err(|error| error.to_string())?;
        let Some(last_newline) = chunk.iter().rposition(|byte| *byte == b'\n') else {
            if chunk.len() >= 4 * 1024 * 1024 {
                return Err("单条 JSONL 记录超过 4 MiB，断点未前移".into());
            }
            return Ok(()); // Hold a partial trailing line and preserve the prior checkpoint.
        };
        let complete_len = last_newline + 1;
        let content = &chunk[..complete_len];
        let claude_file_client = if client == "claudeCode" || client == "claudeDesktop" {
            Some(classify_claude_file(path)?)
        } else {
            None
        };
        let events = if claude_file_client.is_some_and(|actual| actual != client) {
            Vec::new()
        } else {
            match client {
                "claudeCode" | "claudeDesktop" => parse_claude(content, path, client),
                "deepseek" => parse_deepseek(content, path),
                "gemini" => parse_gemini(content, path),
                "opencode" => parse_opencode_json(content, path),
                _ => Vec::new(),
            }
        };
        let offset = start.saturating_add(complete_len as u64);
        let identity = file_prefix_identity(path, offset.min(4_096) as usize)?;
        persist_source_update(
            connection,
            client,
            &path_key,
            i64::try_from(offset).unwrap_or(i64::MAX),
            metadata.len(),
            source_modified_ns,
            &identity,
            events,
        )
        .map_err(|error| error.to_string())?;
        return Ok(());
    }

    if metadata.len() > MAX_SOURCE_FILE_BYTES {
        return Err(format!(
            "文件超过 {} MiB",
            MAX_SOURCE_FILE_BYTES / 1024 / 1024
        ));
    }
    let raw = fs::read(path).map_err(|error| error.to_string())?;
    let fingerprint = hex_digest(&raw);
    if previous.as_ref().is_some_and(|checkpoint| {
        checkpoint.size == metadata.len()
            && checkpoint.modified == source_modified_ns as f64 / 1_000_000_000.0
            && checkpoint.fingerprint.as_deref() == Some(fingerprint.as_str())
    }) {
        return Ok(());
    }
    let content = raw;
    let events = match client {
        "claudeCode" | "claudeDesktop" => {
            if classify_claude_bytes(&content) != client {
                Vec::new()
            } else {
                parse_claude(&content, path, client)
            }
        }
        "deepseek" => parse_deepseek(&content, path),
        "gemini" => parse_gemini(&content, path),
        "opencode" => parse_opencode_json(&content, path),
        _ => Vec::new(),
    };
    persist_source_update(
        connection,
        client,
        &path_key,
        i64::try_from(metadata.len()).unwrap_or(i64::MAX),
        metadata.len(),
        source_modified_ns,
        &fingerprint,
        events,
    )
    .map_err(|error| error.to_string())
}

fn scan_opencode(connection: &mut Connection, database_path: &Path) -> Result<Vec<String>, String> {
    let metadata = fs::metadata(&database_path).map_err(|error| error.to_string())?;
    let wal_metadata = fs::metadata(PathBuf::from(format!("{}-wal", database_path.display()))).ok();
    let db_modified_ns = modified_ns(&metadata);
    let wal_stamp = wal_metadata
        .as_ref()
        .map(|metadata| format!("{}:{}", metadata.len(), modified_ns(metadata)))
        .unwrap_or_else(|| "no-wal".into());
    let source_identity = file_identity(&metadata);
    let stat_fingerprint = format!(
        "{source_identity}:{}:{db_modified_ns}:{wal_stamp}",
        metadata.len()
    );
    let path_key = database_path.to_string_lossy().to_string();
    let previous =
        read_checkpoint(connection, "opencode", &path_key).map_err(|error| error.to_string())?;
    let continuation = previous.as_ref().and_then(|checkpoint| {
        if checkpoint.offset != u64::MAX {
            return None;
        }
        let encoded = checkpoint
            .fingerprint
            .as_deref()?
            .strip_prefix("opencode-page:")?;
        let bytes = BASE64.decode(encoded).ok()?;
        let continuation = serde_json::from_slice::<OpenCodeDatabaseContinuation>(&bytes).ok()?;
        (continuation.source_identity == source_identity).then_some(continuation)
    });
    let cursor = continuation.as_ref().map(|value| &value.cursor);
    let source_fingerprint = continuation
        .as_ref()
        .map(|value| value.source_fingerprint.as_str())
        .unwrap_or(&stat_fingerprint);
    if previous.as_ref().is_some_and(|checkpoint| {
        checkpoint.offset != u64::MAX
            && checkpoint.size == metadata.len()
            && checkpoint.modified == db_modified_ns as f64 / 1_000_000_000.0
            && checkpoint.fingerprint.as_deref() == Some(stat_fingerprint.as_str())
    }) {
        return Ok(Vec::new());
    }

    let source = open_read_only(&database_path).map_err(|error| error.to_string())?;
    source
        .pragma_update(None, "query_only", true)
        .map_err(|error| error.to_string())?;
    let table_exists: i64 = source
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='session_message'",
            [],
            |row| row.get(0),
        )
        .map_err(|error| error.to_string())?;
    if table_exists == 0 {
        return Err("OpenCode 数据库不含 session_message 表".into());
    }
    let cursor_filter = if cursor.is_some() {
        "WHERE m.time_updated > ?1 OR (m.time_updated = ?1 AND m.id COLLATE BINARY > ?2)"
    } else {
        ""
    };
    let sql = format!(
        "SELECT m.id,m.session_id,m.type,m.time_created,m.time_updated,\
         CASE WHEN length(CAST(m.data AS BLOB)) <= {MAX_OPENCODE_ROW_BYTES} THEN m.data ELSE NULL END,\
         COALESCE(length(CAST(m.data AS BLOB)),0),s.time_created \
         FROM session_message AS m LEFT JOIN session_v2 AS s ON s.id=m.session_id \
         {cursor_filter} ORDER BY m.time_updated ASC,m.id COLLATE BINARY ASC LIMIT {}",
        MAX_OPENCODE_ROWS + 1
    );
    let mut statement = source.prepare(&sql).map_err(|error| error.to_string())?;
    let mapped = if let Some(cursor) = &cursor {
        statement.query_map(
            params![cursor.updated_at_milliseconds, cursor.message_id],
            opencode_raw_row,
        )
    } else {
        statement.query_map([], opencode_raw_row)
    }
    .map_err(|error| error.to_string())?;
    let rows = mapped
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|error| error.to_string())?;
    let is_complete = rows.len() <= MAX_OPENCODE_ROWS;
    let consumed = rows.iter().take(MAX_OPENCODE_ROWS).collect::<Vec<_>>();
    let mut events = Vec::new();
    let mut malformed = 0usize;
    let mut oversized = 0usize;
    for row in &consumed {
        if row.data_byte_count > MAX_OPENCODE_ROW_BYTES as i64 {
            oversized += 1;
            continue;
        }
        let (Some(event_id), Some(session_id), Some(row_type), Some(data)) = (
            row.id.as_deref(),
            row.session_id.as_deref(),
            row.row_type.as_deref(),
            row.data.as_deref(),
        ) else {
            malformed += 1;
            continue;
        };
        let Ok(value) = serde_json::from_str::<Value>(data) else {
            malformed += 1;
            continue;
        };
        if let Some(event) = parse_opencode_row(
            &event_id,
            &session_id,
            &row_type,
            row.created_ms,
            row.updated_ms,
            row.session_created_ms,
            &value,
        ) {
            events.push(event);
        }
    }
    let mut notices = Vec::new();
    if malformed > 0 || oversized > 0 {
        notices.push(format!("部分消息缺少有效字段或超过单条上限，未计入 Token（无效 {malformed}，超限 {oversized}）"));
    }
    let mut next_offset = i64::try_from(metadata.len()).unwrap_or(i64::MAX);
    let checkpoint_identity = if is_complete {
        source_fingerprint.to_string()
    } else {
        let last = consumed
            .last()
            .ok_or_else(|| "OpenCode 分页缺少游标".to_string())?;
        let next_cursor = OpenCodeDatabaseCursor {
            updated_at_milliseconds: last
                .updated_ms
                .ok_or_else(|| "OpenCode 行缺少更新时间，断点未前移".to_string())?,
            message_id: last
                .id
                .clone()
                .ok_or_else(|| "OpenCode 行缺少稳定 ID，断点未前移".to_string())?,
        };
        let continuation = OpenCodeDatabaseContinuation {
            source_identity,
            source_fingerprint: source_fingerprint.to_string(),
            cursor: next_cursor,
        };
        let bytes = serde_json::to_vec(&continuation).map_err(|error| error.to_string())?;
        next_offset = -1;
        format!("opencode-page:{}", BASE64.encode(bytes))
    };
    persist_source_update(
        connection,
        "opencode",
        &path_key,
        next_offset,
        metadata.len(),
        db_modified_ns,
        &checkpoint_identity,
        events,
    )
    .map_err(|error| error.to_string())?;
    if !is_complete {
        notices.push("历史分页读取中，每轮继续 500 条；已完成的请求已保留".into());
    }
    Ok(notices)
}

fn file_identity(metadata: &fs::Metadata) -> String {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        format!("{}:{}", metadata.dev(), metadata.ino())
    }
    #[cfg(not(unix))]
    {
        metadata
            .created()
            .ok()
            .and_then(|created| created.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|created| format!("created:{}", created.as_nanos()))
            .unwrap_or_else(|| "created:unknown".into())
    }
}

struct OpenCodeRawRow {
    id: Option<String>,
    session_id: Option<String>,
    row_type: Option<String>,
    created_ms: Option<i64>,
    updated_ms: Option<i64>,
    data: Option<String>,
    data_byte_count: i64,
    session_created_ms: Option<i64>,
}

fn opencode_raw_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<OpenCodeRawRow> {
    Ok(OpenCodeRawRow {
        id: row.get(0)?,
        session_id: row.get(1)?,
        row_type: row.get(2)?,
        created_ms: row.get(3)?,
        updated_ms: row.get(4)?,
        data: row.get(5)?,
        data_byte_count: row.get(6)?,
        session_created_ms: row.get(7)?,
    })
}

fn parse_opencode_row(
    event_id: &str,
    session_id: &str,
    row_type: &str,
    row_created_ms: Option<i64>,
    row_updated_ms: Option<i64>,
    session_created_ms: Option<i64>,
    data: &Value,
) -> Option<UsageEvent> {
    if row_type != "assistant" && row_type != "compaction" {
        return None;
    }
    let time = data.get("time").and_then(Value::as_object);
    let message_created_ms = time.and_then(|time| value_timestamp(time.get("created")));
    let created_ms = message_created_ms.or(row_created_ms);
    if row_type == "assistant" {
        if message_created_ms
            .zip(session_created_ms)
            .is_some_and(|(message, session)| message < session.saturating_sub(2_000))
        {
            return None;
        }
        if time
            .and_then(|time| {
                value_timestamp(time.get("streamed"))
                    .or_else(|| value_timestamp(time.get("completed")))
            })
            .is_none()
        {
            return None;
        }
    }
    let tokens = data.get("tokens")?.as_object()?;
    if !count_fields_valid(
        &Value::Object(tokens.clone()),
        &["input", "output", "reasoning", "cache.read", "cache.write"],
    ) {
        return None;
    }
    let input = read_u64(tokens.get("input"));
    let output = read_u64(tokens.get("output"));
    let reasoning = read_u64(tokens.get("reasoning"));
    let cache = tokens.get("cache").and_then(Value::as_object);
    let cache_read = cache.and_then(|cache| read_u64(cache.get("read")));
    let cache_write = cache.and_then(|cache| read_u64(cache.get("write")));
    if input.is_none()
        && output.is_none()
        && reasoning.is_none()
        && cache_read.is_none()
        && cache_write.is_none()
    {
        return None;
    }
    let preferred_time = match row_type {
        "assistant" => time.and_then(|time| {
            value_timestamp(time.get("streamed")).or_else(|| value_timestamp(time.get("completed")))
        }),
        "compaction" => time.and_then(|time| value_timestamp(time.get("completed"))),
        _ => None,
    };
    let timestamp_ms = preferred_time
        .or_else(|| date_timestamp(data.get("timestamp")))
        .or(row_updated_ms)
        .or(created_ms);
    normalized_event(
        "opencode",
        session_id,
        Some(event_id),
        None,
        data.pointer("/model/id")
            .and_then(Value::as_str)
            .or_else(|| data.get("model").and_then(Value::as_str))
            .or_else(|| data.get("modelID").and_then(Value::as_str)),
        timestamp_ms,
        saturated_sum(&[
            input.unwrap_or(0),
            cache_read.unwrap_or(0),
            cache_write.unwrap_or(0),
        ]),
        saturated_sum(&[output.unwrap_or(0), reasoning.unwrap_or(0)]),
        cache_read,
        cache_write,
        reasoning,
    )
}

fn parse_claude(bytes: &[u8], path: &Path, client: &str) -> Vec<UsageEvent> {
    let mut events = BTreeMap::<EventKey, UsageEvent>::new();
    let fallback_session = file_session_id(path);
    for line in bytes.split(|byte| *byte == b'\n') {
        let Ok(value) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        if value.get("type").and_then(Value::as_str) != Some("assistant") {
            continue;
        }
        if let Some(entrypoint) = value.get("entrypoint").and_then(Value::as_str) {
            let is_desktop_record = entrypoint.starts_with("claude-desktop");
            if (client == "claudeDesktop") != is_desktop_record {
                continue;
            }
        }
        let Some(message) = value.get("message") else {
            continue;
        };
        let model = message.get("model").and_then(Value::as_str);
        if model == Some("<synthetic>") {
            continue;
        }
        let Some(usage) = message.get("usage").and_then(Value::as_object) else {
            continue;
        };
        if !count_fields_valid(
            &Value::Object(usage.clone()),
            &[
                "input_tokens",
                "cache_read_input_tokens",
                "cache_creation_input_tokens",
                "output_tokens",
                "output_tokens_details.thinking_tokens",
            ],
        ) {
            continue;
        }
        let input = read_u64(usage.get("input_tokens"));
        let cache_read = read_u64(usage.get("cache_read_input_tokens"));
        let cache_write = read_u64(usage.get("cache_creation_input_tokens"));
        let output = read_u64(usage.get("output_tokens"));
        let reasoning = usage
            .get("output_tokens_details")
            .and_then(Value::as_object)
            .and_then(|details| read_u64(details.get("thinking_tokens")));
        if input.is_none()
            && cache_read.is_none()
            && cache_write.is_none()
            && output.is_none()
            && reasoning.is_none()
        {
            continue;
        }
        let event_id = message
            .get("id")
            .and_then(Value::as_str)
            .or_else(|| value.get("requestId").and_then(Value::as_str))
            .or_else(|| value.get("uuid").and_then(Value::as_str));
        let session_id = value
            .get("sessionId")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .unwrap_or(&fallback_session)
            .to_string();
        let Some(event) = normalized_event(
            client,
            &session_id,
            event_id,
            None,
            model,
            date_timestamp(value.get("timestamp")),
            saturated_sum(&[
                input.unwrap_or(0),
                cache_read.unwrap_or(0),
                cache_write.unwrap_or(0),
            ]),
            output.unwrap_or(0),
            cache_read,
            cache_write,
            reasoning,
        ) else {
            continue;
        };
        merge_file_event(&mut events, event);
    }
    events.into_values().collect()
}

fn parse_deepseek(bytes: &[u8], path: &Path) -> Vec<UsageEvent> {
    let mut events = BTreeMap::<EventKey, UsageEvent>::new();
    let session_hint = deepseek_session_hint(path);
    let mut current_session = Some(session_hint.clone());
    for line in bytes.split(|byte| *byte == b'\n') {
        let Ok(value) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        if let Some(session) = deepseek_header_id(&value) {
            current_session = Some(session);
        }
        collect_deepseek_value(
            &value,
            &session_hint,
            &mut events,
            0,
            None,
            current_session.as_deref(),
        );
    }
    events.into_values().collect()
}

fn collect_deepseek_value(
    value: &Value,
    session_hint: &str,
    events: &mut BTreeMap<EventKey, UsageEvent>,
    depth: usize,
    inherited_time_ms: Option<i64>,
    inherited_session: Option<&str>,
) {
    if depth > 64 {
        return;
    }
    if let Some(array) = value.as_array() {
        for record in array {
            collect_deepseek_value(
                record,
                session_hint,
                events,
                depth + 1,
                inherited_time_ms,
                inherited_session,
            );
        }
        return;
    }
    let Some(object) = value.as_object() else {
        return;
    };
    let kind = object.get("type").and_then(Value::as_str).unwrap_or("");
    let time_ms = value_timestamp(object.get("time")).or(inherited_time_ms);
    let own_session = object
        .get("sessionId")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .or(inherited_session);
    if kind == "session" || kind == "snapshot" {
        let header_session = deepseek_header_id(value);
        let session = header_session.as_deref().or(own_session);
        if let Some(records) = object.get("records").and_then(Value::as_array) {
            for record in records {
                collect_deepseek_value(record, session_hint, events, depth + 1, time_ms, session);
            }
        }
        return;
    }
    if kind == "event" {
        if let Some(inner) = object.get("event") {
            collect_deepseek_value(inner, session_hint, events, depth + 1, time_ms, own_session);
        }
        return;
    }
    if kind == "assistant/message" {
        let data = object.get("data").unwrap_or(&Value::Null);
        let message = data.get("message").unwrap_or(&Value::Null);
        let usage = data
            .get("usage")
            .and_then(Value::as_object)
            .or_else(|| message.get("usage").and_then(Value::as_object));
        if let Some(usage) = usage {
            if !count_fields_valid(
                &Value::Object(usage.clone()),
                &[
                    "inputTokens",
                    "outputTokens",
                    "cacheReadTokens",
                    "cacheWriteTokens",
                ],
            ) {
                return;
            }
            let input = read_u64(usage.get("inputTokens"));
            let output = read_u64(usage.get("outputTokens"));
            let cache_read = read_u64(usage.get("cacheReadTokens"));
            let cache_write = read_u64(usage.get("cacheWriteTokens"));
            if input.is_some() || output.is_some() || cache_read.is_some() || cache_write.is_some()
            {
                let actual_session = own_session
                    .filter(|value| !value.trim().is_empty())
                    .or_else(|| (!session_hint.trim().is_empty()).then_some(session_hint))
                    .unwrap_or("unknown-session");
                let source_id = message.get("id").and_then(Value::as_str);
                let sequence = read_u64(object.get("seq")).map(|value| value.to_string());
                let source = message.get("source").unwrap_or(&Value::Null);
                let event = normalized_event(
                    "deepseek",
                    actual_session,
                    source_id,
                    sequence.as_deref(),
                    source.get("model").and_then(Value::as_str),
                    time_ms,
                    saturated_sum(&[
                        input.unwrap_or(0),
                        cache_read.unwrap_or(0),
                        cache_write.unwrap_or(0),
                    ]),
                    output.unwrap_or(0),
                    cache_read,
                    cache_write,
                    None,
                );
                if let Some(event) = event {
                    merge_file_event(events, event);
                }
            }
        }
        return;
    }
    if let Some(records) = object.get("records").and_then(Value::as_array) {
        for record in records {
            collect_deepseek_value(
                record,
                session_hint,
                events,
                depth + 1,
                time_ms,
                own_session,
            );
        }
    }
}

fn parse_gemini(bytes: &[u8], path: &Path) -> Vec<UsageEvent> {
    let mut events = BTreeMap::<EventKey, UsageEvent>::new();
    let session_hint = file_session_id(path);
    if path
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("json"))
    {
        if let Ok(value) = serde_json::from_slice::<Value>(bytes) {
            collect_gemini_value(&value, None, &session_hint, &mut events, 0);
        }
    } else {
        for line in bytes.split(|byte| *byte == b'\n') {
            let Ok(value) = serde_json::from_slice::<Value>(line) else {
                continue;
            };
            collect_gemini_value(&value, None, &session_hint, &mut events, 0);
        }
    }
    events.into_values().collect()
}

/// DSH's stable session identifier is recorded in the first session line, or in a snapshot header.
/// Those records may live in a prior JSONL chunk/frame, so cache only this identifier using the
/// source path and its bounded prefix fingerprint. The transcript itself is never cached or stored.
fn deepseek_session_hint(path: &Path) -> String {
    let path_key = path.to_string_lossy().into_owned();
    let size = fs::metadata(path)
        .map(|metadata| metadata.len())
        .unwrap_or(0);
    let fingerprint = file_prefix_identity(path, size.min(4_096) as usize).unwrap_or_default();
    let cache = DEEPSEEK_SESSION_HINT_CACHE.get_or_init(|| Mutex::new(VecDeque::new()));
    if let Ok(cache) = cache.lock() {
        if let Some((_, _, session)) = cache.iter().find(|(cached_path, cached_fingerprint, _)| {
            cached_path == &path_key && cached_fingerprint == &fingerprint
        }) {
            return session.clone();
        }
    }

    let session = read_deepseek_header_id(path).unwrap_or_else(|| deepseek_path_session_hint(path));
    if let Ok(mut cache) = cache.lock() {
        cache.retain(|(cached_path, _, _)| cached_path != &path_key);
        if cache.len() >= MAX_DEEPSEEK_SESSION_HINT_CACHE {
            cache.pop_front();
        }
        cache.push_back((path_key, fingerprint, session.clone()));
    }
    session
}

fn read_deepseek_header_id(path: &Path) -> Option<String> {
    let mut file = fs::File::open(path).ok()?;
    let mut bytes = Vec::new();
    file.by_ref()
        .take(4 * 1024 * 1024)
        .read_to_end(&mut bytes)
        .ok()?;
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let decoded = if name.ends_with(".zstd") {
        decode_dsh_frames(&bytes, 16 * 1024 * 1024).ok()?.0
    } else {
        bytes
    };
    deepseek_header_id_in_jsonl(&decoded)
}

fn deepseek_header_id_in_jsonl(bytes: &[u8]) -> Option<String> {
    // DSH headers are emitted as complete first JSONL records. Ignore any unfinished tail.
    let complete_len = bytes
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map(|index| index + 1)
        .unwrap_or(0);
    for line in bytes[..complete_len].split(|byte| *byte == b'\n') {
        let Ok(value) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        if let Some(session) = deepseek_header_id(&value) {
            return Some(session);
        }
    }
    None
}

fn deepseek_header_id(value: &Value) -> Option<String> {
    if let Some(array) = value.as_array() {
        return array.iter().find_map(deepseek_header_id);
    }
    let object = value.as_object()?;
    let kind = object.get("type").and_then(Value::as_str).unwrap_or("");
    let candidate = match kind {
        "session" => object
            .get("id")
            .and_then(Value::as_str)
            .or_else(|| object.get("sessionId").and_then(Value::as_str))
            .or_else(|| {
                object
                    .get("header")
                    .and_then(|header| header.get("id"))
                    .and_then(Value::as_str)
            }),
        "snapshot" => object
            .get("header")
            .and_then(|header| header.get("id"))
            .and_then(Value::as_str)
            .or_else(|| object.get("sessionId").and_then(Value::as_str)),
        _ => None,
    }
    .map(str::trim)
    .filter(|value| !value.is_empty());
    candidate.map(str::to_string).or_else(|| {
        object
            .get("records")
            .and_then(Value::as_array)
            .and_then(|records| records.iter().find_map(deepseek_header_id))
    })
}

fn deepseek_path_session_hint(path: &Path) -> String {
    let canonical_session_file = path
        .file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.to_ascii_lowercase().starts_with("session.v"))
        .unwrap_or(false);
    if canonical_session_file {
        if let Some(parent) = path
            .parent()
            .and_then(Path::file_name)
            .and_then(|name| name.to_str())
            .filter(|name| !name.trim().is_empty())
        {
            return parent.trim().to_string();
        }
    }
    file_session_id(path)
}

fn parse_opencode_json(bytes: &[u8], path: &Path) -> Vec<UsageEvent> {
    let Ok(root) = serde_json::from_slice::<Value>(bytes) else {
        return Vec::new();
    };
    let mut rows = Vec::new();
    collect_opencode_json_rows(&root, &mut rows, 0);
    let session_hint = file_session_id(path);
    rows.into_iter()
        .filter_map(|object| {
            let data = object.get("data").unwrap_or(&object);
            let session_id = object
                .get("session_id")
                .or_else(|| object.get("sessionID"))
                .or_else(|| object.get("sessionId"))
                .or_else(|| data.get("sessionID"))
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .unwrap_or(&session_hint);
            let row_type = object
                .get("type")
                .or_else(|| object.get("role"))
                .and_then(Value::as_str)
                .unwrap_or("assistant");
            parse_opencode_row(
                object.get("id").and_then(Value::as_str).unwrap_or(""),
                session_id,
                row_type,
                data.pointer("/time/created")
                    .and_then(|value| value_timestamp(Some(value)))
                    .or_else(|| {
                        object
                            .get("time_created")
                            .and_then(|value| value_timestamp(Some(value)))
                    }),
                object
                    .get("time_updated")
                    .and_then(|value| value_timestamp(Some(value))),
                object
                    .get("session_created")
                    .and_then(|value| value_timestamp(Some(value))),
                data,
            )
        })
        .collect()
}

fn collect_opencode_json_rows(value: &Value, rows: &mut Vec<Value>, depth: usize) {
    if depth > 64 {
        return;
    }
    if let Some(array) = value.as_array() {
        for item in array {
            collect_opencode_json_rows(item, rows, depth + 1);
        }
        return;
    }
    let Some(object) = value.as_object() else {
        return;
    };
    if let Some(messages) = object.get("messages").and_then(Value::as_array) {
        for message in messages {
            collect_opencode_json_rows(message, rows, depth + 1);
        }
    } else if let Some(message) = object.get("message").and_then(Value::as_object) {
        collect_opencode_json_rows(&Value::Object(message.clone()), rows, depth + 1);
    } else {
        rows.push(value.clone());
    }
}

fn file_prefix_identity(path: &Path, width: usize) -> Result<String, String> {
    let mut file = fs::File::open(path).map_err(|error| error.to_string())?;
    let mut prefix = vec![0; width];
    let read = file.read(&mut prefix).map_err(|error| error.to_string())?;
    prefix.truncate(read);
    Ok(format!("{}:{}", read, hex_digest(&prefix)))
}

fn decode_dsh_frames(input: &[u8], maximum_decoded: usize) -> Result<(Vec<u8>, usize), String> {
    let mut cursor = 0usize;
    let mut committed = 0usize;
    let mut committed_bytes = 0usize;
    let mut decoded = Vec::new();
    while cursor < input.len() {
        let tail = &input[cursor..];
        let frame_size = match zstd::zstd_safe::find_frame_compressed_size(tail) {
            Ok(size) if size > 0 && size <= tail.len() => size,
            Ok(_) => return Err("压缩日志包含无效的空帧".into()),
            Err(code) => {
                let reason = zstd::zstd_safe::get_error_name(code).to_ascii_lowercase();
                if reason.contains("src size") || reason.contains("srcsize") {
                    break; // The harness may still be appending this independent frame.
                }
                return Err(format!("压缩日志帧损坏: {reason}"));
            }
        };
        let mut decompressor =
            zstd::bulk::Decompressor::new().map_err(|error| error.to_string())?;
        decompressor
            .set_parameter(zstd::zstd_safe::DParameter::WindowLogMax(24))
            .map_err(|error| error.to_string())?;
        let frame = &tail[..frame_size];
        let remaining_capacity = maximum_decoded.saturating_sub(decoded.len());
        if remaining_capacity == 0 {
            return Err("压缩日志解压超过安全上限".into());
        }
        let frame_bytes = decompressor
            .decompress(frame, remaining_capacity)
            .map_err(|error| format!("压缩日志帧损坏或超过解压上限: {error}"))?;
        if decoded.len().saturating_add(frame_bytes.len()) > maximum_decoded {
            return Err("压缩日志解压超过安全上限".into());
        }
        decoded.extend_from_slice(&frame_bytes);
        cursor += frame_size;
        if decoded.is_empty() || decoded.last() == Some(&b'\n') {
            committed = cursor;
            committed_bytes = decoded.len();
        }
    }
    Ok((decoded[..committed_bytes].to_vec(), committed))
}

fn classify_claude_file(path: &Path) -> Result<&'static str, String> {
    let file = fs::File::open(path).map_err(|error| error.to_string())?;
    let mut prefix = Vec::new();
    file.take(64 * 1024)
        .read_to_end(&mut prefix)
        .map_err(|error| error.to_string())?;
    Ok(classify_claude_bytes(&prefix))
}

fn classify_claude_bytes(bytes: &[u8]) -> &'static str {
    let complete_len = bytes
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map(|index| index + 1)
        .unwrap_or(0);
    for line in bytes[..complete_len].split(|byte| *byte == b'\n') {
        let Ok(value) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        let Some(entrypoint) = value.get("entrypoint").and_then(Value::as_str) else {
            continue;
        };
        if entrypoint.trim().is_empty() {
            continue;
        }
        return if entrypoint.starts_with("claude-desktop") {
            "claudeDesktop"
        } else {
            "claudeCode"
        };
    }
    "claudeCode"
}

fn collect_gemini_value(
    value: &Value,
    document_session: Option<&str>,
    session_hint: &str,
    events: &mut BTreeMap<EventKey, UsageEvent>,
    depth: usize,
) {
    if depth > 64 {
        return;
    }
    if let Some(array) = value.as_array() {
        for item in array {
            collect_gemini_value(item, document_session, session_hint, events, depth + 1);
        }
        return;
    }
    let Some(object) = value.as_object() else {
        return;
    };
    let kind = object.get("type").and_then(Value::as_str).unwrap_or("");
    let root_session = object
        .get("sessionId")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .or(document_session);
    if kind == "gemini" {
        if let Some(tokens) = object.get("tokens").and_then(Value::as_object) {
            if !count_fields_valid(
                &Value::Object(tokens.clone()),
                &["input", "tool", "output", "cached", "thoughts"],
            ) {
                return;
            }
            let input = read_u64(tokens.get("input"));
            let tool = read_u64(tokens.get("tool"));
            let output = read_u64(tokens.get("output"));
            let cached = read_u64(tokens.get("cached"));
            let thoughts = read_u64(tokens.get("thoughts"));
            if input.is_some()
                || tool.is_some()
                || output.is_some()
                || cached.is_some()
                || thoughts.is_some()
            {
                let timestamp_ms = date_timestamp(object.get("timestamp"));
                if let Some(event) = normalized_event(
                    "gemini",
                    object
                        .get("sessionId")
                        .and_then(Value::as_str)
                        .filter(|value| !value.trim().is_empty())
                        .or(root_session)
                        .unwrap_or(session_hint),
                    object.get("id").and_then(Value::as_str),
                    None,
                    object.get("model").and_then(Value::as_str),
                    timestamp_ms,
                    // Gemini's input counter already includes cached tokens; `cached` is a subset.
                    saturated_sum(&[input.unwrap_or(0), tool.unwrap_or(0)]),
                    saturated_sum(&[output.unwrap_or(0), thoughts.unwrap_or(0)]),
                    cached,
                    None,
                    thoughts,
                ) {
                    merge_file_event(events, event);
                }
            }
        }
    }
    if kind == "gemini" {
        return;
    }
    if let Some(messages) = object.get("messages").and_then(Value::as_array) {
        for message in messages {
            collect_gemini_value(message, root_session, session_hint, events, depth + 1);
        }
        return;
    }
    if let Some(set) = object.get("$set").and_then(Value::as_object) {
        if let Some(checkpoint) = set.get("messages").and_then(Value::as_object) {
            if let Some(messages) = checkpoint.get("messages").and_then(Value::as_array) {
                for message in messages {
                    collect_gemini_value(message, root_session, session_hint, events, depth + 1);
                }
                return;
            }
        }
        if let Some(messages) = set.get("messages").and_then(Value::as_array) {
            for message in messages {
                collect_gemini_value(message, root_session, session_hint, events, depth + 1);
            }
        }
    }
}

fn merge_file_event(events: &mut BTreeMap<EventKey, UsageEvent>, event: UsageEvent) {
    let key = (
        event.client.clone(),
        event.session_id.clone(),
        event.event_id.clone(),
    );
    if let Some(previous) = events.get_mut(&key) {
        previous.input_tokens = previous.input_tokens.max(event.input_tokens);
        previous.output_tokens = previous.output_tokens.max(event.output_tokens);
        previous.cache_read_tokens =
            max_option(previous.cache_read_tokens, event.cache_read_tokens);
        previous.cache_write_tokens =
            max_option(previous.cache_write_tokens, event.cache_write_tokens);
        previous.reasoning_tokens = max_option(previous.reasoning_tokens, event.reasoning_tokens);
        if event.timestamp_ms >= previous.timestamp_ms && event.model != "unknown" {
            previous.model = event.model.clone();
        }
        previous.timestamp_ms = previous.timestamp_ms.max(event.timestamp_ms);
        if previous.quality == "fallback_identity" || event.quality == "fallback_identity" {
            previous.quality = "fallback_identity".into();
        }
    } else {
        events.insert(key, event);
    }
}

fn normalized_event(
    client: &str,
    session_id: &str,
    source_id: Option<&str>,
    sequence: Option<&str>,
    model: Option<&str>,
    timestamp_ms: Option<i64>,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: Option<u64>,
    cache_write_tokens: Option<u64>,
    reasoning_tokens: Option<u64>,
) -> Option<UsageEvent> {
    let timestamp_ms = timestamp_ms?;
    let model = model
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("unknown");
    let session_id = session_id.trim();
    let session = if session_id.is_empty() {
        "unknown-session"
    } else {
        session_id
    };
    let session_hash = hex_digest(session.as_bytes());
    let source_id = source_id.map(str::trim).filter(|value| !value.is_empty());
    let sequence = sequence.map(str::trim).filter(|value| !value.is_empty());
    let (identity, quality) = if let Some(source_id) = source_id {
        (
            format!("id:{}", hex_digest(source_id.as_bytes())),
            "recorded",
        )
    } else if let Some(sequence) = sequence.filter(|value| !value.is_empty()) {
        (format!("seq:{sequence}"), "recorded")
    } else {
        let normalized = [
            client.to_string(),
            timestamp_ms.to_string(),
            model.to_string(),
            input_tokens.to_string(),
            output_tokens.to_string(),
            cache_read_tokens
                .map(|value| value.to_string())
                .unwrap_or_else(|| "-".into()),
            cache_write_tokens
                .map(|value| value.to_string())
                .unwrap_or_else(|| "-".into()),
            reasoning_tokens
                .map(|value| value.to_string())
                .unwrap_or_else(|| "-".into()),
        ]
        .join("\u{1f}");
        (
            format!("fallback:{}", hex_digest(normalized.as_bytes())),
            "fallback_identity",
        )
    };
    Some(UsageEvent {
        client: client.to_string(),
        session_id: session.to_string(),
        event_id: format!("v1:{session_hash}:{identity}"),
        model: model.to_string(),
        timestamp_ms,
        input_tokens: input_tokens.min(MAX_COUNTER),
        output_tokens: output_tokens.min(MAX_COUNTER),
        cache_read_tokens: cache_read_tokens.map(|value| value.min(MAX_COUNTER)),
        cache_write_tokens: cache_write_tokens.map(|value| value.min(MAX_COUNTER)),
        reasoning_tokens: reasoning_tokens.map(|value| value.min(MAX_COUNTER)),
        quality: quality.into(),
    })
}

fn saturated_sum(values: &[u64]) -> u64 {
    values.iter().copied().fold(0, |total, value| {
        total.saturating_add(value).min(MAX_COUNTER)
    })
}

fn max_option<T: Ord>(left: Option<T>, right: Option<T>) -> Option<T> {
    match (left, right) {
        (Some(left), Some(right)) => Some(left.max(right)),
        (Some(value), None) | (None, Some(value)) => Some(value),
        (None, None) => None,
    }
}

fn file_session_id(path: &Path) -> String {
    path.file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("unknown-session")
        .to_string()
}

fn value_scalar_text(value: &Value) -> String {
    match value {
        Value::String(value) => value.clone(),
        Value::Number(value) => value.to_string(),
        _ => "None".into(),
    }
}

fn value_timestamp(value: Option<&Value>) -> Option<i64> {
    let value = value?;
    if let Some(number) = value.as_i64() {
        return (number >= 0).then_some(number);
    }
    if let Some(number) = value.as_u64() {
        return i64::try_from(number).ok();
    }
    None
}

fn date_timestamp(value: Option<&Value>) -> Option<i64> {
    let value = value?;
    if let Some(parsed) = value
        .as_str()
        .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok())
    {
        return i64::try_from(parsed.unix_timestamp_nanos() / 1_000_000).ok();
    }
    let number = value.as_f64().filter(|number| number.is_finite())?;
    let seconds = if number >= 100_000_000_000.0 {
        number / 1_000.0
    } else {
        number
    };
    let millis = (seconds * 1_000.0).round();
    if millis < i64::MIN as f64 || millis > i64::MAX as f64 {
        return None;
    }
    Some(millis as i64)
}

fn read_u64(value: Option<&Value>) -> Option<u64> {
    let value = value?;
    let parsed = value.as_i64().and_then(|value| u64::try_from(value).ok())?;
    Some(parsed.min(MAX_COUNTER))
}

fn count_fields_valid(object: &Value, keys: &[&str]) -> bool {
    keys.iter().all(|key| {
        let mut value = Some(object);
        for component in key.split('.') {
            value = value.and_then(|current| current.as_object()?.get(component));
        }
        match value {
            None | Some(Value::Null) => true,
            Some(value) => value.as_i64().is_some_and(|count| count >= 0),
        }
    })
}

fn modified_ns(metadata: &fs::Metadata) -> i64 {
    metadata
        .modified()
        .ok()
        .and_then(|modified| modified.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| i64::try_from(duration.as_nanos()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

fn hex_digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn persist_source_update(
    connection: &mut Connection,
    client: &str,
    path: &str,
    offset: i64,
    size: u64,
    modified_ns: i64,
    fingerprint: &str,
    events: Vec<UsageEvent>,
) -> rusqlite::Result<()> {
    let transaction = connection.transaction()?;
    for event in events {
        upsert_event(&transaction, &event)?;
    }
    transaction.execute(
        "INSERT INTO client_file_checkpoints(client, source_key, offset, size, modified, identity) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT(client, source_key) DO UPDATE SET \
         offset=excluded.offset, size=excluded.size, modified=excluded.modified, identity=excluded.identity",
        params![
            client,
            path,
            offset,
            size as i64,
            modified_ns as f64 / 1_000_000_000.0,
            fingerprint
        ],
    )?;
    transaction.commit()
}

fn event_payload(event: &UsageEvent) -> rusqlite::Result<String> {
    event_payload_at(event, event.timestamp_ms as f64)
}

fn event_payload_at(event: &UsageEvent, timestamp_ms: f64) -> rusqlite::Result<String> {
    let payload = ClientUsageEventPayload {
        client: event.client.clone(),
        event_id: event.event_id.clone(),
        session_id: event.session_id.clone(),
        model: event.model.clone(),
        timestamp: timestamp_ms,
        input_tokens: event.input_tokens,
        output_tokens: event.output_tokens,
        cache_read_tokens: event.cache_read_tokens,
        cache_write_tokens: event.cache_write_tokens,
        reasoning_tokens: event.reasoning_tokens,
        quality: event.quality.clone(),
    };
    // Serialize through Value so object keys sort as they do with Swift's `.sortedKeys` encoder.
    let value = serde_json::to_value(payload).map_err(|_| rusqlite::Error::InvalidQuery)?;
    serde_json::to_string(&value).map_err(|_| rusqlite::Error::InvalidQuery)
}

fn upsert_event(transaction: &Transaction<'_>, event: &UsageEvent) -> rusqlite::Result<()> {
    let incoming_payload = event_payload(event)?;
    let previous_payload: Option<String> = transaction
        .query_row(
            "SELECT payload FROM client_usage_events WHERE client=?1 AND event_id=?2",
            params![event.client, event.event_id],
            |row| row.get(0),
        )
        .optional()?;
    let mut projected = event.clone();
    let mut projected_timestamp_ms = projected.timestamp_ms as f64;
    if let Some(previous) = previous_payload.as_deref() {
        if let Ok(previous) = serde_json::from_str::<ClientUsageEventPayload>(previous) {
            if previous.session_id == event.session_id {
                projected.input_tokens = projected.input_tokens.max(previous.input_tokens);
                projected.output_tokens = projected.output_tokens.max(previous.output_tokens);
                projected.cache_read_tokens =
                    max_option(projected.cache_read_tokens, previous.cache_read_tokens);
                projected.cache_write_tokens =
                    max_option(projected.cache_write_tokens, previous.cache_write_tokens);
                projected.reasoning_tokens =
                    max_option(projected.reasoning_tokens, previous.reasoning_tokens);
                if previous.timestamp >= projected_timestamp_ms && previous.model != "unknown" {
                    projected.model = previous.model;
                }
                projected_timestamp_ms = projected_timestamp_ms.max(previous.timestamp);
                if previous.quality == "fallback_identity" || event.quality == "fallback_identity" {
                    projected.quality = "fallback_identity".into();
                }
            }
        }
    }
    let projected_payload = event_payload_at(&projected, projected_timestamp_ms)?;
    if previous_payload.as_deref() == Some(projected_payload.as_str()) {
        return Ok(());
    }
    transaction.execute(
        "INSERT INTO client_usage_revisions(client,event_id,captured_at,payload) VALUES(?1,?2,?3,?4)",
        params![event.client, event.event_id, now_ms() as f64 / 1_000.0, incoming_payload],
    )?;
    transaction.execute(
        "INSERT INTO client_usage_events(client,event_id,session_id,model,timestamp,input_tokens,output_tokens, \
         cache_read_tokens,cache_write_tokens,reasoning_tokens,payload) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11) \
         ON CONFLICT(client,event_id) DO UPDATE SET session_id=excluded.session_id,model=excluded.model, \
         timestamp=excluded.timestamp,input_tokens=excluded.input_tokens,output_tokens=excluded.output_tokens, \
         cache_read_tokens=excluded.cache_read_tokens,cache_write_tokens=excluded.cache_write_tokens, \
         reasoning_tokens=excluded.reasoning_tokens,payload=excluded.payload",
        params![
            event.client,
            event.event_id,
            event.session_id,
            event.model,
            projected_timestamp_ms / 1_000.0,
            projected.input_tokens as i64,
            projected.output_tokens as i64,
            projected.cache_read_tokens.map(|value| value as i64),
            projected.cache_write_tokens.map(|value| value as i64),
            projected.reasoning_tokens.map(|value| value as i64),
            projected_payload,
        ],
    )?;
    Ok(())
}

fn read_checkpoint(
    connection: &Connection,
    client: &str,
    path: &str,
) -> rusqlite::Result<Option<Checkpoint>> {
    connection
        .query_row(
            "SELECT offset, size, modified, identity FROM client_file_checkpoints WHERE client=?1 AND source_key=?2",
            params![client, path],
            |row| {
                let raw_offset: i64 = row.get(0)?;
                Ok(Checkpoint {
                    offset: if raw_offset < 0 { u64::MAX } else { raw_offset as u64 },
                    size: row.get::<_, i64>(1)?.max(0) as u64,
                    modified: row.get(2)?,
                    fingerprint: row.get(3)?,
                })
            },
        )
        .optional()
}

fn ensure_schema(connection: &Connection, database_path: &Path) -> rusqlite::Result<()> {
    let schema_version = read_schema_version(connection)?;
    if schema_version > SCHEMA_VERSION {
        return Err(rusqlite::Error::InvalidQuery);
    }
    if schema_version > 0 && !has_expected_usage_tables(connection)? {
        // Never reinterpret a database that claims to be supported but has another layout.
        return Err(rusqlite::Error::InvalidQuery);
    }
    if schema_version < SCHEMA_VERSION {
        let existing_tables: i64 = connection.query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
            [],
            |row| row.get(0),
        )?;
        if existing_tables > 0 {
            backup_before_upgrade(connection, database_path, schema_version)?;
        }
    }
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS client_usage_events (
            client TEXT NOT NULL,
            event_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            model TEXT NOT NULL,
            timestamp REAL NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cache_read_tokens INTEGER,
            cache_write_tokens INTEGER,
            reasoning_tokens INTEGER,
            payload TEXT NOT NULL,
            PRIMARY KEY(client,event_id)
        );
        CREATE INDEX IF NOT EXISTS client_usage_by_model
            ON client_usage_events(client,model,timestamp);
        CREATE INDEX IF NOT EXISTS client_usage_by_time
            ON client_usage_events(timestamp,client);
        CREATE TABLE IF NOT EXISTS client_usage_revisions (
            revision INTEGER PRIMARY KEY AUTOINCREMENT,
            client TEXT NOT NULL,
            event_id TEXT NOT NULL,
            captured_at REAL NOT NULL,
            payload TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS client_file_checkpoints (
            client TEXT NOT NULL,
            source_key TEXT NOT NULL,
            offset INTEGER NOT NULL,
            size INTEGER NOT NULL,
            modified REAL NOT NULL,
            identity TEXT NOT NULL,
            PRIMARY KEY(client,source_key)
        );
        CREATE TABLE IF NOT EXISTS multi_usage_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        "#,
    )?;
    connection.pragma_update(None, "user_version", SCHEMA_VERSION)?;
    Ok(())
}

fn has_expected_usage_tables(connection: &Connection) -> rusqlite::Result<bool> {
    let count: i64 = connection.query_row(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN \
         ('client_usage_events','client_usage_revisions','client_file_checkpoints')",
        [],
        |row| row.get(0),
    )?;
    if count != 3 {
        return Ok(false);
    }
    for (table, expected) in [
        (
            "client_usage_events",
            &[
                "client",
                "event_id",
                "session_id",
                "model",
                "timestamp",
                "input_tokens",
                "output_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
                "reasoning_tokens",
                "payload",
            ][..],
        ),
        (
            "client_usage_revisions",
            &["revision", "client", "event_id", "captured_at", "payload"][..],
        ),
        (
            "client_file_checkpoints",
            &[
                "client",
                "source_key",
                "offset",
                "size",
                "modified",
                "identity",
            ][..],
        ),
    ] {
        let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
        let columns = statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        if expected
            .iter()
            .any(|column| !columns.iter().any(|actual| actual == column))
        {
            return Ok(false);
        }
    }
    Ok(true)
}

fn backup_before_upgrade(
    source: &Connection,
    database_path: &Path,
    old_version: i64,
) -> rusqlite::Result<()> {
    let parent = database_path
        .parent()
        .ok_or(rusqlite::Error::InvalidPath(database_path.to_path_buf()))?;
    let file_name = database_path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("multi-client-usage.sqlite");
    let base = format!("{file_name}.backup-v{old_version}-{}", now_ms());
    let mut path = parent.join(format!("{base}.sqlite"));
    let mut suffix = 0u32;
    while path.exists() {
        suffix = suffix.saturating_add(1);
        path = parent.join(format!("{base}-{suffix}.sqlite"));
    }
    let mut destination = Connection::open(path)?;
    destination.busy_timeout(DATABASE_BUSY_TIMEOUT)?;
    let backup = Backup::new(source, &mut destination)?;
    backup.run_to_completion(128, Duration::from_millis(5), None)?;
    Ok(())
}

fn open_read_only(path: &Path) -> rusqlite::Result<Connection> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )?;
    connection.busy_timeout(DATABASE_BUSY_TIMEOUT)?;
    Ok(connection)
}

fn read_schema_version(connection: &Connection) -> rusqlite::Result<i64> {
    connection.pragma_query_value(None, "user_version", |row| row.get(0))
}

#[derive(Clone)]
struct ApiPriceRates {
    input: i64,
    cached_input: i64,
    cache_write: i64,
    cache_write_1h: i64,
    output: i64,
}

#[derive(Clone)]
struct ApiTieredPrices {
    base: ApiPriceRates,
    tiers: Vec<(i64, ApiPriceRates)>,
}

impl ApiTieredPrices {
    fn select(&self, input_tokens: i64) -> &ApiPriceRates {
        self.tiers
            .iter()
            .filter(|(above, _)| input_tokens > *above)
            .map(|(_, rates)| rates)
            .last()
            .unwrap_or(&self.base)
    }
}

struct BundledApiPriceModel {
    id: String,
    aliases: Vec<String>,
    free: bool,
    has_time_dependent_price: bool,
    base: Option<ApiTieredPrices>,
    fast: Option<ApiTieredPrices>,
}

struct BundledApiPriceCatalog {
    models: Vec<BundledApiPriceModel>,
    identifiers: HashMap<String, Option<usize>>,
}

fn bundled_api_price_catalog() -> &'static BundledApiPriceCatalog {
    static CATALOG: OnceLock<BundledApiPriceCatalog> = OnceLock::new();
    CATALOG.get_or_init(|| {
        let value = serde_json::from_str::<Value>(BUNDLED_PRICE_TABLE).unwrap_or(Value::Null);
        let raw_models = value
            .get("models")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let models = raw_models
            .iter()
            .filter_map(|raw| {
                let id = raw.get("id")?.as_str()?.to_string();
                let aliases = raw
                    .get("aliases")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect();
                let time_dependent_period = raw
                    .get("periods")
                    .and_then(Value::as_array)
                    .is_some_and(|periods| !periods.is_empty());
                let time_dependent_off_peak =
                    raw.get("offPeak").is_some_and(|value| !value.is_null());
                let base = raw
                    .get("prices")
                    .and_then(|prices| parse_tiered_prices(prices, raw.get("tiers")));
                let fast = raw
                    .get("fast")
                    .and_then(|fast| parse_tiered_prices(fast.get("prices")?, fast.get("tiers")));
                Some(BundledApiPriceModel {
                    id,
                    aliases,
                    free: raw.get("free").and_then(Value::as_bool).unwrap_or(false),
                    has_time_dependent_price: time_dependent_period || time_dependent_off_peak,
                    base,
                    fast,
                })
            })
            .collect::<Vec<_>>();
        let mut identifiers = HashMap::new();
        for (index, model) in models.iter().enumerate() {
            for identifier in std::iter::once(&model.id).chain(model.aliases.iter()) {
                let key = identifier.to_ascii_lowercase();
                identifiers
                    .entry(key)
                    .and_modify(|existing: &mut Option<usize>| {
                        if *existing != Some(index) {
                            *existing = None;
                        }
                    })
                    .or_insert(Some(index));
            }
        }
        BundledApiPriceCatalog {
            models,
            identifiers,
        }
    })
}

fn parse_tiered_prices(prices: &Value, tiers: Option<&Value>) -> Option<ApiTieredPrices> {
    let base = parse_api_price_rates(prices)?;
    let mut parsed_tiers = Vec::new();
    for tier in tiers.and_then(Value::as_array).into_iter().flatten() {
        let above = tier.get("above")?.as_i64()?;
        parsed_tiers.push((above, parse_api_price_rates(tier)?));
    }
    Some(ApiTieredPrices {
        base,
        tiers: parsed_tiers,
    })
}

fn parse_api_price_rates(value: &Value) -> Option<ApiPriceRates> {
    let input = price_rate_micro_usd(value.get("input")?)?;
    let output = price_rate_micro_usd(value.get("output")?)?;
    let cache_write = value
        .get("cacheWrite")
        .filter(|value| !value.is_null())
        .and_then(price_rate_micro_usd)
        .unwrap_or(input);
    let cached_input = value
        .get("cachedInput")
        .filter(|value| !value.is_null())
        .and_then(price_rate_micro_usd)
        .unwrap_or(input);
    let cache_write_1h = value
        .get("cacheWrite1h")
        .filter(|value| !value.is_null())
        .and_then(price_rate_micro_usd)
        .unwrap_or(cache_write);
    Some(ApiPriceRates {
        input,
        cached_input,
        cache_write,
        cache_write_1h,
        output,
    })
}

/// Parse the pinned USD/million-token decimal exactly into integer micro-USD/million,
/// which is pico-USD per token in the bundled PriceBook.
fn price_rate_micro_usd(value: &Value) -> Option<i64> {
    let literal = value.as_number()?.to_string();
    let (whole, fraction) = literal.split_once('.').unwrap_or((&literal, ""));
    if whole.starts_with('-')
        || whole.is_empty()
        || !whole.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    if !fraction.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let whole = whole.parse::<i64>().ok()?;
    let significant_fraction = &fraction[..fraction.len().min(6)];
    if fraction.len() > 6 && fraction[6..].bytes().any(|byte| byte != b'0') {
        return None;
    }
    let fraction_value = if significant_fraction.is_empty() {
        0
    } else {
        significant_fraction.parse::<i64>().ok()?
    };
    let scaled_fraction =
        fraction_value.checked_mul(10_i64.pow(6 - significant_fraction.len() as u32))?;
    whole.checked_mul(1_000_000)?.checked_add(scaled_fraction)
}

fn api_cost_micro_usd(
    raw_model: &str,
    input: i64,
    output: i64,
    cache_read: Option<i64>,
    cache_write: Option<i64>,
) -> Option<i64> {
    let identifier = raw_model.rsplit('/').next()?.trim().to_ascii_lowercase();
    if identifier.is_empty() {
        return None;
    }
    let catalog = bundled_api_price_catalog();
    let (model_index, explicit_fast) = match catalog.identifiers.get(&identifier) {
        Some(Some(index)) => (*index, false),
        Some(None) => return None,
        None if identifier.ends_with("-fast") => {
            let base = identifier.strip_suffix("-fast")?;
            match catalog.identifiers.get(base) {
                Some(Some(index)) => (*index, true),
                _ => return None,
            }
        }
        None => return None,
    };
    let model = catalog.models.get(model_index)?;
    if model.free {
        return Some(0);
    }
    if model.has_time_dependent_price {
        return None;
    }
    let pricing = if explicit_fast {
        model.fast.as_ref()?
    } else {
        model.base.as_ref()?
    };
    let rates = pricing.select(input);
    let cache_read = cache_read?;
    let cache_write = cache_write?;
    if input < 0
        || output < 0
        || cache_read < 0
        || cache_write < 0
        || cache_read > input
        || cache_write > input - cache_read
        || (cache_write > 0 && rates.cache_write != rates.cache_write_1h)
    {
        return None;
    }
    let uncached_input = input - cache_read - cache_write;
    const MAX_CLASS_TOKENS: i64 = 100_000_000;
    if [uncached_input, cache_read, cache_write, output]
        .into_iter()
        .any(|count| count > MAX_CLASS_TOKENS)
    {
        return None;
    }
    let components = [
        uncached_input.checked_mul(rates.input)?,
        cache_read.checked_mul(rates.cached_input)?,
        cache_write.checked_mul(rates.cache_write)?,
        output.checked_mul(rates.output)?,
    ];
    let pico_usd = components.into_iter().try_fold(0_i64, i64::checked_add)?;
    pico_usd.checked_add(500_000).map(|value| value / 1_000_000)
}

fn read_summaries(
    connection: &Connection,
) -> rusqlite::Result<(Vec<MultiClientUsageSummary>, Option<String>)> {
    Ok((read_summary_rows(connection)?, read_updated_at(connection)?))
}

fn read_summary_rows(connection: &Connection) -> rusqlite::Result<Vec<MultiClientUsageSummary>> {
    read_summary_rows_with_prices(connection, None)
}

fn read_summary_rows_with_prices(
    connection: &Connection,
    price_totals: Option<&HashMap<MultiClientPriceModelKey, MultiClientPriceTally>>,
) -> rusqlite::Result<Vec<MultiClientUsageSummary>> {
    read_summary_rows_since_with_prices(connection, price_totals, None)
}

fn read_summary_rows_since_with_prices(
    connection: &Connection,
    price_totals: Option<&HashMap<MultiClientPriceModelKey, MultiClientPriceTally>>,
    since_unix: Option<i64>,
) -> rusqlite::Result<Vec<MultiClientUsageSummary>> {
    let query = if since_unix.is_some() {
        "SELECT client, model, SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens), \
         SUM(cache_write_tokens), SUM(reasoning_tokens), COUNT(*), MAX(timestamp), \
         SUM(cache_read_tokens IS NULL OR cache_write_tokens IS NULL OR reasoning_tokens IS NULL), \
         SUM(cache_read_tokens IS NULL)=0 \
         FROM client_usage_events WHERE timestamp >= ?1 GROUP BY client, model ORDER BY client, model"
    } else {
        "SELECT client, model, SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens), \
         SUM(cache_write_tokens), SUM(reasoning_tokens), COUNT(*), MAX(timestamp), \
         SUM(cache_read_tokens IS NULL OR cache_write_tokens IS NULL OR reasoning_tokens IS NULL), \
         SUM(cache_read_tokens IS NULL)=0 \
         FROM client_usage_events GROUP BY client, model ORDER BY client, model"
    };
    let mut statement = connection.prepare(query)?;
    let read_row = |row: &rusqlite::Row<'_>| {
        let timestamp_seconds: Option<f64> = row.get(8)?;
        let client: String = row.get(0)?;
        let model: String = row.get(1)?;
        let price_tally = price_totals.and_then(|totals| {
            totals.get(&MultiClientPriceModelKey {
                client: client.clone(),
                model: model.clone(),
            })
        });
        Ok(MultiClientUsageSummary {
            client,
            model,
            input_tokens: row.get::<_, i64>(2)?.max(0) as u64,
            output_tokens: row.get::<_, i64>(3)?.max(0) as u64,
            cache_read_tokens: row
                .get::<_, Option<i64>>(4)?
                .map(|value| value.max(0) as u64),
            cache_write_tokens: row
                .get::<_, Option<i64>>(5)?
                .map(|value| value.max(0) as u64),
            reasoning_tokens: row
                .get::<_, Option<i64>>(6)?
                .map(|value| value.max(0) as u64),
            requests: row.get::<_, i64>(7)?.max(0) as u64,
            last_seen: timestamp_seconds.and_then(format_timestamp_seconds),
            incomplete_fields: row.get::<_, i64>(9)? != 0,
            api_cost_usd: price_tally
                .filter(|tally| tally.has_known_request && !tally.overflowed)
                .and_then(|tally| tally.known_cost_micro_usd)
                .map(|cost| cost as f64 / 1_000_000.0),
            unpriced_requests: price_tally.map_or(0, |tally| tally.unpriced_requests),
            cache_read_complete: row.get::<_, i64>(10)? != 0,
        })
    };
    let rows = if let Some(cutoff) = since_unix {
        statement.query_map([cutoff as f64], read_row)?
    } else {
        statement.query_map([], read_row)?
    };
    rows.collect::<rusqlite::Result<Vec<_>>>()
}

fn read_scoped_api_price_aggregates(
    connection: &Connection,
    cutoff_unix: i64,
) -> Result<HashMap<MultiClientPriceModelKey, MultiClientPriceTally>, String> {
    let mut totals = HashMap::<MultiClientPriceModelKey, MultiClientPriceTally>::new();
    let mut statement = connection
        .prepare(
            "SELECT client,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens \
             FROM client_usage_events WHERE timestamp >= ?1",
        )
        .map_err(|error| error.to_string())?;
    let rows = statement
        .query_map([cutoff_unix as f64], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, Option<i64>>(4)?,
                row.get::<_, Option<i64>>(5)?,
            ))
        })
        .map_err(|error| error.to_string())?;
    for row in rows {
        let (client, model, input, output, cache_read, cache_write) =
            row.map_err(|error| error.to_string())?;
        totals
            .entry(MultiClientPriceModelKey {
                client,
                model: model.clone(),
            })
            .or_default()
            .add(api_cost_micro_usd(
                &model,
                input,
                output,
                cache_read,
                cache_write,
            ));
    }
    Ok(totals)
}

fn read_cached_scoped_summaries(
    connection: &Connection,
    database_path: &Path,
    revision: i64,
    cutoff_unix: i64,
    cache: &Mutex<MultiClientScopedSummaryCache>,
) -> Result<
    (
        Vec<MultiClientUsageSummary>,
        Option<(
            MultiClientScopedSummaryCacheKey,
            Vec<MultiClientUsageSummary>,
        )>,
    ),
    String,
> {
    let key = MultiClientScopedSummaryCacheKey {
        database_path: database_path.to_path_buf(),
        revision,
        cutoff_unix,
    };
    if let Some(summaries) = cache.lock().ok().and_then(|mut cache| cache.get(&key)) {
        return Ok((summaries, None));
    }

    let price_totals = read_scoped_api_price_aggregates(connection, cutoff_unix)?;
    let summaries =
        read_summary_rows_since_with_prices(connection, Some(&price_totals), Some(cutoff_unix))
            .map_err(|error| error.to_string())?;
    Ok((summaries.clone(), Some((key, summaries))))
}

fn read_cached_api_price_aggregates(
    connection: &Connection,
    database_path: &Path,
    cache: &Mutex<MultiClientPriceCache>,
) -> Result<
    (
        HashMap<MultiClientPriceModelKey, MultiClientPriceTally>,
        Option<(
            MultiClientPriceAggregateKey,
            HashMap<MultiClientPriceModelKey, MultiClientPriceTally>,
        )>,
    ),
    String,
> {
    let revision = connection
        .query_row(
            "SELECT COALESCE(MAX(revision),0) FROM client_usage_revisions",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map_err(|error| error.to_string())?;
    let key = MultiClientPriceAggregateKey {
        database_path: database_path.to_path_buf(),
        revision,
    };
    if let Some(totals) = cache.lock().ok().and_then(|mut cache| cache.get(&key)) {
        return Ok((totals, None));
    }

    let mut totals = HashMap::<MultiClientPriceModelKey, MultiClientPriceTally>::new();
    let mut statement = connection
        .prepare(
            "SELECT client,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens \
             FROM client_usage_events",
        )
        .map_err(|error| error.to_string())?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, Option<i64>>(4)?,
                row.get::<_, Option<i64>>(5)?,
            ))
        })
        .map_err(|error| error.to_string())?;
    for row in rows {
        let (client, model, input, output, cache_read, cache_write) =
            row.map_err(|error| error.to_string())?;
        let key = MultiClientPriceModelKey {
            client,
            model: model.clone(),
        };
        totals.entry(key).or_default().add(api_cost_micro_usd(
            &model,
            input,
            output,
            cache_read,
            cache_write,
        ));
    }

    Ok((totals.clone(), Some((key, totals))))
}

fn read_updated_at(connection: &Connection) -> rusqlite::Result<Option<String>> {
    let metadata_exists: i64 = connection.query_row(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='multi_usage_metadata'",
        [],
        |row| row.get(0),
    )?;
    let updated_at = if metadata_exists > 0 {
        let value: Option<String> = connection
            .query_row(
                "SELECT value FROM multi_usage_metadata WHERE key='updated_at_ms'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        value
            .and_then(|value| value.parse::<i64>().ok())
            .and_then(format_timestamp)
    } else {
        let latest_revision: Option<f64> = connection.query_row(
            "SELECT MAX(captured_at) FROM client_usage_revisions",
            [],
            |row| row.get(0),
        )?;
        latest_revision.and_then(format_timestamp_seconds)
    };
    Ok(updated_at)
}

fn read_cached_multi_client_aggregates(
    connection: &Connection,
    database_path: &Path,
    now_unix: i64,
    cache: &Mutex<MultiClientAggregateCache>,
) -> Result<MultiClientAggregateRead, String> {
    let snapshot = connection
        .unchecked_transaction()
        .map_err(|error| error.to_string())?;
    let (result, pending_price_cache, pending_aggregate_cache, pending_scoped_summary_caches) =
        read_cached_multi_client_aggregates_in_snapshot(
            &snapshot,
            database_path,
            now_unix,
            cache,
            MULTI_CLIENT_PRICE_CACHE.get_or_init(Default::default),
        )?;
    snapshot.commit().map_err(|error| error.to_string())?;
    if let Some((key, totals)) = pending_price_cache {
        if let Ok(mut cache) = MULTI_CLIENT_PRICE_CACHE
            .get_or_init(Default::default)
            .lock()
        {
            cache.put(key, totals);
        }
    }
    if let Some((key, arrays)) = pending_aggregate_cache {
        if let Ok(mut cache) = cache.lock() {
            cache.put(key, arrays);
        }
    }
    if let Ok(mut cache) = MULTI_CLIENT_SCOPED_SUMMARY_CACHE
        .get_or_init(Default::default)
        .lock()
    {
        for (key, summaries) in pending_scoped_summary_caches {
            cache.put(key, summaries);
        }
    }
    Ok(result)
}

fn read_cached_multi_client_aggregates_in_snapshot(
    connection: &Connection,
    database_path: &Path,
    now_unix: i64,
    cache: &Mutex<MultiClientAggregateCache>,
    price_cache: &Mutex<MultiClientPriceCache>,
) -> Result<
    (
        MultiClientAggregateRead,
        Option<(
            MultiClientPriceAggregateKey,
            HashMap<MultiClientPriceModelKey, MultiClientPriceTally>,
        )>,
        Option<(MultiClientAggregateCacheKey, MultiClientAggregateArrays)>,
        Vec<(
            MultiClientScopedSummaryCacheKey,
            Vec<MultiClientUsageSummary>,
        )>,
    ),
    String,
> {
    let key = multi_client_aggregate_cache_key(connection, database_path, now_unix)
        .map_err(|error| error.to_string())?;
    if let Some(arrays) = cache.lock().ok().and_then(|mut cache| cache.get(&key)) {
        let updated_at = read_updated_at(connection).map_err(|error| error.to_string())?;
        return Ok((
            MultiClientAggregateRead { arrays, updated_at },
            None,
            None,
            Vec::new(),
        ));
    }

    let (price_totals, pending_price_cache) =
        read_cached_api_price_aggregates(connection, database_path, price_cache)?;
    let today_start =
        crate::core::localtime::local_day_bounds(crate::core::localtime::local_date_at(now_unix))
            .map_err(|error| error.to_string())?
            .0;
    let seven_day_start = now_unix
        .div_euclid(300)
        .saturating_mul(300)
        .saturating_sub(7 * 24 * 60 * 60);
    let scoped_cache = MULTI_CLIENT_SCOPED_SUMMARY_CACHE.get_or_init(Default::default);
    let (today_summaries, today_cache) = read_cached_scoped_summaries(
        connection,
        database_path,
        key.revision,
        today_start,
        scoped_cache,
    )?;
    let (seven_day_summaries, seven_day_cache) = read_cached_scoped_summaries(
        connection,
        database_path,
        key.revision,
        seven_day_start,
        scoped_cache,
    )?;
    let mut pending_scoped_summary_caches = Vec::with_capacity(2);
    pending_scoped_summary_caches.extend(today_cache);
    pending_scoped_summary_caches.extend(seven_day_cache);
    let arrays = MultiClientAggregateArrays {
        summaries: read_summary_rows_with_prices(connection, Some(&price_totals))
            .map_err(|error| error.to_string())?,
        today_summaries,
        seven_day_summaries,
        trend_buckets: read_trend_buckets(connection, now_unix)
            .map_err(|error| error.to_string())?,
        daily_buckets: read_daily_buckets(connection, now_unix)?,
    };
    let updated_at = read_updated_at(connection).map_err(|error| error.to_string())?;

    // The caller publishes these only after the read transaction commits.
    let pending_aggregate_cache = Some((key, arrays.clone()));
    Ok((
        MultiClientAggregateRead { arrays, updated_at },
        pending_price_cache,
        pending_aggregate_cache,
        pending_scoped_summary_caches,
    ))
}

fn multi_client_aggregate_cache_key(
    connection: &Connection,
    database_path: &Path,
    now_unix: i64,
) -> rusqlite::Result<MultiClientAggregateCacheKey> {
    let revision = connection.query_row(
        "SELECT COALESCE(MAX(revision),0) FROM client_usage_revisions",
        [],
        |row| row.get(0),
    )?;
    Ok(MultiClientAggregateCacheKey {
        database_path: database_path.to_path_buf(),
        revision,
        minute: now_unix.div_euclid(60),
        local_day: crate::core::localtime::local_date_at(now_unix),
        local_offset_seconds: crate::core::localtime::local_offset_at(now_unix).whole_seconds(),
    })
}

fn read_trend_buckets(
    connection: &Connection,
    now_unix: i64,
) -> rusqlite::Result<Vec<MultiClientUsageTrendBucket>> {
    const WINDOW_SECONDS: i64 = 30 * 24 * 60 * 60;
    let start_unix = now_unix.saturating_sub(WINDOW_SECONDS);
    let mut statement = connection.prepare(
        "SELECT client, CAST(timestamp / 300 AS INTEGER) * 300 AS start_unix, \
         SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens), \
         SUM(cache_write_tokens), SUM(reasoning_tokens), COUNT(*) \
         FROM client_usage_events \
         WHERE client <> 'codex' AND timestamp >= ?1 AND timestamp <= ?2 \
         GROUP BY client, CAST(timestamp / 300 AS INTEGER) \
         ORDER BY client, start_unix",
    )?;
    let rows = statement.query_map(params![start_unix, now_unix], |row| {
        Ok(MultiClientUsageTrendBucket {
            client: row.get(0)?,
            start_unix: row.get(1)?,
            input_tokens: row.get::<_, i64>(2)?.max(0) as u64,
            output_tokens: row.get::<_, i64>(3)?.max(0) as u64,
            cache_read_tokens: row
                .get::<_, Option<i64>>(4)?
                .map(|value| value.max(0) as u64),
            cache_write_tokens: row
                .get::<_, Option<i64>>(5)?
                .map(|value| value.max(0) as u64),
            reasoning_tokens: row
                .get::<_, Option<i64>>(6)?
                .map(|value| value.max(0) as u64),
            requests: row.get::<_, i64>(7)?.max(0) as u64,
        })
    })?;
    rows.collect()
}

/// Stream the raw multi-client events and retain only one aggregate per
/// client/local-date. This deliberately has no LIMIT: history size is reduced
/// by day aggregation without silently dropping clients or source rows.
fn read_daily_buckets(
    connection: &Connection,
    now_unix: i64,
) -> Result<Vec<MultiClientUsageTrendBucket>, String> {
    let today = crate::core::localtime::local_date_at(now_unix);
    let first_day = today
        .checked_sub(CalendarDuration::days(364))
        .ok_or_else(|| "Daily bucket window is outside the supported date range".to_string())?;
    let (start_unix, _) = crate::core::localtime::local_day_bounds(first_day)?;
    let mut statement = connection
        .prepare(
            "SELECT client,timestamp,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens \
             FROM client_usage_events WHERE client <> 'codex' AND timestamp >= ?1 AND timestamp <= ?2",
        )
        .map_err(|error| error.to_string())?;
    let rows = statement
        .query_map(params![start_unix, now_unix], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, f64>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, Option<i64>>(4)?,
                row.get::<_, Option<i64>>(5)?,
                row.get::<_, Option<i64>>(6)?,
            ))
        })
        .map_err(|error| error.to_string())?;

    let mut grouped = BTreeMap::<(String, i64), MultiClientUsageTrendBucket>::new();
    let mut day_starts = BTreeMap::<Date, i64>::new();
    for row in rows {
        let (client, timestamp, input, output, cache_read, cache_write, reasoning) =
            row.map_err(|error| error.to_string())?;
        if !timestamp.is_finite() {
            continue;
        }
        let event_unix = timestamp.floor() as i64;
        let day = crate::core::localtime::local_date_at(event_unix);
        if day < first_day || day > today {
            continue;
        }
        let start_unix = if let Some(start) = day_starts.get(&day) {
            *start
        } else {
            let start = crate::core::localtime::local_day_bounds(day)?.0;
            day_starts.insert(day, start);
            start
        };
        let key = (client.clone(), start_unix);
        let bucket = grouped
            .entry(key)
            .or_insert_with(|| MultiClientUsageTrendBucket {
                client,
                start_unix,
                input_tokens: 0,
                output_tokens: 0,
                cache_read_tokens: None,
                cache_write_tokens: None,
                reasoning_tokens: None,
                requests: 0,
            });
        bucket.input_tokens = bucket.input_tokens.saturating_add(input.max(0) as u64);
        bucket.output_tokens = bucket.output_tokens.saturating_add(output.max(0) as u64);
        bucket.cache_read_tokens = sum_optional(bucket.cache_read_tokens, cache_read);
        bucket.cache_write_tokens = sum_optional(bucket.cache_write_tokens, cache_write);
        bucket.reasoning_tokens = sum_optional(bucket.reasoning_tokens, reasoning);
        bucket.requests = bucket.requests.saturating_add(1);
    }
    Ok(grouped.into_values().collect())
}

fn sum_optional(current: Option<u64>, incoming: Option<i64>) -> Option<u64> {
    match incoming {
        Some(value) => Some(current.unwrap_or(0).saturating_add(value.max(0) as u64)),
        None => current,
    }
}

fn now_unix_seconds() -> i64 {
    OffsetDateTime::now_utc().unix_timestamp()
}

fn now_ms() -> i64 {
    i64::try_from(OffsetDateTime::now_utc().unix_timestamp_nanos() / 1_000_000).unwrap_or(i64::MAX)
}

fn format_timestamp(timestamp_ms: i64) -> Option<String> {
    OffsetDateTime::from_unix_timestamp_nanos(timestamp_ms as i128 * 1_000_000)
        .ok()
        .and_then(|timestamp| timestamp.format(&Rfc3339).ok())
}

fn format_timestamp_seconds(timestamp_seconds: f64) -> Option<String> {
    if !timestamp_seconds.is_finite() {
        return None;
    }
    let nanos = (timestamp_seconds * 1_000_000_000.0).round();
    if nanos < i128::MIN as f64 || nanos > i128::MAX as f64 {
        return None;
    }
    OffsetDateTime::from_unix_timestamp_nanos(nanos as i128)
        .ok()
        .and_then(|timestamp| timestamp.format(&Rfc3339).ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::SystemTime;

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(label: &str) -> Self {
            let nonce = SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "codex-tokenbar-multi-client-{label}-{}-{nonce}",
                std::process::id()
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn preferences_for(paths: &[(&str, &Path)]) -> Vec<MultiClientUsagePreference> {
        let mut preferences = default_preferences();
        for preference in &mut preferences {
            if let Some((_, path)) = paths
                .iter()
                .find(|(client, _)| *client == preference.client)
            {
                preference.enabled = true;
                preference.path = path.to_string_lossy().to_string();
            }
        }
        preferences
    }

    #[test]
    fn defaults_keep_all_clients_and_surfaces_disabled() {
        let preferences = default_preferences();
        assert_eq!(
            preferences
                .iter()
                .map(|value| value.client.as_str())
                .collect::<Vec<_>>(),
            CLIENTS
        );
        assert!(preferences.iter().all(|value| !value.enabled
            && !value.show_sidebar
            && !value.show_menu_bar
            && !value.show_quota));
    }

    #[test]
    fn legacy_preferences_decode_show_quota_as_false() {
        let preference: MultiClientUsagePreference = serde_json::from_value(serde_json::json!({
            "client": "claudeCode",
            "enabled": false,
            "showSidebar": false,
            "showMenuBar": false,
            "color": "#d87757",
            "order": 0,
            "style": "compact"
        }))
        .unwrap();
        assert!(!preference.show_quota);
    }

    #[test]
    fn disabled_first_run_returns_detection_without_creating_usage_database() {
        let temporary = TempDir::new("disabled-first-run");
        let settings = temporary.path().join("settings.json");
        let database = temporary.path().join("multi-client-usage.sqlite");
        let snapshot = refresh_multi_client_usage_at(&settings, &database).unwrap();
        assert!(snapshot
            .preferences
            .iter()
            .all(|preference| !preference.enabled));
        assert!(database.exists() == false);
        assert_eq!(snapshot.quotas.len(), 5);
    }

    #[test]
    fn claude_normalizes_cache_input_and_deduplicates_same_request_id() {
        let bytes = br#"{"sessionId":"s1","entrypoint":"cli","type":"assistant","timestamp":"2026-10-20T10:02:04.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":1000,"cache_read_input_tokens":20000,"output_tokens":150,"output_tokens_details":{"thinking_tokens":60}}}}
{"sessionId":"s1","entrypoint":"cli","type":"assistant","timestamp":"2026-10-20T10:02:06.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":1000,"cache_read_input_tokens":20000,"output_tokens":300,"output_tokens_details":{"thinking_tokens":60}}}}
{"sessionId":"s2","entrypoint":"claude-desktop","type":"assistant","timestamp":"2026-10-20T10:03:05.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":3,"output_tokens":5}}}"#;
        let events = parse_claude(bytes, Path::new("s.jsonl"), "claudeCode");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].input_tokens, 21_002);
        assert_eq!(events[0].output_tokens, 300);
        assert_eq!(events[0].reasoning_tokens, Some(60));
        let desktop_events = parse_claude(bytes, Path::new("s.jsonl"), "claudeDesktop");
        assert_eq!(desktop_events.len(), 1);
        assert_eq!(desktop_events[0].client, "claudeDesktop");
        let expected_id = format!("v1:{}:id:{}", hex_digest(b"s1"), hex_digest(b"m1"));
        assert_eq!(events[0].event_id, expected_id);
        assert_eq!(
            events[0].output_tokens, 300,
            "thinking is already included in Claude output"
        );
        let payload: Value = serde_json::from_str(&event_payload(&events[0]).unwrap()).unwrap();
        assert_eq!(payload["eventID"], expected_id);
        assert_eq!(payload["sessionID"], "s1");
        assert_eq!(payload["timestamp"].as_f64(), Some(1_792_490_526_000.0));
        assert!(payload.get("eventId").is_none());
        assert!(payload.get("cacheWriteTokens").is_some());
        assert!(payload.get("incompleteFields").is_none());
    }

    #[test]
    fn refresh_skips_unchanged_sources_deduplicates_and_keeps_revisions_after_deletion() {
        let temporary = TempDir::new("repeat-delete-correct");
        let database = temporary.path().join("multi-client-usage.sqlite");
        let claude_root = temporary.path().join("claude");
        fs::create_dir_all(&claude_root).unwrap();
        let transcript = claude_root.join("session.jsonl");
        fs::write(
            &transcript,
            br#"{"sessionId":"session-a","entrypoint":"cli","type":"assistant","timestamp":"2026-10-20T10:02:04.000Z","message":{"id":"event-a","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":5,"output_tokens_details":{"thinking_tokens":2}}}}
{"sessionId":"session-a","entrypoint":"cli","type":"assistant","timestamp":"2026-10-20T10:02:05.000Z","message":{"id":"event-a","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":7,"output_tokens_details":{"thinking_tokens":2}}}}
"#,
        )
        .unwrap();
        let preferences = preferences_for(&[("claudeCode", claude_root.as_path())]);
        let settings_path = temporary.path().join("settings.json");
        let bytes = serde_json::to_vec(&PreferencesFile {
            schema_version: 1,
            preferences,
        })
        .unwrap();
        fs::write(&settings_path, bytes).unwrap();
        let (loaded, _) = load_preferences(&settings_path);
        let mut connection = open_database(&database).unwrap();
        ensure_schema(&connection, &database).unwrap();
        scan_transcript_file(&mut connection, "claudeCode", &transcript).unwrap();
        let first = read_summaries(&connection).unwrap().0;
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].requests, 1);
        assert_eq!(first[0].input_tokens, 32);
        assert_eq!(first[0].output_tokens, 7);
        drop(connection);

        let mut connection = open_database(&database).unwrap();
        scan_transcript_file(&mut connection, "claudeCode", &transcript).unwrap();
        let revisions: i64 = connection
            .query_row("SELECT count(*) FROM client_usage_revisions", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(
            revisions, 1,
            "unchanged source files do not create another revision"
        );
        drop(connection);

        fs::write(
            &transcript,
            br#"{"sessionId":"session-a","entrypoint":"cli","type":"assistant","timestamp":"2026-10-20T10:02:04.000Z","message":{"id":"event-a","model":"claude-opus-5-5","usage":{"input_tokens":1,"cache_creation_input_tokens":4,"cache_read_input_tokens":5,"output_tokens":3}}}
"#,
        )
        .unwrap();
        let mut connection = open_database(&database).unwrap();
        scan_transcript_file(&mut connection, "claudeCode", &transcript).unwrap();
        let corrected = read_summaries(&connection).unwrap().0;
        assert_eq!(corrected[0].input_tokens, 32);
        assert_eq!(corrected[0].output_tokens, 7);
        assert!(!corrected[0].incomplete_fields);
        let revisions: i64 = connection
            .query_row("SELECT count(*) FROM client_usage_revisions", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(
            revisions, 1,
            "smaller replay preserves the merged projection"
        );
        drop(connection);

        fs::write(
            &transcript,
            br#"{"sessionId":"session-a","entrypoint":"cli","type":"assistant","timestamp":"2026-10-20T10:02:08.000Z","message":{"id":"event-a","model":"claude-opus-5-5","usage":{"input_tokens":40,"output_tokens":9}}}
"#,
        )
        .unwrap();
        let mut connection = open_database(&database).unwrap();
        scan_transcript_file(&mut connection, "claudeCode", &transcript).unwrap();
        let corrected = read_summaries(&connection).unwrap().0;
        assert_eq!(corrected[0].input_tokens, 40);
        assert_eq!(corrected[0].output_tokens, 9);
        assert_eq!(corrected[0].cache_read_tokens, Some(20));
        assert_eq!(corrected[0].cache_write_tokens, Some(10));
        let revisions: i64 = connection
            .query_row("SELECT count(*) FROM client_usage_revisions", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(revisions, 2);
        drop(connection);

        fs::remove_file(&transcript).unwrap();
        let connection = open_database(&database).unwrap();
        let retained = read_summaries(&connection).unwrap().0;
        assert_eq!(retained[0].input_tokens, 40);
        assert_eq!(loaded.iter().filter(|value| value.enabled).count(), 1);
    }

    #[test]
    fn fractional_swift_timestamp_decodes_and_lower_replay_keeps_projection() {
        let temporary = TempDir::new("fractional-swift-payload");
        let database = temporary.path().join("multi-client-usage.sqlite");
        let connection = open_database(&database).unwrap();
        ensure_schema(&connection, &database).unwrap();
        let event_id = format!("v1:{}:id:{}", hex_digest(b"s"), hex_digest(b"e"));
        let existing = serde_json::json!({
            "client": "claudeCode",
            "eventID": event_id.clone(),
            "sessionID": "s",
            "model": "claude-opus-5-5",
            "timestamp": 1_792_490_524_000.25_f64,
            "inputTokens": 20,
            "outputTokens": 5,
            "cacheReadTokens": 10,
            "cacheWriteTokens": 4,
            "reasoningTokens": 2,
            "quality": "recorded"
        });
        connection
            .execute(
                "INSERT INTO client_usage_events(client,event_id,session_id,model,timestamp,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,payload) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
                params![
                    "claudeCode", event_id, "s", "claude-opus-5-5",
                    1_792_490_524_000.25_f64 / 1_000.0, 20, 5, 10, 4, 2,
                    serde_json::to_string(&existing).unwrap()
                ],
            )
            .unwrap();
        let incoming = normalized_event(
            "claudeCode",
            "s",
            Some("e"),
            None,
            Some("unknown"),
            Some(1_792_490_523_000),
            2,
            1,
            None,
            None,
            None,
        )
        .unwrap();
        let transaction = connection.unchecked_transaction().unwrap();
        upsert_event(&transaction, &incoming).unwrap();
        transaction.commit().unwrap();
        let stored: String = connection
            .query_row("SELECT payload FROM client_usage_events", [], |row| {
                row.get(0)
            })
            .unwrap();
        let stored: Value = serde_json::from_str(&stored).unwrap();
        assert_eq!(stored["timestamp"].as_f64(), Some(1_792_490_524_000.25));
        assert_eq!(stored["inputTokens"], 20);
        let revisions: i64 = connection
            .query_row("SELECT count(*) FROM client_usage_revisions", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(revisions, 0);
    }

    #[test]
    fn jsonl_scanner_resumes_after_its_four_mib_chunk() {
        let temporary = TempDir::new("bounded-jsonl-scan");
        let database = temporary.path().join("multi-client-usage.sqlite");
        let transcript = temporary.path().join("session.jsonl");
        let mut connection = open_database(&database).unwrap();
        ensure_schema(&connection, &database).unwrap();

        let noise = format!("{{\"ignored\":\"{}\"}}\n", "x".repeat(900));
        let mut bytes = Vec::new();
        while bytes.len() <= 4 * 1024 * 1024 + noise.len() {
            bytes.extend_from_slice(noise.as_bytes());
        }
        bytes.extend_from_slice(
            br#"{"sessionId":"gemini-session","id":"final-event","timestamp":"2026-10-20T10:20:09.000Z","type":"gemini","model":"gemini-2.5-pro","tokens":{"input":8,"output":3}}"#,
        );
        bytes.push(b'\n');
        fs::write(&transcript, &bytes).unwrap();

        scan_transcript_file(&mut connection, "gemini", &transcript).unwrap();
        let checkpoint = read_checkpoint(&connection, "gemini", &transcript.to_string_lossy())
            .unwrap()
            .unwrap();
        assert!(checkpoint.offset > 0);
        assert!(checkpoint.offset < bytes.len() as u64);
        assert!(read_summaries(&connection).unwrap().0.is_empty());

        scan_transcript_file(&mut connection, "gemini", &transcript).unwrap();
        let summaries = read_summaries(&connection).unwrap().0;
        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].requests, 1);
        assert_eq!(summaries[0].input_tokens, 8);
        let checkpoint = read_checkpoint(&connection, "gemini", &transcript.to_string_lossy())
            .unwrap()
            .unwrap();
        assert_eq!(checkpoint.offset, bytes.len() as u64);
    }

    #[test]
    fn opencode_database_pages_beyond_five_hundred_rows() {
        let temporary = TempDir::new("opencode-paging");
        let ledger = temporary.path().join("multi-client-usage.sqlite");
        let source_path = temporary.path().join("opencode.db");
        let mut source = Connection::open(&source_path).unwrap();
        source
            .execute_batch(
                "CREATE TABLE session_v2(id TEXT PRIMARY KEY, time_created INTEGER NOT NULL);\
                 CREATE TABLE session_message(id TEXT PRIMARY KEY, session_id TEXT NOT NULL,\
                 type TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);\
                 INSERT INTO session_v2(id,time_created) VALUES('session-a',0);",
            )
            .unwrap();
        let transaction = source.transaction().unwrap();
        for index in 0..501i64 {
            let created = 1_792_490_524_000 + index * 2_000;
            let updated = created + 1_000;
            let id = format!("message-{index:04}");
            let data = serde_json::json!({
                "time": {"created": created, "streamed": updated},
                "model": {"id": "model-a"},
                "tokens": {"input": 1, "output": 2}
            });
            transaction
                .execute(
                    "INSERT INTO session_message(id,session_id,type,time_created,time_updated,data) VALUES(?1,'session-a','assistant',?2,?3,?4)",
                    params![id, created, updated, data.to_string()],
                )
                .unwrap();
        }
        transaction.commit().unwrap();
        drop(source);

        let mut connection = open_database(&ledger).unwrap();
        ensure_schema(&connection, &ledger).unwrap();
        let first_notices = scan_opencode(&mut connection, &source_path).unwrap();
        assert!(first_notices.iter().any(|notice| notice.contains("500 条")));
        let first = read_summaries(&connection).unwrap().0;
        assert_eq!(first[0].requests, 500);

        let created = 1_792_490_524_000i64 + 501i64 * 2_000;
        let updated = created + 1_000;
        let data = serde_json::json!({
            "time": {"created": created, "streamed": updated},
            "model": {"id": "model-a"},
            "tokens": {"input": 1, "output": 2}
        });
        Connection::open(&source_path)
            .unwrap()
            .execute(
                "INSERT INTO session_message(id,session_id,type,time_created,time_updated,data) VALUES('message-0501','session-a','assistant',?1,?2,?3)",
                params![created, updated, data.to_string()],
            )
            .unwrap();

        let second_notices = scan_opencode(&mut connection, &source_path).unwrap();
        assert!(second_notices.is_empty());
        let complete = read_summaries(&connection).unwrap().0;
        assert_eq!(complete[0].requests, 502);
        assert_eq!(complete[0].input_tokens, 502);
        assert_eq!(complete[0].output_tokens, 1_004);

        let replay_notices = scan_opencode(&mut connection, &source_path).unwrap();
        assert!(replay_notices
            .iter()
            .any(|notice| notice.contains("500 条")));
        assert!(scan_opencode(&mut connection, &source_path)
            .unwrap()
            .is_empty());
        assert!(scan_opencode(&mut connection, &source_path)
            .unwrap()
            .is_empty());
        assert_eq!(read_summaries(&connection).unwrap().0[0].requests, 502);
    }

    #[test]
    fn dsh_reader_holds_a_split_compressed_frame_until_it_is_complete() {
        use std::io::Cursor;

        let first = zstd::stream::encode_all(Cursor::new(b"first-event\n"), 0).unwrap();
        let second = zstd::stream::encode_all(Cursor::new(b"second-event\n"), 0).unwrap();
        let mut partial = first.clone();
        partial.extend_from_slice(&second[..second.len() - 3]);
        let (decoded, consumed) = decode_dsh_frames(&partial, 1024).unwrap();
        assert_eq!(decoded, b"first-event\n");
        assert_eq!(consumed, first.len());

        let mut complete = first.clone();
        complete.extend_from_slice(&second);
        let (decoded, consumed) = decode_dsh_frames(&complete, 1024).unwrap();
        assert_eq!(decoded, b"first-event\nsecond-event\n");
        assert_eq!(consumed, complete.len());
    }

    #[test]
    fn gemini_and_deepseek_keep_reasoning_as_output_subset() {
        let gemini = br#"{"sessionId":"g1","id":"g-event","timestamp":"2026-10-20T10:20:09.000Z","type":"gemini","model":"gemini-2.5-pro","tokens":{"input":8000,"output":60,"cached":500,"thoughts":200,"tool":7}}"#;
        let gemini_events = parse_gemini(gemini, Path::new("session.jsonl"));
        assert_eq!(gemini_events[0].input_tokens, 8007);
        assert_eq!(gemini_events[0].output_tokens, 260);
        assert_eq!(gemini_events[0].reasoning_tokens, Some(200));

        let dsh = br#"{"type":"session","version":4,"id":" file-id ","createdAt":1792490520000}
{"type":"assistant/message","seq":4,"time":1792490524000,"data":{"message":{"id":" m1 ","source":{"model":" deepseek-v4 "}},"usage":{"inputTokens":5,"outputTokens":8,"cacheReadTokens":11,"cacheWriteTokens":12}}}"#;
        let dsh_events = parse_deepseek(dsh, Path::new("session.v1.jsonl"));
        assert_eq!(dsh_events.len(), 1);
        assert_eq!(dsh_events[0].input_tokens, 28);
        assert_eq!(dsh_events[0].reasoning_tokens, None);
        assert_eq!(dsh_events[0].session_id, "file-id");
        assert_eq!(dsh_events[0].model, "deepseek-v4");
        assert_eq!(
            dsh_events[0].event_id,
            format!("v1:{}:id:{}", hex_digest(b"file-id"), hex_digest(b"m1"))
        );

        let negative_sequence = br#"{"type":"assistant/message","seq":-4,"time":1792490524000,"sessionId":"session-native","data":{"usage":{"inputTokens":5}}}"#;
        let negative_events = parse_deepseek(negative_sequence, Path::new("session.v1.jsonl"));
        assert_eq!(negative_events.len(), 1);
        assert_eq!(negative_events[0].session_id, "session-native");
        assert_eq!(negative_events[0].quality, "fallback_identity");
    }

    #[test]
    fn deepseek_session_header_survives_append_restart_and_separates_same_named_files() {
        let temporary = TempDir::new("deepseek-stable-session");
        let database = temporary.path().join("multi-client-usage.sqlite");
        let first = temporary
            .path()
            .join("project-a")
            .join("path-session-a")
            .join("session.v4.jsonl.zstd");
        let second = temporary
            .path()
            .join("project-b")
            .join("path-session-b")
            .join("session.v4.jsonl.zstd");
        fs::create_dir_all(first.parent().unwrap()).unwrap();
        fs::create_dir_all(second.parent().unwrap()).unwrap();
        let event = |id: Option<&str>, sequence: u64, input: u64| {
            serde_json::json!({
                "type": "assistant/message",
                "seq": sequence,
                "time": 1_792_490_524_000u64,
                "data": {
                    "message": {
                        "id": id,
                        "source": {"model": "deepseek-v4"}
                    },
                    "usage": {"inputTokens": input, "outputTokens": 8}
                }
            })
        };
        let snapshot = serde_json::json!({
            "type": "snapshot",
            "header": {"id": "native-session-a"},
            "records": [event(Some("message-a"), 4, 10)]
        });
        let encoded_frame = |value: &Value| {
            let mut line = serde_json::to_vec(value).unwrap();
            line.push(b'\n');
            zstd::stream::encode_all(std::io::Cursor::new(line), 0).unwrap()
        };
        fs::write(&first, encoded_frame(&snapshot)).unwrap();

        let mut connection = open_database(&database).unwrap();
        ensure_schema(&connection, &database).unwrap();
        let read_rows = |connection: &Connection| {
            connection
                .prepare(
                    "SELECT session_id,event_id,input_tokens FROM client_usage_events \
                     ORDER BY session_id,event_id",
                )
                .unwrap()
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, u64>(2)?,
                    ))
                })
                .unwrap()
                .collect::<rusqlite::Result<Vec<_>>>()
                .unwrap()
        };
        scan_transcript_file(&mut connection, "deepseek", &first).unwrap();
        let initial = read_rows(&connection);
        assert_eq!(initial.len(), 1);
        assert_eq!(initial[0].0, "native-session-a");
        assert_eq!(initial[0].2, 10);

        use std::io::Write;
        let mut append = fs::OpenOptions::new().append(true).open(&first).unwrap();
        append
            .write_all(&encoded_frame(&event(Some("message-a"), 4, 12)))
            .unwrap();
        append.flush().unwrap();
        scan_transcript_file(&mut connection, "deepseek", &first).unwrap();
        let updated = read_rows(&connection);
        assert_eq!(updated.len(), 1);
        assert_eq!(updated[0].0, "native-session-a");
        assert_eq!(updated[0].2, 12);

        let first_path_key = first.to_string_lossy().to_string();
        if let Some(cache) = DEEPSEEK_SESSION_HINT_CACHE.get() {
            cache
                .lock()
                .unwrap()
                .retain(|(path, _, _)| path != &first_path_key);
        }
        let mut append = fs::OpenOptions::new().append(true).open(&first).unwrap();
        append
            .write_all(&encoded_frame(&event(Some("message-a"), 4, 9)))
            .unwrap();
        append.flush().unwrap();
        scan_transcript_file(&mut connection, "deepseek", &first).unwrap();
        let restarted = read_rows(&connection);
        assert_eq!(restarted.len(), 1);
        assert_eq!(restarted[0].0, "native-session-a");
        assert_eq!(restarted[0].2, 12);

        // The other canonical file has the same basename and sequence, but no header.
        // Its session directory provides a separate identity from the first transcript.
        fs::write(&second, encoded_frame(&event(None, 4, 3))).unwrap();
        scan_transcript_file(&mut connection, "deepseek", &second).unwrap();
        let separated = read_rows(&connection);
        assert_eq!(separated.len(), 2);
        assert!(separated.iter().any(|row| row.0 == "native-session-a"));
        assert!(separated.iter().any(|row| row.0 == "path-session-b"));
        assert_ne!(separated[0].1, separated[1].1);
    }

    #[test]
    fn opencode_reader_combines_cache_and_reasoning_without_reading_content() {
        let value: Value = serde_json::from_str(
            r#"{"time":{"created":1000,"streamed":2000,"completed":3000},"model":{"id":"model-x"},"tokens":{"input":3,"output":10,"reasoning":4,"cache":{"read":100,"write":2}}}"#,
        )
        .unwrap();
        let event = parse_opencode_row(
            "row-1",
            "session-1",
            "assistant",
            Some(1000),
            Some(3000),
            Some(0),
            &value,
        )
        .unwrap();
        assert_eq!(event.input_tokens, 105);
        assert_eq!(event.output_tokens, 14);
        assert_eq!(event.reasoning_tokens, Some(4));
    }

    #[test]
    fn claude_quota_reader_states_and_expired_resets_are_explicit() {
        let now = OffsetDateTime::now_utc().unix_timestamp() as f64;
        let json = serde_json::json!({
            "captured_at_epoch": now,
            "rate_limits": {
                "five_hour": {"used_percentage": 37.5, "resets_at": now - 20.0},
                "seven_day": {"used_percentage": 12, "resets_at": now + 120.0}
            }
        });
        let captured = json["captured_at_epoch"].as_f64().unwrap();
        let limits = json["rate_limits"].as_object().unwrap();
        let five_hour = parse_claude_quota_window(limits.get("five_hour"), now)
            .unwrap()
            .unwrap();
        let seven_day = parse_claude_quota_window(limits.get("seven_day"), now)
            .unwrap()
            .unwrap();
        assert_eq!(five_hour.used_percent, 37.5);
        assert_eq!(five_hour.resets_at, None);
        assert!(seven_day.resets_at.is_some());
        assert!(epoch_seconds_iso(captured).is_some());
        assert_eq!(
            parse_claude_quota_window(Some(&serde_json::json!({"used_percentage":101})), now),
            Err(())
        );
        assert_eq!(claude_quota_state("missing").state, "missing");
        assert_eq!(now_epoch_state(now + 61.0, now), "invalid");
        assert_eq!(now_epoch_state(now - 601.0, now), "stale");
    }

    #[test]
    fn claude_quota_file_reader_handles_missing_stale_tombstone_and_size_limit() {
        let temporary = TempDir::new("claude-quota-file");
        let path = temporary.path().join("latest.json");
        assert_eq!(read_claude_local_quota_at(&path, 10_000.0).state, "missing");

        fs::write(&path, b"null").unwrap();
        assert_eq!(read_claude_local_quota_at(&path, 10_000.0).state, "missing");

        fs::write(
            &path,
            br#"{"captured_at_epoch":9399,"rate_limits":{"five_hour":{"used_percentage":37.5,"resets_at":9500}}}"#,
        )
        .unwrap();
        let stale = read_claude_local_quota_at(&path, 10_000.0);
        assert_eq!(stale.state, "stale");
        assert!(stale.captured_at.is_some());
        assert!(stale.five_hour.is_none());

        fs::write(
            &path,
            br#"{"captured_at_epoch":10000,"rate_limits":{"five_hour":{"used_percentage":37.5,"resets_at":9999}}}"#,
        )
        .unwrap();
        let available = read_claude_local_quota_at(&path, 10_000.0);
        assert_eq!(available.state, "available");
        assert_eq!(available.five_hour.unwrap().resets_at, None);

        fs::write(&path, vec![b'x'; 64 * 1024 + 1]).unwrap();
        assert_eq!(read_claude_local_quota_at(&path, 10_000.0).state, "invalid");
    }

    fn now_epoch_state(captured: f64, now: f64) -> &'static str {
        if captured > now + 60.0 {
            "invalid"
        } else if now - captured > 600.0 {
            "stale"
        } else {
            "available"
        }
    }

    #[test]
    fn schema_upgrade_backs_up_existing_data_and_future_schema_is_left_untouched() {
        let temporary = TempDir::new("schema-preservation");
        let database = temporary.path().join("multi-client-usage.sqlite");
        let legacy = Connection::open(&database).unwrap();
        legacy.execute_batch("CREATE TABLE legacy(value TEXT); INSERT INTO legacy VALUES('preserved'); PRAGMA user_version=0;").unwrap();
        ensure_schema(&legacy, &database).unwrap();
        let events_columns = table_columns(&legacy, "client_usage_events");
        assert_eq!(
            events_columns,
            vec![
                "client".to_string(),
                "event_id".to_string(),
                "session_id".to_string(),
                "model".to_string(),
                "timestamp".to_string(),
                "input_tokens".to_string(),
                "output_tokens".to_string(),
                "cache_read_tokens".to_string(),
                "cache_write_tokens".to_string(),
                "reasoning_tokens".to_string(),
                "payload".to_string(),
            ]
        );
        drop(legacy);
        let backups = fs::read_dir(temporary.path())
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.to_string_lossy().contains("backup-v0"))
            .collect::<Vec<_>>();
        assert_eq!(backups.len(), 1);
        let backup = Connection::open(&backups[0]).unwrap();
        let preserved: String = backup
            .query_row("SELECT value FROM legacy", [], |row| row.get(0))
            .unwrap();
        assert_eq!(preserved, "preserved");
        drop(backup);

        let future = temporary.path().join("future.sqlite");
        let connection = Connection::open(&future).unwrap();
        connection.execute_batch("CREATE TABLE untouched(value INTEGER); INSERT INTO untouched VALUES(7); PRAGMA user_version=99;").unwrap();
        assert!(ensure_schema(&connection, &future).is_err());
        let version = read_schema_version(&connection).unwrap();
        let value: i64 = connection
            .query_row("SELECT value FROM untouched", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, 99);
        assert_eq!(value, 7);
    }

    #[test]
    fn schema_v1_upgrade_backs_up_and_preserves_events_and_checkpoints() {
        let temporary = TempDir::new("schema-v1-to-v2");
        let database = temporary.path().join("multi-client-usage.sqlite");
        let connection = open_database(&database).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE client_usage_events (client TEXT NOT NULL,event_id TEXT NOT NULL,session_id TEXT NOT NULL,model TEXT NOT NULL,timestamp REAL NOT NULL,input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,cache_read_tokens INTEGER,cache_write_tokens INTEGER,reasoning_tokens INTEGER,payload TEXT NOT NULL,PRIMARY KEY(client,event_id));\
                 CREATE INDEX client_usage_by_model ON client_usage_events(client,model,timestamp);\
                 CREATE TABLE client_usage_revisions (revision INTEGER PRIMARY KEY AUTOINCREMENT,client TEXT NOT NULL,event_id TEXT NOT NULL,captured_at REAL NOT NULL,payload TEXT NOT NULL);\
                 CREATE TABLE client_file_checkpoints (client TEXT NOT NULL,source_key TEXT NOT NULL,offset INTEGER NOT NULL,size INTEGER NOT NULL,modified REAL NOT NULL,identity TEXT NOT NULL,PRIMARY KEY(client,source_key));\
                 INSERT INTO client_usage_events VALUES('claudeCode','e1','s1','fixture',1800000000,12,4,NULL,2,NULL,'{}');\
                 INSERT INTO client_file_checkpoints VALUES('claudeCode','/fixture/session.jsonl',128,256,1800000000,'fingerprint');\
                 PRAGMA user_version=1;",
            )
            .unwrap();

        ensure_schema(&connection, &database).unwrap();
        assert_eq!(read_schema_version(&connection).unwrap(), 2);
        let event_count: i64 = connection
            .query_row("SELECT count(*) FROM client_usage_events", [], |row| {
                row.get(0)
            })
            .unwrap();
        let event_tokens: (i64, i64) = connection
            .query_row(
                "SELECT input_tokens,output_tokens FROM client_usage_events WHERE event_id='e1'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        let checkpoint_count: i64 = connection
            .query_row("SELECT count(*) FROM client_file_checkpoints", [], |row| {
                row.get(0)
            })
            .unwrap();
        let timestamp_index: i64 = connection
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='client_usage_by_time'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(event_count, 1);
        assert_eq!(event_tokens, (12, 4));
        assert_eq!(checkpoint_count, 1);
        assert_eq!(timestamp_index, 1);

        drop(connection);
        let backups = fs::read_dir(temporary.path())
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.to_string_lossy().contains("backup-v1"))
            .collect::<Vec<_>>();
        assert_eq!(backups.len(), 1);
        let backup = Connection::open(&backups[0]).unwrap();
        assert_eq!(read_schema_version(&backup).unwrap(), 1);
        assert_eq!(
            backup
                .query_row("SELECT count(*) FROM client_usage_events", [], |row| row
                    .get::<_, i64>(0))
                .unwrap(),
            1
        );
        assert_eq!(
            backup
                .query_row("SELECT count(*) FROM client_file_checkpoints", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap(),
            1
        );
    }

    fn open_database(path: &Path) -> rusqlite::Result<Connection> {
        let connection = Connection::open(path)?;
        connection.busy_timeout(DATABASE_BUSY_TIMEOUT)?;
        Ok(connection)
    }

    fn insert_trend_event(
        connection: &Connection,
        client: &str,
        event_id: &str,
        timestamp: f64,
        input: i64,
        output: i64,
        cache_read: Option<i64>,
        cache_write: Option<i64>,
        reasoning: Option<i64>,
    ) {
        connection
            .execute(
                "INSERT INTO client_usage_events(client,event_id,session_id,model,timestamp,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,payload) VALUES(?1,?2,?2,'fixture',?3,?4,?5,?6,?7,?8,'{}')",
                params![client, event_id, timestamp, input, output, cache_read, cache_write, reasoning],
            )
            .unwrap();
    }

    fn insert_revision(connection: &Connection, client: &str, event_id: &str, captured_at: f64) {
        connection
            .execute(
                "INSERT INTO client_usage_revisions(client,event_id,captured_at,payload) VALUES(?1,?2,?3,'{}')",
                params![client, event_id, captured_at],
            )
            .unwrap();
    }

    fn insert_model_summary_event(
        connection: &Connection,
        client: &str,
        event_id: &str,
        model: &str,
        timestamp: i64,
    ) {
        connection
            .execute(
                "INSERT INTO client_usage_events(client,event_id,session_id,model,timestamp,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,payload) VALUES(?1,?2,?2,?3,?4,100,10,0,0,0,'{}')",
                params![client, event_id, model, timestamp as f64],
            )
            .unwrap();
        insert_revision(connection, client, event_id, timestamp as f64);
    }

    fn read_priced_summaries_for_test(
        connection: &Connection,
        database: &Path,
        cache: &Mutex<MultiClientPriceCache>,
    ) -> Vec<MultiClientUsageSummary> {
        let snapshot = connection.unchecked_transaction().unwrap();
        let (totals, pending) =
            read_cached_api_price_aggregates(&snapshot, database, cache).unwrap();
        let summaries = read_summary_rows_with_prices(&snapshot, Some(&totals)).unwrap();
        snapshot.commit().unwrap();
        if let Some((key, totals)) = pending {
            cache.lock().unwrap().put(key, totals);
        }
        summaries
    }

    #[test]
    fn five_minute_trends_align_utc_and_conserve_raw_events_within_30_days() {
        let temporary = TempDir::new("five-minute-trends");
        let database = temporary.path().join("multi-client-usage.sqlite");
        let connection = open_database(&database).unwrap();
        ensure_schema(&connection, &database).unwrap();

        let now = 1_800_000_600_i64;
        let window_start = now - 30 * 24 * 60 * 60;
        insert_trend_event(
            &connection,
            "claudeCode",
            "at-start",
            window_start as f64,
            10,
            1,
            None,
            Some(2),
            None,
        );
        insert_trend_event(
            &connection,
            "claudeCode",
            "same-bucket",
            (window_start + 299) as f64,
            3,
            4,
            Some(5),
            None,
            Some(7),
        );
        insert_trend_event(
            &connection,
            "claudeCode",
            "next-bucket",
            (window_start + 300) as f64,
            2,
            3,
            None,
            None,
            None,
        );
        insert_trend_event(
            &connection,
            "deepseek",
            "latest",
            (now - 1) as f64,
            8,
            9,
            Some(10),
            Some(11),
            Some(12),
        );
        insert_trend_event(
            &connection,
            "claudeCode",
            "too-old",
            (window_start - 1) as f64,
            100,
            100,
            Some(100),
            Some(100),
            Some(100),
        );
        insert_trend_event(
            &connection,
            "claudeCode",
            "at-upper-bound",
            now as f64,
            100,
            100,
            Some(100),
            Some(100),
            Some(100),
        );
        insert_trend_event(
            &connection,
            "claudeCode",
            "future",
            (now + 1) as f64,
            100,
            100,
            Some(100),
            Some(100),
            Some(100),
        );
        insert_trend_event(
            &connection,
            "codex",
            "codex-is-not-a-multi-client-trend",
            (now - 1) as f64,
            100,
            100,
            Some(100),
            Some(100),
            Some(100),
        );

        let buckets = read_trend_buckets(&connection, now).unwrap();
        assert_eq!(buckets.len(), 4);
        assert!(buckets.iter().all(|bucket| bucket.client != "codex"));
        assert!(buckets
            .iter()
            .all(|bucket| bucket.start_unix.rem_euclid(300) == 0));
        assert_eq!(
            buckets
                .iter()
                .map(|b| b.input_tokens + b.output_tokens)
                .sum::<u64>(),
            240
        );

        let first = buckets
            .iter()
            .find(|bucket| bucket.client == "claudeCode" && bucket.start_unix == window_start)
            .unwrap();
        assert_eq!(first.input_tokens, 13);
        assert_eq!(first.output_tokens, 5);
        assert_eq!(first.cache_read_tokens, Some(5));
        assert_eq!(first.cache_write_tokens, Some(2));
        assert_eq!(first.reasoning_tokens, Some(7));
        assert_eq!(first.requests, 2);

        let unknown = buckets
            .iter()
            .find(|bucket| bucket.client == "claudeCode" && bucket.start_unix == window_start + 300)
            .unwrap();
        assert_eq!(unknown.cache_read_tokens, None);
        assert_eq!(unknown.cache_write_tokens, None);
        assert_eq!(unknown.reasoning_tokens, None);
        assert_eq!(unknown.requests, 1);

        let latest = buckets
            .iter()
            .find(|bucket| bucket.client == "deepseek")
            .unwrap();
        assert_eq!(latest.start_unix, now - 300);
        assert_eq!(latest.input_tokens, 8);
    }

    #[test]
    fn aggregate_cache_hits_unchanged_key_and_invalidates_revision_minute_and_path() {
        let temporary = TempDir::new("aggregate-cache");
        let database = temporary.path().join("multi-client-usage.sqlite");
        let connection = open_database(&database).unwrap();
        ensure_schema(&connection, &database).unwrap();
        let now = 1_800_000_600_i64;
        insert_trend_event(
            &connection,
            "claudeCode",
            "cache-event",
            (now - 10) as f64,
            5,
            2,
            Some(1),
            None,
            None,
        );
        insert_revision(&connection, "claudeCode", "cache-event", (now - 10) as f64);
        connection
            .execute(
                "INSERT INTO multi_usage_metadata(key,value) VALUES('updated_at_ms','1800000000000')",
                [],
            )
            .unwrap();

        let cache = Mutex::new(MultiClientAggregateCache::default());
        let first =
            read_cached_multi_client_aggregates(&connection, &database, now, &cache).unwrap();
        assert_eq!(first.arrays.summaries[0].input_tokens, 5);
        let unchanged =
            read_cached_multi_client_aggregates(&connection, &database, now + 20, &cache).unwrap();
        assert_eq!(unchanged.arrays.summaries[0].input_tokens, 5);
        assert_eq!(cache.lock().unwrap().hits, 1);

        connection
            .execute(
                "UPDATE client_usage_events SET input_tokens=20 WHERE client='claudeCode' AND event_id='cache-event'",
                [],
            )
            .unwrap();
        insert_revision(&connection, "claudeCode", "cache-event", (now + 20) as f64);
        connection
            .execute(
                "UPDATE multi_usage_metadata SET value='1800000060000' WHERE key='updated_at_ms'",
                [],
            )
            .unwrap();
        let revised =
            read_cached_multi_client_aggregates(&connection, &database, now + 30, &cache).unwrap();
        assert_eq!(revised.arrays.summaries[0].input_tokens, 20);
        assert_eq!(revised.updated_at, format_timestamp(1_800_000_060_000));
        assert_eq!(cache.lock().unwrap().hits, 1);

        let revised_hit =
            read_cached_multi_client_aggregates(&connection, &database, now + 40, &cache).unwrap();
        assert_eq!(revised_hit.arrays.summaries[0].input_tokens, 20);
        assert_eq!(cache.lock().unwrap().hits, 2);

        let next_minute =
            read_cached_multi_client_aggregates(&connection, &database, now + 60, &cache).unwrap();
        assert_eq!(next_minute.arrays.summaries[0].input_tokens, 20);
        assert_eq!(cache.lock().unwrap().hits, 2);

        let other_database = temporary.path().join("other.sqlite");
        let other_connection = open_database(&other_database).unwrap();
        ensure_schema(&other_connection, &other_database).unwrap();
        insert_trend_event(
            &other_connection,
            "claudeCode",
            "cache-event",
            (now - 10) as f64,
            7,
            2,
            None,
            None,
            None,
        );
        insert_revision(
            &other_connection,
            "claudeCode",
            "cache-event",
            (now - 10) as f64,
        );
        let other_path = read_cached_multi_client_aggregates(
            &other_connection,
            &other_database,
            now + 60,
            &cache,
        )
        .unwrap();
        assert_eq!(other_path.arrays.summaries[0].input_tokens, 7);
        assert_eq!(cache.lock().unwrap().hits, 2);
    }

    #[test]
    fn scoped_model_summaries_include_cutoff_and_invalidate_for_cutoff_and_revision() {
        let temporary = TempDir::new("scoped-model-summaries");
        let database = temporary.path().join("multi-client-usage.sqlite");
        let connection = open_database(&database).unwrap();
        ensure_schema(&connection, &database).unwrap();

        let now = 1_800_000_000_i64;
        let seven_day_start = now.div_euclid(300) * 300 - 7 * 24 * 60 * 60;
        let today_start =
            crate::core::localtime::local_day_bounds(crate::core::localtime::local_date_at(now))
                .unwrap()
                .0;
        insert_model_summary_event(
            &connection,
            "claudeCode",
            "outside-seven-days",
            "gpt-6.1-sol",
            seven_day_start - 1,
        );
        insert_model_summary_event(
            &connection,
            "claudeCode",
            "at-seven-day-cutoff",
            "gpt-6.1-sol",
            seven_day_start,
        );
        insert_model_summary_event(
            &connection,
            "claudeCode",
            "near-seven-day-edge",
            "gpt-6.1-sol",
            seven_day_start + 100,
        );
        insert_model_summary_event(
            &connection,
            "claudeCode",
            "before-today",
            "gpt-6.1-sol",
            today_start - 1,
        );
        insert_model_summary_event(
            &connection,
            "claudeCode",
            "at-today-cutoff",
            "gpt-6.1-sol",
            today_start,
        );
        insert_model_summary_event(&connection, "claudeCode", "current", "gpt-6.1-sol", now);

        let aggregate_cache = Mutex::new(MultiClientAggregateCache::default());
        let first =
            read_cached_multi_client_aggregates(&connection, &database, now, &aggregate_cache)
                .unwrap();
        let all_time = &first.arrays.summaries[0];
        let seven_days = &first.arrays.seven_day_summaries[0];
        let today = &first.arrays.today_summaries[0];
        assert_eq!(all_time.requests, 6);
        assert_eq!(all_time.api_cost_usd, Some(0.0018));
        assert_eq!(
            seven_days.requests, 5,
            "the exact rolling cutoff is included"
        );
        assert_eq!(seven_days.api_cost_usd, Some(0.0015));
        assert_eq!(
            today.requests, 2,
            "local midnight is included, the prior second is excluded"
        );
        assert_eq!(today.api_cost_usd, Some(0.0006));
        assert!(today.cache_read_complete);
        assert_eq!(today.unpriced_requests, 0);

        let later = read_cached_multi_client_aggregates(
            &connection,
            &database,
            now + 300,
            &aggregate_cache,
        )
        .unwrap();
        assert_eq!(later.arrays.seven_day_summaries[0].requests, 3);
        assert_eq!(
            later.arrays.seven_day_summaries[0].api_cost_usd,
            Some(0.0009)
        );

        insert_model_summary_event(
            &connection,
            "claudeCode",
            "after-revision",
            "gpt-6.1-sol",
            now + 100,
        );
        let revised = read_cached_multi_client_aggregates(
            &connection,
            &database,
            now + 300,
            &aggregate_cache,
        )
        .unwrap();
        assert_eq!(revised.arrays.seven_day_summaries[0].requests, 4);
        assert_eq!(
            revised.arrays.seven_day_summaries[0].api_cost_usd,
            Some(0.0012)
        );
        assert_eq!(revised.arrays.today_summaries[0].requests, 3);
    }

    #[test]
    fn snapshot_serializes_today_and_seven_day_model_summary_arrays_additively() {
        let legacy: MultiClientUsageSnapshot = serde_json::from_value(serde_json::json!({
            "preferences": [],
            "summaries": [],
            "detections": [],
            "trendBuckets": [],
            "dailyBuckets": [],
            "quotas": [],
            "diagnostics": [],
            "updatedAt": null
        }))
        .unwrap();
        assert!(legacy.today_summaries.is_empty());
        assert!(legacy.seven_day_summaries.is_empty());

        let wire = serde_json::to_value(legacy).unwrap();
        assert_eq!(wire["todaySummaries"], serde_json::json!([]));
        assert_eq!(wire["sevenDaySummaries"], serde_json::json!([]));
    }

    #[test]
    fn scoped_summary_cache_is_bounded_and_keeps_recent_cutoffs() {
        let mut cache = MultiClientScopedSummaryCache::default();
        let keys = (0..MAX_SCOPED_SUMMARY_CACHE_ENTRIES + 2)
            .map(|cutoff_unix| MultiClientScopedSummaryCacheKey {
                database_path: PathBuf::from("fixture.sqlite"),
                revision: 1,
                cutoff_unix: cutoff_unix as i64,
            })
            .collect::<Vec<_>>();
        for key in &keys {
            cache.put(key.clone(), Vec::new());
        }
        assert_eq!(cache.entries.len(), MAX_SCOPED_SUMMARY_CACHE_ENTRIES);
        assert!(cache.get(&keys[0]).is_none());
        assert!(cache.get(&keys[2]).is_some());
        cache.put(
            MultiClientScopedSummaryCacheKey {
                database_path: PathBuf::from("fixture.sqlite"),
                revision: 1,
                cutoff_unix: 99,
            },
            Vec::new(),
        );
        assert!(
            cache.get(&keys[2]).is_some(),
            "a hit refreshes the LRU position"
        );
        assert!(cache.get(&keys[3]).is_none());
        assert_eq!(cache.entries.len(), MAX_SCOPED_SUMMARY_CACHE_ENTRIES);
    }

    #[test]
    fn api_cost_prices_each_request_and_keeps_unknowns_explicit() {
        let standard = api_cost_micro_usd("gpt-6.1-sol", 100, 10, Some(0), Some(0));
        assert_eq!(standard, Some(300));

        let small = api_cost_micro_usd("gpt-6.1-sol", 140_000, 0, Some(0), Some(0));
        let long = api_cost_micro_usd("gpt-6.1-sol", 280_000, 0, Some(0), Some(0));
        let mut two_small_requests = MultiClientPriceTally::default();
        two_small_requests.add(small);
        two_small_requests.add(small);
        assert_eq!(two_small_requests.known_cost_micro_usd, Some(560_000));
        assert_eq!(long, Some(1_120_000));

        assert_eq!(
            api_cost_micro_usd("unlisted-provider-model", 100, 10, Some(0), Some(0)),
            None
        );
        assert_eq!(
            api_cost_micro_usd("claude-opus-5-5", 100, 0, Some(0), Some(1)),
            None
        );
        assert_eq!(
            api_cost_micro_usd("gpt-6.1-sol", 100_000_001, 0, Some(0), Some(0)),
            None
        );
        assert_eq!(
            api_cost_micro_usd("glm-4.7-flash", 0, 0, None, None),
            Some(0)
        );
        assert_eq!(
            api_cost_micro_usd("openai/gpt-5.5-2026-04-23", 100, 10, Some(0), Some(0)),
            Some(800)
        );
        assert_eq!(
            api_cost_micro_usd("gpt-6.1-sol-fast", 100, 10, Some(0), Some(0)),
            Some(600)
        );
        assert_eq!(
            api_cost_micro_usd("deepseek-reasoner", 100, 10, Some(0), Some(0)),
            None
        );
        assert_eq!(
            api_cost_micro_usd("gpt-5.5", 1, 0, Some(1), Some(0)),
            Some(1),
            "half-micro-USD per request rounds half-up"
        );

        let mut partial = MultiClientPriceTally::default();
        partial.add(standard);
        partial.add(api_cost_micro_usd("gpt-6.1-sol", 100, 10, None, Some(0)));
        assert_eq!(partial.known_cost_micro_usd, Some(300));
        assert_eq!(partial.unpriced_requests, 1);

        let mut overflow = MultiClientPriceTally {
            known_cost_micro_usd: Some(u128::MAX),
            has_known_request: true,
            ..Default::default()
        };
        overflow.add(Some(1));
        assert!(overflow.overflowed);
        assert_eq!(overflow.known_cost_micro_usd, None);
        overflow.add(Some(1));
        assert_eq!(overflow.known_cost_micro_usd, None);
    }

    #[test]
    fn summary_pricing_fields_are_additive_and_use_the_shared_wire_names() {
        let legacy: MultiClientUsageSummary = serde_json::from_value(serde_json::json!({
            "client": "claudeCode",
            "model": "gpt-6.1-sol",
            "inputTokens": 100,
            "outputTokens": 10,
            "cacheReadTokens": 0,
            "cacheWriteTokens": 0,
            "reasoningTokens": null,
            "requests": 1,
            "lastSeen": null,
            "incompleteFields": false
        }))
        .unwrap();
        assert_eq!(legacy.api_cost_usd, None);
        assert_eq!(legacy.unpriced_requests, 0);
        assert!(!legacy.cache_read_complete);

        let wire = serde_json::to_value(MultiClientUsageSummary {
            api_cost_usd: Some(0.0003),
            unpriced_requests: 1,
            cache_read_complete: true,
            ..legacy
        })
        .unwrap();
        assert_eq!(wire["apiCostUSD"], 0.0003);
        assert_eq!(wire["unpricedRequests"], 1);
        assert_eq!(wire["cacheReadComplete"], true);
        assert!(wire.get("apiCostUsd").is_none());
    }

    #[test]
    fn api_price_aggregate_cache_invalidates_on_revision_and_reports_cache_read_completeness() {
        let temporary = TempDir::new("api-price-cache");
        let database = temporary.path().join("multi-client-usage.sqlite");
        let connection = open_database(&database).unwrap();
        ensure_schema(&connection, &database).unwrap();
        insert_trend_event(
            &connection,
            "claudeCode",
            "known",
            1_800_000_000.0,
            100,
            10,
            Some(0),
            Some(0),
            None,
        );
        insert_trend_event(
            &connection,
            "claudeCode",
            "missing-cache-read",
            1_800_000_001.0,
            100,
            10,
            None,
            Some(0),
            None,
        );
        connection
            .execute(
                "UPDATE client_usage_events SET model='gpt-6.1-sol' WHERE event_id IN ('known','missing-cache-read')",
                [],
            )
            .unwrap();
        insert_revision(&connection, "claudeCode", "known", 1_800_000_000.0);
        insert_revision(
            &connection,
            "claudeCode",
            "missing-cache-read",
            1_800_000_001.0,
        );
        let cache = Mutex::new(MultiClientPriceCache::default());

        let first = read_priced_summaries_for_test(&connection, &database, &cache);
        assert_eq!(first[0].api_cost_usd, Some(0.0003));
        assert_eq!(first[0].unpriced_requests, 1);
        assert!(!first[0].cache_read_complete);
        let unchanged = read_priced_summaries_for_test(&connection, &database, &cache);
        assert_eq!(unchanged[0].api_cost_usd, Some(0.0003));
        assert_eq!(cache.lock().unwrap().hits, 1);

        connection
            .execute(
                "UPDATE client_usage_events SET cache_read_tokens=0 WHERE event_id='missing-cache-read'",
                [],
            )
            .unwrap();
        insert_revision(
            &connection,
            "claudeCode",
            "missing-cache-read",
            1_800_000_002.0,
        );
        let revised = read_priced_summaries_for_test(&connection, &database, &cache);
        assert_eq!(revised[0].api_cost_usd, Some(0.0006));
        assert_eq!(revised[0].unpriced_requests, 0);
        assert!(revised[0].cache_read_complete);
        assert_eq!(cache.lock().unwrap().hits, 1);
    }

    #[test]
    fn daily_trends_use_local_midnights_across_dst_and_keep_all_sources() {
        use time::Month;

        let temporary = TempDir::new("daily-trends");
        let database = temporary.path().join("multi-client-usage.sqlite");
        let connection = open_database(&database).unwrap();
        ensure_schema(&connection, &database).unwrap();

        fn unix(value: &str) -> i64 {
            OffsetDateTime::parse(value, &Rfc3339)
                .unwrap()
                .unix_timestamp()
        }
        let now = unix("2026-03-10T12:00:00Z");
        let today = crate::core::localtime::local_date_at(now);
        let first_day = today - CalendarDuration::days(364);
        let (window_start, _) = crate::core::localtime::local_day_bounds(first_day).unwrap();
        let dst_day = Date::from_calendar_date(2026, Month::March, 8).unwrap();
        let (dst_start, dst_end) = crate::core::localtime::local_day_bounds(dst_day).unwrap();
        let (next_day_start, _) =
            crate::core::localtime::local_day_bounds(dst_day + CalendarDuration::days(1)).unwrap();
        let (today_start, _) = crate::core::localtime::local_day_bounds(today).unwrap();
        assert!((22 * 60 * 60..=26 * 60 * 60).contains(&(dst_end - dst_start)));

        insert_trend_event(
            &connection,
            "claudeCode",
            "before-window",
            (window_start - 1) as f64,
            100,
            100,
            None,
            None,
            None,
        );
        insert_trend_event(
            &connection,
            "claudeCode",
            "at-window",
            window_start as f64,
            10,
            1,
            Some(9),
            Some(8),
            Some(7),
        );
        insert_trend_event(
            &connection,
            "claudeCode",
            "dst-before",
            (dst_start + 60) as f64,
            1,
            10,
            Some(5),
            None,
            None,
        );
        insert_trend_event(
            &connection,
            "claudeCode",
            "dst-after",
            (dst_start + 3_600) as f64,
            2,
            20,
            None,
            Some(2),
            Some(3),
        );
        insert_trend_event(
            &connection,
            "claudeCode",
            "dst-last-second",
            (dst_end - 1) as f64,
            3,
            30,
            Some(7),
            Some(4),
            Some(5),
        );
        insert_trend_event(
            &connection,
            "claudeCode",
            "next-local-day",
            next_day_start as f64,
            4,
            40,
            None,
            None,
            None,
        );
        insert_trend_event(
            &connection,
            "claudeCode",
            "at-upper-bound",
            now as f64,
            5,
            50,
            Some(1),
            Some(2),
            Some(3),
        );
        insert_trend_event(
            &connection,
            "customSource",
            "source-beyond-defaults",
            (now - 1) as f64,
            6,
            60,
            None,
            None,
            None,
        );
        insert_trend_event(
            &connection,
            "claudeCode",
            "future",
            (now + 1) as f64,
            100,
            100,
            None,
            None,
            None,
        );
        insert_trend_event(
            &connection,
            "codex",
            "codex-excluded",
            (now - 1) as f64,
            100,
            100,
            None,
            None,
            None,
        );

        let buckets = read_daily_buckets(&connection, now).unwrap();
        assert_eq!(buckets.len(), 5);
        assert_eq!(
            buckets
                .iter()
                .map(|bucket| bucket.input_tokens + bucket.output_tokens)
                .sum::<u64>(),
            242
        );
        for bucket in &buckets {
            assert_eq!(
                crate::core::localtime::local_day_bounds(crate::core::localtime::local_date_at(
                    bucket.start_unix
                ))
                .unwrap()
                .0,
                bucket.start_unix
            );
        }

        let first = buckets
            .iter()
            .find(|bucket| bucket.client == "claudeCode" && bucket.start_unix == window_start)
            .unwrap();
        assert_eq!(
            (first.input_tokens, first.output_tokens, first.requests),
            (10, 1, 1)
        );
        assert_eq!(
            (
                first.cache_read_tokens,
                first.cache_write_tokens,
                first.reasoning_tokens
            ),
            (Some(9), Some(8), Some(7))
        );

        let dst = buckets
            .iter()
            .find(|bucket| bucket.client == "claudeCode" && bucket.start_unix == dst_start)
            .unwrap();
        assert_eq!(
            (dst.input_tokens, dst.output_tokens, dst.requests),
            (6, 60, 3)
        );
        assert_eq!(
            (
                dst.cache_read_tokens,
                dst.cache_write_tokens,
                dst.reasoning_tokens
            ),
            (Some(12), Some(6), Some(8))
        );

        let next = buckets
            .iter()
            .find(|bucket| bucket.client == "claudeCode" && bucket.start_unix == next_day_start)
            .unwrap();
        assert_eq!(
            (next.input_tokens, next.output_tokens, next.requests),
            (4, 40, 1)
        );
        assert_eq!(
            (
                next.cache_read_tokens,
                next.cache_write_tokens,
                next.reasoning_tokens
            ),
            (None, None, None)
        );

        assert!(buckets
            .iter()
            .any(|bucket| bucket.client == "customSource" && bucket.start_unix == today_start));
        assert!(!buckets.iter().any(|bucket| bucket.client == "codex"));
    }

    fn table_columns(connection: &Connection, table: &str) -> Vec<String> {
        let mut statement = connection
            .prepare(&format!("PRAGMA table_info({table})"))
            .unwrap();
        statement
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap()
    }

    #[test]
    fn tray_lines_only_show_configured_clients_with_recorded_usage() {
        let mut preferences = default_preferences();
        preferences[0].show_menu_bar = true;
        assert!(configured_menu_bar_usage_lines(&preferences, &[]).is_empty());
        let summary = MultiClientUsageSummary {
            client: "claudeCode".into(),
            model: "model-a".into(),
            input_tokens: 100,
            output_tokens: 9,
            cache_read_tokens: Some(40),
            cache_write_tokens: None,
            reasoning_tokens: Some(3),
            requests: 1,
            last_seen: None,
            incomplete_fields: true,
            api_cost_usd: None,
            unpriced_requests: 1,
            cache_read_complete: true,
        };
        assert_eq!(
            configured_menu_bar_usage_lines(&preferences, &[summary]),
            vec!["Claude Code: 100 in · 9 out".to_string()]
        );
    }
}
