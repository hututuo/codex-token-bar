const CODEX_BUNDLE_IDENTIFIER: &str = "com.openai.codex";
const LEGACY_APPLICATION_NAMES: &[&str] = &["Codex", "ChatGPT"];
#[cfg(any(test, windows))]
const WINDOWS_PROCESS_NAMES: &[&str] = &["Codex.exe", "ChatGPT.exe"];
#[cfg(windows)]
const MAX_WINDOWS_PROCESSES: usize = 4096;

pub(crate) fn codex_desktop_is_running() -> Result<bool, String> {
    platform_codex_desktop_is_running()
}

fn macos_application_matches(
    bundle_identifier: Option<&str>,
    localized_name: Option<&str>,
) -> bool {
    match bundle_identifier.filter(|identifier| !identifier.is_empty()) {
        Some(identifier) => identifier == CODEX_BUNDLE_IDENTIFIER,
        None => localized_name.is_some_and(|name| LEGACY_APPLICATION_NAMES.contains(&name)),
    }
}

#[cfg(any(test, windows))]
fn windows_process_name_matches(name: &str) -> bool {
    WINDOWS_PROCESS_NAMES
        .iter()
        .any(|expected| name.eq_ignore_ascii_case(expected))
}

#[cfg(any(test, windows))]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WindowsProcessIteration {
    Continue,
    Exhausted,
}

#[cfg(any(test, windows))]
fn classify_process32_next(
    succeeded: bool,
    last_error: u32,
) -> Result<WindowsProcessIteration, String> {
    if succeeded {
        return Ok(WindowsProcessIteration::Continue);
    }
    const ERROR_NO_MORE_FILES_CODE: u32 = 18;
    if last_error == ERROR_NO_MORE_FILES_CODE {
        Ok(WindowsProcessIteration::Exhausted)
    } else {
        Err(format!(
            "Windows Process32NextW 失败，错误码 {last_error}，已拒绝判定为未运行。"
        ))
    }
}

#[cfg(test)]
fn probe_windows_process_names<'a>(
    names: impl IntoIterator<Item = &'a str>,
    max_processes: usize,
) -> Result<bool, String> {
    let mut names = names.into_iter();
    for _ in 0..max_processes {
        let Some(name) = names.next() else {
            return Ok(false);
        };
        if windows_process_name_matches(name) {
            return Ok(true);
        }
    }
    if names.next().is_some() {
        Err(format!(
            "Windows 进程列表超过检查上限 {max_processes}，拒绝判定为未运行。"
        ))
    } else {
        Ok(false)
    }
}

#[cfg(target_os = "macos")]
fn platform_codex_desktop_is_running() -> Result<bool, String> {
    use objc2_app_kit::NSWorkspace;

    Ok(NSWorkspace::sharedWorkspace()
        .runningApplications()
        .iter()
        .filter(|application| !application.isTerminated())
        .any(|application| {
            let bundle_identifier = application
                .bundleIdentifier()
                .map(|value| value.to_string());
            let localized_name = application.localizedName().map(|value| value.to_string());
            macos_application_matches(bundle_identifier.as_deref(), localized_name.as_deref())
        }))
}

#[cfg(windows)]
fn platform_codex_desktop_is_running() -> Result<bool, String> {
    use std::mem::{size_of, zeroed};
    use windows_sys::Win32::{
        Foundation::{CloseHandle, GetLastError, INVALID_HANDLE_VALUE},
        System::Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
            TH32CS_SNAPPROCESS,
        },
    };

    struct SnapshotHandle(windows_sys::Win32::Foundation::HANDLE);
    impl Drop for SnapshotHandle {
        fn drop(&mut self) {
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }

    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Err(format!(
            "检查 Codex Windows 进程失败：{}",
            std::io::Error::last_os_error()
        ));
    }
    let _snapshot_guard = SnapshotHandle(snapshot);
    let mut entry: PROCESSENTRY32W = unsafe { zeroed() };
    entry.dwSize = u32::try_from(size_of::<PROCESSENTRY32W>())
        .map_err(|_| "Windows 进程结构大小无效".to_string())?;
    if unsafe { Process32FirstW(snapshot, &mut entry) } == 0 {
        return Err(format!(
            "读取 Codex Windows 进程列表失败：{}",
            std::io::Error::last_os_error()
        ));
    }

    for _ in 0..MAX_WINDOWS_PROCESSES {
        let length = entry
            .szExeFile
            .iter()
            .position(|unit| *unit == 0)
            .unwrap_or(entry.szExeFile.len());
        let executable = String::from_utf16_lossy(&entry.szExeFile[..length]);
        if windows_process_name_matches(&executable) {
            return Ok(true);
        }
        let next_succeeded = unsafe { Process32NextW(snapshot, &mut entry) } != 0;
        let last_error = if next_succeeded {
            0
        } else {
            unsafe { GetLastError() }
        };
        match classify_process32_next(next_succeeded, last_error)? {
            WindowsProcessIteration::Continue => {}
            WindowsProcessIteration::Exhausted => return Ok(false),
        }
    }
    Err(format!(
        "Windows 进程列表超过检查上限 {MAX_WINDOWS_PROCESSES}，为避免误判，已拒绝 Provider 写操作。"
    ))
}

#[cfg(not(any(target_os = "macos", windows)))]
fn platform_codex_desktop_is_running() -> Result<bool, String> {
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn macos_matcher_prefers_bundle_identity_and_uses_exact_name_only_without_identity() {
        assert!(macos_application_matches(
            Some("com.openai.codex"),
            Some("Renamed Desktop")
        ));
        assert!(macos_application_matches(None, Some("Codex")));
        assert!(macos_application_matches(None, Some("ChatGPT")));
        assert!(!macos_application_matches(
            Some("com.example.other"),
            Some("Codex")
        ));
        assert!(!macos_application_matches(None, Some("Codex Helper")));
        assert!(!macos_application_matches(None, None));
    }

    #[test]
    fn windows_process_probe_is_exact_case_insensitive_and_bounded() {
        assert_eq!(
            probe_windows_process_names(["explorer.exe", "CODEX.EXE"], 32),
            Ok(true)
        );
        assert_eq!(probe_windows_process_names(["ChatGPT.exe"], 32), Ok(true));
        assert_eq!(
            probe_windows_process_names(["codex-helper.exe", "not-chatgpt.exe"], 32),
            Ok(false)
        );

        let mut names = vec!["unrelated.exe"; 33];
        names.push("Codex.exe");
        assert!(probe_windows_process_names(names, 32).is_err());
    }

    #[test]
    fn windows_process32_next_distinguishes_exhaustion_from_native_failure() {
        assert_eq!(
            classify_process32_next(true, 5),
            Ok(WindowsProcessIteration::Continue)
        );
        assert_eq!(
            classify_process32_next(false, 18),
            Ok(WindowsProcessIteration::Exhausted)
        );
        let error = classify_process32_next(false, 5).unwrap_err();
        assert!(error.contains("5"), "{error}");
    }
}
