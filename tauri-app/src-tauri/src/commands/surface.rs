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
    pub(super) fn validate(self) -> Result<Self, String> {
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
pub async fn set_floating_dock_frame(window: tauri::WebviewWindow, frame: FloatingDockFrame, viewport: Option<FloatingDockFrame>) -> Result<bool, String> {
    require_window_label(&window, "set_floating_dock_frame")?;
    let frame = frame.validate()?;
    let viewport = viewport.map(|value| value.validate()).transpose()?;
    if let Some(viewport) = viewport { dock_viewport_offset(frame, viewport)?; }
    let (sender, receiver) = tokio::sync::oneshot::channel();
    let native = window.clone();
    #[cfg(target_os = "macos")]
    window.with_webview(move |webview| {
        let result = apply_floating_dock_frame(&native, frame, viewport, webview.inner()).map(|_| viewport.is_some());
        let _ = sender.send(result);
    }).map_err(|error| error.to_string())?;
    #[cfg(windows)]
    window.with_webview(move |webview| {
        let requested_viewport = viewport.unwrap_or(frame);
        let keep_pinned = viewport.is_some() && !floating_dock_frames_match(frame, requested_viewport);
        let result = (|| {
            // Match the macOS path for every native frame change, not only the
            // compact edge lip. AppKit disables WKWebView autoresizing before
            // resizing NSWindow, then explicitly commits the requested webview
            // frame in the same main-thread turn. Windows must do the same for
            // ordinary primary <-> details resizes as well; otherwise Wry's
            // WM_SIZE hook publishes an intermediate WebView2 viewport and the
            // primary card visibly reflows before the details frame settles.
            set_windows_floating_viewport_pinned(&native, true)?;
            apply_windows_floating_frame_and_viewport(&native, frame, requested_viewport, webview)?;
            if !keep_pinned {
                set_windows_floating_viewport_pinned(&native, false)?;
            }
            Ok(viewport.is_some())
        })();
        if result.is_err() {
            // Never strand the HWND with Wry's ordinary resize path disabled.
            // Frontend recovery will restore the full frame after this call.
            let _ = set_windows_floating_viewport_pinned(&native, false);
        }
        let _ = sender.send(result);
    }).map_err(|error| error.to_string())?;
    #[cfg(not(any(target_os = "macos", windows)))]
    window.run_on_main_thread(move || {
        let _ = sender.send(apply_floating_dock_frame(&native, frame).map(|_| false));
    }).map_err(|error| error.to_string())?;
    receiver.await.map_err(|_| "Floating frame update was cancelled".to_string())?
}

// Physical offsets of an unchanged full viewport inside the clipped window.
// AppKit views use a bottom-left origin, unlike the public dock coordinates.
fn dock_viewport_offset(frame: FloatingDockFrame, viewport: FloatingDockFrame) -> Result<(f64, f64), String> {
    if frame.x < viewport.x - 1.0 || frame.y < viewport.y - 1.0
        || frame.x + frame.width > viewport.x + viewport.width + 1.0
        || frame.y + frame.height > viewport.y + viewport.height + 1.0 {
        return Err("Dock clip must be contained in its viewport".into());
    }
    Ok((viewport.x - frame.x, frame.y + frame.height - viewport.y - viewport.height))
}

// Windows uses a top-left origin for child HWND coordinates. Keep the full
// WebView2 viewport at its original desktop-space origin while the outer window
// shrinks to the visible edge lip.
#[cfg(any(windows, test))]
fn windows_dock_viewport_offset(frame: FloatingDockFrame, viewport: FloatingDockFrame) -> Result<(f64, f64), String> {
    if frame.x < viewport.x - 1.0 || frame.y < viewport.y - 1.0
        || frame.x + frame.width > viewport.x + viewport.width + 1.0
        || frame.y + frame.height > viewport.y + viewport.height + 1.0 {
        return Err("Dock clip must be contained in its viewport".into());
    }
    Ok((viewport.x - frame.x, viewport.y - frame.y))
}

#[cfg(any(windows, test))]
fn floating_dock_frames_match(frame: FloatingDockFrame, viewport: FloatingDockFrame) -> bool {
    [
        (frame.x, viewport.x),
        (frame.y, viewport.y),
        (frame.width, viewport.width),
        (frame.height, viewport.height),
    ]
    .into_iter()
    .all(|(left, right)| (left - right).abs() < 0.5)
}

#[cfg(target_os = "macos")]
pub(super) fn apply_floating_dock_frame(window: &tauri::WebviewWindow, frame: FloatingDockFrame, viewport: Option<FloatingDockFrame>, webview: *mut std::ffi::c_void) -> Result<(), String> {
    use objc2_app_kit::{NSWindow, NSView, NSAutoresizingMaskOptions};
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
    if webview.is_null() { return Err("Floating native webview is unavailable".into()); }
    let view = unsafe { &*webview.cast::<NSView>() };
    // Disable the WKWebView's own autoresizing before NSWindow resizes its
    // content view. Its viewport/backing store remains full-sized throughout;
    // only the native clip and the view origin change in this main-thread call.
    view.setAutoresizingMask(NSAutoresizingMaskOptions::empty());
    native.setFrame_display(rect, false);
    let viewport = viewport.unwrap_or(frame);
    let (x, y) = dock_viewport_offset(frame, viewport)?;
    view.setFrame(NSRect::new(NSPoint::new(x / scale, y / scale),
        NSSize::new(viewport.width / scale, viewport.height / scale)));
    if frame.width == viewport.width && frame.height == viewport.height {
        view.setAutoresizingMask(NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewHeightSizable);
    }
    native.displayIfNeeded();
    Ok(())
}

#[cfg(windows)]
pub(super) fn apply_floating_dock_frame(window: &tauri::WebviewWindow, frame: FloatingDockFrame) -> Result<(), String> {
    use windows_sys::Win32::UI::WindowsAndMessaging::{SetWindowPos, SWP_NOACTIVATE, SWP_NOZORDER};
    let handle = window.hwnd().map_err(|error| error.to_string())?;
    let success = unsafe { SetWindowPos(handle.0, std::ptr::null_mut(), frame.x.round() as i32, frame.y.round() as i32,
        frame.width.round() as i32, frame.height.round() as i32, SWP_NOACTIVATE | SWP_NOZORDER) };
    if success == 0 { return Err(std::io::Error::last_os_error().to_string()); }
    Ok(())
}

#[cfg(windows)]
fn set_windows_floating_viewport_pinned(window: &tauri::WebviewWindow, pinned: bool) -> Result<(), String> {
    use windows_sys::Win32::UI::WindowsAndMessaging::{RemovePropW, SetPropW};

    // Must stay byte-for-byte aligned with Wry's WM_SIZE guard in the vendored
    // webview2 backend. A window property avoids global state and applies only
    // to this floating HWND.
    const PROPERTY: &[u16] = &[
        67, 111, 100, 101, 120, 84, 111, 107, 101, 110, 66, 97, 114, 58, 58, 80, 105, 110, 110,
        101, 100, 87, 101, 98, 86, 105, 101, 119, 86, 105, 101, 119, 112, 111, 114, 116, 0,
    ]; // "CodexTokenBar::PinnedWebViewViewport\0"
    let handle = window.hwnd().map_err(|error| error.to_string())?;
    if pinned {
        let success = unsafe { SetPropW(handle.0, PROPERTY.as_ptr(), 1usize as _) };
        if success == 0 { return Err(std::io::Error::last_os_error().to_string()); }
    } else {
        // Removal is idempotent; a null return also means the property was not
        // present, which is already the desired state.
        unsafe { RemovePropW(handle.0, PROPERTY.as_ptr()); }
    }
    Ok(())
}

#[cfg(windows)]
fn apply_windows_floating_frame_and_viewport(
    window: &tauri::WebviewWindow,
    frame: FloatingDockFrame,
    viewport: FloatingDockFrame,
    webview: tauri::webview::PlatformWebview,
) -> Result<(), String> {
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        BeginDeferWindowPos, DeferWindowPos, EndDeferWindowPos, SWP_NOACTIVATE, SWP_NOZORDER,
    };

    let (offset_x, offset_y) = windows_dock_viewport_offset(frame, viewport)?;
    let width = viewport.width.round() as i32;
    let height = viewport.height.round() as i32;
    let outer = window.hwnd().map_err(|error| error.to_string())?;
    let controller = webview.controller();

    // Keep the controller viewport fixed, then commit the outer HWND and Wry's
    // child HWND in one batch. A right/bottom compact handle has both a shifted
    // outer origin and a compensating negative child offset; applying those in
    // separate visible calls exposes an intermediate screen-space origin even
    // when the browser viewport size itself is pinned. AppKit avoids that with
    // NSWindow.setFrame(display: false) and publishes only after the WKWebView
    // origin is corrected. DeferWindowPos is the matching Win32 transaction.
    let mut bounds = Default::default();
    unsafe { controller.Bounds(&mut bounds) }.map_err(|error| error.to_string())?;
    bounds.left = 0;
    bounds.top = 0;
    bounds.right = width;
    bounds.bottom = height;
    unsafe { controller.SetBounds(bounds) }.map_err(|error| error.to_string())?;

    let mut webview_parent = Default::default();
    unsafe { controller.ParentWindow(&mut webview_parent) }.map_err(|error| error.to_string())?;
    let deferred = unsafe { BeginDeferWindowPos(2) };
    if deferred.is_null() {
        return Err(std::io::Error::last_os_error().to_string());
    }
    let deferred = unsafe {
        DeferWindowPos(
            deferred,
            outer.0,
            std::ptr::null_mut(),
            frame.x.round() as i32,
            frame.y.round() as i32,
            frame.width.round() as i32,
            frame.height.round() as i32,
            SWP_NOACTIVATE | SWP_NOZORDER,
        )
    };
    if deferred.is_null() {
        return Err(std::io::Error::last_os_error().to_string());
    }
    let deferred = unsafe {
        DeferWindowPos(
            deferred,
            webview_parent.0 as _,
            std::ptr::null_mut(),
            offset_x.round() as i32,
            offset_y.round() as i32,
            width,
            height,
            SWP_NOACTIVATE | SWP_NOZORDER,
        )
    };
    if deferred.is_null() {
        return Err(std::io::Error::last_os_error().to_string());
    }
    if unsafe { EndDeferWindowPos(deferred) } == 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    unsafe { controller.NotifyParentWindowPositionChanged() }.map_err(|error| error.to_string())?;
    Ok(())
}

#[cfg(not(any(target_os = "macos", windows)))]
pub(super) fn apply_floating_dock_frame(window: &tauri::WebviewWindow, frame: FloatingDockFrame) -> Result<(), String> {
    window.set_size(tauri::PhysicalSize::new(frame.width.round() as u32, frame.height.round() as u32)).map_err(|e| e.to_string())?;
    window.set_position(tauri::PhysicalPosition::new(frame.x.round() as i32, frame.y.round() as i32)).map_err(|e| e.to_string())
}

#[cfg(test)]
mod dock_frame_tests {
    use super::{FloatingDockFrame, dock_viewport_offset, floating_dock_frames_match, windows_dock_viewport_offset};
    #[test]
    fn clipping_preserves_global_viewport_coordinates_on_every_edge() {
        let full = FloatingDockFrame { x: -800.0, y: 200.0, width: 600.0, height: 240.0 };
        let clips = [
            (FloatingDockFrame { width: 24.0, ..full }, (0.0, 0.0)),
            (FloatingDockFrame { x: -224.0, width: 24.0, ..full }, (-576.0, 0.0)),
            (FloatingDockFrame { x: -592.0, width: 184.0, height: 24.0, ..full }, (-208.0, -216.0)),
            (FloatingDockFrame { x: -592.0, y: 416.0, width: 184.0, height: 24.0 }, (-208.0, 0.0)),
        ];
        for (clip, expected) in clips { assert_eq!(dock_viewport_offset(clip, full).unwrap(), expected); }
        assert_eq!(dock_viewport_offset(full, full).unwrap(), (0.0, 0.0));
        assert!(dock_viewport_offset(FloatingDockFrame { x: -900.0, ..full }, full).is_err());
    }

    #[test]
    fn windows_clipping_preserves_top_left_viewport_coordinates_on_every_edge() {
        let full = FloatingDockFrame { x: -800.0, y: 200.0, width: 600.0, height: 240.0 };
        let clips = [
            (FloatingDockFrame { width: 24.0, ..full }, (0.0, 0.0)),
            (FloatingDockFrame { x: -224.0, width: 24.0, ..full }, (-576.0, 0.0)),
            (FloatingDockFrame { x: -592.0, width: 184.0, height: 24.0, ..full }, (-208.0, 0.0)),
            (FloatingDockFrame { x: -592.0, y: 416.0, width: 184.0, height: 24.0 }, (-208.0, -216.0)),
        ];
        for (clip, expected) in clips { assert_eq!(windows_dock_viewport_offset(clip, full).unwrap(), expected); }
        assert_eq!(windows_dock_viewport_offset(full, full).unwrap(), (0.0, 0.0));
        assert!(windows_dock_viewport_offset(FloatingDockFrame { x: -900.0, ..full }, full).is_err());
    }

    #[test]
    fn accepts_negative_display_coordinates_and_rejects_invalid_native_bounds() {
        let valid = FloatingDockFrame { x: -1600.0, y: 240.0, width: 24.0, height: 212.0 };
        assert!(valid.validate().is_ok());
        for invalid in [FloatingDockFrame { x: f64::NAN, ..valid }, FloatingDockFrame { width: 0.0, ..valid },
            FloatingDockFrame { y: f64::INFINITY, ..valid }, FloatingDockFrame { width: i32::MAX as f64 + 1.0, ..valid }] {
            assert!(invalid.validate().is_err());
        }
    }

    #[test]
    fn full_viewport_detection_only_unpins_at_the_expanded_frame() {
        let full = FloatingDockFrame { x: 0.0, y: 120.0, width: 600.0, height: 240.0 };
        assert!(floating_dock_frames_match(full, full));
        assert!(floating_dock_frames_match(FloatingDockFrame { x: 0.2, ..full }, full));
        assert!(!floating_dock_frames_match(FloatingDockFrame { width: 24.0, ..full }, full));
        assert!(!floating_dock_frames_match(FloatingDockFrame { x: 576.0, width: 24.0, ..full }, full));
    }
}
