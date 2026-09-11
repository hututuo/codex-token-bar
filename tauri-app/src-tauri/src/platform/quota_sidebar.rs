//! Two passive edge windows: the input frames equal the rail and detail card.
use crate::models::DisplaySurfaceSettingsSnapshot;
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::{Emitter, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

mod placement;
mod motion;
#[cfg(target_os = "macos")]
mod canvas_macos;
use placement::apply_frames;

const LABEL: &str = "quota-sidebar";
const DETAIL: &str = "quota-sidebar-detail";
static STATE: Mutex<Option<(DisplaySurfaceSettingsSnapshot, SidebarMode, bool)>> = Mutex::new(None);

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SidebarMode { Rest, Hover, Detail }
#[derive(Clone, Copy, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SidebarFrame { pub x: f64, pub y: f64, pub width: f64, pub height: f64 }

/// Workarea and returned frames use one coordinate system. Vertical changes
/// stay centered; animation derives each real native frame from these anchors.
#[cfg(test)]
fn frames_for(work: SidebarFrame, side: &str, mode: SidebarMode, shows_five_hour: bool) -> (SidebarFrame, SidebarFrame) {
    frames_for_at(work, side, mode, shows_five_hour, 0.5)
}
fn frames_for_at(work: SidebarFrame, side: &str, mode: SidebarMode, shows_five_hour: bool, center_y: f64) -> (SidebarFrame, SidebarFrame) {
    let center = work.y + work.height * center_y.clamp(0.0, 1.0);
    let (rail_width, rail_height): (f64, f64) = match (mode, shows_five_hour) {
        (SidebarMode::Rest, true) => (16.0, 250.0),
        (SidebarMode::Rest, false) => (16.0, 192.0),
        (_, true) => (88.0, 560.0),
        (_, false) => (88.0, 470.0),
    };
    let width = rail_width.min(work.width.max(1.0));
    let height = rail_height.min(work.height.max(1.0));
    let rail = SidebarFrame { x: if side == "left" { work.x } else { work.x + work.width - width },
        y: (center - height / 2.0).clamp(work.y, work.y + work.height - height), width, height };
    let gap = 16.0_f64.min((work.width - width).max(0.0));
    let detail_width = 420.0_f64.min((work.width - width - gap).max(1.0));
    let detail_height = 600.0_f64.min(work.height.max(1.0));
    let detail = SidebarFrame { x: if side == "left" { (rail.x + width + gap).min(work.x + work.width - detail_width) }
        else { (rail.x - gap - detail_width).max(work.x) },
        y: (center - detail_height / 2.0).clamp(work.y, work.y + work.height - detail_height), width: detail_width, height: detail_height };
    (rail, detail)
}

pub async fn sync_quota_sidebar(app: &tauri::AppHandle, display: &DisplaySurfaceSettingsSnapshot) -> Result<(), String> {
    let app_copy = app.clone();
    let display = display.clone();
    let (send, receive) = tokio::sync::oneshot::channel();
    app.run_on_main_thread(move || { let _ = send.send(sync_on_main(&app_copy, &display)); }).map_err(|e| e.to_string())?;
    receive.await.map_err(|_| "Quota sidebar setup cancelled".to_string())?
}

fn create_window(app: &tauri::AppHandle, label: &str) -> Result<WebviewWindow, String> {
    if let Some(window) = app.get_webview_window(label) { return Ok(window); }
    let window = WebviewWindowBuilder::new(app, label, WebviewUrl::App(format!("/index.html?surface={label}").into()))
        .title(if label == LABEL { "额度侧栏" } else { "额度详情" })
        .inner_size(if label == LABEL { 16.0 } else { 420.0 }, if label == LABEL { 192.0 } else { 600.0 })
        .min_inner_size(1.0, 1.0).resizable(false).decorations(false).transparent(true).shadow(false)
        .always_on_top(true).visible_on_all_workspaces(true).skip_taskbar(true)
        .focused(false).focusable(false).accept_first_mouse(true).visible(false).build().map_err(|e| e.to_string())?;
    #[cfg(target_os = "macos")]
    { configure_macos(&window)?; super::floating_hover_macos::install(&window)?; }
    if label == LABEL {
        #[cfg(target_os = "macos")]
        <WebviewWindow as AsRef<tauri::Webview>>::as_ref(&window).set_auto_resize(false).map_err(|error| error.to_string())?;
        let watched = window.clone();
        window.on_window_event(move |event| {
            if matches!(event, tauri::WindowEvent::ScaleFactorChanged { .. }) {
                let _ = watched.emit("quota-sidebar-environment-changed", ());
            }
        });
    }
    Ok(window)
}

fn sync_on_main(app: &tauri::AppHandle, display: &DisplaySurfaceSettingsSnapshot) -> Result<(), String> {
    let (mode, shows_five_hour) = {
        let mut state = STATE.lock().map_err(|e| e.to_string())?;
        if !display.quota_sidebar_enabled || state.as_ref().is_some_and(|(old, _, _)| old.quota_sidebar_side != display.quota_sidebar_side) { placement::cancel(); }
        let mode = if display.quota_sidebar_enabled { state.as_ref().map(|(_, mode, _)| *mode).unwrap_or(SidebarMode::Rest) } else { SidebarMode::Rest };
        let shows_five_hour = state.as_ref().map(|(_, _, present)| *present).unwrap_or(false);
        *state = Some((display.clone(), mode, shows_five_hour)); (mode, shows_five_hour)
    };
    if !display.quota_sidebar_enabled {
        if let Some(window) = app.get_webview_window(LABEL) {
            window.emit("quota-sidebar-settings-changed", display).map_err(|e| e.to_string())?;
            window.hide().map_err(|e| e.to_string())?;
        }
        if let Some(window) = app.get_webview_window(DETAIL) { window.hide().map_err(|e| e.to_string())?; }
        return Ok(());
    }
    let rail = create_window(app, LABEL)?;
    let detail = create_window(app, DETAIL)?;
    apply_frames(&rail, &detail, &display.quota_sidebar_side, mode, shows_five_hour)?;
    rail.emit("quota-sidebar-settings-changed", display).map_err(|e| e.to_string())?;
    if placement::is_dragging() { return Ok(()); }
    show_passive(&rail)?;
    if mode == SidebarMode::Detail { show_passive(&detail)?; }
    Ok(())
}

#[tauri::command]
pub async fn set_quota_sidebar_mode(window: WebviewWindow, mode: SidebarMode, shows_five_hour: bool, reduced_motion: bool, refresh_geometry: bool) -> Result<SidebarFrame, String> {
    crate::commands::window_auth::require_window_label(&window, "set_quota_sidebar_mode")?;
    let native = window.clone();
    let (send, receive) = tokio::sync::oneshot::channel();
    window.run_on_main_thread(move || {
        let result = (|| {
            // Consult the latest native configuration on the same main-thread
            // queue as disable; an old IPC completion cannot resurrect windows.
            let mut state = STATE.lock().map_err(|e| e.to_string())?;
            let (display, current_mode, current_shows_five_hour) = state.as_mut().ok_or("Quota sidebar not configured")?;
            if !display.quota_sidebar_enabled { return Err("Quota sidebar is disabled".into()); }
            let detail = native.app_handle().get_webview_window(DETAIL).ok_or("Quota detail window unavailable")?;
            if placement::is_dragging() { return apply_frames(&native, &detail, &display.quota_sidebar_side, mode, shows_five_hour); }
            let frame = motion::start(&native, &detail, &display.quota_sidebar_side, mode, shows_five_hour, reduced_motion, refresh_geometry)?;
            if mode == SidebarMode::Detail { show_passive(&detail)?; }
            else { detail.hide().map_err(|e| e.to_string())?; }
            *current_mode = mode;
            *current_shows_five_hour = shows_five_hour;
            Ok(frame)
        })();
        let _ = send.send(result);
    }).map_err(|e| e.to_string())?;
    receive.await.map_err(|_| "Quota sidebar resize cancelled".to_string())?
}

#[tauri::command]
pub async fn drag_quota_sidebar(window: WebviewWindow) -> Result<bool, String> {
    crate::commands::window_auth::require_window_label(&window, "drag_quota_sidebar")?;
    placement::drag(window).await
}

#[tauri::command]
pub fn quota_sidebar_pointer_inside(window: WebviewWindow) -> Result<bool, String> {
    crate::commands::window_auth::require_window_label(&window, "quota_sidebar_pointer_inside")?;
    let pointer = window.cursor_position().map_err(|e| e.to_string())?;
    for label in [LABEL, DETAIL] {
        if let Some(candidate) = window.app_handle().get_webview_window(label) {
            if !candidate.is_visible().map_err(|e| e.to_string())? { continue; }
            let origin = candidate.outer_position().map_err(|e| e.to_string())?;
            let size = candidate.outer_size().map_err(|e| e.to_string())?;
            if pointer.x >= origin.x as f64 && pointer.x < origin.x as f64 + size.width as f64
                && pointer.y >= origin.y as f64 && pointer.y < origin.y as f64 + size.height as f64 { return Ok(true); }
        }
    }
    Ok(false)
}

fn show_passive(window: &WebviewWindow) -> Result<(), String> {
    if window.is_visible().map_err(|e| e.to_string())? { return Ok(()); }
    #[cfg(target_os = "macos")]
    unsafe { (&*window.ns_window().map_err(|e| e.to_string())?.cast::<objc2_app_kit::NSWindow>()).orderFrontRegardless(); }
    #[cfg(not(target_os = "macos"))]
    window.show().map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn configure_macos(window: &WebviewWindow) -> Result<(), String> {
    use objc2_app_kit::{NSWindow, NSWindowCollectionBehavior, NSWindowStyleMask};
    let native = unsafe { &*window.ns_window().map_err(|e| e.to_string())?.cast::<NSWindow>() };
    native.setStyleMask(native.styleMask() | NSWindowStyleMask::NonactivatingPanel);
    native.setCollectionBehavior(NSWindowCollectionBehavior::CanJoinAllSpaces | NSWindowCollectionBehavior::FullScreenAuxiliary);
    native.setHidesOnDeactivate(false);
    native.setAcceptsMouseMovedEvents(true);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn persisted_sidebar_defaults_off_and_roundtrips_independently() {
        let old: DisplaySurfaceSettingsSnapshot = serde_json::from_str(r#"{"floatingWindowEnabled":false,"liveRateEnabled":false}"#).unwrap();
        assert!(!old.quota_sidebar_enabled); assert_eq!(old.quota_sidebar_side, "right");
        let mut enabled = old; enabled.quota_sidebar_enabled = true; enabled.quota_sidebar_side = "left".into();
        let restored: DisplaySurfaceSettingsSnapshot = serde_json::from_str(&serde_json::to_string(&enabled).unwrap()).unwrap();
        assert!(restored.quota_sidebar_enabled); assert!(!restored.floating_window_enabled); assert!(!restored.live_rate_enabled);
        assert_eq!(restored.quota_sidebar_side, "left");
    }
    #[test]
    fn all_levels_keep_center_and_expand_inward() {
        for side in ["left", "right"] {
            let work = SidebarFrame { x: -1440.0, y: 23.0, width: 1440.0, height: 877.0 };
            for mode in [SidebarMode::Rest, SidebarMode::Hover, SidebarMode::Detail] {
                let (rail, detail) = frames_for(work, side, mode, true);
                for f in [rail, detail] { assert_eq!(f.y + f.height / 2.0, work.y + work.height / 2.0); }
                if side == "left" { assert_eq!(rail.x, work.x); assert_eq!(detail.x - (rail.x + rail.width), 16.0); }
                else { assert_eq!(rail.x + rail.width, work.x + work.width); assert_eq!(rail.x - (detail.x + detail.width), 16.0); }
                assert!(rail.width <= 88.0); assert_eq!(detail.width, 420.0);
            }
        }
    }
    #[test]
    fn clicking_detail_preserves_the_entire_hover_rail_frame() {
        for side in ["left", "right"] {
            for five in [false, true] {
                for center in [0.0, 0.2, 0.5, 1.0] {
                    let work = SidebarFrame { x: -1440.0, y: 24.0, width: 1440.0, height: 900.0 };
                    let (hover, _) = frames_for_at(work, side, SidebarMode::Hover, five, center);
                    let (detail, _) = frames_for_at(work, side, SidebarMode::Detail, five, center);
                    assert_eq!(hover, detail);
                    assert_eq!(hover.width, 88.0);
                    assert_eq!(hover.height, if five { 560.0 } else { 470.0 });
                }
            }
        }
    }
    #[test]
    fn five_hour_presence_changes_height_without_moving_center_or_detail() {
        let work = SidebarFrame { x: -1440.0, y: 24.0, width: 1440.0, height: 876.0 };
        for side in ["left", "right"] {
            for mode in [SidebarMode::Rest, SidebarMode::Hover, SidebarMode::Detail] {
                let (three, detail_three) = frames_for(work, side, mode, true);
                let (two, detail_two) = frames_for(work, side, mode, false);
                assert_eq!(three.height, if mode == SidebarMode::Rest { 250.0 } else { 560.0 });
                assert_eq!(two.height, if mode == SidebarMode::Rest { 192.0 } else { 470.0 });
                assert_eq!(three.y + three.height / 2.0, two.y + two.height / 2.0);
                assert_eq!(three.x, two.x); assert_eq!(three.width, two.width);
                assert_eq!(detail_three, detail_two);
            }
        }
    }
    #[test]
    fn tiny_and_fractional_workareas_clamp_both_windows() {
        for width in [80.0, 240.0, 490.5] {
            let work = SidebarFrame { x: 10.5, y: -200.0, width, height: 220.5 };
            for side in ["left", "right"] {
                let (rail, detail) = frames_for(work, side, SidebarMode::Detail, true);
                for f in [rail, detail] { assert!(f.x >= work.x); assert!(f.x + f.width <= work.x + work.width); assert!(f.y >= work.y); assert!(f.y + f.height <= work.y + work.height); }
            }
        }
    }
}
