//! Native mouse tracking owns dragging; no enlarged webview or global event hook.
use super::*;
use std::{path::PathBuf, sync::Mutex};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Position { screen: String, center_y: f64 }
struct Placement { loaded: bool, position: Option<Position> }
static PLACEMENT: Mutex<Placement> = Mutex::new(Placement { loaded: false, position: None });
struct Drag { size: (f64, f64), press: (f64, f64), anchor: (f64, f64), started: bool, mode: SidebarMode, five: bool, prior_side: String }
static DRAG: Mutex<Option<Drag>> = Mutex::new(None);
#[derive(Clone)]
struct Screen { id: String, work: SidebarFrame, scale: f64 }

pub(super) fn is_dragging() -> bool { DRAG.lock().map(|drag| drag.is_some()).unwrap_or(false) }
pub(super) fn cancel() { super::motion::cancel(); if let Ok(mut drag) = DRAG.lock() { *drag = None; } }
fn position_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    Ok(app.path().app_config_dir().map_err(|e| e.to_string())?.join("quota-sidebar-position.json"))
}
fn valid_position(position: Position) -> Option<Position> {
    if position.screen.is_empty() || !position.center_y.is_finite() { return None; }
    Some(Position { center_y: position.center_y.clamp(0.0, 1.0), ..position })
}
fn position(app: &tauri::AppHandle) -> Result<Option<Position>, String> {
    let mut state = PLACEMENT.lock().map_err(|e| e.to_string())?;
    if !state.loaded {
        state.position = std::fs::read(position_path(app)?).ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok()).and_then(valid_position);
        state.loaded = true;
    }
    Ok(state.position.clone())
}
fn save_position(app: &tauri::AppHandle, position: &Position) -> Result<(), String> {
    let path = position_path(app)?;
    if let Some(parent) = path.parent() { std::fs::create_dir_all(parent).map_err(|e| e.to_string())?; }
    let temp = path.with_extension("json.pending");
    std::fs::write(&temp, serde_json::to_vec(position).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    // Only this module writes the independent placement file, once per completed drag.
    std::fs::rename(temp, path).map_err(|e| e.to_string())
}
fn normalized_center(frame: SidebarFrame, work: SidebarFrame) -> f64 {
    ((frame.y + frame.height / 2.0 - work.y) / work.height.max(1.0)).clamp(0.0, 1.0)
}
fn nearest_screen(screens: &[Screen], point: (f64, f64)) -> Option<&Screen> {
    screens.iter().min_by(|a, b| {
        let distance = |screen: &Screen| {
            let x = point.0.clamp(screen.work.x, screen.work.x + screen.work.width);
            let y = point.1.clamp(screen.work.y, screen.work.y + screen.work.height);
            (point.0 - x).powi(2) + (point.1 - y).powi(2)
        };
        distance(a).total_cmp(&distance(b))
    })
}
fn snap_side(work: SidebarFrame, pointer_x: f64) -> &'static str {
    if pointer_x < work.x + work.width / 2.0 { "left" } else { "right" }
}
fn passed_threshold(press: (f64, f64), pointer: (f64, f64), scale: f64) -> bool {
    (pointer.0 - press.0).hypot(pointer.1 - press.1) >= 4.0 * scale
}
fn screen_frames(screen: &Screen, side: &str, mode: SidebarMode, five: bool, center: f64) -> (SidebarFrame, SidebarFrame) {
    let scale = screen.scale;
    let work = SidebarFrame { x: screen.work.x / scale, y: screen.work.y / scale,
        width: screen.work.width / scale, height: screen.work.height / scale };
    let (rail, detail) = super::frames_for_at(work, side, mode, five, center);
    let physical = |f: SidebarFrame| SidebarFrame { x: f.x * scale, y: f.y * scale, width: f.width * scale, height: f.height * scale };
    (physical(rail), physical(detail))
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct Geometry {
    pub screen_id: String, pub work: SidebarFrame, pub scale: f64, pub center: f64,
    pub side: String, pub rail: SidebarFrame, pub card: SidebarFrame,
}
pub(super) fn geometry(rail: &WebviewWindow, side: &str, mode: SidebarMode, five: bool) -> Result<Geometry, String> {
    let saved = position(rail.app_handle())?;
    let screens = screens(rail)?;
    let current = window_frame(rail)?;
    let screen = saved.as_ref().and_then(|saved| screens.iter().find(|screen| screen.id == saved.screen))
        .or_else(|| nearest_screen(&screens, (current.x + current.width / 2.0, current.y + current.height / 2.0)))
        .or_else(|| screens.first()).ok_or("No display available")?;
    let center = saved.map(|s| s.center_y).unwrap_or(0.5);
    let (frame, card) = screen_frames(screen, side, mode, five, center);
    Ok(Geometry { screen_id: screen.id.clone(), work: screen.work, scale: screen.scale,
        center: screen.work.y + screen.work.height * center, side: side.into(), rail: frame, card })
}
pub(super) fn apply_frames(rail: &WebviewWindow, detail: &WebviewWindow, side: &str, mode: SidebarMode, five: bool) -> Result<SidebarFrame, String> {
    if is_dragging() { return window_frame(rail); }
    super::motion::cancel();
    let target = geometry(rail, side, mode, five)?;
    set_rail_frame(rail, target.rail, &target.side, target.scale)?; set_frame(detail, target.card)?;
    Ok(target.rail)
}

fn begin(rail: &WebviewWindow) -> Result<(), String> {
    let mut active = DRAG.lock().map_err(|e| e.to_string())?;
    if active.is_some() { return Err("Quota sidebar drag already active".into()); }
    let state = STATE.lock().map_err(|e| e.to_string())?;
    let (display, mode, five) = state.as_ref().ok_or("Quota sidebar not configured")?;
    if !display.quota_sidebar_enabled { return Err("Quota sidebar is disabled".into()); }
    let (x, y, pressed) = pointer(rail)?;
    if !pressed { return Ok(()); }
    super::motion::cancel(); // Freeze the actual in-between native frame before arming.
    let _ = window_frame(rail)?;
    *active = Some(Drag { size: (0.0, 0.0), press: (x, y), anchor: (0.0, 0.0), started: false,
        mode: if *mode == SidebarMode::Detail { SidebarMode::Hover } else { *mode }, five: *five,
        prior_side: display.quota_sidebar_side.clone() });
    Ok(())
}
struct Finished { position: Position, side: String, prior_side: String }
fn step(rail: &WebviewWindow) -> Result<(bool, Option<Finished>), String> {
    let mut active = DRAG.lock().map_err(|e| e.to_string())?;
    let Some(drag) = active.as_mut() else { return Ok((true, None)); };
    let mut state = STATE.lock().map_err(|e| e.to_string())?;
    let Some((display, mode, _)) = state.as_mut() else { *active = None; return Ok((true, None)); };
    if !display.quota_sidebar_enabled || !rail.is_visible().map_err(|e| e.to_string())? { *active = None; return Ok((true, None)); }
    let (x, y, pressed) = pointer(rail)?;
    let screens = screens(rail)?;
    let screen = nearest_screen(&screens, (x, y)).ok_or("No display available")?;
    if !drag.started {
        if !pressed { *active = None; return Ok((true, None)); }
        if !passed_threshold(drag.press, (x, y), screen.scale) { return Ok((false, None)); }
        // Re-anchor the actual frame after any already-queued hover expansion.
        let frame = window_frame(rail)?;
        let original_scale = nearest_screen(&screens, (frame.x + frame.width / 2.0, frame.y + frame.height / 2.0)).map(|s| s.scale).unwrap_or(screen.scale);
        drag.size = (frame.width / original_scale, frame.height / original_scale);
        drag.anchor = ((x - frame.x) / frame.width.max(1.0), (y - frame.y) / frame.height.max(1.0));
        drag.started = true; *mode = drag.mode;
        if let Some(detail) = rail.app_handle().get_webview_window(DETAIL) { detail.hide().map_err(|e| e.to_string())?; }
        rail.emit("quota-sidebar-drag-started", ()).map_err(|e| e.to_string())?;
    }
    let (mut frame, _) = screen_frames(screen, &display.quota_sidebar_side, drag.mode, drag.five, 0.5);
    frame.width = (drag.size.0 * screen.scale).clamp(1.0, screen.work.width.max(1.0));
    frame.height = (drag.size.1 * screen.scale).clamp(1.0, screen.work.height.max(1.0));
    frame.x = x - drag.anchor.0 * frame.width; frame.y = y - drag.anchor.1 * frame.height;
    set_rail_frame(rail, frame, &display.quota_sidebar_side, screen.scale)?;
    if pressed { return Ok((false, None)); }
    let side = snap_side(screen.work, x).to_string();
    let saved = Position { screen: screen.id.clone(), center_y: normalized_center(frame, screen.work) };
    let (snapped, detail_frame) = screen_frames(screen, &side, drag.mode, drag.five, saved.center_y);
    if let Some(detail) = rail.app_handle().get_webview_window(DETAIL) { set_frame(&detail, detail_frame)?; }
    PLACEMENT.lock().map_err(|e| e.to_string())?.position = Some(saved.clone());
    PLACEMENT.lock().map_err(|e| e.to_string())?.loaded = true;
    display.quota_sidebar_side = side.clone();
    let finished = Finished { position: saved, side, prior_side: drag.prior_side.clone() };
    *active = None;
    super::motion::snap(rail, Geometry { screen_id: screen.id.clone(), work: screen.work,
        scale: screen.scale, center: screen.work.y + screen.work.height * finished.position.center_y,
        side: finished.side.clone(), rail: snapped, card: detail_frame })?;
    Ok((true, Some(finished)))
}

pub(super) async fn drag(rail: WebviewWindow) -> Result<bool, String> {
    let native = rail.clone();
    on_main(&rail, move || begin(&native)).await?;
    let started = std::time::Instant::now();
    loop {
        tokio::time::sleep(std::time::Duration::from_millis(16)).await;
        let native = rail.clone();
        let outcome = on_main(&rail, move || step(&native)).await;
        let (done, finished) = match outcome { Ok(value) => value, Err(error) => { cancel(); return Err(error); } };
        if let Some(finished) = finished {
            let app = rail.app_handle().clone();
            let _saved = tokio::task::spawn_blocking(move || {
                save_position(&app, &finished.position)?;
                super::super::settings::mutate_app_settings(|settings| {
                    // Preserve a newer explicit side-picker selection or disable.
                    if settings.display_surfaces.quota_sidebar_enabled && settings.display_surfaces.quota_sidebar_side == finished.prior_side {
                        settings.display_surfaces.quota_sidebar_side = finished.side;
                    }
                })
            }).await.map_err(|e| e.to_string())??;
            // A newer disable/side change may have completed during disk I/O.
            // Broadcast the current native configuration without showing or resizing.
            let native = rail.clone();
            on_main(&rail, move || {
                if let Some((current, _, _)) = STATE.lock().map_err(|e| e.to_string())?.as_ref() {
                    native.app_handle().emit("display-surfaces-changed", current).map_err(|e| e.to_string())?;
                    native.emit("quota-sidebar-settings-changed", current).map_err(|e| e.to_string())?;
                }
                Ok(())
            }).await?;
            return Ok(true);
        }
        if done { return Ok(false); }
        if started.elapsed() > std::time::Duration::from_secs(600) { cancel(); return Err("Quota sidebar drag timed out".into()); }
    }
}
pub(super) async fn on_main<T: Send + 'static>(window: &WebviewWindow, work: impl FnOnce() -> Result<T, String> + Send + 'static) -> Result<T, String> {
    let (send, receive) = tokio::sync::oneshot::channel();
    window.run_on_main_thread(move || { let _ = send.send(work()); }).map_err(|e| e.to_string())?;
    receive.await.map_err(|_| "Quota sidebar drag cancelled".to_string())?
}

#[cfg(target_os = "macos")]
fn pointer(_: &WebviewWindow) -> Result<(f64, f64, bool), String> {
    let point = objc2_app_kit::NSEvent::mouseLocation();
    Ok((point.x, point.y, objc2_app_kit::NSEvent::pressedMouseButtons() & 1 != 0))
}
#[cfg(windows)]
fn pointer(window: &WebviewWindow) -> Result<(f64, f64, bool), String> {
    let point = window.cursor_position().map_err(|e| e.to_string())?;
    let pressed = unsafe { windows_sys::Win32::UI::Input::KeyboardAndMouse::GetAsyncKeyState(1) } < 0;
    Ok((point.x, point.y, pressed))
}
#[cfg(not(any(target_os = "macos", windows)))]
fn pointer(_: &WebviewWindow) -> Result<(f64, f64, bool), String> { Err("Sidebar dragging is not supported on this platform".into()) }

#[cfg(target_os = "macos")]
fn screens(_: &WebviewWindow) -> Result<Vec<Screen>, String> {
    use objc2_app_kit::NSScreen;
    use objc2_foundation::{MainThreadMarker, NSString};
    let mtm = MainThreadMarker::new().ok_or("Sidebar geometry requires main thread")?;
    Ok(NSScreen::screens(mtm).iter().map(|screen| {
        let work = screen.visibleFrame();
        let id = screen.deviceDescription().objectForKey(&NSString::from_str("NSScreenNumber"))
            .map(|number| unsafe { let id: u32 = objc2::msg_send![&*number, unsignedIntValue]; format!("display:{id}") })
            .unwrap_or_else(|| screen.localizedName().to_string());
        Screen { id, work: SidebarFrame { x: work.origin.x, y: work.origin.y, width: work.size.width, height: work.size.height }, scale: 1.0 }
    }).collect())
}
#[cfg(not(target_os = "macos"))]
fn screens(window: &WebviewWindow) -> Result<Vec<Screen>, String> {
    Ok(window.available_monitors().map_err(|e| e.to_string())?.into_iter().map(|monitor| {
        let work = monitor.work_area();
        Screen { id: monitor.name().cloned().unwrap_or_else(|| format!("display:{},{}", monitor.position().x, monitor.position().y)),
            work: SidebarFrame { x: work.position.x as f64, y: work.position.y as f64, width: work.size.width as f64, height: work.size.height as f64 }, scale: monitor.scale_factor() }
    }).collect())
}
#[cfg(target_os = "macos")]
pub(super) fn window_frame(window: &WebviewWindow) -> Result<SidebarFrame, String> {
    let native = unsafe { &*window.ns_window().map_err(|e| e.to_string())?.cast::<objc2_app_kit::NSWindow>() };
    let frame = native.frame();
    Ok(SidebarFrame { x: frame.origin.x, y: frame.origin.y, width: frame.size.width, height: frame.size.height })
}
#[cfg(not(target_os = "macos"))]
pub(super) fn window_frame(window: &WebviewWindow) -> Result<SidebarFrame, String> {
    #[cfg(windows)]
    if window.label() == super::LABEL { return super::canvas_windows::window_frame(window); }
    let origin = window.outer_position().map_err(|e| e.to_string())?; let size = window.outer_size().map_err(|e| e.to_string())?;
    Ok(SidebarFrame { x: origin.x as f64, y: origin.y as f64, width: size.width as f64, height: size.height as f64 })
}
#[cfg(target_os = "macos")]
pub(super) fn set_frame(window: &WebviewWindow, frame: SidebarFrame) -> Result<(), String> {
    use objc2_foundation::{NSPoint, NSRect, NSSize};
    let native = unsafe { &*window.ns_window().map_err(|e| e.to_string())?.cast::<objc2_app_kit::NSWindow>() };
    let rect = NSRect::new(NSPoint::new(frame.x, frame.y), NSSize::new(frame.width, frame.height));
    if window.label() == super::LABEL {
        super::canvas_macos::set_frame(native, rect)?;
    } else if native.frame() != rect { native.setFrame_display(rect, true); }
    Ok(())
}
pub(super) fn set_rail_frame(window: &WebviewWindow, frame: SidebarFrame, side: &str, scale: f64) -> Result<(), String> {
    #[cfg(windows)]
    { super::canvas_windows::set_frame(window, frame, side == "left", scale) }
    #[cfg(not(windows))]
    { let _ = (side, scale); set_frame(window, frame) }
}
#[cfg(windows)]
pub(super) fn set_frame(window: &WebviewWindow, frame: SidebarFrame) -> Result<(), String> {
    use windows_sys::Win32::UI::WindowsAndMessaging::{SetWindowPos, SWP_NOACTIVATE, SWP_NOZORDER};
    let hwnd = window.hwnd().map_err(|e| e.to_string())?;
    if unsafe { SetWindowPos(hwnd.0, std::ptr::null_mut(), frame.x.round() as i32, frame.y.round() as i32,
        frame.width.round() as i32, frame.height.round() as i32, SWP_NOACTIVATE | SWP_NOZORDER) } == 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok(())
}
#[cfg(not(any(target_os = "macos", windows)))]
pub(super) fn set_frame(window: &WebviewWindow, frame: SidebarFrame) -> Result<(), String> {
    let current = window_frame(window)?;
    if current.width != frame.width.round() || current.height != frame.height.round() {
        window.set_size(tauri::PhysicalSize::new(frame.width.round() as u32, frame.height.round() as u32)).map_err(|e| e.to_string())?;
    }
    if current.x != frame.x.round() || current.y != frame.y.round() {
        window.set_position(tauri::PhysicalPosition::new(frame.x.round() as i32, frame.y.round() as i32)).map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn screen(id: &str, x: f64, y: f64, width: f64, height: f64, scale: f64) -> Screen {
        Screen { id: id.into(), work: SidebarFrame { x, y, width, height }, scale }
    }
    #[test]
    fn drag_threshold_distinguishes_click_and_scales_physical_pixels() {
        assert!(!passed_threshold((100.0, 100.0), (102.0, 102.0), 1.0));
        assert!(passed_threshold((100.0, 100.0), (104.0, 100.0), 1.0));
        assert!(!passed_threshold((100.0, 100.0), (107.0, 100.0), 2.0));
        assert!(passed_threshold((100.0, 100.0), (108.0, 100.0), 2.0));
    }
    #[test]
    fn free_drag_selects_pointer_screen_nearest_edge_and_gap_fallback() {
        let screens = [screen("left", -1440.0, 0.0, 1440.0, 900.0, 1.0), screen("retina", 200.0, -500.0, 2560.0, 1440.0, 2.0)];
        assert_eq!(nearest_screen(&screens, (-700.0, 100.0)).unwrap().id, "left");
        assert_eq!(nearest_screen(&screens, (900.0, -100.0)).unwrap().id, "retina");
        assert_eq!(nearest_screen(&screens, (180.0, 100.0)).unwrap().id, "retina");
        assert_eq!(snap_side(screens[1].work, 210.0), "left");
        assert_eq!(snap_side(screens[1].work, 2500.0), "right");
        assert!(nearest_screen(&[], (0.0, 0.0)).is_none());
    }
    #[test]
    fn normalized_position_roundtrips_and_rejects_invalid_saved_values() {
        let saved = Position { screen: "display:42".into(), center_y: 0.27 };
        let restored = valid_position(serde_json::from_slice(&serde_json::to_vec(&saved).unwrap()).unwrap());
        assert_eq!(restored, Some(saved));
        assert!(valid_position(Position { screen: "".into(), center_y: 0.5 }).is_none());
        assert!(valid_position(Position { screen: "x".into(), center_y: f64::NAN }).is_none());
        assert_eq!(valid_position(Position { screen: "x".into(), center_y: 2.0 }).unwrap().center_y, 1.0);
    }
    #[test]
    fn arbitrary_vertical_anchor_survives_mode_changes_with_workarea_clamping() {
        let screen = screen("main", 0.0, 24.0, 1440.0, 1200.0, 1.0);
        for center in [0.0, 0.27, 0.75, 1.0] {
            for mode in [SidebarMode::Rest, SidebarMode::Hover, SidebarMode::Detail] {
                let (rail, card) = screen_frames(&screen, "left", mode, true, center);
                for frame in [rail, card] {
                    assert!(frame.y >= screen.work.y); assert!(frame.y + frame.height <= screen.work.y + screen.work.height);
                }
                if center == 0.27 { assert!((normalized_center(rail, screen.work) - center).abs() < 1e-9); }
                assert_eq!(rail.x, screen.work.x);
            }
        }
    }
    #[test]
    fn mixed_dpi_geometry_keeps_global_physical_origin_and_logical_width() {
        let screen = screen("two", -2880.0, -300.0, 2880.0, 1800.0, 2.0);
        let (rail, detail) = screen_frames(&screen, "left", SidebarMode::Hover, false, 0.4);
        assert_eq!(rail.x, -2880.0); assert_eq!(rail.width, 176.0); assert_eq!(rail.height, 940.0);
        assert_eq!(detail.x - rail.x - rail.width, 32.0);
        assert!((normalized_center(rail, screen.work) - 0.4).abs() < 1e-9);
        let surviving = [screen.clone()];
        assert_eq!(nearest_screen(&surviving, (5000.0, 4000.0)).unwrap().id, "two");
    }
}


pub(super) fn frame_period(window: &WebviewWindow) -> std::time::Duration {
    #[cfg(target_os = "macos")]
    let hz = (|| {
        let native = unsafe { &*window.ns_window().ok()?.cast::<objc2_app_kit::NSWindow>() };
        let screen = native.screen()?;
        Some(screen.maximumFramesPerSecond().clamp(60, 120) as f64)
    })().unwrap_or(60.0);
    #[cfg(not(target_os = "macos"))]
    let hz = { let _ = window; 60.0 };
    std::time::Duration::from_secs_f64(1.0 / hz)
}
