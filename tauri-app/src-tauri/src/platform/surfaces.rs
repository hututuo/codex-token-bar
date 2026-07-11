use crate::core::startup_trace;
use std::{
    sync::{mpsc, Mutex, OnceLock},
    time::Duration,
};
use tauri::{
    async_runtime,
    image::Image,
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    webview::PageLoadEvent,
    Emitter, LogicalSize, Manager, PhysicalPosition, Position, Size, WebviewUrl, WebviewWindow,
    WebviewWindowBuilder,
};
#[cfg(target_os = "macos")]
use tauri::TitleBarStyle;

const FLOATING_WINDOW_WIDTH: f64 = 296.0;
const FLOATING_WINDOW_MIN_HEIGHT: f64 = 88.0;
const FLOATING_WINDOW_DEFAULT_HEIGHT: f64 = 112.0;
const FLOATING_WINDOW_MIN_SCALE: f64 = 0.9;
const FLOATING_WINDOW_MAX_SCALE: f64 = 1.38;
const FLOATING_WINDOW_VISIBILITY_CHANGED_EVENT: &str = "floating-window-visibility-changed";
const DASHBOARD_WINDOW_WIDTH: f64 = 1180.0;
const DASHBOARD_WINDOW_HEIGHT: f64 = 860.0;
const DASHBOARD_WINDOW_MIN_WIDTH: f64 = 960.0;
const DASHBOARD_WINDOW_MIN_HEIGHT: f64 = 720.0;
const STATUS_PANEL_WIDTH: f64 = 336.0;
const STATUS_PANEL_HEIGHT: f64 = 236.0;
const STATUS_TRAY_ID: &str = "codex-token-bar-status";
const STATUS_TRAY_SHOW_DASHBOARD_ID: &str = "status-tray-show-dashboard";
const STATUS_TRAY_QUIT_ID: &str = "status-tray-quit";
const STATUS_PANEL_PRESS_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, Debug, PartialEq)]
struct PhysicalBounds {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
enum StatusPanelAnchor {
    Below,
    Above,
    Left,
    Right,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum StatusPanelToggleAction {
    Show,
    Hide,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct SurfaceSetupStatus {
    pub(crate) floating_window_error: Option<String>,
    pub(crate) status_panel_error: Option<String>,
    pub(crate) status_tray_error: Option<String>,
}

static SURFACE_SETUP_STATUS: OnceLock<Mutex<SurfaceSetupStatus>> = OnceLock::new();
static STATUS_PANEL_INTERACTION: OnceLock<Mutex<StatusPanelInteractionController>> = OnceLock::new();

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct StatusPanelInteractionController {
    next_generation: u64,
    active_press: Option<StatusPanelPress>,
    suppress_orphan_up: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct StatusPanelPress {
    generation: u64,
    started_visible: bool,
    deferred_blur: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum StatusPanelBlurAction {
    HideNow,
    DeferToTrayRelease,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum StatusPanelCancelAction {
    Nothing,
    HideDeferredBlur,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum StatusPanelReleaseAction {
    Toggle(StatusPanelToggleAction),
    Ignore,
}

impl StatusPanelInteractionController {
    fn begin_tray_press(&mut self, panel_visible: bool) -> u64 {
        self.next_generation = self.next_generation.saturating_add(1);
        let generation = self.next_generation;
        self.suppress_orphan_up = false;
        self.active_press = Some(StatusPanelPress {
            generation,
            started_visible: panel_visible,
            deferred_blur: false,
        });
        generation
    }

    fn blur(&mut self) -> StatusPanelBlurAction {
        if let Some(press) = self.active_press.as_mut() {
            press.deferred_blur = true;
            StatusPanelBlurAction::DeferToTrayRelease
        } else {
            StatusPanelBlurAction::HideNow
        }
    }

    fn finish_tray_press(&mut self, panel_visible_now: bool) -> StatusPanelReleaseAction {
        if let Some(press) = self.active_press.take() {
            return StatusPanelReleaseAction::Toggle(status_panel_toggle_action(
                press.started_visible,
            ));
        }
        if self.suppress_orphan_up {
            self.suppress_orphan_up = false;
            return StatusPanelReleaseAction::Ignore;
        }
        StatusPanelReleaseAction::Toggle(status_panel_toggle_action(panel_visible_now))
    }

    fn cancel(&mut self, generation: Option<u64>) -> StatusPanelCancelAction {
        let Some(press) = self.active_press else {
            return StatusPanelCancelAction::Nothing;
        };
        if generation.is_some_and(|generation| generation != press.generation) {
            return StatusPanelCancelAction::Nothing;
        }
        self.active_press = None;
        self.suppress_orphan_up = true;
        if press.deferred_blur {
            StatusPanelCancelAction::HideDeferredBlur
        } else {
            StatusPanelCancelAction::Nothing
        }
    }
}

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

fn status_panel_interaction_cell() -> &'static Mutex<StatusPanelInteractionController> {
    STATUS_PANEL_INTERACTION.get_or_init(|| Mutex::new(StatusPanelInteractionController::default()))
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
    let show_result = window.show().map_err(|error| {
        let message = error.to_string();
        startup_trace::mark(&format!("floating window show failed: {message}"));
        message
    });
    let visible = finish_floating_visibility_change(show_result, true, |visible| {
        publish_floating_window_visibility(app, visible);
    })?;
    if let Err(error) = window.set_always_on_top(true) {
        startup_trace::mark(&format!("floating window always-on-top skipped: {error}"));
    }
    startup_trace::mark("floating window show end");
    Ok(visible)
}

pub fn hide_floating_window(app: &tauri::AppHandle) -> Result<bool, String> {
    let Some(window) = app.get_webview_window("floating") else {
        return Ok(false);
    };
    let hide_result = window.hide().map_err(|error| error.to_string());
    finish_floating_visibility_change(hide_result, false, |visible| {
        publish_floating_window_visibility(app, visible);
    })
}

fn finish_floating_visibility_change(
    operation: Result<(), String>,
    visible: bool,
    publish: impl FnOnce(bool),
) -> Result<bool, String> {
    operation?;
    publish(visible);
    Ok(visible)
}

fn publish_floating_window_visibility(app: &tauri::AppHandle, visible: bool) {
    if let Err(error) = app.emit(FLOATING_WINDOW_VISIBILITY_CHANGED_EVENT, visible) {
        startup_trace::mark(&format!(
            "floating window visibility event skipped: {error}"
        ));
    }
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
    show_status_panel_at_tray(app, None)
}

fn show_status_panel_at_tray(app: &tauri::AppHandle, tray_bounds: Option<PhysicalBounds>) -> Result<bool, String> {
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
    position_status_panel(app, &window, tray_bounds)?;
    window.show().map_err(|error| error.to_string())?;
    window.set_focus().map_err(|error| error.to_string())?;
    Ok(true)
}

fn toggle_status_panel_at_tray(app: &tauri::AppHandle, tray_bounds: PhysicalBounds) -> Result<bool, String> {
    let is_visible = app
        .get_webview_window("status")
        .map(|window| window.is_visible().map_err(|error| error.to_string()))
        .transpose()?
        .unwrap_or(false);
    let release = status_panel_interaction_cell()
        .lock()
        .map(|mut controller| controller.finish_tray_press(is_visible))
        .unwrap_or_else(|_| {
            StatusPanelReleaseAction::Toggle(status_panel_toggle_action(is_visible))
        });
    perform_status_panel_release(
        release,
        || show_status_panel_at_tray(app, Some(tray_bounds)),
        || hide_status_panel_window(app),
    )
}

fn perform_status_panel_release(
    release: StatusPanelReleaseAction,
    show: impl FnOnce() -> Result<bool, String>,
    hide: impl FnOnce() -> Result<bool, String>,
) -> Result<bool, String> {
    match release {
        StatusPanelReleaseAction::Toggle(StatusPanelToggleAction::Show) => show(),
        StatusPanelReleaseAction::Toggle(StatusPanelToggleAction::Hide) => hide(),
        StatusPanelReleaseAction::Ignore => Ok(false),
    }
}

fn status_panel_toggle_action(is_visible: bool) -> StatusPanelToggleAction {
    if is_visible {
        StatusPanelToggleAction::Hide
    } else {
        StatusPanelToggleAction::Show
    }
}

fn position_status_panel(
    app: &tauri::AppHandle,
    window: &WebviewWindow,
    tray_bounds: Option<PhysicalBounds>,
) -> Result<(), String> {
    let tray_monitor = tray_bounds.and_then(|tray| {
        app.monitor_from_point(tray.x + tray.width / 2.0, tray.y + tray.height / 2.0)
            .ok()
            .flatten()
    });
    let usable_tray_bounds = tray_monitor.as_ref().and(tray_bounds);
    let monitor = tray_monitor
        .or_else(|| window.current_monitor().ok().flatten())
        .or_else(|| app.primary_monitor().ok().flatten())
        .ok_or_else(|| "no monitor is available for the status panel".to_string())?;

    let work_area = monitor.work_area();
    let work_bounds = PhysicalBounds {
        x: work_area.position.x as f64,
        y: work_area.position.y as f64,
        width: work_area.size.width as f64,
        height: work_area.size.height as f64,
    };
    let scale_factor = monitor.scale_factor();
    let panel_size = LogicalSize::new(STATUS_PANEL_WIDTH, STATUS_PANEL_HEIGHT).to_physical::<f64>(scale_factor);
    let panel_size = (panel_size.width, panel_size.height);
    let position = if let Some(tray) = usable_tray_bounds {
        status_panel_position(tray, work_bounds, panel_size, status_panel_anchor_for_monitor(&monitor))
    } else {
        safe_status_panel_position(work_bounds, panel_size)
    };
    window
        .set_position(PhysicalPosition::new(
            position.0.round() as i32,
            position.1.round() as i32,
        ))
        .map_err(|error| error.to_string())
}

#[cfg(target_os = "windows")]
fn status_panel_anchor_for_monitor(monitor: &tauri::Monitor) -> StatusPanelAnchor {
    let position = monitor.position();
    let size = monitor.size();
    let work = monitor.work_area();
    let insets = [
        (work.position.y - position.y, StatusPanelAnchor::Below),
        (
            position.y + size.height as i32 - work.position.y - work.size.height as i32,
            StatusPanelAnchor::Above,
        ),
        (work.position.x - position.x, StatusPanelAnchor::Right),
        (
            position.x + size.width as i32 - work.position.x - work.size.width as i32,
            StatusPanelAnchor::Left,
        ),
    ];
    insets
        .into_iter()
        .max_by_key(|(inset, _)| *inset)
        .filter(|(inset, _)| *inset > 0)
        .map(|(_, anchor)| anchor)
        .unwrap_or(StatusPanelAnchor::Below)
}

#[cfg(not(target_os = "windows"))]
fn status_panel_anchor_for_monitor(_monitor: &tauri::Monitor) -> StatusPanelAnchor {
    StatusPanelAnchor::Below
}

fn status_panel_position(
    tray: PhysicalBounds,
    work: PhysicalBounds,
    panel: (f64, f64),
    anchor: StatusPanelAnchor,
) -> (f64, f64) {
    let centered_x = tray.x + (tray.width - panel.0) / 2.0;
    let centered_y = tray.y + (tray.height - panel.1) / 2.0;
    let desired = match anchor {
        StatusPanelAnchor::Below => (centered_x, tray.y + tray.height),
        StatusPanelAnchor::Above => (centered_x, tray.y - panel.1),
        StatusPanelAnchor::Left => (tray.x - panel.0, centered_y),
        StatusPanelAnchor::Right => (tray.x + tray.width, centered_y),
    };
    clamp_status_panel_position(desired, work, panel)
}

fn safe_status_panel_position(work: PhysicalBounds, panel: (f64, f64)) -> (f64, f64) {
    clamp_status_panel_position(
        (
            work.x + (work.width - panel.0) / 2.0,
            work.y + (work.height - panel.1) / 2.0,
        ),
        work,
        panel,
    )
}

fn clamp_status_panel_position(desired: (f64, f64), work: PhysicalBounds, panel: (f64, f64)) -> (f64, f64) {
    let max_x = (work.x + work.width - panel.0).max(work.x);
    let max_y = (work.y + work.height - panel.1).max(work.y);
    (desired.0.clamp(work.x, max_x), desired.1.clamp(work.y, max_y))
}

fn physical_tray_bounds(rect: tauri::Rect, scale_factor: f64) -> PhysicalBounds {
    let position = match rect.position {
        Position::Physical(position) => position.cast::<f64>(),
        Position::Logical(position) => position.to_physical::<f64>(scale_factor),
    };
    let size = match rect.size {
        Size::Physical(size) => size.cast::<f64>(),
        Size::Logical(size) => size.to_physical::<f64>(scale_factor),
    };
    PhysicalBounds {
        x: position.x,
        y: position.y,
        width: size.width,
        height: size.height,
    }
}

pub fn hide_status_panel_window(app: &tauri::AppHandle) -> Result<bool, String> {
    if let Ok(mut controller) = status_panel_interaction_cell().lock() {
        controller.cancel(None);
    }
    hide_status_panel_window_without_cancelling_interaction(app)
}

fn hide_status_panel_window_without_cancelling_interaction(app: &tauri::AppHandle) -> Result<bool, String> {
    let Some(window) = app.get_webview_window("status") else {
        return Ok(false);
    };
    window.hide().map_err(|error| error.to_string())?;
    Ok(false)
}

pub fn dismiss_status_panel_on_blur(app: &tauri::AppHandle) -> Result<bool, String> {
    let action = status_panel_interaction_cell()
        .lock()
        .map(|mut controller| controller.blur())
        .unwrap_or(StatusPanelBlurAction::HideNow);
    match action {
        StatusPanelBlurAction::HideNow => hide_status_panel_window_without_cancelling_interaction(app),
        StatusPanelBlurAction::DeferToTrayRelease => Ok(false),
    }
}

fn cancel_status_panel_press(
    app: &tauri::AppHandle,
    generation: Option<u64>,
) -> Result<bool, String> {
    let action = status_panel_interaction_cell()
        .lock()
        .map(|mut controller| controller.cancel(generation))
        .unwrap_or(StatusPanelCancelAction::Nothing);
    perform_status_panel_cancel(action, || {
        hide_status_panel_window_without_cancelling_interaction(app)
    })
}

fn perform_status_panel_cancel(
    action: StatusPanelCancelAction,
    hide: impl FnOnce() -> Result<bool, String>,
) -> Result<bool, String> {
    match action {
        StatusPanelCancelAction::Nothing => Ok(false),
        StatusPanelCancelAction::HideDeferredBlur => hide(),
    }
}

fn schedule_status_panel_press_timeout(app: tauri::AppHandle, generation: u64) {
    async_runtime::spawn(async move {
        tokio::time::sleep(STATUS_PANEL_PRESS_TIMEOUT).await;
        let _ = cancel_status_panel_press(&app, Some(generation));
    });
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

pub fn set_status_tray_readout_native(
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

    let show_dashboard_item =
        MenuItem::with_id(app, STATUS_TRAY_SHOW_DASHBOARD_ID, "打开主界面", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(app, STATUS_TRAY_QUIT_ID, "退出", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show_dashboard_item, &quit_item])?;

    let mut builder = TrayIconBuilder::with_id(STATUS_TRAY_ID)
        .title("0.0/s")
        .tooltip("Codex Token Bar")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| {
            let event_id = event.id().as_ref();
            if event_id == STATUS_TRAY_SHOW_DASHBOARD_ID {
                let _ = show_dashboard_window(app);
            } else if event_id == STATUS_TRAY_QUIT_ID {
                app.exit(0);
            }
        })
        .on_tray_icon_event(|tray, event| {
            let app = tray.app_handle();
            match event {
                TrayIconEvent::Click {
                    button: MouseButton::Left,
                    button_state: MouseButtonState::Down,
                    ..
                } => {
                    let visible = app
                        .get_webview_window("status")
                        .and_then(|window| window.is_visible().ok())
                        .unwrap_or(false);
                    let generation = status_panel_interaction_cell()
                        .lock()
                        .ok()
                        .map(|mut controller| controller.begin_tray_press(visible));
                    if let Some(generation) = generation {
                        schedule_status_panel_press_timeout(app.clone(), generation);
                    }
                }
                TrayIconEvent::Click {
                    position,
                    rect,
                    button: MouseButton::Left,
                    button_state: MouseButtonState::Up,
                    ..
                } => {
                    let scale_factor = app
                        .monitor_from_point(position.x, position.y)
                        .ok()
                        .flatten()
                        .map(|monitor| monitor.scale_factor())
                        .unwrap_or(1.0);
                    let _ = toggle_status_panel_at_tray(app, physical_tray_bounds(rect, scale_factor));
                }
                TrayIconEvent::Leave { .. } => {
                    let _ = cancel_status_panel_press(app, None);
                }
                _ => {}
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

    #[test]
    fn native_visibility_only_publishes_after_successful_window_operation() {
        let mut published = Vec::new();
        let visible = finish_floating_visibility_change(Ok(()), true, |value| {
            published.push(value);
        })
        .expect("successful show");
        assert!(visible);
        assert_eq!(published, vec![true]);

        let error = finish_floating_visibility_change(
            Err("hide failed".to_string()),
            false,
            |value| published.push(value),
        )
        .expect_err("failed hide");
        assert_eq!(error, "hide failed");
        assert_eq!(published, vec![true]);
    }

    fn bounds(x: f64, y: f64, width: f64, height: f64) -> PhysicalBounds {
        PhysicalBounds { x, y, width, height }
    }

    #[test]
    fn status_panel_supports_all_taskbar_edges() {
        let work = bounds(0.0, 0.0, 1920.0, 1040.0);
        let panel = (336.0, 236.0);
        assert_eq!(
            status_panel_position(bounds(900.0, 0.0, 24.0, 24.0), work, panel, StatusPanelAnchor::Below),
            (744.0, 24.0)
        );
        assert_eq!(
            status_panel_position(bounds(900.0, 1016.0, 24.0, 24.0), work, panel, StatusPanelAnchor::Above),
            (744.0, 780.0)
        );
        assert_eq!(
            status_panel_position(bounds(0.0, 500.0, 24.0, 24.0), work, panel, StatusPanelAnchor::Right),
            (24.0, 394.0)
        );
        assert_eq!(
            status_panel_position(bounds(1896.0, 500.0, 24.0, 24.0), work, panel, StatusPanelAnchor::Left),
            (1560.0, 394.0)
        );
    }

    #[test]
    fn status_panel_clamps_on_negative_multimonitor_work_area() {
        let work = bounds(-1920.0, -120.0, 1920.0, 1080.0);
        assert_eq!(
            status_panel_position(
                bounds(-20.0, -120.0, 20.0, 20.0),
                work,
                (336.0, 236.0),
                StatusPanelAnchor::Below
            ),
            (-336.0, -100.0)
        );
    }

    #[test]
    fn status_panel_uses_physical_panel_size_and_clamps_oversize_panels() {
        let work = bounds(2560.0, 0.0, 2560.0, 1440.0);
        assert_eq!(
            status_panel_position(
                bounds(3800.0, 0.0, 40.0, 40.0),
                work,
                (672.0, 472.0),
                StatusPanelAnchor::Below
            ),
            (3484.0, 40.0)
        );
        assert_eq!(
            safe_status_panel_position(bounds(-800.0, 0.0, 800.0, 600.0), (900.0, 700.0)),
            (-800.0, 0.0)
        );
    }

    #[test]
    fn logical_tray_rect_converts_once_to_physical_pixels() {
        let rect = tauri::Rect {
            position: Position::Logical((10.0, -20.0).into()),
            size: Size::Logical((18.0, 22.0).into()),
        };
        assert_eq!(physical_tray_bounds(rect, 2.0), bounds(20.0, -40.0, 36.0, 44.0));
    }

    #[test]
    fn status_panel_toggle_hides_visible_and_shows_hidden_panel() {
        assert_eq!(status_panel_toggle_action(true), StatusPanelToggleAction::Hide);
        assert_eq!(status_panel_toggle_action(false), StatusPanelToggleAction::Show);
    }

    #[test]
    fn tray_press_defers_blur_and_closes_panel_that_was_visible_at_mouse_down() {
        let mut controller = StatusPanelInteractionController::default();
        let mut panel_visible = true;

        controller.begin_tray_press(panel_visible);
        assert_eq!(controller.blur(), StatusPanelBlurAction::DeferToTrayRelease);
        assert!(panel_visible, "blur must not hide before tray release");

        assert_eq!(
            controller.finish_tray_press(panel_visible),
            StatusPanelReleaseAction::Toggle(StatusPanelToggleAction::Hide)
        );
        panel_visible = false;
        assert!(!panel_visible, "the same tray click must finish hidden");
    }

    #[test]
    fn outside_blur_hides_immediately_and_next_tray_click_reopens() {
        let mut controller = StatusPanelInteractionController::default();
        assert_eq!(controller.blur(), StatusPanelBlurAction::HideNow);

        controller.begin_tray_press(false);
        assert_eq!(
            controller.finish_tray_press(false),
            StatusPanelReleaseAction::Toggle(StatusPanelToggleAction::Show)
        );
    }

    #[test]
    fn deferred_blur_on_leave_without_mouse_up_runs_real_hide_callback() {
        let mut controller = StatusPanelInteractionController::default();
        let generation = controller.begin_tray_press(true);
        assert_eq!(controller.blur(), StatusPanelBlurAction::DeferToTrayRelease);
        let action = controller.cancel(Some(generation));
        let mut hide_calls = 0;

        let hidden = perform_status_panel_cancel(action, || {
            hide_calls += 1;
            Ok(false)
        })
        .unwrap();

        assert!(!hidden);
        assert_eq!(hide_calls, 1);
        let release = controller.finish_tray_press(false);
        let mut show_calls = 0;
        let mut late_hide_calls = 0;
        perform_status_panel_release(
            release,
            || {
                show_calls += 1;
                Ok(true)
            },
            || {
                late_hide_calls += 1;
                Ok(false)
            },
        )
        .unwrap();
        assert_eq!(show_calls, 0, "late Up after Leave must not reopen the panel");
        assert_eq!(late_hide_calls, 0, "ignored late Up must not hide twice");
        assert_eq!(controller.blur(), StatusPanelBlurAction::HideNow);
    }

    #[test]
    fn deferred_blur_on_generation_timeout_hides_panel() {
        let mut controller = StatusPanelInteractionController::default();
        let generation = controller.begin_tray_press(true);
        assert_eq!(controller.blur(), StatusPanelBlurAction::DeferToTrayRelease);
        assert_eq!(
            controller.cancel(Some(generation)),
            StatusPanelCancelAction::HideDeferredBlur
        );
        let release = controller.finish_tray_press(false);
        let mut show_calls = 0;
        let mut hide_calls = 0;
        perform_status_panel_release(
            release,
            || {
                show_calls += 1;
                Ok(true)
            },
            || {
                hide_calls += 1;
                Ok(false)
            },
        )
        .unwrap();
        assert_eq!(show_calls, 0, "late Up after timeout must not reopen the panel");
        assert_eq!(hide_calls, 0, "ignored late Up must not hide twice");
        assert_eq!(controller.blur(), StatusPanelBlurAction::HideNow);
    }

    #[test]
    fn cancellation_without_blur_only_restores_ordinary_blur_behavior() {
        let mut controller = StatusPanelInteractionController::default();
        let generation = controller.begin_tray_press(true);
        assert_eq!(
            controller.cancel(Some(generation)),
            StatusPanelCancelAction::Nothing
        );
        assert_eq!(controller.blur(), StatusPanelBlurAction::HideNow);
    }

    #[test]
    fn stale_timeout_cannot_cancel_a_new_press_or_hide_a_reopened_panel() {
        let mut controller = StatusPanelInteractionController::default();
        let old_generation = controller.begin_tray_press(true);
        assert_eq!(controller.blur(), StatusPanelBlurAction::DeferToTrayRelease);
        let new_generation = controller.begin_tray_press(false);
        assert_eq!(
            controller.cancel(Some(old_generation)),
            StatusPanelCancelAction::Nothing
        );
        let release = controller.finish_tray_press(false);
        let mut show_calls = 0;
        let mut hide_calls = 0;
        perform_status_panel_release(
            release,
            || {
                show_calls += 1;
                Ok(true)
            },
            || {
                hide_calls += 1;
                Ok(false)
            },
        )
        .unwrap();
        assert_eq!(show_calls, 1);
        assert_eq!(hide_calls, 0);
        assert_ne!(old_generation, new_generation);
        assert_eq!(controller.blur(), StatusPanelBlurAction::HideNow);
    }
}
