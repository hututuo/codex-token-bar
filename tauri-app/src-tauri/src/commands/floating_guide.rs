//! Temporary, local-only overlay windows for the real floating-window tutorial.
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{Emitter, Manager, WebviewUrl, WebviewWindowBuilder};
use super::window_auth::require_window_label;
use super::surface::{FloatingDockFrame, apply_floating_dock_frame};
const CARD: &str = "floating-guide-card";
const CURSOR: &str = "floating-guide-cursor";
static CARD_READY: AtomicBool = AtomicBool::new(false);
static CURSOR_READY: AtomicBool = AtomicBool::new(false);

#[derive(Clone, Copy, serde::Deserialize)]
pub struct GuidePoint { pub x: f64, pub y: f64 }
impl GuidePoint {
    fn validate(self) -> Result<Self, String> {
        if !self.x.is_finite() || !self.y.is_finite() || self.x.abs() > i32::MAX as f64 || self.y.abs() > i32::MAX as f64 { return Err("Invalid guide coordinate".into()); }
        Ok(self)
    }
}
#[derive(Clone, serde::Deserialize, serde::Serialize)]
pub struct GuideMessage { pub step: u8, pub title: String, pub detail: String, pub finished: bool }
#[derive(Clone, serde::Serialize)]
struct GuideUpdate { message: Option<GuideMessage>, pressed: Option<bool> }

#[tauri::command]
pub async fn prepare_floating_guide_overlay(window: tauri::WebviewWindow, app: tauri::AppHandle) -> Result<(), String> {
    require_window_label(&window, "prepare_floating_guide_overlay")?;
    for (label, width, height) in [(CARD, 286.0, 100.0), (CURSOR, 54.0, 65.0)] {
        if app.get_webview_window(label).is_some() { continue; }
        if label == CARD { CARD_READY.store(false, Ordering::SeqCst); } else { CURSOR_READY.store(false, Ordering::SeqCst); }
        let overlay = WebviewWindowBuilder::new(&app, label, WebviewUrl::App(format!("index.html?surface={label}").into()))
            .title("悬浮窗使用指南").inner_size(width, height).decorations(false).transparent(true)
            .resizable(false).visible_on_all_workspaces(true).always_on_top(true).skip_taskbar(true).visible(false).focused(false)
            .shadow(label == CARD).build().map_err(|e| e.to_string())?;
        if label == CURSOR { overlay.set_ignore_cursor_events(true).map_err(|e| e.to_string())?; }
    }
    Ok(())
}
#[tauri::command]
pub fn floating_guide_overlay_ready(window: tauri::WebviewWindow) -> Result<bool, String> {
    require_window_label(&window, "floating_guide_overlay_ready")?;
    Ok(CARD_READY.load(Ordering::SeqCst) && CURSOR_READY.load(Ordering::SeqCst))
}
#[tauri::command]
pub fn floating_guide_overlay_event(window: tauri::WebviewWindow, app: tauri::AppHandle, action: String) -> Result<(), String> {
    match (window.label(), action.as_str()) {
        (CARD, "ready") => CARD_READY.store(true, Ordering::SeqCst),
        (CURSOR, "ready") => CURSOR_READY.store(true, Ordering::SeqCst),
        (CARD, "replay" | "finish") => app.emit_to("floating", "floating-guide-action", action).map_err(|e| e.to_string())?,
        _ => return Err("Guide overlay action is not allowed for this window".into()),
    }
    Ok(())
}

#[tauri::command]
pub async fn update_floating_guide_overlay(
    window: tauri::WebviewWindow, app: tauri::AppHandle,
    cursor: Option<GuidePoint>, card: Option<GuidePoint>, frame: Option<FloatingDockFrame>,
    message: Option<GuideMessage>, pressed: Option<bool>, visible: Option<bool>, close: Option<bool>,
) -> Result<(), String> {
    require_window_label(&window, "update_floating_guide_overlay")?;
    if close == Some(true) {
        for label in [CARD, CURSOR] { if let Some(overlay) = app.get_webview_window(label) { overlay.close().map_err(|e| e.to_string())?; } }
        CARD_READY.store(false, Ordering::SeqCst); CURSOR_READY.store(false, Ordering::SeqCst);
        return Ok(());
    }
    let cursor = cursor.map(GuidePoint::validate).transpose()?;
    let card = card.map(GuidePoint::validate).transpose()?;
    let frame = frame.map(FloatingDockFrame::validate).transpose()?;
    let cursor_window = app.get_webview_window(CURSOR).ok_or("Guide cursor is unavailable")?;
    let card_window = app.get_webview_window(CARD).ok_or("Guide card is unavailable")?;
    if message.is_some() || pressed.is_some() {
        let update = GuideUpdate { message, pressed };
        app.emit_to(CARD, "floating-guide-update", update.clone()).map_err(|e| e.to_string())?;
        app.emit_to(CURSOR, "floating-guide-update", update).map_err(|e| e.to_string())?;
    }
    #[cfg(target_os = "macos")]
    {
        let (sender, receiver) = tokio::sync::oneshot::channel();
        let native = window.clone();
        let target_scale = window.scale_factor().map_err(|e| e.to_string())?;
        window.with_webview(move |webview| {
            let result = (|| {
                if let Some(frame) = frame { apply_floating_dock_frame(&native, frame, None, webview.inner())?; }
                if let Some(point) = cursor { position_overlay(&cursor_window, point, target_scale)?; }
                if let Some(point) = card { position_overlay(&card_window, point, target_scale)?; }
                if let Some(visible) = visible {
                    if visible {
                        configure_overlay(&card_window, &native)?;
                        configure_overlay(&cursor_window, &native)?;
                        card_window.show().map_err(|e| e.to_string())?; cursor_window.show().map_err(|e| e.to_string())?;
                    }
                    else { cursor_window.hide().map_err(|e| e.to_string())?; }
                }
                Ok::<(), String>(())
            })();
            let _ = sender.send(result);
        }).map_err(|e| e.to_string())?;
        receiver.await.map_err(|_| "Guide update cancelled".to_string())??;
    }
    #[cfg(not(target_os = "macos"))]
    {
        if let Some(frame) = frame { apply_floating_dock_frame(&window, frame)?; }
        if let Some(point) = cursor { cursor_window.set_position(tauri::PhysicalPosition::new(point.x as i32, point.y as i32)).map_err(|e| e.to_string())?; }
        if let Some(point) = card { card_window.set_position(tauri::PhysicalPosition::new(point.x as i32, point.y as i32)).map_err(|e| e.to_string())?; }
        if let Some(visible) = visible {
            if visible { card_window.show().map_err(|e| e.to_string())?; cursor_window.show().map_err(|e| e.to_string())?; }
            else { cursor_window.hide().map_err(|e| e.to_string())?; }
        }
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn position_overlay(window: &tauri::WebviewWindow, point: GuidePoint, scale: f64) -> Result<(), String> {
    use objc2_app_kit::NSWindow;
    use objc2_foundation::NSPoint;
    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" { fn CGMainDisplayID() -> u32; fn CGDisplayPixelsHigh(display: u32) -> usize; }
    let raw = window.ns_window().map_err(|e| e.to_string())?;
    if raw.is_null() { return Err("Guide overlay native window unavailable".into()); }
    let native = unsafe { &*raw.cast::<NSWindow>() };
    let height = unsafe { CGDisplayPixelsHigh(CGMainDisplayID()) } as f64;
    native.setFrameOrigin(NSPoint::new(point.x / scale, height - point.y / scale - native.frame().size.height));
    Ok(())
}

#[cfg(target_os = "macos")]
fn configure_overlay(window: &tauri::WebviewWindow, parent: &tauri::WebviewWindow) -> Result<(), String> {
    use objc2_app_kit::{NSWindow, NSWindowCollectionBehavior};
    let raw = window.ns_window().map_err(|e| e.to_string())?;
    let parent_raw = parent.ns_window().map_err(|e| e.to_string())?;
    if raw.is_null() || parent_raw.is_null() { return Err("Guide native window unavailable".into()); }
    let native = unsafe { &*raw.cast::<NSWindow>() };
    let parent = unsafe { &*parent_raw.cast::<NSWindow>() };
    native.setLevel(parent.level() + 2);
    native.setCollectionBehavior(NSWindowCollectionBehavior::CanJoinAllSpaces | NSWindowCollectionBehavior::FullScreenAuxiliary);
    Ok(())
}
