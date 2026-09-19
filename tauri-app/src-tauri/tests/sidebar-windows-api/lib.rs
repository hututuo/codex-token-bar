#![cfg(windows)]
#![allow(dead_code)]
// Only the app-owned frame DTO is supplied here. Tauri, WebView2 and Win32 APIs
// are real dependencies; the production adapter is included without changes.
#[derive(Clone, Copy)]
pub struct SidebarFrame { pub x: f64, pub y: f64, pub width: f64, pub height: f64 }
#[path = "../../src/platform/quota_sidebar/canvas_geometry.rs"]
mod canvas_geometry;
#[path = "../../src/platform/quota_sidebar/canvas_windows.rs"]
mod canvas_windows;
