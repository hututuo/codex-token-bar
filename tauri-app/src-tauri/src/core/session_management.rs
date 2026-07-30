use crate::core::coordination_fs::CoordinationHome;
use crate::core::cross_process_lock::CrossProcessFileLock;
use crate::core::process_tail::ProcessPipeTail;
use crate::core::quota::codex_binary::find_codex_binary_with_report;
use crate::models::{
    SessionActionItemResult, SessionBatchActionResult, SessionContextMessage, SessionContextPage,
    SessionDeleteConfirmation, SessionDeleteRolloutSnapshot, SessionManagementCapabilities,
    SessionManagementCapability, SessionManagementCatalog, SessionManagementThread,
};
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Component, Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{mpsc, Mutex, MutexGuard, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const APP_SERVER_TIMEOUT: Duration = Duration::from_secs(20);
const MUTATION_TIMEOUT: Duration = Duration::from_secs(6 * 60 * 60);
const STDERR_TAIL_LIMIT: usize = 16 * 1024;
const STDERR_DRAIN_GRACE: Duration = Duration::from_millis(500);
const CONTEXT_READ_BUFFER: usize = 64 * 1024;
const DEFAULT_CONTEXT_PAGE_SIZE: usize = 50;
const MAX_CONTEXT_PAGE_SIZE: usize = 200;
const LARGE_LINE_THRESHOLD: u64 = 1024 * 1024;
const MESSAGE_DISPLAY_BYTES: usize = 256 * 1024;
const DELETE_CONFIRMATION_SCHEMA_VERSION: u32 = 1;
const THREAD_SOURCE_KINDS: &[&str] = &[
    "cli",
    "vscode",
    "exec",
    "appServer",
    "subAgent",
    "subAgentReview",
    "subAgentCompact",
    "subAgentThreadSpawn",
    "subAgentOther",
    "unknown",
];
const CHILD_ENV_REMOVE: &[&str] = &[
    "ELECTRON_RUN_AS_NODE",
    "NODE_OPTIONS",
    "TAURI_SIGNING_PRIVATE_KEY",
    "TAURI_SIGNING_PRIVATE_KEY_PATH",
];
static SESSION_MUTATION_LEASE: OnceLock<Mutex<()>> = OnceLock::new();

#[derive(Clone, Debug, Default)]
struct ThreadSupplement {
    rollout_path: Option<PathBuf>,
    title: String,
    preview: String,
    cwd: String,
    created_at: Option<i64>,
    updated_at: Option<i64>,
    recency_at: Option<i64>,
    archived: bool,
    archived_at: Option<i64>,
    tokens_used: Option<i64>,
    source: String,
    model: String,
    first_user_message: String,
    session_id: Option<String>,
    forked_from_id: Option<String>,
    parent_thread_id: Option<String>,
}

#[derive(Clone, Debug, Default)]
struct RolloutScan {
    supplements: HashMap<String, ThreadSupplement>,
    ambiguous_ids: HashSet<String>,
    warnings: Vec<String>,
}

#[derive(Clone, Debug, Default)]
struct ProtocolThread {
    id: String,
    title: String,
    preview: String,
    cwd: String,
    created_at: Option<i64>,
    updated_at: Option<i64>,
    archived: bool,
    status: String,
    source: String,
    model: String,
    rollout_path: Option<PathBuf>,
    session_id: Option<String>,
    forked_from_id: Option<String>,
    parent_thread_id: Option<String>,
}

trait SessionProtocol {
    fn list_threads(&mut self, archived: bool) -> Result<Vec<Value>, String>;
}

pub fn list_catalog(codex_home: &Path) -> Result<SessionManagementCatalog, String> {
    match ProcessAppServer::launch(codex_home).and_then(|mut protocol| {
        protocol.initialize()?;
        Ok(protocol)
    }) {
        Ok(mut protocol) => list_catalog_with_protocol(codex_home, &mut protocol),
        Err(error) => {
            let mut unavailable = UnavailableProtocol { error };
            list_catalog_with_protocol(codex_home, &mut unavailable)
        }
    }
}

fn list_catalog_with_protocol(
    codex_home: &Path,
    protocol: &mut dyn SessionProtocol,
) -> Result<SessionManagementCatalog, String> {
    let mut warnings = Vec::new();
    let active_rows = match protocol.list_threads(false) {
        Ok(rows) => rows,
        Err(error) => {
            warnings.push(format!("官方活动会话列表读取失败：{error}"));
            Vec::new()
        }
    };
    let archived_rows = match protocol.list_threads(true) {
        Ok(rows) => rows,
        Err(error) => {
            warnings.push(format!("官方归档会话列表读取失败：{error}"));
            Vec::new()
        }
    };
    let mut protocol_threads = HashMap::<String, ProtocolThread>::new();
    for row in active_rows {
        if let Some(thread) = parse_protocol_thread(&row, false) {
            protocol_threads.insert(thread.id.clone(), thread);
        }
    }
    for row in archived_rows {
        if let Some(thread) = parse_protocol_thread(&row, true) {
            protocol_threads.insert(thread.id.clone(), thread);
        }
    }

    let mut supplements = match read_state_supplements(codex_home) {
        Ok(rows) => rows,
        Err(error) => {
            warnings.push(format!("只读状态库补充失败：{error}"));
            HashMap::new()
        }
    };
    let scan = scan_rollout_supplements(codex_home);
    warnings.extend(scan.warnings.iter().cloned());
    let mut ambiguous_rollout_ids = scan.ambiguous_ids;
    for (id, scanned) in scan.supplements {
        let row = supplements.entry(id.clone()).or_default();
        if let (Some(database_path), Some(scanned_path)) =
            (row.rollout_path.as_deref(), scanned.rollout_path.as_deref())
        {
            let database_path = trusted_rollout_path(codex_home, database_path).ok();
            if database_path.as_deref() != Some(scanned_path) {
                ambiguous_rollout_ids.insert(id.clone());
                warnings.push(format!(
                    "会话 {id} 的状态库与只读扫描指向不同 rollout，危险操作已安全关闭"
                ));
            }
        } else if row.rollout_path.is_none() {
            row.rollout_path = scanned.rollout_path;
        }
        if row.cwd.trim().is_empty() {
            row.cwd = scanned.cwd;
        }
        row.created_at = row.created_at.or(scanned.created_at);
        row.updated_at = row.updated_at.or(scanned.updated_at);
        row.recency_at = row.recency_at.or(scanned.recency_at);
        row.session_id = row.session_id.clone().or(scanned.session_id);
        row.forked_from_id = row.forked_from_id.clone().or(scanned.forked_from_id);
        row.parent_thread_id = row.parent_thread_id.clone().or(scanned.parent_thread_id);
        if scanned.archived {
            row.archived = true;
        }
    }
    let (protected_auto_resume, auto_resume_protection_error) = match enabled_auto_resume_threads()
    {
        Ok(threads) => (threads, None),
        Err(error) => {
            let message = format!("自动续跑保护状态读取失败，危险操作已安全关闭：{error}");
            warnings.push(message.clone());
            (HashSet::new(), Some(message))
        }
    };
    let mut catalog_capabilities = capabilities(codex_home);
    if let Some(reason) = auto_resume_protection_error.as_ref() {
        let unavailable = SessionManagementCapability {
            available: false,
            reason: Some(reason.clone()),
        };
        catalog_capabilities.official_archive = unavailable.clone();
        catalog_capabilities.official_unarchive = unavailable.clone();
        catalog_capabilities.official_delete = unavailable.clone();
        catalog_capabilities.recovery_archive = unavailable;
    }
    let official_write_unavailable_reason =
        (!catalog_capabilities.official_delete.available).then(|| {
            catalog_capabilities
                .official_delete
                .reason
                .clone()
                .unwrap_or_else(|| "官方写操作当前不可用".into())
        });
    let mut ids: HashSet<String> = protocol_threads.keys().cloned().collect();
    ids.extend(supplements.keys().cloned());
    let mut threads = Vec::with_capacity(ids.len());
    for id in ids {
        let protocol_row = protocol_threads.remove(&id);
        let protocol_present = protocol_row.is_some();
        let protocol = protocol_row.unwrap_or_default();
        let mut supplemental = supplements.get(&id).cloned().unwrap_or_default();
        if supplemental.rollout_path.is_none() {
            supplemental.rollout_path = protocol.rollout_path.clone();
        }
        let rollout_identity_verified =
            enrich_from_session_meta(codex_home, &id, &mut supplemental, &mut warnings);
        let (file_bytes, file_modified_at) = rollout_stat(
            codex_home,
            supplemental.rollout_path.as_deref(),
            &id,
            &mut warnings,
        );

        let status = if protocol.status.is_empty() {
            if protocol.archived || supplemental.archived {
                "notLoaded".to_string()
            } else {
                "unknown".to_string()
            }
        } else {
            protocol.status.clone()
        };
        let archived = if protocol_present {
            protocol.archived
        } else {
            supplemental.archived
        };
        let mut protection_reasons = Vec::new();
        if let Some(reason) = status_protection_reason(&status) {
            protection_reasons.push(reason.into());
        }
        if protected_auto_resume.contains(&id) {
            protection_reasons.push("已被自动续跑任务保护".into());
        }
        if let Some(reason) = auto_resume_protection_error.as_ref() {
            protection_reasons.push(reason.clone());
        }
        if let Some(reason) = official_write_unavailable_reason.as_ref() {
            protection_reasons.push(reason.clone());
        }
        if !rollout_identity_verified {
            protection_reasons
                .push("无法验证 rollout 首行身份与会话 ID 一致，危险操作已安全关闭".into());
        }
        if ambiguous_rollout_ids.contains(&id) {
            protection_reasons.push("同一会话 ID 对应多个 rollout 文件，危险操作已安全关闭".into());
        }
        let safe = protection_reasons.is_empty();
        let parent_thread_id = protocol
            .parent_thread_id
            .clone()
            .or(supplemental.parent_thread_id.clone());
        let source = first_non_empty(&protocol.source, &supplemental.source, "unknown");
        threads.push(SessionManagementThread {
            id,
            title: first_non_empty(&protocol.title, &supplemental.title, "未命名任务"),
            preview: first_non_empty(
                &protocol.preview,
                &supplemental.preview,
                &supplemental.first_user_message,
            ),
            cwd: first_non_empty(&protocol.cwd, &supplemental.cwd, ""),
            created_at: protocol.created_at.or(supplemental.created_at),
            updated_at: protocol.updated_at.or(supplemental.updated_at),
            recency_at: supplemental.recency_at.or(protocol.updated_at),
            archived,
            archived_at: supplemental.archived_at,
            tokens_used: supplemental.tokens_used,
            file_bytes,
            file_modified_at,
            status,
            source: (!source.trim().is_empty() && source != "unknown").then_some(source.clone()),
            model: non_empty_option(&protocol.model)
                .or_else(|| non_empty_option(&supplemental.model)),
            session_id: protocol
                .session_id
                .clone()
                .or(supplemental.session_id.clone()),
            forked_from_id: protocol
                .forked_from_id
                .clone()
                .or(supplemental.forked_from_id.clone()),
            parent_thread_id: parent_thread_id.clone(),
            is_subagent: parent_thread_id.is_some()
                || normalize_status(&source).contains("subagent"),
            spawn_child_count: 0,
            fork_child_count: 0,
            similarity_group_id: None,
            similarity_reason: None,
            protection_reasons,
            can_archive: !archived && safe,
            can_unarchive: archived && safe,
            can_delete: safe,
        });
    }
    apply_relationship_counts(&mut threads);
    apply_similarity_groups(&mut threads, &supplements);
    threads.sort_by(|left, right| {
        right
            .recency_at
            .cmp(&left.recency_at)
            .then_with(|| right.updated_at.cmp(&left.updated_at))
            .then_with(|| left.id.cmp(&right.id))
    });
    let total_bytes = if threads.iter().all(|thread| thread.file_bytes.is_some()) {
        Some(threads.iter().try_fold(0_u64, |sum, thread| {
            sum.checked_add(thread.file_bytes.unwrap_or_default())
                .ok_or_else(|| "会话文件总字节数溢出".to_string())
        })?)
    } else {
        None
    };
    Ok(SessionManagementCatalog {
        threads,
        generated_at: unix_now(),
        codex_home: codex_home.to_string_lossy().into_owned(),
        total_bytes,
        warnings,
        capabilities: catalog_capabilities,
    })
}

pub fn read_context_page(
    codex_home: &Path,
    thread_id: &str,
    before_offset: Option<u64>,
    page_size: Option<usize>,
) -> Result<SessionContextPage, String> {
    validate_thread_id(thread_id)?;
    let supplements = read_state_supplements(codex_home)?;
    let path = supplements
        .get(thread_id)
        .and_then(|row| row.rollout_path.as_deref())
        .and_then(|path| trusted_rollout_path(codex_home, path).ok())
        .or_else(|| find_rollout_by_id(codex_home, thread_id).ok().flatten())
        .ok_or_else(|| format!("找不到会话 {thread_id} 的可信 rollout 文件"))?;
    let source_meta = read_session_meta(&path)
        .map_err(|error| format!("上下文读取前无法验证 rollout 首行身份：{error}"))?;
    if source_meta.id != thread_id {
        return Err(format!(
            "rollout 首行 ID 与目标会话不一致：期望 {thread_id}，实际 {}",
            source_meta.id
        ));
    }
    let mut file = File::open(&path)
        .map_err(|error| format!("打开会话上下文失败（{}）：{error}", path.display()))?;
    let metadata = file
        .metadata()
        .map_err(|error| format!("读取会话文件属性失败：{error}"))?;
    let file_len = metadata.len();
    let mut warnings = Vec::new();
    let safe_end = complete_prefix_end(&mut file, file_len)?;
    if safe_end < file_len {
        warnings.push("文件末尾存在尚未完成的 JSONL 记录，本页已停在最后一个完整行边界".into());
    }
    let requested = before_offset.unwrap_or(safe_end).min(safe_end);
    let mut cursor = requested;
    let page_size = page_size
        .unwrap_or(DEFAULT_CONTEXT_PAGE_SIZE)
        .clamp(1, MAX_CONTEXT_PAGE_SIZE);
    let mut messages = Vec::with_capacity(page_size);
    while cursor > 0 && messages.len() < page_size {
        let Some((start, end)) = previous_line_range(&mut file, cursor)? else {
            cursor = 0;
            break;
        };
        cursor = start;
        if end > start {
            match parse_context_line(&mut file, start, end) {
                Ok(Some(message)) => messages.push(message),
                Ok(None) => {}
                Err(error) => warnings.push(format!("偏移 {start} 的记录无法解析：{error}")),
            }
        }
    }
    messages.reverse();
    let has_more_before = cursor > 0;
    Ok(SessionContextPage {
        thread_id: thread_id.to_string(),
        messages,
        next_before_offset: has_more_before.then_some(cursor),
        has_more_before,
        file_identity: file_identity(&path, &metadata),
        warnings,
    })
}

pub fn archive_threads(
    codex_home: &Path,
    thread_ids: Vec<String>,
    expected_source_key: &str,
) -> SessionBatchActionResult {
    let requested_ids = deduplicated_ids(thread_ids);
    let _lease = match acquire_session_mutation_lease(codex_home, expected_source_key) {
        Ok(lease) => lease,
        Err(error) => return failed_batch(&requested_ids, error),
    };
    let _auto_resume_leases = match crate::core::auto_resume::acquire_session_mutation_thread_leases(
        _lease.coordination_home(),
        &requested_ids,
    ) {
        Ok(leases) => leases,
        Err(error) => return failed_batch(&requested_ids, error),
    };
    run_batch_mutation(
        codex_home,
        requested_ids,
        ReversibleMutation::Archive,
        expected_source_key,
    )
}

pub fn unarchive_threads(
    codex_home: &Path,
    thread_ids: Vec<String>,
    expected_source_key: &str,
) -> SessionBatchActionResult {
    let requested_ids = deduplicated_ids(thread_ids);
    let _lease = match acquire_session_mutation_lease(codex_home, expected_source_key) {
        Ok(lease) => lease,
        Err(error) => return failed_batch(&requested_ids, error),
    };
    let _auto_resume_leases = match crate::core::auto_resume::acquire_session_mutation_thread_leases(
        _lease.coordination_home(),
        &requested_ids,
    ) {
        Ok(leases) => leases,
        Err(error) => return failed_batch(&requested_ids, error),
    };
    run_batch_mutation(
        codex_home,
        requested_ids,
        ReversibleMutation::Unarchive,
        expected_source_key,
    )
}

pub fn prepare_delete_confirmation(
    codex_home: &Path,
    thread_ids: Vec<String>,
    expected_source_key: &str,
) -> Result<SessionDeleteConfirmation, String> {
    let requested_ids = validated_unique_thread_ids(thread_ids)?;
    if requested_ids.is_empty() {
        return Err("至少选择一个会话后才能准备永久删除确认".into());
    }
    ensure_codex_home_identity(codex_home, expected_source_key)?;
    let initial = prepare_delete_impact(codex_home, &requested_ids, expected_source_key)?;
    prepare_delete_confirmation_after_initial(
        codex_home,
        expected_source_key,
        &requested_ids,
        initial,
        || prepare_delete_impact(codex_home, &requested_ids, expected_source_key),
        || Ok(()),
    )
}

fn prepare_delete_confirmation_after_initial<ReadImpact, AfterSnapshot>(
    codex_home: &Path,
    expected_source_key: &str,
    requested_ids: &[String],
    initial: DeletionImpact,
    mut read_impact: ReadImpact,
    after_snapshot: AfterSnapshot,
) -> Result<SessionDeleteConfirmation, String>
where
    ReadImpact: FnMut() -> Result<DeletionImpact, String>,
    AfterSnapshot: FnOnce() -> Result<(), String>,
{
    // The first directory read intentionally happens before the shared write
    // lock so a slow or unavailable app-server never holds the mutation lane.
    // Once locked, every affected thread is leased against auto-resume and the
    // complete official closure is read again before and after file snapshots.
    let _lease = acquire_session_mutation_lease(codex_home, expected_source_key)?;
    let _auto_resume_leases = crate::core::auto_resume::acquire_session_mutation_thread_leases(
        _lease.coordination_home(),
        &initial.affected_ids,
    )?;
    let locked = read_impact()?;
    ensure_same_delete_impact_scope(
        &initial,
        &locked,
        "取得写锁与自动续跑租约期间 spawned 后代范围发生变化",
    )?;
    let confirmation = build_delete_confirmation(codex_home, expected_source_key, &locked)?;
    after_snapshot()?;
    let final_impact = read_impact()?;
    ensure_same_delete_impact_scope(
        &locked,
        &final_impact,
        "建立删除确认快照期间 spawned 后代范围发生变化",
    )?;
    if final_impact.requested_ids != requested_ids {
        return Err("建立删除确认期间请求会话范围发生变化".into());
    }
    validate_delete_confirmation(
        codex_home,
        expected_source_key,
        &final_impact,
        &confirmation,
    )?;
    Ok(confirmation)
}

pub fn delete_threads(
    codex_home: &Path,
    thread_ids: Vec<String>,
    create_recovery: bool,
    recovery_source_key: &str,
    confirmation: SessionDeleteConfirmation,
) -> SessionBatchActionResult {
    let original_thread_ids = deduplicated_ids(thread_ids.clone());
    let requested_ids = match validated_unique_thread_ids(thread_ids) {
        Ok(ids) => ids,
        Err(error) => return failed_batch(&original_thread_ids, error),
    };
    if requested_ids.is_empty() {
        return SessionBatchActionResult {
            results: Vec::new(),
            warnings: Vec::new(),
        };
    }
    if let Err(error) = require_delete_recovery_archive(create_recovery) {
        return failed_batch(&requested_ids, error);
    }
    let _lease = match acquire_session_mutation_lease(codex_home, recovery_source_key) {
        Ok(lease) => lease,
        Err(error) => return failed_batch(&requested_ids, error),
    };
    if let Err(error) = ensure_codex_home_identity(codex_home, recovery_source_key) {
        return failed_batch(&requested_ids, error);
    }
    let initial = match prepare_delete_impact(codex_home, &requested_ids, recovery_source_key) {
        Ok(impact) => impact,
        Err(error) => return failed_batch(&requested_ids, error),
    };
    if let Err(error) =
        validate_delete_confirmation(codex_home, recovery_source_key, &initial, &confirmation)
    {
        return failed_batch(&requested_ids, error);
    }
    let _auto_resume_leases = match crate::core::auto_resume::acquire_session_mutation_thread_leases(
        _lease.coordination_home(),
        &initial.affected_ids,
    ) {
        Ok(leases) => leases,
        Err(error) => return failed_batch(&requested_ids, error),
    };
    let locked = match prepare_delete_impact(codex_home, &requested_ids, recovery_source_key) {
        Ok(impact) => impact,
        Err(error) => return failed_batch(&requested_ids, error),
    };
    if let Err(error) =
        validate_delete_confirmation(codex_home, recovery_source_key, &locked, &confirmation)
    {
        return failed_batch(&requested_ids, error);
    }

    let mut recovery_paths = HashMap::<String, String>::new();
    let mut recovery_receipts = HashMap::<String, RecoveryArchiveReceipt>::new();
    {
        if recovery_source_key.trim().is_empty() {
            return failed_batch(
                &requested_ids,
                "删除未开始：恢复包缺少 Codex Home 物理来源标识".into(),
            );
        }
        // Official delete recursively removes spawned descendants. Every
        // affected rollout must be fully packaged before the first delete.
        // Active and archived sessions use the same verified rollout contract;
        // official archival is not a prerequisite for recovery evidence.
        for affected_id in &initial.affected_ids {
            match create_recovery_archive(codex_home, affected_id, recovery_source_key) {
                Ok(receipt) => {
                    if let Err(error) =
                        validate_receipt_against_confirmation(affected_id, &receipt, &confirmation)
                    {
                        return failed_batch_with_recovery(
                            &requested_ids,
                            format!(
                                "删除未开始：受影响会话 {affected_id} 的恢复包不是用户确认时的 rollout 版本：{error}"
                            ),
                            &recovery_paths,
                        );
                    }
                    recovery_paths.insert(
                        affected_id.clone(),
                        receipt.path.to_string_lossy().into_owned(),
                    );
                    recovery_receipts.insert(affected_id.clone(), receipt);
                }
                Err(error) => {
                    let published_path = error
                        .published_path
                        .as_ref()
                        .map(|path| path.to_string_lossy().into_owned());
                    let mut result = failed_batch_with_recovery(
                        &requested_ids,
                        format!(
                            "删除未开始：受影响会话 {affected_id} 的恢复包创建或校验失败：{error}"
                        ),
                        &recovery_paths,
                    );
                    if let Some(path) = published_path {
                        result.warnings.push(format!(
                            "恢复包已发布但未通过后置校验，路径仍予报告：{affected_id} → {path}"
                        ));
                        if let Some(item) = result
                            .results
                            .iter_mut()
                            .find(|item| item.thread_id == *affected_id)
                        {
                            item.recovery_archive_path = Some(path);
                        }
                    }
                    return result;
                }
            }
        }
        let refreshed = match prepare_delete_impact(codex_home, &requested_ids, recovery_source_key)
        {
            Ok(impact) => impact,
            Err(error) => {
                return failed_batch_with_recovery(
                    &requested_ids,
                    format!("删除未开始：恢复包完成后的安全复核失败：{error}"),
                    &recovery_paths,
                )
            }
        };
        if HashSet::<&str>::from_iter(initial.affected_ids.iter().map(String::as_str))
            != HashSet::<&str>::from_iter(refreshed.affected_ids.iter().map(String::as_str))
            || initial.effective_root_ids != refreshed.effective_root_ids
        {
            return failed_batch_with_recovery(
                &requested_ids,
                "删除未开始：建立恢复包期间 spawned 后代范围发生变化，请刷新后重试".into(),
                &recovery_paths,
            );
        }
        if let Err(error) =
            validate_delete_confirmation(codex_home, recovery_source_key, &refreshed, &confirmation)
        {
            return failed_batch_with_recovery(
                &requested_ids,
                format!("删除未开始：用户确认的 rollout 快照已变化：{error}"),
                &recovery_paths,
            );
        }
        for affected_id in &initial.affected_ids {
            let receipt = recovery_receipts
                .get(affected_id)
                .ok_or_else(|| format!("缺少受影响会话 {affected_id} 的恢复包冻结回执"));
            let validation = receipt
                .and_then(|receipt| verify_recovery_receipt(codex_home, affected_id, receipt));
            if let Err(error) = validation {
                return failed_batch_with_recovery(
                    &requested_ids,
                    format!(
                        "删除未开始：受影响会话 {affected_id} 的 rollout 在恢复包完成后发生变化：{error}"
                    ),
                    &recovery_paths,
                );
            }
        }
    }

    let mut root_results = HashMap::<String, Result<String, String>>::new();
    let mut completed_affected_ids = Vec::<String>::new();
    let mut execution_stopped = false;
    for (index, root_id) in initial.effective_root_ids.iter().enumerate() {
        if execution_stopped {
            root_results.insert(
                root_id.clone(),
                Err("前一个删除根失败或结果不确定，本根未执行".into()),
            );
            continue;
        }
        let remaining_root_ids = &initial.effective_root_ids[index..];
        let expected_remaining_ids = expected_affected_for_roots(&initial, remaining_root_ids);
        let current =
            match prepare_delete_impact(codex_home, remaining_root_ids, recovery_source_key) {
                Ok(impact) => impact,
                Err(error) => {
                    execution_stopped = true;
                    root_results.insert(
                        root_id.clone(),
                        Err(format!("本根执行前安全复核失败：{error}")),
                    );
                    continue;
                }
            };
        if let Err(error) =
            validate_remaining_delete_plan(&current, remaining_root_ids, &expected_remaining_ids)
        {
            execution_stopped = true;
            root_results.insert(root_id.clone(), Err(error));
            continue;
        }
        if !completed_affected_ids.is_empty() {
            if let Err(error) = verify_official_ids_absent(codex_home, &completed_affected_ids) {
                execution_stopped = true;
                root_results.insert(
                    root_id.clone(),
                    Err(format!("前序删除范围最终核验失败，本根未执行：{error}")),
                );
                continue;
            }
        }
        {
            let mut receipt_error = None;
            for affected_id in &expected_remaining_ids {
                let validation = recovery_receipts
                    .get(affected_id)
                    .ok_or_else(|| format!("缺少会话 {affected_id} 的恢复包冻结回执"))
                    .and_then(|receipt| verify_recovery_receipt(codex_home, affected_id, receipt));
                if let Err(error) = validation {
                    receipt_error = Some(format!(
                        "会话 {affected_id} 的恢复材料已不再匹配当前 rollout：{error}"
                    ));
                    break;
                }
            }
            if let Some(error) = receipt_error {
                execution_stopped = true;
                root_results.insert(root_id.clone(), Err(error));
                continue;
            }
        }
        if let Err(error) = ensure_codex_home_identity(codex_home, recovery_source_key) {
            execution_stopped = true;
            root_results.insert(root_id.clone(), Err(error));
            continue;
        }
        let cli_attempt = match execute_delete_cli_with_final_gate(
            codex_home,
            recovery_source_key,
            remaining_root_ids,
            &expected_remaining_ids,
            &confirmation,
            &recovery_receipts,
            || Ok(()),
            || prepare_delete_impact(codex_home, remaining_root_ids, recovery_source_key),
            || run_official_cli(codex_home, root_id, OfficialMutation::Delete),
        ) {
            Ok(attempt) => attempt,
            Err(error) => {
                execution_stopped = true;
                root_results.insert(
                    root_id.clone(),
                    Err(format!("官方删除命令启动前的最终冻结复验失败：{error}")),
                );
                continue;
            }
        };
        let root_affected_ids: Vec<String> = initial
            .descendants_by_root
            .get(root_id)
            .into_iter()
            .flat_map(|ids| ids.iter().cloned())
            .collect();
        let post_verification = ensure_codex_home_identity(codex_home, recovery_source_key)
            .and_then(|_| verify_official_ids_absent(codex_home, &root_affected_ids));
        match (cli_attempt.pinned_evidence_result, post_verification) {
            (Err(evidence_error), verification) => {
                execution_stopped = true;
                let verification = verification
                    .err()
                    .map(|error| format!("；官方目录复核：{error}"))
                    .unwrap_or_default();
                root_results.insert(
                    root_id.clone(),
                    Err(format!(
                        "Codex 命令已启动，但恢复包或原 rollout 的固定句柄在返回后复验失败：{evidence_error}{verification}"
                    )),
                );
            }
            (Ok(()), Ok(())) => {
                completed_affected_ids.extend(root_affected_ids);
                let message = match cli_attempt.command_result {
                    Ok(()) => "已通过 Codex 官方接口删除并核验完整 spawned 闭包".into(),
                    Err(error) => format!(
                        "Codex 命令返回异常，但官方完整目录已核验本根及全部 spawned 后代均不存在：{error}"
                    ),
                };
                root_results.insert(root_id.clone(), Ok(message));
            }
            (Ok(()), Err(verification_error)) => {
                execution_stopped = true;
                let message = match cli_attempt.command_result {
                    Ok(()) => format!(
                        "Codex 命令已返回，但无法确认本根完整 spawned 闭包已删除：{verification_error}"
                    ),
                    Err(command_error) => format!(
                        "Codex 命令失败且删除结果无法确认：{command_error}；复核：{verification_error}"
                    ),
                };
                root_results.insert(root_id.clone(), Err(message));
            }
        }
    }

    let mut final_verification_warning = None;
    if !completed_affected_ids.is_empty() {
        if let Err(error) = verify_official_ids_absent(codex_home, &completed_affected_ids) {
            final_verification_warning = Some(format!(
                "最终官方完整目录无法核验已执行根的冻结闭包：{error}"
            ));
            for result in root_results.values_mut() {
                if result.is_ok() {
                    *result = Err(format!(
                        "官方删除可能已执行，但最终完整闭包核验失败：{error}"
                    ));
                }
            }
        }
    }

    let results = requested_ids
        .iter()
        .map(|thread_id| {
            let covering_root = initial
                .effective_root_ids
                .iter()
                .find(|root| initial.covered_by(root, thread_id))
                .cloned()
                .unwrap_or_else(|| thread_id.clone());
            match root_results.get(&covering_root) {
                Some(Ok(message)) => SessionActionItemResult {
                    thread_id: thread_id.clone(),
                    ok: true,
                    message: Some(if covering_root == *thread_id {
                        format!("{message}；本根会话的 spawned 后代已按官方语义一并处理")
                    } else {
                        format!("已随上级会话 {covering_root} 的官方递归删除一并处理")
                    }),
                    recovery_archive_path: recovery_paths.get(thread_id).cloned(),
                },
                Some(Err(error)) => SessionActionItemResult {
                    thread_id: thread_id.clone(),
                    ok: false,
                    message: Some(error.clone()),
                    recovery_archive_path: recovery_paths.get(thread_id).cloned(),
                },
                None => SessionActionItemResult {
                    thread_id: thread_id.clone(),
                    ok: false,
                    message: Some("无法确认该会话对应的有效删除根，已拒绝操作".into()),
                    recovery_archive_path: recovery_paths.get(thread_id).cloned(),
                },
            }
        })
        .collect();
    let mut warnings = Vec::new();
    if let Some(warning) = final_verification_warning {
        warnings.push(warning);
    }
    if initial.affected_ids.len() > initial.requested_ids.len() {
        warnings.push(format!(
            "官方删除实际影响 {} 个会话，其中 {} 个是 spawned 后代；已按完整影响范围执行门禁并逐个创建校验恢复包",
            initial.affected_ids.len(),
            initial.affected_ids.len() - initial.requested_ids.len()
        ));
    }
    if !initial.external_fork_reference_ids.is_empty() {
        warnings.push(format!(
            "{} 个外部 Fork 仅引用本次删除范围，不会随 spawned 后代递归删除",
            initial.external_fork_reference_ids.len()
        ));
    }
    if !recovery_paths.is_empty() {
        let mut entries: Vec<_> = recovery_paths.iter().collect();
        entries.sort_by(|left, right| left.0.cmp(right.0));
        warnings.extend(
            entries
                .into_iter()
                .map(|(thread_id, path)| format!("恢复包已完整校验：{thread_id} → {path}")),
        );
    }
    SessionBatchActionResult { results, warnings }
}

pub(crate) fn require_delete_recovery_archive(enabled: bool) -> Result<(), String> {
    if enabled {
        Ok(())
    } else {
        Err("永久删除必须先为完整 affected closure 创建并验证恢复包；无恢复包删除已被拒绝".into())
    }
}

pub fn create_recovery_archives(
    codex_home: &Path,
    thread_ids: Vec<String>,
    recovery_source_key: &str,
) -> SessionBatchActionResult {
    let requested_ids = deduplicated_ids(thread_ids);
    let _lease = match acquire_session_mutation_lease(codex_home, recovery_source_key) {
        Ok(lease) => lease,
        Err(error) => return failed_batch(&requested_ids, error),
    };
    let _auto_resume_leases = match crate::core::auto_resume::acquire_session_mutation_thread_leases(
        _lease.coordination_home(),
        &requested_ids,
    ) {
        Ok(leases) => leases,
        Err(error) => return failed_batch(&requested_ids, error),
    };
    let mut results = Vec::with_capacity(requested_ids.len());
    for thread_id in requested_ids {
        results.push(
            match create_recovery_archive(codex_home, &thread_id, recovery_source_key) {
                Ok(receipt) => SessionActionItemResult {
                    thread_id,
                    ok: true,
                    message: Some("深度压缩恢复包已创建并校验；原会话未删除".into()),
                    recovery_archive_path: Some(receipt.path.to_string_lossy().into_owned()),
                },
                Err(error) => SessionActionItemResult {
                    thread_id,
                    ok: false,
                    message: Some(error.to_string()),
                    recovery_archive_path: error
                        .published_path
                        .map(|path| path.to_string_lossy().into_owned()),
                },
            },
        );
    }
    SessionBatchActionResult {
        results,
        warnings: Vec::new(),
    }
}

struct SessionMutationLease {
    _cross_process: CrossProcessFileLock,
    coordination_home: CoordinationHome,
    _in_process: MutexGuard<'static, ()>,
}

impl SessionMutationLease {
    fn coordination_home(&self) -> &CoordinationHome {
        &self.coordination_home
    }
}

fn acquire_session_mutation_lease(
    codex_home: &Path,
    expected_source_key: &str,
) -> Result<SessionMutationLease, String> {
    ensure_codex_home_identity(codex_home, expected_source_key)?;
    let in_process = SESSION_MUTATION_LEASE
        .get_or_init(|| Mutex::new(()))
        .lock()
        .map_err(|_| "会话写操作互斥锁已损坏，已拒绝危险操作".to_string())?;
    let coordination_home = CoordinationHome::open(codex_home)?;
    let lock_directory = coordination_home.session_lock_directory()?;
    let cross_process =
        CrossProcessFileLock::acquire_in(&lock_directory, "session-operation.lock", "会话写操作")?;
    coordination_home.validate()?;
    ensure_codex_home_identity(codex_home, expected_source_key)?;
    Ok(SessionMutationLease {
        _cross_process: cross_process,
        coordination_home,
        _in_process: in_process,
    })
}

fn session_operation_lock_path(codex_home: &Path) -> PathBuf {
    codex_home
        .join("backups_state")
        .join("codex-token-bar")
        .join("session-operation.lock")
}

#[derive(Clone, Copy)]
enum OfficialMutation {
    Archive,
    Unarchive,
    Delete,
}

#[derive(Clone, Copy)]
enum ReversibleMutation {
    Archive,
    Unarchive,
}

impl ReversibleMutation {
    fn official(self) -> OfficialMutation {
        match self {
            Self::Archive => OfficialMutation::Archive,
            Self::Unarchive => OfficialMutation::Unarchive,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct DeletionImpact {
    requested_ids: Vec<String>,
    effective_root_ids: Vec<String>,
    affected_ids: Vec<String>,
    external_fork_reference_ids: Vec<String>,
    total_bytes: Option<u64>,
    descendants_by_root: HashMap<String, HashSet<String>>,
}

struct StrictOfficialDirectory {
    catalog: SessionManagementCatalog,
    official_parent_by_id: HashMap<String, Option<String>>,
}

struct FrozenSessionProtocol {
    active: Option<Vec<Value>>,
    archived: Option<Vec<Value>>,
}

impl SessionProtocol for FrozenSessionProtocol {
    fn list_threads(&mut self, archived: bool) -> Result<Vec<Value>, String> {
        if archived {
            self.archived
                .take()
                .ok_or_else(|| "官方归档会话目录被重复读取".to_string())
        } else {
            self.active
                .take()
                .ok_or_else(|| "官方活动会话目录被重复读取".to_string())
        }
    }
}

impl DeletionImpact {
    fn covered_by(&self, root_id: &str, thread_id: &str) -> bool {
        self.descendants_by_root
            .get(root_id)
            .is_some_and(|ids| ids.contains(thread_id))
    }
}

fn load_strict_official_directory(codex_home: &Path) -> Result<StrictOfficialDirectory, String> {
    let mut protocol = ProcessAppServer::launch(codex_home)?;
    protocol.initialize()?;
    let active = protocol.list_threads(false)?;
    let archived = protocol.list_threads(true)?;
    load_strict_official_directory_from_rows(codex_home, active, archived)
}

fn load_strict_official_directory_from_rows(
    codex_home: &Path,
    active: Vec<Value>,
    archived: Vec<Value>,
) -> Result<StrictOfficialDirectory, String> {
    let mut official_parent_by_id = HashMap::<String, Option<String>>::new();
    for (archived_state, rows) in [(false, &active), (true, &archived)] {
        for row in rows {
            let thread = parse_protocol_thread(row, archived_state)
                .ok_or_else(|| "Codex thread/list 返回缺少有效 ID 的会话行".to_string())?;
            if official_parent_by_id
                .insert(thread.id.clone(), thread.parent_thread_id.clone())
                .is_some()
            {
                return Err(format!(
                    "Codex 官方完整目录中会话 {} 重复出现，已拒绝危险操作",
                    thread.id
                ));
            }
        }
    }
    validate_official_parent_graph(&official_parent_by_id)?;

    let scan = scan_rollout_supplements(codex_home);
    if !scan.warnings.is_empty() {
        return Err(format!(
            "只读 rollout 扫描未能完整证明会话路径唯一：{}",
            scan.warnings.join("；")
        ));
    }
    if !scan.ambiguous_ids.is_empty() {
        let mut ids: Vec<_> = scan.ambiguous_ids.into_iter().collect();
        ids.sort();
        return Err(format!(
            "同一会话 ID 对应多个 rollout，已拒绝危险操作：{}",
            ids.join("、")
        ));
    }
    for (thread_id, local) in &scan.supplements {
        let local_parent = local.parent_thread_id.as_ref();
        let Some(official_parent) = official_parent_by_id.get(thread_id) else {
            if let Some(parent_id) = local_parent {
                return Err(format!(
                    "本地 rollout 会话 {thread_id} 指向 {parent_id}，但该会话不在 Codex 官方完整目录中"
                ));
            }
            continue;
        };
        if local_parent != official_parent.as_ref() {
            return Err(format!(
                "会话 {thread_id} 的本地 parent 边与官方 ancestorThreadId 不一致：本地 {}，官方 {}",
                local_parent.map(String::as_str).unwrap_or("无"),
                official_parent.as_deref().unwrap_or("无")
            ));
        }
        if let Some(parent_id) = local_parent {
            if !official_parent_by_id.contains_key(parent_id) {
                return Err(format!(
                    "本地 rollout 会话 {thread_id} 指向未知 parent {parent_id}"
                ));
            }
        }
    }

    let mut frozen = FrozenSessionProtocol {
        active: Some(active),
        archived: Some(archived),
    };
    let catalog = list_catalog_with_protocol(codex_home, &mut frozen)?;
    Ok(StrictOfficialDirectory {
        catalog,
        official_parent_by_id,
    })
}

fn validate_official_parent_graph(
    official_parent_by_id: &HashMap<String, Option<String>>,
) -> Result<(), String> {
    for (thread_id, parent_id) in official_parent_by_id {
        if let Some(parent_id) = parent_id {
            if !official_parent_by_id.contains_key(parent_id) {
                return Err(format!(
                    "Codex 官方目录中会话 {thread_id} 的 ancestorThreadId 指向未知会话 {parent_id}"
                ));
            }
        }
    }
    ensure_acyclic_official_parent_graph(official_parent_by_id)?;
    Ok(())
}

fn ensure_acyclic_official_parent_graph(
    parent_by_id: &HashMap<String, Option<String>>,
) -> Result<(), String> {
    for start in parent_by_id.keys() {
        let mut seen = HashSet::new();
        let mut current = Some(start.as_str());
        while let Some(thread_id) = current {
            if !seen.insert(thread_id) {
                return Err(format!("Codex 官方 ancestorThreadId 图包含环：{thread_id}"));
            }
            current = parent_by_id
                .get(thread_id)
                .and_then(|parent| parent.as_deref());
        }
    }
    Ok(())
}

fn same_unique_ids(left: &[String], right: &[String]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let left: HashSet<&str> = left.iter().map(String::as_str).collect();
    let right: HashSet<&str> = right.iter().map(String::as_str).collect();
    left.len() == right.len() && left == right
}

fn ensure_same_delete_impact_scope(
    expected: &DeletionImpact,
    current: &DeletionImpact,
    context: &str,
) -> Result<(), String> {
    if expected.requested_ids != current.requested_ids
        || expected.effective_root_ids != current.effective_root_ids
        || expected.affected_ids != current.affected_ids
        || expected.descendants_by_root != current.descendants_by_root
    {
        return Err(format!(
            "{context}：原为 {} 个请求/{} 个根/{} 个受影响会话，现为 {} 个请求/{} 个根/{} 个受影响会话；请刷新并重新确认",
            expected.requested_ids.len(),
            expected.effective_root_ids.len(),
            expected.affected_ids.len(),
            current.requested_ids.len(),
            current.effective_root_ids.len(),
            current.affected_ids.len()
        ));
    }
    Ok(())
}

fn build_delete_confirmation(
    codex_home: &Path,
    physical_home_key: &str,
    impact: &DeletionImpact,
) -> Result<SessionDeleteConfirmation, String> {
    ensure_codex_home_identity(codex_home, physical_home_key)?;
    let mut rollouts = Vec::with_capacity(impact.affected_ids.len());
    for thread_id in &impact.affected_ids {
        ensure_codex_home_identity(codex_home, physical_home_key)?;
        rollouts.push(capture_delete_rollout_snapshot(codex_home, thread_id)?);
    }
    ensure_codex_home_identity(codex_home, physical_home_key)?;
    Ok(SessionDeleteConfirmation {
        schema_version: DELETE_CONFIRMATION_SCHEMA_VERSION,
        prepared_at: unix_now(),
        physical_home_key: physical_home_key.to_string(),
        requested_ids: impact.requested_ids.clone(),
        effective_root_ids: impact.effective_root_ids.clone(),
        affected_ids: impact.affected_ids.clone(),
        rollouts,
    })
}

fn validate_delete_confirmation(
    codex_home: &Path,
    expected_physical_home_key: &str,
    impact: &DeletionImpact,
    confirmation: &SessionDeleteConfirmation,
) -> Result<(), String> {
    if confirmation.schema_version != DELETE_CONFIRMATION_SCHEMA_VERSION {
        return Err(format!(
            "删除确认版本不受支持：期望 {}，实际 {}",
            DELETE_CONFIRMATION_SCHEMA_VERSION, confirmation.schema_version
        ));
    }
    if confirmation.prepared_at <= 0 {
        return Err("删除确认缺少有效准备时间".into());
    }
    if confirmation.physical_home_key != expected_physical_home_key {
        return Err("删除确认绑定的 Codex Home 与当前来源令牌不一致".into());
    }
    ensure_codex_home_identity(codex_home, &confirmation.physical_home_key)?;
    validate_delete_confirmation_scope(impact, confirmation)?;
    validate_confirmation_rollout_subset(codex_home, confirmation, &impact.affected_ids)?;
    Ok(())
}

fn validate_delete_confirmation_scope(
    impact: &DeletionImpact,
    confirmation: &SessionDeleteConfirmation,
) -> Result<(), String> {
    if confirmation.requested_ids != impact.requested_ids
        || confirmation.effective_root_ids != impact.effective_root_ids
        || confirmation.affected_ids != impact.affected_ids
    {
        return Err(format!(
            "官方递归删除范围已变化：确认时 {} 个请求/{} 个根/{} 个会话，当前 {} 个请求/{} 个根/{} 个会话；请刷新并重新确认",
            confirmation.requested_ids.len(),
            confirmation.effective_root_ids.len(),
            confirmation.affected_ids.len(),
            impact.requested_ids.len(),
            impact.effective_root_ids.len(),
            impact.affected_ids.len()
        ));
    }
    Ok(())
}

fn validate_confirmation_rollout_subset(
    codex_home: &Path,
    confirmation: &SessionDeleteConfirmation,
    thread_ids: &[String],
) -> Result<(), String> {
    if confirmation.rollouts.len() != confirmation.affected_ids.len()
        || confirmation
            .rollouts
            .iter()
            .map(|snapshot| snapshot.thread_id.as_str())
            .ne(confirmation.affected_ids.iter().map(String::as_str))
    {
        return Err("删除确认中的 rollout 快照未与完整 affected 顺序一一对应".into());
    }
    let requested: HashSet<&str> = thread_ids.iter().map(String::as_str).collect();
    if requested.len() != thread_ids.len()
        || !requested
            .iter()
            .all(|thread_id| confirmation.affected_ids.iter().any(|id| id == thread_id))
    {
        return Err("删除确认复验范围包含重复或未确认会话".into());
    }
    for expected in confirmation
        .rollouts
        .iter()
        .filter(|snapshot| requested.contains(snapshot.thread_id.as_str()))
    {
        let current = capture_delete_rollout_snapshot(codex_home, &expected.thread_id)?;
        if &current != expected {
            return Err(format!(
                "会话 {} 的规范路径、物理身份、大小、修改时间或 SHA-256 已变化；请刷新并重新确认",
                expected.thread_id
            ));
        }
    }
    Ok(())
}

fn capture_delete_rollout_snapshot(
    codex_home: &Path,
    thread_id: &str,
) -> Result<SessionDeleteRolloutSnapshot, String> {
    validate_thread_id(thread_id)?;
    let rollout = resolve_verified_rollout(codex_home, thread_id)?;
    let canonical_home = codex_home
        .canonicalize()
        .map_err(|error| format!("规范化 Codex Home 失败：{error}"))?;
    let relative = rollout
        .strip_prefix(&canonical_home)
        .map_err(|_| "rollout 不在当前 Codex Home 内".to_string())?
        .to_string_lossy()
        .replace('\\', "/");
    let mut source = open_rollout_source(&rollout)?;
    let before = rollout_source_snapshot_from_file(&source)?;
    let meta = read_session_meta_from_reader(
        source
            .try_clone()
            .map_err(|error| format!("复制 rollout 文件句柄失败：{error}"))?,
    )
    .map_err(|error| format!("无法验证 rollout 首行身份：{error}"))?;
    if meta.id != thread_id {
        return Err(format!(
            "rollout 首行 ID 与目标会话不一致：期望 {thread_id}，实际 {}",
            meta.id
        ));
    }
    source
        .seek(SeekFrom::Start(0))
        .map_err(|error| format!("重置 rollout 读取位置失败：{error}"))?;
    let digest = sha256_reader(&mut source)?;
    let after = rollout_source_snapshot_from_file(&source)?;
    let current_path = resolve_verified_rollout(codex_home, thread_id)?;
    if current_path != rollout {
        return Err("rollout 在建立删除确认快照期间改变了规范路径".into());
    }
    let mut current = open_rollout_source(&current_path)?;
    let current_snapshot = rollout_source_snapshot_from_file(&current)?;
    current
        .seek(SeekFrom::Start(0))
        .map_err(|error| format!("重置当前 rollout 读取位置失败：{error}"))?;
    let current_digest = sha256_reader(&mut current)?;
    if before != after || before != current_snapshot || digest != current_digest {
        return Err("rollout 在建立删除确认快照期间发生变化".into());
    }
    Ok(delete_rollout_snapshot_value(
        thread_id, relative, &before, digest,
    ))
}

fn delete_rollout_snapshot_value(
    thread_id: &str,
    canonical_relative_path: String,
    snapshot: &RolloutSourceSnapshot,
    sha256: String,
) -> SessionDeleteRolloutSnapshot {
    SessionDeleteRolloutSnapshot {
        thread_id: thread_id.to_string(),
        canonical_relative_path,
        physical_identity: rollout_physical_identity(snapshot),
        size_bytes: snapshot.bytes.to_string(),
        modified_nanos: snapshot.modified_nanos.map(|value| value.to_string()),
        sha256,
    }
}

fn rollout_physical_identity(snapshot: &RolloutSourceSnapshot) -> String {
    #[cfg(unix)]
    {
        return format!("unix:{}:{}", snapshot.device, snapshot.inode);
    }
    #[cfg(windows)]
    {
        return format!(
            "windows:{}:{}",
            snapshot.volume_serial_number, snapshot.file_id
        );
    }
    #[cfg(not(any(unix, windows)))]
    {
        format!(
            "portable:{}:{}",
            snapshot.bytes,
            snapshot
                .modified_nanos
                .map(|value| value.to_string())
                .unwrap_or_else(|| "unknown".into())
        )
    }
}

fn deletion_impact(
    threads: &[SessionManagementThread],
    thread_ids: Vec<String>,
) -> Result<DeletionImpact, String> {
    let requested_ids = deduplicated_ids(thread_ids);
    let by_id: HashMap<&str, &SessionManagementThread> = threads
        .iter()
        .map(|thread| (thread.id.as_str(), thread))
        .collect();
    if let Some(missing) = requested_ids
        .iter()
        .find(|id| !by_id.contains_key(id.as_str()))
    {
        return Err(format!("官方会话目录中不存在会话 {missing}"));
    }
    let mut children = HashMap::<&str, Vec<&str>>::new();
    for thread in threads {
        if let Some(parent) = thread.parent_thread_id.as_deref() {
            if by_id.contains_key(parent) {
                children.entry(parent).or_default().push(thread.id.as_str());
            }
        }
    }
    for values in children.values_mut() {
        values.sort_unstable();
        values.dedup();
    }
    let closure = |root: &str| -> HashSet<String> {
        let mut result = HashSet::new();
        let mut pending = vec![root];
        while let Some(current) = pending.pop() {
            if !result.insert(current.to_string()) {
                continue;
            }
            if let Some(next) = children.get(current) {
                pending.extend(next.iter().rev().copied());
            }
        }
        result
    };

    // Keep only roots that are not already covered by another selected root.
    // If a parent appears after its child, it replaces that child. Cycles are
    // safe because the first selected member covers the rest.
    let mut effective_root_ids: Vec<String> = Vec::new();
    let mut descendants_by_root = HashMap::<String, HashSet<String>>::new();
    for selected in &requested_ids {
        if effective_root_ids.iter().any(|root| {
            descendants_by_root
                .get(root)
                .is_some_and(|ids| ids.contains(selected))
        }) {
            continue;
        }
        let selected_closure = closure(selected);
        effective_root_ids.retain(|root| !selected_closure.contains(root));
        descendants_by_root.retain(|root, _| effective_root_ids.contains(root));
        descendants_by_root.insert(selected.clone(), selected_closure);
        effective_root_ids.push(selected.clone());
    }

    let mut affected_ids = Vec::new();
    let mut affected_set = HashSet::new();
    for root in &effective_root_ids {
        let mut ids: Vec<String> = descendants_by_root
            .get(root)
            .into_iter()
            .flat_map(|ids| ids.iter().cloned())
            .collect();
        ids.sort();
        if let Some(position) = ids.iter().position(|id| id == root) {
            let root_id = ids.remove(position);
            ids.insert(0, root_id);
        }
        for id in ids {
            if affected_set.insert(id.clone()) {
                affected_ids.push(id);
            }
        }
    }
    let mut external_fork_reference_ids: Vec<String> = threads
        .iter()
        .filter(|thread| {
            !affected_set.contains(&thread.id)
                && thread
                    .forked_from_id
                    .as_ref()
                    .is_some_and(|parent| affected_set.contains(parent))
        })
        .map(|thread| thread.id.clone())
        .collect();
    external_fork_reference_ids.sort();
    let total_bytes = if affected_ids.iter().all(|id| {
        by_id
            .get(id.as_str())
            .and_then(|thread| thread.file_bytes)
            .is_some()
    }) {
        affected_ids.iter().try_fold(0_u64, |sum, id| {
            sum.checked_add(
                by_id
                    .get(id.as_str())
                    .and_then(|thread| thread.file_bytes)
                    .unwrap_or_default(),
            )
        })
    } else {
        None
    };
    Ok(DeletionImpact {
        requested_ids,
        effective_root_ids,
        affected_ids,
        external_fork_reference_ids,
        total_bytes,
        descendants_by_root,
    })
}

fn failed_batch(thread_ids: &[String], error: String) -> SessionBatchActionResult {
    SessionBatchActionResult {
        results: thread_ids
            .iter()
            .map(|thread_id| SessionActionItemResult {
                thread_id: thread_id.clone(),
                ok: false,
                message: Some(error.clone()),
                recovery_archive_path: None,
            })
            .collect(),
        warnings: Vec::new(),
    }
}

fn failed_batch_with_recovery(
    thread_ids: &[String],
    error: String,
    recovery_paths: &HashMap<String, String>,
) -> SessionBatchActionResult {
    let mut warnings: Vec<String> = recovery_paths
        .iter()
        .map(|(thread_id, path)| format!("删除未开始，但恢复包已完整校验：{thread_id} → {path}"))
        .collect();
    warnings.sort();
    SessionBatchActionResult {
        results: thread_ids
            .iter()
            .map(|thread_id| SessionActionItemResult {
                thread_id: thread_id.clone(),
                ok: false,
                message: Some(error.clone()),
                recovery_archive_path: recovery_paths.get(thread_id).cloned(),
            })
            .collect(),
        warnings,
    }
}

fn ensure_codex_home_identity(codex_home: &Path, expected_source_key: &str) -> Result<(), String> {
    if expected_source_key.trim().is_empty() {
        return Err("Codex Home 物理来源标识为空，已拒绝危险操作".into());
    }
    let current = crate::commands::dashboard::physical_home_key(codex_home)?;
    if current != expected_source_key {
        return Err(format!(
            "Codex Home 物理身份已变化：期望 {expected_source_key}，实际 {current}；已拒绝危险操作"
        ));
    }
    Ok(())
}

fn prepare_delete_impact(
    codex_home: &Path,
    thread_ids: &[String],
    expected_source_key: &str,
) -> Result<DeletionImpact, String> {
    ensure_codex_home_identity(codex_home, expected_source_key)?;
    let mut protocol = ProcessAppServer::launch(codex_home)?;
    protocol.initialize()?;
    let active = protocol.list_threads(false)?;
    let archived = protocol.list_threads(true)?;
    let directory = load_strict_official_directory_from_rows(codex_home, active, archived)?;
    let impact = deletion_impact(&directory.catalog.threads, thread_ids.to_vec())?;
    for root_id in &impact.effective_root_ids {
        let rows = protocol.list_descendants(root_id)?;
        validate_ancestor_query_rows(
            root_id,
            &rows,
            &directory.official_parent_by_id,
            impact
                .descendants_by_root
                .get(root_id)
                .ok_or_else(|| format!("删除根 {root_id} 缺少冻结闭包"))?,
        )?;
    }
    let by_id: HashMap<&str, &SessionManagementThread> = directory
        .catalog
        .threads
        .iter()
        .map(|thread| (thread.id.as_str(), thread))
        .collect();
    for affected_id in &impact.affected_ids {
        let thread = by_id
            .get(affected_id.as_str())
            .ok_or_else(|| format!("受影响会话 {affected_id} 已从目录消失"))?;
        if !thread.protection_reasons.is_empty() {
            return Err(format!(
                "受影响会话 {affected_id} 当前受保护：{}",
                thread.protection_reasons.join("；")
            ));
        }
        if normalize_status(&thread.status) != "notloaded" {
            return Err(format!(
                "受影响会话 {affected_id} 的实时状态为 {}；只有 notLoaded 会话可删除",
                thread.status
            ));
        }
    }
    for affected_id in &impact.affected_ids {
        ensure_codex_home_identity(codex_home, expected_source_key)?;
        revalidate_mutation_safety(codex_home, affected_id)?;
    }
    ensure_codex_home_identity(codex_home, expected_source_key)?;
    Ok(impact)
}

fn validate_ancestor_query_rows(
    root_id: &str,
    rows: &[Value],
    official_parent_by_id: &HashMap<String, Option<String>>,
    expected_closure: &HashSet<String>,
) -> Result<(), String> {
    let mut query_ids = HashSet::new();
    for row in rows {
        let thread = parse_protocol_thread(row, false).ok_or_else(|| {
            format!("thread/list ancestorThreadId={root_id} 返回缺少有效 ID 的会话行")
        })?;
        if !query_ids.insert(thread.id.clone()) {
            return Err(format!(
                "thread/list ancestorThreadId={root_id} 重复返回会话 {}",
                thread.id
            ));
        }
        let official_parent = official_parent_by_id.get(&thread.id).ok_or_else(|| {
            format!(
                "thread/list ancestorThreadId={root_id} 返回官方完整目录未知会话 {}",
                thread.id
            )
        })?;
        if official_parent != &thread.parent_thread_id {
            return Err(format!(
                "thread/list ancestorThreadId={root_id} 返回的会话 {} parent 与官方完整目录不一致",
                thread.id
            ));
        }
    }
    query_ids.insert(root_id.to_string());
    if &query_ids != expected_closure {
        return Err(format!(
            "thread/list ancestorThreadId={root_id} 返回的递归闭包已变化：期望 {} 个会话，实际 {} 个会话",
            expected_closure.len(),
            query_ids.len()
        ));
    }
    Ok(())
}

fn expected_affected_for_roots(frozen: &DeletionImpact, root_ids: &[String]) -> Vec<String> {
    let expected: HashSet<&str> = root_ids
        .iter()
        .flat_map(|root_id| {
            frozen
                .descendants_by_root
                .get(root_id)
                .into_iter()
                .flat_map(|ids| ids.iter().map(String::as_str))
        })
        .collect();
    frozen
        .affected_ids
        .iter()
        .filter(|id| expected.contains(id.as_str()))
        .cloned()
        .collect()
}

fn validate_remaining_delete_plan(
    current: &DeletionImpact,
    expected_root_ids: &[String],
    expected_affected_ids: &[String],
) -> Result<(), String> {
    if !same_unique_ids(&current.effective_root_ids, expected_root_ids)
        || !same_unique_ids(&current.affected_ids, expected_affected_ids)
    {
        return Err(format!(
            "官方递归删除剩余范围已变化：期望 {} 个根/{} 个会话，当前 {} 个根/{} 个会话",
            expected_root_ids.len(),
            expected_affected_ids.len(),
            current.effective_root_ids.len(),
            current.affected_ids.len()
        ));
    }
    Ok(())
}

fn verify_official_ids_absent(codex_home: &Path, thread_ids: &[String]) -> Result<(), String> {
    let directory = load_strict_official_directory(codex_home)?;
    let mut remaining: Vec<String> = thread_ids
        .iter()
        .filter(|thread_id| {
            directory
                .official_parent_by_id
                .contains_key(thread_id.as_str())
        })
        .cloned()
        .collect();
    remaining.sort();
    remaining.dedup();
    if remaining.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "官方完整目录仍包含冻结删除范围中的会话：{}",
            remaining.join("、")
        ))
    }
}

fn run_batch_mutation(
    codex_home: &Path,
    thread_ids: Vec<String>,
    mutation: ReversibleMutation,
    expected_source_key: &str,
) -> SessionBatchActionResult {
    collect_batch_results(thread_ids, |thread_id| {
        mutate_one(codex_home, thread_id, mutation, expected_source_key)
    })
}

fn collect_batch_results(
    thread_ids: Vec<String>,
    mut action: impl FnMut(&str) -> Result<(String, Option<String>), String>,
) -> SessionBatchActionResult {
    let mut stopped = false;
    let mut results = Vec::new();
    for thread_id in deduplicated_ids(thread_ids) {
        if stopped {
            results.push(SessionActionItemResult {
                thread_id,
                ok: false,
                message: Some("前一项写操作失败或结果不确定，本项未执行".into()),
                recovery_archive_path: None,
            });
            continue;
        }
        match action(&thread_id) {
            Ok((message, recovery_archive_path)) => results.push(SessionActionItemResult {
                thread_id,
                ok: true,
                message: Some(message),
                recovery_archive_path,
            }),
            Err(error) => {
                stopped = true;
                results.push(SessionActionItemResult {
                    thread_id,
                    ok: false,
                    message: Some(error),
                    recovery_archive_path: None,
                });
            }
        }
    }
    SessionBatchActionResult {
        results,
        warnings: Vec::new(),
    }
}

fn mutate_one(
    codex_home: &Path,
    thread_id: &str,
    mutation: ReversibleMutation,
    expected_source_key: &str,
) -> Result<(String, Option<String>), String> {
    ensure_codex_home_identity(codex_home, expected_source_key)?;
    validate_thread_id(thread_id)?;
    let catalog = list_catalog(codex_home)?;
    let before = catalog
        .threads
        .iter()
        .find(|thread| thread.id == thread_id)
        .ok_or_else(|| "官方会话目录中不存在该会话".to_string())?;
    if !before.protection_reasons.is_empty() {
        return Err(format!(
            "会话当前受保护：{}",
            before.protection_reasons.join("；")
        ));
    }
    revalidate_mutation_safety(codex_home, thread_id)?;
    match mutation {
        ReversibleMutation::Archive if before.archived => {
            return Err("会话已经处于官方归档中".into())
        }
        ReversibleMutation::Unarchive if !before.archived => {
            return Err("会话当前不在官方归档中".into())
        }
        _ => {}
    }
    revalidate_mutation_safety(codex_home, thread_id)?;
    ensure_codex_home_identity(codex_home, expected_source_key)?;
    run_official_cli(codex_home, thread_id, mutation.official())?;
    ensure_codex_home_identity(codex_home, expected_source_key)
        .map_err(|error| format!("官方命令可能已执行，但 Codex Home 身份复核失败：{error}"))?;
    let refreshed = list_catalog(codex_home)?;
    let after = refreshed
        .threads
        .iter()
        .find(|thread| thread.id == thread_id);
    let verified = match mutation {
        ReversibleMutation::Archive => after.is_some_and(|thread| thread.archived),
        ReversibleMutation::Unarchive => after.is_some_and(|thread| !thread.archived),
    };
    if !verified {
        return Err("官方命令已返回，但重新读取目录未确认目标状态；已停止后续操作".into());
    }
    let message = match mutation {
        ReversibleMutation::Archive => "已通过 Codex 官方接口归档",
        ReversibleMutation::Unarchive => "已通过 Codex 官方接口恢复",
    };
    Ok((message.into(), None))
}

fn run_official_cli(
    codex_home: &Path,
    thread_id: &str,
    mutation: OfficialMutation,
) -> Result<(), String> {
    let codex = find_codex_binary_with_report()?.path;
    let arguments: Vec<&str> = match mutation {
        OfficialMutation::Archive => vec!["archive", thread_id],
        OfficialMutation::Unarchive => vec!["unarchive", thread_id],
        OfficialMutation::Delete => vec!["delete", "--force", thread_id],
    };
    let mut command = Command::new(&codex);
    command
        .args(arguments)
        .env("CODEX_HOME", codex_home)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for key in CHILD_ENV_REMOVE {
        command.env_remove(key);
    }
    configure_hidden_child(&mut command);
    let mut child = command
        .spawn()
        .map_err(|error| format!("启动 Codex 会话命令失败：{error}"))?;
    let stdout = ProcessPipeTail::spawn(child.stdout.take(), STDERR_TAIL_LIMIT, STDERR_DRAIN_GRACE);
    let stderr = ProcessPipeTail::spawn(child.stderr.take(), STDERR_TAIL_LIMIT, STDERR_DRAIN_GRACE);
    let deadline = Instant::now() + MUTATION_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(status)) => {
                return Err(format!(
                    "Codex 会话命令失败（{status}）：{}{}",
                    stdout.text().trim(),
                    stderr.text().trim()
                ))
            }
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(50)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("Codex 会话命令超时，已终止并要求重新读取状态".into());
            }
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("等待 Codex 会话命令失败：{error}"));
            }
        }
    }
}

fn capabilities(codex_home: &Path) -> SessionManagementCapabilities {
    let available = || SessionManagementCapability {
        available: true,
        reason: None,
    };
    let official = match find_codex_binary_with_report() {
        Err(error) => SessionManagementCapability {
            available: false,
            reason: Some(format!("找不到可用 Codex CLI：{error}")),
        },
        Ok(_) => match crate::platform::codex_desktop_is_running() {
            Ok(false) => available(),
            Ok(true) => SessionManagementCapability {
                available: false,
                reason: Some(
                    "检测到 Codex 桌面端仍在运行；请先完全退出 Codex，避免跨进程 writer 冲突"
                        .into(),
                ),
            },
            Err(error) => SessionManagementCapability {
                available: false,
                reason: Some(format!("无法排除 Codex writer，已安全禁用：{error}")),
            },
        },
    };
    let _ = codex_home;
    SessionManagementCapabilities {
        official_archive: official.clone(),
        official_unarchive: official.clone(),
        official_delete: official,
        recovery_archive: available(),
        recovery_restore: SessionManagementCapability {
            available: false,
            reason: Some(
                "Codex 当前没有官方会话导入接口；为避免绕过 writer 门禁，本版不提供直接恢复".into(),
            ),
        },
        recovery_reclaim: SessionManagementCapability {
            available: false,
            reason: Some(
                "恢复包只创建和校验，不会自动删除官方会话；释放空间需另行确认并走官方删除".into(),
            ),
        },
    }
}

fn mutation_writer_gate(codex_home: &Path, thread_id: &str) -> Result<(), String> {
    match crate::platform::codex_desktop_is_running() {
        Ok(false) => {}
        Ok(true) => {
            return Err(
                "Codex 桌面端仍在运行；当前 Codex 版本缺少跨进程 owner 保护，请完全退出后重试"
                    .into(),
            )
        }
        Err(error) => return Err(format!("无法确认 Codex 桌面端状态，已拒绝写操作：{error}")),
    }
    let rollout = resolve_verified_rollout(codex_home, thread_id)?;
    let sqlite_home = crate::core::provider_repair::resolve_sqlite_home_path(codex_home)
        .map_err(|error| format!("无法确认 Codex SQLite Home，已拒绝写操作：{error}"))?;
    let candidates = vec![rollout, sqlite_home.join("state_5.sqlite")];
    let held = crate::platform::files_open_in_other_processes(&candidates)
        .map_err(|error| format!("无法检查 rollout writer，已拒绝写操作：{error}"))?;
    if !held.is_empty() {
        return Err(format!(
            "目标会话或状态库仍被其他进程打开：{}",
            held.join("；")
        ));
    }
    Ok(())
}

fn revalidate_mutation_safety(codex_home: &Path, thread_id: &str) -> Result<(), String> {
    let protected = enabled_auto_resume_threads()
        .map_err(|error| format!("无法确认自动续跑保护状态，已拒绝危险操作：{error}"))?;
    if protected.contains(thread_id) {
        return Err("会话已被启用的自动续跑任务保护".into());
    }
    let _ = resolve_verified_rollout(codex_home, thread_id)?;
    mutation_writer_gate(codex_home, thread_id)?;
    let current_status = read_thread_status(codex_home, thread_id)?;
    if current_status != "notLoaded" {
        return Err(format!(
            "写操作前实时复核发现任务状态为 {current_status}；只有 notLoaded 会话可处理"
        ));
    }
    Ok(())
}

fn resolve_verified_rollout(codex_home: &Path, thread_id: &str) -> Result<PathBuf, String> {
    let supplements = read_state_supplements(codex_home)?;
    let database_candidate = supplements
        .get(thread_id)
        .and_then(|row| row.rollout_path.as_deref())
        .map(|path| trusted_rollout_path(codex_home, path))
        .transpose()?;
    let scan = scan_rollout_supplements(codex_home);
    if !scan.warnings.is_empty() {
        return Err(format!(
            "只读 rollout 扫描不完整，无法证明会话 {thread_id} 的路径唯一：{}",
            scan.warnings.join("；")
        ));
    }
    if scan.ambiguous_ids.contains(thread_id) {
        return Err(format!(
            "会话 {thread_id} 对应多个 rollout 文件，已拒绝危险操作"
        ));
    }
    let scanned_candidate = scan
        .supplements
        .get(thread_id)
        .and_then(|row| row.rollout_path.clone());
    if database_candidate.is_some()
        && scanned_candidate.is_some()
        && database_candidate != scanned_candidate
    {
        return Err(format!(
            "会话 {thread_id} 的状态库与只读扫描指向不同 rollout，已拒绝危险操作"
        ));
    }
    let candidate = database_candidate
        .or(scanned_candidate)
        .or(find_rollout_by_id(codex_home, thread_id)?)
        .ok_or_else(|| "无法定位目标 rollout，不能验证会话身份或跨进程 writer".to_string())?;
    let meta = read_session_meta(&candidate)
        .map_err(|error| format!("无法验证 rollout 首行身份：{error}"))?;
    if meta.id != thread_id {
        return Err(format!(
            "rollout 首行 ID 与目标会话不一致：期望 {thread_id}，实际 {}",
            meta.id
        ));
    }
    Ok(candidate)
}

fn read_thread_status(codex_home: &Path, thread_id: &str) -> Result<String, String> {
    let mut protocol = ProcessAppServer::launch(codex_home)?;
    protocol.initialize()?;
    let thread = protocol.read_thread(thread_id)?;
    Ok(thread
        .pointer("/status/type")
        .and_then(Value::as_str)
        .or_else(|| thread.get("status").and_then(Value::as_str))
        .unwrap_or("unknown")
        .to_string())
}

fn enabled_auto_resume_threads() -> Result<HashSet<String>, String> {
    Ok(crate::platform::read_app_settings()?
        .auto_resume
        .resolved_tasks()
        .into_iter()
        .filter(|task| task.enabled)
        .map(|task| task.thread_id)
        .filter(|id| !id.trim().is_empty())
        .collect())
}

fn read_state_supplements(codex_home: &Path) -> Result<HashMap<String, ThreadSupplement>, String> {
    let sqlite_home = crate::core::provider_repair::resolve_sqlite_home_path(codex_home)
        .map_err(|error| format!("解析 Codex SQLite Home 失败：{error}"))?;
    let database = sqlite_home.join("state_5.sqlite");
    if !database.is_file() {
        return Ok(HashMap::new());
    }
    let connection = Connection::open_with_flags(
        &database,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|error| format!("打开 {} 失败：{error}", database.display()))?;
    let columns = sqlite_columns(&connection, "threads")?;
    if !columns.contains("id") {
        return Err("threads 表缺少 id 字段".into());
    }
    let expression = |name: &str, default: &str| {
        if columns.contains(name) {
            format!("\"{name}\"")
        } else {
            default.to_string()
        }
    };
    let query = format!(
        "SELECT {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {} FROM threads",
        expression("id", "''"),
        expression("rollout_path", "NULL"),
        expression("title", "''"),
        expression("preview", "''"),
        expression("first_user_message", "''"),
        expression("cwd", "''"),
        expression("created_at", "NULL"),
        expression("updated_at", "NULL"),
        expression("recency_at", "NULL"),
        expression("archived", "0"),
        expression("archived_at", "NULL"),
        expression("tokens_used", "NULL"),
        expression("source", "''"),
        expression("model", "''"),
    );
    let mut statement = connection
        .prepare(&query)
        .map_err(|error| format!("准备会话状态查询失败：{error}"))?;
    let rows = statement
        .query_map([], |row| {
            let id: String = row.get(0)?;
            let rollout: Option<String> = row.get(1)?;
            Ok((
                id,
                ThreadSupplement {
                    rollout_path: rollout
                        .filter(|value| !value.trim().is_empty())
                        .map(PathBuf::from),
                    title: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                    preview: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
                    first_user_message: row.get::<_, Option<String>>(4)?.unwrap_or_default(),
                    cwd: row.get::<_, Option<String>>(5)?.unwrap_or_default(),
                    created_at: sqlite_optional_i64(row, 6),
                    updated_at: sqlite_optional_i64(row, 7),
                    recency_at: sqlite_optional_i64(row, 8),
                    archived: sqlite_optional_i64(row, 9).unwrap_or(0) != 0,
                    archived_at: row.get::<_, Option<i64>>(10).unwrap_or(None),
                    tokens_used: sqlite_optional_i64(row, 11),
                    source: row.get::<_, Option<String>>(12)?.unwrap_or_default(),
                    model: row.get::<_, Option<String>>(13)?.unwrap_or_default(),
                    ..ThreadSupplement::default()
                },
            ))
        })
        .map_err(|error| format!("读取会话状态失败：{error}"))?;
    let mut result = HashMap::new();
    for row in rows {
        let (id, supplement) = row.map_err(|error| format!("解码会话状态失败：{error}"))?;
        if !id.trim().is_empty() {
            result.insert(id, supplement);
        }
    }
    Ok(result)
}

fn scan_rollout_supplements(codex_home: &Path) -> RolloutScan {
    let mut result = HashMap::new();
    let mut ambiguous_ids = HashSet::new();
    let mut warnings = Vec::new();
    for (root, archived) in [
        (codex_home.join("sessions"), false),
        (codex_home.join("archived_sessions"), true),
    ] {
        if !root.is_dir() {
            continue;
        }
        let mut pending = vec![root];
        while let Some(directory) = pending.pop() {
            let entries = match fs::read_dir(&directory) {
                Ok(entries) => entries,
                Err(error) => {
                    warnings.push(format!("只读扫描无法读取 {}：{error}", directory.display()));
                    continue;
                }
            };
            for entry in entries {
                let entry = match entry {
                    Ok(entry) => entry,
                    Err(error) => {
                        warnings.push(format!("只读扫描目录项失败：{error}"));
                        continue;
                    }
                };
                let file_type = match entry.file_type() {
                    Ok(file_type) => file_type,
                    Err(error) => {
                        warnings.push(format!(
                            "只读扫描无法读取 {} 的类型：{error}",
                            entry.path().display()
                        ));
                        continue;
                    }
                };
                if file_type.is_symlink() {
                    warnings.push(format!(
                        "只读扫描拒绝符号链接或重解析 rollout 路径：{}",
                        entry.path().display()
                    ));
                    continue;
                }
                if file_type.is_dir() {
                    pending.push(entry.path());
                    continue;
                }
                if !file_type.is_file()
                    || entry.path().extension().and_then(|value| value.to_str()) != Some("jsonl")
                {
                    continue;
                }
                let path = match trusted_rollout_path(codex_home, &entry.path()) {
                    Ok(path) => path,
                    Err(error) => {
                        warnings.push(format!(
                            "只读扫描拒绝不可信 rollout {}：{error}",
                            entry.path().display()
                        ));
                        continue;
                    }
                };
                let meta = match read_session_meta(&path) {
                    Ok(meta) if !meta.id.trim().is_empty() => meta,
                    Ok(_) => {
                        warnings.push(format!(
                            "只读扫描发现缺少会话 ID 的 rollout：{}",
                            path.display()
                        ));
                        continue;
                    }
                    Err(error) => {
                        warnings.push(format!(
                            "只读扫描无法解析 {} 的首行：{error}",
                            path.display()
                        ));
                        continue;
                    }
                };
                let metadata = fs::metadata(&path).ok();
                let modified = metadata
                    .as_ref()
                    .and_then(|metadata| metadata.modified().ok())
                    .and_then(system_time_unix);
                let created = metadata
                    .as_ref()
                    .and_then(|metadata| metadata.created().ok())
                    .and_then(system_time_unix);
                let id = meta.id.clone();
                let candidate = ThreadSupplement {
                    rollout_path: Some(path),
                    cwd: meta.cwd,
                    created_at: created,
                    updated_at: modified,
                    recency_at: modified,
                    archived,
                    session_id: meta.session_id,
                    forked_from_id: meta.forked_from_id,
                    parent_thread_id: meta.parent_thread_id,
                    ..ThreadSupplement::default()
                };
                match result
                    .get(&id)
                    .and_then(|row: &ThreadSupplement| row.rollout_path.as_ref())
                {
                    Some(existing) if candidate.rollout_path.as_ref() != Some(existing) => {
                        ambiguous_ids.insert(id.clone());
                        warnings.push(format!(
                            "只读扫描发现会话 {id} 对应多个 rollout：{} 与 {}；危险操作已安全关闭",
                            existing.display(),
                            candidate
                                .rollout_path
                                .as_deref()
                                .map(Path::display)
                                .map(|value| value.to_string())
                                .unwrap_or_else(|| "未知路径".into())
                        ));
                    }
                    Some(_) => {}
                    None => {
                        result.insert(id, candidate);
                    }
                }
            }
        }
    }
    RolloutScan {
        supplements: result,
        ambiguous_ids,
        warnings,
    }
}

fn sqlite_columns(connection: &Connection, table: &str) -> Result<HashSet<String>, String> {
    let mut statement = connection
        .prepare(&format!("PRAGMA table_info(\"{table}\")"))
        .map_err(|error| error.to_string())?;
    let rows = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|error| error.to_string())?;
    rows.collect::<Result<HashSet<_>, _>>()
        .map_err(|error| error.to_string())
}

fn sqlite_optional_i64(row: &rusqlite::Row<'_>, index: usize) -> Option<i64> {
    row.get::<_, Option<i64>>(index).ok().flatten()
}

fn enrich_from_session_meta(
    codex_home: &Path,
    thread_id: &str,
    supplement: &mut ThreadSupplement,
    warnings: &mut Vec<String>,
) -> bool {
    let path = supplement
        .rollout_path
        .as_deref()
        .and_then(|path| trusted_rollout_path(codex_home, path).ok())
        .or_else(|| find_rollout_by_id(codex_home, thread_id).ok().flatten());
    let Some(path) = path else {
        warnings.push(format!(
            "会话 {thread_id} 缺少可信 rollout，危险操作已安全关闭"
        ));
        return false;
    };
    supplement.rollout_path = Some(path.clone());
    match read_session_meta(&path) {
        Ok(meta) if meta.id == thread_id => {
            supplement.cwd = first_non_empty(&supplement.cwd, &meta.cwd, "");
            supplement.session_id = meta.session_id;
            supplement.forked_from_id = meta.forked_from_id;
            supplement.parent_thread_id = meta.parent_thread_id;
            true
        }
        Ok(meta) => {
            warnings.push(format!(
                "会话 {thread_id} 的 rollout 首行 ID 与状态库不一致，危险操作已安全关闭：{}",
                meta.id
            ));
            false
        }
        Err(error) => {
            warnings.push(format!(
                "会话 {thread_id} 首行读取失败，危险操作已安全关闭：{error}"
            ));
            false
        }
    }
}

#[derive(Default)]
struct SessionMeta {
    id: String,
    cwd: String,
    session_id: Option<String>,
    forked_from_id: Option<String>,
    parent_thread_id: Option<String>,
}

#[derive(Deserialize)]
struct SessionMetaEnvelope {
    #[serde(rename = "type")]
    kind: String,
    payload: SessionMetaPayload,
}

#[derive(Deserialize)]
struct SessionMetaPayload {
    #[serde(default, alias = "thread_id", alias = "threadId")]
    id: String,
    #[serde(default)]
    cwd: String,
    #[serde(default, alias = "sessionId")]
    session_id: Option<String>,
    #[serde(default, alias = "forkedFromId")]
    forked_from_id: Option<String>,
    #[serde(default, alias = "parentThreadId")]
    parent_thread_id: Option<String>,
}

fn read_session_meta(path: &Path) -> Result<SessionMeta, String> {
    let file = File::open(path).map_err(|error| error.to_string())?;
    read_session_meta_from_reader(file)
}

fn read_session_meta_from_reader(reader: impl Read) -> Result<SessionMeta, String> {
    let envelope = serde_json::Deserializer::from_reader(reader)
        .into_iter::<SessionMetaEnvelope>()
        .next()
        .ok_or_else(|| "rollout 为空".to_string())?
        .map_err(|error| error.to_string())?;
    if envelope.kind != "session_meta" {
        return Err("首条记录不是 session_meta".into());
    }
    let payload = envelope.payload;
    Ok(SessionMeta {
        id: payload.id,
        cwd: payload.cwd,
        session_id: payload.session_id,
        forked_from_id: payload.forked_from_id,
        parent_thread_id: payload.parent_thread_id,
    })
}

fn rollout_stat(
    codex_home: &Path,
    rollout_path: Option<&Path>,
    thread_id: &str,
    warnings: &mut Vec<String>,
) -> (Option<u64>, Option<i64>) {
    let path = rollout_path
        .and_then(|path| trusted_rollout_path(codex_home, path).ok())
        .or_else(|| find_rollout_by_id(codex_home, thread_id).ok().flatten());
    let Some(path) = path else {
        return (None, None);
    };
    match fs::metadata(&path) {
        Ok(metadata) => (
            Some(metadata.len()),
            metadata.modified().ok().and_then(system_time_unix),
        ),
        Err(error) => {
            warnings.push(format!("会话 {thread_id} 文件属性读取失败：{error}"));
            (None, None)
        }
    }
}

fn trusted_rollout_path(codex_home: &Path, raw: &Path) -> Result<PathBuf, String> {
    if raw.components().any(|component| {
        matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        )
    }) && !raw.is_absolute()
    {
        return Err("rollout 相对路径包含越界组件".into());
    }
    let candidate = if raw.is_absolute() {
        raw.to_path_buf()
    } else {
        codex_home.join(raw)
    };
    reject_windows_reparse_components(codex_home, &candidate)?;
    let canonical = candidate
        .canonicalize()
        .map_err(|error| format!("规范化 rollout 路径失败：{error}"))?;
    let home = codex_home
        .canonicalize()
        .map_err(|error| format!("规范化 Codex Home 失败：{error}"))?;
    let sessions = home.join("sessions");
    let archived = home.join("archived_sessions");
    if !canonical.starts_with(&sessions) && !canonical.starts_with(&archived) {
        return Err(format!(
            "rollout 文件越过 Codex Home 边界：{}",
            candidate.display()
        ));
    }
    if !canonical.is_file() {
        return Err("rollout 目标不是普通文件".into());
    }
    Ok(canonical)
}

#[cfg(windows)]
fn reject_windows_reparse_components(codex_home: &Path, candidate: &Path) -> Result<(), String> {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;

    let mut current = Some(candidate);
    while let Some(path) = current {
        if path == codex_home {
            break;
        }
        let metadata = fs::symlink_metadata(path)
            .map_err(|error| format!("读取 rollout 路径属性失败：{error}"))?;
        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(format!(
                "rollout 路径包含 Windows 重解析点：{}",
                path.display()
            ));
        }
        current = path.parent();
    }
    Ok(())
}

#[cfg(not(windows))]
fn reject_windows_reparse_components(_codex_home: &Path, _candidate: &Path) -> Result<(), String> {
    Ok(())
}

fn find_rollout_by_id(codex_home: &Path, thread_id: &str) -> Result<Option<PathBuf>, String> {
    let mut matches = Vec::new();
    for root in [
        codex_home.join("sessions"),
        codex_home.join("archived_sessions"),
    ] {
        if !root.is_dir() {
            continue;
        }
        let mut pending = vec![root];
        while let Some(directory) = pending.pop() {
            let entries = fs::read_dir(&directory)
                .map_err(|error| format!("读取 {} 失败：{error}", directory.display()))?;
            for entry in entries {
                let entry = entry.map_err(|error| error.to_string())?;
                let file_type = entry.file_type().map_err(|error| error.to_string())?;
                if file_type.is_symlink() {
                    continue;
                }
                if file_type.is_dir() {
                    pending.push(entry.path());
                    continue;
                }
                let name = entry.file_name().to_string_lossy().into_owned();
                if !name.contains(thread_id) {
                    continue;
                }
                let path = trusted_rollout_path(codex_home, &entry.path())?;
                if read_session_meta(&path).is_ok_and(|meta| meta.id == thread_id) {
                    if !matches.contains(&path) {
                        matches.push(path);
                    }
                }
            }
        }
    }
    match matches.len() {
        0 => Ok(None),
        1 => Ok(matches.pop()),
        count => Err(format!(
            "会话 {thread_id} 对应 {count} 个 rollout 文件，无法安全选择"
        )),
    }
}

fn parse_protocol_thread(value: &Value, archived: bool) -> Option<ProtocolThread> {
    let id = canonical_uuid(value.get("id")?.as_str()?)?;
    let forked_from_id = optional_uuid_value_alias(value, &["forkedFromId", "forked_from_id"])?;
    let parent_thread_id =
        optional_uuid_value_alias(value, &["parentThreadId", "parent_thread_id"])?;
    let preview = value
        .get("preview")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let title = value
        .get("name")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(&preview)
        .to_string();
    Some(ProtocolThread {
        id,
        title,
        preview,
        cwd: value
            .get("cwd")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        created_at: value.get("createdAt").and_then(Value::as_i64),
        updated_at: value.get("updatedAt").and_then(Value::as_i64),
        archived,
        status: value
            .pointer("/status/type")
            .and_then(Value::as_str)
            .or_else(|| value.get("status").and_then(Value::as_str))
            .unwrap_or("unknown")
            .to_string(),
        source: source_label(value.get("source")),
        model: value
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        rollout_path: value
            .get("path")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(PathBuf::from),
        session_id: string_value_alias(value, &["sessionId", "session_id"]),
        forked_from_id,
        parent_thread_id,
    })
}

fn canonical_uuid(value: &str) -> Option<String> {
    Uuid::parse_str(value.trim())
        .ok()
        .map(|uuid| uuid.to_string())
}

fn optional_uuid_value_alias(value: &Value, keys: &[&str]) -> Option<Option<String>> {
    for key in keys {
        let Some(raw) = value.get(*key) else {
            continue;
        };
        if raw.is_null() {
            return Some(None);
        }
        let raw = raw.as_str()?;
        if raw.trim().is_empty() {
            return Some(None);
        }
        return canonical_uuid(raw).map(Some);
    }
    Some(None)
}

fn string_value_alias(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_str))
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
}

fn source_label(source: Option<&Value>) -> String {
    match source {
        Some(Value::String(value)) => value.clone(),
        Some(Value::Object(value)) => value
            .keys()
            .next()
            .cloned()
            .unwrap_or_else(|| "unknown".into()),
        _ => "unknown".into(),
    }
}

fn apply_relationship_counts(threads: &mut [SessionManagementThread]) {
    let mut spawn = HashMap::<String, u64>::new();
    let mut forks = HashMap::<String, u64>::new();
    for thread in threads.iter() {
        if let Some(parent) = thread.parent_thread_id.as_ref() {
            *spawn.entry(parent.clone()).or_default() += 1;
        }
        if let Some(parent) = thread.forked_from_id.as_ref() {
            *forks.entry(parent.clone()).or_default() += 1;
        }
    }
    for thread in threads {
        thread.spawn_child_count = spawn.get(&thread.id).copied().unwrap_or(0);
        thread.fork_child_count = forks.get(&thread.id).copied().unwrap_or(0);
    }
}

fn apply_similarity_groups(
    threads: &mut [SessionManagementThread],
    supplements: &HashMap<String, ThreadSupplement>,
) {
    let mut groups = HashMap::<String, Vec<usize>>::new();
    for (index, thread) in threads.iter().enumerate() {
        let first = supplements
            .get(&thread.id)
            .map(|row| row.first_user_message.as_str())
            .unwrap_or("");
        let normalized_title = normalize_similarity(&thread.title);
        let normalized_first = normalize_similarity(first);
        if normalized_title.is_empty() && normalized_first.is_empty() {
            continue;
        }
        let mut hasher = Sha256::new();
        hasher.update(normalized_title.as_bytes());
        hasher.update([0]);
        hasher.update(normalized_first.as_bytes());
        groups
            .entry(format!("{:x}", hasher.finalize()))
            .or_default()
            .push(index);
    }
    for (hash, indices) in groups {
        if indices.len() < 2 {
            continue;
        }
        let group_id = format!("similar-{}", &hash[..16]);
        for index in indices {
            threads[index].similarity_group_id = Some(group_id.clone());
            threads[index].similarity_reason = Some("规范化标题与首条消息一致".into());
        }
    }
}

fn normalize_similarity(value: &str) -> String {
    value
        .chars()
        .filter(|character| character.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

fn complete_prefix_end(file: &mut File, file_len: u64) -> Result<u64, String> {
    if file_len == 0 {
        return Ok(0);
    }
    file.seek(SeekFrom::Start(file_len - 1))
        .map_err(|error| error.to_string())?;
    let mut byte = [0_u8; 1];
    file.read_exact(&mut byte)
        .map_err(|error| error.to_string())?;
    if byte[0] == b'\n' {
        return Ok(file_len);
    }
    let mut cursor = file_len;
    let mut buffer = vec![0_u8; CONTEXT_READ_BUFFER];
    while cursor > 0 {
        let start = cursor.saturating_sub(buffer.len() as u64);
        let length = usize::try_from(cursor - start).map_err(|_| "文件偏移溢出")?;
        file.seek(SeekFrom::Start(start))
            .map_err(|error| error.to_string())?;
        file.read_exact(&mut buffer[..length])
            .map_err(|error| error.to_string())?;
        if let Some(index) = buffer[..length].iter().rposition(|byte| *byte == b'\n') {
            return Ok(start + index as u64 + 1);
        }
        cursor = start;
    }
    Ok(0)
}

fn previous_line_range(file: &mut File, before: u64) -> Result<Option<(u64, u64)>, String> {
    if before == 0 {
        return Ok(None);
    }
    let mut end = before;
    file.seek(SeekFrom::Start(end - 1))
        .map_err(|error| error.to_string())?;
    let mut last = [0_u8; 1];
    file.read_exact(&mut last)
        .map_err(|error| error.to_string())?;
    if last[0] == b'\n' {
        end -= 1;
    }
    if end == 0 {
        return Ok(None);
    }
    let mut cursor = end;
    let mut buffer = vec![0_u8; CONTEXT_READ_BUFFER];
    while cursor > 0 {
        let start = cursor.saturating_sub(buffer.len() as u64);
        let length = usize::try_from(cursor - start).map_err(|_| "文件偏移溢出")?;
        file.seek(SeekFrom::Start(start))
            .map_err(|error| error.to_string())?;
        file.read_exact(&mut buffer[..length])
            .map_err(|error| error.to_string())?;
        if let Some(index) = buffer[..length].iter().rposition(|byte| *byte == b'\n') {
            return Ok(Some((start + index as u64 + 1, end)));
        }
        cursor = start;
    }
    Ok(Some((0, end)))
}

fn parse_context_line(
    file: &mut File,
    start: u64,
    end: u64,
) -> Result<Option<SessionContextMessage>, String> {
    let length = end.saturating_sub(start);
    file.seek(SeekFrom::Start(start))
        .map_err(|error| error.to_string())?;
    if length > LARGE_LINE_THRESHOLD {
        return parse_large_context_line(file.take(length), start);
    }
    let length = usize::try_from(length).map_err(|_| "单行长度超过平台地址范围")?;
    let mut bytes = vec![0_u8; length];
    file.read_exact(&mut bytes)
        .map_err(|error| error.to_string())?;
    let value: Value = serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
    context_message_from_value(&value, start)
}

fn context_message_from_value(
    value: &Value,
    offset: u64,
) -> Result<Option<SessionContextMessage>, String> {
    if value.get("type").and_then(Value::as_str) != Some("response_item") {
        return Ok(None);
    }
    let payload = value
        .get("payload")
        .and_then(Value::as_object)
        .ok_or_else(|| "response_item 缺少 payload".to_string())?;
    let kind = payload
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let role = payload
        .get("role")
        .and_then(Value::as_str)
        .unwrap_or_else(|| {
            if kind.contains("function") {
                "tool"
            } else {
                "assistant"
            }
        });
    let mut content = String::new();
    collect_content(payload.get("content"), &mut content);
    if content.is_empty() {
        for key in ["text", "message", "output", "arguments", "name"] {
            collect_content(payload.get(key), &mut content);
        }
    }
    if content.trim().is_empty() {
        return Ok(None);
    }
    truncate_string_bytes(&mut content, MESSAGE_DISPLAY_BYTES);
    Ok(Some(SessionContextMessage {
        id: payload
            .get("id")
            .or_else(|| payload.get("call_id"))
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or_else(|| format!("offset-{offset}")),
        role: role.to_string(),
        content,
        timestamp: value
            .get("timestamp")
            .and_then(Value::as_str)
            .map(str::to_string),
        offset,
        kind: kind.to_string(),
    }))
}

fn collect_content(value: Option<&Value>, output: &mut String) {
    match value {
        Some(Value::String(value)) => append_content(output, value),
        Some(Value::Array(values)) => {
            for value in values {
                if let Some(text) = value
                    .get("text")
                    .or_else(|| value.get("content"))
                    .or_else(|| value.get("output"))
                    .and_then(Value::as_str)
                {
                    append_content(output, text);
                }
            }
        }
        Some(Value::Object(value)) => {
            for key in ["text", "content", "output"] {
                if let Some(text) = value.get(key).and_then(Value::as_str) {
                    append_content(output, text);
                }
            }
        }
        _ => {}
    }
}

fn append_content(output: &mut String, value: &str) {
    if !output.is_empty() {
        output.push('\n');
    }
    output.push_str(value);
}

/// Large JSONL rows are scanned as a stream. Only the small metadata fields and
/// the first display slice of text-like values are retained; the rest of the
/// row is still consumed and validated at the line boundary without allocating
/// a buffer proportional to the row size.
fn parse_large_context_line(
    reader: impl Read,
    offset: u64,
) -> Result<Option<SessionContextMessage>, String> {
    let mut scanner =
        LargeJsonStringScanner::new(BufReader::with_capacity(CONTEXT_READ_BUFFER, reader));
    let fields = scanner.scan()?;
    if fields.record_type.as_deref() != Some("response_item") {
        return Ok(None);
    }
    let kind = fields.payload_type.unwrap_or_else(|| "unknown".into());
    let role = fields.role.unwrap_or_else(|| {
        if kind.contains("function") {
            "tool".into()
        } else {
            "assistant".into()
        }
    });
    if fields.content.trim().is_empty() {
        return Ok(None);
    }
    Ok(Some(SessionContextMessage {
        id: fields.id.unwrap_or_else(|| format!("offset-{offset}")),
        role,
        content: fields.content,
        timestamp: fields.timestamp,
        offset,
        kind,
    }))
}

#[derive(Default)]
struct LargeLineFields {
    record_type: Option<String>,
    payload_type: Option<String>,
    role: Option<String>,
    id: Option<String>,
    timestamp: Option<String>,
    content: String,
}

struct LargeJsonStringScanner<R: BufRead> {
    reader: R,
    pushed: Option<u8>,
}

impl<R: BufRead> LargeJsonStringScanner<R> {
    fn new(reader: R) -> Self {
        Self {
            reader,
            pushed: None,
        }
    }

    fn scan(&mut self) -> Result<LargeLineFields, String> {
        let mut fields = LargeLineFields::default();
        let mut pending_key: Option<String> = None;
        while let Some(byte) = self.next_byte()? {
            if byte != b'"' {
                continue;
            }
            let (value, value_truncated) = self.read_json_string(MESSAGE_DISPLAY_BYTES)?;
            let next = self.next_non_whitespace()?;
            if next == Some(b':') {
                pending_key = Some(value);
                continue;
            }
            if let Some(next) = next {
                self.pushed = Some(next);
            }
            let Some(key) = pending_key.take() else {
                continue;
            };
            match key.as_str() {
                "type" if value == "response_item" => fields.record_type = Some(value),
                "type" if fields.payload_type.is_none() => fields.payload_type = Some(value),
                "role" if fields.role.is_none() => fields.role = Some(value),
                "id" | "call_id" if fields.id.is_none() => fields.id = Some(value),
                "timestamp" if fields.timestamp.is_none() => fields.timestamp = Some(value),
                "text" | "message" | "output" | "arguments" | "name" => {
                    if fields.content.len() < MESSAGE_DISPLAY_BYTES {
                        if !fields.content.is_empty() {
                            fields.content.push('\n');
                        }
                        fields.content.push_str(&value);
                        truncate_string_bytes(&mut fields.content, MESSAGE_DISPLAY_BYTES);
                        if value_truncated {
                            append_large_value_marker(&mut fields.content);
                        }
                    }
                }
                _ => {}
            }
        }
        Ok(fields)
    }

    fn next_non_whitespace(&mut self) -> Result<Option<u8>, String> {
        loop {
            match self.next_byte()? {
                Some(byte) if byte.is_ascii_whitespace() => {}
                other => return Ok(other),
            }
        }
    }

    fn next_byte(&mut self) -> Result<Option<u8>, String> {
        if self.pushed.is_some() {
            return Ok(self.pushed.take());
        }
        let buffer = self.reader.fill_buf().map_err(|error| error.to_string())?;
        let Some(byte) = buffer.first().copied() else {
            return Ok(None);
        };
        self.reader.consume(1);
        Ok(Some(byte))
    }

    fn read_json_string(&mut self, limit: usize) -> Result<(String, bool), String> {
        let mut bytes = Vec::with_capacity(limit.min(256));
        let mut escaped = false;
        let mut truncated = false;
        loop {
            let byte = self
                .next_byte()?
                .ok_or_else(|| "JSON 字符串未闭合".to_string())?;
            if escaped {
                escaped = false;
                let decoded = match byte {
                    b'"' => b'"',
                    b'\\' => b'\\',
                    b'/' => b'/',
                    b'b' => 0x08,
                    b'f' => 0x0c,
                    b'n' => b'\n',
                    b'r' => b'\r',
                    b't' => b'\t',
                    b'u' => {
                        let mut digits = [0_u8; 4];
                        for digit in &mut digits {
                            *digit = self
                                .next_byte()?
                                .ok_or_else(|| "JSON Unicode 转义不完整".to_string())?;
                        }
                        let text =
                            std::str::from_utf8(&digits).map_err(|error| error.to_string())?;
                        let scalar = u16::from_str_radix(text, 16)
                            .map_err(|error| format!("JSON Unicode 转义无效：{error}"))?;
                        if let Some(character) = char::from_u32(u32::from(scalar)) {
                            let mut encoded = [0_u8; 4];
                            let encoded = character.encode_utf8(&mut encoded).as_bytes();
                            if bytes.len() < limit {
                                bytes.extend_from_slice(
                                    &encoded[..encoded.len().min(limit - bytes.len())],
                                );
                            } else {
                                truncated = true;
                            }
                        }
                        continue;
                    }
                    _ => return Err("JSON 转义无效".into()),
                };
                if bytes.len() < limit {
                    bytes.push(decoded);
                } else {
                    truncated = true;
                }
                continue;
            }
            match byte {
                b'\\' => escaped = true,
                b'"' => break,
                value if bytes.len() < limit => bytes.push(value),
                _ => truncated = true,
            }
        }
        Ok((String::from_utf8_lossy(&bytes).into_owned(), truncated))
    }
}

fn truncate_string_bytes(value: &mut String, limit: usize) {
    if value.len() <= limit {
        return;
    }
    let mut boundary = limit;
    while boundary > 0 && !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    value.truncate(boundary);
    value.push_str("\n…（本条内容较大，当前页显示前段）");
}

fn append_large_value_marker(value: &mut String) {
    const MARKER: &str = "\n…（本条内容较大，当前页显示前段）";
    let target = MESSAGE_DISPLAY_BYTES.saturating_sub(MARKER.len());
    if value.len() > target {
        let mut boundary = target;
        while boundary > 0 && !value.is_char_boundary(boundary) {
            boundary -= 1;
        }
        value.truncate(boundary);
    }
    if !value.ends_with(MARKER) {
        value.push_str(MARKER);
    }
}

fn file_identity(path: &Path, metadata: &fs::Metadata) -> String {
    let mut hasher = Sha256::new();
    hasher.update(path.to_string_lossy().as_bytes());
    hasher.update(metadata.len().to_le_bytes());
    if let Ok(modified) = metadata.modified() {
        if let Ok(duration) = modified.duration_since(UNIX_EPOCH) {
            hasher.update(duration.as_nanos().to_le_bytes());
        }
    }
    format!("{:x}", hasher.finalize())
}

fn validate_thread_id(thread_id: &str) -> Result<(), String> {
    Uuid::parse_str(thread_id)
        .map(|_| ())
        .map_err(|_| "会话 ID 不是有效 UUID".into())
}

fn validated_unique_thread_ids(thread_ids: Vec<String>) -> Result<Vec<String>, String> {
    let mut normalized = Vec::with_capacity(thread_ids.len());
    let mut seen = HashSet::with_capacity(thread_ids.len());
    for raw in thread_ids {
        let id =
            canonical_uuid(&raw).ok_or_else(|| format!("会话 ID 不是有效 UUID：{}", raw.trim()))?;
        if !seen.insert(id.clone()) {
            return Err(format!("会话 ID 重复出现：{id}"));
        }
        normalized.push(id);
    }
    Ok(normalized)
}

fn deduplicated_ids(thread_ids: Vec<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    thread_ids
        .into_iter()
        .filter(|id| seen.insert(id.clone()))
        .collect()
}

fn first_non_empty(primary: &str, secondary: &str, fallback: &str) -> String {
    [primary, secondary, fallback]
        .into_iter()
        .find(|value| !value.trim().is_empty())
        .unwrap_or("")
        .to_string()
}

fn non_empty_option(value: &str) -> Option<String> {
    (!value.trim().is_empty()).then(|| value.to_string())
}

fn normalize_status(value: &str) -> String {
    value
        .chars()
        .filter(|character| character.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

fn status_protection_reason(status: &str) -> Option<&'static str> {
    match status {
        "notLoaded" => None,
        "active" => Some("任务仍在运行"),
        "idle" | "loaded" => Some("任务仍由 Codex 加载，当前版本只允许处理未加载会话"),
        "systemError" => Some("任务处于系统错误状态，需先在 Codex 中处理"),
        _ => Some("无法证明任务未被 Codex 加载"),
    }
}

fn system_time_unix(value: SystemTime) -> Option<i64> {
    value
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|duration| duration.as_secs().min(i64::MAX as u64) as i64)
}

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .min(i64::MAX as u64) as i64
}

struct ProcessAppServer {
    child: Child,
    stdin: std::process::ChildStdin,
    messages: mpsc::Receiver<Value>,
    stderr: ProcessPipeTail,
    next_request_id: i64,
}

struct UnavailableProtocol {
    error: String,
}

impl SessionProtocol for UnavailableProtocol {
    fn list_threads(&mut self, _archived: bool) -> Result<Vec<Value>, String> {
        Err(self.error.clone())
    }
}

impl ProcessAppServer {
    fn launch(codex_home: &Path) -> Result<Self, String> {
        let codex = find_codex_binary_with_report()?.path;
        let mut command = Command::new(codex);
        for key in CHILD_ENV_REMOVE {
            command.env_remove(key);
        }
        command
            .env("CODEX_HOME", codex_home)
            .args(["app-server", "--listen", "stdio://"]);
        configure_hidden_child(&mut command);
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| format!("启动 Codex app-server 失败：{error}"))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "Codex app-server stdin 不可用".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "Codex app-server stdout 不可用".to_string())?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| "Codex app-server stderr 不可用".to_string())?;
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if let Ok(message) = serde_json::from_str::<Value>(&line) {
                    let _ = sender.send(message);
                }
            }
        });
        Ok(Self {
            child,
            stdin,
            messages: receiver,
            stderr: ProcessPipeTail::spawn(Some(stderr), STDERR_TAIL_LIMIT, STDERR_DRAIN_GRACE),
            next_request_id: 2,
        })
    }

    fn initialize(&mut self) -> Result<(), String> {
        self.send(json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "codex-token-bar-session-manager",
                    "title": "Codex Token Bar",
                    "version": env!("CARGO_PKG_VERSION")
                },
                "capabilities": {
                    "experimentalApi": true,
                    "requestAttestation": false
                }
            }
        }))?;
        let response = self.wait_for_response(1)?;
        response_result(&response)?;
        self.send(json!({"jsonrpc": "2.0", "method": "initialized"}))
    }

    fn send(&mut self, value: Value) -> Result<(), String> {
        serde_json::to_writer(&mut self.stdin, &value).map_err(|error| error.to_string())?;
        self.stdin
            .write_all(b"\n")
            .map_err(|error| error.to_string())?;
        self.stdin.flush().map_err(|error| error.to_string())
    }

    fn wait_for_response(&mut self, request_id: i64) -> Result<Value, String> {
        let deadline = Instant::now() + APP_SERVER_TIMEOUT;
        while Instant::now() < deadline {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match self
                .messages
                .recv_timeout(remaining.min(Duration::from_millis(250)))
            {
                Ok(message) if message.get("id").and_then(Value::as_i64) == Some(request_id) => {
                    return Ok(message)
                }
                Ok(message) if message.get("id").is_some() && message.get("method").is_some() => {
                    let id = message.get("id").cloned().unwrap_or(Value::Null);
                    self.send(json!({
                        "jsonrpc": "2.0",
                        "id": id,
                        "error": {
                            "code": -32000,
                            "message": "Session management does not grant permissions or answer user input."
                        }
                    }))?;
                }
                Ok(_) => {}
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(format!("Codex app-server 提前退出{}", self.stderr_text()))
                }
            }
        }
        Err(format!(
            "等待 Codex app-server 响应超时{}",
            self.stderr_text()
        ))
    }

    fn wait_for_response_without_deadline(&mut self, request_id: i64) -> Result<Value, String> {
        loop {
            match self.messages.recv_timeout(Duration::from_millis(250)) {
                Ok(message) if message.get("id").and_then(Value::as_i64) == Some(request_id) => {
                    return Ok(message)
                }
                Ok(message) if message.get("id").is_some() && message.get("method").is_some() => {
                    let id = message.get("id").cloned().unwrap_or(Value::Null);
                    self.send(json!({
                        "jsonrpc": "2.0",
                        "id": id,
                        "error": {
                            "code": -32000,
                            "message": "Session management does not grant permissions or answer user input."
                        }
                    }))?;
                }
                Ok(_) => {}
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if let Some(status) = self
                        .child
                        .try_wait()
                        .map_err(|error| format!("检查 Codex app-server 状态失败：{error}"))?
                    {
                        return Err(format!(
                            "Codex app-server 在完整目录读取期间退出（{status}）{}",
                            self.stderr_text()
                        ));
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(format!("Codex app-server 提前退出{}", self.stderr_text()))
                }
            }
        }
    }

    fn request_page(
        &mut self,
        archived: bool,
        cursor: Option<&str>,
        ancestor_thread_id: Option<&str>,
    ) -> Result<Value, String> {
        let request_id = self.next_request_id;
        self.next_request_id = self
            .next_request_id
            .checked_add(1)
            .ok_or_else(|| "Codex app-server 请求编号溢出".to_string())?;
        let params = thread_list_params(archived, cursor, ancestor_thread_id);
        self.send(json!({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/list",
            "params": params
        }))?;
        let response = self.wait_for_response_without_deadline(request_id)?;
        response_result(&response).cloned()
    }

    fn list_descendants(&mut self, ancestor_thread_id: &str) -> Result<Vec<Value>, String> {
        let mut rows = Vec::new();
        for archived in [false, true] {
            rows.extend(collect_all_thread_pages(|cursor| {
                self.request_page(archived, cursor, Some(ancestor_thread_id))
            })?);
        }
        Ok(rows)
    }

    fn read_thread(&mut self, thread_id: &str) -> Result<Value, String> {
        let request_id = self.next_request_id;
        self.next_request_id = self
            .next_request_id
            .checked_add(1)
            .ok_or_else(|| "Codex app-server 请求编号溢出".to_string())?;
        self.send(json!({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/read",
            "params": {
                "threadId": thread_id,
                "includeTurns": false
            }
        }))?;
        let response = self.wait_for_response(request_id)?;
        response_result(&response)?
            .get("thread")
            .cloned()
            .ok_or_else(|| "Codex thread/read 响应缺少 thread".into())
    }

    fn stderr_text(&self) -> String {
        let text = self.stderr.text();
        if text.trim().is_empty() {
            String::new()
        } else {
            format!("；stderr：{}", text.trim())
        }
    }
}

fn thread_list_params(
    archived: bool,
    cursor: Option<&str>,
    ancestor_thread_id: Option<&str>,
) -> Value {
    let mut params = json!({
        "limit": 100,
        "archived": archived,
        "useStateDbOnly": true,
        "sourceKinds": THREAD_SOURCE_KINDS,
        "sortKey": "updated_at",
        "sortDirection": "desc"
    });
    if let Some(cursor) = cursor {
        params["cursor"] = Value::String(cursor.to_string());
    }
    if let Some(ancestor_thread_id) = ancestor_thread_id {
        params["ancestorThreadId"] = Value::String(ancestor_thread_id.to_string());
    }
    params
}

impl SessionProtocol for ProcessAppServer {
    fn list_threads(&mut self, archived: bool) -> Result<Vec<Value>, String> {
        collect_all_thread_pages(|cursor| self.request_page(archived, cursor, None))
    }
}

impl Drop for ProcessAppServer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn collect_all_thread_pages(
    mut request: impl FnMut(Option<&str>) -> Result<Value, String>,
) -> Result<Vec<Value>, String> {
    let mut rows = Vec::new();
    let mut cursor: Option<String> = None;
    let mut seen = HashSet::new();
    loop {
        let result = request(cursor.as_deref())?;
        let page = result
            .get("data")
            .and_then(Value::as_array)
            .ok_or_else(|| "Codex thread/list 响应缺少 data".to_string())?;
        rows.extend(page.iter().cloned());
        let next = result
            .get("nextCursor")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|cursor| !cursor.is_empty())
            .map(str::to_string);
        let Some(next) = next else {
            return Ok(rows);
        };
        if !seen.insert(next.clone()) {
            return Err(format!("Codex thread/list 返回重复游标：{next}"));
        }
        cursor = Some(next);
    }
}

fn response_result(message: &Value) -> Result<&Value, String> {
    if let Some(error) = message.get("error") {
        return Err(error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("Codex JSON-RPC 请求失败")
            .to_string());
    }
    message
        .get("result")
        .ok_or_else(|| "Codex JSON-RPC 响应缺少 result".into())
}

#[cfg(windows)]
fn configure_hidden_child(command: &mut Command) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    command.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
fn configure_hidden_child(_command: &mut Command) {}

#[derive(Debug)]
struct RecoveryArchiveReceipt {
    path: PathBuf,
    rollout_path: PathBuf,
    source_snapshot: RolloutSourceSnapshot,
    sha256: String,
    original_relative_path: String,
    source_handle: File,
    package_handle: File,
    package_snapshot: RolloutSourceSnapshot,
    package_sha256: String,
}

#[derive(Debug)]
struct RecoveryArchiveError {
    message: String,
    published_path: Option<PathBuf>,
}

impl RecoveryArchiveError {
    fn published(message: impl Into<String>, path: PathBuf) -> Self {
        Self {
            message: message.into(),
            published_path: Some(path),
        }
    }
}

impl From<String> for RecoveryArchiveError {
    fn from(message: String) -> Self {
        Self {
            message,
            published_path: None,
        }
    }
}

impl From<&str> for RecoveryArchiveError {
    fn from(message: &str) -> Self {
        message.to_string().into()
    }
}

impl std::fmt::Display for RecoveryArchiveError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

type RecoveryArchiveResult<T> = Result<T, RecoveryArchiveError>;

#[derive(Clone, Debug, PartialEq, Eq)]
struct RecoveryDirectoryIdentity {
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
    #[cfg(windows)]
    volume_serial_number: u32,
    #[cfg(windows)]
    file_id: u64,
}

struct PinnedRecoveryRoot {
    path: PathBuf,
    directory: File,
    identity: RecoveryDirectoryIdentity,
}

impl PinnedRecoveryRoot {
    fn prepare(path: &Path) -> Result<Self, String> {
        if let Ok(metadata) = fs::symlink_metadata(path) {
            if metadata.file_type().is_symlink() {
                return Err("恢复包根目录是符号链接，已拒绝使用".into());
            }
            reject_windows_reparse_metadata(&metadata, "恢复包根目录")?;
        }
        fs::create_dir_all(path).map_err(|error| format!("创建恢复包根目录失败：{error}"))?;
        let directory = open_recovery_directory(path)?;
        let identity = recovery_directory_identity(&directory)?;
        let pinned = Self {
            path: path.to_path_buf(),
            directory,
            identity,
        };
        pinned.validate_path_identity()?;
        pinned.cleanup_owned_stale_artifacts()?;
        Ok(pinned)
    }

    fn validate_path_identity(&self) -> Result<(), String> {
        let metadata = fs::symlink_metadata(&self.path)
            .map_err(|error| format!("读取恢复包根目录属性失败：{error}"))?;
        if metadata.file_type().is_symlink() {
            return Err("恢复包根目录在操作期间变为符号链接".into());
        }
        reject_windows_reparse_metadata(&metadata, "恢复包根目录")?;
        let current = open_recovery_directory(&self.path)?;
        if recovery_directory_identity(&current)? != self.identity {
            return Err("恢复包根目录物理身份已变化".into());
        }
        Ok(())
    }

    fn cleanup_owned_stale_artifacts(&self) -> Result<(), String> {
        self.validate_path_identity()?;
        let entries =
            fs::read_dir(&self.path).map_err(|error| format!("枚举恢复包暂存文件失败：{error}"))?;
        for entry in entries {
            let entry = entry.map_err(|error| format!("读取恢复包目录项失败：{error}"))?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if !is_owned_recovery_temporary_name(&name) {
                continue;
            }
            let metadata = fs::symlink_metadata(entry.path())
                .map_err(|error| format!("读取恢复包暂存项属性失败：{error}"))?;
            if metadata.file_type().is_symlink() {
                return Err(format!("恢复包暂存项 {name} 是符号链接，已拒绝清理"));
            }
            reject_windows_reparse_metadata(&metadata, "恢复包暂存项")?;
            if !metadata.is_file() {
                return Err(format!("恢复包暂存项 {name} 不是普通文件，已拒绝清理"));
            }
            self.remove_file(&name)?;
        }
        self.validate_path_identity()
    }

    #[cfg(unix)]
    fn create_file(&self, name: &str) -> Result<File, String> {
        use std::os::fd::{AsRawFd, FromRawFd};
        let name = recovery_relative_c_string(name)?;
        // SAFETY: `self.directory` is a live, O_DIRECTORY|O_NOFOLLOW descriptor;
        // `name` is a validated single component; openat returns a new owned fd.
        let descriptor = unsafe {
            libc::openat(
                self.directory.as_raw_fd(),
                name.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if descriptor < 0 {
            return Err(format!(
                "在固定恢复根创建暂存文件失败：{}",
                std::io::Error::last_os_error()
            ));
        }
        // SAFETY: `descriptor` was just returned by openat and ownership is
        // transferred exactly once into File.
        Ok(unsafe { File::from_raw_fd(descriptor) })
    }

    #[cfg(not(unix))]
    fn create_file(&self, name: &str) -> Result<File, String> {
        self.validate_path_identity()?;
        let path = self.path.join(validate_recovery_relative_name(name)?);
        let file = open_new_recovery_file(&path)?;
        self.validate_path_identity()?;
        Ok(file)
    }

    #[cfg(unix)]
    fn open_file(&self, name: &str) -> Result<File, String> {
        use std::os::fd::{AsRawFd, FromRawFd};
        let name = recovery_relative_c_string(name)?;
        // SAFETY: the pinned directory fd is valid and `name` is one component.
        let descriptor = unsafe {
            libc::openat(
                self.directory.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if descriptor < 0 {
            return Err(format!(
                "从固定恢复根打开文件失败：{}",
                std::io::Error::last_os_error()
            ));
        }
        // SAFETY: `descriptor` is newly owned and transferred exactly once.
        Ok(unsafe { File::from_raw_fd(descriptor) })
    }

    #[cfg(not(unix))]
    fn open_file(&self, name: &str) -> Result<File, String> {
        self.validate_path_identity()?;
        let file = open_recovery_package(&self.path.join(validate_recovery_relative_name(name)?))?;
        self.validate_path_identity()?;
        Ok(file)
    }

    #[cfg(unix)]
    fn open_file_if_exists(&self, name: &str) -> Result<Option<File>, String> {
        use std::os::fd::{AsRawFd, FromRawFd};
        let name = recovery_relative_c_string(name)?;
        // SAFETY: the pinned directory fd is valid and `name` is one component.
        let descriptor = unsafe {
            libc::openat(
                self.directory.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if descriptor < 0 {
            let error = std::io::Error::last_os_error();
            return if error.kind() == std::io::ErrorKind::NotFound {
                Ok(None)
            } else {
                Err(format!("从固定恢复根检查文件失败：{error}"))
            };
        }
        // SAFETY: `descriptor` is newly owned and transferred exactly once.
        Ok(Some(unsafe { File::from_raw_fd(descriptor) }))
    }

    #[cfg(not(unix))]
    fn open_file_if_exists(&self, name: &str) -> Result<Option<File>, String> {
        self.validate_path_identity()?;
        let path = self.path.join(validate_recovery_relative_name(name)?);
        match open_recovery_package(&path) {
            Ok(file) => {
                self.validate_path_identity()?;
                Ok(Some(file))
            }
            Err(error) if !path.exists() => Ok(None),
            Err(error) => Err(error),
        }
    }

    #[cfg(unix)]
    fn hard_link(&self, source: &str, destination: &str) -> std::io::Result<()> {
        use std::os::fd::AsRawFd;
        let source = recovery_relative_c_string(source)
            .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidInput, error))?;
        let destination = recovery_relative_c_string(destination)
            .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidInput, error))?;
        // SAFETY: both names are validated single components and both directory
        // descriptors are the same live pinned recovery directory.
        let result = unsafe {
            libc::linkat(
                self.directory.as_raw_fd(),
                source.as_ptr(),
                self.directory.as_raw_fd(),
                destination.as_ptr(),
                0,
            )
        };
        if result == 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error())
        }
    }

    #[cfg(not(unix))]
    fn hard_link(&self, source: &str, destination: &str) -> std::io::Result<()> {
        self.validate_path_identity()
            .map_err(std::io::Error::other)?;
        let source = self.path.join(
            validate_recovery_relative_name(source)
                .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidInput, error))?,
        );
        let destination = self.path.join(
            validate_recovery_relative_name(destination)
                .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidInput, error))?,
        );
        fs::hard_link(source, destination)?;
        self.validate_path_identity().map_err(std::io::Error::other)
    }

    #[cfg(unix)]
    fn remove_file(&self, name: &str) -> Result<(), String> {
        use std::os::fd::AsRawFd;
        let name = recovery_relative_c_string(name)?;
        // SAFETY: the pinned directory fd is valid and `name` is one component.
        let result = unsafe { libc::unlinkat(self.directory.as_raw_fd(), name.as_ptr(), 0) };
        if result == 0 {
            Ok(())
        } else {
            Err(format!(
                "从固定恢复根删除暂存文件失败：{}",
                std::io::Error::last_os_error()
            ))
        }
    }

    #[cfg(not(unix))]
    fn remove_file(&self, name: &str) -> Result<(), String> {
        self.validate_path_identity()?;
        let path = self.path.join(validate_recovery_relative_name(name)?);
        let metadata = fs::symlink_metadata(&path)
            .map_err(|error| format!("读取待清理恢复包暂存项失败：{error}"))?;
        if metadata.file_type().is_symlink() {
            return Err("待清理恢复包暂存项是符号链接".into());
        }
        reject_windows_reparse_metadata(&metadata, "待清理恢复包暂存项")?;
        fs::remove_file(path).map_err(|error| format!("清理恢复包暂存项失败：{error}"))?;
        self.validate_path_identity()
    }

    fn sync(&self) -> Result<(), String> {
        self.directory
            .sync_all()
            .map_err(|error| format!("持久化固定恢复包根目录失败：{error}"))
    }
}

fn validate_recovery_relative_name(name: &str) -> Result<&str, String> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.contains('/')
        || name.contains('\\')
        || name.contains('\0')
    {
        return Err("恢复包文件名不是受限的单路径组件".into());
    }
    Ok(name)
}

#[cfg(unix)]
fn recovery_relative_c_string(name: &str) -> Result<std::ffi::CString, String> {
    std::ffi::CString::new(validate_recovery_relative_name(name)?.as_bytes())
        .map_err(|_| "恢复包文件名包含 NUL".into())
}

fn is_owned_recovery_temporary_name(name: &str) -> bool {
    let Some(stem) = name
        .strip_suffix(".tmp")
        .or_else(|| name.strip_suffix(".partial"))
    else {
        return false;
    };
    let Some(stem) = stem.strip_prefix('.') else {
        return false;
    };
    let Some((thread_id, process_and_time)) = stem.split_once('.') else {
        return false;
    };
    let Some((process_id, timestamp)) = process_and_time.split_once('-') else {
        return false;
    };
    canonical_uuid(thread_id).is_some()
        && !process_id.is_empty()
        && process_id.bytes().all(|byte| byte.is_ascii_digit())
        && !timestamp.is_empty()
        && timestamp.bytes().all(|byte| byte.is_ascii_digit())
}

fn recovery_directory_identity(file: &File) -> Result<RecoveryDirectoryIdentity, String> {
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    if !metadata.is_dir() {
        return Err("恢复包根不是目录".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Ok(RecoveryDirectoryIdentity {
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }
    #[cfg(windows)]
    {
        let (volume_serial_number, file_id) = windows_file_identity(file)
            .map_err(|error| format!("读取 Windows 恢复根物理身份失败：{error}"))?;
        Ok(RecoveryDirectoryIdentity {
            volume_serial_number,
            file_id,
        })
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = metadata;
        Ok(RecoveryDirectoryIdentity {})
    }
}

#[cfg(unix)]
fn open_recovery_directory(path: &Path) -> Result<File, String> {
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|error| format!("固定恢复包根目录失败：{error}"))
}

#[cfg(windows)]
fn open_recovery_directory(path: &Path) -> Result<File, String> {
    use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    let directory = fs::OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
        .map_err(|error| format!("固定 Windows 恢复包根目录失败：{error}"))?;
    let metadata = directory.metadata().map_err(|error| error.to_string())?;
    if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err("Windows 恢复包根目录是重解析点".into());
    }
    Ok(directory)
}

#[cfg(not(any(unix, windows)))]
fn open_recovery_directory(path: &Path) -> Result<File, String> {
    File::open(path).map_err(|error| format!("固定恢复包根目录失败：{error}"))
}

#[cfg(not(unix))]
fn open_new_recovery_file(path: &Path) -> Result<File, String> {
    #[cfg(windows)]
    {
        use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        let file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .open(path)
            .map_err(|error| format!("创建 Windows 恢复包暂存文件失败：{error}"))?;
        let metadata = file.metadata().map_err(|error| error.to_string())?;
        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err("Windows 恢复包暂存文件是重解析点".into());
        }
        return Ok(file);
    }
    #[cfg(not(windows))]
    {
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)
            .map_err(|error| format!("创建恢复包暂存文件失败：{error}"))
    }
}

#[cfg(windows)]
fn reject_windows_reparse_metadata(metadata: &fs::Metadata, label: &str) -> Result<(), String> {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        Err(format!("{label} 是 Windows 重解析点，已拒绝操作"))
    } else {
        Ok(())
    }
}

#[cfg(not(windows))]
fn reject_windows_reparse_metadata(_metadata: &fs::Metadata, _label: &str) -> Result<(), String> {
    Ok(())
}

fn create_recovery_archive(
    codex_home: &Path,
    thread_id: &str,
    recovery_source_key: &str,
) -> RecoveryArchiveResult<RecoveryArchiveReceipt> {
    ensure_codex_home_identity(codex_home, recovery_source_key)?;
    revalidate_mutation_safety(codex_home, thread_id)?;
    let package_root = recovery_archive_root(recovery_source_key)?;
    let result = create_recovery_archive_at(codex_home, thread_id, &package_root)?;
    if let Err(error) = ensure_codex_home_identity(codex_home, recovery_source_key) {
        return Err(RecoveryArchiveError::published(error, result.path.clone()));
    }
    Ok(result)
}

fn create_recovery_archive_at(
    codex_home: &Path,
    thread_id: &str,
    package_root: &Path,
) -> RecoveryArchiveResult<RecoveryArchiveReceipt> {
    create_recovery_archive_at_with_hook(codex_home, thread_id, package_root, |_| Ok(()))
}

fn create_recovery_archive_at_with_hook(
    codex_home: &Path,
    thread_id: &str,
    package_root: &Path,
    after_copy: impl FnMut(&Path) -> Result<(), String>,
) -> RecoveryArchiveResult<RecoveryArchiveReceipt> {
    create_recovery_archive_at_with_hooks(codex_home, thread_id, package_root, after_copy, |_| {
        Ok(())
    })
}

fn create_recovery_archive_at_with_hooks(
    codex_home: &Path,
    thread_id: &str,
    package_root: &Path,
    mut after_copy: impl FnMut(&Path) -> Result<(), String>,
    mut after_publish: impl FnMut(&Path) -> Result<(), String>,
) -> RecoveryArchiveResult<RecoveryArchiveReceipt> {
    validate_thread_id(thread_id)?;
    let rollout = resolve_verified_rollout(codex_home, thread_id)
        .map_err(|error| format!("找不到唯一可信 rollout 文件：{error}"))?;
    let source_meta = read_session_meta(&rollout)
        .map_err(|error| format!("恢复包创建前无法验证 rollout 首行身份：{error}"))?;
    if source_meta.id != thread_id {
        return Err(format!(
            "rollout 首行 ID 与目标会话不一致：期望 {thread_id}，实际 {}",
            source_meta.id
        )
        .into());
    }
    let recovery_root = PinnedRecoveryRoot::prepare(package_root)?;
    let stage_name = format!(".{thread_id}.{}-{}.tmp", std::process::id(), unix_now());
    let stage = package_root.join(&stage_name);
    let result: RecoveryArchiveResult<RecoveryArchiveReceipt> =
        (|| -> RecoveryArchiveResult<RecoveryArchiveReceipt> {
            let mut source = open_rollout_source(&rollout)?;
            let source_before = rollout_source_snapshot_from_file(&source)?;
            let source_meta = read_session_meta_from_reader(
                source
                    .try_clone()
                    .map_err(|error| format!("复制 rollout 文件句柄失败：{error}"))?,
            )
            .map_err(|error| format!("恢复包创建前无法验证 rollout 首行身份：{error}"))?;
            if source_meta.id != thread_id {
                return Err(format!(
                    "rollout 首行 ID 与目标会话不一致：期望 {thread_id}，实际 {}",
                    source_meta.id
                )
                .into());
            }
            // Duplicated file descriptors may share a file offset. Always rewind
            // the pinned source after parsing metadata and again before copying.
            source
                .seek(SeekFrom::Start(0))
                .map_err(|error| format!("重置 rollout 读取位置失败：{error}"))?;
            let digest = sha256_reader(&mut source)?;
            source
                .seek(SeekFrom::Start(0))
                .map_err(|error| format!("重置 rollout 读取位置失败：{error}"))?;
            let destination_name = format!("{thread_id}-{digest}.ctb-session.zip");
            let destination = package_root.join(&destination_name);
            let relative = rollout
                .strip_prefix(
                    codex_home
                        .canonicalize()
                        .map_err(|error| error.to_string())?,
                )
                .map_err(|_| "rollout 不在 Codex Home 内".to_string())?
                .to_string_lossy()
                .replace('\\', "/");
            let manifest = RecoveryArchiveManifest {
                schema_version: 1,
                thread_id: thread_id.to_string(),
                created_at: unix_now(),
                original_relative_path: relative.clone(),
                original_bytes: source_before.bytes,
                sha256: digest.clone(),
                compression: "zip-deflate-9".into(),
                restore_supported: false,
            };
            let stage_file = recovery_root.create_file(&stage_name)?;
            let mut zip = zip::ZipWriter::new(stage_file);
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated)
                .compression_level(Some(9));
            zip.start_file("manifest.json", options)
                .map_err(|error| error.to_string())?;
            serde_json::to_writer_pretty(&mut zip, &manifest).map_err(|error| error.to_string())?;
            zip.start_file("rollout.jsonl", options)
                .map_err(|error| error.to_string())?;
            std::io::copy(&mut source, &mut zip).map_err(|error| error.to_string())?;
            let file = zip.finish().map_err(|error| error.to_string())?;
            file.sync_all().map_err(|error| error.to_string())?;
            after_copy(&rollout)?;
            verify_recovery_archive_file(
                recovery_root.open_file(&stage_name)?,
                &stage,
                source_before.bytes,
                &digest,
                &relative,
                thread_id,
            )?;
            let source_after = rollout_source_snapshot_from_file(&source)?;
            let path_after = rollout_source_snapshot(&rollout)?;
            if source_after != source_before || path_after != source_before {
                return Err("源 rollout 在压缩期间发生变化，暂存包已拒绝发布".into());
            }
            if let Some(existing) = recovery_root.open_file_if_exists(&destination_name)? {
                if verify_recovery_archive_file(
                    existing,
                    &destination,
                    source_before.bytes,
                    &digest,
                    &relative,
                    thread_id,
                )
                .is_ok()
                {
                    if let Err(error) = recovery_root.remove_file(&stage_name) {
                        return Err(RecoveryArchiveError::published(
                            format!("恢复包已存在且校验通过，但清理暂存文件失败：{error}"),
                            destination,
                        ));
                    }
                    return pin_recovery_receipt(
                        thread_id,
                        destination.clone(),
                        rollout.clone(),
                        source_before.clone(),
                        digest.clone(),
                        relative.clone(),
                        source,
                        recovery_root.open_file(&destination_name)?,
                    );
                }
                return Err(RecoveryArchiveError::published(
                    "同名恢复包已存在但完整回读校验失败，已拒绝复用或覆盖",
                    destination,
                ));
            }
            match recovery_root.hard_link(&stage_name, &destination_name) {
                Ok(()) => {
                    if let Err(error) = recovery_root.remove_file(&stage_name) {
                        return Err(RecoveryArchiveError::published(
                            format!("恢复包已发布，但清理暂存文件失败：{error}"),
                            destination,
                        ));
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    if verify_recovery_archive_file(
                        recovery_root.open_file(&destination_name)?,
                        &destination,
                        source_before.bytes,
                        &digest,
                        &relative,
                        thread_id,
                    )
                    .is_ok()
                    {
                        if let Err(error) = recovery_root.remove_file(&stage_name) {
                            return Err(RecoveryArchiveError::published(
                                format!(
                                "恢复包在发布竞态中已存在且校验通过，但清理暂存文件失败：{error}"
                            ),
                                destination,
                            ));
                        }
                        return pin_recovery_receipt(
                            thread_id,
                            destination.clone(),
                            rollout.clone(),
                            source_before.clone(),
                            digest.clone(),
                            relative.clone(),
                            source,
                            recovery_root.open_file(&destination_name)?,
                        );
                    }
                    return Err(RecoveryArchiveError::published(
                        "同名恢复包在发布期间出现且完整回读校验失败，已拒绝覆盖",
                        destination,
                    ));
                }
                Err(error) => return Err(format!("原子发布恢复包失败：{error}").into()),
            }
            if let Err(error) = recovery_root.sync() {
                return Err(RecoveryArchiveError::published(
                    format!("恢复包已发布，但目录持久化失败：{error}"),
                    destination,
                ));
            }
            if let Err(error) = after_publish(&destination) {
                return Err(RecoveryArchiveError::published(
                    format!("恢复包已发布，但后置测试失败：{error}"),
                    destination,
                ));
            }
            recovery_root.validate_path_identity().map_err(|error| {
                RecoveryArchiveError::published(
                    format!("恢复包发布后根目录身份复验失败：{error}"),
                    destination.clone(),
                )
            })?;
            if let Err(error) = verify_recovery_archive_file(
                recovery_root.open_file(&destination_name)?,
                &destination,
                source_before.bytes,
                &digest,
                &relative,
                thread_id,
            ) {
                return Err(RecoveryArchiveError::published(
                    format!("恢复包已发布，但后置完整回读校验失败：{error}"),
                    destination,
                ));
            }
            pin_recovery_receipt(
                thread_id,
                destination,
                rollout,
                source_before,
                digest,
                relative,
                source,
                recovery_root.open_file(&destination_name)?,
            )
        })();
    if result.is_err() {
        let _ = recovery_root.remove_file(&stage_name);
    }
    result
}

fn pin_recovery_receipt(
    thread_id: &str,
    path: PathBuf,
    rollout_path: PathBuf,
    source_snapshot: RolloutSourceSnapshot,
    sha256: String,
    original_relative_path: String,
    mut source_handle: File,
    mut package_handle: File,
) -> RecoveryArchiveResult<RecoveryArchiveReceipt> {
    let pinned_source_snapshot = rollout_source_snapshot_from_file(&source_handle)?;
    source_handle
        .seek(SeekFrom::Start(0))
        .map_err(|error| format!("重置固定 rollout 句柄失败：{error}"))?;
    let pinned_source_digest = sha256_reader(&mut source_handle)?;
    if pinned_source_snapshot != source_snapshot || pinned_source_digest != sha256 {
        return Err(RecoveryArchiveError::published(
            "恢复包发布后，无法固定与打包版本一致的源 rollout 句柄",
            path,
        ));
    }
    let package_snapshot = rollout_source_snapshot_from_file(&package_handle).map_err(|error| {
        RecoveryArchiveError::published(
            format!("恢复包发布后无法读取包文件物理身份：{error}"),
            path.clone(),
        )
    })?;
    package_handle.seek(SeekFrom::Start(0)).map_err(|error| {
        RecoveryArchiveError::published(format!("重置固定恢复包句柄失败：{error}"), path.clone())
    })?;
    let package_sha256 = sha256_reader(&mut package_handle).map_err(|error| {
        RecoveryArchiveError::published(format!("读取固定恢复包摘要失败：{error}"), path.clone())
    })?;
    verify_recovery_archive_file(
        package_handle.try_clone().map_err(|error| {
            RecoveryArchiveError::published(
                format!("复制固定恢复包句柄失败：{error}"),
                path.clone(),
            )
        })?,
        &path,
        source_snapshot.bytes,
        &sha256,
        &original_relative_path,
        thread_id,
    )
    .map_err(|error| {
        RecoveryArchiveError::published(
            format!("固定恢复包句柄完整回读失败：{error}"),
            path.clone(),
        )
    })?;
    Ok(RecoveryArchiveReceipt {
        path,
        rollout_path,
        source_snapshot,
        sha256,
        original_relative_path,
        source_handle,
        package_handle,
        package_snapshot,
        package_sha256,
    })
}

fn recovery_archive_root(recovery_source_key: &str) -> Result<PathBuf, String> {
    if recovery_source_key.trim().is_empty() {
        return Err("恢复包缺少 Codex Home 物理来源标识".into());
    }
    let mut hasher = Sha256::new();
    hasher.update(recovery_source_key.as_bytes());
    let namespace = format!("source-{:x}", hasher.finalize());
    #[cfg(test)]
    if let Some(path) = std::env::var_os("CODEX_TOKEN_BAR_SESSION_ARCHIVE_ROOT") {
        return Ok(PathBuf::from(path).join(namespace));
    }
    Ok(crate::core::app_paths::session_recovery_archive_root()?.join(namespace))
}

#[cfg(test)]
fn sha256_file(path: &Path) -> Result<String, String> {
    let mut file = File::open(path).map_err(|error| error.to_string())?;
    sha256_reader(&mut file)
}

fn sha256_reader(reader: &mut impl Read) -> Result<String, String> {
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; CONTEXT_READ_BUFFER];
    loop {
        let read = reader
            .read(&mut buffer)
            .map_err(|error| error.to_string())?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RecoveryArchiveManifest {
    schema_version: u64,
    thread_id: String,
    created_at: i64,
    original_relative_path: String,
    original_bytes: u64,
    sha256: String,
    compression: String,
    restore_supported: bool,
}

fn verify_recovery_archive(
    path: &Path,
    expected_id: &str,
    expected_bytes: u64,
    expected_digest: &str,
    expected_relative_path: &str,
) -> Result<(), String> {
    let file = open_recovery_package(path)?;
    verify_recovery_archive_file(
        file,
        path,
        expected_bytes,
        expected_digest,
        expected_relative_path,
        expected_id,
    )
}

fn verify_recovery_archive_file(
    file: File,
    _path: &Path,
    expected_bytes: u64,
    expected_digest: &str,
    expected_relative_path: &str,
    expected_id: &str,
) -> Result<(), String> {
    let mut zip = zip::ZipArchive::new(file).map_err(|error| error.to_string())?;
    let member_names = (0..zip.len())
        .map(|index| {
            zip.by_index(index)
                .map(|member| member.name().to_string())
                .map_err(|error| error.to_string())
        })
        .collect::<Result<Vec<_>, _>>()?;
    if member_names.len() != 2
        || member_names
            .iter()
            .filter(|name| name.as_str() == "manifest.json")
            .count()
            != 1
        || member_names
            .iter()
            .filter(|name| name.as_str() == "rollout.jsonl")
            .count()
            != 1
    {
        return Err("恢复包成员必须且只能是 manifest.json 与 rollout.jsonl".into());
    }
    let manifest: RecoveryArchiveManifest = {
        let member = zip
            .by_name("manifest.json")
            .map_err(|error| format!("恢复包缺少 manifest：{error}"))?;
        serde_json::from_reader(member).map_err(|error| error.to_string())?
    };
    if manifest.schema_version != 1
        || manifest.thread_id != expected_id
        || manifest.created_at <= 0
        || manifest.original_relative_path != expected_relative_path
        || manifest.original_bytes != expected_bytes
        || manifest.sha256 != expected_digest
        || manifest.compression != "zip-deflate-9"
        || manifest.restore_supported
    {
        return Err("恢复包 manifest 与源会话不一致".into());
    }
    let mut rollout = zip
        .by_name("rollout.jsonl")
        .map_err(|error| format!("恢复包缺少 rollout：{error}"))?;
    let mut hasher = Sha256::new();
    let mut bytes = 0_u64;
    let mut buffer = vec![0_u8; CONTEXT_READ_BUFFER];
    loop {
        let read = rollout
            .read(&mut buffer)
            .map_err(|error| error.to_string())?;
        if read == 0 {
            break;
        }
        bytes = bytes
            .checked_add(read as u64)
            .ok_or_else(|| "恢复包长度溢出".to_string())?;
        hasher.update(&buffer[..read]);
    }
    let digest = format!("{:x}", hasher.finalize());
    if bytes != expected_bytes || digest != expected_digest {
        return Err("恢复包 rollout 回读校验失败".into());
    }
    drop(rollout);
    let packaged_meta = {
        let member = zip
            .by_name("rollout.jsonl")
            .map_err(|error| format!("恢复包缺少 rollout：{error}"))?;
        read_session_meta_from_reader(member)
            .map_err(|error| format!("恢复包 rollout 首行身份无效：{error}"))?
    };
    if packaged_meta.id != expected_id {
        return Err(format!(
            "恢复包 rollout 首行 ID 与目标会话不一致：期望 {expected_id}，实际 {}",
            packaged_meta.id
        ));
    }
    Ok(())
}

fn verify_recovery_receipt(
    codex_home: &Path,
    thread_id: &str,
    receipt: &RecoveryArchiveReceipt,
) -> Result<(), String> {
    verify_pinned_source_handle(thread_id, receipt)?;
    verify_pinned_package_handle(thread_id, receipt)?;
    let current_path = resolve_verified_rollout(codex_home, thread_id)?;
    if current_path != receipt.rollout_path {
        return Err(format!(
            "rollout 路径已变化：打包时 {}，当前 {}",
            receipt.rollout_path.display(),
            current_path.display()
        ));
    }
    let mut source = open_rollout_source(&current_path)?;
    let current_snapshot = rollout_source_snapshot_from_file(&source)?;
    if current_snapshot != receipt.source_snapshot {
        return Err("rollout 文件长度、时间或物理身份已变化".into());
    }
    let meta = read_session_meta_from_reader(
        source
            .try_clone()
            .map_err(|error| format!("复制 rollout 文件句柄失败：{error}"))?,
    )
    .map_err(|error| format!("无法重新验证 rollout 首行：{error}"))?;
    if meta.id != thread_id {
        return Err(format!(
            "rollout 首行 ID 已变化：期望 {thread_id}，实际 {}",
            meta.id
        ));
    }
    source
        .seek(SeekFrom::Start(0))
        .map_err(|error| format!("重置 rollout 读取位置失败：{error}"))?;
    let digest = sha256_reader(&mut source)?;
    if digest != receipt.sha256 {
        return Err("rollout 内容摘要已变化".into());
    }
    let mut package = open_recovery_package(&receipt.path)?;
    let package_snapshot = rollout_source_snapshot_from_file(&package)?;
    package
        .seek(SeekFrom::Start(0))
        .map_err(|error| format!("重置当前恢复包读取位置失败：{error}"))?;
    let package_sha256 = sha256_reader(&mut package)?;
    if package_snapshot != receipt.package_snapshot || package_sha256 != receipt.package_sha256 {
        return Err("恢复包路径当前指向的物理文件或内容已变化".into());
    }
    verify_recovery_archive_file(
        package,
        &receipt.path,
        receipt.source_snapshot.bytes,
        &receipt.sha256,
        &receipt.original_relative_path,
        thread_id,
    )
    .map_err(|error| format!("恢复包后置回读失败：{error}"))
}

fn verify_pinned_source_handle(
    thread_id: &str,
    receipt: &RecoveryArchiveReceipt,
) -> Result<(), String> {
    let snapshot = rollout_source_snapshot_from_file(&receipt.source_handle)?;
    if snapshot != receipt.source_snapshot {
        return Err("固定的原 rollout 句柄长度、时间或物理身份已变化".into());
    }
    let mut source = receipt
        .source_handle
        .try_clone()
        .map_err(|error| format!("复制固定 rollout 句柄失败：{error}"))?;
    source
        .seek(SeekFrom::Start(0))
        .map_err(|error| format!("重置固定 rollout 句柄失败：{error}"))?;
    let digest = sha256_reader(&mut source)?;
    if digest != receipt.sha256 {
        return Err("固定的原 rollout 句柄内容摘要已变化".into());
    }
    let mut meta_handle = receipt
        .source_handle
        .try_clone()
        .map_err(|error| format!("复制固定 rollout 元数据句柄失败：{error}"))?;
    meta_handle
        .seek(SeekFrom::Start(0))
        .map_err(|error| format!("重置固定 rollout 元数据句柄失败：{error}"))?;
    let meta = read_session_meta_from_reader(meta_handle)
        .map_err(|error| format!("固定的原 rollout 首行无效：{error}"))?;
    if meta.id != thread_id {
        return Err(format!(
            "固定的原 rollout 首行 ID 已变化：期望 {thread_id}，实际 {}",
            meta.id
        ));
    }
    Ok(())
}

fn verify_pinned_package_handle(
    thread_id: &str,
    receipt: &RecoveryArchiveReceipt,
) -> Result<(), String> {
    let snapshot = rollout_source_snapshot_from_file(&receipt.package_handle)?;
    if snapshot != receipt.package_snapshot {
        return Err("固定的恢复包句柄长度、时间或物理身份已变化".into());
    }
    let mut package = receipt
        .package_handle
        .try_clone()
        .map_err(|error| format!("复制固定恢复包句柄失败：{error}"))?;
    package
        .seek(SeekFrom::Start(0))
        .map_err(|error| format!("重置固定恢复包句柄失败：{error}"))?;
    let digest = sha256_reader(&mut package)?;
    if digest != receipt.package_sha256 {
        return Err("固定的恢复包句柄内容摘要已变化".into());
    }
    verify_recovery_archive_file(
        receipt
            .package_handle
            .try_clone()
            .map_err(|error| format!("复制固定恢复包校验句柄失败：{error}"))?,
        &receipt.path,
        receipt.source_snapshot.bytes,
        &receipt.sha256,
        &receipt.original_relative_path,
        thread_id,
    )
    .map_err(|error| format!("固定恢复包完整回读失败：{error}"))
}

fn verify_pinned_receipt_after_cli(
    thread_id: &str,
    receipt: &RecoveryArchiveReceipt,
) -> Result<(), String> {
    verify_pinned_source_handle(thread_id, receipt)?;
    verify_pinned_package_handle(thread_id, receipt)?;
    let mut package = open_recovery_package(&receipt.path)?;
    let snapshot = rollout_source_snapshot_from_file(&package)?;
    package
        .seek(SeekFrom::Start(0))
        .map_err(|error| format!("重置 CLI 返回后的恢复包路径句柄失败：{error}"))?;
    let digest = sha256_reader(&mut package)?;
    if snapshot != receipt.package_snapshot || digest != receipt.package_sha256 {
        return Err("CLI 返回后，恢复包路径不再指向固定的完整包版本".into());
    }
    Ok(())
}

fn validate_receipt_against_confirmation(
    thread_id: &str,
    receipt: &RecoveryArchiveReceipt,
    confirmation: &SessionDeleteConfirmation,
) -> Result<(), String> {
    let expected = confirmation
        .rollouts
        .iter()
        .find(|snapshot| snapshot.thread_id == thread_id)
        .ok_or_else(|| format!("确认快照缺少会话 {thread_id}"))?;
    let actual = delete_rollout_snapshot_value(
        thread_id,
        receipt.original_relative_path.clone(),
        &receipt.source_snapshot,
        receipt.sha256.clone(),
    );
    if &actual != expected {
        return Err("恢复包源版本与确认时规范路径、物理身份、大小、时间或摘要不一致".into());
    }
    Ok(())
}

struct DeleteCliAttempt {
    command_result: Result<(), String>,
    pinned_evidence_result: Result<(), String>,
}

fn execute_delete_cli_with_final_gate<BeforeCli, ReadFinalImpact, Executor>(
    codex_home: &Path,
    expected_source_key: &str,
    remaining_root_ids: &[String],
    expected_affected_ids: &[String],
    confirmation: &SessionDeleteConfirmation,
    recovery_receipts: &HashMap<String, RecoveryArchiveReceipt>,
    before_cli: BeforeCli,
    read_final_impact: ReadFinalImpact,
    executor: Executor,
) -> Result<DeleteCliAttempt, String>
where
    BeforeCli: FnOnce() -> Result<(), String>,
    ReadFinalImpact: FnOnce() -> Result<DeletionImpact, String>,
    Executor: FnOnce() -> Result<(), String>,
{
    before_cli()?;
    ensure_codex_home_identity(codex_home, expected_source_key)?;
    validate_confirmation_rollout_subset(codex_home, confirmation, expected_affected_ids)?;
    for thread_id in expected_affected_ids {
        let receipt = recovery_receipts
            .get(thread_id)
            .ok_or_else(|| format!("缺少会话 {thread_id} 的固定恢复包回执"))?;
        validate_receipt_against_confirmation(thread_id, receipt, confirmation)?;
        verify_recovery_receipt(codex_home, thread_id, receipt)?;
    }
    // Full source/package hashing can take minutes for large sessions. Read
    // the official remaining descendant closure only after those hashes, then
    // launch immediately so a descendant created during verification cannot
    // silently fall outside the user's frozen confirmation.
    let final_impact = read_final_impact()?;
    validate_remaining_delete_plan(&final_impact, remaining_root_ids, expected_affected_ids)?;
    ensure_codex_home_identity(codex_home, expected_source_key)?;
    let command_result = executor();
    let pinned_evidence_result = expected_affected_ids.iter().try_for_each(|thread_id| {
        let receipt = recovery_receipts
            .get(thread_id)
            .ok_or_else(|| format!("缺少会话 {thread_id} 的固定恢复包回执"))?;
        verify_pinned_receipt_after_cli(thread_id, receipt)
    });
    Ok(DeleteCliAttempt {
        command_result,
        pinned_evidence_result,
    })
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RolloutSourceSnapshot {
    bytes: u64,
    modified_nanos: Option<u128>,
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
    #[cfg(windows)]
    volume_serial_number: u32,
    #[cfg(windows)]
    file_id: u64,
}

fn rollout_source_snapshot(path: &Path) -> Result<RolloutSourceSnapshot, String> {
    let file = open_rollout_source(path)?;
    rollout_source_snapshot_from_file(&file)
}

fn rollout_source_snapshot_from_file(file: &File) -> Result<RolloutSourceSnapshot, String> {
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    if !metadata.is_file() {
        return Err("rollout 源不是普通文件".into());
    }
    let modified_nanos = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_nanos());
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Ok(RolloutSourceSnapshot {
            bytes: metadata.len(),
            modified_nanos,
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }
    #[cfg(windows)]
    {
        let (volume_serial_number, file_id) = windows_file_identity(file)
            .map_err(|error| format!("读取 Windows rollout 物理身份失败：{error}"))?;
        Ok(RolloutSourceSnapshot {
            bytes: metadata.len(),
            modified_nanos,
            volume_serial_number,
            file_id,
        })
    }
    #[cfg(not(any(unix, windows)))]
    {
        Ok(RolloutSourceSnapshot {
            bytes: metadata.len(),
            modified_nanos,
        })
    }
}

#[cfg(windows)]
fn windows_file_identity(file: &File) -> std::io::Result<(u32, u64)> {
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
        return Err(std::io::Error::last_os_error());
    }
    let information = unsafe { information.assume_init() };
    let file_id =
        (u64::from(information.file_index_high) << 32) | u64::from(information.file_index_low);
    Ok((information.volume_serial_number, file_id))
}

#[cfg(unix)]
fn open_rollout_source(path: &Path) -> Result<File, String> {
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| format!("打开 rollout 源失败：{error}"))
}

#[cfg(windows)]
fn open_rollout_source(path: &Path) -> Result<File, String> {
    use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
        .map_err(|error| format!("打开 rollout 源失败：{error}"))?;
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err("rollout 源是重解析点，已拒绝跟随".into());
    }
    if !metadata.is_file() {
        return Err("rollout 源不是普通文件".into());
    }
    Ok(file)
}

#[cfg(not(any(unix, windows)))]
fn open_rollout_source(path: &Path) -> Result<File, String> {
    File::open(path).map_err(|error| format!("打开 rollout 源失败：{error}"))
}

#[cfg(unix)]
fn open_recovery_package(path: &Path) -> Result<File, String> {
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| format!("打开恢复包失败：{error}"))
}

#[cfg(windows)]
fn open_recovery_package(path: &Path) -> Result<File, String> {
    use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
        .map_err(|error| format!("打开恢复包失败：{error}"))?;
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err("恢复包是 Windows 重解析点，已拒绝跟随".into());
    }
    if !metadata.is_file() {
        return Err("恢复包不是普通文件".into());
    }
    Ok(file)
}

#[cfg(not(any(unix, windows)))]
fn open_recovery_package(path: &Path) -> Result<File, String> {
    File::open(path).map_err(|error| format!("打开恢复包失败：{error}"))
}

#[cfg(unix)]
fn sync_parent(path: &Path) -> Result<(), String> {
    let directory = File::open(path).map_err(|error| error.to_string())?;
    directory.sync_all().map_err(|error| error.to_string())
}

#[cfg(not(unix))]
fn sync_parent(_path: &Path) -> Result<(), String> {
    // The completed ZIP itself is synced before the atomic rename. Rust's
    // portable File API cannot open a Windows directory for FlushFileBuffers.
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::params;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    struct TestHome {
        root: PathBuf,
    }

    impl TestHome {
        fn new(label: &str) -> Self {
            let root = std::env::temp_dir().join(format!(
                "codex-token-bar-session-manager-{label}-{}-{}",
                std::process::id(),
                TEST_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(root.join("sessions/2026/07/30")).unwrap();
            fs::create_dir_all(root.join("archived_sessions")).unwrap();
            Self { root }
        }

        fn session_path(&self, id: &str) -> PathBuf {
            self.root
                .join("sessions/2026/07/30")
                .join(format!("rollout-{id}.jsonl"))
        }

        fn archived_path(&self, id: &str) -> PathBuf {
            self.root
                .join("archived_sessions")
                .join(format!("rollout-{id}.jsonl"))
        }

        fn create_db(&self, rows: &[(&str, &Path, bool)]) {
            let connection = Connection::open(self.root.join("state_5.sqlite")).unwrap();
            connection
                .execute_batch(
                    "CREATE TABLE threads (
                        id TEXT PRIMARY KEY,
                        rollout_path TEXT,
                        title TEXT,
                        preview TEXT,
                        first_user_message TEXT,
                        cwd TEXT,
                        created_at INTEGER,
                        updated_at INTEGER,
                        recency_at INTEGER,
                        archived INTEGER,
                        archived_at INTEGER,
                        tokens_used INTEGER,
                        source TEXT,
                        model TEXT
                    );",
                )
                .unwrap();
            for (id, path, archived) in rows {
                connection
                    .execute(
                        "INSERT INTO threads VALUES (?1, ?2, 'title', 'preview', 'hello', '/tmp/project', 1, 2, 3, ?3, NULL, 10, 'cli', 'gpt-test')",
                        params![id, path.to_string_lossy(), i64::from(*archived)],
                    )
                    .unwrap();
            }
        }
    }

    impl Drop for TestHome {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn impact_thread(
        id: &str,
        parent_thread_id: Option<&str>,
        forked_from_id: Option<&str>,
        file_bytes: Option<u64>,
        status: &str,
    ) -> SessionManagementThread {
        SessionManagementThread {
            id: id.into(),
            title: id.into(),
            preview: String::new(),
            cwd: "/tmp".into(),
            created_at: None,
            updated_at: None,
            recency_at: None,
            archived: true,
            archived_at: None,
            tokens_used: None,
            file_bytes,
            file_modified_at: None,
            status: status.into(),
            source: None,
            model: None,
            session_id: None,
            forked_from_id: forked_from_id.map(str::to_string),
            parent_thread_id: parent_thread_id.map(str::to_string),
            is_subagent: parent_thread_id.is_some(),
            spawn_child_count: 0,
            fork_child_count: 0,
            similarity_group_id: None,
            similarity_reason: None,
            protection_reasons: Vec::new(),
            can_archive: false,
            can_unarchive: true,
            can_delete: status == "notLoaded",
        }
    }

    struct FakeProtocol {
        active: Result<Vec<Value>, String>,
        archived: Result<Vec<Value>, String>,
    }

    impl SessionProtocol for FakeProtocol {
        fn list_threads(&mut self, archived: bool) -> Result<Vec<Value>, String> {
            if archived {
                self.archived.clone()
            } else {
                self.active.clone()
            }
        }
    }

    #[test]
    fn pagination_reads_every_page_and_rejects_repeated_cursor() {
        let mut calls = 0;
        let rows = collect_all_thread_pages(|cursor| {
            calls += 1;
            Ok(match cursor {
                None => json!({"data": [{"id": "one"}], "nextCursor": "next"}),
                Some("next") => json!({"data": [{"id": "two"}], "nextCursor": null}),
                _ => unreachable!(),
            })
        })
        .unwrap();
        assert_eq!(calls, 2);
        assert_eq!(rows.len(), 2);

        let error = collect_all_thread_pages(|_| Ok(json!({"data": [], "nextCursor": "same"})))
            .unwrap_err();
        assert!(error.contains("重复游标"));
    }

    #[test]
    fn descendant_thread_list_request_is_state_db_only_and_carries_ancestor() {
        let params = thread_list_params(true, Some("cursor-2"), Some("root"));
        assert_eq!(
            params.get("ancestorThreadId").and_then(Value::as_str),
            Some("root")
        );
        assert_eq!(
            params.get("useStateDbOnly").and_then(Value::as_bool),
            Some(true)
        );
        assert_eq!(params.get("archived").and_then(Value::as_bool), Some(true));
        assert_eq!(
            params.get("cursor").and_then(Value::as_str),
            Some("cursor-2")
        );
    }

    #[test]
    fn protocol_parent_thread_id_remains_the_direct_spawn_edge() {
        let child = Uuid::new_v4().to_string();
        let root = Uuid::new_v4().to_string();
        let thread = parse_protocol_thread(
            &json!({
                "id": child,
                "ancestorThreadId": Uuid::new_v4().to_string(),
                "parentThreadId": root
            }),
            false,
        )
        .unwrap();
        assert_eq!(thread.parent_thread_id.as_deref(), Some(root.as_str()));
    }

    #[test]
    fn protocol_thread_ids_are_trimmed_uuid_validated_and_canonicalized() {
        let id = Uuid::new_v4().to_string();
        let parent = Uuid::new_v4().to_string();
        let parsed = parse_protocol_thread(
            &json!({
                "id": format!("  {}  ", id.to_uppercase()),
                "parentThreadId": format!(" {} ", parent.to_uppercase())
            }),
            false,
        )
        .unwrap();
        assert_eq!(parsed.id, id);
        assert_eq!(parsed.parent_thread_id.as_deref(), Some(parent.as_str()));
        assert!(parse_protocol_thread(&json!({"id": "not-a-uuid"}), false).is_none());
        assert!(parse_protocol_thread(
            &json!({"id": Uuid::new_v4().to_string(), "parentThreadId": "bad"}),
            false,
        )
        .is_none());
    }

    #[test]
    fn strict_directory_rejects_invalid_and_normalized_duplicate_protocol_ids() {
        let home = TestHome::new("strict-protocol-id");
        let id = Uuid::new_v4().to_string();
        let invalid = load_strict_official_directory_from_rows(
            &home.root,
            vec![json!({"id": "invalid"})],
            Vec::new(),
        )
        .err()
        .expect("invalid protocol ID must fail closed");
        assert!(invalid.contains("缺少有效 ID"));

        let duplicate = load_strict_official_directory_from_rows(
            &home.root,
            vec![json!({"id": id})],
            vec![json!({"id": format!(" {} ", id.to_uppercase())})],
        )
        .err()
        .expect("canonical duplicate protocol ID must fail closed");
        assert!(duplicate.contains("重复出现"));
    }

    #[test]
    fn ancestor_thread_query_must_equal_the_full_official_recursive_closure() {
        let root = Uuid::new_v4().to_string();
        let child = Uuid::new_v4().to_string();
        let unknown = Uuid::new_v4().to_string();
        let official = HashMap::from([(root.clone(), None), (child.clone(), Some(root.clone()))]);
        let expected = HashSet::from([root.clone(), child.clone()]);
        validate_ancestor_query_rows(
            &root,
            &[json!({"id": child, "parentThreadId": root})],
            &official,
            &expected,
        )
        .unwrap();

        let error = validate_ancestor_query_rows(&root, &[], &official, &expected).unwrap_err();
        assert!(error.contains("递归闭包已变化"));
        let error = validate_ancestor_query_rows(
            &root,
            &[json!({"id": unknown, "parentThreadId": root})],
            &official,
            &expected,
        )
        .unwrap_err();
        assert!(error.contains("未知会话"));
    }

    #[test]
    fn official_parent_graph_rejects_unknown_ancestors_and_cycles() {
        let unknown = HashMap::from([
            ("root".to_string(), None),
            ("child".to_string(), Some("missing".to_string())),
        ]);
        assert!(validate_official_parent_graph(&unknown)
            .unwrap_err()
            .contains("未知会话 missing"));

        let cycle = HashMap::from([
            ("a".to_string(), Some("b".to_string())),
            ("b".to_string(), Some("a".to_string())),
        ]);
        assert!(ensure_acyclic_official_parent_graph(&cycle)
            .unwrap_err()
            .contains("包含环"));
    }

    #[test]
    fn deletion_impact_expands_spawned_closure_and_removes_redundant_selected_roots() {
        let threads = vec![
            impact_thread("root", None, None, Some(100), "notLoaded"),
            impact_thread("child", Some("root"), None, Some(200), "notLoaded"),
            impact_thread("grandchild", Some("child"), None, Some(300), "notLoaded"),
            impact_thread("fork", None, Some("child"), Some(400), "notLoaded"),
        ];
        let impact = deletion_impact(
            &threads,
            vec!["child".into(), "root".into(), "child".into()],
        )
        .unwrap();

        assert_eq!(impact.requested_ids, vec!["child", "root"]);
        assert_eq!(impact.effective_root_ids, vec!["root"]);
        assert_eq!(impact.affected_ids, vec!["root", "child", "grandchild"]);
        assert_eq!(impact.external_fork_reference_ids, vec!["fork"]);
        assert_eq!(impact.total_bytes, Some(600));
    }

    #[test]
    fn deletion_impact_is_cycle_safe_and_preserves_unknown_total_bytes() {
        let threads = vec![
            impact_thread("a", Some("b"), None, Some(1), "notLoaded"),
            impact_thread("b", Some("a"), None, None, "notLoaded"),
        ];
        let impact = deletion_impact(&threads, vec!["a".into(), "b".into()]).unwrap();

        assert_eq!(impact.effective_root_ids.len(), 1);
        assert_eq!(
            impact.affected_ids.iter().cloned().collect::<HashSet<_>>(),
            HashSet::from(["a".to_string(), "b".to_string()])
        );
        assert_eq!(impact.total_bytes, None);
    }

    #[test]
    fn delete_confirmation_requires_the_exact_ordered_roots_and_full_closure() {
        let threads = vec![
            impact_thread("root", None, None, Some(1), "notLoaded"),
            impact_thread("child", Some("root"), None, Some(2), "notLoaded"),
        ];
        let impact = deletion_impact(&threads, vec!["root".into()]).unwrap();
        let mut confirmation = SessionDeleteConfirmation {
            schema_version: DELETE_CONFIRMATION_SCHEMA_VERSION,
            prepared_at: 1,
            physical_home_key: "fixture".into(),
            requested_ids: impact.requested_ids.clone(),
            effective_root_ids: impact.effective_root_ids.clone(),
            affected_ids: impact.affected_ids.clone(),
            rollouts: Vec::new(),
        };
        validate_delete_confirmation_scope(&impact, &confirmation).unwrap();
        confirmation.affected_ids.reverse();
        assert!(validate_delete_confirmation_scope(&impact, &confirmation)
            .unwrap_err()
            .contains("范围已变化"));
        confirmation.affected_ids = impact.affected_ids.clone();
        confirmation.effective_root_ids.push("root".into());
        assert!(validate_delete_confirmation_scope(&impact, &confirmation).is_err());
    }

    #[test]
    fn permanent_delete_rejects_a_missing_recovery_archive_contract_before_any_io() {
        let home = TestHome::new("delete-recovery-required");
        let id = Uuid::new_v4().to_string();

        let result = delete_threads(
            &home.root,
            vec![id.clone()],
            false,
            "unused-source-key",
            SessionDeleteConfirmation {
                schema_version: DELETE_CONFIRMATION_SCHEMA_VERSION,
                prepared_at: 1,
                physical_home_key: "unused-source-key".into(),
                requested_ids: vec![id.clone()],
                effective_root_ids: vec![id.clone()],
                affected_ids: vec![id],
                rollouts: Vec::new(),
            },
        );

        assert_eq!(result.results.len(), 1);
        assert!(!result.results[0].ok);
        assert!(result.results[0]
            .message
            .as_deref()
            .is_some_and(|message| message.contains("完整 affected closure")));
    }

    #[test]
    fn failed_delete_batch_preserves_every_verified_recovery_path() {
        let root = Uuid::new_v4().to_string();
        let child = Uuid::new_v4().to_string();
        let recovery_paths = HashMap::from([
            (root.clone(), "/tmp/root.ctb-session.zip".to_string()),
            (child.clone(), "/tmp/child.ctb-session.zip".to_string()),
        ]);

        let result = failed_batch_with_recovery(
            std::slice::from_ref(&root),
            "delete blocked".into(),
            &recovery_paths,
        );

        assert_eq!(result.results.len(), 1);
        assert_eq!(
            result.results[0].recovery_archive_path.as_deref(),
            Some("/tmp/root.ctb-session.zip")
        );
        assert!(result
            .warnings
            .iter()
            .any(|warning| warning.contains(&child) && warning.contains("child.ctb-session.zip")));
    }

    #[test]
    fn read_only_rollout_scan_finds_threads_missing_from_state_database() {
        let home = TestHome::new("filesystem-scan");
        let id = Uuid::new_v4().to_string();
        let path = home.session_path(&id);
        fs::write(
            &path,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\",\"cwd\":\"/tmp/scanned\"}}}}\n"
            ),
        )
        .unwrap();

        let scan = scan_rollout_supplements(&home.root);

        assert!(scan.warnings.is_empty(), "{:?}", scan.warnings);
        assert_eq!(scan.supplements.get(&id).unwrap().cwd, "/tmp/scanned");
        assert_eq!(
            scan.supplements.get(&id).unwrap().rollout_path.as_deref(),
            Some(path.canonicalize().unwrap().as_path())
        );
    }

    #[test]
    fn rollout_scan_marks_the_same_session_id_at_multiple_paths_ambiguous() {
        let home = TestHome::new("filesystem-scan-duplicate");
        let id = Uuid::new_v4().to_string();
        let active = home.session_path(&id);
        let archived = home.archived_path(&id);
        let line = format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\"}}}}\n");
        fs::write(&active, &line).unwrap();
        fs::write(&archived, &line).unwrap();

        let scan = scan_rollout_supplements(&home.root);

        assert!(scan.ambiguous_ids.contains(&id));
        assert!(scan
            .warnings
            .iter()
            .any(|warning| warning.contains("多个 rollout")));
        assert!(find_rollout_by_id(&home.root, &id)
            .unwrap_err()
            .contains("2 个 rollout"));
    }

    #[test]
    fn catalog_combines_protocol_db_lineage_and_file_stat_without_deduplicating_threads() {
        let home = TestHome::new("catalog");
        let first = Uuid::new_v4().to_string();
        let second = Uuid::new_v4().to_string();
        let first_path = home.session_path(&first);
        let second_path = home.session_path(&second);
        fs::write(
            &first_path,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{first}\",\"session_id\":\"tree\",\"forked_from_id\":\"{second}\"}}}}\n"
            ),
        )
        .unwrap();
        fs::write(
            &second_path,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{second}\",\"session_id\":\"tree\",\"parent_thread_id\":\"{first}\"}}}}\n"
            ),
        )
        .unwrap();
        home.create_db(&[
            (&first, first_path.as_path(), false),
            (&second, second_path.as_path(), false),
        ]);
        let mut protocol = FakeProtocol {
            active: Ok(vec![
                json!({"id": first, "name": "one", "status": {"type": "idle"}, "updatedAt": 4}),
                json!({"id": second, "name": "two", "status": {"type": "notLoaded"}, "updatedAt": 5}),
            ]),
            archived: Ok(Vec::new()),
        };
        let catalog = list_catalog_with_protocol(&home.root, &mut protocol).unwrap();
        assert_eq!(catalog.threads.len(), 2);
        let first = catalog
            .threads
            .iter()
            .find(|thread| thread.title == "one")
            .unwrap();
        assert_eq!(first.fork_child_count, 0);
        assert_eq!(first.spawn_child_count, 1);
        assert_eq!(first.session_id.as_deref(), Some("tree"));
        assert!(catalog.total_bytes.is_some_and(|bytes| bytes > 0));
    }

    #[test]
    fn catalog_keeps_sqlite_rows_when_one_protocol_side_fails() {
        let home = TestHome::new("partial");
        let id = Uuid::new_v4().to_string();
        let path = home.session_path(&id);
        fs::write(
            &path,
            format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\"}}}}\n"),
        )
        .unwrap();
        home.create_db(&[(&id, path.as_path(), false)]);
        let mut protocol = FakeProtocol {
            active: Err("offline".into()),
            archived: Ok(Vec::new()),
        };
        let catalog = list_catalog_with_protocol(&home.root, &mut protocol).unwrap();
        assert_eq!(catalog.threads.len(), 1);
        assert!(catalog
            .warnings
            .iter()
            .any(|warning| warning.contains("offline")));
    }

    #[test]
    fn missing_optional_state_columns_remain_unknown_instead_of_becoming_zero() {
        let home = TestHome::new("sparse-state");
        let id = Uuid::new_v4().to_string();
        let path = home.session_path(&id);
        fs::write(
            &path,
            format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\"}}}}\n"),
        )
        .unwrap();
        let connection = Connection::open(home.root.join("state_5.sqlite")).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    rollout_path TEXT,
                    archived INTEGER
                );",
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO threads VALUES (?1, ?2, 0)",
                params![id, path.to_string_lossy()],
            )
            .unwrap();
        drop(connection);

        let rows = read_state_supplements(&home.root).unwrap();
        let row = rows.get(&id).unwrap();
        assert_eq!(row.created_at, None);
        assert_eq!(row.updated_at, None);
        assert_eq!(row.recency_at, None);
        assert_eq!(row.tokens_used, None);
    }

    #[test]
    fn context_pages_backward_ignore_partial_tail_and_preserve_access_to_earlier_pages() {
        let home = TestHome::new("context");
        let id = Uuid::new_v4().to_string();
        let path = home.session_path(&id);
        let content = format!(
            "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\"}}}}\n\
             {{\"timestamp\":\"one\",\"type\":\"response_item\",\"payload\":{{\"type\":\"message\",\"role\":\"user\",\"content\":[{{\"type\":\"input_text\",\"text\":\"first\"}}]}}}}\n\
             {{\"timestamp\":\"two\",\"type\":\"response_item\",\"payload\":{{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":\"second\"}}]}}}}\n\
             {{\"type\":\"response_item\",\"payload\":"
        );
        fs::write(&path, content).unwrap();
        home.create_db(&[(&id, path.as_path(), false)]);
        let latest = read_context_page(&home.root, &id, None, Some(1)).unwrap();
        assert_eq!(latest.messages.len(), 1);
        assert_eq!(latest.messages[0].content, "second");
        assert!(latest.has_more_before);
        assert!(latest
            .warnings
            .iter()
            .any(|warning| warning.contains("末尾")));
        let earlier =
            read_context_page(&home.root, &id, latest.next_before_offset, Some(1)).unwrap();
        assert_eq!(earlier.messages[0].content, "first");
    }

    #[test]
    fn context_large_line_streams_and_truncates_only_the_display_payload() {
        let home = TestHome::new("large-line");
        let id = Uuid::new_v4().to_string();
        let path = home.session_path(&id);
        let huge = "x".repeat(LARGE_LINE_THRESHOLD as usize + 4096);
        let mut file = File::create(&path).unwrap();
        writeln!(
            file,
            "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\"}}}}"
        )
        .unwrap();
        writeln!(
            file,
            "{}",
            json!({
                "timestamp": "now",
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": huge}]
                }
            })
        )
        .unwrap();
        home.create_db(&[(&id, path.as_path(), false)]);
        let page = read_context_page(&home.root, &id, None, Some(1)).unwrap();
        assert_eq!(page.messages.len(), 1);
        assert!(page.messages[0].content.len() < MESSAGE_DISPLAY_BYTES + 128);
        assert!(page.messages[0].content.contains("本条内容较大"));
    }

    #[test]
    fn trusted_rollout_rejects_path_traversal_and_symlink_escape() {
        let home = TestHome::new("traversal");
        let outside = home.root.parent().unwrap().join(format!(
            "outside-{}",
            TEST_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::write(&outside, "{}\n").unwrap();
        assert!(trusted_rollout_path(&home.root, Path::new("../outside")).is_err());
        #[cfg(unix)]
        {
            let link = home.root.join("sessions/escape.jsonl");
            std::os::unix::fs::symlink(&outside, &link).unwrap();
            assert!(trusted_rollout_path(&home.root, &link).is_err());
        }
        let _ = fs::remove_file(outside);
    }

    #[test]
    fn session_mutations_share_and_exclusively_lock_the_swift_lock_path() {
        let fixture = TestHome::new("shared-session-operation-lock");
        let home = fixture.root.as_path();
        let lock_path = session_operation_lock_path(home);
        assert_eq!(
            lock_path,
            home.join("backups_state")
                .join("codex-token-bar")
                .join("session-operation.lock")
        );
        let coordination_home = CoordinationHome::open(home).unwrap();
        let lock_directory = coordination_home.session_lock_directory().unwrap();
        assert_eq!(
            lock_directory.display_path(),
            lock_path.parent().unwrap().canonicalize().unwrap()
        );
        let first = CrossProcessFileLock::acquire_in(
            &lock_directory,
            "session-operation.lock",
            "测试会话写操作",
        )
        .unwrap();
        assert!(CrossProcessFileLock::try_acquire_in(
            &lock_directory,
            "session-operation.lock",
            "测试会话写操作",
        )
        .unwrap()
        .is_none());
        drop(first);
        assert!(CrossProcessFileLock::try_acquire_in(
            &lock_directory,
            "session-operation.lock",
            "测试会话写操作",
        )
        .unwrap()
        .is_some());
    }

    #[test]
    fn recovery_archive_rejects_duplicate_rollout_paths_for_the_same_session() {
        let home = TestHome::new("recovery-duplicate-rollout");
        let id = Uuid::new_v4().to_string();
        let active = home.session_path(&id);
        let archived = home.archived_path(&id);
        let line = format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\"}}}}\n");
        fs::write(&active, &line).unwrap();
        fs::write(&archived, &line).unwrap();
        home.create_db(&[(&id, archived.as_path(), true)]);

        let error =
            create_recovery_archive_at(&home.root, &id, &home.root.join("packages")).unwrap_err();

        assert!(error.message.contains("多个 rollout"), "{error}");
    }

    #[test]
    fn recovery_archive_is_verified_and_corrupt_existing_package_is_never_reused() {
        let home = TestHome::new("recovery");
        let id = Uuid::new_v4().to_string();
        let rollout = home.archived_path(&id);
        fs::write(
            &rollout,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\"}}}}\n\
                 {{\"type\":\"response_item\",\"payload\":{{\"type\":\"message\",\"role\":\"user\",\"content\":[{{\"text\":\"hello\"}}]}}}}\n"
            ),
        )
        .unwrap();
        home.create_db(&[(&id, rollout.as_path(), true)]);
        let packages = home.root.join("packages");
        let package = create_recovery_archive_at(&home.root, &id, &packages).unwrap();
        let digest = sha256_file(&rollout).unwrap();
        verify_recovery_archive(
            &package.path,
            &id,
            fs::metadata(&rollout).unwrap().len(),
            &digest,
            &rollout
                .strip_prefix(&home.root)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/"),
        )
        .unwrap();

        fs::write(&package.path, b"damaged").unwrap();
        let error = create_recovery_archive_at(&home.root, &id, &packages).unwrap_err();
        assert!(error.message.contains("完整回读校验失败"), "{error}");
        assert_eq!(fs::read(&package.path).unwrap(), b"damaged");
    }

    #[test]
    fn recovery_archive_accepts_an_unarchived_rollout() {
        let home = TestHome::new("recovery-unarchived");
        let id = Uuid::new_v4().to_string();
        let rollout = home.session_path(&id);
        fs::write(
            &rollout,
            format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\"}}}}\n"),
        )
        .unwrap();
        home.create_db(&[(&id, rollout.as_path(), false)]);

        let receipt =
            create_recovery_archive_at(&home.root, &id, &home.root.join("packages")).unwrap();

        assert!(receipt.path.is_file());
        assert_eq!(receipt.rollout_path, rollout.canonicalize().unwrap());
    }

    #[test]
    fn recovery_archive_uses_content_identity_so_later_versions_do_not_collide() {
        let home = TestHome::new("recovery-versioned");
        let id = Uuid::new_v4().to_string();
        let rollout = home.archived_path(&id);
        fs::write(
            &rollout,
            format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\"}}}}\n"),
        )
        .unwrap();
        home.create_db(&[(&id, rollout.as_path(), true)]);
        let packages = home.root.join("packages");
        let first = create_recovery_archive_at(&home.root, &id, &packages).unwrap();
        fs::OpenOptions::new()
            .append(true)
            .open(&rollout)
            .unwrap()
            .write_all(b"{\"changed\":true}\n")
            .unwrap();
        let second = create_recovery_archive_at(&home.root, &id, &packages).unwrap();

        assert_ne!(first.path, second.path);
        assert!(first.path.is_file());
        assert!(second.path.is_file());
    }

    #[test]
    fn recovery_receipt_freezes_digest_size_and_physical_rollout_identity() {
        let home = TestHome::new("recovery-receipt");
        let id = Uuid::new_v4().to_string();
        let rollout = home.archived_path(&id);
        fs::write(
            &rollout,
            format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\"}}}}\n"),
        )
        .unwrap();
        home.create_db(&[(&id, rollout.as_path(), true)]);
        let receipt =
            create_recovery_archive_at(&home.root, &id, &home.root.join("packages")).unwrap();
        verify_recovery_receipt(&home.root, &id, &receipt).unwrap();

        fs::OpenOptions::new()
            .append(true)
            .open(&rollout)
            .unwrap()
            .write_all(b"{\"changed\":true}\n")
            .unwrap();
        let error = verify_recovery_receipt(&home.root, &id, &receipt).unwrap_err();
        assert!(
            error.contains("已变化") || error.contains("摘要"),
            "{error}"
        );
    }

    #[test]
    fn delete_confirmation_freezes_rollout_path_identity_size_time_and_digest() {
        let home = TestHome::new("delete-confirmation-snapshot");
        let id = Uuid::new_v4().to_string();
        let rollout = home.archived_path(&id);
        fs::write(
            &rollout,
            format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\"}}}}\n"),
        )
        .unwrap();
        home.create_db(&[(&id, rollout.as_path(), true)]);
        let impact = deletion_impact(
            &[impact_thread(
                &id,
                None,
                None,
                Some(fs::metadata(&rollout).unwrap().len()),
                "notLoaded",
            )],
            vec![id.clone()],
        )
        .unwrap();
        let source_key = crate::commands::dashboard::physical_home_key(&home.root).unwrap();
        let confirmation = build_delete_confirmation(&home.root, &source_key, &impact).unwrap();

        assert_eq!(confirmation.physical_home_key, source_key);
        assert_eq!(confirmation.requested_ids, vec![id.clone()]);
        assert_eq!(confirmation.effective_root_ids, vec![id.clone()]);
        assert_eq!(confirmation.affected_ids, vec![id.clone()]);
        assert_eq!(confirmation.rollouts.len(), 1);
        let snapshot = &confirmation.rollouts[0];
        assert_eq!(snapshot.thread_id, id);
        assert_eq!(
            snapshot.canonical_relative_path,
            rollout
                .strip_prefix(&home.root)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/")
        );
        assert_eq!(
            snapshot.size_bytes,
            fs::metadata(&rollout).unwrap().len().to_string()
        );
        assert_eq!(snapshot.sha256.len(), 64);
        assert!(!snapshot.physical_identity.is_empty());
    }

    #[test]
    fn delete_confirmation_fails_when_a_descendant_appears_during_snapshotting() {
        use std::cell::Cell;

        let home = TestHome::new("delete-confirmation-descendant-race");
        let root_id = Uuid::new_v4().to_string();
        let child_id = Uuid::new_v4().to_string();
        let root_rollout = home.session_path(&root_id);
        let child_rollout = home.session_path(&child_id);
        fs::write(
            &root_rollout,
            format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{root_id}\"}}}}\n"),
        )
        .unwrap();
        let initial = deletion_impact(
            &[impact_thread(
                &root_id,
                None,
                None,
                Some(fs::metadata(&root_rollout).unwrap().len()),
                "notLoaded",
            )],
            vec![root_id.clone()],
        )
        .unwrap();
        let expanded = deletion_impact(
            &[
                impact_thread(
                    &root_id,
                    None,
                    None,
                    Some(fs::metadata(&root_rollout).unwrap().len()),
                    "notLoaded",
                ),
                impact_thread(&child_id, Some(&root_id), None, Some(1), "notLoaded"),
            ],
            vec![root_id.clone()],
        )
        .unwrap();
        let source_key = crate::commands::dashboard::physical_home_key(&home.root).unwrap();
        let reads = Cell::new(0_u8);

        let error = prepare_delete_confirmation_after_initial(
            &home.root,
            &source_key,
            std::slice::from_ref(&root_id),
            initial.clone(),
            || {
                let call = reads.get();
                reads.set(call + 1);
                Ok(if call == 0 {
                    initial.clone()
                } else {
                    expanded.clone()
                })
            },
            || {
                fs::write(
                    &child_rollout,
                    format!(
                        "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{child_id}\",\"parent_thread_id\":\"{root_id}\"}}}}\n"
                    ),
                )
                .map_err(|error| error.to_string())
            },
        )
        .unwrap_err();

        assert_eq!(
            reads.get(),
            2,
            "locked and final closure reads are required"
        );
        assert!(error.contains("建立删除确认快照期间"), "{error}");
        assert!(error.contains("spawned 后代范围发生变化"), "{error}");
    }

    #[test]
    fn generic_mutation_path_cannot_launch_permanent_delete() {
        let source = include_str!("session_management.rs");
        let start = source.find("fn mutate_one(").unwrap();
        let end = start
            + source[start..]
                .find("\nfn run_official_cli(")
                .expect("mutate_one source boundary");
        let delete_variant = ["OfficialMutation", "::", "Delete"].concat();
        assert!(
            !source[start..end].contains(&delete_variant),
            "generic archive/unarchive mutation path must not regain a delete branch"
        );

        let guarded_call = [
            "run_official_cli(codex_home, root_id, ",
            "OfficialMutation",
            "::",
            "Delete)",
        ]
        .concat();
        assert_eq!(
            source.matches(&guarded_call).count(),
            1,
            "permanent delete CLI must have exactly one source call site"
        );
    }

    #[test]
    fn parent_rollout_swap_after_prior_checks_prevents_cli_executor_call() {
        use std::cell::Cell;

        let home = TestHome::new("delete-pre-cli-parent-swap");
        let id = Uuid::new_v4().to_string();
        let rollout = home.session_path(&id);
        let content = format!(
            "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\"}}}}\n\
             {{\"type\":\"response_item\",\"payload\":{{\"type\":\"message\",\"role\":\"user\",\"content\":[{{\"text\":\"fixed\"}}]}}}}\n"
        );
        fs::write(&rollout, &content).unwrap();
        home.create_db(&[(&id, rollout.as_path(), false)]);
        let impact = deletion_impact(
            &[impact_thread(
                &id,
                None,
                None,
                Some(content.len() as u64),
                "notLoaded",
            )],
            vec![id.clone()],
        )
        .unwrap();
        let source_key = crate::commands::dashboard::physical_home_key(&home.root).unwrap();
        let confirmation = build_delete_confirmation(&home.root, &source_key, &impact).unwrap();
        let receipt =
            create_recovery_archive_at(&home.root, &id, &home.root.join("packages")).unwrap();
        validate_receipt_against_confirmation(&id, &receipt, &confirmation).unwrap();
        let receipts = HashMap::from([(id.clone(), receipt)]);
        let parent = rollout.parent().unwrap().to_path_buf();
        let detached = home.root.join("detached-session-day");
        let file_name = rollout.file_name().unwrap().to_owned();
        let calls = Cell::new(0_u64);

        let error = execute_delete_cli_with_final_gate(
            &home.root,
            &source_key,
            std::slice::from_ref(&id),
            std::slice::from_ref(&id),
            &confirmation,
            &receipts,
            || {
                fs::rename(&parent, &detached).map_err(|error| error.to_string())?;
                fs::create_dir_all(&parent).map_err(|error| error.to_string())?;
                fs::write(parent.join(file_name), &content).map_err(|error| error.to_string())
            },
            || Ok(impact.clone()),
            || {
                calls.set(calls.get() + 1);
                Ok(())
            },
        )
        .err()
        .expect("pre-launch rollout substitution must fail closed");

        assert_eq!(calls.get(), 0, "official CLI executor must not run");
        assert!(
            error.contains("已变化") || error.contains("不同") || error.contains("物理身份"),
            "{error}"
        );
    }

    #[test]
    fn descendant_appearing_after_recovery_hashing_prevents_cli_executor_call() {
        use std::cell::Cell;

        let home = TestHome::new("delete-pre-cli-descendant-race");
        let root_id = Uuid::new_v4().to_string();
        let child_id = Uuid::new_v4().to_string();
        let root_rollout = home.session_path(&root_id);
        let child_rollout = home.session_path(&child_id);
        let root_content =
            format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{root_id}\"}}}}\n");
        fs::write(&root_rollout, &root_content).unwrap();
        home.create_db(&[(&root_id, root_rollout.as_path(), false)]);
        let initial = deletion_impact(
            &[impact_thread(
                &root_id,
                None,
                None,
                Some(root_content.len() as u64),
                "notLoaded",
            )],
            vec![root_id.clone()],
        )
        .unwrap();
        let expanded = deletion_impact(
            &[
                impact_thread(
                    &root_id,
                    None,
                    None,
                    Some(root_content.len() as u64),
                    "notLoaded",
                ),
                impact_thread(&child_id, Some(&root_id), None, Some(1), "notLoaded"),
            ],
            vec![root_id.clone()],
        )
        .unwrap();
        let source_key = crate::commands::dashboard::physical_home_key(&home.root).unwrap();
        let confirmation = build_delete_confirmation(&home.root, &source_key, &initial).unwrap();
        let receipt =
            create_recovery_archive_at(&home.root, &root_id, &home.root.join("packages")).unwrap();
        let receipts = HashMap::from([(root_id.clone(), receipt)]);
        let calls = Cell::new(0_u64);

        let error = execute_delete_cli_with_final_gate(
            &home.root,
            &source_key,
            std::slice::from_ref(&root_id),
            std::slice::from_ref(&root_id),
            &confirmation,
            &receipts,
            || Ok(()),
            || {
                fs::write(
                    &child_rollout,
                    format!(
                        "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{child_id}\",\"parent_thread_id\":\"{root_id}\"}}}}\n"
                    ),
                )
                .map_err(|error| error.to_string())?;
                Ok(expanded.clone())
            },
            || {
                calls.set(calls.get() + 1);
                Ok(())
            },
        )
        .err()
        .expect("new descendant must invalidate the final delete scope");

        assert_eq!(calls.get(), 0, "official CLI executor must not run");
        assert!(error.contains("剩余范围已变化"), "{error}");
    }

    #[test]
    fn pinned_recovery_root_cleans_only_owned_staging_names_and_rejects_symlinks() {
        let home = TestHome::new("recovery-staging-cleanup");
        let packages = home.root.join("packages");
        fs::create_dir_all(&packages).unwrap();
        let id = Uuid::new_v4();
        let stale_tmp = packages.join(format!(".{id}.12-34.tmp"));
        let stale_partial = packages.join(format!(".{id}.56-78.partial"));
        let unrelated = packages.join("keep-me.tmp");
        fs::write(&stale_tmp, b"stale").unwrap();
        fs::write(&stale_partial, b"stale").unwrap();
        fs::write(&unrelated, b"keep").unwrap();

        let pinned = PinnedRecoveryRoot::prepare(&packages).unwrap();
        assert!(!stale_tmp.exists());
        assert!(!stale_partial.exists());
        assert_eq!(fs::read(&unrelated).unwrap(), b"keep");
        drop(pinned);

        #[cfg(unix)]
        {
            let linked_root = home.root.join("linked-packages");
            std::os::unix::fs::symlink(&packages, &linked_root).unwrap();
            assert!(PinnedRecoveryRoot::prepare(&linked_root)
                .err()
                .expect("symlink recovery root must fail closed")
                .contains("符号链接"));
        }
    }

    #[test]
    fn published_package_path_survives_post_publish_verification_failure() {
        let home = TestHome::new("recovery-published-error");
        let id = Uuid::new_v4().to_string();
        let rollout = home.archived_path(&id);
        fs::write(
            &rollout,
            format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\"}}}}\n"),
        )
        .unwrap();
        home.create_db(&[(&id, rollout.as_path(), true)]);
        let packages = home.root.join("packages");
        let error = create_recovery_archive_at_with_hooks(
            &home.root,
            &id,
            &packages,
            |_| Ok(()),
            |published| fs::write(published, b"damaged").map_err(|error| error.to_string()),
        )
        .unwrap_err();

        let published = error.published_path.expect("published path must survive");
        assert!(published.is_file());
        assert!(error.message.contains("已发布"));
    }

    #[test]
    fn recovery_archive_rejects_rollout_with_different_first_line_id() {
        let home = TestHome::new("recovery-mismatched-id");
        let id = Uuid::new_v4().to_string();
        let other_id = Uuid::new_v4().to_string();
        let rollout = home.archived_path(&id);
        fs::write(
            &rollout,
            format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{other_id}\"}}}}\n"),
        )
        .unwrap();
        home.create_db(&[(&id, rollout.as_path(), true)]);
        let packages = home.root.join("packages");

        let error = create_recovery_archive_at(&home.root, &id, &packages).unwrap_err();

        assert!(
            error.message.contains("首行 ID 与目标会话不一致"),
            "{error}"
        );
        assert!(!packages.join(format!("{id}.ctb-session.zip")).exists());
    }

    #[test]
    fn recovery_archive_roots_are_namespaced_by_physical_codex_home() {
        let first = recovery_archive_root("unix:1:100").unwrap();
        let repeated = recovery_archive_root("unix:1:100").unwrap();
        let second = recovery_archive_root("unix:1:200").unwrap();

        assert_eq!(first, repeated);
        assert_ne!(first, second);
        assert!(first
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with("source-"));
    }

    #[test]
    fn recovery_archive_rejects_source_identity_change_before_publish() {
        let home = TestHome::new("recovery-source-change");
        let id = Uuid::new_v4().to_string();
        let rollout = home.archived_path(&id);
        fs::write(
            &rollout,
            format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\"}}}}\n"),
        )
        .unwrap();
        home.create_db(&[(&id, rollout.as_path(), true)]);
        let packages = home.root.join("packages");
        let error = create_recovery_archive_at_with_hook(&home.root, &id, &packages, |source| {
            let mut file = fs::OpenOptions::new()
                .append(true)
                .open(source)
                .map_err(|error| error.to_string())?;
            file.write_all(b"{\"changed\":true}\n")
                .map_err(|error| error.to_string())
        })
        .unwrap_err();
        assert!(
            error.message.contains("回读校验失败") || error.message.contains("压缩期间发生变化"),
            "{error}"
        );
        assert!(!packages.join(format!("{id}.ctb-session.zip")).exists());
        assert!(fs::read_dir(&packages).unwrap().all(|entry| !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .ends_with(".tmp")));
    }

    #[test]
    fn dto_serialization_keeps_unix_seconds_nullable_numbers_and_iso_message_timestamp() {
        let thread = SessionManagementThread {
            id: Uuid::new_v4().to_string(),
            title: "title".into(),
            preview: String::new(),
            cwd: "/tmp".into(),
            created_at: Some(1_722_222_222),
            updated_at: None,
            recency_at: Some(1_722_222_333),
            archived: false,
            archived_at: None,
            tokens_used: None,
            file_bytes: None,
            file_modified_at: Some(1_722_222_444),
            status: "notLoaded".into(),
            source: None,
            model: Some("gpt-test".into()),
            session_id: None,
            forked_from_id: None,
            parent_thread_id: None,
            is_subagent: false,
            spawn_child_count: 0,
            fork_child_count: 0,
            similarity_group_id: None,
            similarity_reason: None,
            protection_reasons: Vec::new(),
            can_archive: true,
            can_unarchive: false,
            can_delete: true,
        };
        let value = serde_json::to_value(&thread).unwrap();
        assert_eq!(
            value.get("createdAt").and_then(Value::as_i64),
            Some(1_722_222_222)
        );
        assert!(value.get("updatedAt").is_some_and(Value::is_null));
        assert!(value.get("fileBytes").is_some_and(Value::is_null));
        assert!(value.get("source").is_some_and(Value::is_null));

        let message = SessionContextMessage {
            id: "message".into(),
            role: "user".into(),
            content: "hello".into(),
            timestamp: Some("2026-07-30T15:00:00Z".into()),
            offset: 42,
            kind: "message".into(),
        };
        let value = serde_json::to_value(message).unwrap();
        assert_eq!(
            value.get("timestamp").and_then(Value::as_str),
            Some("2026-07-30T15:00:00Z")
        );
    }

    #[test]
    fn batch_runner_stops_after_first_failure_and_marks_later_items_unexecuted() {
        let first = Uuid::new_v4().to_string();
        let second = Uuid::new_v4().to_string();
        let third = Uuid::new_v4().to_string();
        let mut visited = Vec::new();
        let result = collect_batch_results(
            vec![first.clone(), second.clone(), third.clone()],
            |thread_id| {
                visited.push(thread_id.to_string());
                if thread_id == second {
                    Err("simulated runner failure".into())
                } else {
                    Ok(("ok".into(), None))
                }
            },
        );
        assert_eq!(visited, vec![first, second.clone()]);
        assert_eq!(result.results.len(), 3);
        assert!(!result.results[1].ok);
        assert!(result.results[1]
            .message
            .as_deref()
            .is_some_and(|message| message.contains("simulated")));
        assert!(!result.results[2].ok);
        assert!(result.results[2]
            .message
            .as_deref()
            .is_some_and(|message| message.contains("未执行")));
    }

    #[test]
    fn only_exact_not_loaded_status_passes_the_mutation_status_gate() {
        assert_eq!(status_protection_reason("notLoaded"), None);
        for status in [
            "notloaded",
            "NotLoaded",
            "not_loaded",
            "not loaded",
            "idle",
            "active",
            "loaded",
            "systemError",
            "unknown",
            "",
        ] {
            assert!(
                status_protection_reason(status).is_some(),
                "{status} must fail closed"
            );
        }
    }
}
