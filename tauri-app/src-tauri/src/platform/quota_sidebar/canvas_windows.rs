//! Keep both the HWND and WebView2 canvas fixed while the window region expands.
//! Called on Tauri's UI thread, including during drag and reduced-motion jumps.
use super::{canvas_geometry::{layout, CanvasFrame}, SidebarFrame};
use tauri::{Emitter, WebviewWindow};
use windows_sys::Win32::{
    Foundation::{HWND, RECT},
    Graphics::Gdi::{CombineRgn, CreateRectRgn, CreateRoundRectRgn, DeleteObject,
        GetWindowRgnBox, RedrawWindow, SetWindowRgn, RDW_ALLCHILDREN, RDW_FRAME, RDW_INVALIDATE, RGN_OR, RGN_ERROR},
    System::Threading::GetCurrentThreadId,
    UI::WindowsAndMessaging::{GetWindowRect, GetWindowThreadProcessId, SetPropW, SetWindowPos,
        SWP_NOACTIVATE, SWP_NOCOPYBITS, SWP_NOREDRAW, SWP_NOZORDER},
};

fn last_error() -> String { std::io::Error::last_os_error().to_string() }

// Same per-HWND gate as vendored Wry's WM_SIZE / WM_MOVE handlers. It remains
// set for this rail's lifetime, never for the independent detail-card window.
const PINNED_VIEWPORT: &[u16] = &[
    67, 111, 100, 101, 120, 84, 111, 107, 101, 110, 66, 97, 114, 58, 58, 80, 105, 110, 110,
    101, 100, 87, 101, 98, 86, 105, 101, 119, 86, 105, 101, 119, 112, 111, 114, 116, 0,
];

struct Repaint(HWND);
impl Drop for Repaint {
    fn drop(&mut self) {
        // Also invalidate after a partial native failure. No WM_SETREDRAW state
        // can be stranded, and no blocking DwmFlush is added to the frame loop.
        unsafe { RedrawWindow(self.0, std::ptr::null(), std::ptr::null_mut(),
            RDW_INVALIDATE | RDW_FRAME | RDW_ALLCHILDREN); }
    }
}

fn clip(hwnd: HWND, f: CanvasFrame, left: bool) -> Result<(), String> {
    unsafe {
        let radius = f.radius.min(f.width / 2).min(f.height / 2).max(1);
        let (x, y) = (f.clip_x, f.clip_y);
        let rounded = CreateRoundRectRgn(x, y, x + f.width, y + f.height, radius * 2, radius * 2);
        if rounded.is_null() { return Err(last_error()); }
        // Square the screen-facing half, keeping only the two inward corners.
        let square = CreateRectRgn(x + if left { 0 } else { f.width / 2 }, y,
            x + if left { (f.width + 1) / 2 } else { f.width }, y + f.height);
        if square.is_null() { let error = last_error(); DeleteObject(rounded); return Err(error); }
        let combined = CombineRgn(rounded, rounded, square, RGN_OR);
        DeleteObject(square);
        if combined == 0 { let error = last_error(); DeleteObject(rounded); return Err(error); }
        if SetWindowRgn(hwnd, rounded, 0) == 0 {
            let error = last_error(); DeleteObject(rounded); return Err(error);
        }
        // SetWindowRgn transfers ownership to Windows on success.
    }
    Ok(())
}

/// Geometry/presence/drag must use the visible input region, not the larger
/// invisible HWND. Before the first canvas setup the window has no region.
pub(super) fn window_frame(window: &WebviewWindow) -> Result<SidebarFrame, String> {
    let hwnd = window.hwnd().map_err(|e| e.to_string())?;
    let mut outer = RECT::default();
    if unsafe { GetWindowRect(hwnd.0, &mut outer) } == 0 { return Err(last_error()); }
    let mut region = RECT::default();
    if unsafe { GetWindowRgnBox(hwnd.0, &mut region) } == RGN_ERROR {
        region.right = outer.right - outer.left;
        region.bottom = outer.bottom - outer.top;
    }
    Ok(SidebarFrame { x: (outer.left + region.left) as f64, y: (outer.top + region.top) as f64,
        width: (region.right - region.left) as f64, height: (region.bottom - region.top) as f64 })
}

pub(super) fn set_frame(window: &WebviewWindow, frame: SidebarFrame, left: bool, scale: f64) -> Result<(), String> {
    let f = layout(frame, left, scale)?;
    let outer = window.hwnd().map_err(|e| e.to_string())?;
    if unsafe { GetWindowThreadProcessId(outer.0, std::ptr::null_mut()) } != unsafe { GetCurrentThreadId() } {
        return Err("Sidebar canvas requires the UI thread".into());
    }
    let (send, receive) = std::sync::mpsc::sync_channel(1);
    let outer_handle = outer.0 as usize;
    // Tauri 2's with_webview executes inline on its UI thread. Do not let the
    // next animation sample overtake this one or block waiting on that thread.
    window.with_webview(move |webview| {
        let outer = outer_handle as HWND;
        let result = (|| {
            if unsafe { SetPropW(outer, PINNED_VIEWPORT.as_ptr(), 1usize as _) } == 0 { return Err(last_error()); }
            let controller = webview.controller();
            let mut bounds = Default::default();
            unsafe { controller.Bounds(&mut bounds) }.map_err(|e| e.to_string())?;
            let bounds_changed = bounds.left != 0 || bounds.top != 0 || bounds.right != f.canvas_width || bounds.bottom != f.canvas_height;
            if bounds_changed {
                bounds.left = 0; bounds.top = 0;
                bounds.right = f.canvas_width; bounds.bottom = f.canvas_height;
                unsafe { controller.SetBounds(bounds) }.map_err(|e| e.to_string())?;
            }
            let mut child = Default::default();
            unsafe { controller.ParentWindow(&mut child) }.map_err(|e| e.to_string())?;
            let _repaint = Repaint(outer);
            // During a normal expansion neither HWND moves/resizes. Only the
            // region changes, so DWM cannot expose an intermediate parent/child
            // offset. SetWindowPos is needed only for setup, dragging, DPI or a
            // workarea-clamped center change. No cross-parent DeferWindowPos.
            let flags = SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOREDRAW | SWP_NOCOPYBITS;
            let mut actual = RECT::default();
            if unsafe { GetWindowRect(outer, &mut actual) } == 0 { return Err(last_error()); }
            let host_changed = actual.left != f.canvas_x || actual.top != f.canvas_y
                || actual.right - actual.left != f.canvas_width || actual.bottom - actual.top != f.canvas_height;
            if host_changed {
                if unsafe { SetWindowPos(outer, std::ptr::null_mut(), f.canvas_x, f.canvas_y,
                    f.canvas_width, f.canvas_height, flags) } == 0 { return Err(last_error()); }
            }
            if bounds_changed && unsafe { SetWindowPos(child.0 as _, std::ptr::null_mut(), 0, 0,
                f.canvas_width, f.canvas_height, flags) } == 0 { return Err(last_error()); }
            clip(outer, f, left)?;
            if host_changed || bounds_changed {
                unsafe { controller.NotifyParentWindowPositionChanged() }.map_err(|e| e.to_string())?;
            }
            Ok(())
        })();
        let _ = send.send(result);
    }).map_err(|e| e.to_string())?;
    receive.try_recv().map_err(|_| "Sidebar canvas update was not executed on the UI thread".to_string())??;
    // Native resize events now describe the fixed host, not its input region.
    // Publish logical clip dimensions for the decorative edge only; they never
    // affect the summary's fixed positioning or drive the animation.
    window.emit("quota-sidebar-clip-changed", (f.width as f64 / scale, f.height as f64 / scale)).map_err(|e| e.to_string())
}
