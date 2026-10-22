//! A session click counter only: no event contents are retained or consumed.
#[cfg(target_os = "macos")]
pub(super) fn revision() -> Result<u64, String> {
    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" { fn CGEventSourceCounterForEventType(state_id: i32, event_type: u32) -> u32; }
    // Combined session state; left/right/other mouse-down. No event tap or AX access.
    Ok(unsafe { [1, 3, 25].into_iter().map(|kind| CGEventSourceCounterForEventType(0, kind) as u64).sum() })
}

#[cfg(windows)]
pub(super) fn revision() -> Result<u64, String> { windows::revision() }

#[cfg(not(any(target_os = "macos", windows)))]
pub(super) fn revision() -> Result<u64, String> { Ok(0) }

#[cfg(windows)]
mod windows {
    use std::sync::{OnceLock, atomic::{AtomicU64, Ordering}, mpsc};
    use windows_sys::Win32::{Foundation::{LPARAM, LRESULT, WPARAM}, System::LibraryLoader::GetModuleHandleW,
        UI::WindowsAndMessaging::{CallNextHookEx, DispatchMessageW, GetMessageW, SetWindowsHookExW,
            UnhookWindowsHookEx, MSG, WH_MOUSE_LL, WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN, WM_XBUTTONDOWN}};
    static CLICKS: AtomicU64 = AtomicU64::new(0);
    static STARTED: OnceLock<Result<(), String>> = OnceLock::new();
    unsafe extern "system" fn observe(code: i32, message: WPARAM, data: LPARAM) -> LRESULT {
        if code >= 0 && matches!(message as u32, WM_LBUTTONDOWN | WM_RBUTTONDOWN | WM_MBUTTONDOWN | WM_XBUTTONDOWN) {
            CLICKS.fetch_add(1, Ordering::Relaxed);
        }
        // Never prevent the original click from reaching its target application.
        CallNextHookEx(std::ptr::null_mut(), code, message, data)
    }
    pub(super) fn revision() -> Result<u64, String> {
        STARTED.get_or_init(|| {
            let (ready, wait) = mpsc::sync_channel(1);
            std::thread::Builder::new().name("sidebar-click-counter".into()).spawn(move || unsafe {
                let hook = SetWindowsHookExW(WH_MOUSE_LL, Some(observe), GetModuleHandleW(std::ptr::null()), 0);
                if hook.is_null() { let _ = ready.send(Err("无法监听侧栏外的鼠标点击".to_string())); return; }
                if ready.send(Ok(())).is_err() { UnhookWindowsHookEx(hook); return; }
                let mut message: MSG = std::mem::zeroed();
                while GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) > 0 { DispatchMessageW(&message); }
                UnhookWindowsHookEx(hook);
            }).map_err(|_| "无法启动侧栏点击监听".to_string())?;
            wait.recv_timeout(std::time::Duration::from_secs(2)).map_err(|_| "侧栏点击监听启动超时".to_string())?
        }).clone()?;
        Ok(CLICKS.load(Ordering::Relaxed))
    }
}
