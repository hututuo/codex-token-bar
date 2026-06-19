use crate::core::startup_trace;
use std::sync::{Mutex, OnceLock};
use tauri::{
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    webview::PageLoadEvent,
    Manager, WebviewUrl, WebviewWindowBuilder,
};

const FLOATING_WINDOW_WIDTH: f64 = 296.0;
const FLOATING_WINDOW_HEIGHT: f64 = 112.0;
const FLOATING_WINDOW_MIN_SCALE: f64 = 0.9;
const FLOATING_WINDOW_MAX_SCALE: f64 = 1.38;
const DASHBOARD_WINDOW_WIDTH: f64 = 1180.0;
const DASHBOARD_WINDOW_HEIGHT: f64 = 860.0;
const DASHBOARD_WINDOW_MIN_WIDTH: f64 = 960.0;
const DASHBOARD_WINDOW_MIN_HEIGHT: f64 = 720.0;
const STATUS_PANEL_WIDTH: f64 = 336.0;
const STATUS_PANEL_HEIGHT: f64 = 236.0;
const STATUS_TRAY_ID: &str = "codex-token-bar-status";

#[derive(Clone, Debug, Default)]
pub(crate) struct SurfaceSetupStatus {
    pub(crate) floating_window_error: Option<String>,
    pub(crate) status_panel_error: Option<String>,
    pub(crate) status_tray_error: Option<String>,
}

static SURFACE_SETUP_STATUS: OnceLock<Mutex<SurfaceSetupStatus>> = OnceLock::new();

pub fn setup_desktop_surfaces(app: &tauri::App) -> tauri::Result<()> {
    startup_trace::mark("rust setup start");
    let mut status = SurfaceSetupStatus::default();

    startup_trace::mark("dashboard window create start");
    create_dashboard_window(app.handle())?;
    startup_trace::mark("dashboard window create end");

    startup_trace::mark("status tray create start");
    if let Err(error) = create_status_tray(app) {
        let message = error.to_string();
        eprintln!("Codex Token Bar: status tray setup failed: {message}");
        status.status_tray_error = Some(message);
    }
    startup_trace::mark("status tray create end");

    set_surface_setup_status(status);
    startup_trace::mark("rust setup end");
    Ok(())
}

pub(crate) fn surface_setup_status() -> SurfaceSetupStatus {
    surface_setup_status_cell()
        .lock()
        .map(|status| status.clone())
        .unwrap_or_default()
}

fn set_surface_setup_status(next: SurfaceSetupStatus) {
    if let Ok(mut status) = surface_setup_status_cell().lock() {
        *status = next;
    }
}

fn surface_setup_status_cell() -> &'static Mutex<SurfaceSetupStatus> {
    SURFACE_SETUP_STATUS.get_or_init(|| Mutex::new(SurfaceSetupStatus::default()))
}

pub fn show_floating_window(app: &tauri::AppHandle) -> Result<bool, String> {
    if app.get_webview_window("floating").is_none() {
        create_floating_window(app).map_err(|error| {
            let message = error.to_string();
            set_floating_window_error(Some(message.clone()));
            message
        })?;
    }
    set_floating_window_error(None);
    let window = app
        .get_webview_window("floating")
        .ok_or_else(|| "floating window is not available".to_string())?;
    window.show().map_err(|error| error.to_string())?;
    window
        .set_always_on_top(true)
        .map_err(|error| error.to_string())?;
    Ok(true)
}

pub fn hide_floating_window(app: &tauri::AppHandle) -> Result<bool, String> {
    let Some(window) = app.get_webview_window("floating") else {
        return Ok(false);
    };
    window.hide().map_err(|error| error.to_string())?;
    Ok(false)
}

pub fn show_dashboard_window(app: &tauri::AppHandle) -> Result<bool, String> {
    if app.get_webview_window("main").is_none() {
        create_dashboard_window(app).map_err(|error| error.to_string())?;
    }
    let window = app
        .get_webview_window("main")
        .ok_or_else(|| "dashboard window is not available".to_string())?;
    window.show().map_err(|error| error.to_string())?;
    window.set_focus().map_err(|error| error.to_string())?;
    Ok(true)
}

pub fn show_status_panel_window(app: &tauri::AppHandle) -> Result<bool, String> {
    if app.get_webview_window("status").is_none() {
        create_status_panel_window(app).map_err(|error| {
            let message = error.to_string();
            set_status_panel_error(Some(message.clone()));
            message
        })?;
    }
    set_status_panel_error(None);
    let window = app
        .get_webview_window("status")
        .ok_or_else(|| "status panel is not available".to_string())?;
    window.show().map_err(|error| error.to_string())?;
    window.set_focus().map_err(|error| error.to_string())?;
    Ok(true)
}

pub fn hide_status_panel_window(app: &tauri::AppHandle) -> Result<bool, String> {
    let Some(window) = app.get_webview_window("status") else {
        return Ok(false);
    };
    window.hide().map_err(|error| error.to_string())?;
    Ok(false)
}

fn toggle_status_panel_window(app: &tauri::AppHandle) {
    if app.get_webview_window("status").is_none() {
        let _ = show_status_panel_window(app);
        return;
    }

    let Some(window) = app.get_webview_window("status") else {
        return;
    };

    if window.is_visible().unwrap_or(false) {
        let _ = window.hide();
        return;
    }

    let _ = window.show();
    let _ = window.set_focus();
}

pub fn set_status_tray_readout(
    app: &tauri::AppHandle,
    title: String,
    tooltip: String,
) -> Result<bool, String> {
    let Some(tray) = app.tray_by_id(STATUS_TRAY_ID) else {
        return Ok(false);
    };

    tray.set_title(Some(title))
        .map_err(|error| error.to_string())?;
    tray.set_tooltip(Some(tooltip))
        .map_err(|error| error.to_string())?;
    Ok(true)
}

fn create_status_tray(app: &tauri::App) -> tauri::Result<()> {
    if app.tray_by_id(STATUS_TRAY_ID).is_some() {
        return Ok(());
    }

    TrayIconBuilder::with_id(STATUS_TRAY_ID)
        .title("0.0/s")
        .tooltip("Codex Token Bar")
        .show_menu_on_left_click(false)
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                toggle_status_panel_window(tray.app_handle());
            }
        })
        .build(app)?;

    Ok(())
}

fn create_dashboard_window(app: &tauri::AppHandle) -> tauri::Result<()> {
    if app.get_webview_window("main").is_some() {
        return Ok(());
    }

    WebviewWindowBuilder::new(app, "main", WebviewUrl::App("/index.html".into()))
        .title("Codex Token Bar")
        .inner_size(DASHBOARD_WINDOW_WIDTH, DASHBOARD_WINDOW_HEIGHT)
        .min_inner_size(DASHBOARD_WINDOW_MIN_WIDTH, DASHBOARD_WINDOW_MIN_HEIGHT)
        .resizable(true)
        .center()
        .visible(false)
        .on_page_load(|window, payload| {
            if matches!(payload.event(), PageLoadEvent::Finished) {
                startup_trace::mark("dashboard page load finished");
                if let Err(error) = window.show() {
                    startup_trace::mark(&format!("dashboard page load show failed: {error}"));
                    return;
                }
                if let Err(error) = window.set_focus() {
                    startup_trace::mark(&format!("dashboard page load focus failed: {error}"));
                }
                startup_trace::mark("dashboard window shown after page load");
            }
        })
        .build()?;

    Ok(())
}

fn create_floating_window(app: &tauri::AppHandle) -> tauri::Result<()> {
    if app.get_webview_window("floating").is_some() {
        return Ok(());
    }

    WebviewWindowBuilder::new(
        app,
        "floating",
        WebviewUrl::App("/index.html?surface=floating".into()),
    )
    .title("Codex Token Bar Floating")
    .inner_size(FLOATING_WINDOW_WIDTH, FLOATING_WINDOW_HEIGHT)
    .min_inner_size(
        FLOATING_WINDOW_WIDTH * FLOATING_WINDOW_MIN_SCALE,
        FLOATING_WINDOW_HEIGHT * FLOATING_WINDOW_MIN_SCALE,
    )
    .max_inner_size(
        FLOATING_WINDOW_WIDTH * FLOATING_WINDOW_MAX_SCALE,
        FLOATING_WINDOW_HEIGHT * FLOATING_WINDOW_MAX_SCALE,
    )
    .position(48.0, 86.0)
    .decorations(false)
    .resizable(false)
    .focused(false)
    .always_on_top(true)
    .visible_on_all_workspaces(true)
    .skip_taskbar(true)
    .shadow(false)
    .transparent(true)
    .build()?;

    Ok(())
}

fn create_status_panel_window(app: &tauri::AppHandle) -> tauri::Result<()> {
    if app.get_webview_window("status").is_some() {
        return Ok(());
    }

    WebviewWindowBuilder::new(
        app,
        "status",
        WebviewUrl::App("/index.html?surface=status".into()),
    )
    .title("Codex Token Bar Status")
    .inner_size(STATUS_PANEL_WIDTH, STATUS_PANEL_HEIGHT)
    .position(84.0, 80.0)
    .decorations(false)
    .resizable(false)
    .focused(false)
    .always_on_top(true)
    .skip_taskbar(true)
    .shadow(true)
    .visible(false)
    .build()?;

    Ok(())
}

fn set_floating_window_error(error: Option<String>) {
    if let Ok(mut status) = surface_setup_status_cell().lock() {
        status.floating_window_error = error;
    }
}

fn set_status_panel_error(error: Option<String>) {
    if let Ok(mut status) = surface_setup_status_cell().lock() {
        status.status_panel_error = error;
    }
}
