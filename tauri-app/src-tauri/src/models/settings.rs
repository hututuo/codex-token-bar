use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettingsSnapshot {
    #[serde(default, alias = "codex_home")]
    pub codex_home: Option<String>,
    #[serde(default)]
    pub custom_account_display_name: String,
    #[serde(default = "default_quota_refresh_interval_ms")]
    pub quota_refresh_interval_ms: u64,
    #[serde(default)]
    pub floating_window: FloatingWindowSettingsSnapshot,
    #[serde(default)]
    pub floating_position: Option<FloatingWindowPositionSnapshot>,
    #[serde(default)]
    pub display_surfaces: DisplaySurfaceSettingsSnapshot,
    #[serde(default)]
    pub setup_guide_completed: bool,
    #[serde(default)]
    pub session_enhancements: SessionEnhancementSettingsSnapshot,
    #[serde(default)]
    pub auto_resume: AutoResumeSettingsSnapshot,
}

impl Default for AppSettingsSnapshot {
    fn default() -> Self {
        Self {
            codex_home: None,
            custom_account_display_name: String::new(),
            quota_refresh_interval_ms: default_quota_refresh_interval_ms(),
            floating_window: FloatingWindowSettingsSnapshot::default(),
            floating_position: None,
            display_surfaces: DisplaySurfaceSettingsSnapshot::default(),
            setup_guide_completed: false,
            session_enhancements: SessionEnhancementSettingsSnapshot::default(),
            auto_resume: AutoResumeSettingsSnapshot::default(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionEnhancementSettingsSnapshot {
    #[serde(default)]
    pub session_delete: bool,
    #[serde(default = "default_enabled")]
    pub markdown_export: bool,
    #[serde(default)]
    pub paste_fix: bool,
    #[serde(default = "default_enabled")]
    pub project_move: bool,
    #[serde(default)]
    pub thread_id_badge: bool,
    #[serde(default)]
    pub conversation_view: bool,
    #[serde(default = "default_conversation_view_max_width")]
    pub conversation_view_max_width: u32,
    #[serde(default = "default_enabled")]
    pub thread_scroll_restore: bool,
}

impl Default for SessionEnhancementSettingsSnapshot {
    fn default() -> Self {
        Self {
            session_delete: false,
            markdown_export: true,
            paste_fix: false,
            project_move: true,
            thread_id_badge: false,
            conversation_view: false,
            conversation_view_max_width: default_conversation_view_max_width(),
            thread_scroll_restore: true,
        }
    }
}

fn default_conversation_view_max_width() -> u32 {
    900
}

pub const AUTO_RESUME_TASK_COLLECTION_VERSION: u8 = 2;

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AutoResumeSettingsSnapshot {
    #[serde(default)]
    pub task_collection_version: u8,
    #[serde(default)]
    pub selected_task_id: String,
    #[serde(default)]
    pub tasks: Vec<AutoResumeTaskSettingsSnapshot>,
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub thread_id: String,
    #[serde(default)]
    pub thread_title: String,
    #[serde(default)]
    pub thread_cwd: String,
    #[serde(default = "default_auto_resume_prompt")]
    pub prompt: String,
    #[serde(default)]
    pub invisible_resume_enabled: Option<bool>,
    #[serde(default)]
    pub auto_approval_enabled: bool,
    #[serde(default = "default_auto_resume_schedule_mode")]
    pub schedule_mode: String,
    #[serde(default = "default_auto_resume_interval_minutes")]
    pub interval_minutes: u32,
    #[serde(default = "default_auto_resume_daily_hour")]
    pub daily_hour: u8,
    #[serde(default)]
    pub daily_minute: u8,
    #[serde(default)]
    pub failure_recovery_policy_version: u8,
    #[serde(default)]
    pub failure_recovery_reasons: Vec<String>,
    #[serde(default)]
    pub capacity_recovery_enabled: bool,
    #[serde(default = "default_enabled")]
    pub quota_resume_enabled: bool,
    #[serde(default = "default_auto_resume_quota_window")]
    pub quota_window: String,
    #[serde(default = "default_auto_resume_low_threshold")]
    pub quota_low_threshold_percent: u8,
    #[serde(default = "default_auto_resume_recovery_threshold")]
    pub quota_recovery_threshold_percent: u8,
    #[serde(default = "default_auto_resume_cooldown_minutes")]
    pub cooldown_minutes: u32,
    #[serde(default = "default_auto_resume_max_runs_per_day")]
    pub max_runs_per_day: u8,
    #[serde(default = "default_enabled")]
    pub notify_on_result: bool,
}

impl Default for AutoResumeSettingsSnapshot {
    fn default() -> Self {
        Self {
            task_collection_version: 0,
            selected_task_id: String::new(),
            tasks: Vec::new(),
            enabled: false,
            thread_id: String::new(),
            thread_title: String::new(),
            thread_cwd: String::new(),
            prompt: default_auto_resume_prompt(),
            invisible_resume_enabled: Some(true),
            auto_approval_enabled: false,
            schedule_mode: default_auto_resume_schedule_mode(),
            interval_minutes: default_auto_resume_interval_minutes(),
            daily_hour: default_auto_resume_daily_hour(),
            daily_minute: 0,
            failure_recovery_policy_version: 0,
            failure_recovery_reasons: Vec::new(),
            capacity_recovery_enabled: false,
            quota_resume_enabled: true,
            quota_window: default_auto_resume_quota_window(),
            quota_low_threshold_percent: default_auto_resume_low_threshold(),
            quota_recovery_threshold_percent: default_auto_resume_recovery_threshold(),
            cooldown_minutes: default_auto_resume_cooldown_minutes(),
            max_runs_per_day: default_auto_resume_max_runs_per_day(),
            notify_on_result: true,
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AutoResumeTaskSettingsSnapshot {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub created_at: i64,
    #[serde(default)]
    pub updated_at: i64,
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub thread_id: String,
    #[serde(default)]
    pub thread_title: String,
    #[serde(default)]
    pub thread_cwd: String,
    #[serde(default = "default_auto_resume_prompt")]
    pub prompt: String,
    #[serde(default)]
    pub invisible_resume_enabled: Option<bool>,
    #[serde(default)]
    pub auto_approval_enabled: bool,
    #[serde(default = "default_auto_resume_schedule_mode")]
    pub schedule_mode: String,
    #[serde(default = "default_auto_resume_interval_minutes")]
    pub interval_minutes: u32,
    #[serde(default = "default_auto_resume_daily_hour")]
    pub daily_hour: u8,
    #[serde(default)]
    pub daily_minute: u8,
    #[serde(default)]
    pub failure_recovery_policy_version: u8,
    #[serde(default)]
    pub failure_recovery_reasons: Vec<String>,
    #[serde(default)]
    pub capacity_recovery_enabled: bool,
    #[serde(default = "default_enabled")]
    pub quota_resume_enabled: bool,
    #[serde(default = "default_auto_resume_quota_window")]
    pub quota_window: String,
    #[serde(default = "default_auto_resume_low_threshold")]
    pub quota_low_threshold_percent: u8,
    #[serde(default = "default_auto_resume_recovery_threshold")]
    pub quota_recovery_threshold_percent: u8,
    #[serde(default = "default_auto_resume_cooldown_minutes")]
    pub cooldown_minutes: u32,
    #[serde(default = "default_auto_resume_max_runs_per_day")]
    pub max_runs_per_day: u8,
    #[serde(default = "default_enabled")]
    pub notify_on_result: bool,
}

impl Default for AutoResumeTaskSettingsSnapshot {
    fn default() -> Self {
        Self {
            id: String::new(),
            created_at: 0,
            updated_at: 0,
            enabled: false,
            thread_id: String::new(),
            thread_title: String::new(),
            thread_cwd: String::new(),
            prompt: default_auto_resume_prompt(),
            invisible_resume_enabled: Some(true),
            auto_approval_enabled: false,
            schedule_mode: default_auto_resume_schedule_mode(),
            interval_minutes: default_auto_resume_interval_minutes(),
            daily_hour: default_auto_resume_daily_hour(),
            daily_minute: 0,
            failure_recovery_policy_version: 0,
            failure_recovery_reasons: Vec::new(),
            capacity_recovery_enabled: false,
            quota_resume_enabled: true,
            quota_window: default_auto_resume_quota_window(),
            quota_low_threshold_percent: default_auto_resume_low_threshold(),
            quota_recovery_threshold_percent: default_auto_resume_recovery_threshold(),
            cooldown_minutes: default_auto_resume_cooldown_minutes(),
            max_runs_per_day: default_auto_resume_max_runs_per_day(),
            notify_on_result: true,
        }
    }
}

impl AutoResumeTaskSettingsSnapshot {
    pub fn as_legacy_settings(&self) -> AutoResumeSettingsSnapshot {
        AutoResumeSettingsSnapshot {
            task_collection_version: 0,
            selected_task_id: self.id.clone(),
            tasks: Vec::new(),
            enabled: self.enabled,
            thread_id: self.thread_id.clone(),
            thread_title: self.thread_title.clone(),
            thread_cwd: self.thread_cwd.clone(),
            prompt: self.prompt.clone(),
            invisible_resume_enabled: self.invisible_resume_enabled,
            auto_approval_enabled: self.auto_approval_enabled,
            schedule_mode: self.schedule_mode.clone(),
            interval_minutes: self.interval_minutes,
            daily_hour: self.daily_hour,
            daily_minute: self.daily_minute,
            failure_recovery_policy_version: self.failure_recovery_policy_version,
            failure_recovery_reasons: self.failure_recovery_reasons.clone(),
            capacity_recovery_enabled: self.capacity_recovery_enabled,
            quota_resume_enabled: self.quota_resume_enabled,
            quota_window: self.quota_window.clone(),
            quota_low_threshold_percent: self.quota_low_threshold_percent,
            quota_recovery_threshold_percent: self.quota_recovery_threshold_percent,
            cooldown_minutes: self.cooldown_minutes,
            max_runs_per_day: self.max_runs_per_day,
            notify_on_result: self.notify_on_result,
        }
    }
}

impl AutoResumeSettingsSnapshot {
    pub fn resolved_tasks(&self) -> Vec<AutoResumeTaskSettingsSnapshot> {
        if self.task_collection_version >= AUTO_RESUME_TASK_COLLECTION_VERSION
            || !self.tasks.is_empty()
        {
            return self.tasks.clone();
        }
        if self.thread_id.trim().is_empty() {
            return Vec::new();
        }
        vec![AutoResumeTaskSettingsSnapshot {
            id: legacy_auto_resume_task_id(&self.thread_id),
            created_at: 0,
            updated_at: 0,
            enabled: self.enabled,
            thread_id: self.thread_id.clone(),
            thread_title: self.thread_title.clone(),
            thread_cwd: self.thread_cwd.clone(),
            prompt: self.prompt.clone(),
            invisible_resume_enabled: self.invisible_resume_enabled,
            auto_approval_enabled: self.auto_approval_enabled,
            schedule_mode: self.schedule_mode.clone(),
            interval_minutes: self.interval_minutes,
            daily_hour: self.daily_hour,
            daily_minute: self.daily_minute,
            failure_recovery_policy_version: self.failure_recovery_policy_version,
            failure_recovery_reasons: self.failure_recovery_reasons.clone(),
            capacity_recovery_enabled: self.capacity_recovery_enabled,
            quota_resume_enabled: self.quota_resume_enabled,
            quota_window: self.quota_window.clone(),
            quota_low_threshold_percent: self.quota_low_threshold_percent,
            quota_recovery_threshold_percent: self.quota_recovery_threshold_percent,
            cooldown_minutes: self.cooldown_minutes,
            max_runs_per_day: self.max_runs_per_day,
            notify_on_result: self.notify_on_result,
        }]
    }
}

fn legacy_auto_resume_task_id(thread_id: &str) -> String {
    let mut hash = 14_695_981_039_346_656_037_u64;
    for byte in thread_id.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(1_099_511_628_211);
    }
    format!("legacy-{hash:016x}")
}

fn default_auto_resume_prompt() -> String {
    "继续".into()
}

fn default_auto_resume_schedule_mode() -> String {
    "off".into()
}

fn default_auto_resume_interval_minutes() -> u32 {
    60
}

fn default_auto_resume_daily_hour() -> u8 {
    9
}

fn default_auto_resume_quota_window() -> String {
    "either".into()
}

fn default_auto_resume_low_threshold() -> u8 {
    5
}

fn default_auto_resume_recovery_threshold() -> u8 {
    20
}

fn default_auto_resume_cooldown_minutes() -> u32 {
    30
}

fn default_auto_resume_max_runs_per_day() -> u8 {
    6
}

pub fn default_quota_refresh_interval_ms() -> u64 {
    60_000
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FloatingWindowSettingsSnapshot {
    #[serde(default = "default_floating_opacity")]
    pub opacity: f64,
    #[serde(default = "default_floating_scale")]
    pub scale: f64,
    #[serde(default = "default_token_rate_full_scale")]
    pub token_rate_full_scale: f64,
    #[serde(default = "default_floating_unread_effect")]
    pub unread_effect: String,
    #[serde(default = "default_floating_gradient_start")]
    pub gradient_start: String,
    #[serde(default = "default_floating_gradient_end")]
    pub gradient_end: String,
    #[serde(default = "default_floating_gradient_direction")]
    pub gradient_direction: String,
    #[serde(default = "default_floating_gradient_type")]
    pub gradient_type: String,
    #[serde(default = "default_floating_quota_color_mode")]
    pub quota_color_mode: String,
    #[serde(default = "default_floating_quota_fixed_color")]
    pub quota_fixed_color: String,
    #[serde(default = "default_floating_text_tone")]
    pub text_tone: f64,
    #[serde(default)]
    pub content_visibility: FloatingContentVisibilitySnapshot,
}

impl Default for FloatingWindowSettingsSnapshot {
    fn default() -> Self {
        Self {
            opacity: default_floating_opacity(),
            scale: default_floating_scale(),
            token_rate_full_scale: default_token_rate_full_scale(),
            unread_effect: default_floating_unread_effect(),
            gradient_start: default_floating_gradient_start(),
            gradient_end: default_floating_gradient_end(),
            gradient_direction: default_floating_gradient_direction(),
            gradient_type: default_floating_gradient_type(),
            quota_color_mode: default_floating_quota_color_mode(),
            quota_fixed_color: default_floating_quota_fixed_color(),
            text_tone: default_floating_text_tone(),
            content_visibility: FloatingContentVisibilitySnapshot::default(),
        }
    }
}

fn default_floating_opacity() -> f64 {
    0.92
}

fn default_floating_scale() -> f64 {
    1.0
}

fn default_token_rate_full_scale() -> f64 {
    200.0
}

fn default_floating_unread_effect() -> String {
    "ripple".into()
}

fn default_floating_gradient_start() -> String {
    "#ffffff".into()
}

fn default_floating_gradient_end() -> String {
    "#daefff".into()
}

fn default_floating_gradient_direction() -> String {
    "135deg".into()
}

fn default_floating_gradient_type() -> String {
    "linear".into()
}

fn default_floating_quota_color_mode() -> String {
    "adaptive".into()
}

fn default_floating_quota_fixed_color() -> String {
    "#1469cc".into()
}

fn default_floating_text_tone() -> f64 {
    -1.0
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FloatingContentVisibilitySnapshot {
    #[serde(default = "default_enabled")]
    pub show_rate_and_bar: bool,
    #[serde(default = "default_enabled")]
    pub show_usage_status: bool,
    #[serde(default = "default_enabled")]
    pub show_metrics: bool,
    #[serde(default = "default_enabled")]
    pub show_running_threads: bool,
    #[serde(default = "default_enabled")]
    pub show_today_model_share: bool,
    #[serde(default = "default_enabled")]
    pub show_today_model_cost: bool,
    #[serde(default = "default_enabled")]
    pub show_quota: bool,
    #[serde(default = "default_enabled")]
    pub show_radar: bool,
    #[serde(default = "default_enabled")]
    pub show_crowd_radar: bool,
    #[serde(default = "default_floating_content_order")]
    pub order: Vec<String>,
    #[serde(default = "default_floating_page_pairs")]
    pub page_pairs: Vec<Vec<String>>,
}

impl Default for FloatingContentVisibilitySnapshot {
    fn default() -> Self {
        Self {
            show_rate_and_bar: default_enabled(),
            show_usage_status: default_enabled(),
            show_metrics: default_enabled(),
            show_running_threads: default_enabled(),
            show_today_model_share: default_enabled(),
            show_today_model_cost: default_enabled(),
            show_quota: default_enabled(),
            show_radar: default_enabled(),
            show_crowd_radar: default_enabled(),
            order: default_floating_content_order(),
            page_pairs: default_floating_page_pairs(),
        }
    }
}

fn default_floating_content_order() -> Vec<String> {
    [
        "rateAndBar",
        "usageStatus",
        "metrics",
        "runningThreads",
        "todayModelShare",
        "todayModelCost",
        "radar",
        "crowdRadar",
        "quota",
    ]
    .into_iter()
    .map(String::from)
    .collect()
}

fn default_floating_page_pairs() -> Vec<Vec<String>> {
    vec![vec!["todayModelShare".into(), "todayModelCost".into()]]
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FloatingWindowPositionSnapshot {
    pub x: f64,
    pub y: f64,
    pub saved_at: Option<i64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplaySurfaceSettingsSnapshot {
    #[serde(default = "default_enabled")]
    pub floating_window_enabled: bool,
    #[serde(default = "default_enabled")]
    pub live_rate_enabled: bool,
    #[serde(default = "default_enabled")]
    pub status_tray_live_text_enabled: bool,
    #[serde(default = "default_status_metric_order")]
    pub status_metric_order: Vec<String>,
    #[serde(default = "default_status_metric_label_style")]
    pub status_metric_label_style: String,
    #[serde(default = "default_status_summary_order")]
    pub status_summary_order: Vec<String>,
}

impl Default for DisplaySurfaceSettingsSnapshot {
    fn default() -> Self {
        Self {
            floating_window_enabled: default_enabled(),
            live_rate_enabled: default_enabled(),
            status_tray_live_text_enabled: default_enabled(),
            status_metric_order: default_status_metric_order(),
            status_metric_label_style: default_status_metric_label_style(),
            status_summary_order: default_status_summary_order(),
        }
    }
}

pub const STATUS_METRIC_IDS: [&str; 9] = [
    "rate", "fiveHour", "sevenDay", "iq", "today", "total", "requests", "running", "unread",
];

pub fn default_status_metric_order() -> Vec<String> {
    ["rate", "fiveHour", "sevenDay", "iq"]
        .into_iter()
        .map(String::from)
        .collect()
}

pub fn default_status_metric_label_style() -> String {
    "compact".into()
}

pub const STATUS_SUMMARY_SECTION_IDS: [&str; 7] = [
    "overview",
    "usage",
    "quota",
    "running",
    "unread",
    "radar",
    "crowdRadar",
];

pub fn default_status_summary_order() -> Vec<String> {
    STATUS_SUMMARY_SECTION_IDS
        .into_iter()
        .map(String::from)
        .collect()
}

fn default_enabled() -> bool {
    true
}
