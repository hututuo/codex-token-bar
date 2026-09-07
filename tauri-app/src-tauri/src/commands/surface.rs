use super::window_auth::require_window_label;
use crate::platform;

#[tauri::command]
pub async fn show_floating_window(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<bool, String> {
    require_window_label(&window, "show_floating_window")?;
    platform::show_floating_window_from_command(&app).await
}

#[tauri::command]
pub fn hide_floating_window(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<bool, String> {
    require_window_label(&window, "hide_floating_window")?;
    platform::hide_floating_window(&app)
}

#[tauri::command]
pub async fn show_dashboard_window(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<bool, String> {
    require_window_label(&window, "show_dashboard_window")?;
    platform::show_dashboard_window_from_command(&app).await
}

#[tauri::command]
pub async fn show_status_panel_window(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<bool, String> {
    require_window_label(&window, "show_status_panel_window")?;
    platform::show_status_panel_window_from_command(&app).await
}

#[tauri::command]
pub fn hide_status_panel_window(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<bool, String> {
    require_window_label(&window, "hide_status_panel_window")?;
    platform::hide_status_panel_window(&app)
}

#[tauri::command]
pub fn dismiss_status_panel_on_blur(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<bool, String> {
    require_window_label(&window, "dismiss_status_panel_on_blur")?;
    platform::dismiss_status_panel_on_blur(&app)
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FloatingPointerState {
    x: f64,
    y: f64,
    left_button_down: bool,
}

/// Read only during a native drag or at a hide boundary, never on an idle timer.
#[tauri::command]
pub fn read_floating_pointer_state(
    window: tauri::WebviewWindow,
) -> Result<FloatingPointerState, String> {
    require_window_label(&window, "read_floating_pointer_state")?;
    let position = window.cursor_position().map_err(|error| error.to_string())?;
    Ok(FloatingPointerState {
        x: position.x,
        y: position.y,
        left_button_down: floating_left_button_down()?,
    })
}

#[cfg(target_os = "macos")]
fn floating_left_button_down() -> Result<bool, String> {
    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGEventSourceButtonState(state_id: i32, button: u32) -> bool;
    }
    // Combined session state, left mouse button; no event tap or AX permission.
    Ok(unsafe { CGEventSourceButtonState(0, 0) })
}

#[cfg(windows)]
fn floating_left_button_down() -> Result<bool, String> {
    #[link(name = "user32")]
    extern "system" {
        fn GetAsyncKeyState(virtual_key: i32) -> i16;
    }
    Ok(unsafe { GetAsyncKeyState(0x01) } < 0)
}

#[cfg(not(any(target_os = "macos", windows)))]
fn floating_left_button_down() -> Result<bool, String> {
    Err("Native edge docking pointer state is unavailable on this platform".into())
}

#[derive(Clone, Copy, serde::Deserialize)]
pub struct FloatingDockFrame {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

impl FloatingDockFrame {
    fn validate(self) -> Result<Self, String> {
        if [self.x, self.y, self.width, self.height].iter().any(|v| !v.is_finite() || v.abs() > i32::MAX as f64)
            || self.width < 1.0 || self.height < 1.0 {
            return Err("Invalid floating dock frame".into());
        }
        Ok(self)
    }
}

/// Commit position and size together so a right/bottom handle never paints at
/// the previous full window's origin between two separate native API calls.
#[tauri::command]
pub async fn set_floating_dock_frame(window: tauri::WebviewWindow, frame: FloatingDockFrame) -> Result<(), String> {
    require_window_label(&window, "set_floating_dock_frame")?;
    let frame = frame.validate()?;
    let (sender, receiver) = tokio::sync::oneshot::channel();
    let native = window.clone();
    window.run_on_main_thread(move || { let _ = sender.send(apply_floating_dock_frame(&native, frame)); })
        .map_err(|error| error.to_string())?;
    receiver.await.map_err(|_| "Floating frame update was cancelled".to_string())?
}

#[cfg(target_os = "macos")]
fn apply_floating_dock_frame(window: &tauri::WebviewWindow, frame: FloatingDockFrame) -> Result<(), String> {
    use objc2_app_kit::NSWindow;
    use objc2_foundation::{MainThreadMarker, NSPoint, NSRect, NSSize};
    let _mtm = MainThreadMarker::new().ok_or("Floating frame update requires the main thread")?;
    let raw = window.ns_window().map_err(|error| error.to_string())?;
    if raw.is_null() { return Err("Floating native window is unavailable".into()); }
    let native = unsafe { &*raw.cast::<NSWindow>() };
    let scale = native.backingScaleFactor();
    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGMainDisplayID() -> u32;
        fn CGDisplayPixelsHigh(display: u32) -> usize;
    }
    let primary_height = unsafe { CGDisplayPixelsHigh(CGMainDisplayID()) } as f64;
    // Match Tao's physical-pixel / primary-display top-left conversion.
    let rect = NSRect::new(
        NSPoint::new(frame.x / scale, primary_height - (frame.y + frame.height) / scale),
        NSSize::new(frame.width / scale, frame.height / scale),
    );
    native.setFrame_display(rect, true);
    Ok(())
}

#[cfg(windows)]
fn apply_floating_dock_frame(window: &tauri::WebviewWindow, frame: FloatingDockFrame) -> Result<(), String> {
    use windows_sys::Win32::UI::WindowsAndMessaging::{SetWindowPos, SWP_NOACTIVATE, SWP_NOZORDER};
    let handle = window.hwnd().map_err(|error| error.to_string())?;
    let success = unsafe { SetWindowPos(handle.0, std::ptr::null_mut(), frame.x.round() as i32, frame.y.round() as i32,
        frame.width.round() as i32, frame.height.round() as i32, SWP_NOACTIVATE | SWP_NOZORDER) };
    if success == 0 { return Err(std::io::Error::last_os_error().to_string()); }
    Ok(())
}

#[cfg(not(any(target_os = "macos", windows)))]
fn apply_floating_dock_frame(window: &tauri::WebviewWindow, frame: FloatingDockFrame) -> Result<(), String> {
    window.set_size(tauri::PhysicalSize::new(frame.width.round() as u32, frame.height.round() as u32)).map_err(|e| e.to_string())?;
    window.set_position(tauri::PhysicalPosition::new(frame.x.round() as i32, frame.y.round() as i32)).map_err(|e| e.to_string())
}

#[cfg(test)]
mod dock_frame_tests {
    use super::FloatingDockFrame;
    #[test]
    fn accepts_negative_display_coordinates_and_rejects_invalid_native_bounds() {
        let valid = FloatingDockFrame { x: -1600.0, y: 240.0, width: 24.0, height: 212.0 };
        assert!(valid.validate().is_ok());
        for invalid in [FloatingDockFrame { x: f64::NAN, ..valid }, FloatingDockFrame { width: 0.0, ..valid },
            FloatingDockFrame { y: f64::INFINITY, ..valid }, FloatingDockFrame { width: i32::MAX as f64 + 1.0, ..valid }] {
            assert!(invalid.validate().is_err());
        }
    }
}
