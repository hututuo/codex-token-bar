// Tao rebuilds Win32 styles for visibility and move-loop state changes.
// Keep the floating HWND borderless across those changes, not only at show.
use std::ffi::c_void;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GWL_EXSTYLE, GWL_STYLE, STYLESTRUCT, WM_NCDESTROY, WM_STYLECHANGING,
    WS_BORDER, WS_CAPTION, WS_DLGFRAME, WS_EX_WINDOWEDGE, WS_POPUP, WS_THICKFRAME,
};

type SubclassProc = unsafe extern "system" fn(*mut c_void, u32, usize, isize, usize, usize) -> isize;
#[link(name = "comctl32")]
extern "system" {
    fn SetWindowSubclass(hwnd: *mut c_void, callback: Option<SubclassProc>, id: usize, data: usize) -> i32;
    fn RemoveWindowSubclass(hwnd: *mut c_void, callback: Option<SubclassProc>, id: usize) -> i32;
    fn DefSubclassProc(hwnd: *mut c_void, message: u32, wparam: usize, lparam: isize) -> isize;
}
const STYLE_GUARD_ID: usize = 0x5442_4643;

fn floating_style(style: u32, extended: bool) -> u32 {
    if extended { style & !WS_EX_WINDOWEDGE }
    else { (style & !(WS_CAPTION | WS_THICKFRAME | WS_BORDER | WS_DLGFRAME)) | WS_POPUP }
}

unsafe extern "system" fn style_guard(
    hwnd: *mut c_void, message: u32, wparam: usize, lparam: isize, id: usize, _data: usize,
) -> isize {
    if message == WM_NCDESTROY {
        RemoveWindowSubclass(hwnd, Some(style_guard), id);
    }
    let result = DefSubclassProc(hwnd, message, wparam, lparam);
    // Let the remaining handlers run first, then constrain only border chrome.
    // STYLESTRUCT is owned by Windows and valid only during this message.
    if message == WM_STYLECHANGING && lparam != 0 {
        let index = wparam as i32;
        if index == GWL_STYLE || index == GWL_EXSTYLE {
            let styles = &mut *(lparam as *mut STYLESTRUCT);
            styles.styleNew = floating_style(styles.styleNew, index == GWL_EXSTYLE);
        }
    }
    result
}

fn install_style_guard(hwnd: *mut c_void) -> Result<(), String> {
    // Same HWND/procedure/id is an idempotent update, not another subclass.
    if unsafe { SetWindowSubclass(hwnd, Some(style_guard), STYLE_GUARD_ID, 0) } == 0 {
        return Err("Could not install floating window style guard".into());
    }
    Ok(())
}

pub(super) fn enforce(window: &tauri::WebviewWindow) -> Result<(), String> {
    use std::ffi::c_void;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        GetWindowLongPtrW, SetWindowLongPtrW, SetWindowPos, GWL_EXSTYLE, GWL_STYLE,
        SWP_FRAMECHANGED, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER,
    };

    let handle = window.hwnd().map_err(|error| error.to_string())?;
    install_style_guard(handle.0)?;
    let style = unsafe { GetWindowLongPtrW(handle.0, GWL_STYLE) } as u32;
    let ex_style = unsafe { GetWindowLongPtrW(handle.0, GWL_EXSTYLE) } as u32;
    let clean_style = floating_style(style, false);
    let clean_ex_style = floating_style(ex_style, true);
    unsafe {
        SetWindowLongPtrW(handle.0, GWL_STYLE, clean_style as isize);
        SetWindowLongPtrW(handle.0, GWL_EXSTYLE, clean_ex_style as isize);
    }
    let success = unsafe {
        SetWindowPos(
            handle.0,
            std::ptr::null_mut(),
            0,
            0,
            0,
            0,
            SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER,
        )
    };
    if success == 0 { return Err(std::io::Error::last_os_error().to_string()); }

    // Windows 11 may still draw/clip an undecorated top-level HWND using DWM
    // border and corner policy. Mac has no equivalent invisible docking inset;
    // turn both off so the requested outer frame is the visible frame too.
    #[link(name = "dwmapi")]
    extern "system" {
        fn DwmSetWindowAttribute(
            hwnd: *mut c_void,
            attribute: u32,
            value: *const c_void,
            size: u32,
        ) -> i32;
    }
    const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;
    const DWMWA_BORDER_COLOR: u32 = 34;
    const DWMWCP_DONOTROUND: u32 = 1;
    const DWMWA_COLOR_NONE: u32 = 0xFFFF_FFFE;
    unsafe {
        let _ = DwmSetWindowAttribute(
            handle.0,
            DWMWA_WINDOW_CORNER_PREFERENCE,
            (&DWMWCP_DONOTROUND as *const u32).cast(),
            std::mem::size_of::<u32>() as u32,
        );
        let _ = DwmSetWindowAttribute(
            handle.0,
            DWMWA_BORDER_COLOR,
            (&DWMWA_COLOR_NONE as *const u32).cast(),
            std::mem::size_of::<u32>() as u32,
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows_sys::Win32::UI::WindowsAndMessaging::{WS_VISIBLE, WS_SYSMENU, WS_EX_TOPMOST, WS_EX_NOACTIVATE};
    #[test]
    fn repeated_tao_style_rebuilds_cannot_restore_caption_or_resize_border() {
        let tao = WS_CAPTION | WS_THICKFRAME | WS_VISIBLE | WS_SYSMENU;
        let clean = floating_style(tao, false);
        assert_eq!(clean & (WS_CAPTION | WS_THICKFRAME | WS_BORDER | WS_DLGFRAME), 0);
        assert_eq!(clean & (WS_VISIBLE | WS_SYSMENU | WS_POPUP), WS_VISIBLE | WS_SYSMENU | WS_POPUP);
        assert_eq!(floating_style(clean, false), clean);
        assert_eq!(floating_style(clean | WS_CAPTION | WS_THICKFRAME, false), clean);
    }
    #[test]
    fn extended_style_filter_preserves_topmost_and_focus_policy() {
        let style = WS_EX_WINDOWEDGE | WS_EX_TOPMOST | WS_EX_NOACTIVATE;
        assert_eq!(floating_style(style, true), WS_EX_TOPMOST | WS_EX_NOACTIVATE);
    }
}
