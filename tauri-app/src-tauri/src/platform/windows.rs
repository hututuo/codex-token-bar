use std::path::PathBuf;
use std::sync::{atomic::AtomicBool, OnceLock};

use super::startup::{secondary_instance_action, SecondaryInstanceAction, StartupLaunchMode};

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

pub fn activate_existing_instance_and_exit(mode: StartupLaunchMode) -> bool {
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
            return false;
        }
        let mutex = CreateMutexW(null(), 1, mutex_name.as_ptr());
        if mutex.is_null() {
            let _ = CloseHandle(event);
            return false;
        }
        let owns_primary_mutex = GetLastError() != ERROR_ALREADY_EXISTS;

        match secondary_instance_action(owns_primary_mutex, mode) {
            SecondaryInstanceAction::ContinueAsPrimary => {
                let _ = SINGLE_INSTANCE_MUTEX_HANDLE.set(mutex as usize);
                let _ = SINGLE_INSTANCE_ACTIVATION_EVENT_HANDLE.set(event as usize);
                false
            }
            SecondaryInstanceAction::SignalPrimaryAndExit => {
                let _ = SetEvent(event);
                let _ = CloseHandle(mutex);
                let _ = CloseHandle(event);
                true
            }
            SecondaryInstanceAction::ExitSilently => {
                let _ = CloseHandle(mutex);
                let _ = CloseHandle(event);
                true
            }
        }
    }
}

pub fn start_instance_activation_listener(app: tauri::AppHandle) {
    use windows_sys::Win32::{
        Foundation::WAIT_OBJECT_0,
        System::Threading::{WaitForSingleObject, INFINITE},
    };

    let Some(event) = SINGLE_INSTANCE_ACTIVATION_EVENT_HANDLE.get().copied() else {
        return;
    };
    super::startup::start_activation_listener_once(&ACTIVATION_LISTENER_STARTED, || {
        std::thread::spawn(move || {
            super::startup::consume_activation_signals(
                || unsafe { WaitForSingleObject(event as _, INFINITE) == WAIT_OBJECT_0 },
                || {
                    let dispatch = app.clone();
                    let activation = app.clone();
                    let _ = dispatch.run_on_main_thread(move || {
                        let _ = super::surfaces::show_dashboard_window(&activation);
                    });
                },
            );
        });
    });
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
