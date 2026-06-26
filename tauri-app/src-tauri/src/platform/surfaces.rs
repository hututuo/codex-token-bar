use crate::core::startup_trace;
use std::{
    sync::{mpsc, Mutex, OnceLock},
    time::Duration,
};
use tauri::{
    image::Image,
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    webview::PageLoadEvent,
    Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder,
};
#[cfg(target_os = "macos")]
use tauri::TitleBarStyle;

const FLOATING_WINDOW_WIDTH: f64 = 296.0;
const FLOATING_WINDOW_MIN_HEIGHT: f64 = 88.0;
const FLOATING_WINDOW_DEFAULT_HEIGHT: f64 = 112.0;
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

    if cfg!(target_os = "windows") {
        startup_trace::mark("floating setup create start");
        if let Err(error) = create_floating_window(app.handle()) {
            let message = error.to_string();
            eprintln!("Codex Token Bar: floating window setup failed: {message}");
            status.floating_window_error = Some(message);
        }
        startup_trace::mark("floating setup create end");
    }

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
    startup_trace::mark("floating window show start");
    if app.get_webview_window("floating").is_none() {
        if cfg!(target_os = "windows") {
            let message = "Windows 悬浮窗未在启动阶段完成初始化".to_string();
            startup_trace::mark(&format!("floating window missing on windows: {message}"));
            set_floating_window_error(Some(message.clone()));
            return Err(message);
        }
        startup_trace::mark("floating window create start");
        if let Err(error) = create_floating_window_on_main_thread(app) {
            if app.get_webview_window("floating").is_none() {
                let message = error;
                startup_trace::mark(&format!("floating window create failed: {message}"));
                set_floating_window_error(Some(message.clone()));
                return Err(message);
            }
        }
        startup_trace::mark("floating window create end");
    }
    set_floating_window_error(None);
    let window = app
        .get_webview_window("floating")
        .ok_or_else(|| "floating window is not available".to_string())?;
    window.show().map_err(|error| {
        let message = error.to_string();
        startup_trace::mark(&format!("floating window show failed: {message}"));
        message
    })?;
    if let Err(error) = window.set_always_on_top(true) {
        startup_trace::mark(&format!("floating window always-on-top skipped: {error}"));
    }
    startup_trace::mark("floating window show end");
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

fn create_floating_window_on_main_thread(app: &tauri::AppHandle) -> Result<(), String> {
    let (tx, rx) = mpsc::channel();
    let app_for_call = app.clone();
    let app_for_window = app.clone();
    startup_trace::mark("floating window main dispatch start");
    app_for_call
        .run_on_main_thread(move || {
            startup_trace::mark("floating window build on main start");
            let result =
                create_floating_window(&app_for_window).map_err(|error| error.to_string());
            startup_trace::mark("floating window build on main end");
            let _ = tx.send(result);
        })
        .map_err(|error| error.to_string())?;
    startup_trace::mark("floating window main dispatch end");

    rx.recv_timeout(Duration::from_secs(3))
        .map_err(|_| "创建悬浮窗超时".to_string())?
}

fn toggle_status_panel_window(app: &tauri::AppHandle) {
    if cfg!(target_os = "windows") {
        return;
    }

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

    let mut builder = TrayIconBuilder::with_id(STATUS_TRAY_ID)
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
        });

    builder = builder.icon(status_tray_icon());

    builder.build(app)?;

    Ok(())
}

fn status_tray_icon() -> Image<'static> {
    const SIZE: u32 = 32;
    let mut rgba = vec![0; (SIZE * SIZE * 4) as usize];

    paint_rounded_rect(&mut rgba, SIZE, 2.0, 2.0, 30.0, 30.0, 8.0, [255, 255, 255, 255]);
    paint_rounded_rect(&mut rgba, SIZE, 3.0, 3.0, 29.0, 29.0, 7.0, [222, 240, 255, 120]);

    for row in 0..4 {
        for col in 0..5 {
            let power = (col as f32 / 4.0) * 0.6 + (row as f32 / 3.0) * 0.4;
            let blue = (190.0 - 78.0 * power).round() as u8;
            paint_rounded_rect(
                &mut rgba,
                SIZE,
                8.0 + col as f32 * 4.1,
                10.0 + row as f32 * 4.0,
                11.0 + col as f32 * 4.1,
                13.0 + row as f32 * 4.0,
                0.9,
                [blue, 216, 255, (96.0 + 112.0 * power).round() as u8],
            );
        }
    }

    let points = [
        (6.5, 24.0),
        (11.0, 19.6),
        (15.0, 21.2),
        (19.2, 16.4),
        (23.0, 12.0),
        (26.0, 9.4),
    ];
    paint_polyline(&mut rgba, SIZE, &points, 2.9, [255, 255, 255, 245]);
    paint_polyline(&mut rgba, SIZE, &points, 1.7, [0, 156, 220, 255]);
    for point in points.iter().skip(1) {
        paint_circle(&mut rgba, SIZE, point.0, point.1, 2.2, [255, 255, 255, 245]);
        paint_circle(&mut rgba, SIZE, point.0, point.1, 1.35, [0, 158, 222, 255]);
    }

    paint_line(&mut rgba, SIZE, 6.4, 7.2, 9.8, 7.2, 1.3, [25, 70, 132, 245]);
    paint_line(&mut rgba, SIZE, 6.4, 7.2, 6.4, 9.2, 1.3, [25, 70, 132, 245]);
    paint_line(&mut rgba, SIZE, 10.7, 6.2, 14.1, 10.2, 1.3, [25, 70, 132, 245]);
    paint_line(&mut rgba, SIZE, 14.1, 6.2, 10.7, 10.2, 1.3, [25, 70, 132, 245]);

    Image::new_owned(rgba, SIZE, SIZE)
}

fn paint_rounded_rect(
    rgba: &mut [u8],
    size: u32,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    radius: f32,
    color: [u8; 4],
) {
    let left = x0.floor().max(0.0) as i32;
    let top = y0.floor().max(0.0) as i32;
    let right = x1.ceil().min(size as f32) as i32;
    let bottom = y1.ceil().min(size as f32) as i32;
    for y in top..bottom {
        for x in left..right {
            let px = x as f32 + 0.5;
            let py = y as f32 + 0.5;
            let cx = px.clamp(x0 + radius, x1 - radius);
            let cy = py.clamp(y0 + radius, y1 - radius);
            if (px - cx).powi(2) + (py - cy).powi(2) <= radius.powi(2) {
                blend_rgba(rgba, size, x, y, color);
            }
        }
    }
}

fn paint_polyline(rgba: &mut [u8], size: u32, points: &[(f32, f32)], stroke: f32, color: [u8; 4]) {
    for pair in points.windows(2) {
        paint_line(rgba, size, pair[0].0, pair[0].1, pair[1].0, pair[1].1, stroke, color);
    }
}

fn paint_line(
    rgba: &mut [u8],
    size: u32,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    stroke: f32,
    color: [u8; 4],
) {
    let distance = ((x1 - x0).powi(2) + (y1 - y0).powi(2)).sqrt();
    let steps = (distance / (stroke * 0.3).max(0.3)).ceil().max(1.0) as i32;
    for step in 0..=steps {
        let progress = step as f32 / steps as f32;
        paint_circle(
            rgba,
            size,
            x0 + (x1 - x0) * progress,
            y0 + (y1 - y0) * progress,
            stroke / 2.0,
            color,
        );
    }
}

fn paint_circle(rgba: &mut [u8], size: u32, cx: f32, cy: f32, radius: f32, color: [u8; 4]) {
    let left = (cx - radius).floor().max(0.0) as i32;
    let top = (cy - radius).floor().max(0.0) as i32;
    let right = (cx + radius).ceil().min(size as f32) as i32;
    let bottom = (cy + radius).ceil().min(size as f32) as i32;
    let radius_squared = radius.powi(2);
    for y in top..bottom {
        for x in left..right {
            let px = x as f32 + 0.5;
            let py = y as f32 + 0.5;
            if (px - cx).powi(2) + (py - cy).powi(2) <= radius_squared {
                blend_rgba(rgba, size, x, y, color);
            }
        }
    }
}

fn blend_rgba(rgba: &mut [u8], size: u32, x: i32, y: i32, color: [u8; 4]) {
    if x < 0 || y < 0 || x >= size as i32 || y >= size as i32 {
        return;
    }
    let src_alpha = color[3] as f32 / 255.0;
    if src_alpha <= 0.0 {
        return;
    }
    let idx = ((y as u32 * size + x as u32) * 4) as usize;
    let dst_alpha = rgba[idx + 3] as f32 / 255.0;
    let out_alpha = src_alpha + dst_alpha * (1.0 - src_alpha);
    if out_alpha <= 0.0 {
        return;
    }
    for channel in 0..3 {
        let src = color[channel] as f32;
        let dst = rgba[idx + channel] as f32;
        rgba[idx + channel] =
            ((src * src_alpha + dst * dst_alpha * (1.0 - src_alpha)) / out_alpha).round() as u8;
    }
    rgba[idx + 3] = (out_alpha * 255.0).round() as u8;
}

fn create_dashboard_window(app: &tauri::AppHandle) -> tauri::Result<()> {
    if app.get_webview_window("main").is_some() {
        return Ok(());
    }

    let window = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("/index.html".into()))
        .title("Codex Token Bar")
        .icon(taskbar_window_icon())?
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
    let _ = window.set_icon(taskbar_window_icon());
    apply_windows_taskbar_icon(&window);

    Ok(())
}

#[cfg(windows)]
fn apply_windows_taskbar_icon(window: &tauri::WebviewWindow) {
    use std::ptr::null;
    use windows_sys::Win32::{
        System::LibraryLoader::GetModuleHandleW,
        UI::WindowsAndMessaging::{
            LoadImageW, SendMessageW, ICON_BIG, ICON_SMALL, IMAGE_ICON, LR_DEFAULTSIZE, LR_SHARED,
            WM_SETICON,
        },
    };

    let Ok(hwnd) = window.hwnd() else {
        return;
    };

    // Tauri embeds the executable icon as resource 1. Do not use
    // IDI_APPLICATION (32512) here: that asks Windows for the system default
    // application icon and can leave the taskbar showing the old/incorrect art.
    const APPLICATION_ICON_RESOURCE_ID: usize = 1;
    unsafe {
        let module = GetModuleHandleW(null());
        let icon = LoadImageW(
            module,
            APPLICATION_ICON_RESOURCE_ID as *const u16,
            IMAGE_ICON,
            0,
            0,
            LR_DEFAULTSIZE | LR_SHARED,
        );
        if !icon.is_null() {
            SendMessageW(hwnd.0, WM_SETICON, ICON_BIG as usize, icon as isize);
            SendMessageW(hwnd.0, WM_SETICON, ICON_SMALL as usize, icon as isize);
        }
    }
}

#[cfg(not(windows))]
fn apply_windows_taskbar_icon(_window: &tauri::WebviewWindow) {}

fn taskbar_window_icon() -> Image<'static> {
    const SIZE: u32 = 128;
    let mut rgba = vec![0; (SIZE * SIZE * 4) as usize];

    paint_rounded_rect(&mut rgba, SIZE, 7.0, 9.0, 121.0, 120.0, 26.0, [254, 255, 255, 255]);
    paint_rounded_rect(&mut rgba, SIZE, 11.0, 13.0, 117.0, 116.0, 23.0, [234, 246, 255, 46]);
    paint_rounded_rect(&mut rgba, SIZE, 13.0, 16.0, 115.0, 114.0, 22.0, [255, 255, 255, 42]);
    paint_rounded_rect(&mut rgba, SIZE, 14.0, 18.0, 114.0, 113.0, 21.0, [160, 210, 255, 6]);

    for row in 0..6 {
        for col in 0..7 {
            let power = (col as f32 / 6.0) * 0.58 + (row as f32 / 5.0) * 0.42;
            paint_rounded_rect(
                &mut rgba,
                SIZE,
                28.0 + col as f32 * 11.2,
                39.0 + row as f32 * 10.5,
                36.4 + col as f32 * 11.2,
                47.4 + row as f32 * 10.5,
                2.0,
                [
                    (238.0 - 38.0 * power).round() as u8,
                    (248.0 - 30.0 * power).round() as u8,
                    255,
                    (26.0 + 52.0 * power).round() as u8,
                ],
            );
        }
    }

    let points = [
        (18.0, 96.0),
        (35.0, 79.0),
        (48.0, 85.0),
        (65.0, 68.0),
        (79.0, 76.0),
        (94.0, 56.0),
        (108.0, 44.0),
    ];
    paint_polyline(&mut rgba, SIZE, &points, 7.0, [255, 255, 255, 245]);
    paint_polyline(&mut rgba, SIZE, &points, 4.0, [24, 184, 230, 255]);
    for point in points.iter().skip(1) {
        paint_circle(&mut rgba, SIZE, point.0, point.1, 5.5, [255, 255, 255, 246]);
        paint_circle(&mut rgba, SIZE, point.0, point.1, 3.4, [25, 183, 229, 255]);
    }

    paint_line(&mut rgba, SIZE, 24.0, 25.0, 38.0, 25.0, 5.0, [24, 64, 124, 250]);
    paint_line(&mut rgba, SIZE, 24.0, 25.0, 24.0, 34.0, 5.0, [24, 64, 124, 250]);
    paint_line(&mut rgba, SIZE, 45.0, 20.0, 59.0, 38.0, 5.0, [24, 64, 124, 250]);
    paint_line(&mut rgba, SIZE, 59.0, 20.0, 45.0, 38.0, 5.0, [24, 64, 124, 250]);

    Image::new_owned(rgba, SIZE, SIZE)
}

fn create_floating_window(app: &tauri::AppHandle) -> tauri::Result<()> {
    if app.get_webview_window("floating").is_some() {
        return Ok(());
    }

    let builder = WebviewWindowBuilder::new(
        app,
        "floating",
        WebviewUrl::App("/index.html?surface=floating".into()),
    )
    .title("Codex Token Bar Floating");

    #[cfg(target_os = "macos")]
    let builder = builder
        .hidden_title(true)
        .title_bar_style(TitleBarStyle::Overlay);

    let builder = builder
    .inner_size(FLOATING_WINDOW_WIDTH, FLOATING_WINDOW_DEFAULT_HEIGHT)
    .min_inner_size(
        FLOATING_WINDOW_WIDTH * FLOATING_WINDOW_MIN_SCALE,
        FLOATING_WINDOW_MIN_HEIGHT * FLOATING_WINDOW_MIN_SCALE,
    )
    .max_inner_size(
        FLOATING_WINDOW_WIDTH * FLOATING_WINDOW_MAX_SCALE,
        FLOATING_WINDOW_DEFAULT_HEIGHT * FLOATING_WINDOW_MAX_SCALE,
    )
    .position(48.0, 86.0)
    .resizable(false)
    .focused(false)
    .visible(false);

    let window = if cfg!(target_os = "windows") {
        builder
            .decorations(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .shadow(false)
            .transparent(true)
            .build()?
    } else {
        builder
            .decorations(false)
            .always_on_top(true)
            .visible_on_all_workspaces(true)
            .skip_taskbar(true)
            .shadow(false)
            .transparent(true)
            .build()?
    };
    enforce_floating_window_chrome(&window);

    Ok(())
}

fn enforce_floating_window_chrome(window: &WebviewWindow) {
    if let Err(error) = window.set_decorations(false) {
        startup_trace::mark(&format!("floating window set decorations skipped: {error}"));
    }
    if let Err(error) = window.set_shadow(false) {
        startup_trace::mark(&format!("floating window set shadow skipped: {error}"));
    }
    if let Err(error) = window.set_always_on_top(true) {
        startup_trace::mark(&format!("floating window set always-on-top skipped: {error}"));
    }
    if let Err(error) = window.set_skip_taskbar(true) {
        startup_trace::mark(&format!("floating window set skip-taskbar skipped: {error}"));
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn floating_window_height_keeps_swift_protection_without_clipping_default_content() {
        assert_eq!(FLOATING_WINDOW_MIN_HEIGHT, 88.0);
        assert_eq!(FLOATING_WINDOW_DEFAULT_HEIGHT, 112.0);
        assert!(FLOATING_WINDOW_DEFAULT_HEIGHT * FLOATING_WINDOW_MAX_SCALE >= 112.0 * 1.38);
    }
}
