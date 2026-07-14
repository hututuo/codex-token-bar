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
        }
    }
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
    pub show_quota: bool,
    #[serde(default = "default_enabled")]
    pub show_radar: bool,
    #[serde(default = "default_floating_content_order")]
    pub order: Vec<String>,
}

impl Default for FloatingContentVisibilitySnapshot {
    fn default() -> Self {
        Self {
            show_rate_and_bar: default_enabled(),
            show_usage_status: default_enabled(),
            show_metrics: default_enabled(),
            show_quota: default_enabled(),
            show_radar: default_enabled(),
            order: default_floating_content_order(),
        }
    }
}

fn default_floating_content_order() -> Vec<String> {
    ["rateAndBar", "usageStatus", "metrics", "radar", "quota"]
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
