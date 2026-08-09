use crate::core::{app_paths, app_paths::home_dir};
use crate::models::{
    AppSettingsSnapshot, AutoResumeSettingsSnapshot, DisplaySurfaceSettingsSnapshot,
    FloatingContentVisibilitySnapshot, FloatingWindowPositionSnapshot,
    FloatingWindowSettingsSnapshot, AUTO_RESUME_TASK_COLLECTION_VERSION,
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

const RECOVERY_DIAGNOSTIC_LIMIT: usize = 8;
const RECOVERY_CANDIDATE_MAX_BYTES: u64 = 1024 * 1024;
const RECOVERY_TOTAL_CANDIDATE_LIMIT: usize = 16;
const RECOVERY_DIRECTORY_ENTRY_LIMIT: usize = 1024;
const RECOVERY_TOTAL_BYTES_LIMIT: u64 = 2 * 1024 * 1024;
const COMMIT_MARKER_MAX_BYTES: u64 = 4096;
const TEMP_CREATE_ATTEMPT_LIMIT: usize = 16;
const FLOATING_PAGING_GUIDE_REVISION: u32 = 2;
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
enum PrimarySettingsRead {
    Missing,
    Valid(AppSettingsSnapshot),
    Invalid(String),
}

#[derive(Clone, Debug)]
struct RecoveryCandidate {
    path: PathBuf,
    freshness: u128,
    protocol: RecoveryCandidateProtocol,
    size: u64,
    precheck: Option<RecoveryCandidatePrecheck>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RecoveryCandidateProtocol {
    LegacyV3,
    TransactionalV4,
}

#[derive(Debug)]
enum RecoveryCandidateRead {
    Valid(AppSettingsSnapshot),
    ConclusivelyInvalid(String),
    Transient(String),
    TotalLimitExceeded(String),
}

#[derive(Clone, Debug)]
enum RecoveryCandidatePrecheck {
    ConclusivelyInvalid(String),
    Transient(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum SettingsCommitMarker {
    Pending {
        generation: u128,
        candidate_name: String,
    },
    Committed {
        generation: u128,
    },
}

#[derive(Debug)]
struct RecoveryReadBudget {
    remaining_bytes: u64,
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

pub fn complete_floating_paging_guide(
    show_page_navigation_arrows: bool,
) -> Result<AppSettingsSnapshot, String> {
    mutate_app_settings(|settings| {
        apply_floating_paging_guide_completion(settings, show_page_navigation_arrows);
    })
}

fn apply_floating_paging_guide_completion(
    settings: &mut AppSettingsSnapshot,
    show_page_navigation_arrows: bool,
) {
    settings.floating_window.paging_guide_revision = settings
        .floating_window
        .paging_guide_revision
        .max(FLOATING_PAGING_GUIDE_REVISION);
    settings
        .floating_window
        .content_visibility
        .show_page_navigation_arrows = show_page_navigation_arrows;
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
        settings.display_surfaces = sanitize_display_surfaces(display_surfaces);
    })
}

pub fn save_quota_refresh_interval_ms(interval_ms: u64) -> Result<AppSettingsSnapshot, String> {
    mutate_app_settings(|settings| {
        settings.quota_refresh_interval_ms = sanitize_quota_refresh_interval_ms(interval_ms);
    })
}

pub fn save_auto_resume_settings(
    auto_resume: AutoResumeSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    mutate_app_settings(|settings| {
        settings.auto_resume = sanitize_auto_resume_settings(auto_resume);
    })
}

pub fn save_session_enhancement_settings(
    session_enhancements: crate::models::SessionEnhancementSettingsSnapshot,
) -> Result<AppSettingsSnapshot, String> {
    mutate_app_settings(|settings| {
        settings.session_enhancements = sanitize_session_enhancement_settings(session_enhancements);
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
    let outcome = mutate_app_settings_at_with_hooks(
        path,
        |_| {},
        |_, _| {},
        sync_parent_directory,
        mutation,
    )?;
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
    AfterRead: FnOnce(&AppSettingsSnapshot),
    BeforeReplace: FnOnce(&Path, &Path),
    SyncParent: FnMut(&Path) -> Result<(), String>,
    Mutation: FnOnce(&mut AppSettingsSnapshot),
{
    mutate_app_settings_at_with_transaction_hooks(
        path,
        || {},
        after_read,
        before_replace,
        sync_parent,
        mutation,
    )
}

fn mutate_app_settings_at_with_transaction_hooks<
    BeforeLock,
    AfterRead,
    BeforeReplace,
    SyncParent,
    Mutation,
>(
    path: &Path,
    before_lock: BeforeLock,
    after_read: AfterRead,
    before_replace: BeforeReplace,
    sync_parent: SyncParent,
    mutation: Mutation,
) -> Result<SettingsMutationOutcome, String>
where
    BeforeLock: FnOnce(),
    AfterRead: FnOnce(&AppSettingsSnapshot),
    BeforeReplace: FnOnce(&Path, &Path),
    SyncParent: FnMut(&Path) -> Result<(), String>,
    Mutation: FnOnce(&mut AppSettingsSnapshot),
{
    before_lock();
    let _guard = settings_lock()
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let mut settings = read_app_settings_at(path)?;
    after_read(&settings);
    mutation(&mut settings);
    let saved = sanitize_app_settings(settings);
    let diagnostic = write_app_settings_at_with_hooks(path, &saved, before_replace, sync_parent)?;
    Ok(SettingsMutationOutcome {
        settings: saved,
        diagnostic,
    })
}

#[cfg(test)]
fn mutate_app_settings_at_with_cleanup_hook<CleanupCandidate, Mutation>(
    path: &Path,
    cleanup_candidate: CleanupCandidate,
    mutation: Mutation,
) -> Result<SettingsMutationOutcome, String>
where
    CleanupCandidate: FnMut(&Path) -> Result<(), String>,
    Mutation: FnOnce(&mut AppSettingsSnapshot),
{
    let _guard = settings_lock()
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let mut settings = read_app_settings_at(path)?;
    mutation(&mut settings);
    let saved = sanitize_app_settings(settings);
    let diagnostic = write_app_settings_at_with_controls(
        path,
        &saved,
        |_, _| {},
        sync_parent_directory,
        cleanup_candidate,
    )?;
    Ok(SettingsMutationOutcome {
        settings: saved,
        diagnostic,
    })
}

fn settings_lock() -> &'static Mutex<()> {
    SETTINGS_LOCK.get_or_init(|| Mutex::new(()))
}

fn install_recovered_settings_at(
    path: &Path,
    settings: &AppSettingsSnapshot,
    source_candidate: &Path,
) -> Result<Option<String>, String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("设置文件缺少父目录：{}", path.display()))?;
    std::fs::create_dir_all(parent)
        .map_err(|error| format!("创建设置目录失败：{}（{}）", parent.display(), error))?;
    let bytes = serde_json::to_vec_pretty(settings).map_err(|error| error.to_string())?;
    if bytes.len() as u64 > RECOVERY_CANDIDATE_MAX_BYTES {
        return Err(format!(
            "恢复快照大小 {} 超过安装上限 {RECOVERY_CANDIDATE_MAX_BYTES} bytes",
            bytes.len()
        ));
    }

    let existing_candidates = interrupted_temp_candidates(path)?;
    let marker = read_commit_marker(path)?;
    let eligible =
        eligible_recovery_candidates_for_marker(marker.clone(), existing_candidates.clone())?;
    if !eligible
        .iter()
        .any(|candidate| candidate.path == source_candidate && candidate.precheck.is_none())
    {
        return Err(format!(
            "恢复源候选在安装前已缺失或不再符合提交标记：{}",
            source_candidate.display()
        ));
    }
    let generation = next_ready_generation(&existing_candidates, marker.as_ref())?;
    let (in_progress_path, _, mut temp_file) = create_unique_in_progress_file(path)?;
    if let Err(error) = temp_file
        .write_all(&bytes)
        .and_then(|_| temp_file.flush())
        .and_then(|_| temp_file.sync_all())
    {
        drop(temp_file);
        let _ = std::fs::remove_file(&in_progress_path);
        return Err(format!(
            "写入恢复安装临时文件失败：{}（{}）",
            in_progress_path.display(),
            error
        ));
    }
    drop(temp_file);

    // The selected source candidate is already durable recovery state, so recovery can install
    // the synced snapshot directly without temporarily exceeding the candidate inventory bound.
    replace_settings_file(&in_progress_path, path).map_err(|error| {
        format!(
            "原子安装恢复设置失败：{} -> {}（{}）；原恢复候选仍保留：{}",
            in_progress_path.display(),
            path.display(),
            error,
            source_candidate.display()
        )
    })?;
    if let Err(error) = sync_parent_directory(parent) {
        return Ok(Some(format!(
            "恢复设置已提交但持久性未确认：{}（目录同步失败：{}；原恢复候选仍保留：{}）",
            path.display(),
            error,
            source_candidate.display()
        )));
    }

    let committed_marker = SettingsCommitMarker::Committed { generation };
    if let Err(error) = write_commit_marker(path, &committed_marker, &mut sync_parent_directory) {
        return Ok(Some(format!(
            "恢复设置已持久提交但完成标记持久性未确认：{}（{}；原恢复候选仍保留：{}）",
            path.display(),
            error,
            source_candidate.display()
        )));
    }

    Ok(cleanup_superseded_ready_candidates(
        &existing_candidates,
        &mut discard_recovery_candidate,
    ))
}

fn write_app_settings_at_with_hooks<BeforeReplace, SyncParent>(
    path: &Path,
    settings: &AppSettingsSnapshot,
    before_replace: BeforeReplace,
    sync_parent: SyncParent,
) -> Result<Option<String>, String>
where
    BeforeReplace: FnOnce(&Path, &Path),
    SyncParent: FnMut(&Path) -> Result<(), String>,
{
    write_app_settings_at_with_controls(
        path,
        settings,
        before_replace,
        sync_parent,
        discard_recovery_candidate,
    )
}

fn write_app_settings_at_with_controls<BeforeReplace, SyncParent, CleanupCandidate>(
    path: &Path,
    settings: &AppSettingsSnapshot,
    before_replace: BeforeReplace,
    sync_parent: SyncParent,
    cleanup_candidate: CleanupCandidate,
) -> Result<Option<String>, String>
where
    BeforeReplace: FnOnce(&Path, &Path),
    SyncParent: FnMut(&Path) -> Result<(), String>,
    CleanupCandidate: FnMut(&Path) -> Result<(), String>,
{
    let mut sync_parent = sync_parent;
    let mut cleanup_candidate = cleanup_candidate;
    let parent = path
        .parent()
        .ok_or_else(|| format!("设置文件缺少父目录：{}", path.display()))?;
    std::fs::create_dir_all(parent)
        .map_err(|error| format!("创建设置目录失败：{}（{}）", parent.display(), error))?;

    let bytes = serde_json::to_vec_pretty(settings).map_err(|error| error.to_string())?;
    let existing_candidates = interrupted_temp_candidates(path)?;
    let (existing_marker, marker_repair_diagnostic) =
        read_or_repair_commit_marker_for_write(path, &existing_candidates, &mut sync_parent)?;
    let existing_candidates = prepare_ready_candidates_for_admission(
        path,
        existing_candidates,
        existing_marker.as_ref(),
        bytes.len() as u64,
        &mut sync_parent,
        &mut cleanup_candidate,
    )
    .map_err(|error| attach_prior_diagnostic(error, &marker_repair_diagnostic))?;
    let generation = next_ready_generation(&existing_candidates, existing_marker.as_ref())
        .map_err(|error| attach_prior_diagnostic(error, &marker_repair_diagnostic))?;
    let (in_progress_path, sequence, mut temp_file) = create_unique_in_progress_file(path)
        .map_err(|error| attach_prior_diagnostic(error, &marker_repair_diagnostic))?;
    if let Err(error) = temp_file
        .write_all(&bytes)
        .and_then(|_| temp_file.flush())
        .and_then(|_| temp_file.sync_all())
    {
        drop(temp_file);
        let _ = std::fs::remove_file(&in_progress_path);
        return Err(attach_prior_diagnostic(
            format!(
                "写入设置进行中临时文件失败：{}（{}）",
                in_progress_path.display(),
                error
            ),
            &marker_repair_diagnostic,
        ));
    }
    drop(temp_file);

    let ready_path = ready_settings_temp_path(path, generation, sequence)
        .map_err(|error| attach_prior_diagnostic(error, &marker_repair_diagnostic))?;
    replace_settings_file(&in_progress_path, &ready_path).map_err(|error| {
        attach_prior_diagnostic(
            format!(
                "发布设置恢复候选失败：{} -> {}（{}）；进行中文件保持不可恢复状态",
                in_progress_path.display(),
                ready_path.display(),
                error
            ),
            &marker_repair_diagnostic,
        )
    })?;
    if let Err(error) = sync_parent(parent) {
        return Err(attach_prior_diagnostic(
            format!(
                "设置恢复候选已发布但目录持久性未确认，未尝试替换主设置：{}（{}）",
                ready_path.display(),
                error
            ),
            &marker_repair_diagnostic,
        ));
    }

    let candidate_name = ready_path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("恢复候选文件名不是有效 UTF-8：{}", ready_path.display()))?
        .to_owned();
    let pending_marker = SettingsCommitMarker::Pending {
        generation,
        candidate_name,
    };
    write_commit_marker(path, &pending_marker, &mut sync_parent).map_err(|error| {
        attach_prior_diagnostic(
            format!(
                "设置恢复候选已持久发布但待提交标记失败，未尝试替换主设置：{}（{}）",
                ready_path.display(),
                error
            ),
            &marker_repair_diagnostic,
        )
    })?;

    // Crash order: durable ready -> durable pending marker -> primary -> durable committed marker.
    // Pending permits only its exact ready path; committed rejects every leftover ready path.
    before_replace(&ready_path, path);
    replace_settings_file(&ready_path, path).map_err(|error| {
        attach_prior_diagnostic(
            format!(
                "原子替换设置文件失败：{} -> {}（{}）；已保留临时文件用于恢复",
                ready_path.display(),
                path.display(),
                error
            ),
            &marker_repair_diagnostic,
        )
    })?;
    if let Err(error) = sync_parent(parent) {
        return Ok(merge_diagnostics(
            marker_repair_diagnostic,
            Some(format!(
                "设置文件已提交但持久性未确认：{}（目录同步失败：{}；待提交标记继续阻止旧候选回滚）",
                path.display(),
                error
            )),
        ));
    }

    let committed_marker = SettingsCommitMarker::Committed { generation };
    if let Err(error) = write_commit_marker(path, &committed_marker, &mut sync_parent) {
        return Ok(merge_diagnostics(
            marker_repair_diagnostic,
            Some(format!(
                "设置文件已持久提交但完成标记持久性未确认：{}（{}；待提交标记继续阻止旧候选回滚）",
                path.display(),
                error
            )),
        ));
    }

    Ok(merge_diagnostics(
        marker_repair_diagnostic,
        cleanup_superseded_ready_candidates(&existing_candidates, &mut cleanup_candidate),
    ))
}

fn create_unique_in_progress_file(path: &Path) -> Result<(PathBuf, u64, File), String> {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("设置文件名不是有效 UTF-8：{}", path.display()))?;
    let parent = path
        .parent()
        .ok_or_else(|| format!("设置文件缺少父目录：{}", path.display()))?;

    for _ in 0..TEMP_CREATE_ATTEMPT_LIMIT {
        let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let created_at = system_time_key(SystemTime::now());
        let temp_path = parent.join(format!(
            "{file_name}.tmp-in-progress-v3-{created_at:039}-{}-{sequence:020}",
            std::process::id(),
        ));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp_path)
        {
            Ok(file) => return Ok((temp_path, sequence, file)),
            Err(error) if error.kind() == ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(format!(
                    "创建设置进行中临时文件失败：{}（{}）",
                    temp_path.display(),
                    error
                ));
            }
        }
    }

    Err(format!(
        "创建唯一设置进行中临时文件失败：连续 {TEMP_CREATE_ATTEMPT_LIMIT} 次命名冲突"
    ))
}

fn ready_settings_temp_path(
    path: &Path,
    generation: u128,
    sequence: u64,
) -> Result<PathBuf, String> {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("设置文件名不是有效 UTF-8：{}", path.display()))?;
    let parent = path
        .parent()
        .ok_or_else(|| format!("设置文件缺少父目录：{}", path.display()))?;
    Ok(parent.join(format!(
        "{file_name}.tmp-ready-v4-{generation:039}-{}-{sequence:020}",
        std::process::id(),
    )))
}

fn ensure_new_ready_candidate_fits(
    existing: &[RecoveryCandidate],
    new_bytes: u64,
) -> Result<(), String> {
    if new_bytes > RECOVERY_CANDIDATE_MAX_BYTES {
        return Err(format!(
            "不能发布新的设置恢复候选：单个候选大小 {new_bytes} 超过上限 {RECOVERY_CANDIDATE_MAX_BYTES} bytes"
        ));
    }
    if existing.len() >= RECOVERY_TOTAL_CANDIDATE_LIMIT {
        return Err(format!(
            "不能发布新的设置恢复候选：现有候选数量 {} 已达到上限 {}",
            existing.len(),
            RECOVERY_TOTAL_CANDIDATE_LIMIT
        ));
    }
    let existing_bytes = existing
        .iter()
        .try_fold(0u64, |total, candidate| total.checked_add(candidate.size));
    let Some(total_bytes) = existing_bytes.and_then(|total| total.checked_add(new_bytes)) else {
        return Err("不能发布新的设置恢复候选：候选累计大小溢出".into());
    };
    if total_bytes > RECOVERY_TOTAL_BYTES_LIMIT {
        return Err(format!(
            "不能发布新的设置恢复候选：累计大小 {total_bytes} 超过上限 {RECOVERY_TOTAL_BYTES_LIMIT} bytes"
        ));
    }
    Ok(())
}

fn prepare_ready_candidates_for_admission<SyncParent, CleanupCandidate>(
    path: &Path,
    existing: Vec<RecoveryCandidate>,
    marker: Option<&SettingsCommitMarker>,
    new_bytes: u64,
    sync_parent: &mut SyncParent,
    cleanup_candidate: &mut CleanupCandidate,
) -> Result<Vec<RecoveryCandidate>, String>
where
    SyncParent: FnMut(&Path) -> Result<(), String>,
    CleanupCandidate: FnMut(&Path) -> Result<(), String>,
{
    let capacity_error = match ensure_new_ready_candidate_fits(&existing, new_bytes) {
        Ok(()) => return Ok(existing),
        Err(error) => error,
    };
    if new_bytes > RECOVERY_CANDIDATE_MAX_BYTES {
        return Err(capacity_error);
    }

    let marker_before = marker.cloned();
    let retained_pending = match marker_before.as_ref() {
        Some(SettingsCommitMarker::Pending { .. }) => {
            let eligible =
                eligible_recovery_candidates_for_marker(marker_before.clone(), existing.clone())?;
            let candidate = eligible
                .first()
                .ok_or_else(|| "待提交设置恢复候选缺失；拒绝容量清理".to_string())?;
            if candidate.precheck.is_some() {
                return Err(format!(
                    "待提交设置恢复候选不再是可安全恢复的普通文件，拒绝容量清理：{}",
                    candidate.path.display()
                ));
            }
            Some(candidate.path.clone())
        }
        Some(SettingsCommitMarker::Committed { .. }) => None,
        None => {
            return Err(format!(
                "{capacity_error}；没有耐久提交标记可证明哪些恢复候选已被取代，拒绝自动清理"
            ));
        }
    };

    let marker_for_cleanup = marker_before
        .as_ref()
        .ok_or_else(|| "容量清理缺少提交标记，已停止保存".to_string())?;
    let cleanup_targets = provably_superseded_ready_candidates(
        path,
        &existing,
        marker_for_cleanup,
        retained_pending.as_deref(),
    )?;
    if cleanup_targets.is_empty() {
        return Err(format!(
            "{capacity_error}；唯一候选是必须保留的待提交恢复候选，无法安全腾出容量"
        ));
    }

    let mut failures = Vec::new();
    let mut omitted = 0usize;
    let mut removed = 0usize;
    for candidate in cleanup_targets {
        match cleanup_candidate(&candidate.path) {
            Ok(()) => removed += 1,
            Err(error) => record_recovery_diagnostic(&mut failures, &mut omitted, || {
                format!("{}（{}）", candidate.path.display(), error)
            }),
        }
    }

    let parent = path
        .parent()
        .ok_or_else(|| format!("设置文件缺少父目录：{}", path.display()))?;
    if let Err(error) = sync_parent(parent) {
        return Err(format_capacity_cleanup_failure(
            retained_pending.as_deref(),
            removed,
            &failures,
            omitted,
            Some(format!("父目录同步失败：{error}")),
            &capacity_error,
        ));
    }
    if !failures.is_empty() {
        return Err(format_capacity_cleanup_failure(
            retained_pending.as_deref(),
            removed,
            &failures,
            omitted,
            None,
            &capacity_error,
        ));
    }

    let marker_after = read_commit_marker(path).map_err(|error| {
        format!("设置恢复候选容量清理后无法重新验证提交标记，已停止保存：{error}")
    })?;
    if marker_after != marker_before {
        return Err("设置恢复候选容量清理期间提交标记发生变化，已停止保存".into());
    }
    let refreshed = interrupted_temp_candidates(path)?;
    provably_superseded_ready_candidates(
        path,
        &refreshed,
        marker_after
            .as_ref()
            .ok_or_else(|| "容量清理后提交标记意外缺失，已停止保存".to_string())?,
        retained_pending.as_deref(),
    )?;
    if matches!(marker_after, Some(SettingsCommitMarker::Pending { .. })) {
        let eligible =
            eligible_recovery_candidates_for_marker(marker_after.clone(), refreshed.clone())?;
        if eligible
            .first()
            .is_none_or(|candidate| candidate.precheck.is_some())
        {
            return Err("容量清理后待提交设置恢复候选不再可安全恢复，已停止保存".into());
        }
    }
    ensure_new_ready_candidate_fits(&refreshed, new_bytes)?;
    Ok(refreshed)
}

fn provably_superseded_ready_candidates<'a>(
    settings_path: &Path,
    candidates: &'a [RecoveryCandidate],
    marker: &SettingsCommitMarker,
    retained_pending: Option<&Path>,
) -> Result<Vec<&'a RecoveryCandidate>, String> {
    let marker_generation = marker.generation();
    let mut cleanup = Vec::new();
    let mut unproven = Vec::new();
    let mut omitted = 0usize;

    for candidate in candidates {
        if retained_pending == Some(candidate.path.as_path()) {
            continue;
        }
        if let Some(RecoveryCandidatePrecheck::Transient(error)) = candidate.precheck.as_ref() {
            record_recovery_diagnostic(&mut unproven, &mut omitted, || {
                format!(
                    "{}（候选身份无法确认：{}）",
                    candidate.path.display(),
                    error
                )
            });
            continue;
        }
        match ready_candidate_generation(settings_path, candidate) {
            Some(generation) if generation < marker_generation => cleanup.push(candidate),
            Some(generation) => {
                record_recovery_diagnostic(&mut unproven, &mut omitted, || {
                    format!(
                        "{}（候选代次 {generation}，标记代次 {marker_generation}）",
                        candidate.path.display()
                    )
                });
            }
            None => record_recovery_diagnostic(&mut unproven, &mut omitted, || {
                format!("{}（候选代次或身份无法确认）", candidate.path.display())
            }),
        }
    }

    if !unproven.is_empty() {
        let omitted = if omitted == 0 {
            String::new()
        } else {
            format!("；另省略 {omitted} 项")
        };
        return Err(format!(
            "发现未被当前提交标记证明已过时的恢复候选，拒绝容量清理并停止保存：{}{}",
            unproven.join("；"),
            omitted
        ));
    }
    Ok(cleanup)
}

fn ready_candidate_generation(settings_path: &Path, candidate: &RecoveryCandidate) -> Option<u128> {
    let settings_name = settings_path.file_name()?.to_str()?;
    let candidate_name = candidate.path.file_name()?.to_str()?;
    let prefix = match candidate.protocol {
        RecoveryCandidateProtocol::LegacyV3 => format!("{settings_name}.tmp-ready-v3-"),
        RecoveryCandidateProtocol::TransactionalV4 => format!("{settings_name}.tmp-ready-v4-"),
    };
    ready_candidate_freshness(candidate_name, &prefix)
}

fn format_capacity_cleanup_failure(
    retained_pending: Option<&Path>,
    removed: usize,
    failures: &[String],
    omitted: usize,
    durability_error: Option<String>,
    capacity_error: &str,
) -> String {
    let retained = retained_pending.map_or_else(
        || "没有待提交候选需要保留".to_string(),
        |path| format!("已保留待提交候选 {}", path.display()),
    );
    let failures = if failures.is_empty() {
        "没有逐项清理错误".to_string()
    } else {
        format!("清理失败：{}", failures.join("；"))
    };
    let omitted = if omitted == 0 {
        String::new()
    } else {
        format!("；另省略 {omitted} 项")
    };
    let durability_error = durability_error
        .map(|error| format!("；{error}"))
        .unwrap_or_default();
    format!(
        "设置恢复候选容量清理不确定，已停止保存：{retained}；已清理 {removed} 项；{failures}{omitted}{durability_error}；原容量诊断：{capacity_error}"
    )
}

fn next_ready_generation(
    candidates: &[RecoveryCandidate],
    marker: Option<&SettingsCommitMarker>,
) -> Result<u128, String> {
    let marker_generation = marker.map_or(0, SettingsCommitMarker::generation);
    let candidate_generation = candidates
        .iter()
        .map(|candidate| candidate.freshness)
        .max()
        .unwrap_or_default();
    system_time_key(SystemTime::now())
        .max(marker_generation)
        .max(candidate_generation)
        .checked_add(1)
        .ok_or_else(|| "设置恢复代次已溢出".into())
}

impl SettingsCommitMarker {
    fn generation(&self) -> u128 {
        match self {
            Self::Pending { generation, .. } | Self::Committed { generation } => *generation,
        }
    }

    fn encode(&self) -> String {
        match self {
            Self::Pending {
                generation,
                candidate_name,
            } => format!("v1 pending {generation} {candidate_name}\n"),
            Self::Committed { generation } => format!("v1 committed {generation}\n"),
        }
    }
}

fn commit_marker_path(path: &Path) -> Result<PathBuf, String> {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("设置文件名不是有效 UTF-8：{}", path.display()))?;
    Ok(path.with_file_name(format!("{file_name}.commit-v1")))
}

fn read_or_repair_commit_marker_for_write<SyncParent>(
    settings_path: &Path,
    candidates: &[RecoveryCandidate],
    sync_parent: &mut SyncParent,
) -> Result<(Option<SettingsCommitMarker>, Option<String>), String>
where
    SyncParent: FnMut(&Path) -> Result<(), String>,
{
    match read_commit_marker(settings_path) {
        Ok(marker) => Ok((marker, None)),
        Err(marker_error) => {
            validate_authoritative_primary_for_marker_repair(settings_path).map_err(
                |primary_error| {
                    format!(
                        "{marker_error}；主设置不能证明为有效安全普通文件，拒绝修复提交标记：{primary_error}"
                    )
                },
            )?;
            let quarantine_path = quarantine_bad_commit_marker(settings_path, sync_parent)?;
            let repaired_generation = next_ready_generation(candidates, None)?;
            let repaired_marker = SettingsCommitMarker::Committed {
                generation: repaired_generation,
            };
            write_commit_marker(settings_path, &repaired_marker, sync_parent).map_err(|error| {
                format!(
                    "损坏设置提交标记已隔离至 {}，但根据有效主设置重建耐久完成标记失败：{}",
                    quarantine_path.display(),
                    error
                )
            })?;
            Ok((
                Some(repaired_marker),
                Some(format!(
                    "损坏设置提交标记已隔离至 {}，并根据有效主设置重建完成标记（原错误：{}）",
                    quarantine_path.display(),
                    marker_error
                )),
            ))
        }
    }
}

fn validate_authoritative_primary_for_marker_repair(path: &Path) -> Result<(), String> {
    match read_primary_settings_at(path) {
        PrimarySettingsRead::Valid(_) => Ok(()),
        PrimarySettingsRead::Missing => Err(format!("主设置不存在：{}", path.display())),
        PrimarySettingsRead::Invalid(error) => Err(error),
    }
}

fn quarantine_bad_commit_marker<SyncParent>(
    settings_path: &Path,
    sync_parent: &mut SyncParent,
) -> Result<PathBuf, String>
where
    SyncParent: FnMut(&Path) -> Result<(), String>,
{
    let marker_path = commit_marker_path(settings_path)?;
    let parent = marker_path
        .parent()
        .ok_or_else(|| format!("设置提交标记缺少父目录：{}", marker_path.display()))?;
    let marker_name = marker_path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| {
            format!(
                "设置提交标记文件名不是有效 UTF-8：{}",
                marker_path.display()
            )
        })?;

    for _ in 0..TEMP_CREATE_ATTEMPT_LIMIT {
        let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let quarantined_at = system_time_key(SystemTime::now());
        let quarantine_path = marker_path.with_file_name(format!(
            "{marker_name}.corrupt-v1-{quarantined_at:039}-{}-{sequence:020}",
            std::process::id()
        ));
        let reservation = match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&quarantine_path)
        {
            Ok(file) => file,
            Err(error) if error.kind() == ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(format!(
                    "创建损坏设置提交标记隔离保留位失败：{}（{}）",
                    quarantine_path.display(),
                    error
                ));
            }
        };
        drop(reservation);

        if let Err(error) = replace_settings_file(&marker_path, &quarantine_path) {
            let _ = std::fs::remove_file(&quarantine_path);
            return Err(format!(
                "隔离损坏设置提交标记失败：{} -> {}（{}）",
                marker_path.display(),
                quarantine_path.display(),
                error
            ));
        }
        sync_parent(parent).map_err(|error| {
            format!(
                "损坏设置提交标记已隔离至 {}，但父目录持久性未确认：{}",
                quarantine_path.display(),
                error
            )
        })?;
        return Ok(quarantine_path);
    }

    Err(format!(
        "创建唯一损坏设置提交标记隔离路径失败：连续 {TEMP_CREATE_ATTEMPT_LIMIT} 次命名冲突"
    ))
}

fn read_commit_marker(path: &Path) -> Result<Option<SettingsCommitMarker>, String> {
    let marker_path = commit_marker_path(path)?;
    let entry_metadata = match std::fs::symlink_metadata(&marker_path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(format!(
                "检查设置提交标记目录项失败：{}（{}）",
                marker_path.display(),
                error
            ));
        }
    };
    if !entry_metadata.file_type().is_file()
        || entry_metadata.file_type().is_symlink()
        || metadata_is_reparse_point(&entry_metadata)
    {
        return Err(format!(
            "设置提交标记不是安全普通文件：{}",
            marker_path.display()
        ));
    }
    let mut options = OpenOptions::new();
    options.read(true);
    configure_recovery_open_no_follow(&mut options);
    let file = match options.open(&marker_path) {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(format!(
                "安全打开设置提交标记失败：{}（{}）",
                marker_path.display(),
                error
            ));
        }
    };
    let metadata = file
        .metadata()
        .map_err(|error| format!("读取设置提交标记元数据失败：{}", error))?;
    if !metadata.file_type().is_file() || metadata_is_reparse_point(&metadata) {
        return Err(format!(
            "设置提交标记不是安全普通文件：{}",
            marker_path.display()
        ));
    }
    if metadata.len() > COMMIT_MARKER_MAX_BYTES {
        return Err(format!(
            "设置提交标记超过大小上限：{} > {} bytes",
            metadata.len(),
            COMMIT_MARKER_MAX_BYTES
        ));
    }
    let mut bytes = Vec::new();
    file.take(COMMIT_MARKER_MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("读取设置提交标记失败：{}", error))?;
    if bytes.len() as u64 > COMMIT_MARKER_MAX_BYTES {
        return Err(format!(
            "设置提交标记读取超过大小上限：{} > {} bytes",
            bytes.len(),
            COMMIT_MARKER_MAX_BYTES
        ));
    }
    parse_commit_marker(path, &marker_path, &bytes).map(Some)
}

fn parse_commit_marker(
    settings_path: &Path,
    marker_path: &Path,
    bytes: &[u8],
) -> Result<SettingsCommitMarker, String> {
    let text = std::str::from_utf8(bytes).map_err(|error| {
        format!(
            "设置提交标记不是 UTF-8：{}（{}）",
            marker_path.display(),
            error
        )
    })?;
    let parts: Vec<&str> = text.split_whitespace().collect();
    match parts.as_slice() {
        ["v1", "pending", generation, candidate_name] => {
            let generation = generation.parse().map_err(|error| {
                format!(
                    "设置提交标记代次无效：{}（{}）",
                    marker_path.display(),
                    error
                )
            })?;
            let file_name = settings_path
                .file_name()
                .and_then(|name| name.to_str())
                .ok_or_else(|| format!("设置文件名不是有效 UTF-8：{}", settings_path.display()))?;
            let expected_prefix = format!("{file_name}.tmp-ready-v4-");
            if !candidate_name.starts_with(&expected_prefix) {
                return Err(format!(
                    "设置待提交标记引用了无效恢复候选：{}",
                    candidate_name
                ));
            }
            Ok(SettingsCommitMarker::Pending {
                generation,
                candidate_name: (*candidate_name).into(),
            })
        }
        ["v1", "committed", generation] => {
            let generation = generation.parse().map_err(|error| {
                format!(
                    "设置提交标记代次无效：{}（{}）",
                    marker_path.display(),
                    error
                )
            })?;
            Ok(SettingsCommitMarker::Committed { generation })
        }
        _ => Err(format!("设置提交标记格式无效：{}", marker_path.display())),
    }
}

fn write_commit_marker<SyncParent>(
    settings_path: &Path,
    marker: &SettingsCommitMarker,
    sync_parent: &mut SyncParent,
) -> Result<(), String>
where
    SyncParent: FnMut(&Path) -> Result<(), String>,
{
    let marker_path = commit_marker_path(settings_path)?;
    let parent = marker_path
        .parent()
        .ok_or_else(|| format!("设置提交标记缺少父目录：{}", marker_path.display()))?;
    let marker_name = marker_path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| {
            format!(
                "设置提交标记文件名不是有效 UTF-8：{}",
                marker_path.display()
            )
        })?;
    let mut created_temp = None;
    for _ in 0..TEMP_CREATE_ATTEMPT_LIMIT {
        let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let created_at = system_time_key(SystemTime::now());
        let temp_path = marker_path.with_file_name(format!(
            "{marker_name}.tmp-{created_at:039}-{}-{sequence:020}",
            std::process::id()
        ));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp_path)
        {
            Ok(file) => {
                created_temp = Some((temp_path, file));
                break;
            }
            Err(error) if error.kind() == ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(format!(
                    "创建设置提交标记临时文件失败：{}（{}）",
                    temp_path.display(),
                    error
                ));
            }
        }
    }
    let (temp_path, mut file) = created_temp.ok_or_else(|| {
        format!("创建唯一设置提交标记临时文件失败：连续 {TEMP_CREATE_ATTEMPT_LIMIT} 次命名冲突")
    })?;
    let bytes = marker.encode().into_bytes();
    if let Err(error) = file
        .write_all(&bytes)
        .and_then(|_| file.flush())
        .and_then(|_| file.sync_all())
    {
        drop(file);
        let _ = std::fs::remove_file(&temp_path);
        return Err(format!(
            "写入设置提交标记临时文件失败：{}（{}）",
            temp_path.display(),
            error
        ));
    }
    drop(file);
    replace_settings_file(&temp_path, &marker_path).map_err(|error| {
        format!(
            "原子替换设置提交标记失败：{} -> {}（{}）",
            temp_path.display(),
            marker_path.display(),
            error
        )
    })?;
    sync_parent(parent).map_err(|error| {
        format!(
            "设置提交标记已替换但目录持久性未确认：{}（{}）",
            marker_path.display(),
            error
        )
    })
}

fn cleanup_superseded_ready_candidates<CleanupCandidate>(
    candidates: &[RecoveryCandidate],
    cleanup_candidate: &mut CleanupCandidate,
) -> Option<String>
where
    CleanupCandidate: FnMut(&Path) -> Result<(), String>,
{
    let mut failures = Vec::new();
    let mut omitted = 0usize;
    for candidate in candidates {
        if let Err(error) = cleanup_candidate(&candidate.path) {
            record_recovery_diagnostic(&mut failures, &mut omitted, || {
                format!("{}（{}）", candidate.path.display(), error)
            });
        }
    }
    if failures.is_empty() {
        None
    } else {
        let omitted = if omitted > 0 {
            format!("；另省略 {omitted} 个失败")
        } else {
            String::new()
        };
        Some(format!(
            "设置已提交，但旧恢复候选清理失败：{}{}",
            failures.join("；"),
            omitted
        ))
    }
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
    match read_primary_settings_at(path) {
        PrimarySettingsRead::Valid(settings) => Ok(SettingsReadOutcome {
            settings,
            diagnostic: None,
        }),
        PrimarySettingsRead::Missing => {
            let candidates = interrupted_temp_candidates(path)?;
            if candidates.is_empty() && read_commit_marker(path)?.is_none() {
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
        PrimarySettingsRead::Invalid(primary_error) => {
            recover_interrupted_settings(path, primary_error)
        }
    }
}

fn read_primary_settings_at(path: &Path) -> PrimarySettingsRead {
    read_primary_settings_at_with_controls(path, || {}, metadata_is_reparse_point)
}

fn read_primary_settings_at_with_controls<AfterOpen, IsReparse>(
    path: &Path,
    after_open: AfterOpen,
    is_reparse: IsReparse,
) -> PrimarySettingsRead
where
    AfterOpen: FnOnce(),
    IsReparse: Fn(&std::fs::Metadata) -> bool,
{
    let entry_metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return PrimarySettingsRead::Missing,
        Err(error) => {
            return PrimarySettingsRead::Invalid(format!(
                "检查主设置目录项失败：{}（{}）",
                path.display(),
                error
            ));
        }
    };
    if is_reparse(&entry_metadata) {
        return PrimarySettingsRead::Invalid(format!(
            "主设置是 Windows reparse point：{}",
            path.display()
        ));
    }
    if !entry_metadata.file_type().is_file() || entry_metadata.file_type().is_symlink() {
        return PrimarySettingsRead::Invalid(format!("主设置不是安全普通文件：{}", path.display()));
    }
    if entry_metadata.len() > RECOVERY_CANDIDATE_MAX_BYTES {
        return PrimarySettingsRead::Invalid(format!(
            "主设置大小超过上限：{} > {} bytes（{}）",
            entry_metadata.len(),
            RECOVERY_CANDIDATE_MAX_BYTES,
            path.display()
        ));
    }

    let mut options = OpenOptions::new();
    options.read(true);
    configure_recovery_open_no_follow(&mut options);
    let mut file = match options.open(path) {
        Ok(file) => file,
        Err(error) => {
            return PrimarySettingsRead::Invalid(format!(
                "安全打开主设置失败：{}（{}）",
                path.display(),
                error
            ));
        }
    };
    let opened_metadata = match file.metadata() {
        Ok(metadata) => metadata,
        Err(error) => {
            return PrimarySettingsRead::Invalid(format!(
                "读取已打开主设置元数据失败：{}（{}）",
                path.display(),
                error
            ));
        }
    };
    if is_reparse(&opened_metadata) {
        return PrimarySettingsRead::Invalid(format!(
            "已打开主设置是 Windows reparse point：{}",
            path.display()
        ));
    }
    if !opened_metadata.file_type().is_file() {
        return PrimarySettingsRead::Invalid(format!(
            "已打开主设置不是安全普通文件：{}",
            path.display()
        ));
    }
    if opened_metadata.len() > RECOVERY_CANDIDATE_MAX_BYTES {
        return PrimarySettingsRead::Invalid(format!(
            "已打开主设置大小超过上限：{} > {} bytes（{}）",
            opened_metadata.len(),
            RECOVERY_CANDIDATE_MAX_BYTES,
            path.display()
        ));
    }
    if !primary_metadata_identity_matches(&entry_metadata, &opened_metadata) {
        return PrimarySettingsRead::Invalid(format!(
            "主设置身份在安全打开期间发生变化：{}",
            path.display()
        ));
    }
    if let Err(error) =
        validate_primary_opened_path_identity(path, &file, &is_reparse, "安全打开期间")
    {
        return PrimarySettingsRead::Invalid(error);
    }

    after_open();

    let mut bytes = Vec::new();
    if let Err(error) = (&mut file)
        .take(RECOVERY_CANDIDATE_MAX_BYTES + 1)
        .read_to_end(&mut bytes)
    {
        return PrimarySettingsRead::Invalid(format!(
            "读取主设置失败：{}（{}）",
            path.display(),
            error
        ));
    }
    if bytes.len() as u64 > RECOVERY_CANDIDATE_MAX_BYTES {
        return PrimarySettingsRead::Invalid(format!(
            "读取主设置超过大小上限：{} > {} bytes（{}）",
            bytes.len(),
            RECOVERY_CANDIDATE_MAX_BYTES,
            path.display()
        ));
    }

    let post_opened_metadata = match file.metadata() {
        Ok(metadata) => metadata,
        Err(error) => {
            return PrimarySettingsRead::Invalid(format!(
                "读取后重新检查已打开主设置失败：{}（{}）",
                path.display(),
                error
            ));
        }
    };
    if is_reparse(&post_opened_metadata) || !post_opened_metadata.file_type().is_file() {
        return PrimarySettingsRead::Invalid(format!(
            "读取后已打开主设置不是安全普通文件：{}",
            path.display()
        ));
    }
    if post_opened_metadata.len() > RECOVERY_CANDIDATE_MAX_BYTES {
        return PrimarySettingsRead::Invalid(format!(
            "读取后主设置大小超过上限：{} > {} bytes（{}）",
            post_opened_metadata.len(),
            RECOVERY_CANDIDATE_MAX_BYTES,
            path.display()
        ));
    }
    if !primary_metadata_identity_matches(&opened_metadata, &post_opened_metadata) {
        return PrimarySettingsRead::Invalid(format!(
            "已打开主设置身份在读取期间发生变化：{}",
            path.display()
        ));
    }

    if let Err(error) = validate_primary_opened_path_identity(path, &file, &is_reparse, "读取期间")
    {
        return PrimarySettingsRead::Invalid(error);
    }

    match parse_settings(path, &bytes) {
        Ok(settings) => PrimarySettingsRead::Valid(settings),
        Err(error) => PrimarySettingsRead::Invalid(error),
    }
}

#[cfg(test)]
fn read_primary_settings_at_for_test<AfterOpen, IsReparse>(
    path: &Path,
    after_open: AfterOpen,
    is_reparse: IsReparse,
) -> Result<AppSettingsSnapshot, String>
where
    AfterOpen: FnOnce(),
    IsReparse: Fn(&std::fs::Metadata) -> bool,
{
    match read_primary_settings_at_with_controls(path, after_open, is_reparse) {
        PrimarySettingsRead::Valid(settings) => Ok(settings),
        PrimarySettingsRead::Missing => Err(format!("主设置不存在：{}", path.display())),
        PrimarySettingsRead::Invalid(error) => Err(error),
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
    before_candidate_open: BeforeCandidateOpen,
) -> Result<SettingsReadOutcome, String>
where
    BeforeCandidateOpen: FnMut(&Path),
{
    recover_from_candidates_with_controls(
        path,
        primary_error,
        candidates,
        before_candidate_open,
        read_recovery_candidate,
    )
}

#[cfg(test)]
fn recover_from_candidates_with_reader<ReadCandidate>(
    path: &Path,
    primary_error: String,
    candidates: Vec<RecoveryCandidate>,
    read_candidate: ReadCandidate,
) -> Result<SettingsReadOutcome, String>
where
    ReadCandidate: FnMut(&RecoveryCandidate, &mut RecoveryReadBudget) -> RecoveryCandidateRead,
{
    recover_from_candidates_with_controls(path, primary_error, candidates, |_| {}, read_candidate)
}

fn recover_from_candidates_with_controls<BeforeCandidateOpen, ReadCandidate>(
    path: &Path,
    primary_error: String,
    candidates: Vec<RecoveryCandidate>,
    mut before_candidate_open: BeforeCandidateOpen,
    mut read_candidate: ReadCandidate,
) -> Result<SettingsReadOutcome, String>
where
    BeforeCandidateOpen: FnMut(&Path),
    ReadCandidate: FnMut(&RecoveryCandidate, &mut RecoveryReadBudget) -> RecoveryCandidateRead,
{
    validate_recovery_inventory(&candidates)?;
    let candidates = eligible_recovery_candidates(path, candidates)?;
    let mut checked = 0usize;
    let mut candidate_diagnostics = Vec::new();
    let mut omitted_diagnostics = 0;
    let mut read_budget = RecoveryReadBudget {
        remaining_bytes: RECOVERY_TOTAL_BYTES_LIMIT,
    };

    for candidate in candidates {
        checked += 1;
        before_candidate_open(&candidate.path);
        let candidate_result = match &candidate.precheck {
            Some(RecoveryCandidatePrecheck::ConclusivelyInvalid(error)) => {
                RecoveryCandidateRead::ConclusivelyInvalid(error.clone())
            }
            Some(RecoveryCandidatePrecheck::Transient(error)) => {
                RecoveryCandidateRead::Transient(error.clone())
            }
            None => read_candidate(&candidate, &mut read_budget),
        };
        match candidate_result {
            RecoveryCandidateRead::Valid(settings) => {
                let write_diagnostic =
                    install_recovered_settings_at(path, &settings, &candidate.path).map_err(
                        |error| {
                            format!(
                                "{primary_error}；恢复候选有效但安装失败：{}（{}）",
                                candidate.path.display(),
                                error
                            )
                        },
                    )?;
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
            RecoveryCandidateRead::ConclusivelyInvalid(error) => {
                let cleanup = discard_recovery_candidate(&candidate.path);
                record_recovery_diagnostic(
                    &mut candidate_diagnostics,
                    &mut omitted_diagnostics,
                    || {
                        format!(
                            "{}（确定无效：{}{}）",
                            candidate.path.display(),
                            error,
                            cleanup_diagnostic(cleanup),
                        )
                    },
                );
            }
            RecoveryCandidateRead::Transient(error) => record_recovery_diagnostic(
                &mut candidate_diagnostics,
                &mut omitted_diagnostics,
                || {
                    format!(
                        "{}（{}{}）",
                        candidate.path.display(),
                        error,
                        "；瞬态候选已保留",
                    )
                },
            ),
            RecoveryCandidateRead::TotalLimitExceeded(error) => {
                return Err(format!("{primary_error}；恢复失败：{error}"));
            }
        }
    }

    let bounded = if omitted_diagnostics > 0 {
        format!("；仅展示前 {RECOVERY_DIAGNOSTIC_LIMIT} 个诊断，省略 {omitted_diagnostics} 个")
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

fn record_recovery_diagnostic(
    diagnostics: &mut Vec<String>,
    omitted: &mut usize,
    detail: impl FnOnce() -> String,
) {
    if diagnostics.len() < RECOVERY_DIAGNOSTIC_LIMIT {
        diagnostics.push(detail());
    } else {
        *omitted += 1;
    }
}

fn validate_recovery_inventory(candidates: &[RecoveryCandidate]) -> Result<(), String> {
    if candidates.len() > RECOVERY_TOTAL_CANDIDATE_LIMIT {
        return Err(format!(
            "恢复候选数量超过上限：{} > {}",
            candidates.len(),
            RECOVERY_TOTAL_CANDIDATE_LIMIT
        ));
    }
    let total_bytes = candidates
        .iter()
        .try_fold(0u64, |total, candidate| total.checked_add(candidate.size));
    let Some(total_bytes) = total_bytes else {
        return Err("恢复候选累计大小溢出".into());
    };
    if total_bytes > RECOVERY_TOTAL_BYTES_LIMIT {
        return Err(format!(
            "恢复候选累计大小超过上限：{total_bytes} > {RECOVERY_TOTAL_BYTES_LIMIT} bytes"
        ));
    }
    Ok(())
}

fn eligible_recovery_candidates(
    path: &Path,
    candidates: Vec<RecoveryCandidate>,
) -> Result<Vec<RecoveryCandidate>, String> {
    eligible_recovery_candidates_for_marker(read_commit_marker(path)?, candidates)
}

fn eligible_recovery_candidates_for_marker(
    marker: Option<SettingsCommitMarker>,
    candidates: Vec<RecoveryCandidate>,
) -> Result<Vec<RecoveryCandidate>, String> {
    match marker {
        None => {
            if candidates
                .iter()
                .any(|candidate| candidate.protocol == RecoveryCandidateProtocol::TransactionalV4)
            {
                return Err(
                    "发现没有耐久待提交标记的 v4 恢复候选；为避免未确认发布或回滚已停止恢复".into(),
                );
            }
            Ok(candidates)
        }
        Some(SettingsCommitMarker::Pending {
            generation,
            candidate_name,
        }) => {
            let candidate = candidates.into_iter().find(|candidate| {
                candidate.protocol == RecoveryCandidateProtocol::TransactionalV4
                    && candidate.freshness == generation
                    && candidate.path.file_name().and_then(|name| name.to_str())
                        == Some(candidate_name.as_str())
            });
            candidate.map(|candidate| vec![candidate]).ok_or_else(|| {
                format!(
                    "待提交设置恢复候选缺失或身份不匹配：{candidate_name}（代次 {generation}）；为避免回滚已停止恢复"
                )
            })
        }
        Some(SettingsCommitMarker::Committed { generation }) => Err(format!(
            "设置恢复候选已被后续提交代次 {generation} 取代；主设置损坏时禁止回滚旧候选"
        )),
    }
}

fn interrupted_temp_candidates(path: &Path) -> Result<Vec<RecoveryCandidate>, String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("设置文件缺少父目录：{}", path.display()))?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("设置文件名不是有效 UTF-8：{}", path.display()))?;
    let legacy_prefix = format!("{file_name}.tmp-ready-v3-");
    let transactional_prefix = format!("{file_name}.tmp-ready-v4-");
    let mut candidates = Vec::new();
    let mut total_bytes = 0u64;
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
    let mut scanned_entries = 0usize;
    for entry in entries {
        scanned_entries += 1;
        if scanned_entries > RECOVERY_DIRECTORY_ENTRY_LIMIT {
            return Err(format!(
                "设置恢复目录项扫描数量超过上限：至少 {scanned_entries} 个，上限 {RECOVERY_DIRECTORY_ENTRY_LIMIT} 个；为避免未绑定元数据 I/O 已停止"
            ));
        }
        let entry = entry.map_err(|error| {
            format!(
                "枚举设置恢复候选失败：{}（{}）；为避免部分恢复已停止",
                parent.display(),
                error
            )
        })?;
        let candidate = entry.path();
        let Some(candidate_name) = candidate.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        let (protocol, ready_prefix) = if candidate_name.starts_with(&transactional_prefix) {
            (
                RecoveryCandidateProtocol::TransactionalV4,
                &transactional_prefix,
            )
        } else if candidate_name.starts_with(&legacy_prefix) {
            (RecoveryCandidateProtocol::LegacyV3, &legacy_prefix)
        } else {
            continue;
        };
        if candidates.len() >= RECOVERY_TOTAL_CANDIDATE_LIMIT {
            return Err(format!(
                "恢复候选数量超过上限：至少 {} 个，上限 {} 个；为避免任意子集恢复已停止",
                candidates.len() + 1,
                RECOVERY_TOTAL_CANDIDATE_LIMIT
            ));
        }
        let metadata = match std::fs::symlink_metadata(&candidate) {
            Ok(metadata) => metadata,
            Err(error) => {
                candidates.push(RecoveryCandidate {
                    path: candidate,
                    freshness: 0,
                    protocol,
                    size: 0,
                    precheck: Some(RecoveryCandidatePrecheck::Transient(format!(
                        "读取非跟随元数据出现瞬态失败：{error}"
                    ))),
                });
                continue;
            }
        };
        let file_type = metadata.file_type();
        let size = if file_type.is_file() {
            metadata.len()
        } else {
            0
        };
        total_bytes = total_bytes
            .checked_add(size)
            .ok_or_else(|| "恢复候选累计大小溢出".to_string())?;
        if total_bytes > RECOVERY_TOTAL_BYTES_LIMIT {
            return Err(format!(
                "恢复候选累计大小超过上限：{total_bytes} > {RECOVERY_TOTAL_BYTES_LIMIT} bytes；为避免部分恢复已停止"
            ));
        }
        let parsed_freshness = ready_candidate_freshness(candidate_name, ready_prefix);
        let precheck = if file_type.is_symlink() {
            Some(RecoveryCandidatePrecheck::ConclusivelyInvalid(
                "恢复候选是符号链接".into(),
            ))
        } else if !file_type.is_file() {
            Some(RecoveryCandidatePrecheck::ConclusivelyInvalid(
                "恢复候选是非普通文件".into(),
            ))
        } else if metadata_is_reparse_point(&metadata) {
            Some(RecoveryCandidatePrecheck::ConclusivelyInvalid(
                "恢复候选是 Windows reparse point".into(),
            ))
        } else if parsed_freshness.is_none() {
            Some(RecoveryCandidatePrecheck::ConclusivelyInvalid(
                "恢复候选名称格式无效".into(),
            ))
        } else if metadata.len() > RECOVERY_CANDIDATE_MAX_BYTES {
            Some(RecoveryCandidatePrecheck::ConclusivelyInvalid(format!(
                "恢复候选超过大小上限：{} > {} bytes",
                metadata.len(),
                RECOVERY_CANDIDATE_MAX_BYTES
            )))
        } else {
            None
        };
        let freshness = parsed_freshness
            .or_else(|| metadata.modified().ok().map(system_time_key))
            .unwrap_or_default();
        candidates.push(RecoveryCandidate {
            path: candidate,
            freshness,
            protocol,
            size,
            precheck,
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

fn ready_candidate_freshness(file_name: &str, prefix: &str) -> Option<u128> {
    let mut parts = file_name.strip_prefix(prefix)?.split('-');
    let freshness = parts.next()?.parse().ok()?;
    parts.next()?.parse::<u32>().ok()?;
    parts.next()?.parse::<u64>().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Some(freshness)
}

fn system_time_key(value: SystemTime) -> u128 {
    value
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

fn read_recovery_candidate(
    candidate: &RecoveryCandidate,
    budget: &mut RecoveryReadBudget,
) -> RecoveryCandidateRead {
    let mut options = OpenOptions::new();
    options.read(true);
    configure_recovery_open_no_follow(&mut options);
    let mut file = match options.open(&candidate.path) {
        Ok(file) => file,
        Err(error) => {
            return RecoveryCandidateRead::Transient(format!(
                "安全打开恢复候选出现瞬态失败：{error}"
            ));
        }
    };
    let metadata = match file.metadata() {
        Ok(metadata) => metadata,
        Err(error) => {
            return RecoveryCandidateRead::Transient(format!(
                "读取已打开候选元数据出现瞬态失败：{error}"
            ));
        }
    };
    if !metadata.file_type().is_file() {
        return RecoveryCandidateRead::ConclusivelyInvalid("已打开恢复候选是非普通文件".into());
    }
    if metadata_is_reparse_point(&metadata) {
        return RecoveryCandidateRead::ConclusivelyInvalid(
            "已打开恢复候选是 Windows reparse point".into(),
        );
    }
    if metadata.len() > budget.remaining_bytes {
        return RecoveryCandidateRead::TotalLimitExceeded(format!(
            "恢复累计读取超过上限：候选 {} 需要 {} bytes，仅剩 {} bytes",
            candidate.path.display(),
            metadata.len(),
            budget.remaining_bytes
        ));
    }
    if metadata.len() > RECOVERY_CANDIDATE_MAX_BYTES {
        return RecoveryCandidateRead::ConclusivelyInvalid(format!(
            "已打开恢复候选超过大小上限：{} > {} bytes",
            metadata.len(),
            RECOVERY_CANDIDATE_MAX_BYTES
        ));
    }

    let available_before_read = budget.remaining_bytes;
    let mut bytes = Vec::new();
    let read_limit = RECOVERY_CANDIDATE_MAX_BYTES.min(available_before_read);
    let read_result = (&mut file).take(read_limit).read_to_end(&mut bytes);
    if bytes.len() as u64 > RECOVERY_CANDIDATE_MAX_BYTES {
        return RecoveryCandidateRead::ConclusivelyInvalid(format!(
            "读取恢复候选超过大小上限：{} > {} bytes",
            bytes.len(),
            RECOVERY_CANDIDATE_MAX_BYTES
        ));
    }
    if bytes.len() as u64 > budget.remaining_bytes {
        return RecoveryCandidateRead::TotalLimitExceeded(format!(
            "恢复累计读取超过上限：候选 {} 实际读取 {} bytes，仅剩 {} bytes",
            candidate.path.display(),
            bytes.len(),
            budget.remaining_bytes
        ));
    }
    budget.remaining_bytes -= bytes.len() as u64;
    if let Err(error) = read_result {
        return RecoveryCandidateRead::Transient(format!(
            "读取恢复候选出现瞬态失败：{error}；已读取 {} bytes 计入累计上限",
            bytes.len()
        ));
    }
    let post_read_size = match file.metadata() {
        Ok(metadata) => metadata.len(),
        Err(error) => {
            return RecoveryCandidateRead::Transient(format!(
                "读取候选后重新检查大小出现瞬态失败：{error}；已读取 {} bytes 计入累计上限",
                bytes.len()
            ));
        }
    };
    if post_read_size > available_before_read {
        return RecoveryCandidateRead::TotalLimitExceeded(format!(
            "恢复累计读取超过上限：候选 {} 当前大小 {} bytes，读取前仅剩 {} bytes",
            candidate.path.display(),
            post_read_size,
            available_before_read
        ));
    }
    if post_read_size > RECOVERY_CANDIDATE_MAX_BYTES {
        return RecoveryCandidateRead::ConclusivelyInvalid(format!(
            "读取后恢复候选超过大小上限：{post_read_size} > {RECOVERY_CANDIDATE_MAX_BYTES} bytes"
        ));
    }
    match parse_settings(&candidate.path, &bytes) {
        Ok(settings) => RecoveryCandidateRead::Valid(settings),
        Err(error) => RecoveryCandidateRead::ConclusivelyInvalid(error),
    }
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

fn validate_primary_opened_path_identity<IsReparse>(
    path: &Path,
    opened_file: &File,
    is_reparse: &IsReparse,
    phase: &str,
) -> Result<(), String>
where
    IsReparse: Fn(&std::fs::Metadata) -> bool,
{
    let path_metadata = std::fs::symlink_metadata(path).map_err(|error| {
        format!(
            "主设置身份在{phase}无法重新验证：{}（{}）",
            path.display(),
            error
        )
    })?;
    if is_reparse(&path_metadata)
        || !path_metadata.file_type().is_file()
        || path_metadata.file_type().is_symlink()
    {
        return Err(format!(
            "主设置身份在{phase}发生变化或变为非安全普通文件：{}",
            path.display()
        ));
    }
    if path_metadata.len() > RECOVERY_CANDIDATE_MAX_BYTES {
        return Err(format!(
            "主设置在{phase}超过大小上限：{} > {} bytes（{}）",
            path_metadata.len(),
            RECOVERY_CANDIDATE_MAX_BYTES,
            path.display()
        ));
    }
    let opened_metadata = opened_file.metadata().map_err(|error| {
        format!(
            "主设置身份在{phase}无法重新读取已打开文件元数据：{}（{}）",
            path.display(),
            error
        )
    })?;
    if !primary_metadata_identity_matches(&opened_metadata, &path_metadata) {
        return Err(format!("主设置身份在{phase}发生变化：{}", path.display()));
    }
    validate_windows_primary_handle_identity(path, opened_file, is_reparse, phase)
}

#[cfg(unix)]
fn primary_metadata_identity_matches(left: &std::fs::Metadata, right: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;

    left.dev() == right.dev() && left.ino() == right.ino()
}

#[cfg(windows)]
fn primary_metadata_identity_matches(left: &std::fs::Metadata, right: &std::fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;

    left.creation_time() == right.creation_time()
        && left.last_write_time() == right.last_write_time()
        && left.file_size() == right.file_size()
        && left.file_attributes() == right.file_attributes()
}

#[cfg(not(any(unix, windows)))]
fn primary_metadata_identity_matches(
    _left: &std::fs::Metadata,
    _right: &std::fs::Metadata,
) -> bool {
    true
}

#[cfg(windows)]
fn validate_windows_primary_handle_identity<IsReparse>(
    path: &Path,
    opened_file: &File,
    is_reparse: &IsReparse,
    phase: &str,
) -> Result<(), String>
where
    IsReparse: Fn(&std::fs::Metadata) -> bool,
{
    let mut options = OpenOptions::new();
    options.read(true);
    configure_recovery_open_no_follow(&mut options);
    let current_file = options.open(path).map_err(|error| {
        format!(
            "主设置身份在{phase}无法通过非跟随句柄重新验证：{}（{}）",
            path.display(),
            error
        )
    })?;
    let current_metadata = current_file.metadata().map_err(|error| {
        format!(
            "主设置身份在{phase}无法读取当前路径句柄元数据：{}（{}）",
            path.display(),
            error
        )
    })?;
    if is_reparse(&current_metadata) || !current_metadata.file_type().is_file() {
        return Err(format!(
            "主设置身份在{phase}变为 Windows reparse point 或非普通文件：{}",
            path.display()
        ));
    }
    let opened_identity = windows_file_identity(opened_file)?;
    let current_identity = windows_file_identity(&current_file)?;
    if opened_identity != current_identity {
        return Err(format!("主设置身份在{phase}发生变化：{}", path.display()));
    }
    Ok(())
}

#[cfg(not(windows))]
fn validate_windows_primary_handle_identity<IsReparse>(
    _path: &Path,
    _opened_file: &File,
    _is_reparse: &IsReparse,
    _phase: &str,
) -> Result<(), String>
where
    IsReparse: Fn(&std::fs::Metadata) -> bool,
{
    Ok(())
}

#[cfg(windows)]
fn windows_file_identity(file: &File) -> Result<(u32, u64), String> {
    use std::{ffi::c_void, mem::MaybeUninit, os::windows::io::AsRawHandle};

    #[repr(C)]
    struct FileTime {
        low_date_time: u32,
        high_date_time: u32,
    }

    #[repr(C)]
    struct ByHandleFileInformation {
        file_attributes: u32,
        creation_time: FileTime,
        last_access_time: FileTime,
        last_write_time: FileTime,
        volume_serial_number: u32,
        file_size_high: u32,
        file_size_low: u32,
        number_of_links: u32,
        file_index_high: u32,
        file_index_low: u32,
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn GetFileInformationByHandle(
            file: *mut c_void,
            information: *mut ByHandleFileInformation,
        ) -> i32;
    }

    let mut information = MaybeUninit::<ByHandleFileInformation>::uninit();
    let result = unsafe {
        GetFileInformationByHandle(file.as_raw_handle().cast(), information.as_mut_ptr())
    };
    if result == 0 {
        return Err(format!(
            "读取 Windows 主设置文件身份失败：{}",
            std::io::Error::last_os_error()
        ));
    }
    let information = unsafe { information.assume_init() };
    let file_index =
        (u64::from(information.file_index_high) << 32) | u64::from(information.file_index_low);
    Ok((information.volume_serial_number, file_index))
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

fn attach_prior_diagnostic(error: String, prior: &Option<String>) -> String {
    match prior {
        Some(prior) => format!("{error}；{prior}"),
        None => error,
    }
}

fn merge_diagnostics(first: Option<String>, second: Option<String>) -> Option<String> {
    match (first, second) {
        (Some(first), Some(second)) => Some(format!("{first}；{second}")),
        (Some(diagnostic), None) | (None, Some(diagnostic)) => Some(diagnostic),
        (None, None) => None,
    }
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

#[cfg(any(test, windows))]
fn sync_windows_parent_directory_with_controls<Directory, OpenDirectory, FlushDirectory>(
    parent: &Path,
    open_directory: OpenDirectory,
    flush_directory: FlushDirectory,
) -> Result<(), String>
where
    OpenDirectory: FnOnce(&Path) -> std::io::Result<Directory>,
    FlushDirectory: FnOnce(&Directory) -> std::io::Result<()>,
{
    let directory = open_directory(parent)
        .map_err(|error| format!("打开设置目录失败：{}（{}）", parent.display(), error))?;
    flush_directory(&directory)
        .map_err(|error| format!("同步设置目录失败：{}（{}）", parent.display(), error))
}

#[cfg(windows)]
fn sync_parent_directory(parent: &Path) -> Result<(), String> {
    sync_windows_parent_directory_with_controls(
        parent,
        open_windows_directory_for_sync,
        flush_windows_directory,
    )
}

#[cfg(windows)]
fn open_windows_directory_for_sync(parent: &Path) -> std::io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;

    const FILE_SHARE_READ: u32 = 0x0000_0001;
    const FILE_SHARE_WRITE: u32 = 0x0000_0002;
    const FILE_SHARE_DELETE: u32 = 0x0000_0004;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;

    let mut options = OpenOptions::new();
    options
        .read(true)
        .write(true)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS);
    options.open(parent)
}

#[cfg(windows)]
fn flush_windows_directory(directory: &File) -> std::io::Result<()> {
    use std::{ffi::c_void, os::windows::io::AsRawHandle};

    #[link(name = "kernel32")]
    extern "system" {
        fn FlushFileBuffers(file: *mut c_void) -> i32;
    }

    // SAFETY: The raw handle remains owned by `directory` and valid for the duration of the call.
    let flushed = unsafe { FlushFileBuffers(directory.as_raw_handle().cast()) };
    if flushed == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(not(any(unix, windows)))]
fn sync_parent_directory(parent: &Path) -> Result<(), String> {
    Err(format!(
        "当前平台无法确认设置目录持久性，拒绝继续保存：{}",
        parent.display()
    ))
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
    settings.display_surfaces = sanitize_display_surfaces(settings.display_surfaces);
    settings.session_enhancements =
        sanitize_session_enhancement_settings(settings.session_enhancements);
    settings.auto_resume = sanitize_auto_resume_settings(settings.auto_resume);
    settings
}

fn sanitize_display_surfaces(
    mut settings: DisplaySurfaceSettingsSnapshot,
) -> DisplaySurfaceSettingsSnapshot {
    let supported = crate::models::STATUS_METRIC_IDS
        .into_iter()
        .collect::<std::collections::HashSet<_>>();
    let mut seen = std::collections::HashSet::new();
    settings
        .status_metric_order
        .retain(|metric| supported.contains(metric.as_str()) && seen.insert(metric.clone()));

    if !matches!(
        settings.status_metric_label_style.as_str(),
        "full" | "compact" | "hidden"
    ) {
        settings.status_metric_label_style = crate::models::default_status_metric_label_style();
    }

    let supported_sections = crate::models::STATUS_SUMMARY_SECTION_IDS
        .into_iter()
        .collect::<std::collections::HashSet<_>>();
    let mut seen_sections = std::collections::HashSet::new();
    settings.status_summary_order.retain(|section| {
        supported_sections.contains(section.as_str()) && seen_sections.insert(section.clone())
    });
    settings
}

fn sanitize_session_enhancement_settings(
    mut settings: crate::models::SessionEnhancementSettingsSnapshot,
) -> crate::models::SessionEnhancementSettingsSnapshot {
    // The legacy Codex-sidebar delete action bypassed the session manager's
    // mandatory recovery package, closure revalidation, and shared operation
    // lock. Keep the field only for backward-compatible settings decoding,
    // but never publish or persist it as enabled.
    settings.session_delete = false;
    settings.conversation_view_max_width = settings.conversation_view_max_width.clamp(320, 4_000);
    settings
}

fn sanitize_auto_resume_settings(
    mut settings: AutoResumeSettingsSnapshot,
) -> AutoResumeSettingsSnapshot {
    sanitize_auto_resume_legacy_fields(&mut settings);
    if settings.task_collection_version < AUTO_RESUME_TASK_COLLECTION_VERSION
        && settings.tasks.is_empty()
        && !settings.thread_id.is_empty()
    {
        settings.tasks = settings.resolved_tasks();
    }
    let mut seen_ids = std::collections::HashSet::new();
    let mut seen_threads = std::collections::HashSet::new();
    settings.tasks = settings
        .tasks
        .into_iter()
        .filter_map(|task| {
            let mut legacy = task.as_legacy_settings();
            sanitize_auto_resume_legacy_fields(&mut legacy);
            if legacy.thread_id.is_empty() {
                return None;
            }
            let id = {
                let trimmed = task.id.trim();
                if trimmed.is_empty() {
                    stable_auto_resume_task_id(&legacy.thread_id)
                } else {
                    trimmed.chars().take(128).collect()
                }
            };
            if !seen_ids.insert(id.clone()) || !seen_threads.insert(legacy.thread_id.clone()) {
                return None;
            }
            Some(crate::models::AutoResumeTaskSettingsSnapshot {
                id,
                created_at: task.created_at.max(0),
                updated_at: task.updated_at.max(task.created_at).max(0),
                enabled: legacy.enabled,
                thread_id: legacy.thread_id,
                thread_title: legacy.thread_title,
                thread_cwd: legacy.thread_cwd,
                prompt: legacy.prompt,
                invisible_resume_enabled: legacy.invisible_resume_enabled,
                auto_approval_enabled: legacy.auto_approval_enabled,
                schedule_mode: legacy.schedule_mode,
                interval_minutes: legacy.interval_minutes,
                daily_hour: legacy.daily_hour,
                daily_minute: legacy.daily_minute,
                failure_recovery_policy_version: legacy.failure_recovery_policy_version,
                failure_recovery_reasons: legacy.failure_recovery_reasons,
                capacity_recovery_enabled: legacy.capacity_recovery_enabled,
                quota_resume_enabled: legacy.quota_resume_enabled,
                quota_window: legacy.quota_window,
                quota_low_threshold_percent: legacy.quota_low_threshold_percent,
                quota_recovery_threshold_percent: legacy.quota_recovery_threshold_percent,
                cooldown_minutes: legacy.cooldown_minutes,
                max_runs_per_day: legacy.max_runs_per_day,
                notify_on_result: legacy.notify_on_result,
            })
        })
        .collect();
    settings.selected_task_id = settings.selected_task_id.trim().chars().take(128).collect();
    if !settings.tasks.is_empty() {
        if !settings
            .tasks
            .iter()
            .any(|task| task.id == settings.selected_task_id)
        {
            settings.selected_task_id = settings.tasks[0].id.clone();
        }
        let selected = settings
            .tasks
            .iter()
            .find(|task| task.id == settings.selected_task_id)
            .unwrap_or(&settings.tasks[0])
            .as_legacy_settings();
        let tasks = std::mem::take(&mut settings.tasks);
        let selected_task_id = settings.selected_task_id.clone();
        settings = selected;
        settings.task_collection_version = AUTO_RESUME_TASK_COLLECTION_VERSION;
        settings.selected_task_id = selected_task_id;
        settings.tasks = tasks;
    } else {
        settings.task_collection_version = AUTO_RESUME_TASK_COLLECTION_VERSION;
        settings.selected_task_id.clear();
        settings.enabled = false;
        settings.thread_id.clear();
        settings.thread_title.clear();
        settings.thread_cwd.clear();
    }
    settings
}

fn sanitize_auto_resume_legacy_fields(settings: &mut AutoResumeSettingsSnapshot) {
    // Exact post-turn conditions: all CodexErrorInfo variants whose
    // affects_turn_status() value is true, except UsageLimitExceeded (handled
    // by quota recovery), plus the terminal TurnStatus::Interrupted.
    const FAILURE_REASONS: [&str; 14] = [
        "serverOverloaded",
        "httpConnectionFailed",
        "responseStreamConnectionFailed",
        "responseStreamDisconnected",
        "responseTooManyFailedAttempts",
        "internalServerError",
        "interrupted",
        "contextWindowExceeded",
        "sessionBudgetExceeded",
        "unauthorized",
        "badRequest",
        "sandboxError",
        "cyberPolicy",
        "other",
    ];
    settings.thread_id = settings.thread_id.trim().chars().take(128).collect();
    settings.thread_title = settings.thread_title.trim().chars().take(240).collect();
    settings.thread_cwd = settings.thread_cwd.trim().chars().take(2_048).collect();
    settings.prompt = settings.prompt.trim().chars().take(8_000).collect();
    if settings.prompt.is_empty() {
        settings.prompt = "继续".into();
    }
    settings.invisible_resume_enabled = Some(
        settings
            .invisible_resume_enabled
            .unwrap_or(settings.prompt == "继续"),
    );
    settings.schedule_mode = match settings.schedule_mode.as_str() {
        "interval" => "interval",
        "daily" => "daily",
        _ => "off",
    }
    .into();
    settings.interval_minutes = match settings.interval_minutes {
        15 | 30 | 60 | 120 | 360 | 720 => settings.interval_minutes,
        _ => 60,
    };
    settings.daily_hour = settings.daily_hour.min(23);
    settings.daily_minute = settings.daily_minute.min(59);
    let requested_reasons = if settings.failure_recovery_policy_version == 0 {
        if settings.capacity_recovery_enabled {
            vec!["serverOverloaded".to_string()]
        } else {
            Vec::new()
        }
    } else if settings.failure_recovery_policy_version == 1 {
        let mut migrated = Vec::new();
        for reason in &settings.failure_recovery_reasons {
            match reason.as_str() {
                "capacity" => migrated.push("serverOverloaded".to_string()),
                "serverError" => migrated.push("internalServerError".to_string()),
                "retryLimit" => {
                    migrated.push("responseTooManyFailedAttempts".to_string());
                }
                "contextWindow" => migrated.push("contextWindowExceeded".to_string()),
                "sessionBudget" => migrated.push("sessionBudgetExceeded".to_string()),
                "requestConflict" => migrated.push("badRequest".to_string()),
                "authentication" => migrated.push("unauthorized".to_string()),
                "sandbox" => migrated.push("sandboxError".to_string()),
                "interrupted" => migrated.push("interrupted".to_string()),
                "other" => migrated.push("other".to_string()),
                exact if FAILURE_REASONS.contains(&exact) => migrated.push(exact.to_string()),
                // These former buckets partitioned the same connection
                // variants using HTTP status/message guesses. No equally
                // narrow CodexErrorInfo exists, so do not broaden them.
                "network" | "rateLimit" | "timeout" | _ => {}
            }
        }
        migrated
    } else {
        settings.failure_recovery_reasons.clone()
    };
    settings.failure_recovery_reasons = FAILURE_REASONS
        .iter()
        .filter(|reason| requested_reasons.iter().any(|value| value == **reason))
        .map(|reason| (*reason).to_string())
        .collect();
    settings.failure_recovery_policy_version = 2;
    settings.capacity_recovery_enabled = !settings.failure_recovery_reasons.is_empty();
    settings.quota_window = match settings.quota_window.as_str() {
        "fiveHour" => "fiveHour",
        "sevenDay" => "sevenDay",
        _ => "either",
    }
    .into();
    settings.quota_low_threshold_percent = settings.quota_low_threshold_percent.min(20);
    settings.quota_recovery_threshold_percent = settings
        .quota_recovery_threshold_percent
        .clamp(settings.quota_low_threshold_percent.saturating_add(1), 100);
    settings.cooldown_minutes = settings.cooldown_minutes.clamp(1, 24 * 60);
    settings.max_runs_per_day = settings.max_runs_per_day.clamp(1, 24);
    if settings.thread_id.is_empty() {
        settings.enabled = false;
    }
    if settings.enabled
        && settings.schedule_mode == "off"
        && !settings.capacity_recovery_enabled
        && !settings.quota_resume_enabled
    {
        settings.enabled = false;
    }
}

fn stable_auto_resume_task_id(thread_id: &str) -> String {
    let mut hash = 14_695_981_039_346_656_037_u64;
    for byte in thread_id.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(1_099_511_628_211);
    }
    format!("task-{hash:016x}")
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
        quota_color_mode: sanitize_floating_quota_color_mode(&settings.quota_color_mode).into(),
        quota_fixed_color: sanitize_hex_color(&settings.quota_fixed_color, "#1469cc").into(),
        text_tone: clamp_f64(settings.text_tone, -1.0, 1.0, -1.0),
        paging_guide_revision: settings.paging_guide_revision,
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
        show_running_threads: visibility.show_running_threads,
        show_today_model_share: visibility.show_today_model_share,
        show_today_model_cost: visibility.show_today_model_cost,
        show_quota: visibility.show_quota,
        show_radar: visibility.show_radar,
        show_crowd_radar: visibility.show_crowd_radar,
        show_page_navigation_arrows: visibility.show_page_navigation_arrows,
        order: sanitize_floating_content_order(visibility.order),
        page_pairs: sanitize_floating_page_pairs(visibility.page_pairs),
    }
}

fn sanitize_floating_content_order(order: Vec<String>) -> Vec<String> {
    let defaults = [
        "rateAndBar",
        "usageStatus",
        "metrics",
        "runningThreads",
        "todayModelShare",
        "todayModelCost",
        "radar",
        "crowdRadar",
        "quota",
    ];
    let mut next: Vec<String> = Vec::new();
    for item in order {
        if defaults.contains(&item.as_str()) && !next.iter().any(|existing| existing == &item) {
            next.push(item);
        }
    }
    for item in defaults {
        if !next.iter().any(|existing| existing == item) {
            if item == "runningThreads" {
                if let Some(metrics_index) = next.iter().position(|existing| existing == "metrics")
                {
                    next.insert(metrics_index + 1, item.into());
                    continue;
                }
            }
            if item == "todayModelShare" {
                if let Some(running_index) = next
                    .iter()
                    .position(|existing| existing == "runningThreads")
                {
                    next.insert(running_index + 1, item.into());
                    continue;
                }
            }
            if item == "todayModelCost" {
                if let Some(share_index) = next
                    .iter()
                    .position(|existing| existing == "todayModelShare")
                {
                    next.insert(share_index + 1, item.into());
                    continue;
                }
            }
            if item == "crowdRadar" {
                if let Some(radar_index) = next.iter().position(|existing| existing == "radar") {
                    next.insert(radar_index + 1, item.into());
                    continue;
                }
            }
            next.push(item.into());
        }
    }
    next
}

fn sanitize_floating_page_pairs(pairs: Vec<Vec<String>>) -> Vec<Vec<String>> {
    let allowed = [
        "metrics",
        "runningThreads",
        "todayModelShare",
        "todayModelCost",
        "radar",
        "crowdRadar",
        "quota",
    ];
    let mut used: Vec<String> = Vec::new();
    let mut next: Vec<Vec<String>> = Vec::new();
    for pair in pairs {
        if pair.len() != 2
            || pair[0] == pair[1]
            || !allowed.contains(&pair[0].as_str())
            || !allowed.contains(&pair[1].as_str())
            || used.iter().any(|item| item == &pair[0] || item == &pair[1])
        {
            continue;
        }
        used.push(pair[0].clone());
        used.push(pair[1].clone());
        next.push(pair);
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

fn sanitize_floating_quota_color_mode(value: &str) -> &'static str {
    match value {
        "adaptive" => "adaptive",
        "fixed" => "fixed",
        "panelGradient" => "panelGradient",
        _ => "adaptive",
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
        cell::Cell,
        fs::FileTimes,
        sync::{mpsc, TryLockError},
        thread,
        time::{Duration, SystemTime, UNIX_EPOCH},
    };

    #[test]
    fn session_enhancement_settings_keep_safe_defaults_and_clamp_width() {
        let defaults: AppSettingsSnapshot = serde_json::from_str("{}").unwrap();
        assert!(!defaults.session_enhancements.session_delete);
        assert!(defaults.session_enhancements.markdown_export);
        assert!(defaults.session_enhancements.project_move);
        assert!(defaults.session_enhancements.thread_scroll_restore);

        let sanitized = sanitize_session_enhancement_settings(
            crate::models::SessionEnhancementSettingsSnapshot {
                session_delete: true,
                paste_fix: true,
                conversation_view_max_width: 99_999,
                ..crate::models::SessionEnhancementSettingsSnapshot::default()
            },
        );
        assert!(
            !sanitized.session_delete,
            "persisted legacy opt-ins must migrate to fail-closed"
        );
        assert!(sanitized.paste_fix);
        assert_eq!(sanitized.conversation_view_max_width, 4_000);
    }

    #[test]
    fn auto_resume_settings_fail_closed_without_target_and_clamp_guards() {
        let sanitized = sanitize_auto_resume_settings(AutoResumeSettingsSnapshot {
            enabled: true,
            thread_id: "   ".into(),
            prompt: "  ".into(),
            schedule_mode: "every-second".into(),
            interval_minutes: 1,
            daily_hour: 99,
            daily_minute: 99,
            quota_window: "unknown".into(),
            quota_low_threshold_percent: 99,
            quota_recovery_threshold_percent: 1,
            cooldown_minutes: 0,
            max_runs_per_day: 99,
            ..AutoResumeSettingsSnapshot::default()
        });
        assert!(!sanitized.enabled);
        assert_eq!(sanitized.prompt, "继续");
        assert_eq!(sanitized.schedule_mode, "off");
        assert_eq!(sanitized.interval_minutes, 60);
        assert_eq!(sanitized.daily_hour, 23);
        assert_eq!(sanitized.daily_minute, 59);
        assert_eq!(sanitized.quota_window, "either");
        assert_eq!(sanitized.quota_low_threshold_percent, 20);
        assert_eq!(sanitized.quota_recovery_threshold_percent, 21);
        assert_eq!(sanitized.cooldown_minutes, 1);
        assert_eq!(sanitized.max_runs_per_day, 24);
    }

    #[test]
    fn auto_resume_invisible_mode_migrates_legacy_prompt_without_overriding_explicit_choice() {
        let legacy_custom = sanitize_auto_resume_settings(AutoResumeSettingsSnapshot {
            prompt: "按原计划继续".into(),
            invisible_resume_enabled: None,
            ..AutoResumeSettingsSnapshot::default()
        });
        assert_eq!(legacy_custom.invisible_resume_enabled, Some(false));

        let explicit_invisible = sanitize_auto_resume_settings(AutoResumeSettingsSnapshot {
            prompt: "按原计划继续".into(),
            invisible_resume_enabled: Some(true),
            ..AutoResumeSettingsSnapshot::default()
        });
        assert_eq!(explicit_invisible.invisible_resume_enabled, Some(true));
        assert_eq!(explicit_invisible.prompt, "按原计划继续");

        let explicit_visible_continue = sanitize_auto_resume_settings(AutoResumeSettingsSnapshot {
            prompt: "继续".into(),
            invisible_resume_enabled: Some(false),
            ..AutoResumeSettingsSnapshot::default()
        });
        assert_eq!(
            explicit_visible_continue.invisible_resume_enabled,
            Some(false)
        );
    }

    #[test]
    fn auto_resume_task_collection_migrates_legacy_and_deduplicates_fail_closed() {
        let legacy = sanitize_auto_resume_settings(AutoResumeSettingsSnapshot {
            enabled: true,
            thread_id: " legacy-thread ".into(),
            thread_title: " Legacy ".into(),
            auto_approval_enabled: true,
            ..AutoResumeSettingsSnapshot::default()
        });
        let migrated = legacy.resolved_tasks();
        assert_eq!(migrated.len(), 1);
        assert!(migrated[0].id.starts_with("legacy-"));
        assert_eq!(migrated[0].thread_id, "legacy-thread");
        assert!(migrated[0].auto_approval_enabled);
        assert_eq!(
            legacy.task_collection_version,
            AUTO_RESUME_TASK_COLLECTION_VERSION
        );
        assert_eq!(legacy.tasks.len(), 1);

        let task_a = crate::models::AutoResumeTaskSettingsSnapshot {
            id: "task-a".into(),
            enabled: true,
            thread_id: "thread-a".into(),
            auto_approval_enabled: true,
            quota_resume_enabled: false,
            capacity_recovery_enabled: false,
            schedule_mode: "off".into(),
            ..crate::models::AutoResumeTaskSettingsSnapshot::default()
        };
        let duplicate_thread = crate::models::AutoResumeTaskSettingsSnapshot {
            id: "duplicate".into(),
            thread_id: "thread-a".into(),
            ..crate::models::AutoResumeTaskSettingsSnapshot::default()
        };
        let task_b = crate::models::AutoResumeTaskSettingsSnapshot {
            id: "task-b".into(),
            enabled: true,
            thread_id: "thread-b".into(),
            ..crate::models::AutoResumeTaskSettingsSnapshot::default()
        };
        let sanitized = sanitize_auto_resume_settings(AutoResumeSettingsSnapshot {
            selected_task_id: "missing".into(),
            tasks: vec![task_a, duplicate_thread, task_b],
            ..AutoResumeSettingsSnapshot::default()
        });
        assert_eq!(sanitized.tasks.len(), 2);
        assert_eq!(sanitized.selected_task_id, "task-a");
        assert!(!sanitized.tasks[0].enabled);
        assert!(sanitized.tasks[0].auto_approval_enabled);
        assert!(sanitized.tasks[1].enabled);
        assert_eq!(sanitized.thread_id, "thread-a");

        let deleted = sanitize_auto_resume_settings(AutoResumeSettingsSnapshot {
            task_collection_version: AUTO_RESUME_TASK_COLLECTION_VERSION,
            enabled: true,
            thread_id: "stale-deleted-thread".into(),
            thread_title: "stale title".into(),
            tasks: Vec::new(),
            ..AutoResumeSettingsSnapshot::default()
        });
        assert_eq!(
            deleted.task_collection_version,
            AUTO_RESUME_TASK_COLLECTION_VERSION
        );
        assert!(deleted.tasks.is_empty());
        assert!(deleted.resolved_tasks().is_empty());
        assert!(deleted.thread_id.is_empty());
        assert!(!deleted.enabled);
    }

    #[test]
    fn auto_resume_failure_policy_migrates_capacity_and_preserves_explicit_empty() {
        let migrated = sanitize_auto_resume_settings(AutoResumeSettingsSnapshot {
            enabled: true,
            thread_id: "legacy-capacity".into(),
            capacity_recovery_enabled: true,
            quota_resume_enabled: false,
            ..AutoResumeSettingsSnapshot::default()
        });
        assert_eq!(migrated.failure_recovery_policy_version, 2);
        assert_eq!(migrated.failure_recovery_reasons, ["serverOverloaded"]);
        assert!(migrated.capacity_recovery_enabled);

        let explicit_empty = sanitize_auto_resume_settings(AutoResumeSettingsSnapshot {
            enabled: true,
            thread_id: "new-policy".into(),
            failure_recovery_policy_version: 1,
            failure_recovery_reasons: Vec::new(),
            capacity_recovery_enabled: true,
            quota_resume_enabled: false,
            ..AutoResumeSettingsSnapshot::default()
        });
        assert!(explicit_empty.failure_recovery_reasons.is_empty());
        assert!(!explicit_empty.capacity_recovery_enabled);
        assert!(!explicit_empty.enabled);

        let canonical = sanitize_auto_resume_settings(AutoResumeSettingsSnapshot {
            enabled: true,
            thread_id: "canonical".into(),
            failure_recovery_policy_version: 1,
            failure_recovery_reasons: vec![
                "interrupted".into(),
                "network".into(),
                "network".into(),
                "rateLimit".into(),
                "serverError".into(),
                "unknown".into(),
            ],
            quota_resume_enabled: false,
            ..AutoResumeSettingsSnapshot::default()
        });
        assert_eq!(
            canonical.failure_recovery_reasons,
            ["internalServerError", "interrupted"]
        );
        assert!(canonical.capacity_recovery_enabled);
    }

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
                "quotaColorMode": "rainbow",
                "quotaFixedColor": "navy",
                "textTone": 4,
                "contentVisibility": {
                    "showRadar": false,
                    "showPageNavigationArrows": false,
                    "order": ["quota", "quota", "unknown", "rateAndBar"]
                }
            },
            "displaySurfaces": {
                "statusMetricOrder": ["iq", "iq", "unknown", "rate"],
                "statusMetricLabelStyle": "wide",
                "statusSummaryOrder": ["radar", "radar", "unknown", "quota"]
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
        assert_eq!(sanitized.floating_window.quota_color_mode, "adaptive");
        assert_eq!(sanitized.floating_window.quota_fixed_color, "#1469cc");
        assert_eq!(sanitized.floating_window.text_tone, 1.0);
        assert!(!sanitized.floating_window.content_visibility.show_radar);
        assert!(!FloatingContentVisibilitySnapshot::default().show_page_navigation_arrows);
        assert_eq!(sanitized.floating_window.paging_guide_revision, 0);
        assert!(
            sanitized
                .floating_window
                .content_visibility
                .show_crowd_radar
        );
        assert!(
            sanitized
                .floating_window
                .content_visibility
                .show_running_threads
        );
        assert!(
            sanitized
                .floating_window
                .content_visibility
                .show_today_model_share
        );
        assert!(
            sanitized
                .floating_window
                .content_visibility
                .show_today_model_cost
        );
        assert!(!sanitized.floating_window.content_visibility.show_page_navigation_arrows);
        assert_eq!(
            sanitized.floating_window.content_visibility.order,
            [
                "quota",
                "rateAndBar",
                "usageStatus",
                "metrics",
                "runningThreads",
                "todayModelShare",
                "todayModelCost",
                "radar",
                "crowdRadar",
            ]
        );
        assert_eq!(
            sanitized.floating_window.content_visibility.page_pairs,
            [vec![
                "todayModelShare".to_string(),
                "todayModelCost".to_string()
            ]]
        );
        assert!(sanitized.display_surfaces.floating_window_enabled);
        assert!(sanitized.display_surfaces.live_rate_enabled);
        assert!(sanitized.display_surfaces.status_tray_live_text_enabled);
        assert_eq!(
            sanitized.display_surfaces.status_metric_order,
            ["iq", "rate"]
        );
        assert_eq!(
            sanitized.display_surfaces.status_metric_label_style,
            "compact"
        );
        assert_eq!(
            sanitized.display_surfaces.status_summary_order,
            ["radar", "quota"]
        );
        assert!(!sanitized.setup_guide_completed);
    }

    #[test]
    fn paging_guide_completion_updates_only_revision_and_arrow_preference() {
        let mut settings = AppSettingsSnapshot::default();
        settings.floating_window.opacity = 0.73;
        settings.floating_window.scale = 1.21;
        settings.floating_window.paging_guide_revision = 0;
        settings
            .floating_window
            .content_visibility
            .show_page_navigation_arrows = false;

        apply_floating_paging_guide_completion(&mut settings, true);

        assert_eq!(settings.floating_window.paging_guide_revision, 2);
        assert!(settings.floating_window.content_visibility.show_page_navigation_arrows);
        assert_eq!(settings.floating_window.opacity, 0.73);
        assert_eq!(settings.floating_window.scale, 1.21);

        settings.floating_window.paging_guide_revision = 4;
        apply_floating_paging_guide_completion(&mut settings, false);
        assert_eq!(settings.floating_window.paging_guide_revision, 4);
        assert!(!settings.floating_window.content_visibility.show_page_navigation_arrows);
    }

    #[test]
    fn display_surfaces_preserve_an_explicit_empty_status_metric_order() {
        let sanitized = sanitize_app_settings(AppSettingsSnapshot {
            display_surfaces: DisplaySurfaceSettingsSnapshot {
                status_metric_order: Vec::new(),
                status_summary_order: Vec::new(),
                ..DisplaySurfaceSettingsSnapshot::default()
            },
            ..AppSettingsSnapshot::default()
        });

        assert!(sanitized.display_surfaces.status_metric_order.is_empty());
        assert!(sanitized.display_surfaces.status_summary_order.is_empty());
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
                "quotaColorMode": "fixed",
                "quotaFixedColor": "#ABCDEF",
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
        assert_eq!(settings.floating_window.quota_color_mode, "fixed");
        assert_eq!(settings.floating_window.quota_fixed_color, "#ABCDEF");
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
        let root = TestSettingsRoot::new("missing");
        let path = root.settings_path();
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
        let root = TestSettingsRoot::new("corrupt");
        let path = root.settings_path();
        std::fs::write(&path, b"{not-json").unwrap();

        let error = read_app_settings_at(&path).unwrap_err();

        assert!(error.contains("设置文件不是有效 JSON"));
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
    fn competing_mutation_reads_first_commit_only_after_transaction_lock_handoff() {
        let root = TestSettingsRoot::new("concurrent-mutations");
        let path = root.settings_path();
        write_fixture(&path, &AppSettingsSnapshot::default());
        let (first_read_tx, first_read_rx) = mpsc::channel();
        let (release_first_tx, release_first_rx) = mpsc::channel();
        let (second_attempt_tx, second_attempt_rx) = mpsc::channel();
        let (second_read_tx, second_read_rx) = mpsc::channel();

        let first_path = path.clone();
        let first_writer = thread::spawn(move || {
            mutate_app_settings_at_with_transaction_hooks(
                &first_path,
                || {},
                |settings| {
                    assert!(settings.custom_account_display_name.is_empty());
                    first_read_tx.send(()).unwrap();
                    release_first_rx.recv().unwrap();
                },
                |_, _| {},
                sync_parent_directory,
                |settings| {
                    settings.custom_account_display_name = "first-committed".into();
                },
            )
            .unwrap()
        });
        first_read_rx.recv().unwrap();

        let second_path = path.clone();
        let second_writer = thread::spawn(move || {
            mutate_app_settings_at_with_transaction_hooks(
                &second_path,
                || {
                    second_attempt_tx.send(()).unwrap();
                    assert!(matches!(
                        settings_lock().try_lock(),
                        Err(TryLockError::WouldBlock)
                    ));
                },
                |settings| {
                    second_read_tx
                        .send(settings.custom_account_display_name.clone())
                        .unwrap();
                },
                |_, _| {},
                sync_parent_directory,
                |settings| {
                    settings.display_surfaces = DisplaySurfaceSettingsSnapshot {
                        floating_window_enabled: false,
                        live_rate_enabled: true,
                        status_tray_live_text_enabled: false,
                        status_metric_order: vec!["unread".into(), "rate".into()],
                        status_metric_label_style: "hidden".into(),
                        status_summary_order: vec!["radar".into(), "overview".into()],
                    };
                },
            )
            .unwrap()
        });

        second_attempt_rx.recv().unwrap();
        release_first_tx.send(()).unwrap();
        first_writer.join().unwrap();
        assert_eq!(second_read_rx.recv().unwrap(), "first-committed");
        second_writer.join().unwrap();

        let saved = read_app_settings_at(&path).unwrap();
        assert_eq!(saved.custom_account_display_name, "first-committed");
        assert!(!saved.display_surfaces.floating_window_enabled);
        assert!(saved.display_surfaces.live_rate_enabled);
        assert!(!saved.display_surfaces.status_tray_live_text_enabled);
        assert_eq!(
            saved.display_surfaces.status_metric_order,
            ["unread", "rate"]
        );
        assert_eq!(saved.display_surfaces.status_metric_label_style, "hidden");
        assert_eq!(
            saved.display_surfaces.status_summary_order,
            ["radar", "overview"]
        );
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
                |_| {},
                |ready_path, _| {
                    let ready_name = ready_path.file_name().unwrap().to_string_lossy();
                    assert!(ready_name.starts_with("settings.json.tmp-ready-v4-"));
                    assert!(!std::fs::read_dir(ready_path.parent().unwrap())
                        .unwrap()
                        .flatten()
                        .any(|entry| entry
                            .file_name()
                            .to_string_lossy()
                            .starts_with("settings.json.tmp-in-progress-v3-")));
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
        let sync_calls = Cell::new(0usize);

        let outcome = mutate_app_settings_at_with_hooks(
            &path,
            |_| {},
            |_, _| {},
            |parent| {
                let call = sync_calls.get() + 1;
                sync_calls.set(call);
                if call == 3 {
                    Err("injected directory sync failure".into())
                } else {
                    sync_parent_directory(parent)
                }
            },
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
    fn windows_directory_sync_control_propagates_flush_failure() {
        let root = TestSettingsRoot::new("windows-sync-control-failure");
        let open_called = Cell::new(false);
        let flush_called = Cell::new(false);

        let error = sync_windows_parent_directory_with_controls(
            &root.path,
            |_| {
                open_called.set(true);
                Ok(())
            },
            |_| {
                flush_called.set(true);
                Err(std::io::Error::other("injected FlushFileBuffers failure"))
            },
        )
        .unwrap_err();

        assert!(open_called.get());
        assert!(flush_called.get());
        assert!(error.contains("同步设置目录失败"));
        assert!(error.contains("injected FlushFileBuffers failure"));
        assert!(error.contains(&root.path.display().to_string()));
    }

    #[cfg(windows)]
    #[test]
    fn windows_parent_directory_sync_flushes_real_directory_handle() {
        let root = TestSettingsRoot::new("windows-real-directory-sync");

        sync_parent_directory(&root.path).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn windows_parent_directory_sync_rejects_missing_directory() {
        let root = TestSettingsRoot::new("windows-missing-directory-sync");
        let missing = root.path.join("missing");

        let error = sync_parent_directory(&missing).unwrap_err();

        assert!(error.contains("打开设置目录失败"));
        assert!(error.contains(&missing.display().to_string()));
    }

    #[test]
    fn successful_commit_supersedes_ready_left_by_prior_replace_failure() {
        let root = TestSettingsRoot::new("superseded-ready");
        let path = root.settings_path();
        write_fixture(&path, &AppSettingsSnapshot::default());
        let stale_ready = leave_ready_candidate_after_replace_failure(&path, "stale-a");
        assert!(stale_ready.exists());

        let committed = mutate_app_settings_at(&path, |settings| {
            settings.custom_account_display_name = "committed-b".into();
        })
        .unwrap();
        assert_eq!(committed.custom_account_display_name, "committed-b");
        std::fs::write(&path, b"{corrupt-after-b").unwrap();

        let error = read_app_settings_at_with_diagnostics(&path).unwrap_err();

        assert!(error.contains("后续提交") || error.contains("已提交"));
        assert_eq!(std::fs::read(&path).unwrap(), b"{corrupt-after-b");
    }

    #[test]
    fn successful_commit_supersedes_stale_ready_even_when_obsolete_cleanup_fails() {
        let root = TestSettingsRoot::new("superseded-ready-cleanup-failure");
        let path = root.settings_path();
        write_fixture(&path, &AppSettingsSnapshot::default());
        let stale_ready = leave_ready_candidate_after_replace_failure(&path, "stale-a");
        assert!(stale_ready.exists());

        let outcome = mutate_app_settings_at_with_cleanup_hook(
            &path,
            |candidate| {
                if candidate == stale_ready {
                    Err("injected obsolete cleanup failure".into())
                } else {
                    discard_recovery_candidate(candidate)
                }
            },
            |settings| settings.custom_account_display_name = "committed-b".into(),
        )
        .unwrap();

        assert_eq!(outcome.settings.custom_account_display_name, "committed-b");
        assert!(outcome
            .diagnostic
            .as_deref()
            .unwrap()
            .contains("injected obsolete cleanup failure"));
        assert!(stale_ready.exists());
        std::fs::write(&path, b"{corrupt-after-b").unwrap();

        let error = read_app_settings_at_with_diagnostics(&path).unwrap_err();

        assert!(error.contains("后续提交") || error.contains("已提交"));
        assert!(stale_ready.exists());
        assert_eq!(std::fs::read(&path).unwrap(), b"{corrupt-after-b");
    }

    #[test]
    fn sixteen_failed_replacements_are_pruned_before_a_healthy_save() {
        let root = TestSettingsRoot::new("sixteen-failed-replacements");
        let path = root.settings_path();
        write_fixture(&path, &AppSettingsSnapshot::default());
        let candidates = accumulate_ready_candidates_after_replace_failures(
            &path,
            RECOVERY_TOTAL_CANDIDATE_LIMIT,
        );
        assert_eq!(candidates.len(), RECOVERY_TOTAL_CANDIDATE_LIMIT);

        let pending_path = pending_candidate_path(&path);
        assert!(pending_path.exists());
        let in_progress = in_progress_temp_path(&path, 999, 7, 1);
        let mut active_file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&in_progress)
            .unwrap();
        active_file.write_all(b"active-write").unwrap();
        let sync_calls = Cell::new(0usize);

        let saved = mutate_app_settings_at_with_hooks(
            &path,
            |_| {},
            |_, _| {},
            |parent| {
                sync_calls.set(sync_calls.get() + 1);
                sync_parent_directory(parent)
            },
            |settings| settings.custom_account_display_name = "healthy-save".into(),
        )
        .unwrap()
        .settings;

        assert_eq!(saved.custom_account_display_name, "healthy-save");
        assert_eq!(
            sync_calls.get(),
            5,
            "capacity cleanup plus ready, pending, primary, and committed must each sync"
        );
        assert_eq!(
            read_app_settings_at(&path)
                .unwrap()
                .custom_account_display_name,
            "healthy-save"
        );
        assert!(interrupted_temp_candidates(&path).unwrap().is_empty());
        assert!(in_progress.exists());
        active_file.write_all(b"-continues").unwrap();
        assert_eq!(
            std::fs::read(&in_progress).unwrap(),
            b"active-write-continues"
        );
        assert!(matches!(
            read_commit_marker(&path).unwrap(),
            Some(SettingsCommitMarker::Committed { .. })
        ));
    }

    #[test]
    fn newer_durable_ready_without_pending_marker_is_preserved_and_blocks_capacity_cleanup() {
        let root = TestSettingsRoot::new("newer-cross-process-ready");
        let path = root.settings_path();
        write_fixture(&path, &AppSettingsSnapshot::default());
        accumulate_ready_candidates_after_replace_failures(
            &path,
            RECOVERY_TOTAL_CANDIDATE_LIMIT - 1,
        );
        let marker_before = read_commit_marker(&path).unwrap().unwrap();
        let SettingsCommitMarker::Pending { generation, .. } = marker_before.clone() else {
            panic!("expected pending commit marker");
        };
        let newer_generation = generation.checked_add(1).unwrap();
        let foreign_pid = std::process::id().wrapping_add(1);
        let newer_ready =
            transactional_ready_temp_path(&path, newer_generation, foreign_pid, u64::MAX - 1);
        write_durable_ready_fixture(
            &newer_ready,
            &AppSettingsSnapshot {
                custom_account_display_name: "other-process-ready".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        assert_eq!(
            interrupted_temp_candidates(&path).unwrap().len(),
            RECOVERY_TOTAL_CANDIDATE_LIMIT
        );
        let replacement_reached = Cell::new(false);

        let error = mutate_app_settings_at_with_hooks(
            &path,
            |_| {},
            |_, _| replacement_reached.set(true),
            sync_parent_directory,
            |settings| settings.custom_account_display_name = "must-not-save".into(),
        )
        .unwrap_err();

        assert!(error.contains("未被当前提交标记证明已过时"));
        assert!(!replacement_reached.get());
        assert!(newer_ready.exists());
        assert_eq!(read_commit_marker(&path).unwrap(), Some(marker_before));
        assert!(read_app_settings_at(&path)
            .unwrap()
            .custom_account_display_name
            .is_empty());
    }

    #[test]
    fn committed_marker_preserves_newer_unknown_ready_and_blocks_capacity_cleanup() {
        let root = TestSettingsRoot::new("newer-ready-after-committed");
        let path = root.settings_path();
        write_fixture(&path, &AppSettingsSnapshot::default());
        let committed_generation = 100u128;
        write_commit_marker(
            &path,
            &SettingsCommitMarker::Committed {
                generation: committed_generation,
            },
            &mut sync_parent_directory,
        )
        .unwrap();
        for generation in 1..RECOVERY_TOTAL_CANDIDATE_LIMIT as u128 {
            let candidate = ready_settings_temp_path(&path, generation, generation as u64).unwrap();
            write_durable_ready_fixture(&candidate, &AppSettingsSnapshot::default());
        }
        let newer_ready =
            ready_settings_temp_path(&path, committed_generation + 1, u64::MAX - 2).unwrap();
        write_durable_ready_fixture(
            &newer_ready,
            &AppSettingsSnapshot {
                custom_account_display_name: "newer-than-committed".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        assert_eq!(
            interrupted_temp_candidates(&path).unwrap().len(),
            RECOVERY_TOTAL_CANDIDATE_LIMIT
        );

        let error = mutate_app_settings_at(&path, |settings| {
            settings.custom_account_display_name = "must-not-save".into();
        })
        .unwrap_err();

        assert!(error.contains("未被当前提交标记证明已过时"));
        assert!(newer_ready.exists());
        assert!(matches!(
            read_commit_marker(&path).unwrap(),
            Some(SettingsCommitMarker::Committed { generation: 100 })
        ));
    }

    #[test]
    fn marker_generation_does_not_supersede_identity_uncertain_candidate() {
        let root = TestSettingsRoot::new("identity-uncertain-ready");
        let path = root.settings_path();
        let candidate = RecoveryCandidate {
            path: ready_settings_temp_path(&path, 10, 1).unwrap(),
            freshness: 0,
            protocol: RecoveryCandidateProtocol::TransactionalV4,
            size: 0,
            precheck: Some(RecoveryCandidatePrecheck::Transient(
                "injected metadata uncertainty".into(),
            )),
        };

        let error = provably_superseded_ready_candidates(
            &path,
            &[candidate],
            &SettingsCommitMarker::Committed { generation: 100 },
            None,
        )
        .unwrap_err();

        assert!(error.contains("身份无法确认"));
    }

    #[test]
    fn undeletable_superseded_candidates_fail_closed_with_bounded_diagnostics() {
        let root = TestSettingsRoot::new("undeletable-superseded-capacity");
        let path = root.settings_path();
        write_fixture(&path, &AppSettingsSnapshot::default());
        let candidates = accumulate_ready_candidates_after_replace_failures(
            &path,
            RECOVERY_TOTAL_CANDIDATE_LIMIT,
        );
        let pending_path = pending_candidate_path(&path);
        let superseded: Vec<PathBuf> = candidates
            .into_iter()
            .filter(|candidate| candidate != &pending_path)
            .collect();
        assert_eq!(superseded.len(), RECOVERY_TOTAL_CANDIDATE_LIMIT - 1);
        for candidate in &superseded {
            std::fs::remove_file(candidate).unwrap();
            std::fs::create_dir(candidate).unwrap();
            std::fs::write(candidate.join("keep"), b"undeletable").unwrap();
        }
        let in_progress = in_progress_temp_path(&path, 1_000, 7, 2);
        std::fs::write(&in_progress, b"active").unwrap();
        let sync_calls = Cell::new(0usize);
        let replacement_reached = Cell::new(false);

        let error = mutate_app_settings_at_with_hooks(
            &path,
            |_| {},
            |_, _| replacement_reached.set(true),
            |parent| {
                sync_calls.set(sync_calls.get() + 1);
                sync_parent_directory(parent)
            },
            |settings| settings.custom_account_display_name = "must-not-save".into(),
        )
        .unwrap_err();

        assert!(error.contains("容量清理不确定"));
        assert!(error.contains(&pending_path.display().to_string()));
        assert!(error.contains("另省略 7 项"));
        assert!(error.len() < 8_192, "diagnostic must remain bounded");
        assert!(pending_path.exists());
        assert!(superseded.iter().all(|candidate| candidate.exists()));
        assert!(in_progress.exists());
        assert_eq!(sync_calls.get(), 1);
        assert!(!replacement_reached.get());
        assert!(read_app_settings_at(&path)
            .unwrap()
            .custom_account_display_name
            .is_empty());
    }

    #[test]
    fn ready_directory_sync_failure_stops_before_primary_replacement_and_reports_ready_path() {
        let root = TestSettingsRoot::new("ready-sync-failure");
        let path = root.settings_path();
        write_fixture(&path, &AppSettingsSnapshot::default());
        let replacement_reached = Cell::new(false);

        let result = mutate_app_settings_at_with_hooks(
            &path,
            |_| {},
            |_, _| replacement_reached.set(true),
            |_| Err("injected ready directory sync failure".into()),
            |settings| settings.custom_account_display_name = "must-not-commit".into(),
        );
        let error = result.unwrap_err();

        assert!(!replacement_reached.get());
        assert!(error.contains("tmp-ready-v4-"));
        assert!(error.contains("injected ready directory sync failure"));
        assert!(read_app_settings_at(&path)
            .unwrap()
            .custom_account_display_name
            .is_empty());
    }

    #[test]
    fn valid_primary_quarantines_malformed_commit_marker_and_continues_saving() {
        let root = TestSettingsRoot::new("repair-malformed-marker");
        let path = root.settings_path();
        write_fixture(&path, &AppSettingsSnapshot::default());
        let marker_path = commit_marker_path(&path).unwrap();
        std::fs::write(&marker_path, b"not-a-marker").unwrap();
        let sync_calls = Cell::new(0usize);

        let outcome = mutate_app_settings_at_with_hooks(
            &path,
            |_| {},
            |_, _| {},
            |parent| {
                sync_calls.set(sync_calls.get() + 1);
                sync_parent_directory(parent)
            },
            |settings| settings.custom_account_display_name = "saved-after-repair".into(),
        )
        .unwrap();

        let quarantines = commit_marker_quarantines(&path);
        assert_eq!(quarantines.len(), 1);
        assert_eq!(std::fs::read(&quarantines[0]).unwrap(), b"not-a-marker");
        assert_eq!(sync_calls.get(), 6);
        assert_eq!(
            outcome.settings.custom_account_display_name,
            "saved-after-repair"
        );
        assert!(outcome
            .diagnostic
            .as_deref()
            .unwrap()
            .contains(&quarantines[0].display().to_string()));
        assert!(matches!(
            read_commit_marker(&path).unwrap(),
            Some(SettingsCommitMarker::Committed { .. })
        ));
    }

    #[test]
    fn valid_primary_quarantines_oversized_commit_marker_and_continues_saving() {
        let root = TestSettingsRoot::new("repair-oversized-marker");
        let path = root.settings_path();
        write_fixture(&path, &AppSettingsSnapshot::default());
        let marker_path = commit_marker_path(&path).unwrap();
        File::create(&marker_path)
            .unwrap()
            .set_len(COMMIT_MARKER_MAX_BYTES + 1)
            .unwrap();

        let saved = mutate_app_settings_at(&path, |settings| {
            settings.custom_account_display_name = "saved-after-oversized".into();
        })
        .unwrap();

        assert_eq!(saved.custom_account_display_name, "saved-after-oversized");
        let quarantines = commit_marker_quarantines(&path);
        assert_eq!(quarantines.len(), 1);
        assert_eq!(
            std::fs::metadata(&quarantines[0]).unwrap().len(),
            COMMIT_MARKER_MAX_BYTES + 1
        );
        assert!(matches!(
            read_commit_marker(&path).unwrap(),
            Some(SettingsCommitMarker::Committed { .. })
        ));
    }

    #[cfg(unix)]
    #[test]
    fn valid_primary_quarantines_symlink_commit_marker_without_touching_target() {
        use std::os::unix::fs::symlink;

        let root = TestSettingsRoot::new("repair-symlink-marker");
        let path = root.settings_path();
        write_fixture(&path, &AppSettingsSnapshot::default());
        let marker_path = commit_marker_path(&path).unwrap();
        let target = root.path.join("marker-target");
        std::fs::write(&target, b"target-must-stay").unwrap();
        symlink(&target, &marker_path).unwrap();

        let saved = mutate_app_settings_at(&path, |settings| {
            settings.custom_account_display_name = "saved-after-symlink".into();
        })
        .unwrap();

        assert_eq!(saved.custom_account_display_name, "saved-after-symlink");
        assert_eq!(std::fs::read(&target).unwrap(), b"target-must-stay");
        let quarantines = commit_marker_quarantines(&path);
        assert_eq!(quarantines.len(), 1);
        assert!(std::fs::symlink_metadata(&quarantines[0])
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(matches!(
            read_commit_marker(&path).unwrap(),
            Some(SettingsCommitMarker::Committed { .. })
        ));
    }

    #[test]
    fn bad_commit_marker_quarantine_sync_failure_stops_before_primary_replacement() {
        let root = TestSettingsRoot::new("marker-quarantine-sync-failure");
        let path = root.settings_path();
        write_fixture(
            &path,
            &AppSettingsSnapshot {
                custom_account_display_name: "authoritative-primary".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        let marker_path = commit_marker_path(&path).unwrap();
        std::fs::write(&marker_path, b"not-a-marker").unwrap();
        let replacement_reached = Cell::new(false);

        let error = mutate_app_settings_at_with_hooks(
            &path,
            |_| {},
            |_, _| replacement_reached.set(true),
            |_| Err("injected marker quarantine sync failure".into()),
            |settings| settings.custom_account_display_name = "must-not-save".into(),
        )
        .unwrap_err();

        let quarantines = commit_marker_quarantines(&path);
        assert_eq!(quarantines.len(), 1);
        assert!(!replacement_reached.get());
        assert!(error.contains(&quarantines[0].display().to_string()));
        assert!(error.contains("injected marker quarantine sync failure"));
        assert_eq!(
            read_app_settings_at(&path)
                .unwrap()
                .custom_account_display_name,
            "authoritative-primary"
        );
    }

    #[test]
    fn bad_commit_marker_stays_fail_closed_when_primary_is_missing_or_invalid() {
        for (label, primary) in [
            ("missing-primary", None),
            ("invalid-primary", Some(b"{invalid-primary".as_slice())),
        ] {
            let root = TestSettingsRoot::new(label);
            let path = root.settings_path();
            if let Some(primary) = primary {
                std::fs::write(&path, primary).unwrap();
            }
            let marker_path = commit_marker_path(&path).unwrap();
            std::fs::write(&marker_path, b"not-a-marker").unwrap();

            let error = mutate_app_settings_at(&path, |settings| {
                settings.custom_account_display_name = "must-not-save".into();
            })
            .unwrap_err();

            assert!(error.contains("设置提交标记"));
            assert_eq!(std::fs::read(&marker_path).unwrap(), b"not-a-marker");
            assert!(commit_marker_quarantines(&path).is_empty());
            if primary.is_none() {
                assert!(!path.exists());
            } else {
                assert_eq!(std::fs::read(&path).unwrap(), b"{invalid-primary");
            }
        }
    }

    #[test]
    fn valid_primary_ignores_an_in_progress_partial_file() {
        let root = TestSettingsRoot::new("interrupted-temp");
        let path = root.settings_path();
        let settings = AppSettingsSnapshot {
            custom_account_display_name: "primary".into(),
            ..AppSettingsSnapshot::default()
        };
        write_fixture(&path, &settings);
        std::fs::write(in_progress_temp_path(&path, 1, 1, 1), b"{partial").unwrap();

        let outcome = read_app_settings_at_with_diagnostics(&path).unwrap();

        assert_eq!(outcome.settings.custom_account_display_name, "primary");
        assert!(outcome.diagnostic.is_none());
    }

    #[cfg(unix)]
    #[test]
    fn primary_symlink_is_never_authoritative_or_followed() {
        use std::os::unix::fs::symlink;

        let root = TestSettingsRoot::new("primary-symlink");
        let path = root.settings_path();
        let target = root.path.join("symlink-target.json");
        write_fixture(
            &target,
            &AppSettingsSnapshot {
                custom_account_display_name: "must-not-follow".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        let target_before = std::fs::read(&target).unwrap();
        symlink(&target, &path).unwrap();

        let error = read_app_settings_at_with_diagnostics(&path).unwrap_err();

        assert!(error.contains("主设置不是安全普通文件"));
        assert_eq!(std::fs::read(&target).unwrap(), target_before);
        assert!(std::fs::symlink_metadata(&path)
            .unwrap()
            .file_type()
            .is_symlink());
    }

    #[test]
    fn non_regular_primary_enters_fail_closed_recovery() {
        let root = TestSettingsRoot::new("primary-non-regular");
        let path = root.settings_path();
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("keep"), b"untouched").unwrap();

        let error = read_app_settings_at_with_diagnostics(&path).unwrap_err();

        assert!(error.contains("主设置不是安全普通文件"));
        assert_eq!(std::fs::read(path.join("keep")).unwrap(), b"untouched");
    }

    #[test]
    fn oversized_primary_is_never_accepted_as_authoritative() {
        let root = TestSettingsRoot::new("primary-oversized");
        let path = root.settings_path();
        let settings = AppSettingsSnapshot {
            custom_account_display_name: "valid-prefix-must-not-win".into(),
            ..AppSettingsSnapshot::default()
        };
        let mut oversized = serde_json::to_vec_pretty(&settings).unwrap();
        oversized.resize(RECOVERY_CANDIDATE_MAX_BYTES as usize + 1, b' ');
        std::fs::write(&path, oversized).unwrap();

        let error = read_app_settings_at_with_diagnostics(&path).unwrap_err();

        assert!(error.contains("主设置大小超过上限"));
    }

    #[test]
    fn reparse_classified_primary_is_rejected() {
        let root = TestSettingsRoot::new("primary-reparse-classified");
        let path = root.settings_path();
        write_fixture(&path, &AppSettingsSnapshot::default());

        let error = read_primary_settings_at_for_test(&path, || {}, |_| true).unwrap_err();

        assert!(error.contains("reparse"));
    }

    #[cfg(unix)]
    #[test]
    fn primary_identity_swap_after_open_is_rejected() {
        let root = TestSettingsRoot::new("primary-identity-swap");
        let path = root.settings_path();
        write_fixture(
            &path,
            &AppSettingsSnapshot {
                custom_account_display_name: "opened-primary".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        let replacement = root.path.join("replacement.json");
        write_fixture(
            &replacement,
            &AppSettingsSnapshot {
                custom_account_display_name: "replacement-primary".into(),
                ..AppSettingsSnapshot::default()
            },
        );

        let error = read_primary_settings_at_for_test(
            &path,
            || replace_settings_file(&replacement, &path).unwrap(),
            |_| false,
        )
        .unwrap_err();

        assert!(error.contains("身份在读取期间发生变化"));
        assert_eq!(
            serde_json::from_slice::<AppSettingsSnapshot>(&std::fs::read(&path).unwrap())
                .unwrap()
                .custom_account_display_name,
            "replacement-primary"
        );
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
        write_fixture(&ready_temp_path(&path, 9999, 1, 1), &recovered);

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
        let stale_path = ready_temp_path(&path, 10, 99_999, 1);
        let fresh_path = ready_temp_path(&path, 20, 1, 1);
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
        let candidate = ready_temp_path(&path, 20, 99_999, 1);
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
    fn reparse_classified_ready_candidate_fails_closed_and_does_not_hide_valid_candidate() {
        let root = TestSettingsRoot::new("reparse-classified-ready");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        let reparse = ready_temp_path(&path, 200, 2, 1);
        write_fixture(
            &reparse,
            &AppSettingsSnapshot {
                custom_account_display_name: "must-not-install".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        let valid = ready_temp_path(&path, 100, 1, 1);
        write_fixture(
            &valid,
            &AppSettingsSnapshot {
                custom_account_display_name: "after-reparse".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        let mut candidates = interrupted_temp_candidates(&path).unwrap();
        let classified = candidates
            .iter_mut()
            .find(|candidate| candidate.path == reparse)
            .unwrap();
        classified.precheck = Some(RecoveryCandidatePrecheck::ConclusivelyInvalid(
            "恢复候选是 Windows reparse point".into(),
        ));

        let recovered =
            recover_from_candidates(&path, "corrupt primary".into(), candidates).unwrap();

        assert_eq!(
            recovered.settings.custom_account_display_name,
            "after-reparse"
        );
        assert!(!reparse.exists());
    }

    #[test]
    fn recovery_rejects_and_removes_non_regular_candidate() {
        let root = TestSettingsRoot::new("directory-candidate");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        let candidate = ready_temp_path(&path, 20, 99_999, 1);
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
        let candidate = ready_temp_path(&path, 20, 99_999, 1);
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
    fn within_total_limits_newer_failures_do_not_hide_older_valid_candidate() {
        let root = TestSettingsRoot::new("ready-progress-within-limit");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        let valid = ready_temp_path(&path, 100, 1, 1);
        write_fixture(
            &valid,
            &AppSettingsSnapshot {
                custom_account_display_name: "older-valid".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        let mut undeletable = Vec::new();
        for index in 0..8 {
            let candidate = ready_temp_path(&path, 300 + index, 9, index as u64);
            std::fs::create_dir(&candidate).unwrap();
            std::fs::write(candidate.join("keep"), b"prevents remove_dir").unwrap();
            undeletable.push(candidate);
        }
        let mut transient = Vec::new();
        for index in 0..7 {
            let candidate = ready_temp_path(&path, 200 + index, 7, index as u64);
            write_fixture(&candidate, &AppSettingsSnapshot::default());
            transient.push(candidate);
        }

        let recovered = recover_from_candidates_with_reader(
            &path,
            "corrupt primary".into(),
            interrupted_temp_candidates(&path).unwrap(),
            |candidate, budget| {
                if transient.contains(&candidate.path) {
                    RecoveryCandidateRead::Transient("injected share failure".into())
                } else {
                    read_recovery_candidate(candidate, budget)
                }
            },
        )
        .unwrap();

        assert_eq!(
            recovered.settings.custom_account_display_name,
            "older-valid"
        );
        assert!(undeletable.iter().all(|candidate| candidate.exists()));
        assert!(transient.iter().all(|candidate| !candidate.exists()));
    }

    #[test]
    fn recovery_never_scans_or_touches_active_in_progress_file() {
        let root = TestSettingsRoot::new("active-in-progress");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        let in_progress = in_progress_temp_path(&path, 300, 7, 1);
        let mut active_writer = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&in_progress)
            .unwrap();
        active_writer.write_all(b"{partial").unwrap();
        active_writer.flush().unwrap();
        active_writer
            .set_times(FileTimes::new().set_modified(UNIX_EPOCH + Duration::from_secs(300)))
            .unwrap();
        let valid = ready_temp_path(&path, 100, 1, 1);
        write_fixture(
            &valid,
            &AppSettingsSnapshot {
                custom_account_display_name: "ready-only".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        set_modified_time(&valid, UNIX_EPOCH + Duration::from_secs(100));

        let candidates = interrupted_temp_candidates(&path).unwrap();
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].path, valid);
        let mut opened = Vec::new();
        let recovered = recover_from_candidates_with_hook(
            &path,
            "corrupt primary".into(),
            candidates,
            |candidate| opened.push(candidate.to_path_buf()),
        )
        .unwrap();

        active_writer.write_all(b"-still-owned").unwrap();
        active_writer.flush().unwrap();
        assert!(in_progress.exists());
        assert_eq!(
            std::fs::read(&in_progress).unwrap(),
            b"{partial-still-owned"
        );
        assert!(!opened.contains(&in_progress));
        assert_eq!(recovered.settings.custom_account_display_name, "ready-only");
    }

    #[test]
    fn newer_ready_candidate_published_between_scans_wins_over_older_ready() {
        let root = TestSettingsRoot::new("new-ready-between-scans");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        let mut initial = Vec::new();
        for freshness in 100..=108 {
            let candidate = ready_temp_path(&path, freshness, 4, freshness as u64);
            write_fixture(
                &candidate,
                &AppSettingsSnapshot {
                    custom_account_display_name: format!("candidate-{freshness}"),
                    ..AppSettingsSnapshot::default()
                },
            );
            set_modified_time(
                &candidate,
                UNIX_EPOCH + Duration::from_secs(freshness as u64),
            );
            initial.push(candidate);
        }

        let first_error = recover_from_candidates_with_reader(
            &path,
            "corrupt primary".into(),
            interrupted_temp_candidates(&path).unwrap(),
            |_, _| RecoveryCandidateRead::Transient("injected share failure".into()),
        )
        .unwrap_err();
        assert!(first_error.contains("injected share failure"));

        let newer = ready_temp_path(&path, 200, 2, 1);
        write_fixture(
            &newer,
            &AppSettingsSnapshot {
                custom_account_display_name: "newest-ready".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        set_modified_time(&newer, UNIX_EPOCH + Duration::from_secs(200));
        let older = initial[0].clone();
        let recovered = recover_from_candidates_with_reader(
            &path,
            "corrupt primary".into(),
            interrupted_temp_candidates(&path).unwrap(),
            |candidate, budget| {
                if candidate.path == newer || candidate.path == older {
                    read_recovery_candidate(candidate, budget)
                } else {
                    RecoveryCandidateRead::Transient("injected share failure".into())
                }
            },
        )
        .unwrap();

        assert_eq!(
            recovered.settings.custom_account_display_name,
            "newest-ready"
        );
    }

    #[test]
    fn missing_ready_candidate_does_not_hide_an_older_valid_candidate() {
        let root = TestSettingsRoot::new("missing-ready");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        let missing = ready_temp_path(&path, 200, 2, 1);
        write_fixture(&missing, &AppSettingsSnapshot::default());
        set_modified_time(&missing, UNIX_EPOCH + Duration::from_secs(200));
        let valid = ready_temp_path(&path, 100, 1, 1);
        write_fixture(
            &valid,
            &AppSettingsSnapshot {
                custom_account_display_name: "after-missing".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        set_modified_time(&valid, UNIX_EPOCH + Duration::from_secs(100));
        let candidates = interrupted_temp_candidates(&path).unwrap();

        let recovered = recover_from_candidates_with_hook(
            &path,
            "corrupt primary".into(),
            candidates,
            |candidate| {
                if candidate == missing {
                    std::fs::remove_file(candidate).unwrap();
                }
            },
        )
        .unwrap();

        assert_eq!(
            recovered.settings.custom_account_display_name,
            "after-missing"
        );
    }

    #[test]
    fn malformed_ready_name_fails_closed_and_does_not_hide_valid_candidate() {
        let root = TestSettingsRoot::new("malformed-ready");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        let malformed = malformed_ready_temp_path(&path, "malformed");
        write_fixture(
            &malformed,
            &AppSettingsSnapshot {
                custom_account_display_name: "must-not-install".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        set_modified_time(&malformed, UNIX_EPOCH + Duration::from_secs(200));
        let valid = ready_temp_path(&path, 100, 1, 1);
        write_fixture(
            &valid,
            &AppSettingsSnapshot {
                custom_account_display_name: "valid-ready".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        set_modified_time(&valid, UNIX_EPOCH + Duration::from_secs(100));

        let recovered = read_app_settings_at_with_diagnostics(&path).unwrap();

        assert_eq!(
            recovered.settings.custom_account_display_name,
            "valid-ready"
        );
        assert!(!malformed.exists());
    }

    #[test]
    fn oversized_ready_candidate_is_rejected_before_reader_and_does_not_hide_valid_candidate() {
        let root = TestSettingsRoot::new("oversized-ready");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        let oversized = ready_temp_path(&path, 200, 2, 1);
        let oversized_file = File::create(&oversized).unwrap();
        oversized_file
            .set_len(RECOVERY_CANDIDATE_MAX_BYTES + 1)
            .unwrap();
        set_modified_time(&oversized, UNIX_EPOCH + Duration::from_secs(200));
        let valid = ready_temp_path(&path, 100, 1, 1);
        write_fixture(
            &valid,
            &AppSettingsSnapshot {
                custom_account_display_name: "after-oversized".into(),
                ..AppSettingsSnapshot::default()
            },
        );
        set_modified_time(&valid, UNIX_EPOCH + Duration::from_secs(100));

        let recovered = recover_from_candidates_with_reader(
            &path,
            "corrupt primary".into(),
            interrupted_temp_candidates(&path).unwrap(),
            |candidate, budget| {
                assert_ne!(
                    candidate.path, oversized,
                    "oversized candidate must be rejected before reading"
                );
                read_recovery_candidate(candidate, budget)
            },
        )
        .unwrap();

        assert_eq!(
            recovered.settings.custom_account_display_name,
            "after-oversized"
        );
    }

    #[test]
    fn recovery_candidate_count_over_hard_limit_fails_closed() {
        let root = TestSettingsRoot::new("candidate-count-overflow");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        for index in 0..17 {
            let candidate = ready_temp_path(&path, 100 + index, 3, index as u64);
            write_fixture(
                &candidate,
                &AppSettingsSnapshot {
                    custom_account_display_name: format!("candidate-{index}"),
                    ..AppSettingsSnapshot::default()
                },
            );
        }

        let error = read_app_settings_at_with_diagnostics(&path).unwrap_err();

        assert!(error.contains("恢复候选数量超过上限"));
        assert_eq!(std::fs::read(&path).unwrap(), b"{corrupt-primary");
    }

    #[test]
    fn recovery_directory_entry_scan_over_hard_limit_fails_closed() {
        let root = TestSettingsRoot::new("directory-entry-overflow");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        for index in 0..1025 {
            std::fs::write(root.path.join(format!("unrelated-{index:04}")), b"ignored").unwrap();
        }

        let error = read_app_settings_at_with_diagnostics(&path).unwrap_err();

        assert!(error.contains("目录项扫描数量超过上限"));
        assert_eq!(std::fs::read(&path).unwrap(), b"{corrupt-primary");
    }

    #[test]
    fn aggregate_candidate_bytes_over_hard_limit_fails_before_recovery_reads() {
        let root = TestSettingsRoot::new("candidate-byte-overflow");
        let path = root.settings_path();
        for index in 0..3 {
            let candidate = ready_temp_path(&path, 100 + index, 3, index as u64);
            File::create(candidate)
                .unwrap()
                .set_len(768 * 1024)
                .unwrap();
        }

        let error = interrupted_temp_candidates(&path).unwrap_err();

        assert!(error.contains("恢复候选累计大小超过上限"));
    }

    #[test]
    fn post_scan_candidate_growth_cannot_exceed_total_recovery_io_budget() {
        let root = TestSettingsRoot::new("candidate-io-overflow");
        let path = root.settings_path();
        std::fs::write(&path, b"{corrupt-primary").unwrap();
        for index in 0..3 {
            let candidate = ready_temp_path(&path, 100 + index, 3, index as u64);
            write_fixture(&candidate, &AppSettingsSnapshot::default());
        }
        let candidates = interrupted_temp_candidates(&path).unwrap();

        let error = recover_from_candidates_with_hook(
            &path,
            "corrupt primary".into(),
            candidates,
            |candidate| {
                OpenOptions::new()
                    .write(true)
                    .open(candidate)
                    .unwrap()
                    .set_len(768 * 1024)
                    .unwrap();
            },
        )
        .unwrap_err();

        assert!(error.contains("恢复累计读取超过上限"));
        assert_eq!(std::fs::read(&path).unwrap(), b"{corrupt-primary");
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

    fn leave_ready_candidate_after_replace_failure(path: &Path, value: &str) -> PathBuf {
        let result = mutate_app_settings_at_with_hooks(
            path,
            |_| {},
            |_, destination| {
                std::fs::remove_file(destination).unwrap();
                std::fs::create_dir(destination).unwrap();
            },
            sync_parent_directory,
            |settings| settings.custom_account_display_name = value.into(),
        );
        let error = result.unwrap_err();
        assert!(error.contains("原子替换设置文件失败"));
        let candidates = interrupted_temp_candidates(path).unwrap();
        assert_eq!(candidates.len(), 1);
        let ready = candidates[0].path.clone();
        let mut budget = RecoveryReadBudget {
            remaining_bytes: RECOVERY_TOTAL_BYTES_LIMIT,
        };
        assert!(matches!(
            read_recovery_candidate(&candidates[0], &mut budget),
            RecoveryCandidateRead::Valid(_)
        ));
        std::fs::remove_dir(path).unwrap();
        write_fixture(path, &AppSettingsSnapshot::default());
        ready
    }

    fn accumulate_ready_candidates_after_replace_failures(
        path: &Path,
        failure_count: usize,
    ) -> Vec<PathBuf> {
        for index in 0..failure_count {
            let result = mutate_app_settings_at_with_hooks(
                path,
                |_| {},
                |_, destination| {
                    std::fs::remove_file(destination).unwrap();
                    std::fs::create_dir(destination).unwrap();
                },
                sync_parent_directory,
                |settings| settings.custom_account_display_name = format!("failed-save-{index}"),
            );
            let error = result.unwrap_err();
            assert!(error.contains("原子替换设置文件失败"));
            std::fs::remove_dir(path).unwrap();
            write_fixture(path, &AppSettingsSnapshot::default());
        }

        interrupted_temp_candidates(path)
            .unwrap()
            .into_iter()
            .map(|candidate| candidate.path)
            .collect()
    }

    fn pending_candidate_path(settings_path: &Path) -> PathBuf {
        let Some(SettingsCommitMarker::Pending { candidate_name, .. }) =
            read_commit_marker(settings_path).unwrap()
        else {
            panic!("expected pending commit marker");
        };
        settings_path.parent().unwrap().join(candidate_name)
    }

    fn write_fixture(path: &Path, settings: &AppSettingsSnapshot) {
        std::fs::write(path, serde_json::to_vec_pretty(settings).unwrap()).unwrap();
    }

    fn write_durable_ready_fixture(path: &Path, settings: &AppSettingsSnapshot) {
        let bytes = serde_json::to_vec_pretty(settings).unwrap();
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)
            .unwrap();
        file.write_all(&bytes).unwrap();
        file.flush().unwrap();
        file.sync_all().unwrap();
        drop(file);
        sync_parent_directory(path.parent().unwrap()).unwrap();
    }

    fn set_modified_time(path: &Path, modified: SystemTime) {
        let file = OpenOptions::new().write(true).open(path).unwrap();
        file.set_times(FileTimes::new().set_modified(modified))
            .unwrap();
    }

    fn commit_marker_quarantines(settings_path: &Path) -> Vec<PathBuf> {
        let marker_name = commit_marker_path(settings_path)
            .unwrap()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let prefix = format!("{marker_name}.corrupt-v1-");
        let mut paths: Vec<PathBuf> = std::fs::read_dir(settings_path.parent().unwrap())
            .unwrap()
            .flatten()
            .filter(|entry| entry.file_name().to_string_lossy().starts_with(&prefix))
            .map(|entry| entry.path())
            .collect();
        paths.sort();
        paths
    }

    fn in_progress_temp_path(
        settings_path: &Path,
        created_at: u128,
        pid: u32,
        sequence: u64,
    ) -> PathBuf {
        settings_path.with_file_name(format!(
            "settings.json.tmp-in-progress-v3-{created_at:039}-{pid}-{sequence:020}"
        ))
    }

    fn ready_temp_path(settings_path: &Path, freshness: u128, pid: u32, sequence: u64) -> PathBuf {
        settings_path.with_file_name(format!(
            "settings.json.tmp-ready-v3-{freshness:039}-{pid}-{sequence:020}"
        ))
    }

    fn transactional_ready_temp_path(
        settings_path: &Path,
        generation: u128,
        pid: u32,
        sequence: u64,
    ) -> PathBuf {
        let file_name = settings_path.file_name().unwrap().to_string_lossy();
        settings_path.with_file_name(format!(
            "{file_name}.tmp-ready-v4-{generation:039}-{pid}-{sequence:020}"
        ))
    }

    fn malformed_ready_temp_path(settings_path: &Path, suffix: &str) -> PathBuf {
        settings_path.with_file_name(format!("settings.json.tmp-ready-v3-{suffix}"))
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
