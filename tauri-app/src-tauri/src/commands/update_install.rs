// A launched installer is not a completed installation; retain a support receipt.
use crate::core::atomic_file;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
static RECEIPT_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[derive(Debug, Deserialize, Serialize)]
struct InstallAttempt {
    source_version: String,
    target_version: String,
    directory: PathBuf,
    started_at: u64,
    status: String,
    detail: Option<String>,
}

fn save(path: &Path, attempt: &InstallAttempt) -> Result<(), String> {
    let bytes = serde_json::to_vec_pretty(attempt).map_err(|e| e.to_string())?;
    atomic_file::write_atomically(path, &bytes).map_err(|e| format!("无法保存更新安装记录：{e}"))
}

fn load(path: &Path) -> Result<Option<InstallAttempt>, String> {
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).map(Some)
            .map_err(|e| format!("更新安装记录损坏：{e}")),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("无法读取更新安装记录：{e}")),
    }
}

pub(super) fn begin_attempt(path: &Path, source: &str, target: &str, directory: &Path) -> Result<(), String> {
    let _receipt = RECEIPT_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    save(path, &InstallAttempt {
        source_version: source.into(), target_version: target.into(),
        directory: directory.into(),
        started_at: std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default().as_secs(),
        status: "pending".into(), detail: None,
    })
}

pub(super) fn fail_attempt(path: &Path, error: &str) -> Result<(), String> {
    let _receipt = RECEIPT_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(mut attempt) = load(path)? {
        attempt.status = "launchFailed".into();
        attempt.detail = Some(error.chars().take(512).collect());
        save(path, &attempt)?;
    }
    Ok(())
}

fn has_completed(attempt: &InstallAttempt, current: &str, directory: &Path) -> bool {
    let versions = (semver::Version::parse(current), semver::Version::parse(&attempt.target_version));
    directory == attempt.directory && matches!(versions, (Ok(current), Ok(target)) if !current.cmp_precedence(&target).is_lt())
}

pub(super) fn reconcile_attempt(path: &Path, version: &str) -> Result<Option<String>, String> {
    let _receipt = RECEIPT_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let Some(mut attempt) = load(path)? else { return Ok(None); };
    if attempt.status == "confirmed" { return Ok(None); }
    let executable = std::env::current_exe().map_err(|e| e.to_string())?;
    let directory = std::fs::canonicalize(executable.parent().ok_or("无法定位正在运行的程序目录")?)
        .map_err(|e| e.to_string())?;
    if has_completed(&attempt, version, &directory) {
        attempt.status = "confirmed".into();
        attempt.detail = None;
        save(path, &attempt)?;
        return Ok(Some(format!("已完成 {} 更新", attempt.target_version)));
    }
    // A concurrently running installer may still complete; never call this failed.
    Ok(Some(if directory != attempt.directory {
        "上次更新尚未确认：当前启动的是其他安装目录，请从已更新的入口启动".into()
    } else if attempt.status == "launchFailed" {
        "上次安装器启动失败，请重试更新或下载安装包".into()
    } else {
        format!("尚未确认 {} 更新完成；若安装器已退出，请重试或下载安装包", attempt.target_version)
    }))
}

#[cfg(windows)]
pub(super) fn registered_install_directory() -> Result<PathBuf, String> {
    use winreg::{enums::{HKEY_CURRENT_USER, KEY_READ, KEY_WOW64_64KEY}, RegKey};
    let key = RegKey::predef(HKEY_CURRENT_USER)
        .open_subkey_with_flags(r"Software\codex\Codex Token Bar", KEY_READ | KEY_WOW64_64KEY)
        .map_err(|_| "找不到此程序的安装目录登记，请使用正式安装包重新安装".to_string())?;
    let directory: String = key.get_value("")
        .map_err(|_| "安装目录登记不完整，请使用正式安装包重新安装".to_string())?;
    let executable = std::env::current_exe().map_err(|e| e.to_string())?;
    validate_install_directory(&executable, Path::new(&directory))
}

#[cfg(any(windows, test))]
fn validate_install_directory(executable: &Path, directory: &Path) -> Result<PathBuf, String> {
    let registered = std::fs::canonicalize(directory)
        .map_err(|_| "登记的安装目录不可用，请使用正式安装包重新安装".to_string())?;
    let current = std::fs::canonicalize(executable.parent().ok_or("无法定位程序目录")?)
        .map_err(|e| e.to_string())?;
    if !executable.file_name().is_some_and(|name| name.to_string_lossy().eq_ignore_ascii_case("codex-token-bar.exe")) || registered != current {
        return Err("当前程序与登记的安装目录不一致，请从正式安装入口启动后更新".into());
    }
    Ok(current)
}

#[cfg(windows)]
pub(super) fn destination_argument(directory: &Path) -> std::ffi::OsString {
    // NSIS /D= must be last and unquoted, even with spaces in its value.
    let mut argument = std::ffi::OsString::from("/D=");
    let text = directory.as_os_str().to_string_lossy();
    if let Some(unc) = text.strip_prefix(r"\\?\UNC\") {
        argument.push(format!(r"\\{unc}"));
    } else {
        argument.push(text.strip_prefix(r"\\?\").unwrap_or(&text));
    }
    argument
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn confirmation_requires_target_version_and_same_directory() {
        let attempt = InstallAttempt { source_version: "0.9.2".into(), target_version: "0.9.3".into(),
            directory: PathBuf::from("registered"), started_at: 0, status: "pending".into(), detail: None };
        assert!(!has_completed(&attempt, "0.9.2", Path::new("registered")));
        assert!(!has_completed(&attempt, "0.9.3", Path::new("other")));
        assert!(has_completed(&attempt, "0.9.3", Path::new("registered")));
        assert!(has_completed(&attempt, "0.9.4", Path::new("registered")));
        assert!(!has_completed(&attempt, "unknown", Path::new("registered")));
    }
    #[test]
    fn automatic_install_requires_registered_directory_and_product_executable() {
        let root = std::env::temp_dir().join(format!("tokenbar-path-guard-{}", uuid_for_test()));
        let current = root.join("用户 current dir");
        let other = root.join("other dir");
        std::fs::create_dir_all(&current).unwrap();
        std::fs::create_dir_all(&other).unwrap();
        let executable = current.join("codex-token-bar.exe");
        assert!(validate_install_directory(&executable, &current).is_ok());
        assert!(validate_install_directory(&executable, &other).is_err());
        assert!(validate_install_directory(&current.join("renamed.exe"), &current).is_err());
        assert!(validate_install_directory(&executable, &root.join("missing")).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
    fn uuid_for_test() -> u128 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    }
    #[cfg(windows)]
    #[test]
    fn nsis_destination_is_unquoted_and_preserves_spaces_and_unicode() {
        assert_eq!(destination_argument(Path::new(r"\\?\C:\Users\用户\Token Bar")), "/D=C:\\Users\\用户\\Token Bar");
        assert_eq!(destination_argument(Path::new(r"\\?\UNC\host\share\Token Bar")), "/D=\\\\host\\share\\Token Bar");
    }
}
