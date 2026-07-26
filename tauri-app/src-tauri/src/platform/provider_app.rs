const CODEX_BUNDLE_IDENTIFIER: &str = "com.openai.codex";
const LEGACY_APPLICATION_NAMES: &[&str] = &["Codex", "ChatGPT"];
const CODEX_DEBUG_ARGUMENTS: &[&str] = &[
    "--remote-debugging-address=127.0.0.1",
    "--remote-debugging-port=9229",
];
#[cfg(any(test, windows))]
const WINDOWS_PROCESS_NAMES: &[&str] = &["Codex.exe", "ChatGPT.exe"];
#[cfg(windows)]
const MAX_WINDOWS_PROCESSES: usize = 4096;

pub(crate) fn codex_desktop_is_running() -> Result<bool, String> {
    platform_codex_desktop_is_running()
}

pub(crate) fn relaunch_codex_with_debug_port() -> Result<(), String> {
    platform_relaunch_codex_with_debug_port()
}

pub(crate) fn managed_process_identity(pid: u32) -> Result<String, String> {
    platform_managed_process_identity(pid)
}

pub(crate) fn managed_process_command(pid: u32) -> Result<String, String> {
    platform_managed_process_command(pid)
}

pub(crate) fn process_command_contains_argument(command: &str, argument: &str) -> bool {
    if argument.is_empty() {
        return false;
    }
    command.match_indices(argument).any(|(start, matched)| {
        let before = command[..start]
            .chars()
            .next_back()
            .is_none_or(process_argument_boundary);
        let end = start + matched.len();
        let after = command[end..]
            .chars()
            .next()
            .is_none_or(process_argument_boundary);
        before && after
    })
}

fn process_argument_boundary(value: char) -> bool {
    value.is_whitespace() || matches!(value, '"' | '\'')
}

pub(crate) fn managed_process_executable_path(pid: u32) -> Result<std::path::PathBuf, String> {
    platform_managed_process_executable_path(pid)
}

pub(crate) fn focus_managed_process(pid: u32) -> Result<(), String> {
    platform_focus_managed_process(pid)
}

pub(crate) fn terminate_managed_process(pid: u32) -> Result<(), String> {
    platform_terminate_managed_process(pid)
}

#[derive(Clone, Debug)]
pub(crate) struct ManagedCodexLaunch {
    pub pid: u32,
    pub executable_path: std::path::PathBuf,
    pub user_data_marker: String,
    pub process_start_identity: String,
}

pub(crate) fn launch_managed_codex_instance(
    codex_home: &std::path::Path,
    electron_data_directory: &std::path::Path,
    working_directory: Option<&std::path::Path>,
    arguments: &[String],
) -> Result<ManagedCodexLaunch, String> {
    platform_launch_managed_codex_instance(
        codex_home,
        electron_data_directory,
        working_directory,
        arguments,
    )
}

#[cfg(target_os = "macos")]
fn platform_launch_managed_codex_instance(
    codex_home: &std::path::Path,
    electron_data_directory: &std::path::Path,
    working_directory: Option<&std::path::Path>,
    arguments: &[String],
) -> Result<ManagedCodexLaunch, String> {
    use std::collections::HashSet;
    use std::process::Command;
    use std::time::Duration;

    let executable_path = platform_locate_codex_desktop_executable()?;
    let application_path = executable_path
        .parent()
        .and_then(std::path::Path::parent)
        .and_then(std::path::Path::parent)
        .filter(|path| path.extension().and_then(|value| value.to_str()) == Some("app"))
        .ok_or_else(|| {
            "Codex 可执行文件不在标准 .app 包内，无法通过 LaunchServices 安全多开".to_string()
        })?;
    let user_data_marker = format!("--user-data-dir={}", electron_data_directory.display());
    let preexisting = macos_process_ids_with_marker(&user_data_marker)?
        .into_iter()
        .collect::<HashSet<_>>();
    let mut command = Command::new("/usr/bin/open");
    command
        .arg("-n")
        .arg("-a")
        .arg(application_path)
        .arg("--env")
        .arg(macos_open_environment_argument("CODEX_HOME", codex_home)?)
        .arg("--env")
        .arg(macos_open_environment_argument(
            "CODEX_ELECTRON_USER_DATA_PATH",
            electron_data_directory,
        )?);
    if let Some(directory) = working_directory {
        command
            .current_dir(directory)
            .arg("--env")
            .arg(macos_open_environment_argument("PWD", directory)?)
            .arg("--env")
            .arg(macos_open_environment_argument(
                "CODEX_WORKING_DIRECTORY",
                directory,
            )?);
    }
    command.arg("--args").arg(&user_data_marker).args(arguments);
    let output = command
        .output()
        .map_err(|error| format!("通过 LaunchServices 启动 Codex 实例失败：{error}"))?;
    if !output.status.success() {
        return Err(format!(
            "通过 LaunchServices 启动 Codex 实例失败：{}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }

    let mut last_error = "尚未发现匹配实例进程".to_string();
    for _ in 0..100 {
        match macos_process_ids_with_marker(&user_data_marker) {
            Ok(pids) => {
                for pid in pids {
                    if preexisting.contains(&pid) {
                        continue;
                    }
                    let candidate = match platform_managed_process_executable_path(pid) {
                        Ok(path) => path,
                        Err(error) => {
                            last_error = error;
                            continue;
                        }
                    };
                    if candidate != executable_path {
                        continue;
                    }
                    match platform_managed_process_identity(pid) {
                        Ok(process_start_identity) => {
                            return Ok(ManagedCodexLaunch {
                                pid,
                                executable_path,
                                user_data_marker,
                                process_start_identity,
                            });
                        }
                        Err(error) => last_error = error,
                    }
                }
            }
            Err(error) => last_error = error,
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let cleanup = terminate_new_macos_launches(&user_data_marker, &executable_path, &preexisting);
    Err(match cleanup {
        Ok(0) => {
            format!("LaunchServices 已接受启动请求，但无法核对真实 Codex 主进程：{last_error}")
        }
        Ok(count) => format!(
            "LaunchServices 已接受启动请求，但无法核对真实 Codex 主进程；已终止 {count} 个未登记候选进程：{last_error}"
        ),
        Err(error) => format!(
            "LaunchServices 已接受启动请求，但无法核对真实 Codex 主进程：{last_error}；清理未登记候选进程也失败：{error}"
        ),
    })
}

#[cfg(target_os = "macos")]
fn macos_open_environment_argument(
    name: &str,
    value: &std::path::Path,
) -> Result<std::ffi::OsString, String> {
    let value = value
        .to_str()
        .ok_or_else(|| format!("{name} 路径不是有效 UTF-8，LaunchServices 无法安全传递"))?;
    Ok(std::ffi::OsString::from(format!("{name}={value}")))
}

#[cfg(target_os = "macos")]
fn macos_process_ids_with_marker(marker: &str) -> Result<Vec<u32>, String> {
    let output = std::process::Command::new("/bin/ps")
        .args(["-axo", "pid=,command="])
        .output()
        .map_err(|error| format!("枚举 Codex 实例进程失败：{error}"))?;
    if !output.status.success() {
        return Err("枚举 Codex 实例进程失败".into());
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| {
            let line = line.trim_start();
            let split = line.find(char::is_whitespace)?;
            if !process_command_contains_argument(&line[split..], marker) {
                return None;
            }
            line[..split].parse::<u32>().ok()
        })
        .collect())
}

#[cfg(target_os = "macos")]
fn terminate_new_macos_launches(
    marker: &str,
    executable_path: &std::path::Path,
    preexisting: &std::collections::HashSet<u32>,
) -> Result<usize, String> {
    let mut terminated = 0_usize;
    let mut failures = Vec::new();
    for pid in macos_process_ids_with_marker(marker)? {
        if preexisting.contains(&pid) {
            continue;
        }
        let candidate = match platform_managed_process_executable_path(pid) {
            Ok(candidate) => candidate,
            Err(error) => {
                failures.push(error);
                continue;
            }
        };
        if candidate != executable_path {
            continue;
        }
        match platform_terminate_managed_process(pid) {
            Ok(()) => terminated += 1,
            Err(error) => failures.push(error),
        }
    }
    if failures.is_empty() {
        Ok(terminated)
    } else {
        Err(failures.join("；"))
    }
}

#[cfg(windows)]
fn platform_launch_managed_codex_instance(
    codex_home: &std::path::Path,
    electron_data_directory: &std::path::Path,
    working_directory: Option<&std::path::Path>,
    arguments: &[String],
) -> Result<ManagedCodexLaunch, String> {
    use std::process::{Command, Stdio};
    use std::time::Duration;

    let executable_path = platform_locate_codex_desktop_executable()?;
    let user_data_marker = format!("--user-data-dir={}", electron_data_directory.display());
    let mut command = Command::new(&executable_path);
    command
        .env("CODEX_HOME", codex_home)
        .env("CODEX_ELECTRON_USER_DATA_PATH", electron_data_directory)
        .arg(&user_data_marker)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    if let Some(directory) = working_directory {
        command.current_dir(directory);
    }
    let mut child = command
        .spawn()
        .map_err(|error| format!("启动 Codex 实例失败：{error}"))?;
    let pid = child.id();
    let mut last_error = "尚未读取进程身份".to_string();
    for _ in 0..40 {
        match platform_managed_process_identity(pid) {
            Ok(process_start_identity) => {
                match (
                    platform_managed_process_executable_path(pid),
                    platform_managed_process_command(pid),
                ) {
                    (Ok(candidate), Ok(command))
                        if windows_paths_equal(&candidate, &executable_path)
                            && process_command_contains_argument(&command, &user_data_marker) =>
                    {
                        drop(child);
                        return Ok(ManagedCodexLaunch {
                            pid,
                            executable_path,
                            user_data_marker,
                            process_start_identity,
                        });
                    }
                    (Ok(candidate), Ok(_)) => {
                        last_error =
                            format!("进程路径或独立数据目录标记不匹配：{}", candidate.display());
                    }
                    (Err(error), _) | (_, Err(error)) => last_error = error,
                }
            }
            Err(error) => last_error = error,
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let cleanup = child.kill().and_then(|_| child.wait());
    Err(match cleanup {
        Ok(_) => format!("Codex 进程启动后无法核对身份，已终止未登记实例：{last_error}"),
        Err(error) => {
            format!("Codex 进程启动后无法核对身份：{last_error}；终止未登记实例也失败：{error}")
        }
    })
}

#[cfg(windows)]
fn windows_paths_equal(left: &std::path::Path, right: &std::path::Path) -> bool {
    left.to_string_lossy()
        .eq_ignore_ascii_case(&right.to_string_lossy())
}

#[cfg(not(any(target_os = "macos", windows)))]
fn platform_launch_managed_codex_instance(
    _codex_home: &std::path::Path,
    _electron_data_directory: &std::path::Path,
    _working_directory: Option<&std::path::Path>,
    _arguments: &[String],
) -> Result<ManagedCodexLaunch, String> {
    Err("当前 Linux 版本暂不支持 Codex 桌面应用多开".into())
}

#[cfg(target_os = "macos")]
fn platform_locate_codex_desktop_executable() -> Result<std::path::PathBuf, String> {
    use objc2_app_kit::NSWorkspace;
    use objc2_foundation::NSString;

    let workspace = NSWorkspace::sharedWorkspace();
    let application_url = workspace
        .URLForApplicationWithBundleIdentifier(&NSString::from_str(CODEX_BUNDLE_IDENTIFIER))
        .ok_or_else(|| "没有找到 Codex 桌面应用".to_string())?;
    let application_path = application_url
        .path()
        .map(|path| std::path::PathBuf::from(path.to_string()))
        .ok_or_else(|| "Codex 桌面应用路径无效".to_string())?;
    let macos_directory = application_path.join("Contents").join("MacOS");
    for name in ["Codex", "ChatGPT"] {
        let candidate = macos_directory.join(name);
        if candidate.is_file() {
            return candidate
                .canonicalize()
                .map_err(|error| format!("无法解析 Codex 可执行文件：{error}"));
        }
    }
    let info_path = application_path.join("Contents").join("Info.plist");
    let info = plist::Value::from_file(&info_path)
        .map_err(|error| format!("读取 Codex Info.plist 失败：{error}"))?;
    let executable = info
        .as_dictionary()
        .and_then(|dictionary| dictionary.get("CFBundleExecutable"))
        .and_then(plist::Value::as_string)
        .ok_or_else(|| "Codex Info.plist 缺少 CFBundleExecutable".to_string())?;
    macos_directory
        .join(executable)
        .canonicalize()
        .map_err(|error| format!("无法解析 Codex 可执行文件：{error}"))
}

#[cfg(windows)]
fn platform_locate_codex_desktop_executable() -> Result<std::path::PathBuf, String> {
    let mut candidates = Vec::new();
    if let Some(path) = std::env::var_os("CODEX_DESKTOP_EXECUTABLE") {
        candidates.push(std::path::PathBuf::from(path));
    }
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        let local = std::path::PathBuf::from(local);
        candidates.push(local.join("Programs").join("Codex").join("Codex.exe"));
        candidates.push(local.join("Programs").join("ChatGPT").join("ChatGPT.exe"));
    }
    if let Some(program_files) = std::env::var_os("ProgramFiles") {
        let program_files = std::path::PathBuf::from(program_files);
        candidates.push(program_files.join("Codex").join("Codex.exe"));
        candidates.push(program_files.join("ChatGPT").join("ChatGPT.exe"));
    }
    candidates
        .into_iter()
        .find(|path| path.is_file())
        .ok_or_else(|| {
            "没有找到可直接启动的 Codex 桌面应用；Microsoft Store 受保护安装暂不支持多开".into()
        })
        .and_then(|path| {
            path.canonicalize()
                .map_err(|error| format!("无法解析 Codex 可执行文件：{error}"))
        })
}

#[cfg(not(any(target_os = "macos", windows)))]
fn platform_locate_codex_desktop_executable() -> Result<std::path::PathBuf, String> {
    Err("当前 Linux 版本暂不支持 Codex 桌面应用多开".into())
}

#[cfg(unix)]
fn process_ps_field(pid: u32, field: &str) -> Result<String, String> {
    let output = std::process::Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", field])
        .output()
        .map_err(|error| format!("检查进程 {pid} 失败：{error}"))?;
    if !output.status.success() {
        return Err(format!("进程 {pid} 已结束或无法读取"));
    }
    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if value.is_empty() {
        Err(format!("进程 {pid} 已结束或无法读取"))
    } else {
        Ok(value)
    }
}

#[cfg(target_os = "macos")]
fn platform_managed_process_identity(pid: u32) -> Result<String, String> {
    process_ps_field(pid, "lstart=")
}

#[cfg(target_os = "linux")]
fn platform_managed_process_identity(pid: u32) -> Result<String, String> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat"))
        .map_err(|error| format!("读取进程 {pid} 启动标识失败：{error}"))?;
    let end = stat
        .rfind(')')
        .ok_or_else(|| "Linux 进程状态格式无效".to_string())?;
    let fields = stat[end + 2..].split_whitespace().collect::<Vec<_>>();
    fields
        .get(19)
        .map(|value| (*value).to_string())
        .ok_or_else(|| "Linux 进程状态缺少启动标识".to_string())
}

#[cfg(unix)]
fn platform_managed_process_command(pid: u32) -> Result<String, String> {
    process_ps_field(pid, "command=")
}

#[cfg(target_os = "macos")]
fn platform_managed_process_executable_path(pid: u32) -> Result<std::path::PathBuf, String> {
    let command = platform_managed_process_command(pid)?;
    let app_marker = ".app/Contents/MacOS/";
    let end = command
        .find(app_marker)
        .and_then(|index| {
            command[index + app_marker.len()..]
                .find(' ')
                .map(|tail| index + app_marker.len() + tail)
        })
        .unwrap_or_else(|| command.find(" --").unwrap_or(command.len()));
    std::path::PathBuf::from(command[..end].trim())
        .canonicalize()
        .map_err(|error| format!("无法核对进程 {pid} 的可执行文件：{error}"))
}

#[cfg(target_os = "linux")]
fn platform_managed_process_executable_path(pid: u32) -> Result<std::path::PathBuf, String> {
    std::fs::read_link(format!("/proc/{pid}/exe"))
        .map_err(|error| format!("无法核对进程 {pid} 的可执行文件：{error}"))
}

#[cfg(unix)]
fn platform_focus_managed_process(pid: u32) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let script = format!(
            "tell application \"System Events\" to set frontmost of first process whose unix id is {pid} to true"
        );
        let output = std::process::Command::new("/usr/bin/osascript")
            .args(["-e", &script])
            .output()
            .map_err(|error| format!("聚焦 Codex 实例失败：{error}"))?;
        if output.status.success() {
            return Ok(());
        }
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    #[cfg(not(target_os = "macos"))]
    Err("当前 Linux 版本暂不支持聚焦 Codex 桌面实例".into())
}

#[cfg(unix)]
fn platform_terminate_managed_process(pid: u32) -> Result<(), String> {
    let result = unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
    if result == 0 {
        Ok(())
    } else {
        Err(format!(
            "停止进程 {pid} 失败：{}",
            std::io::Error::last_os_error()
        ))
    }
}

#[cfg(windows)]
fn windows_process_handle(
    pid: u32,
    access: u32,
) -> Result<windows_sys::Win32::Foundation::HANDLE, String> {
    let handle = unsafe { windows_sys::Win32::System::Threading::OpenProcess(access, 0, pid) };
    if handle.is_null() {
        Err(format!(
            "打开进程 {pid} 失败：{}",
            std::io::Error::last_os_error()
        ))
    } else {
        Ok(handle)
    }
}

#[cfg(windows)]
fn platform_managed_process_identity(pid: u32) -> Result<String, String> {
    use windows_sys::Win32::{
        Foundation::{CloseHandle, FILETIME},
        System::Threading::{GetProcessTimes, PROCESS_QUERY_LIMITED_INFORMATION},
    };
    let handle = windows_process_handle(pid, PROCESS_QUERY_LIMITED_INFORMATION)?;
    let mut creation = FILETIME::default();
    let mut exit = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    let ok = unsafe { GetProcessTimes(handle, &mut creation, &mut exit, &mut kernel, &mut user) };
    unsafe { CloseHandle(handle) };
    if ok == 0 {
        return Err(format!(
            "读取进程 {pid} 启动标识失败：{}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(format!(
        "{:08x}{:08x}",
        creation.dwHighDateTime, creation.dwLowDateTime
    ))
}

#[cfg(windows)]
fn platform_managed_process_executable_path(pid: u32) -> Result<std::path::PathBuf, String> {
    use windows_sys::Win32::{
        Foundation::CloseHandle,
        System::Threading::{QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION},
    };
    let handle = windows_process_handle(pid, PROCESS_QUERY_LIMITED_INFORMATION)?;
    let mut buffer = vec![0_u16; 32_768];
    let mut length = buffer.len() as u32;
    let ok = unsafe { QueryFullProcessImageNameW(handle, 0, buffer.as_mut_ptr(), &mut length) };
    unsafe { CloseHandle(handle) };
    if ok == 0 {
        return Err(format!(
            "读取进程 {pid} 路径失败：{}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(std::path::PathBuf::from(String::from_utf16_lossy(
        &buffer[..length as usize],
    )))
}

#[cfg(windows)]
fn platform_managed_process_command(pid: u32) -> Result<String, String> {
    let script = format!(
        "$p=Get-CimInstance Win32_Process -Filter 'ProcessId = {pid}'; if($null -eq $p){{exit 3}}; [Console]::Out.Write($p.CommandLine)"
    );
    let output = std::process::Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .output()
        .map_err(|error| format!("读取进程 {pid} 命令行失败：{error}"))?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    } else {
        Err(format!("进程 {pid} 已结束或命令行不可读"))
    }
}

#[cfg(windows)]
fn platform_focus_managed_process(pid: u32) -> Result<(), String> {
    use windows_sys::Win32::{
        Foundation::{BOOL, HWND, LPARAM},
        UI::WindowsAndMessaging::{
            EnumWindows, GetWindowThreadProcessId, IsWindowVisible, SetForegroundWindow,
            ShowWindow, SW_RESTORE,
        },
    };
    struct FocusContext {
        pid: u32,
        found: bool,
    }
    unsafe extern "system" fn callback(window: HWND, parameter: LPARAM) -> BOOL {
        let context = &mut *(parameter as *mut FocusContext);
        let mut window_pid = 0_u32;
        GetWindowThreadProcessId(window, &mut window_pid);
        if window_pid == context.pid && IsWindowVisible(window) != 0 {
            ShowWindow(window, SW_RESTORE);
            context.found = SetForegroundWindow(window) != 0;
            return 0;
        }
        1
    }
    let mut context = FocusContext { pid, found: false };
    unsafe {
        EnumWindows(
            Some(callback),
            (&mut context as *mut FocusContext) as LPARAM,
        )
    };
    if context.found {
        Ok(())
    } else {
        Err(format!("没有找到进程 {pid} 的可见窗口"))
    }
}

#[cfg(windows)]
fn platform_terminate_managed_process(pid: u32) -> Result<(), String> {
    use windows_sys::Win32::{
        Foundation::CloseHandle,
        System::Threading::{TerminateProcess, PROCESS_TERMINATE},
    };
    let handle = windows_process_handle(pid, PROCESS_TERMINATE)?;
    let ok = unsafe { TerminateProcess(handle, 0) };
    unsafe { CloseHandle(handle) };
    if ok == 0 {
        Err(format!(
            "停止进程 {pid} 失败：{}",
            std::io::Error::last_os_error()
        ))
    } else {
        Ok(())
    }
}

fn codex_debug_arguments() -> &'static [&'static str] {
    CODEX_DEBUG_ARGUMENTS
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
            let localized_name = application
                .localizedName()
                .map(|value| value.to_string());
            macos_application_matches(bundle_identifier.as_deref(), localized_name.as_deref())
        }))
}

#[cfg(target_os = "macos")]
fn platform_relaunch_codex_with_debug_port() -> Result<(), String> {
    use objc2_app_kit::NSWorkspace;
    use objc2_foundation::NSString;
    use std::process::Command;
    use std::time::{Duration, Instant};

    let workspace = NSWorkspace::sharedWorkspace();
    let running = workspace
        .runningApplications()
        .iter()
        .filter(|application| {
            if application.isTerminated() {
                return false;
            }
            let bundle_identifier = application
                .bundleIdentifier()
                .map(|value| value.to_string());
            let localized_name = application.localizedName().map(|value| value.to_string());
            macos_application_matches(bundle_identifier.as_deref(), localized_name.as_deref())
        })
        .collect::<Vec<_>>();
    let application_url = running
        .iter()
        .find_map(|application| application.bundleURL())
        .or_else(|| {
            workspace.URLForApplicationWithBundleIdentifier(&NSString::from_str(
                CODEX_BUNDLE_IDENTIFIER,
            ))
        })
        .ok_or_else(|| "没有找到 Codex 桌面应用".to_string())?;
    let application_path = application_url
        .path()
        .map(|path| path.to_string())
        .filter(|path| !path.is_empty())
        .ok_or_else(|| "Codex 桌面应用路径无效".to_string())?;

    for application in &running {
        if !application.terminate() {
            return Err("Codex 拒绝退出，请先保存正在编辑的内容后重试".into());
        }
    }
    let deadline = Instant::now() + Duration::from_secs(10);
    while running.iter().any(|application| !application.isTerminated()) {
        if Instant::now() >= deadline {
            return Err("等待 Codex 退出超时".into());
        }
        std::thread::sleep(Duration::from_millis(100));
    }

    let output = Command::new("/usr/bin/open")
        .args(["-na", application_path.as_str(), "--args"])
        .args(codex_debug_arguments())
        .output()
        .map_err(|error| format!("重新打开 Codex 失败：{error}"))?;
    if output.status.success() {
        return Ok(());
    }
    let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
    Err(if detail.is_empty() {
        "重新打开 Codex 失败".into()
    } else {
        format!("重新打开 Codex 失败：{detail}")
    })
}

#[cfg(not(target_os = "macos"))]
fn platform_relaunch_codex_with_debug_port() -> Result<(), String> {
    Err("当前平台暂不支持自动重启 Codex；请以 --remote-debugging-port=9229 启动 Codex".into())
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
    fn debug_launch_is_bound_to_the_loopback_interface() {
        assert_eq!(
            codex_debug_arguments(),
            [
                "--remote-debugging-address=127.0.0.1",
                "--remote-debugging-port=9229",
            ]
        );
    }

    #[test]
    fn process_marker_matching_requires_argument_boundaries() {
        let marker = "--user-data-dir=/tmp/Codex Home";
        assert!(process_command_contains_argument(
            "/Applications/Codex --user-data-dir=/tmp/Codex Home --new-window",
            marker
        ));
        assert!(process_command_contains_argument(
            r#""C:\Codex.exe" "--user-data-dir=/tmp/Codex Home""#,
            marker
        ));
        assert!(!process_command_contains_argument(
            "/Applications/Codex --user-data-dir=/tmp/Codex Home-copy",
            marker
        ));
        assert!(!process_command_contains_argument(
            "/Applications/Codex --other=--user-data-dir=/tmp/Codex Home",
            marker
        ));
    }

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

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_open_environment_argument_preserves_paths_with_spaces() {
        assert_eq!(
            macos_open_environment_argument(
                "CODEX_HOME",
                std::path::Path::new("/Users/test/Application Support/Codex Home")
            )
            .unwrap(),
            std::ffi::OsString::from("CODEX_HOME=/Users/test/Application Support/Codex Home")
        );
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
