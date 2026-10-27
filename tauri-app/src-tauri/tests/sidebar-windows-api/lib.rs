#![cfg(windows)]
#![allow(dead_code)]
// Only the app-owned frame DTO is supplied here. Tauri, WebView2, Win32 APIs,
// and the production logical canvas metrics are real; production adapters are
// included without changes.
#[derive(Clone, Copy)]
pub struct SidebarFrame { pub x: f64, pub y: f64, pub width: f64, pub height: f64 }
#[path = "../../src/platform/quota_sidebar/canvas_metrics.rs"]
mod canvas_metrics;
use canvas_metrics::SIDEBAR_CANVAS_HEIGHT;
#[path = "../../src/platform/quota_sidebar/canvas_geometry.rs"]
mod canvas_geometry;
#[path = "../../src/platform/quota_sidebar/canvas_windows.rs"]
mod canvas_windows;
