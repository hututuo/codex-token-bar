use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettingsSnapshot {
    #[serde(default, alias = "codex_home")]
    pub codex_home: Option<String>,
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
            floating_window: FloatingWindowSettingsSnapshot::default(),
            floating_position: None,
            display_surfaces: DisplaySurfaceSettingsSnapshot::default(),
            setup_guide_completed: false,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FloatingWindowSettingsSnapshot {
    #[serde(default = "default_floating_opacity")]
    pub opacity: f64,
    #[serde(default = "default_floating_scale")]
    pub scale: f64,
    #[serde(default = "default_floating_unread_effect")]
    pub unread_effect: String,
}

impl Default for FloatingWindowSettingsSnapshot {
    fn default() -> Self {
        Self {
            opacity: default_floating_opacity(),
            scale: default_floating_scale(),
            unread_effect: default_floating_unread_effect(),
        }
    }
}

fn default_floating_opacity() -> f64 {
    0.92
}

fn default_floating_scale() -> f64 {
    1.0
}

fn default_floating_unread_effect() -> String {
    "ripple".into()
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
    pub status_tray_live_text_enabled: bool,
}

impl Default for DisplaySurfaceSettingsSnapshot {
    fn default() -> Self {
        Self {
            floating_window_enabled: default_enabled(),
            status_tray_live_text_enabled: default_enabled(),
        }
    }
}

fn default_enabled() -> bool {
    true
}
