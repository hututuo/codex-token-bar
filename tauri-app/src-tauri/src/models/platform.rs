use serde::Serialize;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexHomeStatus {
    pub path: String,
    pub exists: bool,
    pub source: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformCapabilities {
    pub platform: String,
    pub shell: String,
    pub floating_window: PlatformFeatureCapability,
    pub floating_transparency: PlatformFeatureCapability,
    pub floating_drag: PlatformFeatureCapability,
    pub floating_lock: PlatformFeatureCapability,
    pub status_tray: PlatformFeatureCapability,
    pub status_tray_live_text: PlatformFeatureCapability,
    pub autostart: PlatformFeatureCapability,
    pub notifications: PlatformFeatureCapability,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformFeatureCapability {
    pub available: bool,
    pub status: String,
    pub label: String,
    pub note: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AutostartStatus {
    pub available: bool,
    pub enabled: bool,
    pub status: String,
    pub message: String,
}
