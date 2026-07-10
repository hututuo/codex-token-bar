use crate::core::{app_paths, app_paths::home_dir};
use crate::models::{
    AppSettingsSnapshot, DisplaySurfaceSettingsSnapshot, FloatingContentVisibilitySnapshot,
    FloatingWindowPositionSnapshot, FloatingWindowSettingsSnapshot,
};
use std::{
    fs::{File, OpenOptions},
    io::{ErrorKind, Read, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex, OnceLock,
    },
    time::{SystemTime, UNIX_EPOCH},
};

const RECOVERY_CANDIDATE_LIMIT: usize = 8;
const TEMP_CREATE_ATTEMPT_LIMIT: usize = 16;
static SETTINGS_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static TEMP_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Debug)]
struct SettingsReadOutcome {
    settings: AppSettingsSnapshot,
    diagnostic: Option<String>,
}

#[derive(Debug)]
struct SettingsMutationOutcome {
    settings: AppSettingsSnapshot,
    diagnostic: Option<String>,
}

#[derive(Debug)]
struct RecoveryCandidate {
    path: PathBuf,
    freshness: u128,
    invalid_reason: Option<String>,
}

pub fn read_app_settings() -> Result<AppSettingsSnapshot, String> {
    let path = settings_path()?;
    let _guard = settings_lock()
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    read_app_settings_at(&path)
}

pub fn save_floating_settings(
    floating_window: FloatingWindowSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    mutate_app_settings(|settings| {
        settings.floating_window = sanitize_floating_settings(floating_window);
    })
}

pub fn save_floating_position(
    floating_position: FloatingWindowPositionSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    mutate_app_settings(|settings| {
        settings.floating_position = sanitize_floating_position(Some(floating_position));
    })
}

pub fn save_display_surfaces(
    display_surfaces: DisplaySurfaceSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    mutate_app_settings(|settings| {
        settings.display_surfaces = display_surfaces;
    })
}

pub fn save_quota_refresh_interval_ms(interval_ms: u64) -> Result<AppSettingsSnapshot, String> {
    mutate_app_settings(|settings| {
        settings.quota_refresh_interval_ms = sanitize_quota_refresh_interval_ms(interval_ms);
    })
}

pub fn save_custom_account_display_name(
    custom_account_display_name: String,
) -> Result<AppSettingsSnapshot, String> {
    mutate_app_settings(|settings| {
        settings.custom_account_display_name = custom_account_display_name;
    })
}

pub fn save_setup_guide_completed(completed: bool) -> Result<AppSettingsSnapshot, String> {
    mutate_app_settings(|settings| {
        settings.setup_guide_completed = completed;
    })
}

pub(super) fn normalize_user_path(path: &str) -> PathBuf {
    let trimmed = path.trim();
    if trimmed == "~" {
        return home_dir();
    }
    if let Some(rest) = trimmed.strip_prefix("~/") {
        return home_dir().join(rest);
    }
    PathBuf::from(trimmed)
}

pub(super) fn mutate_app_settings(
    mutation: impl FnOnce(&mut AppSettingsSnapshot),
) -> Result<AppSettingsSnapshot, String> {
    mutate_app_settings_at(&settings_path()?, mutation)
}

fn mutate_app_settings_at(
    path: &Path,
    mutation: impl FnOnce(&mut AppSettingsSnapshot),
) -> Result<AppSettingsSnapshot, String> {
    let outcome =
        mutate_app_settings_at_with_hooks(path, || {}, |_, _| {}, sync_parent_directory, mutation)?;
    if let Some(diagnostic) = outcome.diagnostic {
        eprintln!("{diagnostic}");
    }
    Ok(outcome.settings)
}

fn mutate_app_settings_at_with_hooks<AfterRead, BeforeReplace, SyncParent, Mutation>(
    path: &Path,
    after_read: AfterRead,
    before_replace: BeforeReplace,
    sync_parent: SyncParent,
    mutation: Mutation,
) -> Result<SettingsMutationOutcome, String>
where
    AfterRead: FnOnce(),
    BeforeReplace: FnOnce(&Path, &Path),
    SyncParent: FnOnce(&Path) -> Result<(), String>,
    Mutation: FnOnce(&mut AppSettingsSnapshot),
{
    let _guard = settings_lock()
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let mut settings = read_app_settings_at(path)?;
    after_read();
    mutation(&mut settings);
    let saved = sanitize_app_settings(settings);
    let diagnostic = write_app_settings_at_with_hooks(path, &saved, before_replace, sync_parent)?;
    Ok(SettingsMutationOutcome {
        settings: saved,
        diagnostic,
    })
}

fn settings_lock() -> &'static Mutex<()> {
    SETTINGS_LOCK.get_or_init(|| Mutex::new(()))
}

fn write_app_settings_at(
    path: &Path,
    settings: &AppSettingsSnapshot,
) -> Result<Option<String>, String> {
    write_app_settings_at_with_hooks(path, settings, |_, _| {}, sync_parent_directory)
}

fn write_app_settings_at_with_hooks<BeforeReplace, SyncParent>(
    path: &Path,
    settings: &AppSettingsSnapshot,
    before_replace: BeforeReplace,
    sync_parent: SyncParent,
) -> Result<Option<String>, String>
where
    BeforeReplace: FnOnce(&Path, &Path),
    SyncParent: FnOnce(&Path) -> Result<(), String>,
{
    let parent = path
        .parent()
        .ok_or_else(|| format!("设置文件缺少父目录：{}", path.display()))?;
    std::fs::create_dir_all(parent)
        .map_err(|error| format!("创建设置目录失败：{}（{}）", parent.display(), error))?;

    let bytes = serde_json::to_vec_pretty(settings).map_err(|error| error.to_string())?;
    let (temp_path, mut temp_file) = create_unique_temp_file(path)?;
    if let Err(error) = temp_file
        .write_all(&bytes)
        .and_then(|_| temp_file.flush())
        .and_then(|_| temp_file.sync_all())
    {
        drop(temp_file);
        let _ = std::fs::remove_file(&temp_path);
        return Err(format!(
            "写入设置临时文件失败：{}（{}）",
            temp_path.display(),
            error
        ));
    }
    drop(temp_file);

    before_replace(&temp_path, path);
    replace_settings_file(&temp_path, path).map_err(|error| {
        format!(
            "原子替换设置文件失败：{} -> {}（{}）；已保留临时文件用于恢复",
            temp_path.display(),
            path.display(),
            error
        )
    })?;
    Ok(sync_parent(parent).err().map(|error| {
        format!(
            "设置文件已提交但持久性未确认：{}（目录同步失败：{}）",
            path.display(),
            error
        )
    }))
}

fn create_unique_temp_file(path: &Path) -> Result<(PathBuf, File), String> {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("设置文件名不是有效 UTF-8：{}", path.display()))?;
    let parent = path
        .parent()
        .ok_or_else(|| format!("设置文件缺少父目录：{}", path.display()))?;

    for _ in 0..TEMP_CREATE_ATTEMPT_LIMIT {
        let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let freshness = system_time_key(SystemTime::now());
        let temp_path = parent.join(format!(
            "{file_name}.tmp-v2-{freshness:039}-{}-{sequence:020}",
            std::process::id(),
        ));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp_path)
        {
            Ok(file) => return Ok((temp_path, file)),
            Err(error) if error.kind() == ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(format!(
                    "创建设置临时文件失败：{}（{}）",
                    temp_path.display(),
                    error
                ));
            }
        }
    }

    Err(format!(
        "创建唯一设置临时文件失败：连续 {TEMP_CREATE_ATTEMPT_LIMIT} 次命名冲突"
    ))
}

pub(super) fn read_app_settings_or_default() -> AppSettingsSnapshot {
    read_app_settings().unwrap_or_default()
}

fn read_app_settings_at(path: &Path) -> Result<AppSettingsSnapshot, String> {
    let outcome = read_app_settings_at_with_diagnostics(path)?;
    if let Some(diagnostic) = outcome.diagnostic {
        eprintln!("{diagnostic}");
    }
    Ok(outcome.settings)
}

fn read_app_settings_at_with_diagnostics(path: &Path) -> Result<SettingsReadOutcome, String> {
    match std::fs::read(path) {
        Ok(bytes) => match parse_settings(path, &bytes) {
            Ok(settings) => Ok(SettingsReadOutcome {
                settings,
                diagnostic: None,
            }),
            Err(primary_error) => recover_interrupted_settings(path, primary_error),
        },
        Err(error) if error.kind() == ErrorKind::NotFound => {
            let candidates = interrupted_temp_candidates(path)?;
            if candidates.is_empty() {
                Ok(SettingsReadOutcome {
                    settings: AppSettingsSnapshot::default(),
                    diagnostic: None,
                })
            } else {
                recover_from_candidates(
                    path,
                    format!("设置文件不存在：{}", path.display()),
                    candidates,
                )
            }
        }
        Err(error) => Err(format!("读取设置文件失败：{}（{}）", path.display(), error)),
    }
}

fn parse_settings(path: &Path, bytes: &[u8]) -> Result<AppSettingsSnapshot, String> {
    serde_json::from_slice::<AppSettingsSnapshot>(bytes)
        .map(sanitize_app_settings)
        .map_err(|error| format!("设置文件不是有效 JSON：{}（{}）", path.display(), error))
}

fn recover_interrupted_settings(
    path: &Path,
    primary_error: String,
) -> Result<SettingsReadOutcome, String> {
    let candidates = interrupted_temp_candidates(path)?;
    recover_from_candidates(path, primary_error, candidates)
}

fn recover_from_candidates(
    path: &Path,
    primary_error: String,
    candidates: Vec<RecoveryCandidate>,
) -> Result<SettingsReadOutcome, String> {
    recover_from_candidates_with_hook(path, primary_error, candidates, |_| {})
}

fn recover_from_candidates_with_hook<BeforeCandidateOpen>(
    path: &Path,
    primary_error: String,
    candidates: Vec<RecoveryCandidate>,
    mut before_candidate_open: BeforeCandidateOpen,
) -> Result<SettingsReadOutcome, String>
where
    BeforeCandidateOpen: FnMut(&Path),
{
    let total = candidates.len();
    let checked = total.min(RECOVERY_CANDIDATE_LIMIT);
    let mut candidate_diagnostics = Vec::new();

    for candidate in candidates.into_iter().take(RECOVERY_CANDIDATE_LIMIT) {
        before_candidate_open(&candidate.path);
        let candidate_result = candidate
            .invalid_reason
            .clone()
            .map_or_else(|| read_recovery_candidate(&candidate.path), Err);
        match candidate_result {
            Ok(settings) => {
                let write_diagnostic = write_app_settings_at(path, &settings).map_err(|error| {
                    format!(
                        "{primary_error}；恢复候选有效但安装失败：{}（{}）",
                        candidate.path.display(),
                        error
                    )
                })?;
                let cleanup = discard_recovery_candidate(&candidate.path);
                return Ok(SettingsReadOutcome {
                    settings,
                    diagnostic: Some(format!(
                        "设置文件已从中断写入恢复：{} -> {}；原始诊断：{}{}{}",
                        candidate.path.display(),
                        path.display(),
                        primary_error,
                        cleanup_diagnostic(cleanup),
                        optional_diagnostic(write_diagnostic),
                    )),
                });
            }
            Err(error) => candidate_diagnostics.push(format!(
                "{}（{}{}）",
                candidate.path.display(),
                error,
                cleanup_diagnostic(discard_recovery_candidate(&candidate.path)),
            )),
        }
    }

    let bounded = if total > RECOVERY_CANDIDATE_LIMIT {
        format!("；共有 {total} 个恢复候选，仅检查前 {RECOVERY_CANDIDATE_LIMIT} 个")
    } else {
        String::new()
    };
    let details = if candidate_diagnostics.is_empty() {
        "无可用中断写入候选".into()
    } else {
        format!(
            "已检查 {checked} 个候选：{}",
            candidate_diagnostics.join("；")
        )
    };
    Err(format!("{primary_error}；恢复失败：{details}{bounded}"))
}

fn interrupted_temp_candidates(path: &Path) -> Result<Vec<RecoveryCandidate>, String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("设置文件缺少父目录：{}", path.display()))?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("设置文件名不是有效 UTF-8：{}", path.display()))?;
    let prefix = format!("{file_name}.tmp-");
    let mut candidates = Vec::new();
    let entries = match std::fs::read_dir(parent) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(candidates),
        Err(error) => {
            return Err(format!(
                "扫描设置恢复候选失败：{}（{}）",
                parent.display(),
                error
            ));
        }
    };
    for entry in entries.flatten() {
        let candidate = entry.path();
        let Some(candidate_name) = candidate.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if !candidate_name.starts_with(&prefix) {
            continue;
        }
        let metadata = match std::fs::symlink_metadata(&candidate) {
            Ok(metadata) => metadata,
            Err(error) => {
                candidates.push(RecoveryCandidate {
                    path: candidate,
                    freshness: 0,
                    invalid_reason: Some(format!("读取非跟随元数据失败：{error}")),
                });
                continue;
            }
        };
        let file_type = metadata.file_type();
        let invalid_reason = if file_type.is_symlink() {
            Some("恢复候选是符号链接".into())
        } else if !file_type.is_file() {
            Some("恢复候选是非普通文件".into())
        } else if metadata_is_reparse_point(&metadata) {
            Some("恢复候选是 Windows reparse point".into())
        } else {
            None
        };
        let freshness = embedded_candidate_freshness(candidate_name, &prefix)
            .or_else(|| metadata.modified().ok().map(system_time_key))
            .unwrap_or_default();
        candidates.push(RecoveryCandidate {
            path: candidate,
            freshness,
            invalid_reason,
        });
    }
    candidates.sort_by(|left, right| {
        right
            .freshness
            .cmp(&left.freshness)
            .then_with(|| right.path.file_name().cmp(&left.path.file_name()))
    });
    Ok(candidates)
}

fn embedded_candidate_freshness(file_name: &str, prefix: &str) -> Option<u128> {
    file_name
        .strip_prefix(prefix)?
        .strip_prefix("v2-")?
        .split('-')
        .next()?
        .parse()
        .ok()
}

fn system_time_key(value: SystemTime) -> u128 {
    value
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

fn read_recovery_candidate(candidate: &Path) -> Result<AppSettingsSnapshot, String> {
    let mut options = OpenOptions::new();
    options.read(true);
    configure_recovery_open_no_follow(&mut options);
    let mut file = options
        .open(candidate)
        .map_err(|error| format!("安全打开恢复候选失败：{error}"))?;
    let metadata = file
        .metadata()
        .map_err(|error| format!("读取已打开候选元数据失败：{error}"))?;
    if !metadata.file_type().is_file() {
        return Err("已打开恢复候选是非普通文件".into());
    }
    if metadata_is_reparse_point(&metadata) {
        return Err("已打开恢复候选是 Windows reparse point".into());
    }

    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)
        .map_err(|error| format!("读取恢复候选失败：{error}"))?;
    parse_settings(candidate, &bytes)
}

#[cfg(unix)]
fn configure_recovery_open_no_follow(options: &mut OpenOptions) {
    use std::os::unix::fs::OpenOptionsExt;

    #[cfg(any(target_os = "linux", target_os = "android"))]
    const O_NOFOLLOW: i32 = 0x0002_0000;
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    const O_NOFOLLOW: i32 = 0x0000_0100;
    options.custom_flags(O_NOFOLLOW);
}

#[cfg(windows)]
fn configure_recovery_open_no_follow(options: &mut OpenOptions) {
    use std::os::windows::fs::OpenOptionsExt;

    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
}

#[cfg(not(any(unix, windows)))]
fn configure_recovery_open_no_follow(_options: &mut OpenOptions) {}

#[cfg(windows)]
fn metadata_is_reparse_point(metadata: &std::fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;

    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn metadata_is_reparse_point(_metadata: &std::fs::Metadata) -> bool {
    false
}

fn discard_recovery_candidate(candidate: &Path) -> Result<(), String> {
    match std::fs::symlink_metadata(candidate) {
        Ok(metadata) if metadata.file_type().is_dir() && !metadata.file_type().is_symlink() => {
            std::fs::remove_dir(candidate).map_err(|error| format!("移除无效候选目录失败：{error}"))
        }
        Ok(_) => {
            std::fs::remove_file(candidate).map_err(|error| format!("移除无效候选失败：{error}"))
        }
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("检查无效候选失败：{error}")),
    }
}

fn cleanup_diagnostic(result: Result<(), String>) -> String {
    match result {
        Ok(()) => "；候选已清理".into(),
        Err(error) => format!("；候选清理失败：{error}"),
    }
}

fn optional_diagnostic(diagnostic: Option<String>) -> String {
    diagnostic.map_or_else(String::new, |diagnostic| format!("；{diagnostic}"))
}

#[cfg(not(windows))]
fn replace_settings_file(temp_path: &Path, destination: &Path) -> std::io::Result<()> {
    std::fs::rename(temp_path, destination)
}

#[cfg(windows)]
fn replace_settings_file(temp_path: &Path, destination: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;

    const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
    const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
    #[link(name = "kernel32")]
    extern "system" {
        fn MoveFileExW(
            existing_file_name: *const u16,
            new_file_name: *const u16,
            flags: u32,
        ) -> i32;
    }

    let existing: Vec<u16> = temp_path.as_os_str().encode_wide().chain(Some(0)).collect();
    let destination: Vec<u16> = destination
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    // SAFETY: Both buffers are owned, NUL-terminated UTF-16 paths and remain alive for the call.
    let replaced = unsafe {
        MoveFileExW(
            existing.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if replaced == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(unix)]
fn sync_parent_directory(parent: &Path) -> Result<(), String> {
    File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| format!("同步设置目录失败：{}（{}）", parent.display(), error))
}

#[cfg(not(unix))]
fn sync_parent_directory(_parent: &Path) -> Result<(), String> {
    Ok(())
}

fn sanitize_app_settings(mut settings: AppSettingsSnapshot) -> AppSettingsSnapshot {
    settings.codex_home = settings.codex_home.and_then(|path| {
        let trimmed = path.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.into())
        }
    });
    settings.custom_account_display_name = settings.custom_account_display_name.trim().into();
    settings.quota_refresh_interval_ms =
        sanitize_quota_refresh_interval_ms(settings.quota_refresh_interval_ms);
    settings.floating_window = sanitize_floating_settings(settings.floating_window);
    settings.floating_position = sanitize_floating_position(settings.floating_position);
    settings
}

fn sanitize_quota_refresh_interval_ms(value: u64) -> u64 {
    match value {
        30_000 | 60_000 | 180_000 | 300_000 | 600_000 => value,
        _ => 60_000,
    }
}

fn sanitize_floating_settings(
    settings: FloatingWindowSettingsSnapshot,
) -> FloatingWindowSettingsSnapshot {
    FloatingWindowSettingsSnapshot {
        opacity: clamp_f64(settings.opacity, 0.4, 1.0, 0.92),
        scale: clamp_f64(settings.scale, 0.9, 1.38, 1.0),
        token_rate_full_scale: clamp_f64(settings.token_rate_full_scale, 50.0, 400.0, 200.0),
        unread_effect: sanitize_unread_effect(&settings.unread_effect).into(),
        gradient_start: sanitize_hex_color(&settings.gradient_start, "#ffffff").into(),
        gradient_end: sanitize_hex_color(&settings.gradient_end, "#daefff").into(),
        gradient_direction: sanitize_gradient_direction(&settings.gradient_direction).into(),
        gradient_type: sanitize_gradient_type(&settings.gradient_type).into(),
        text_tone: clamp_f64(settings.text_tone, -1.0, 1.0, -1.0),
        content_visibility: sanitize_floating_content_visibility(settings.content_visibility),
    }
}

fn sanitize_floating_content_visibility(
    visibility: FloatingContentVisibilitySnapshot,
) -> FloatingContentVisibilitySnapshot {
    FloatingContentVisibilitySnapshot {
        show_rate_and_bar: visibility.show_rate_and_bar,
        show_usage_status: visibility.show_usage_status,
        show_metrics: visibility.show_metrics,
        show_quota: visibility.show_quota,
        show_radar: visibility.show_radar,
        order: sanitize_floating_content_order(visibility.order),
    }
}

fn sanitize_floating_content_order(order: Vec<String>) -> Vec<String> {
    let defaults = ["rateAndBar", "usageStatus", "metrics", "radar", "quota"];
    let mut next: Vec<String> = Vec::new();
    for item in order {
        if defaults.contains(&item.as_str()) && !next.iter().any(|existing| existing == &item) {
            next.push(item);
        }
    }
    for item in defaults {
        if !next.iter().any(|existing| existing == item) {
            next.push(item.into());
        }
    }
    next
}

fn sanitize_unread_effect(value: &str) -> &'static str {
    match value {
        "off" => "off",
        "ripple" => "ripple",
        "shimmer" => "shimmer",
        _ => "ripple",
    }
}

fn clamp_f64(value: f64, minimum: f64, maximum: f64, fallback: f64) -> f64 {
    if !value.is_finite() {
        return fallback;
    }

    value.clamp(minimum, maximum)
}

fn sanitize_hex_color(value: &str, fallback: &'static str) -> String {
    let trimmed = value.trim();
    let valid = trimmed.len() == 7
        && trimmed.starts_with('#')
        && trimmed
            .chars()
            .skip(1)
            .all(|character| character.is_ascii_hexdigit());
    if valid {
        trimmed.to_ascii_lowercase()
    } else {
        fallback.into()
    }
}

fn sanitize_gradient_direction(value: &str) -> String {
    match value {
        "135deg" | "90deg" | "180deg" | "45deg" => value.into(),
        _ => "135deg".into(),
    }
}

fn sanitize_gradient_type(value: &str) -> String {
    match value {
        "linear" | "radial" | "conic" => value.into(),
        _ => "linear".into(),
    }
}

fn sanitize_floating_position(
    position: Option<FloatingWindowPositionSnapshot>,
) -> Option<FloatingWindowPositionSnapshot> {
    let position = position?;
    if !is_valid_coordinate(position.x) || !is_valid_coordinate(position.y) {
        return None;
    }

    Some(FloatingWindowPositionSnapshot {
        x: position.x,
        y: position.y,
        saved_at: position.saved_at.filter(|value| *value > 0),
    })
}

fn is_valid_coordinate(value: f64) -> bool {
    value.is_finite() && value.abs() <= 20_000.0
}

fn settings_path() -> Result<PathBuf, String> {
    app_paths::settings_path()
        .ok_or_else(|| "无法定位系统应用支持目录，不能读取或保存本地设置".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs::FileTimes,
        sync::mpsc,
        thread,
        time::{Duration, SystemTime, UNIX_EPOCH},
    };

    #[test]
    fn settings_keep_legacy_codex_home_and_sanitize_floating_values() {
        let raw = r##"{
            "codex_home": "~/custom-codex",
            "customAccountDisplayName": "  来先生  ",
            "quotaRefreshIntervalMs": 31000,
            "floatingWindow": {
                "opacity": 1.4,
                "scale": 0.2,
                "unreadEffect": "sparkle",
                "gradientStart": "blue",
                "gradientEnd": "#12",
                "gradientDirection": "270deg",
                "gradientType": "mesh",
                "textTone": 4,
                "contentVisibility": {
                    "showRadar": false,
                    "order": ["quota", "quota", "unknown", "rateAndBar"]
                }
            }
        }"##;

        let settings: AppSettingsSnapshot = serde_json::from_str(raw).unwrap();
        let sanitized = sanitize_app_settings(settings);

        assert_eq!(sanitized.codex_home.as_deref(), Some("~/custom-codex"));
        assert_eq!(sanitized.custom_account_display_name, "来先生");
        assert_eq!(sanitized.quota_refresh_interval_ms, 60_000);
        assert_eq!(sanitized.floating_window.opacity, 1.0);
        assert_eq!(sanitized.floating_window.scale, 0.9);
        assert_eq!(sanitized.floating_window.token_rate_full_scale, 200.0);
        assert_eq!(sanitized.floating_window.unread_effect, "ripple");
        assert_eq!(sanitized.floating_window.gradient_start, "#ffffff");
        assert_eq!(sanitized.floating_window.gradient_end, "#daefff");
        assert_eq!(sanitized.floating_window.gradient_direction, "135deg");
        assert_eq!(sanitized.floating_window.gradient_type, "linear");
        assert_eq!(sanitized.floating_window.text_tone, 1.0);
        assert!(!sanitized.floating_window.content_visibility.show_radar);
        assert_eq!(
            sanitized.floating_window.content_visibility.order,
            ["quota", "rateAndBar", "usageStatus", "metrics", "radar"]
        );
        assert!(sanitized.display_surfaces.floating_window_enabled);
        assert!(sanitized.display_surfaces.live_rate_enabled);
        assert!(sanitized.display_surfaces.status_tray_live_text_enabled);
        assert!(!sanitized.setup_guide_completed);
    }

    #[test]
    fn settings_clear_blank_custom_account_display_name() {
        let settings = AppSettingsSnapshot {
            custom_account_display_name: "   ".into(),
            ..AppSettingsSnapshot::default()
        };

        assert!(sanitize_app_settings(settings)
            .custom_account_display_name
            .is_empty());
    }

    #[test]
    fn settings_drop_unreasonable_floating_position() {
        let settings = AppSettingsSnapshot {
            floating_position: Some(FloatingWindowPositionSnapshot {
                x: 20_001.0,
                y: 24.0,
                saved_at: Some(1),
            }),
            ..AppSettingsSnapshot::default()
        };

        assert!(sanitize_app_settings(settings).floating_position.is_none());
    }

    #[test]
    fn settings_accept_partial_nested_objects() {
        let raw = r##"{
            "quotaRefreshIntervalMs": 180000,
            "floatingWindow": {
                "opacity": 0.7,
                "unreadEffect": "shimmer",
                "gradientStart": "#ABCDEF",
                "gradientEnd": "#123456",
                "gradientDirection": "90deg",
                "gradientType": "conic",
                "textTone": -0.5,
                "contentVisibility": {
                    "showUsageStatus": false,
                    "order": ["metrics", "rateAndBar", "usageStatus", "radar", "quota"]
                }
            },
            "setupGuideCompleted": true,
            "displaySurfaces": {
                "floatingWindowEnabled": false
            }
        }"##;

        let settings: AppSettingsSnapshot = serde_json::from_str(raw).unwrap();

        assert_eq!(settings.quota_refresh_interval_ms, 180_000);
        assert_eq!(settings.floating_window.opacity, 0.7);
        assert_eq!(settings.floating_window.scale, 1.0);
        assert_eq!(settings.floating_window.unread_effect, "shimmer");
        assert_eq!(settings.floating_window.gradient_start, "#ABCDEF");
        assert_eq!(settings.floating_window.gradient_end, "#123456");
        assert_eq!(settings.floating_window.gradient_direction, "90deg");
        assert_eq!(settings.floating_window.gradient_type, "conic");
        assert_eq!(settings.floating_window.text_tone, -0.5);
        assert!(
            !settings
                .floating_window
                .content_visibility
                .show_usage_status
        );
        assert_eq!(
            settings.floating_window.content_visibility.order,
            ["metrics", "rateAndBar", "usageStatus", "radar", "quota"]
        );
        assert!(settings.setup_guide_completed);
        assert!(!settings.display_surfaces.floating_window_enabled);
        assert!(settings.display_surfaces.live_rate_enabled);
        assert!(settings.display_surfaces.status_tray_live_text_enabled);
    }

    #[test]
    fn missing_settings_file_uses_first_launch_defaults() {
        let path = unique_test_settings_path("missing");
        let settings = read_app_settings_at(&path).unwrap();

        assert!(settings.codex_home.is_none());
        assert_eq!(settings.quota_refresh_interval_ms, 60_000);
        assert!(settings.display_surfaces.floating_window_enabled);
        assert!(settings.display_surfaces.live_rate_enabled);
        assert!(settings.display_surfaces.status_tray_live_text_enabled);
        assert!(!settings.setup_guide_completed);
    }

    #[test]
    fn corrupt_settings_file_returns_error() {
        let path = unique_test_settings_path("corrupt");
        std::fs::write(&path, b"{not-json").unwrap();

        let error = read_app_settings_at(&path).unwrap_err();

        assert!(error.contains("设置文件不是有效 JSON"));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn settings_accept_only_supported_quota_refresh_cadences() {
        for accepted in [30_000, 60_000, 180_000, 300_000, 600_000] {
            let settings = AppSettingsSnapshot {
                quota_refresh_interval_ms: accepted,
                ..AppSettingsSnapshot::default()
            };

            assert_eq!(
                sanitize_app_settings(settings).quota_refresh_interval_ms,
                accepted
            );
        }

        for rejected in [0, 1, 31_000, 120_000, 900_000] {
            let settings = AppSettingsSnapshot {
                quota_refresh_interval_ms: rejected,
                ..AppSettingsSnapshot::default()
            };

            assert_eq!(
                sanitize_app_settings(settings).quota_refresh_interval_ms,
                60_000
            );
        }
    }

    #[test]
    fn locked_mutations_cannot_capture_the_same_old_snapshot() {
        let root = TestSettingsRoot::new("concurrent-mutations");
        let path = root.settings_path();
        write_fixture(&path, &AppSettingsSnapshot::default());
        let (first_read_tx, first_read_rx) = mpsc::channel();
        let (release_first_tx, release_first_rx) = mpsc::channel();

        let position_path = path.clone();
        let position_writer = thread::spawn(move || {
            mutate_app_settings_at_with_hooks(
                &position_path,
                || {
                    first_read_tx.send(()).unwrap();
                    release_first_rx.recv().unwrap();
                },
                |_, _| {},
                sync_parent_directory,
                |settings| {
                    settings.floating_position = Some(FloatingWindowPositionSnapshot {
                        x: 321.0,
                        y: 654.0,
                        saved_at: Some(77),
                    });
                },
            )
            .unwrap()
        });
        first_read_rx.recv().unwrap();

        let (second_started_tx, second_started_rx) = mpsc::channel();
        let (second_read_tx, second_read_rx) = mpsc::channel();
        let surfaces_path = path.clone();
        let surfaces_writer = thread::spawn(move || {
            second_started_tx.send(()).unwrap();
            mutate_app_settings_at_with_hooks(
                &surfaces_path,
                || second_read_tx.send(()).unwrap(),
                |_, _| {},
                sync_parent_directory,
                |settings| {
                    settings.display_surfaces = DisplaySurfaceSettingsSnapshot {
                        floating_window_enabled: false,
                        live_rate_enabled: true,
                        status_tray_live_text_enabled: false,
                    };
                },
            )
            .unwrap()
        });

        second_started_rx.recv().unwrap();
        assert!(second_read_rx
            .recv_timeout(Duration::from_millis(100))
            .is_err());
        release_first_tx.send(()).unwrap();
        position_writer.join().unwrap();
        second_read_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        surfaces_writer.join().unwrap();

        let saved = read_app_settings_at(&path).unwrap();
        let position = saved.floating_position.unwrap();
        assert_eq!(
            (position.x, position.y, position.saved_at),
            (321.0, 654.0, Some(77))
        );
        assert!(!saved.display_surfaces.floating_window_enabled);
        assert!(saved.display_surfaces.live_rate_enabled);
        assert!(!saved.display_surfaces.status_tray_live_text_enabled);
    }

    #[test]
    fn raw_reader_observes_complete_old_json_while_writer_waits_before_replace() {
        let root = TestSettingsRoot::new("reader-during-write");
        let path = root.settings_path();
        write_fixture(&path, &AppSettingsSnapshot::default());
        let (ready_tx, ready_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();

        let writer_path = path.clone();
        let writer = thread::spawn(move || {
            mutate_app_settings_at_with_hooks(
                &writer_path,
                || {},
                |_, _| {
                    ready_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                },
                sync_parent_directory,
                |settings| settings.custom_account_display_name = "replacement".into(),
            )
            .unwrap()
        });

        ready_rx.recv().unwrap();
        let visible: AppSettingsSnapshot =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert!(visible.custom_account_display_name.is_empty());
        release_tx.send(()).unwrap();
        writer.join().unwrap();

        assert_eq!(
            read_app_settings_at(&path)
                .unwrap()
                .custom_account_display_name,
            "replacement"
        );
    }

    #[test]
    fn directory_sync_failure_returns_committed_snapshot_with_diagnostic() {
        let root = TestSettingsRoot::new("directory-sync-diagnostic");
        let path = root.settings_path();
        write_fixture(&path, &AppSettingsSnapshot::default());

        let outcome = mutate_app_settings_at_with_hooks(
            &path,
            || {},
            |_, _| {},
            |_| Err("injected directory sync failure".into()),
            |settings| settings.custom_account_display_name = "committed".into(),
        )
        .unwrap();

        assert_eq!(outcome.settings.custom_account_display_name, "committed");
        assert!(outcome
            .diagnostic
            .as_deref()
            .unwrap()
            .contains("已提交但持久性未确认"));
        assert_eq!(
            read_app_settings_at(&path)
                .unwrap()
                .custom_account_display_name,
            "committed"
        );
    }

    #[test]
    fn valid_primary_ignores_an_interrupted_corrupt_temp_file() {
        let root = TestSettingsRoot::new("interrupted-temp");
        let path = root.settings_path();
        let settings = AppSettingsSnapshot {
            custom_account_display_name: "primary".into(),
            ..AppSettingsSnapshot::default()
        };
        write_fixture(&path, &settings);
        std::fs::write(interrupted_temp_path(&path, "0001"), b"{partial").unwrap();

        let outcome = read_app_settings_at_with_diagnostics(&path).unwrap();

        assert_eq!(outcome.settings.custom_account_display_name, "primary");
        assert!(outcome.diagnostic.is_none());
    }

    #[test]
    fn corrupt_primary_recovers_from_a_valid_interrupted_temp_with_diagnostic() {
        let root = TestSettingsRoot::new("corrupt-primary-recovery");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        let recovered = AppSettingsSnapshot {
            custom_account_display_name: "recovered".into(),
            quota_refresh_interval_ms: 180_000,
            ..AppSettingsSnapshot::default()
        };
        write_fixture(&interrupted_temp_path(&path, "9999"), &recovered);

        let outcome = read_app_settings_at_with_diagnostics(&path).unwrap();

        assert_eq!(outcome.settings.custom_account_display_name, "recovered");
        assert_eq!(outcome.settings.quota_refresh_interval_ms, 180_000);
        assert!(outcome
            .diagnostic
            .as_deref()
            .unwrap()
            .contains("已从中断写入恢复"));
        assert_eq!(
            read_app_settings_at(&path)
                .unwrap()
                .custom_account_display_name,
            "recovered"
        );
    }

    #[test]
    fn recovery_uses_cross_process_freshness_instead_of_pid_order() {
        let root = TestSettingsRoot::new("cross-process-freshness");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        let stale_path = interrupted_temp_path(&path, "99999-00000000000000000001");
        let fresh_path = interrupted_temp_path(&path, "00001-00000000000000000001");
        write_fixture(
            &stale_path,
            &AppSettingsSnapshot {
                custom_account_display_name: "stale-high-pid".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        write_fixture(
            &fresh_path,
            &AppSettingsSnapshot {
                custom_account_display_name: "fresh-low-pid".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        set_modified_time(&stale_path, UNIX_EPOCH + Duration::from_secs(10));
        set_modified_time(&fresh_path, UNIX_EPOCH + Duration::from_secs(20));

        let recovered = read_app_settings_at_with_diagnostics(&path).unwrap();

        assert_eq!(
            recovered.settings.custom_account_display_name,
            "fresh-low-pid"
        );
    }

    #[cfg(unix)]
    #[test]
    fn recovery_rejects_symlink_candidate_without_installing_it_as_primary() {
        use std::os::unix::fs::symlink;

        let root = TestSettingsRoot::new("symlink-candidate");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        let target = root.path.join("valid-target.json");
        write_fixture(
            &target,
            &AppSettingsSnapshot {
                custom_account_display_name: "must-not-follow".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        let candidate = interrupted_temp_path(&path, "99999-00000000000000000001");
        symlink(&target, &candidate).unwrap();

        let error = read_app_settings_at_with_diagnostics(&path).unwrap_err();

        assert!(error.contains("符号链接") || error.contains("非普通文件"));
        assert!(!std::fs::symlink_metadata(&path)
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(std::fs::symlink_metadata(&candidate).is_err());
    }

    #[test]
    fn recovery_rejects_and_removes_non_regular_candidate() {
        let root = TestSettingsRoot::new("directory-candidate");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        let candidate = interrupted_temp_path(&path, "99999-00000000000000000001");
        std::fs::create_dir(&candidate).unwrap();

        let error = read_app_settings_at_with_diagnostics(&path).unwrap_err();

        assert!(error.contains("非普通文件"));
        assert!(std::fs::symlink_metadata(&candidate).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn recovery_revalidates_candidate_after_scan_before_installing_snapshot() {
        use std::os::unix::fs::symlink;

        let root = TestSettingsRoot::new("candidate-toctou");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        let candidate = interrupted_temp_path(&path, "99999-00000000000000000001");
        write_fixture(&candidate, &AppSettingsSnapshot::default());
        let target = root.path.join("valid-target.json");
        write_fixture(
            &target,
            &AppSettingsSnapshot {
                custom_account_display_name: "must-not-install".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        let candidates = interrupted_temp_candidates(&path).unwrap();

        let error = recover_from_candidates_with_hook(
            &path,
            "corrupt primary".into(),
            candidates,
            |candidate_path| {
                std::fs::remove_file(candidate_path).unwrap();
                symlink(&target, candidate_path).unwrap();
            },
        )
        .unwrap_err();

        assert!(error.contains("安全打开") || error.contains("符号链接"));
        assert!(!std::fs::symlink_metadata(&path)
            .unwrap()
            .file_type()
            .is_symlink());
        assert_eq!(std::fs::read(&path).unwrap(), b"{corrupt-primary");
    }

    #[test]
    fn bounded_recovery_removes_invalid_candidates_then_reaches_older_valid_file() {
        let root = TestSettingsRoot::new("bounded-recovery");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        let valid = interrupted_temp_path(&path, "0001");
        write_fixture(
            &valid,
            &AppSettingsSnapshot {
                custom_account_display_name: "older-valid".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        let mut invalid = Vec::new();
        for index in 2..=RECOVERY_CANDIDATE_LIMIT + 1 {
            let candidate = interrupted_temp_path(&path, &format!("{index:04}"));
            std::fs::write(&candidate, b"{corrupt-temp").unwrap();
            invalid.push(candidate);
        }

        let first_error = read_app_settings_at_with_diagnostics(&path).unwrap_err();
        assert!(first_error.contains(&format!("仅检查前 {RECOVERY_CANDIDATE_LIMIT} 个")));
        assert!(invalid.iter().all(|candidate| !candidate.exists()));

        let recovered = read_app_settings_at_with_diagnostics(&path).unwrap();

        assert_eq!(
            recovered.settings.custom_account_display_name,
            "older-valid"
        );
    }

    #[test]
    fn repeated_atomic_replacement_overwrites_an_existing_destination() {
        let root = TestSettingsRoot::new("repeated-existing-destination");
        let path = root.settings_path();
        write_fixture(&path, &AppSettingsSnapshot::default());

        for index in 0..20 {
            let saved = mutate_app_settings_at(&path, |settings| {
                settings.custom_account_display_name = format!("replacement-{index}");
            })
            .unwrap();
            assert_eq!(
                saved.custom_account_display_name,
                format!("replacement-{index}")
            );
            assert_eq!(
                read_app_settings_at(&path)
                    .unwrap()
                    .custom_account_display_name,
                format!("replacement-{index}")
            );
        }
    }

    struct TestSettingsRoot {
        path: PathBuf,
    }

    impl TestSettingsRoot {
        fn new(label: &str) -> Self {
            let path = unique_test_settings_path(label).with_extension("d");
            std::fs::create_dir_all(&path).unwrap();
            Self { path }
        }

        fn settings_path(&self) -> PathBuf {
            self.path.join("settings.json")
        }
    }

    impl Drop for TestSettingsRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    fn write_fixture(path: &Path, settings: &AppSettingsSnapshot) {
        std::fs::write(path, serde_json::to_vec_pretty(settings).unwrap()).unwrap();
    }

    fn set_modified_time(path: &Path, modified: SystemTime) {
        let file = OpenOptions::new().write(true).open(path).unwrap();
        file.set_times(FileTimes::new().set_modified(modified))
            .unwrap();
    }

    fn interrupted_temp_path(settings_path: &Path, suffix: &str) -> PathBuf {
        settings_path.with_file_name(format!("settings.json.tmp-{suffix}"))
    }

    fn unique_test_settings_path(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "codex-token-bar-settings-{label}-{}-{nanos}.json",
            std::process::id()
        ))
    }
}
