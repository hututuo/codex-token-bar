use crate::models::AutostartStatus;
use std::path::Path;
use winreg::enums::{HKEY_CURRENT_USER, KEY_READ, KEY_SET_VALUE};
use winreg::{RegKey, RegValue};

const RUN_KEY: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const STARTUP_APPROVED_KEY: &str =
    "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run";
const STARTUP_APPROVED_ENABLED: [u8; 12] = [
    0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

pub(crate) fn read(app: &tauri::AppHandle) -> Result<AutostartStatus, String> {
    let value_name = app.package_info().name.to_string();
    let command = read_run_command(&value_name)?;
    if let Some(command) = command.as_deref() {
        let executable = current_executable()?;
        if !command_targets_executable(command, &executable) {
            return Ok(external_registration_status());
        }
    }
    let enabled = command.is_some() && startup_approved_enabled(&value_name)?;
    Ok(AutostartStatus {
        available: true,
        enabled,
        status: if enabled { "enabled" } else { "disabled" }.into(),
        message: if enabled {
            "已开启开机自启。".into()
        } else {
            "未开启开机自启。".into()
        },
    })
}

pub(crate) fn set(app: &tauri::AppHandle, enabled: bool) -> Result<AutostartStatus, String> {
    let value_name = app.package_info().name.to_string();
    if let Some(command) = read_run_command(&value_name)? {
        let executable = current_executable()?;
        if !command_targets_executable(&command, &executable) {
            return Ok(external_registration_status());
        }
    }
    if enabled {
        let command = current_autostart_command()?;
        let (run, _) = RegKey::predef(HKEY_CURRENT_USER)
            .create_subkey(RUN_KEY)
            .map_err(|error| format!("打开 Windows 自启动注册表失败：{error}"))?;
        run.set_value(&value_name, &command)
            .map_err(|error| format!("写入 Windows 自启动注册项失败：{error}"))?;
        let (approved, _) = RegKey::predef(HKEY_CURRENT_USER)
            .create_subkey(STARTUP_APPROVED_KEY)
            .map_err(|error| format!("打开 Windows 自启动批准状态失败：{error}"))?;
        approved
            .set_raw_value(
                &value_name,
                &RegValue {
                    vtype: winreg::enums::RegType::REG_BINARY,
                    bytes: STARTUP_APPROVED_ENABLED.to_vec(),
                },
            )
            .map_err(|error| format!("写入 Windows 自启动批准状态失败：{error}"))?;
    } else {
        if let Ok(run) =
            RegKey::predef(HKEY_CURRENT_USER).open_subkey_with_flags(RUN_KEY, KEY_SET_VALUE)
        {
            match run.delete_value(&value_name) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(format!("删除 Windows 自启动注册项失败：{error}")),
            }
        }
        if let Ok(approved) = RegKey::predef(HKEY_CURRENT_USER)
            .open_subkey_with_flags(STARTUP_APPROVED_KEY, KEY_SET_VALUE)
        {
            match approved.delete_value(&value_name) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(format!("删除 Windows 自启动批准状态失败：{error}")),
            }
        }
    }
    read(app)
}

/// Repairs only an existing value that clearly belongs to this executable.
/// This is called once during startup so users who enabled autostart before
/// the quoting fix do not need to toggle the setting manually.
pub(crate) fn repair_current_registration(app: &tauri::AppHandle) -> Result<(), String> {
    let value_name = app.package_info().name.to_string();
    let run = match RegKey::predef(HKEY_CURRENT_USER)
        .open_subkey_with_flags(RUN_KEY, KEY_READ | KEY_SET_VALUE)
    {
        Ok(run) => run,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("读取 Windows 自启动注册项失败：{error}")),
    };
    let Ok(existing) = run.get_value::<String, _>(&value_name) else {
        return Ok(());
    };
    let executable = current_executable()?;
    if command_targets_executable(&existing, &executable) {
        let desired = format!("{} --autostart", quote_windows_argument(&executable));
        if existing != desired {
            run.set_value(&value_name, &desired)
                .map_err(|error| format!("修复 Windows 自启动路径引号失败：{error}"))?;
        }
    }
    Ok(())
}

fn read_run_command(value_name: &str) -> Result<Option<String>, String> {
    match RegKey::predef(HKEY_CURRENT_USER).open_subkey_with_flags(RUN_KEY, KEY_READ) {
        Ok(run) => match run.get_value::<String, _>(value_name) {
            Ok(command) => Ok(Some(command)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(format!("读取 Windows 自启动注册项失败：{error}")),
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("读取 Windows 自启动注册项失败：{error}")),
    }
}

fn external_registration_status() -> AutostartStatus {
    AutostartStatus {
        available: true,
        enabled: false,
        status: "external".into(),
        message: "发现同名自启动项，但它指向其他程序；未修改该项。".into(),
    }
}

fn startup_approved_enabled(value_name: &str) -> Result<bool, String> {
    let approved = match RegKey::predef(HKEY_CURRENT_USER)
        .open_subkey_with_flags(STARTUP_APPROVED_KEY, KEY_READ)
    {
        Ok(key) => key,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(true),
        Err(error) => return Err(format!("读取 Windows 自启动批准状态失败：{error}")),
    };
    let raw = match approved.get_raw_value(value_name) {
        Ok(raw) => raw.bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(true),
        Err(error) => return Err(format!("读取 Windows 自启动批准状态失败：{error}")),
    };
    if raw.is_empty() {
        return Ok(false);
    }
    // StartupApproved\Run uses 0x02 for an enabled entry.  Other values,
    // including the disabled 0x03 state, must not be reported as enabled.
    Ok(raw[0] == 0x02)
}

fn current_autostart_command() -> Result<String, String> {
    let executable = current_executable()?;
    Ok(format!(
        "{} --autostart",
        quote_windows_argument(&executable)
    ))
}

fn current_executable() -> Result<std::path::PathBuf, String> {
    std::env::current_exe()
        .and_then(|path| path.canonicalize())
        .map_err(|error| format!("解析当前 Windows 可执行文件失败：{error}"))
}

fn quote_windows_argument(path: &Path) -> String {
    let value = path.to_string_lossy();
    format!("\"{}\"", value.replace('"', "\\\""))
}

fn command_targets_executable(command: &str, executable: &Path) -> bool {
    let command = command.trim_start();
    let expected = executable.to_string_lossy();
    if let Some(rest) = command.strip_prefix('"') {
        let Some(end) = rest.find('"') else {
            return false;
        };
        return paths_equal(&rest[..end], &expected);
    }
    command
        .get(..expected.len())
        .is_some_and(|prefix| paths_equal(prefix, &expected))
        && command.get(expected.len()..).is_none_or(|rest| {
            rest.is_empty() || rest.chars().next().is_some_and(char::is_whitespace)
        })
}

fn paths_equal(left: &str, right: &str) -> bool {
    left.trim_end_matches(['\\', '/'])
        .eq_ignore_ascii_case(right.trim_end_matches(['\\', '/']))
}

#[cfg(test)]
mod tests {
    use super::{command_targets_executable, quote_windows_argument};
    use std::path::Path;

    #[test]
    fn quote_windows_argument_preserves_spaces() {
        assert_eq!(
            quote_windows_argument(Path::new(r"C:\Program Files\Codex Token Bar\Codex.exe")),
            r#""C:\Program Files\Codex Token Bar\Codex.exe""#
        );
    }

    #[test]
    fn command_target_matching_accepts_old_unquoted_and_new_quoted_forms() {
        let executable = Path::new(r"C:\Program Files\Codex Token Bar\Codex.exe");
        assert!(command_targets_executable(
            r#"C:\Program Files\Codex Token Bar\Codex.exe --autostart"#,
            executable
        ));
        assert!(command_targets_executable(
            r#""C:\Program Files\Codex Token Bar\Codex.exe" --autostart"#,
            executable
        ));
        assert!(!command_targets_executable(
            r#"C:\Other\Codex.exe --autostart"#,
            executable
        ));
    }
}
