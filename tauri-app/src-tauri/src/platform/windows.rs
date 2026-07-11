use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    OnceLock,
};

use super::startup::{
    resolve_single_instance_launch, SingleInstanceLaunchOutcome, StartupLaunchMode,
};

const SINGLE_INSTANCE_MUTEX_NAME: &str = "Local\\CodexTokenBarTauriSingleInstance";
const SINGLE_INSTANCE_ACTIVATION_EVENT_NAME: &str =
    "Local\\CodexTokenBarTauriSingleInstanceActivation";

static SINGLE_INSTANCE_MUTEX_HANDLE: OnceLock<usize> = OnceLock::new();
static SINGLE_INSTANCE_ACTIVATION_EVENT_HANDLE: OnceLock<usize> = OnceLock::new();
static ACTIVATION_LISTENER_STARTED: AtomicBool = AtomicBool::new(false);

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

pub fn prepare_single_instance(mode: StartupLaunchMode) -> SingleInstanceLaunchOutcome {
    use std::ptr::null;
    use windows_sys::Win32::{
        Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS},
        System::Threading::{CreateEventW, CreateMutexW, SetEvent},
    };

    let event_name = wide_null(SINGLE_INSTANCE_ACTIVATION_EVENT_NAME);
    let mutex_name = wide_null(SINGLE_INSTANCE_MUTEX_NAME);
    unsafe {
        // Create/open the auto-reset event before claiming the mutex. A secondary arriving in
        // the primary's setup gap can signal it immediately; the signal remains pending until
        // the listener begins waiting.
        let event = CreateEventW(null(), 0, 0, event_name.as_ptr());
        if event.is_null() {
            return SingleInstanceLaunchOutcome::FatalFailure(format!(
                "创建单实例激活事件失败（Windows error {}）",
                GetLastError()
            ));
        }
        let mutex = CreateMutexW(null(), 1, mutex_name.as_ptr());
        if mutex.is_null() {
            let error = GetLastError();
            let _ = CloseHandle(event);
            return SingleInstanceLaunchOutcome::FatalFailure(format!(
                "创建单实例互斥锁失败（Windows error {error}）"
            ));
        }
        let owns_primary_mutex = GetLastError() != ERROR_ALREADY_EXISTS;

        let outcome = resolve_single_instance_launch(owns_primary_mutex, mode, || {
            if SetEvent(event) == 0 {
                Err(format!("Windows error {}", GetLastError()))
            } else {
                Ok(())
            }
        });
        match outcome {
            SingleInstanceLaunchOutcome::ContinueAsPrimary => {
                if SINGLE_INSTANCE_MUTEX_HANDLE.set(mutex as usize).is_err()
                    || SINGLE_INSTANCE_ACTIVATION_EVENT_HANDLE.set(event as usize).is_err()
                {
                    let _ = CloseHandle(mutex);
                    let _ = CloseHandle(event);
                    SingleInstanceLaunchOutcome::FatalFailure(
                        "单实例控制器已被重复初始化".into(),
                    )
                } else {
                    SingleInstanceLaunchOutcome::ContinueAsPrimary
                }
            }
            secondary => {
                let _ = CloseHandle(mutex);
                let _ = CloseHandle(event);
                secondary
            }
        }
    }
}

pub fn report_startup_failure(error: &str) {
    use std::ptr::null_mut;
    use windows_sys::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONERROR, MB_OK};

    eprintln!("Codex Token Bar: fatal startup failure: {error}");
    let message = wide_null(error);
    let title = wide_null("Codex Token Bar 启动失败");
    unsafe {
        let _ = MessageBoxW(
            null_mut(),
            message.as_ptr(),
            title.as_ptr(),
            MB_OK | MB_ICONERROR,
        );
    }
}

pub fn start_instance_activation_listener(app: tauri::AppHandle) {
    use windows_sys::Win32::{
        Foundation::{GetLastError, WAIT_FAILED, WAIT_OBJECT_0},
        System::Threading::{WaitForSingleObject, INFINITE},
    };

    let Some(event) = SINGLE_INSTANCE_ACTIVATION_EVENT_HANDLE.get().copied() else {
        return;
    };
    super::startup::start_activation_listener_once(&ACTIVATION_LISTENER_STARTED, || {
        std::thread::spawn(move || {
            super::startup::consume_activation_signals(
                || unsafe {
                    match WaitForSingleObject(event as _, INFINITE) {
                        WAIT_OBJECT_0 => Ok(true),
                        WAIT_FAILED => Err(format!(
                            "等待主实例激活事件失败（Windows error {}）",
                            GetLastError()
                        )),
                        code => Err(format!("等待主实例激活事件返回异常状态 {code}")),
                    }
                },
                || {
                    let dispatch = app.clone();
                    let activation = app.clone();
                    dispatch
                        .run_on_main_thread(move || {
                            if let Err(error) = super::surfaces::show_dashboard_window(&activation) {
                                report_activation_error(&format!("显示主界面失败：{error}"));
                            }
                        })
                        .map_err(|error| format!("调度主实例激活失败：{error}"))
                },
                report_activation_error,
            );
            ACTIVATION_LISTENER_STARTED.store(false, Ordering::Release);
        });
    });
}

fn report_activation_error(error: &str) {
    crate::core::startup_trace::mark(&format!("windows instance activation failed: {error}"));
    eprintln!("Codex Token Bar: Windows instance activation failed: {error}");
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
        assert_eq!(
            SINGLE_INSTANCE_ACTIVATION_EVENT_NAME,
            "Local\\CodexTokenBarTauriSingleInstanceActivation"
        );
    }
}
