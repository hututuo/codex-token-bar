use crate::core::startup_trace;
use super::StartupLaunchMode;
use serde::Deserialize;
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::Duration,
};
#[cfg(target_os = "macos")]
use objc2::{rc::Retained, runtime::AnyObject, AnyThread, MainThreadMarker};
#[cfg(target_os = "macos")]
use objc2_app_kit::{
    NSMutableParagraphStyle, NSColor, NSFont, NSFontAttributeName,
    NSFontWeightSemibold, NSForegroundColorAttributeName, NSParagraphStyleAttributeName,
    NSStringDrawing, NSTextAlignment, NSTextTab, NSTextTabOptionKey, NSVariableStatusItemLength,
    NSWindow,
};
#[cfg(target_os = "macos")]
use objc2_foundation::{
    NSArray, NSDictionary, NSMutableAttributedString, NSPoint, NSRange, NSString,
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

const FLOATING_WINDOW_WIDTH: f64 = 288.0;
const FLOATING_WINDOW_MIN_HEIGHT: f64 = 88.0;
const FLOATING_WINDOW_DEFAULT_HEIGHT: f64 = 138.0;
const FLOATING_WINDOW_MIN_SCALE: f64 = 0.9;
const FLOATING_WINDOW_MAX_SCALE: f64 = 1.38;
const FLOATING_WINDOW_VISIBILITY_CHANGED_EVENT: &str = "floating-window-visibility-changed";
const DASHBOARD_WINDOW_WIDTH: f64 = 1180.0;
const DASHBOARD_WINDOW_HEIGHT: f64 = 860.0;
const DASHBOARD_WINDOW_MIN_WIDTH: f64 = 960.0;
const DASHBOARD_WINDOW_MIN_HEIGHT: f64 = 720.0;
const STATUS_PANEL_WIDTH: f64 = 390.0;
const STATUS_PANEL_HEIGHT: f64 = 440.0;
const STATUS_INDICATOR_MIN_WIDTH: f64 = 64.0;
const STATUS_INDICATOR_MAX_WIDTH: f64 = 720.0;
const STATUS_INDICATOR_HEIGHT: f64 = 40.0;
const STATUS_INDICATOR_GAP: f64 = 8.0;
const STATUS_TRAY_ID: &str = "codex-token-bar-status";
const STATUS_TRAY_SHOW_DASHBOARD_ID: &str = "status-tray-show-dashboard";
const STATUS_TRAY_UPDATE_ID: &str = "status-tray-update";
const STATUS_TRAY_QUIT_ID: &str = "status-tray-quit";
const STATUS_PANEL_PRESS_TIMEOUT: Duration = Duration::from_secs(2);
const DASHBOARD_VISIBILITY_WATCHDOG_DELAY: Duration = Duration::from_secs(6);

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
static STATUS_INDICATOR_PRESENTATION: OnceLock<Mutex<StatusIndicatorPresentationController>> =
    OnceLock::new();
static STATUS_INDICATOR_WINDOW_CREATION_SCHEDULED: AtomicBool = AtomicBool::new(false);
static UPDATE_TRAY_FALLBACK_VERSION: OnceLock<Mutex<Option<String>>> = OnceLock::new();
static STATUS_TRAY_LIVE_READOUT: OnceLock<Mutex<StatusTrayReadout>> = OnceLock::new();
static STATUS_TRAY_APPLIED_READOUT: OnceLock<Mutex<Option<StatusTrayReadout>>> = OnceLock::new();

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct StatusTrayLine {
    pub(crate) text: String,
    #[serde(default)]
    pub(crate) secondary: bool,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct StatusTrayColumn {
    pub(crate) top: StatusTrayLine,
    pub(crate) bottom: StatusTrayLine,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct StatusTrayReadout {
    columns: Vec<StatusTrayColumn>,
    title: String,
    tooltip: String,
}

impl Default for StatusTrayReadout {
    fn default() -> Self {
        Self {
            columns: Vec::new(),
            title: String::new(),
            tooltip: "Codex Token Bar".into(),
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum StatusIndicatorMode {
    #[default]
    Hidden,
    Collapsed,
    Expanded,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum StatusIndicatorTransition {
    None,
    Hide,
    Collapse,
    Expand,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum StatusIndicatorNativePresentation {
    Hide,
    Present(StatusIndicatorMode),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct StatusIndicatorHostPlan {
    create_owner: bool,
    presentation: StatusIndicatorNativePresentation,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct StatusIndicatorPresentationController {
    enabled: bool,
    composed_owner_active: bool,
    has_compact_content: bool,
    compact_width: f64,
    mode: StatusIndicatorMode,
    tray_bounds: Option<PhysicalBounds>,
}

impl Default for StatusIndicatorPresentationController {
    fn default() -> Self {
        Self {
            enabled: false,
            composed_owner_active: false,
            has_compact_content: false,
            compact_width: 0.0,
            mode: StatusIndicatorMode::Hidden,
            tray_bounds: None,
        }
    }
}

impl StatusIndicatorPresentationController {
    fn configure(&mut self, enabled: bool, composed_owner_active: bool) -> StatusIndicatorTransition {
        self.enabled = enabled;
        self.composed_owner_active = composed_owner_active;
        if !enabled {
            self.mode = StatusIndicatorMode::Hidden;
            return StatusIndicatorTransition::Hide;
        }
        if self.mode == StatusIndicatorMode::Expanded {
            return StatusIndicatorTransition::None;
        }
        if self.has_compact_content {
            self.mode = StatusIndicatorMode::Collapsed;
            StatusIndicatorTransition::Collapse
        } else {
            self.mode = StatusIndicatorMode::Hidden;
            StatusIndicatorTransition::Hide
        }
    }

    fn publish(&mut self, width: f64) -> StatusIndicatorTransition {
        self.has_compact_content = width.is_finite() && width > 0.0;
        self.compact_width = status_indicator_width(width);
        if !self.enabled || self.mode == StatusIndicatorMode::Expanded {
            return StatusIndicatorTransition::None;
        }
        if self.has_compact_content {
            self.mode = StatusIndicatorMode::Collapsed;
            StatusIndicatorTransition::Collapse
        } else {
            self.mode = StatusIndicatorMode::Hidden;
            StatusIndicatorTransition::Hide
        }
    }

    fn expand(&mut self, tray_bounds: Option<PhysicalBounds>) -> StatusIndicatorTransition {
        if let Some(tray_bounds) = tray_bounds {
            self.tray_bounds = Some(tray_bounds);
        }
        if !self.enabled {
            return StatusIndicatorTransition::None;
        }
        self.mode = StatusIndicatorMode::Expanded;
        StatusIndicatorTransition::Expand
    }

    fn collapse(&mut self) -> StatusIndicatorTransition {
        if !self.enabled || !self.has_compact_content {
            self.mode = StatusIndicatorMode::Hidden;
            return StatusIndicatorTransition::Hide;
        }
        self.mode = StatusIndicatorMode::Collapsed;
        StatusIndicatorTransition::Collapse
    }

    fn remember_tray_bounds(&mut self, tray_bounds: PhysicalBounds) {
        self.tray_bounds = Some(tray_bounds);
    }

    fn detail_open(&self) -> bool {
        self.enabled && self.mode == StatusIndicatorMode::Expanded
    }
}

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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FloatingStartupAction {
    None,
    CreateAndShow,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SurfaceStartupPlan {
    create_dashboard: bool,
    floating: FloatingStartupAction,
}

fn surface_startup_plan(
    mode: StartupLaunchMode,
    floating_enabled: bool,
) -> SurfaceStartupPlan {
    match mode {
        StartupLaunchMode::Manual => SurfaceStartupPlan {
            create_dashboard: true,
            // Never synchronously create a second WebView2 controller during Windows startup.
            // Wry's current Windows controller creation pumps a nested message loop; creating
            // the hidden floating controller here can deadlock the COM STA before Tauri's
            // event loop starts. Floating remains lazy on manual launch.
            floating: FloatingStartupAction::None,
        },
        StartupLaunchMode::Autostart => SurfaceStartupPlan {
            create_dashboard: false,
            floating: if floating_enabled {
                FloatingStartupAction::CreateAndShow
            } else {
                FloatingStartupAction::None
            },
        },
    }
}

fn execute_surface_startup_plan(
    plan: SurfaceStartupPlan,
    create_dashboard: impl FnOnce() -> Result<(), String>,
    create_floating: impl FnOnce() -> Result<(), String>,
    show_floating: impl FnOnce() -> Result<(), String>,
    create_tray: impl FnOnce() -> Result<(), String>,
) -> Result<SurfaceSetupStatus, String> {
    let mut status = SurfaceSetupStatus::default();
    if plan.create_dashboard {
        create_dashboard()?;
    }
    if plan.floating != FloatingStartupAction::None {
        match create_floating() {
            Err(error) => status.floating_window_error = Some(error),
            Ok(()) if plan.floating == FloatingStartupAction::CreateAndShow => {
                if let Err(error) = show_floating() {
                    status.floating_window_error = Some(error);
                }
            }
            Ok(()) => {}
        }
    }
    if let Err(error) = create_tray() {
        status.status_tray_error = Some(error);
    }
    Ok(status)
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

pub fn setup_desktop_surfaces(
    app: &tauri::App,
    mode: StartupLaunchMode,
    floating_enabled: bool,
) -> tauri::Result<()> {
    startup_trace::mark("rust setup start");
    let plan = surface_startup_plan(mode, floating_enabled);

    let status = execute_surface_startup_plan(
        plan,
        || {
            startup_trace::mark("dashboard window create start");
            let result = create_dashboard_window(app.handle()).map_err(|error| error.to_string());
            startup_trace::mark("dashboard window create end");
            result
        },
        || {
            startup_trace::mark("floating setup create start");
            let result = create_floating_window(app.handle()).map_err(|error| error.to_string());
            startup_trace::mark("floating setup create end");
            result
        },
        || show_floating_window(app.handle()).map(|_| ()),
        || {
            startup_trace::mark("status tray create deferred");
            schedule_status_tray_creation(app.handle().clone())
        },
    )
    .map_err(|error| tauri::Error::Io(std::io::Error::other(error)))?;

    if let Some(error) = status.floating_window_error.as_deref() {
        eprintln!("Codex Token Bar: floating window setup failed: {error}");
    }
    if let Some(error) = status.status_tray_error.as_deref() {
        eprintln!("Codex Token Bar: status tray setup failed: {error}");
    }

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

fn status_indicator_presentation_cell() -> &'static Mutex<StatusIndicatorPresentationController> {
    STATUS_INDICATOR_PRESENTATION.get_or_init(|| Mutex::new(StatusIndicatorPresentationController::default()))
}

fn status_indicator_width(width: f64) -> f64 {
    if width.is_finite() && width > 0.0 {
        width.clamp(STATUS_INDICATOR_MIN_WIDTH, STATUS_INDICATOR_MAX_WIDTH)
    } else {
        0.0
    }
}

fn status_indicator_enabled() -> bool {
    status_indicator_presentation_cell().lock().map(|controller| controller.enabled).unwrap_or(false)
}

fn status_indicator_composed_owner_active() -> bool {
    status_indicator_presentation_cell()
        .lock()
        .map(|controller| controller.composed_owner_active)
        .unwrap_or(false)
}

fn compact_status_indicator_enabled() -> bool {
    compact_status_indicator_supported(cfg!(target_os = "windows")) && status_indicator_enabled()
}

fn compact_status_indicator_supported(target_is_windows: bool) -> bool {
    target_is_windows
}

fn status_indicator_native_presentation(
    target_is_windows: bool,
    enabled: bool,
    mode: StatusIndicatorMode,
) -> StatusIndicatorNativePresentation {
    if !compact_status_indicator_supported(target_is_windows)
        || !enabled
        || mode == StatusIndicatorMode::Hidden
    {
        StatusIndicatorNativePresentation::Hide
    } else {
        StatusIndicatorNativePresentation::Present(mode)
    }
}

fn status_indicator_host_plan(
    target_is_windows: bool,
    enabled: bool,
    mode: StatusIndicatorMode,
) -> StatusIndicatorHostPlan {
    StatusIndicatorHostPlan {
        create_owner: enabled,
        presentation: status_indicator_native_presentation(target_is_windows, enabled, mode),
    }
}

pub fn show_floating_window(app: &tauri::AppHandle) -> Result<bool, String> {
    startup_trace::mark("floating window show start");
    if app.get_webview_window("floating").is_none() {
        startup_trace::mark("floating window create start");
        if let Err(error) = create_floating_window(app).map_err(|error| error.to_string()) {
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

pub async fn show_floating_window_from_command(
    app: &tauri::AppHandle,
) -> Result<bool, String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    let app_for_call = app.clone();
    let app_for_window = app.clone();
    startup_trace::mark("floating window main dispatch start");
    app_for_call
        .run_on_main_thread(move || {
            let result = show_floating_window(&app_for_window);
            let _ = tx.send(result);
        })
        .map_err(|error| error.to_string())?;
    startup_trace::mark("floating window main dispatch end");
    rx.await
        .map_err(|_| "悬浮窗主线程操作在完成前被取消".to_string())?
}

pub async fn show_dashboard_window_from_command(
    app: &tauri::AppHandle,
) -> Result<bool, String> {
    dispatch_surface_command(app, "主界面", show_dashboard_window).await
}

pub async fn show_status_panel_window_from_command(
    app: &tauri::AppHandle,
) -> Result<bool, String> {
    dispatch_surface_command(app, "状态面板", show_status_panel_window).await
}

async fn dispatch_surface_command(
    app: &tauri::AppHandle,
    label: &'static str,
    operation: fn(&tauri::AppHandle) -> Result<bool, String>,
) -> Result<bool, String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    let dispatch = app.clone();
    let target = app.clone();
    dispatch
        .run_on_main_thread(move || {
            let _ = tx.send(operation(&target));
        })
        .map_err(|error| error.to_string())?;
    rx.await
        .map_err(|_| format!("{label}主线程操作在完成前被取消"))?
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
    super::startup::perform_dashboard_activation(
        app.get_webview_window("main").is_some(),
        || create_dashboard_window(app).map_err(|error| error.to_string()),
        || {
            app.get_webview_window("main")
                .ok_or_else(|| "dashboard window is not available".to_string())?
                .show()
                .map_err(|error| error.to_string())
        },
        || {
            app.get_webview_window("main")
                .ok_or_else(|| "dashboard window is not available".to_string())?
                .set_focus()
                .map_err(|error| error.to_string())
        },
    )
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
    let tray_bounds = tray_bounds.or_else(|| current_status_tray_bounds(app));
    if compact_status_indicator_enabled() {
        if let Ok(mut controller) = status_indicator_presentation_cell().lock() {
            controller.expand(tray_bounds);
        }
    }
    present_status_panel(app, &window, StatusIndicatorMode::Expanded, tray_bounds)
}

fn toggle_status_panel_at_tray(app: &tauri::AppHandle, tray_bounds: PhysicalBounds) -> Result<bool, String> {
    if let Ok(mut controller) = status_indicator_presentation_cell().lock() {
        controller.remember_tray_bounds(tray_bounds);
    }
    let is_visible = status_panel_open_for_toggle(app)?;
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

fn status_panel_open_for_toggle(app: &tauri::AppHandle) -> Result<bool, String> {
    if compact_status_indicator_enabled() {
        return status_indicator_presentation_cell()
            .lock()
            .map(|controller| controller.detail_open())
            .map_err(|error| error.to_string());
    }
    app.get_webview_window("status")
        .map(|window| window.is_visible().map_err(|error| error.to_string()))
        .transpose()
        .map(|visible| visible.unwrap_or(false))
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
    logical_size: (f64, f64),
    mode: StatusIndicatorMode,
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
    let panel_size = LogicalSize::new(logical_size.0, logical_size.1).to_physical::<f64>(scale_factor);
    let panel_size = (panel_size.width, panel_size.height);
    let anchor = status_panel_anchor_for_monitor(&monitor);
    let position = if let Some(tray) = usable_tray_bounds {
        if mode == StatusIndicatorMode::Collapsed && cfg!(target_os = "windows") {
            status_indicator_position(tray, work_bounds, panel_size, anchor, STATUS_INDICATOR_GAP * scale_factor)
        } else {
            status_panel_position(tray, work_bounds, panel_size, anchor)
        }
    } else if cfg!(target_os = "windows") {
        fallback_status_panel_position(work_bounds, panel_size, anchor)
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

fn present_status_panel(
    app: &tauri::AppHandle,
    window: &WebviewWindow,
    mode: StatusIndicatorMode,
    tray_bounds: Option<PhysicalBounds>,
) -> Result<bool, String> {
    let logical_size = match mode {
        StatusIndicatorMode::Collapsed => {
            let width = status_indicator_presentation_cell()
                .lock()
                .map(|controller| controller.compact_width)
                .unwrap_or(STATUS_INDICATOR_MIN_WIDTH);
            (width, STATUS_INDICATOR_HEIGHT)
        }
        StatusIndicatorMode::Expanded | StatusIndicatorMode::Hidden => (STATUS_PANEL_WIDTH, STATUS_PANEL_HEIGHT),
    };
    window.set_size(LogicalSize::new(logical_size.0, logical_size.1)).map_err(|error| error.to_string())?;
    #[cfg(target_os = "macos")]
    let positioned_natively = if mode == StatusIndicatorMode::Expanded {
        match position_macos_status_panel_at_tray(app, window, logical_size) {
            Ok(positioned) => positioned,
            Err(error) => {
                startup_trace::mark(&format!("native status panel anchor skipped: {error}"));
                false
            }
        }
    } else {
        false
    };
    #[cfg(not(target_os = "macos"))]
    let positioned_natively = false;
    if !positioned_natively {
        position_status_panel(app, window, tray_bounds, logical_size, mode)?;
    }
    window.show().map_err(|error| error.to_string())?;
    if mode == StatusIndicatorMode::Expanded {
        window.set_focus().map_err(|error| error.to_string())?;
        Ok(true)
    } else {
        Ok(false)
    }
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

fn status_indicator_position(
    tray: PhysicalBounds,
    work: PhysicalBounds,
    panel: (f64, f64),
    anchor: StatusPanelAnchor,
    gap: f64,
) -> (f64, f64) {
    let desired = match anchor {
        StatusPanelAnchor::Below => (tray.x - panel.0 - gap, tray.y + tray.height),
        StatusPanelAnchor::Above => (tray.x - panel.0 - gap, tray.y - panel.1),
        StatusPanelAnchor::Left => (tray.x - panel.0, tray.y - panel.1 - gap),
        StatusPanelAnchor::Right => (tray.x + tray.width, tray.y - panel.1 - gap),
    };
    clamp_status_panel_position(desired, work, panel)
}

fn safe_status_panel_position(work: PhysicalBounds, panel: (f64, f64)) -> (f64, f64) {
    clamp_status_panel_position(
        (work.x + work.width - panel.0, work.y),
        work,
        panel,
    )
}

fn macos_status_panel_position(
    tray: PhysicalBounds,
    visible_frame: PhysicalBounds,
    panel: (f64, f64),
) -> (f64, f64) {
    let desired = (
        tray.x + (tray.width - panel.0) / 2.0,
        tray.y - panel.1,
    );
    clamp_status_panel_position(desired, visible_frame, panel)
}

#[cfg(target_os = "macos")]
fn position_macos_status_panel_at_tray(
    app: &tauri::AppHandle,
    window: &WebviewWindow,
    logical_size: (f64, f64),
) -> Result<bool, String> {
    let tray = app
        .tray_by_id(STATUS_TRAY_ID)
        .ok_or_else(|| "status tray is not available".to_string())?;
    let panel_window = window.ns_window().map_err(|error| error.to_string())?;
    if panel_window.is_null() {
        return Err("status panel native window is not available".into());
    }
    let panel_window_address = panel_window as usize;

    tray.with_inner_tray_icon(move |inner| -> Result<bool, String> {
        let mtm = MainThreadMarker::new()
            .ok_or_else(|| "status panel positioning must run on the main thread".to_string())?;
        let status_item = inner
            .ns_status_item()
            .ok_or_else(|| "status item is not available".to_string())?;
        let button = status_item
            .button(mtm)
            .ok_or_else(|| "status item button is not available".to_string())?;
        let tray_window = button
            .window()
            .ok_or_else(|| "status item window is not available".to_string())?;
        let screen = tray_window
            .screen()
            .ok_or_else(|| "status item screen is not available".to_string())?;
        let tray_frame = tray_window.frame();
        let visible = screen.visibleFrame();
        let origin = macos_status_panel_position(
            PhysicalBounds {
                x: tray_frame.origin.x,
                y: tray_frame.origin.y,
                width: tray_frame.size.width,
                height: tray_frame.size.height,
            },
            PhysicalBounds {
                x: visible.origin.x,
                y: visible.origin.y,
                width: visible.size.width,
                height: visible.size.height,
            },
            logical_size,
        );
        let panel_window = unsafe { &*(panel_window_address as *const NSWindow) };
        panel_window.setFrameOrigin(NSPoint::new(origin.0, origin.1));
        Ok(true)
    })
    .map_err(|error| error.to_string())?
}

fn fallback_status_panel_position(work: PhysicalBounds, panel: (f64, f64), anchor: StatusPanelAnchor) -> (f64, f64) {
    // Windows exposes no supported API for reserving an inline text slot inside the notification
    // area. This is a standalone window; it never SetParents into or injects code into Explorer.
    let right = work.x + work.width - panel.0;
    let bottom = work.y + work.height - panel.1;
    let desired = match anchor {
        StatusPanelAnchor::Below => (right, work.y),
        StatusPanelAnchor::Above | StatusPanelAnchor::Left => (right, bottom),
        StatusPanelAnchor::Right => (work.x, bottom),
    };
    clamp_status_panel_position(desired, work, panel)
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

fn current_status_tray_bounds(app: &tauri::AppHandle) -> Option<PhysicalBounds> {
    let rect = app.tray_by_id(STATUS_TRAY_ID)?.rect().ok().flatten()?;
    let scale_factor = match rect.position {
        Position::Physical(position) => app
            .monitor_from_point(position.x as f64, position.y as f64)
            .ok()
            .flatten()
            .map(|monitor| monitor.scale_factor()),
        Position::Logical(_) => app.primary_monitor().ok().flatten().map(|monitor| monitor.scale_factor()),
    }
    .unwrap_or(1.0);
    Some(physical_tray_bounds(rect, scale_factor))
}

pub fn hide_status_panel_window(app: &tauri::AppHandle) -> Result<bool, String> {
    if let Ok(mut controller) = status_panel_interaction_cell().lock() {
        controller.cancel(None);
    }
    hide_status_panel_window_without_cancelling_interaction(app)
}

fn hide_status_panel_window_without_cancelling_interaction(app: &tauri::AppHandle) -> Result<bool, String> {
    if compact_status_indicator_enabled() {
        return collapse_status_panel_window(app);
    }
    force_hide_status_panel_window(app)
}

fn collapse_status_panel_window(app: &tauri::AppHandle) -> Result<bool, String> {
    let (transition, tray_bounds) = status_indicator_presentation_cell()
        .lock()
        .map(|mut controller| {
            let transition = controller.collapse();
            (transition, controller.tray_bounds)
        })
        .map_err(|error| error.to_string())?;
    if transition != StatusIndicatorTransition::Collapse {
        return force_hide_status_panel_window(app);
    }
    let Some(window) = app.get_webview_window("status") else {
        return Ok(false);
    };
    present_status_panel(
        app,
        &window,
        StatusIndicatorMode::Collapsed,
        tray_bounds.or_else(|| current_status_tray_bounds(app)),
    )
}

fn force_hide_status_panel_window(app: &tauri::AppHandle) -> Result<bool, String> {
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

fn schedule_dashboard_show(app: tauri::AppHandle) {
    async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_millis(1)).await;
        let dispatch = app.clone();
        let dashboard = app.clone();
        if let Err(error) = dispatch.run_on_main_thread(move || {
            if let Err(error) = show_dashboard_window(&dashboard) {
                startup_trace::mark(&format!("deferred dashboard show failed: {error}"));
            }
        }) {
            startup_trace::mark(&format!("deferred dashboard dispatch failed: {error}"));
        }
    });
}

fn schedule_status_panel_toggle(app: tauri::AppHandle, tray_bounds: PhysicalBounds) {
    async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_millis(1)).await;
        let dispatch = app.clone();
        let status_app = app.clone();
        if let Err(error) = dispatch.run_on_main_thread(move || {
            if let Err(error) = toggle_status_panel_at_tray(&status_app, tray_bounds) {
                startup_trace::mark(&format!("deferred status panel toggle failed: {error}"));
            }
        }) {
            startup_trace::mark(&format!("deferred status panel dispatch failed: {error}"));
        }
    });
}

pub fn set_status_tray_readout_native(
    app: &tauri::AppHandle,
    title: String,
    tooltip: String,
) -> Result<bool, String> {
    if status_indicator_composed_owner_active() {
        return Ok(true);
    }
    let readout = StatusTrayReadout {
        columns: Vec::new(),
        title,
        tooltip,
    };
    cache_status_tray_readout(readout.clone());
    apply_status_tray_readout(app, readout)
}

pub fn set_status_indicator_enabled_native(
    app: &tauri::AppHandle,
    enabled: bool,
    composed_owner_active: bool,
) -> Result<(), String> {
    let (transition, mode) = status_indicator_presentation_cell()
        .lock()
        .map(|mut controller| {
            let transition = controller.configure(enabled, composed_owner_active);
            (transition, controller.mode)
        })
        .map_err(|error| error.to_string())?;
    let host_plan = status_indicator_host_plan(cfg!(target_os = "windows"), enabled, mode);
    if host_plan.create_owner {
        // The hidden status WebView remains the composed readout owner on every platform.
        // Only Windows is allowed to present that owner as a compact taskbar-adjacent strip.
        schedule_status_indicator_window_creation(app.clone())?;
        let readout = cached_status_tray_readout();
        let _ = apply_status_tray_readout(app, readout)?;
    } else {
        let _ = apply_status_tray_readout(app, StatusTrayReadout::default())?;
    }
    if transition != StatusIndicatorTransition::None {
        dispatch_status_indicator_window_operation(app, "configuration", |app| {
            reconcile_status_indicator_window(app)
        })?;
    }
    Ok(())
}

pub async fn publish_status_indicator_readout_native(
    app: &tauri::AppHandle,
    title: String,
    tooltip: String,
    width: f64,
    columns: Vec<StatusTrayColumn>,
) -> Result<bool, String> {
    let readout = StatusTrayReadout {
        columns,
        title,
        tooltip,
    };
    cache_status_tray_readout(readout.clone());
    let transition = status_indicator_presentation_cell()
        .lock()
        .map(|mut controller| controller.publish(width))
        .map_err(|error| error.to_string())?;
    if !status_indicator_enabled() {
        return Ok(false);
    }
    let tray_updated = apply_status_tray_readout_and_wait(app, readout).await?;
    let window_updated = if cfg!(target_os = "windows") && transition != StatusIndicatorTransition::None {
        dispatch_status_indicator_window_operation_and_wait(app, "compact readout", |app| {
            reconcile_status_indicator_window(app)
        })
        .await?
    } else {
        false
    };
    Ok(tray_updated || window_updated)
}

fn apply_status_tray_readout(app: &tauri::AppHandle, readout: StatusTrayReadout) -> Result<bool, String> {
    if app.tray_by_id(STATUS_TRAY_ID).is_none() {
        return Ok(false);
    }
    let update_version = update_tray_fallback_version().lock().ok().and_then(|version| version.clone());
    let readout = status_tray_readout_with_update(readout, update_version.as_deref());
    let changed = status_tray_applied_readout()
        .lock()
        .map(|applied| applied.as_ref() != Some(&readout))
        .unwrap_or(true);
    if !changed {
        return Ok(true);
    }
    dispatch_status_tray_operation(app, "status readout", move |app| {
        apply_status_tray_readout_now(app, readout)
    })
}

async fn apply_status_tray_readout_and_wait(
    app: &tauri::AppHandle,
    readout: StatusTrayReadout,
) -> Result<bool, String> {
    if app.tray_by_id(STATUS_TRAY_ID).is_none() {
        return Ok(false);
    }
    let update_version = update_tray_fallback_version()
        .lock()
        .ok()
        .and_then(|version| version.clone());
    let readout = status_tray_readout_with_update(readout, update_version.as_deref());
    let changed = status_tray_applied_readout()
        .lock()
        .map(|applied| applied.as_ref() != Some(&readout))
        .unwrap_or(true);
    if !changed {
        return Ok(true);
    }
    dispatch_status_tray_operation_and_wait(app, "status readout", move |app| {
        apply_status_tray_readout_now(app, readout)
    })
    .await
}

fn apply_status_tray_readout_now(
    app: &tauri::AppHandle,
    readout: StatusTrayReadout,
) -> Result<(), String> {
    let tray = app
        .tray_by_id(STATUS_TRAY_ID)
        .ok_or_else(|| "status tray is not available".to_string())?;
    #[cfg(target_os = "macos")]
    apply_macos_status_tray_title(&tray, &readout)?;
    tray.set_tooltip(Some(readout.tooltip.clone()))
        .map_err(|error| error.to_string())?;
    if let Ok(mut applied) = status_tray_applied_readout().lock() {
        *applied = Some(readout);
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn apply_macos_status_tray_title<R: tauri::Runtime>(
    tray: &tauri::tray::TrayIcon<R>,
    readout: &StatusTrayReadout,
) -> Result<(), String> {
    if readout.columns.is_empty() {
        return tray
            .set_title(Some(readout.title.clone()))
            .map_err(|error| error.to_string());
    }

    let columns = readout.columns.clone();
    tray.with_inner_tray_icon(move |inner| -> Result<(), String> {
        let mtm = MainThreadMarker::new()
            .ok_or_else(|| "status tray title must be updated on the main thread".to_string())?;
        let status_item = inner
            .ns_status_item()
            .ok_or_else(|| "status item is not available".to_string())?;
        let button = status_item
            .button(mtm)
            .ok_or_else(|| "status item button is not available".to_string())?;
        let attributed_title = macos_status_tray_attributed_title(&columns);
        button.setAttributedTitle(&attributed_title);
        status_item.setLength(NSVariableStatusItemLength);
        Ok(())
    })
    .map_err(|error| error.to_string())?
}

#[cfg(target_os = "macos")]
const MACOS_STATUS_TRAY_FONT_SIZE: f64 = 8.75;
#[cfg(target_os = "macos")]
const MACOS_STATUS_TRAY_LINE_SPACING: f64 = -1.0;
#[cfg(target_os = "macos")]
const MACOS_STATUS_TRAY_COLUMN_SPACING: f64 = 6.0;

#[cfg(target_os = "macos")]
fn macos_status_tray_attributed_title(
    columns: &[StatusTrayColumn],
) -> Retained<NSMutableAttributedString> {
    let semibold_weight = unsafe { NSFontWeightSemibold };
    let font = NSFont::monospacedSystemFontOfSize_weight(
        MACOS_STATUS_TRAY_FONT_SIZE,
        semibold_weight,
    );
    let primary_color = NSColor::controlTextColor();
    let secondary_color = NSColor::secondaryLabelColor();
    let result = NSMutableAttributedString::from_nsstring(&NSString::from_str(""));
    if columns.is_empty() {
        return result;
    }
    macos_append_status_row(
        &result,
        columns,
        true,
        &font,
        &primary_color,
        &secondary_color,
    );
    macos_append_status_piece(&result, "\n", &font, &primary_color);
    macos_append_status_row(
        &result,
        columns,
        false,
        &font,
        &primary_color,
        &secondary_color,
    );
    let range = NSRange::new(0, result.length());

    let paragraph = NSMutableParagraphStyle::new();
    paragraph.setAlignment(NSTextAlignment::Left);
    paragraph.setLineSpacing(MACOS_STATUS_TRAY_LINE_SPACING);
    let options = NSDictionary::<NSTextTabOptionKey, AnyObject>::new();
    let tab_stops = macos_status_tray_column_starts(columns, &font)
        .into_iter()
        .skip(1)
        .map(|location| unsafe {
            NSTextTab::initWithTextAlignment_location_options(
                NSTextTab::alloc(),
                NSTextAlignment::Left,
                location,
                &options,
            )
        })
        .collect::<Vec<_>>();
    let tab_stops = NSArray::from_retained_slice(&tab_stops);
    paragraph.setTabStops(Some(&tab_stops));
    let paragraph_object: &AnyObject = paragraph.as_ref();

    unsafe {
        result.addAttribute_value_range(
            NSParagraphStyleAttributeName,
            paragraph_object,
            range,
        );
    }

    result
}

#[cfg(target_os = "macos")]
fn macos_append_status_row(
    result: &NSMutableAttributedString,
    columns: &[StatusTrayColumn],
    top: bool,
    font: &NSFont,
    primary_color: &NSColor,
    secondary_color: &NSColor,
) {
    for (index, column) in columns.iter().enumerate() {
        if index > 0 {
            macos_append_status_piece(result, "\t", font, primary_color);
        }
        let line = if top { &column.top } else { &column.bottom };
        let rendered = if line.text.is_empty() {
            "\u{200B}"
        } else {
            line.text.as_str()
        };
        let color = if line.secondary {
            secondary_color
        } else {
            primary_color
        };
        macos_append_status_piece(result, rendered, font, color);
    }
}

#[cfg(target_os = "macos")]
fn macos_append_status_piece(
    result: &NSMutableAttributedString,
    text: &str,
    font: &NSFont,
    color: &NSColor,
) {
    let piece = NSMutableAttributedString::from_nsstring(&NSString::from_str(text));
    let range = NSRange::new(0, piece.length());
    let font_object: &AnyObject = font.as_ref();
    let color_object: &AnyObject = color.as_ref();
    unsafe {
        piece.addAttribute_value_range(NSFontAttributeName, font_object, range);
        piece.addAttribute_value_range(NSForegroundColorAttributeName, color_object, range);
    }
    result.appendAttributedString(&piece);
}

#[cfg(target_os = "macos")]
fn macos_status_tray_column_starts(columns: &[StatusTrayColumn], font: &NSFont) -> Vec<f64> {
    if columns.is_empty() {
        return Vec::new();
    }
    let mut starts = vec![0.0];
    let mut next_start = 0.0;
    for column in columns.iter().take(columns.len() - 1) {
        let top_width = macos_status_line_width(&column.top.text, font);
        let bottom_width = macos_status_line_width(&column.bottom.text, font);
        next_start += top_width.max(bottom_width) + MACOS_STATUS_TRAY_COLUMN_SPACING;
        starts.push(next_start);
    }
    starts
}

#[cfg(target_os = "macos")]
fn macos_status_line_width(text: &str, font: &NSFont) -> f64 {
    if text.is_empty() {
        return 0.0;
    }
    let text = NSString::from_str(text);
    let font_object: &AnyObject = font.as_ref();
    let font_attribute_name = unsafe { NSFontAttributeName };
    let attributes = NSDictionary::from_slices(&[font_attribute_name], &[font_object]);
    unsafe { text.sizeWithAttributes(Some(&attributes)).width }
}

pub fn set_update_available_tray_fallback(app: &tauri::AppHandle, version: &str) -> Result<bool, String> {
    if let Ok(mut cached) = update_tray_fallback_version().lock() {
        *cached = Some(version.to_string());
    }
    let live_readout = visible_status_tray_readout();
    let version = version.to_string();
    let readout = status_tray_readout_with_update(live_readout, Some(&version));
    dispatch_status_tray_operation(app, "update available", move |app| {
        apply_status_tray_readout_now(app, readout)?;
        let Some(tray) = app.tray_by_id(STATUS_TRAY_ID) else {
            return Ok(());
        };
        tray.set_icon(Some(status_tray_update_icon())).map_err(|error| error.to_string())?;
        let menu = status_tray_menu(app, Some(&version)).map_err(|error| error.to_string())?;
        tray.set_menu(Some(menu)).map_err(|error| error.to_string())?;
        Ok(())
    })
}

pub fn clear_update_available_tray_fallback(app: &tauri::AppHandle) -> Result<bool, String> {
    if let Ok(mut cached) = update_tray_fallback_version().lock() { *cached = None; }
    let live_readout = visible_status_tray_readout();
    dispatch_status_tray_operation(app, "clear update", move |app| {
        apply_status_tray_readout_now(app, live_readout)?;
        let Some(tray) = app.tray_by_id(STATUS_TRAY_ID) else {
            return Ok(());
        };
        tray.set_icon(Some(status_tray_icon())).map_err(|error| error.to_string())?;
        let menu = status_tray_menu(app, None).map_err(|error| error.to_string())?;
        tray.set_menu(Some(menu)).map_err(|error| error.to_string())?;
        Ok(())
    })
}

fn dispatch_status_tray_operation(
    app: &tauri::AppHandle,
    label: &'static str,
    operation: impl FnOnce(&tauri::AppHandle) -> Result<(), String> + Send + 'static,
) -> Result<bool, String> {
    if app.tray_by_id(STATUS_TRAY_ID).is_none() {
        return Ok(false);
    }
    let dispatch = app.clone();
    let tray_app = app.clone();
    dispatch
        .run_on_main_thread(move || {
            if let Err(error) = operation(&tray_app) {
                startup_trace::mark(&format!("status tray {label} failed: {error}"));
                eprintln!("Codex Token Bar: status tray {label} failed: {error}");
            }
        })
        .map_err(|error| error.to_string())?;
    Ok(true)
}

async fn dispatch_status_tray_operation_and_wait(
    app: &tauri::AppHandle,
    label: &'static str,
    operation: impl FnOnce(&tauri::AppHandle) -> Result<(), String> + Send + 'static,
) -> Result<bool, String> {
    if app.tray_by_id(STATUS_TRAY_ID).is_none() {
        return Ok(false);
    }
    let (tx, rx) = tokio::sync::oneshot::channel();
    let dispatch = app.clone();
    let tray_app = app.clone();
    dispatch
        .run_on_main_thread(move || {
            let result = operation(&tray_app);
            if let Err(error) = &result {
                startup_trace::mark(&format!("status tray {label} failed: {error}"));
                eprintln!("Codex Token Bar: status tray {label} failed: {error}");
            }
            let _ = tx.send(result);
        })
        .map_err(|error| error.to_string())?;
    await_status_operation_result(
        rx,
        format!("status tray {label} main-thread operation was cancelled"),
    )
    .await?;
    Ok(true)
}

fn dispatch_status_indicator_window_operation(
    app: &tauri::AppHandle,
    label: &'static str,
    operation: impl FnOnce(&tauri::AppHandle) -> Result<bool, String> + Send + 'static,
) -> Result<bool, String> {
    if app.get_webview_window("status").is_none() {
        return Ok(false);
    }
    let dispatch = app.clone();
    let status_app = app.clone();
    dispatch
        .run_on_main_thread(move || {
            if let Err(error) = operation(&status_app) {
                startup_trace::mark(&format!("status indicator {label} failed: {error}"));
                eprintln!("Codex Token Bar: status indicator {label} failed: {error}");
            }
        })
        .map_err(|error| error.to_string())?;
    Ok(true)
}

async fn dispatch_status_indicator_window_operation_and_wait(
    app: &tauri::AppHandle,
    label: &'static str,
    operation: impl FnOnce(&tauri::AppHandle) -> Result<bool, String> + Send + 'static,
) -> Result<bool, String> {
    if app.get_webview_window("status").is_none() {
        return Ok(false);
    }
    let (tx, rx) = tokio::sync::oneshot::channel();
    let dispatch = app.clone();
    let status_app = app.clone();
    dispatch
        .run_on_main_thread(move || {
            let result = operation(&status_app);
            if let Err(error) = &result {
                startup_trace::mark(&format!("status indicator {label} failed: {error}"));
                eprintln!("Codex Token Bar: status indicator {label} failed: {error}");
            }
            let _ = tx.send(result);
        })
        .map_err(|error| error.to_string())?;
    await_status_operation_result(
        rx,
        format!("status indicator {label} main-thread operation was cancelled"),
    )
    .await
}

async fn await_status_operation_result<T>(
    receiver: tokio::sync::oneshot::Receiver<Result<T, String>>,
    cancellation_error: String,
) -> Result<T, String> {
    receiver.await.map_err(|_| cancellation_error)?
}

fn reconcile_status_indicator_window(app: &tauri::AppHandle) -> Result<bool, String> {
    let (enabled, mode, tray_bounds) = status_indicator_presentation_cell()
        .lock()
        .map(|controller| (controller.enabled, controller.mode, controller.tray_bounds))
        .map_err(|error| error.to_string())?;
    let host_plan = status_indicator_host_plan(cfg!(target_os = "windows"), enabled, mode);
    match host_plan.presentation {
        StatusIndicatorNativePresentation::Hide => {
            // macOS publishes the composed menu-bar text from this hidden owner. Never expose
            // its collapsed 40 pt rendering; the tray click presents the full summary directly.
            return force_hide_status_panel_window(app);
        }
        StatusIndicatorNativePresentation::Present(mode) => {
            let Some(window) = app.get_webview_window("status") else {
                return Ok(false);
            };
            return present_status_panel(
                app,
                &window,
                mode,
                tray_bounds.or_else(|| current_status_tray_bounds(app)),
            );
        }
    }
}

fn schedule_status_indicator_window_creation(app: tauri::AppHandle) -> Result<(), String> {
    if app.get_webview_window("status").is_some()
        || STATUS_INDICATOR_WINDOW_CREATION_SCHEDULED.swap(true, Ordering::AcqRel)
    {
        return Ok(());
    }
    async_runtime::spawn(async move {
        // Always defer the second WebView. Synchronous WebView2 creation from Builder::setup
        // can deadlock the Windows COM STA before Tauri's event loop starts.
        tokio::time::sleep(Duration::from_millis(1)).await;
        let dispatch = app.clone();
        let status_app = app.clone();
        if let Err(error) = dispatch.run_on_main_thread(move || {
            STATUS_INDICATOR_WINDOW_CREATION_SCHEDULED.store(false, Ordering::Release);
            if !status_indicator_enabled() || status_app.get_webview_window("status").is_some() {
                return;
            }
            match create_status_panel_window(&status_app) {
                Ok(()) => {
                    set_status_panel_error(None);
                    if let Err(error) = reconcile_status_indicator_window(&status_app) {
                        set_status_panel_error(Some(error.clone()));
                        eprintln!(
                            "Codex Token Bar: deferred status indicator presentation failed: {error}"
                        );
                    }
                }
                Err(error) => {
                    let error = error.to_string();
                    set_status_panel_error(Some(error.clone()));
                    eprintln!("Codex Token Bar: deferred status indicator window setup failed: {error}");
                }
            }
        }) {
            STATUS_INDICATOR_WINDOW_CREATION_SCHEDULED.store(false, Ordering::Release);
            set_status_panel_error(Some(error.to_string()));
        }
    });
    Ok(())
}

fn schedule_status_tray_creation(app: tauri::AppHandle) -> Result<(), String> {
    async_runtime::spawn(async move {
        // Ensure Builder::setup has returned before any native tray API is called.
        // On Windows those APIs share the UI/COM thread with WebView2 creation.
        tokio::time::sleep(Duration::from_millis(1)).await;
        let dispatch = app.clone();
        let tray_app = app.clone();
        if let Err(error) = dispatch.run_on_main_thread(move || {
            startup_trace::mark("status tray create start");
            let result = create_status_tray(&tray_app).map_err(|error| error.to_string());
            match result {
                Ok(()) => set_status_tray_error(None),
                Err(error) => {
                    startup_trace::mark(&format!("status tray create failed: {error}"));
                    set_status_tray_error(Some(error.clone()));
                    eprintln!("Codex Token Bar: status tray setup failed: {error}");
                }
            }
            startup_trace::mark("status tray create end");
        }) {
            let error = error.to_string();
            set_status_tray_error(Some(error.clone()));
            startup_trace::mark(&format!("status tray create dispatch failed: {error}"));
            eprintln!("Codex Token Bar: status tray setup dispatch failed: {error}");
        }
    });
    Ok(())
}

fn set_status_tray_error(error: Option<String>) {
    if let Ok(mut status) = surface_setup_status_cell().lock() {
        status.status_tray_error = error;
    }
}

fn update_tray_fallback_version() -> &'static Mutex<Option<String>> {
    UPDATE_TRAY_FALLBACK_VERSION.get_or_init(|| Mutex::new(None))
}

fn status_tray_live_readout() -> &'static Mutex<StatusTrayReadout> {
    STATUS_TRAY_LIVE_READOUT.get_or_init(|| Mutex::new(StatusTrayReadout::default()))
}

fn cache_status_tray_readout(readout: StatusTrayReadout) {
    if let Ok(mut cached) = status_tray_live_readout().lock() {
        *cached = readout;
    }
}

fn cached_status_tray_readout() -> StatusTrayReadout {
    status_tray_live_readout()
        .lock()
        .map(|readout| readout.clone())
        .unwrap_or_default()
}

fn visible_status_tray_readout() -> StatusTrayReadout {
    if status_indicator_composed_owner_active() && !status_indicator_enabled() {
        StatusTrayReadout::default()
    } else {
        cached_status_tray_readout()
    }
}

fn status_tray_applied_readout() -> &'static Mutex<Option<StatusTrayReadout>> {
    STATUS_TRAY_APPLIED_READOUT.get_or_init(|| Mutex::new(None))
}

fn status_tray_title(live_title: &str, update_version: Option<&str>) -> String {
    update_version
        .map(|version| if live_title.is_empty() { format!("↑v{version}") } else { format!("{live_title} ↑v{version}") })
        .unwrap_or_else(|| live_title.to_string())
}

fn status_tray_readout_with_update(readout: StatusTrayReadout, update_version: Option<&str>) -> StatusTrayReadout {
    let mut columns = readout.columns;
    if let Some(version) = update_version {
        columns.push(StatusTrayColumn {
            top: StatusTrayLine {
                text: "↑".into(),
                secondary: false,
            },
            bottom: StatusTrayLine {
                text: format!("v{version}"),
                secondary: true,
            },
        });
    }
    let title = status_tray_title(&readout.title, update_version);
    let tooltip = update_version
        .map(|version| {
            if readout.tooltip.is_empty() {
                format!("有新版本 v{version}，打开主界面安装")
            } else {
                format!("{} · 有新版本 v{version}，打开主界面安装", readout.tooltip)
            }
        })
        .unwrap_or(readout.tooltip);
    StatusTrayReadout {
        columns,
        title,
        tooltip,
    }
}

fn create_status_tray(app: &tauri::AppHandle) -> tauri::Result<()> {
    if app.tray_by_id(STATUS_TRAY_ID).is_some() {
        return Ok(());
    }

    let update_version = update_tray_fallback_version()
        .lock()
        .ok()
        .and_then(|version| version.clone());
    let readout = status_tray_readout_with_update(
        visible_status_tray_readout(),
        update_version.as_deref(),
    );
    let menu = status_tray_menu(app, update_version.as_deref())?;

    let mut builder = TrayIconBuilder::with_id(STATUS_TRAY_ID)
        .title(readout.title.clone())
        .tooltip(readout.tooltip.clone())
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| {
            let event_id = event.id().as_ref();
            if event_id == STATUS_TRAY_SHOW_DASHBOARD_ID || event_id == STATUS_TRAY_UPDATE_ID {
                schedule_dashboard_show(app.clone());
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
                    let visible = status_panel_open_for_toggle(app).unwrap_or(false);
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
                    schedule_status_panel_toggle(
                        app.clone(),
                        physical_tray_bounds(rect, scale_factor),
                    );
                }
                TrayIconEvent::Leave { .. } => {
                    let _ = cancel_status_panel_press(app, None);
                }
                _ => {}
            }
        });

    builder = builder.icon(if update_version.is_some() {
        status_tray_update_icon()
    } else {
        status_tray_icon()
    });

    builder.build(app)?;
    apply_status_tray_readout_now(app, readout).map_err(|error| std::io::Error::other(error))?;

    Ok(())
}

fn status_tray_menu<R: tauri::Runtime, M: Manager<R>>(app: &M, update: Option<&str>) -> tauri::Result<Menu<R>> {
    let update_item = MenuItem::with_id(
        app,
        STATUS_TRAY_UPDATE_ID,
        update.map(|version| format!("发现新版本 v{version} · 打开主界面安装")).unwrap_or_else(|| "暂无可用更新".into()),
        update.is_some(),
        None::<&str>,
    )?;
    let show_dashboard_item = MenuItem::with_id(app, STATUS_TRAY_SHOW_DASHBOARD_ID, "打开主界面", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(app, STATUS_TRAY_QUIT_ID, "退出", true, None::<&str>)?;
    Menu::with_items(app, &[&update_item, &show_dashboard_item, &quit_item])
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

fn status_tray_update_icon() -> Image<'static> {
    let image = status_tray_icon();
    let mut rgba = image.rgba().to_vec();
    const SIZE: u32 = 32;
    for y in 1..11 {
        for x in 21..31 {
            let dx = x as f32 - 26.0;
            let dy = y as f32 - 6.0;
            if dx * dx + dy * dy <= 25.0 {
                let offset = ((y * SIZE + x) * 4) as usize;
                rgba[offset..offset + 4].copy_from_slice(&[255, 72, 72, 255]);
            }
        }
    }
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

    let page_presented = Arc::new(AtomicBool::new(false));
    let page_presented_on_load = Arc::clone(&page_presented);
    let builder = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("/index.html".into()))
        .title("Codex Token Bar")
        .icon(taskbar_window_icon())?
        .inner_size(DASHBOARD_WINDOW_WIDTH, DASHBOARD_WINDOW_HEIGHT)
        .min_inner_size(DASHBOARD_WINDOW_MIN_WIDTH, DASHBOARD_WINDOW_MIN_HEIGHT)
        .resizable(true)
        .center()
        .visible(false)
        .on_page_load(move |window, payload| {
            if matches!(payload.event(), PageLoadEvent::Finished) {
                page_presented_on_load.store(true, Ordering::Release);
                startup_trace::mark("dashboard page load finished");
                let _ = window.set_title("Codex Token Bar");
                if let Err(error) = window.show() {
                    startup_trace::mark(&format!("dashboard page load show failed: {error}"));
                    return;
                }
                if let Err(error) = window.set_focus() {
                    startup_trace::mark(&format!("dashboard page load focus failed: {error}"));
                }
                startup_trace::mark("dashboard window shown after page load");
            }
        });
    #[cfg(target_os = "windows")]
    let webview_attempt = begin_windows_webview_creation("main");
    #[cfg(target_os = "windows")]
    let builder = apply_windows_webview_data_directory(builder, webview_attempt.as_ref());
    let window_result = builder.build();
    #[cfg(target_os = "windows")]
    finish_windows_webview_creation("main", webview_attempt.as_ref(), window_result.is_ok());
    let window = window_result?;
    let _ = window.set_icon(taskbar_window_icon());
    apply_windows_taskbar_icon(&window);
    schedule_dashboard_visibility_watchdog(app.clone(), page_presented);

    Ok(())
}

fn schedule_dashboard_visibility_watchdog(
    app: tauri::AppHandle,
    page_presented: Arc<AtomicBool>,
) {
    async_runtime::spawn(async move {
        tokio::time::sleep(DASHBOARD_VISIBILITY_WATCHDOG_DELAY).await;
        if page_presented.load(Ordering::Acquire) {
            return;
        }
        let dispatch = app.clone();
        let dashboard = app.clone();
        if let Err(error) = dispatch.run_on_main_thread(move || {
            if page_presented.swap(true, Ordering::AcqRel) {
                return;
            }
            let Some(window) = dashboard.get_webview_window("main") else {
                return;
            };
            startup_trace::mark("dashboard visibility watchdog fired");
            let _ = window.set_title("Codex Token Bar · 页面加载超时");
            if let Err(error) = window.show() {
                startup_trace::mark(&format!(
                    "dashboard visibility watchdog show failed: {error}"
                ));
            }
        }) {
            startup_trace::mark(&format!(
                "dashboard visibility watchdog dispatch failed: {error}"
            ));
        }
    });
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

    #[cfg(target_os = "windows")]
    let webview_attempt = begin_windows_webview_creation("floating");
    #[cfg(target_os = "windows")]
    let builder = apply_windows_webview_data_directory(builder, webview_attempt.as_ref());
    let window_result = if cfg!(target_os = "windows") {
        builder
            .decorations(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .shadow(false)
            .transparent(true)
            .build()
    } else {
        builder
            .decorations(false)
            .always_on_top(true)
            .visible_on_all_workspaces(true)
            .skip_taskbar(true)
            .shadow(false)
            .transparent(true)
            .build()
    };
    #[cfg(target_os = "windows")]
    finish_windows_webview_creation(
        "floating",
        webview_attempt.as_ref(),
        window_result.is_ok(),
    );
    let window = window_result?;
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

    let builder = WebviewWindowBuilder::new(
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
    .transparent(true)
    .visible(false);
    #[cfg(target_os = "windows")]
    let webview_attempt = begin_windows_webview_creation("status");
    #[cfg(target_os = "windows")]
    let builder = apply_windows_webview_data_directory(builder, webview_attempt.as_ref());
    let window_result = builder.build();
    #[cfg(target_os = "windows")]
    finish_windows_webview_creation("status", webview_attempt.as_ref(), window_result.is_ok());
    window_result?;

    Ok(())
}

#[cfg(target_os = "windows")]
fn begin_windows_webview_creation(
    label: &str,
) -> Option<crate::core::webview_startup::WebviewStartupAttempt> {
    match crate::core::webview_startup::begin() {
        Ok(attempt) => {
            startup_trace::mark(&format!(
                "webview {label} profile {}",
                attempt.profile_label()
            ));
            Some(attempt)
        }
        Err(error) => {
            startup_trace::mark(&format!(
                "webview {label} recovery sentinel unavailable: {error}"
            ));
            None
        }
    }
}

#[cfg(target_os = "windows")]
fn apply_windows_webview_data_directory<'a, R, M>(
    builder: WebviewWindowBuilder<'a, R, M>,
    attempt: Option<&crate::core::webview_startup::WebviewStartupAttempt>,
) -> WebviewWindowBuilder<'a, R, M>
where
    R: tauri::Runtime,
    M: Manager<R>,
{
    match attempt.and_then(|attempt| attempt.data_directory()) {
        // A recovery slot intentionally changes both the user-data directory and the GPU
        // path. That covers the two recurrent WebView2 startup failures without deleting the
        // original profile; all windows in the recovered process receive identical options.
        Some(path) => builder
            .data_directory(path)
            .additional_browser_args("--disable-gpu"),
        None => builder,
    }
}

#[cfg(target_os = "windows")]
fn finish_windows_webview_creation(
    label: &str,
    attempt: Option<&crate::core::webview_startup::WebviewStartupAttempt>,
    succeeded: bool,
) {
    if !succeeded {
        startup_trace::mark(&format!("webview {label} creation left recovery sentinel"));
        return;
    }
    if let Some(attempt) = attempt {
        if let Err(error) = crate::core::webview_startup::complete(attempt) {
            startup_trace::mark(&format!(
                "webview {label} recovery sentinel completion failed: {error}"
            ));
        }
    }
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
    fn startup_plan_keeps_manual_dashboard_and_autostart_background_only() {
        assert_eq!(
            surface_startup_plan(StartupLaunchMode::Manual, true),
            SurfaceStartupPlan {
                create_dashboard: true,
                floating: FloatingStartupAction::None,
            }
        );
        assert_eq!(
            surface_startup_plan(StartupLaunchMode::Manual, false).floating,
            FloatingStartupAction::None
        );
        assert_eq!(
            surface_startup_plan(StartupLaunchMode::Autostart, true),
            SurfaceStartupPlan {
                create_dashboard: false,
                floating: FloatingStartupAction::CreateAndShow,
            }
        );
        assert_eq!(
            surface_startup_plan(StartupLaunchMode::Autostart, false),
            SurfaceStartupPlan {
                create_dashboard: false,
                floating: FloatingStartupAction::None,
            }
        );
        assert_eq!(
            surface_startup_plan(StartupLaunchMode::Autostart, true),
            SurfaceStartupPlan {
                create_dashboard: false,
                floating: FloatingStartupAction::CreateAndShow,
            }
        );
    }

    #[test]
    fn startup_executor_preserves_floating_tray_and_fatal_dashboard_errors() {
        let autostart = surface_startup_plan(StartupLaunchMode::Autostart, true);
        let mut dashboard_calls = 0;
        let mut floating_show_calls = 0;
        let status = execute_surface_startup_plan(
            autostart,
            || {
                dashboard_calls += 1;
                Ok(())
            },
            || Err("floating create failed".into()),
            || {
                floating_show_calls += 1;
                Ok(())
            },
            || Err("tray create failed".into()),
        )
        .unwrap();
        assert_eq!(dashboard_calls, 0);
        assert_eq!(floating_show_calls, 0);
        assert_eq!(status.floating_window_error.as_deref(), Some("floating create failed"));
        assert_eq!(status.status_tray_error.as_deref(), Some("tray create failed"));

        let manual = surface_startup_plan(StartupLaunchMode::Manual, false);
        let error = execute_surface_startup_plan(
            manual,
            || Err("dashboard create failed".into()),
            || Ok(()),
            || Ok(()),
            || Ok(()),
        )
        .unwrap_err();
        assert_eq!(error, "dashboard create failed");
    }

    #[test]
    fn floating_window_dimensions_keep_compact_swift_proportions_without_clipping_default_content() {
        assert_eq!(FLOATING_WINDOW_WIDTH, 288.0);
        assert_eq!(FLOATING_WINDOW_MIN_HEIGHT, 88.0);
        assert_eq!(FLOATING_WINDOW_DEFAULT_HEIGHT, 138.0);
        assert!(FLOATING_WINDOW_DEFAULT_HEIGHT * FLOATING_WINDOW_MAX_SCALE >= 138.0 * 1.38);
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

    #[test]
    fn awaited_status_operation_propagates_setter_failure_and_cancellation() {
        async_runtime::block_on(async {
            let (error_tx, error_rx) =
                tokio::sync::oneshot::channel::<Result<bool, String>>();
            error_tx
                .send(Err("setter failed".into()))
                .expect("send setter failure");
            assert_eq!(
                await_status_operation_result(error_rx, "cancelled".into())
                    .await
                    .expect_err("inner setter failure must reach the caller"),
                "setter failed"
            );

            let (cancel_tx, cancel_rx) =
                tokio::sync::oneshot::channel::<Result<bool, String>>();
            drop(cancel_tx);
            assert_eq!(
                await_status_operation_result(cancel_rx, "cancelled".into())
                    .await
                    .expect_err("cancelled main-thread work must reach the caller"),
                "cancelled"
            );
        });
    }

    fn bounds(x: f64, y: f64, width: f64, height: f64) -> PhysicalBounds {
        PhysicalBounds { x, y, width, height }
    }

    #[test]
    fn status_panel_supports_all_taskbar_edges() {
        let work = bounds(0.0, 0.0, 1920.0, 1040.0);
        let panel = (STATUS_PANEL_WIDTH, STATUS_PANEL_HEIGHT);
        assert_eq!(
            status_panel_position(bounds(900.0, 0.0, 24.0, 24.0), work, panel, StatusPanelAnchor::Below),
            (717.0, 24.0)
        );
        assert_eq!(
            status_panel_position(bounds(900.0, 1016.0, 24.0, 24.0), work, panel, StatusPanelAnchor::Above),
            (717.0, 576.0)
        );
        assert_eq!(
            status_panel_position(bounds(0.0, 500.0, 24.0, 24.0), work, panel, StatusPanelAnchor::Right),
            (24.0, 292.0)
        );
        assert_eq!(
            status_panel_position(bounds(1896.0, 500.0, 24.0, 24.0), work, panel, StatusPanelAnchor::Left),
            (1506.0, 292.0)
        );
    }

    #[test]
    fn status_panel_clamps_on_negative_multimonitor_work_area() {
        let work = bounds(-1920.0, -120.0, 1920.0, 1080.0);
        assert_eq!(
            status_panel_position(
                bounds(-20.0, -120.0, 20.0, 20.0),
                work,
                (STATUS_PANEL_WIDTH, STATUS_PANEL_HEIGHT),
                StatusPanelAnchor::Below
            ),
            (-390.0, -100.0)
        );
    }

    #[test]
    fn macos_status_panel_anchor_stays_below_the_clicked_item_and_clamps_edges() {
        let visible = bounds(0.0, 24.0, 1512.0, 958.0);
        let panel = (STATUS_PANEL_WIDTH, STATUS_PANEL_HEIGHT);
        assert_eq!(
            macos_status_panel_position(bounds(900.0, 960.0, 72.0, 22.0), visible, panel),
            (741.0, 520.0)
        );
        assert_eq!(
            macos_status_panel_position(bounds(8.0, 960.0, 40.0, 22.0), visible, panel),
            (0.0, 520.0)
        );
        assert_eq!(
            macos_status_panel_position(bounds(1500.0, 960.0, 40.0, 22.0), visible, panel),
            (1122.0, 520.0)
        );
    }

    #[test]
    fn compact_status_indicator_width_is_bounded_and_accepts_narrow_content() {
        assert_eq!(status_indicator_width(0.0), 0.0);
        assert_eq!(status_indicator_width(-1.0), 0.0);
        assert_eq!(status_indicator_width(1.0), 64.0);
        assert_eq!(status_indicator_width(88.0), 88.0);
        assert_eq!(status_indicator_width(999.0), 720.0);
        assert_eq!(status_indicator_width(f64::NAN), 0.0);
    }

    #[test]
    fn compact_status_indicator_window_is_windows_only() {
        assert!(compact_status_indicator_supported(true));
        assert!(!compact_status_indicator_supported(false));
        assert_eq!(
            status_indicator_host_plan(false, true, StatusIndicatorMode::Collapsed),
            StatusIndicatorHostPlan {
                create_owner: true,
                presentation: StatusIndicatorNativePresentation::Hide,
            }
        );
        assert_eq!(
            status_indicator_native_presentation(false, true, StatusIndicatorMode::Collapsed),
            StatusIndicatorNativePresentation::Hide
        );
        assert_eq!(
            status_indicator_native_presentation(false, true, StatusIndicatorMode::Expanded),
            StatusIndicatorNativePresentation::Hide
        );
        assert_eq!(
            status_indicator_native_presentation(true, true, StatusIndicatorMode::Collapsed),
            StatusIndicatorNativePresentation::Present(StatusIndicatorMode::Collapsed)
        );
        assert_eq!(
            status_indicator_native_presentation(true, false, StatusIndicatorMode::Collapsed),
            StatusIndicatorNativePresentation::Hide
        );
        assert_eq!(
            status_indicator_host_plan(true, false, StatusIndicatorMode::Collapsed),
            StatusIndicatorHostPlan {
                create_owner: false,
                presentation: StatusIndicatorNativePresentation::Hide,
            }
        );
    }

    #[test]
    fn status_indicator_state_machine_replays_cached_content_after_enable() {
        let mut controller = StatusIndicatorPresentationController::default();
        assert_eq!(controller.publish(80.0), StatusIndicatorTransition::None);
        assert_eq!(controller.configure(true, true), StatusIndicatorTransition::Collapse);
        assert_eq!(controller.publish(80.0), StatusIndicatorTransition::Collapse);
        let tray = bounds(1800.0, 1040.0, 24.0, 24.0);
        assert_eq!(controller.expand(Some(tray)), StatusIndicatorTransition::Expand);
        assert!(controller.detail_open());
        assert_eq!(controller.publish(96.0), StatusIndicatorTransition::None);
        assert_eq!(controller.collapse(), StatusIndicatorTransition::Collapse);
        assert_eq!(controller.configure(false, true), StatusIndicatorTransition::Hide);
        assert!(controller.composed_owner_active);
        assert_eq!(controller.mode, StatusIndicatorMode::Hidden);
        assert_eq!(controller.publish(112.0), StatusIndicatorTransition::None);
        assert_eq!(controller.configure(true, true), StatusIndicatorTransition::Collapse);
        assert_eq!(controller.compact_width, 112.0);
    }

    #[test]
    fn empty_metric_order_keeps_summary_available_without_compact_strip() {
        let mut controller = StatusIndicatorPresentationController::default();
        assert_eq!(controller.configure(true, true), StatusIndicatorTransition::Hide);
        assert_eq!(controller.publish(0.0), StatusIndicatorTransition::Hide);
        assert!(!controller.has_compact_content);
        assert_eq!(controller.compact_width, 0.0);
        let tray = bounds(1800.0, 1040.0, 24.0, 24.0);
        assert_eq!(controller.expand(Some(tray)), StatusIndicatorTransition::Expand);
        assert!(controller.detail_open());
        assert_eq!(controller.collapse(), StatusIndicatorTransition::Hide);
        assert_eq!(controller.mode, StatusIndicatorMode::Hidden);
    }

    #[test]
    fn rapid_configuration_changes_converge_to_the_last_setting() {
        let mut controller = StatusIndicatorPresentationController::default();
        controller.publish(96.0);
        for index in 0..20 {
            let enabled = index % 2 == 1;
            controller.configure(enabled, true);
        }
        assert!(controller.enabled);
        assert_eq!(controller.mode, StatusIndicatorMode::Collapsed);
        controller.configure(false, true);
        controller.publish(0.0);
        assert_eq!(controller.configure(true, true), StatusIndicatorTransition::Hide);
        assert_eq!(controller.mode, StatusIndicatorMode::Hidden);
    }

    #[test]
    fn collapsed_status_indicator_prefers_tray_left_and_clamps_to_work_area() {
        let work = bounds(0.0, 0.0, 1920.0, 1040.0);
        let panel = (120.0, 40.0);
        assert_eq!(
            status_indicator_position(bounds(1800.0, 1040.0, 24.0, 24.0), work, panel, StatusPanelAnchor::Above, 8.0),
            (1672.0, 1000.0)
        );
        assert_eq!(
            status_indicator_position(bounds(1800.0, -24.0, 24.0, 24.0), work, panel, StatusPanelAnchor::Below, 8.0),
            (1672.0, 0.0)
        );
        assert_eq!(
            status_indicator_position(bounds(-24.0, 900.0, 24.0, 24.0), work, panel, StatusPanelAnchor::Right, 8.0),
            (0.0, 852.0)
        );
        assert_eq!(
            status_indicator_position(bounds(1920.0, 900.0, 24.0, 24.0), work, panel, StatusPanelAnchor::Left, 8.0),
            (1800.0, 852.0)
        );
    }

    #[test]
    fn status_indicator_fallback_stays_taskbar_adjacent() {
        let work = bounds(-1920.0, 0.0, 1920.0, 1040.0);
        let panel = (80.0, 40.0);
        assert_eq!(fallback_status_panel_position(work, panel, StatusPanelAnchor::Above), (-80.0, 1000.0));
        assert_eq!(fallback_status_panel_position(work, panel, StatusPanelAnchor::Below), (-80.0, 0.0));
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
        assert_eq!(
            safe_status_panel_position(bounds(0.0, 24.0, 1920.0, 1056.0), (390.0, 440.0)),
            (1530.0, 24.0)
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
    fn clearing_update_suffix_restores_live_tray_text() {
        let live = "12.4/s · 42%";
        assert_eq!(status_tray_title(live, Some("0.8.0")), "12.4/s · 42% ↑v0.8.0");
        assert_eq!(status_tray_title(live, None), live);
    }

    #[test]
    fn empty_composed_readout_is_data_not_a_disable_signal() {
        let readout = StatusTrayReadout {
            columns: Vec::new(),
            title: String::new(),
            tooltip: String::new(),
        };
        assert_eq!(status_tray_readout_with_update(readout.clone(), None), readout);
        assert_eq!(
            status_tray_readout_with_update(readout, Some("0.9.0")),
            StatusTrayReadout {
                columns: vec![StatusTrayColumn {
                    top: StatusTrayLine {
                        text: "↑".into(),
                        secondary: false,
                    },
                    bottom: StatusTrayLine {
                        text: "v0.9.0".into(),
                        secondary: true,
                    },
                }],
                title: "↑v0.9.0".into(),
                tooltip: "有新版本 v0.9.0，打开主界面安装".into(),
            }
        );
    }

    #[test]
    fn default_status_readout_is_neutral_instead_of_a_fake_zero() {
        assert_eq!(
            StatusTrayReadout::default(),
            StatusTrayReadout {
                columns: Vec::new(),
                title: String::new(),
                tooltip: "Codex Token Bar".into(),
            }
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_status_tray_uses_large_true_rows_with_shared_column_starts() {
        assert!(MACOS_STATUS_TRAY_FONT_SIZE >= 8.5);
        assert!(MACOS_STATUS_TRAY_LINE_SPACING < 0.0);
        let font = NSFont::monospacedSystemFontOfSize_weight(
            MACOS_STATUS_TRAY_FONT_SIZE,
            unsafe { NSFontWeightSemibold },
        );
        let columns = vec![
            StatusTrayColumn {
                top: StatusTrayLine { text: "12.4".into(), secondary: false },
                bottom: StatusTrayLine { text: "tok/s".into(), secondary: true },
            },
            StatusTrayColumn {
                top: StatusTrayLine { text: "5 41%".into(), secondary: false },
                bottom: StatusTrayLine { text: "7 76%".into(), secondary: false },
            },
        ];
        let starts = macos_status_tray_column_starts(&columns, &font);
        assert_eq!(starts.len(), 2);
        assert_eq!(starts[0], 0.0);
        assert!(starts[1] > macos_status_line_width("tok/s", &font));
        assert!(MACOS_STATUS_TRAY_COLUMN_SPACING >= 6.0);
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
