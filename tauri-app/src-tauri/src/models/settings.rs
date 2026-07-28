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
    #[serde(default = "default_enabled")]
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
            session_delete: true,
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

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AutoResumeSettingsSnapshot {
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
    #[serde(default = "default_auto_resume_schedule_mode")]
    pub schedule_mode: String,
    #[serde(default = "default_auto_resume_interval_minutes")]
    pub interval_minutes: u32,
    #[serde(default = "default_auto_resume_daily_hour")]
    pub daily_hour: u8,
    #[serde(default)]
    pub daily_minute: u8,
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
            enabled: false,
            thread_id: String::new(),
            thread_title: String::new(),
            thread_cwd: String::new(),
            prompt: default_auto_resume_prompt(),
            schedule_mode: default_auto_resume_schedule_mode(),
            interval_minutes: default_auto_resume_interval_minutes(),
            daily_hour: default_auto_resume_daily_hour(),
            daily_minute: 0,
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
    pub show_quota: bool,
    #[serde(default = "default_enabled")]
    pub show_radar: bool,
    #[serde(default = "default_enabled")]
    pub show_crowd_radar: bool,
    #[serde(default = "default_floating_content_order")]
    pub order: Vec<String>,
}

impl Default for FloatingContentVisibilitySnapshot {
    fn default() -> Self {
        Self {
            show_rate_and_bar: default_enabled(),
            show_usage_status: default_enabled(),
            show_metrics: default_enabled(),
            show_running_threads: default_enabled(),
            show_quota: default_enabled(),
            show_radar: default_enabled(),
            show_crowd_radar: default_enabled(),
            order: default_floating_content_order(),
        }
    }
}

fn default_floating_content_order() -> Vec<String> {
    [
        "rateAndBar",
        "usageStatus",
        "metrics",
        "runningThreads",
        "radar",
        "crowdRadar",
        "quota",
    ]
        .into_iter()
        .map(String::from)
        .collect()
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
}

impl Default for DisplaySurfaceSettingsSnapshot {
    fn default() -> Self {
        Self {
            floating_window_enabled: default_enabled(),
            live_rate_enabled: default_enabled(),
            status_tray_live_text_enabled: default_enabled(),
        }
    }
}

fn default_enabled() -> bool {
    true
}
