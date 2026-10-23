//! Track only the active gesture. Avoid the OS caption move loop for this
//! transparent window: it can paint non-client chrome into the WebView surface.
#[derive(Clone, Copy)]
struct DragGrip { x: f64, y: f64 }
impl DragGrip {
    fn new(cursor: (f64, f64), origin: (f64, f64), size: (f64, f64)) -> Self {
        Self { x: ((cursor.0 - origin.0) / size.0.max(1.0)).clamp(0.0, 1.0),
            y: ((cursor.1 - origin.1) / size.1.max(1.0)).clamp(0.0, 1.0) }
    }
    fn origin(self, cursor: (f64, f64), size: (f64, f64)) -> (i32, i32) {
        ((cursor.0 - self.x * size.0).round() as i32, (cursor.1 - self.y * size.1).round() as i32)
    }
}

#[cfg(windows)]
async fn on_main<T: Send + 'static>(window: &tauri::WebviewWindow, work: impl FnOnce() -> Result<T, String> + Send + 'static) -> Result<T, String> {
    let (send, receive) = tokio::sync::oneshot::channel();
    window.run_on_main_thread(move || { let _ = send.send(work()); }).map_err(|e| e.to_string())?;
    receive.await.map_err(|_| "Floating drag dispatcher closed".to_string())?
}

#[cfg(windows)]
static ACTIVE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
#[cfg(windows)]
struct ActiveDrag;
#[cfg(windows)]
impl Drop for ActiveDrag {
    fn drop(&mut self) { ACTIVE.store(false, std::sync::atomic::Ordering::Release); }
}

#[cfg(windows)]
pub(crate) async fn drag(window: tauri::WebviewWindow) -> Result<(), String> {
    use std::sync::atomic::Ordering;
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::GetAsyncKeyState;
    use windows_sys::Win32::UI::WindowsAndMessaging::{SetWindowPos, SWP_NOACTIVATE, SWP_NOSIZE, SWP_NOZORDER};
    if ACTIVE.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_err() {
        return Err("Floating window drag already active".into());
    }
    let _active = ActiveDrag;
    let native = window.clone();
    let grip = on_main(&window, move || {
        if unsafe { GetAsyncKeyState(1) } >= 0 { return Err("Floating drag ended before dispatch".into()); }
        let cursor = native.cursor_position().map_err(|e| e.to_string())?;
        let origin = native.outer_position().map_err(|e| e.to_string())?;
        let size = native.outer_size().map_err(|e| e.to_string())?;
        Ok(DragGrip::new((cursor.x, cursor.y), (origin.x as f64, origin.y as f64), (size.width as f64, size.height as f64)))
    }).await?;
    let started = std::time::Instant::now();
    loop {
        tokio::time::sleep(std::time::Duration::from_millis(16)).await;
        let native = window.clone();
        let done = on_main(&window, move || {
            // Never move after mouse-up: the dock controller may already have
            // snapped the release frame. Size is read live for a DPI transition.
            if unsafe { GetAsyncKeyState(1) } >= 0 || !native.is_visible().map_err(|e| e.to_string())? { return Ok(true); }
            let cursor = native.cursor_position().map_err(|e| e.to_string())?;
            let size = native.outer_size().map_err(|e| e.to_string())?;
            let point = grip.origin((cursor.x, cursor.y), (size.width as f64, size.height as f64));
            let current = native.outer_position().map_err(|e| e.to_string())?;
            if (current.x, current.y) != point {
                let hwnd = native.hwnd().map_err(|e| e.to_string())?;
                if unsafe { SetWindowPos(hwnd.0, std::ptr::null_mut(), point.0, point.1, 0, 0, SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOZORDER) } == 0 {
                    return Err(std::io::Error::last_os_error().to_string());
                }
            }
            Ok(false)
        }).await?;
        if done { return Ok(()); }
        if started.elapsed() > std::time::Duration::from_secs(120) { return Err("Floating window drag timed out".into()); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn drag_keeps_the_grab_point_on_negative_and_positive_screens() {
        let grip = DragGrip::new((1100.0, 592.0), (983.0, 514.0), (462.0, 177.0));
        assert_eq!(grip.origin((2215.0, 592.0), (462.0, 177.0)), (2098, 514));
        assert_eq!(grip.origin((-1100.0, 592.0), (462.0, 177.0)), (-1217, 514));
    }
    #[test]
    fn crossing_dpi_preserves_fractional_grip_without_old_screen_coordinates() {
        let grip = DragGrip::new((150.0, 90.0), (0.0, 30.0), (300.0, 120.0));
        assert_eq!(grip.origin((-500.0, 300.0), (600.0, 240.0)), (-800, 180));
    }
}
