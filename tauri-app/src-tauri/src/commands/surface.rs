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
