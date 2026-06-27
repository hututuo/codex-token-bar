use std::path::PathBuf;
use std::sync::OnceLock;

const SINGLE_INSTANCE_MUTEX_NAME: &str = "Local\\CodexTokenBarTauriSingleInstance";
const DASHBOARD_WINDOW_TITLE: &str = "Codex Token Bar";

static SINGLE_INSTANCE_MUTEX_HANDLE: OnceLock<usize> = OnceLock::new();

pub fn default_codex_home() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .or_else(|| {
            let drive = std::env::var_os("HOMEDRIVE")?;
            let path = std::env::var_os("HOMEPATH")?;
            let mut full = PathBuf::from(drive);
            full.push(path);
            Some(full)
        })
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".codex")
}

pub fn activate_existing_instance_and_exit() -> bool {
    use std::ptr::null;
    use windows_sys::Win32::{
        Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS},
        System::Threading::CreateMutexW,
    };

    let name = wide_null(SINGLE_INSTANCE_MUTEX_NAME);
    unsafe {
        let handle = CreateMutexW(null(), 1, name.as_ptr());
        if handle.is_null() {
            return false;
        }

        if GetLastError() == ERROR_ALREADY_EXISTS {
            let _ = CloseHandle(handle);
            activate_existing_dashboard_window();
            return true;
        }

        let _ = SINGLE_INSTANCE_MUTEX_HANDLE.set(handle as usize);
    }

    false
}

fn activate_existing_dashboard_window() {
    use std::ptr::null;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        FindWindowW, IsIconic, SetForegroundWindow, ShowWindow, SW_RESTORE,
    };

    let title = wide_null(DASHBOARD_WINDOW_TITLE);
    unsafe {
        let hwnd = FindWindowW(null(), title.as_ptr());
        if hwnd.is_null() {
            return;
        }
        if IsIconic(hwnd) != 0 {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        let _ = SetForegroundWindow(hwnd);
    }
}

fn wide_null(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_instance_uses_stable_user_scope_mutex_name() {
        assert_eq!(
            SINGLE_INSTANCE_MUTEX_NAME,
            "Local\\CodexTokenBarTauriSingleInstance"
        );
        assert_eq!(DASHBOARD_WINDOW_TITLE, "Codex Token Bar");
    }
}
