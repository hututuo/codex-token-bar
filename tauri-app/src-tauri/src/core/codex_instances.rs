use crate::core::{
    app_paths, atomic_file, auto_resume, cross_process_lock::CrossProcessFileLock,
};
use crate::models::{
    CodexControlledProcess, CodexInstance, CodexInstanceActionResult, CodexInstanceConflict,
    CodexInstanceCreateMode, CodexInstanceCreateRequest, CodexInstanceImportRequest,
    CodexInstanceRegistrySnapshot, CodexInstanceRuntimeStatus, CodexInstanceSyncOperation,
    CodexInstanceSyncPreview, CodexInstanceSyncResult, CodexInstanceSyncTransactionSummary,
    CodexInstanceUpdateRequest,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use time::OffsetDateTime;
use uuid::Uuid;

const REGISTRY_SCHEMA_VERSION: u32 = 1;
const TRANSACTION_SCHEMA_VERSION: u32 = 1;
const FIRST_LINE_LIMIT: u64 = 1024 * 1024;
const CONFIGURATION_FILES: &[&str] = &["config.toml", "AGENTS.md"];
const CONFIGURATION_DIRECTORIES: &[&str] = &["rules", "skills"];

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct CodexInstanceRegistry {
    schema_version: u32,
    updated_at: i64,
    instances: Vec<CodexInstance>,
    conflicts: Vec<CodexInstanceConflict>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SyncTransaction {
    schema_version: u32,
    transaction_id: String,
    created_at: i64,
    state: String,
    instance_ids: Vec<String>,
    operations: Vec<CodexInstanceSyncOperation>,
    conflicts: Vec<CodexInstanceConflict>,
}

#[derive(Clone, Debug)]
struct InstancePaths {
    registry: PathBuf,
    managed_root: PathBuf,
    sync_root: PathBuf,
}

impl InstancePaths {
    fn system() -> Result<Self, String> {
        Ok(Self {
            registry: app_paths::codex_instances_registry_path()?,
            managed_root: app_paths::codex_instances_managed_root()?,
            sync_root: app_paths::codex_instance_sync_root()?,
        })
    }
}

#[derive(Clone, Debug)]
struct RolloutFile {
    instance_id: String,
    thread_id: String,
    path: PathBuf,
    relative_path: PathBuf,
    length: u64,
    hash: String,
}

pub fn list_instances() -> Result<CodexInstanceRegistrySnapshot, String> {
    list_instances_at(&InstancePaths::system()?)
}

pub fn create_instance(
    request: CodexInstanceCreateRequest,
) -> Result<CodexInstanceActionResult, String> {
    let paths = InstancePaths::system()?;
    let _sync_lock = acquire_sync_lock(&paths)?;
    let _registry_lock = acquire_registry_lock(&paths)?;
    validate_name(&request.name)?;
    validate_arguments(&request.arguments)?;
    let working_directory = validate_optional_directory(request.working_directory.as_deref())?;
    let mut registry = load_registry(&paths)?;
    let id = Uuid::new_v4().to_string();
    let instance_root = paths.managed_root.join(&id);
    let home = instance_root.join("home");
    let electron = instance_root.join("electron-data");
    fs::create_dir_all(&home).map_err(|error| format!("创建实例 Codex Home 失败：{error}"))?;
    if let Err(error) = fs::create_dir_all(&electron) {
        let _ = fs::remove_dir_all(&instance_root);
        return Err(format!("创建实例桌面数据目录失败：{error}"));
    }
    let copy_result = match request.mode {
        CodexInstanceCreateMode::Empty => Ok(()),
        CodexInstanceCreateMode::CopyConfiguration => {
            let source = request
                .source_home
                .as_deref()
                .map(PathBuf::from)
                .unwrap_or_else(crate::platform::default_codex_home);
            copy_configuration(&source, &home, request.copy_auth)
        }
    };
    if let Err(error) = copy_result {
        let _ = fs::remove_dir_all(&instance_root);
        return Err(error);
    }
    let now = now_millis();
    let instance = CodexInstance {
        id,
        name: request.name.trim().to_string(),
        codex_home: canonical_existing(&home)?.display().to_string(),
        electron_data_directory: canonical_existing(&electron)?.display().to_string(),
        working_directory: working_directory.map(|path| path.display().to_string()),
        arguments: request.arguments,
        managed: true,
        is_default: false,
        auto_sync_enabled: request.auto_sync_enabled,
        created_at: now,
        updated_at: now,
        controlled_process: None,
    };
    ensure_unique_home(&registry, &instance.codex_home, None)?;
    registry.instances.push(instance.clone());
    if let Err(error) = save_registry(&paths, &mut registry) {
        let _ = fs::remove_dir_all(&instance_root);
        return Err(error);
    }
    Ok(CodexInstanceActionResult {
        instance: Some(instance),
        message: "Codex 实例已创建；它拥有独立的会话目录和桌面数据目录。".into(),
    })
}

pub fn import_instance(
    request: CodexInstanceImportRequest,
) -> Result<CodexInstanceActionResult, String> {
    let paths = InstancePaths::system()?;
    let _sync_lock = acquire_sync_lock(&paths)?;
    let _registry_lock = acquire_registry_lock(&paths)?;
    validate_name(&request.name)?;
    validate_arguments(&request.arguments)?;
    let home = canonical_directory(Path::new(&request.codex_home), "Codex Home")?;
    ensure_disjoint_from_managed_root(&paths, &home)?;
    let working_directory = validate_optional_directory(request.working_directory.as_deref())?;
    let mut registry = load_registry(&paths)?;
    ensure_unique_home(&registry, &home.display().to_string(), None)?;
    let id = Uuid::new_v4().to_string();
    let instance_root = paths.managed_root.join(&id);
    let electron = instance_root.join("electron-data");
    fs::create_dir_all(&electron).map_err(|error| format!("创建实例桌面数据目录失败：{error}"))?;
    let now = now_millis();
    let instance = CodexInstance {
        id,
        name: request.name.trim().to_string(),
        codex_home: home.display().to_string(),
        electron_data_directory: canonical_existing(&electron)?.display().to_string(),
        working_directory: working_directory.map(|path| path.display().to_string()),
        arguments: request.arguments,
        managed: false,
        is_default: false,
        auto_sync_enabled: request.auto_sync_enabled,
        created_at: now,
        updated_at: now,
        controlled_process: None,
    };
    registry.instances.push(instance.clone());
    if let Err(error) = save_registry(&paths, &mut registry) {
        let _ = fs::remove_dir_all(&instance_root);
        return Err(error);
    }
    Ok(CodexInstanceActionResult {
        instance: Some(instance),
        message: "已有 Codex Home 已登记；取消登记时不会删除原目录。".into(),
    })
}

pub fn update_instance(
    request: CodexInstanceUpdateRequest,
) -> Result<CodexInstanceActionResult, String> {
    let paths = InstancePaths::system()?;
    let _sync_lock = acquire_sync_lock(&paths)?;
    let _registry_lock = acquire_registry_lock(&paths)?;
    ensure_no_unfinished_transactions(&paths, std::slice::from_ref(&request.id))?;
    validate_name(&request.name)?;
    validate_arguments(&request.arguments)?;
    let working_directory = validate_optional_directory(request.working_directory.as_deref())?;
    let mut registry = load_registry(&paths)?;
    let instance = registry
        .instances
        .iter_mut()
        .find(|instance| instance.id == request.id)
        .ok_or_else(|| "没有找到要修改的 Codex 实例".to_string())?;
    ensure_instance_stopped(instance)?;
    instance.name = request.name.trim().to_string();
    instance.working_directory = working_directory.map(|path| path.display().to_string());
    instance.arguments = request.arguments;
    instance.auto_sync_enabled = request.auto_sync_enabled;
    instance.updated_at = now_millis();
    let updated = instance.clone();
    save_registry(&paths, &mut registry)?;
    Ok(CodexInstanceActionResult {
        instance: Some(updated),
        message: "实例设置已保存。".into(),
    })
}

pub fn delete_instance(id: &str) -> Result<CodexInstanceActionResult, String> {
    if id == "default" {
        return Err("默认实例不能删除".into());
    }
    let paths = InstancePaths::system()?;
    let _sync_lock = acquire_sync_lock(&paths)?;
    let _registry_lock = acquire_registry_lock(&paths)?;
    ensure_no_unfinished_transactions(&paths, &[id.to_string()])?;
    let mut registry = load_registry(&paths)?;
    let index = registry
        .instances
        .iter()
        .position(|instance| instance.id == id)
        .ok_or_else(|| "没有找到要删除的 Codex 实例".to_string())?;
    let instance = registry.instances[index].clone();
    ensure_instance_stopped(&instance)?;
    let root = validate_owned_instance_root(&paths, &instance)?;
    let renamed = paths
        .managed_root
        .join(format!(".{}-delete-{}", instance.id, Uuid::new_v4()));
    fs::rename(&root, &renamed).map_err(|error| format!("暂存待删除实例失败：{error}"))?;
    let quarantine = Some((root, renamed));
    registry.instances.remove(index);
    registry
        .conflicts
        .retain(|conflict| !conflict.instance_ids.iter().any(|value| value == id));
    if let Err(error) = save_registry(&paths, &mut registry) {
        if let Some((root, renamed)) = &quarantine {
            let _ = fs::rename(renamed, root);
        }
        return Err(error);
    }
    let cleanup_warning = quarantine.and_then(|(_, renamed)| {
        fs::remove_dir_all(&renamed)
            .err()
            .map(|error| format!("（登记已移除，但清理 Token Bar 所有目录失败：{error}）"))
    });
    Ok(CodexInstanceActionResult {
        instance: None,
        message: if instance.managed {
            format!(
                "托管实例及其独立目录已删除。{}",
                cleanup_warning.unwrap_or_default()
            )
        } else {
            format!(
                "外部实例已取消登记；原 Codex Home 保持不变。{}",
                cleanup_warning.unwrap_or_default()
            )
        },
    })
}

pub fn instance_runtime_status(id: &str) -> Result<CodexInstanceRuntimeStatus, String> {
    let paths = InstancePaths::system()?;
    let _registry_lock = acquire_registry_lock(&paths)?;
    let registry = load_registry(&paths)?;
    let instances = with_default_instance(registry.instances)?;
    let instance = instances
        .iter()
        .find(|instance| instance.id == id)
        .ok_or_else(|| "没有找到 Codex 实例".to_string())?;
    runtime_status(instance)
}

pub fn list_instance_runtime_statuses() -> Result<Vec<CodexInstanceRuntimeStatus>, String> {
    let paths = InstancePaths::system()?;
    let _registry_lock = acquire_registry_lock(&paths)?;
    let registry = load_registry(&paths)?;
    Ok(with_default_instance(registry.instances)?
        .iter()
        .map(|instance| match runtime_status(instance) {
            Ok(status) => status,
            Err(error) => CodexInstanceRuntimeStatus {
                id: instance.id.clone(),
                running: true,
                controlled: false,
                pid: None,
                message: format!("状态无法可靠确认，已按运行中锁定危险操作：{error}"),
            },
        })
        .collect())
}

pub fn launch_instance(id: &str) -> Result<CodexInstanceActionResult, String> {
    if id == "default" {
        return Err("默认实例由系统正常入口启动，实例管理器不会重复启动它".into());
    }
    let paths = InstancePaths::system()?;
    let _sync_lock = acquire_sync_lock(&paths)?;
    let _registry_lock = acquire_registry_lock(&paths)?;
    ensure_no_unfinished_transactions(&paths, &[id.to_string()])?;
    let mut registry = load_registry(&paths)?;
    let auto_sync_enabled = registry
        .instances
        .iter()
        .find(|instance| instance.id == id)
        .ok_or_else(|| "没有找到 Codex 实例".to_string())?
        .auto_sync_enabled;
    let auto_sync_message = if auto_sync_enabled {
        run_auto_sync_if_ready(&paths, &mut registry)?.map(|result| result.message)
    } else {
        None
    };
    let instance = registry
        .instances
        .iter_mut()
        .find(|instance| instance.id == id)
        .ok_or_else(|| "没有找到 Codex 实例".to_string())?;
    let status = runtime_status(instance)?;
    if status.running {
        return Ok(CodexInstanceActionResult {
            instance: Some(instance.clone()),
            message: "实例已在运行。".into(),
        });
    }
    fs::create_dir_all(&instance.electron_data_directory)
        .map_err(|error| format!("创建实例桌面数据目录失败：{error}"))?;
    let launch = crate::platform::launch_managed_codex_instance(
        Path::new(&instance.codex_home),
        Path::new(&instance.electron_data_directory),
        instance.working_directory.as_deref().map(Path::new),
        &instance.arguments,
    )?;
    let now = now_millis();
    instance.controlled_process = Some(CodexControlledProcess {
        pid: launch.pid,
        executable_path: launch.executable_path.display().to_string(),
        user_data_marker: launch.user_data_marker.clone(),
        started_at: now,
        process_start_identity: launch.process_start_identity.clone(),
    });
    instance.updated_at = now;
    let launched = instance.clone();
    if let Err(error) = save_registry(&paths, &mut registry) {
        let cleanup = terminate_just_launched_process(&launch);
        return Err(match cleanup {
            Ok(()) => format!("Codex 实例已启动，但控制信息未能保存；已终止未登记实例：{error}"),
            Err(cleanup_error) => format!(
                "Codex 实例已启动，但控制信息未能保存：{error}；终止未登记实例也失败：{cleanup_error}"
            ),
        });
    }
    Ok(CodexInstanceActionResult {
        instance: Some(launched),
        message: match auto_sync_message {
            Some(message) => format!("{message} Codex 实例已用独立环境启动。"),
            None => "Codex 实例已用独立环境启动。".into(),
        },
    })
}

pub fn focus_instance(id: &str) -> Result<CodexInstanceActionResult, String> {
    let paths = InstancePaths::system()?;
    let _registry_lock = acquire_registry_lock(&paths)?;
    let registry = load_registry(&paths)?;
    let instance = registry
        .instances
        .iter()
        .find(|instance| instance.id == id)
        .ok_or_else(|| "只能聚焦由实例管理器登记的实例".to_string())?;
    let process = verified_controlled_process(instance)?
        .ok_or_else(|| "该实例没有由 Token Bar 启动的可验证进程".to_string())?;
    crate::platform::focus_managed_process(process.pid)?;
    Ok(CodexInstanceActionResult {
        instance: Some(instance.clone()),
        message: "已切换到该 Codex 实例。".into(),
    })
}

pub fn stop_instance(id: &str) -> Result<CodexInstanceActionResult, String> {
    if id == "default" {
        return Err("实例管理器不会停止默认 Codex，避免中断当前任务".into());
    }
    let paths = InstancePaths::system()?;
    let _sync_lock = acquire_sync_lock(&paths)?;
    let _registry_lock = acquire_registry_lock(&paths)?;
    let mut registry = load_registry(&paths)?;
    let instance = registry
        .instances
        .iter_mut()
        .find(|instance| instance.id == id)
        .ok_or_else(|| "没有找到 Codex 实例".to_string())?;
    let process = verified_controlled_process(instance)?
        .ok_or_else(|| "没有找到由 Token Bar 启动且身份匹配的实例进程".to_string())?;
    crate::platform::terminate_managed_process(process.pid)?;
    wait_for_process_exit(process.pid, &process.process_start_identity)?;
    instance.controlled_process = None;
    instance.updated_at = now_millis();
    let stopped = instance.clone();
    save_registry(&paths, &mut registry)?;
    let auto_sync_message = if stopped.auto_sync_enabled {
        match run_auto_sync_if_ready(&paths, &mut registry) {
            Ok(result) => result.map(|result| result.message),
            Err(error) => Some(format!("自动同步已暂停：{error}")),
        }
    } else {
        None
    };
    Ok(CodexInstanceActionResult {
        instance: Some(stopped),
        message: match auto_sync_message {
            Some(message) => format!("实例已退出。{message}"),
            None => "实例已退出。".into(),
        },
    })
}

pub fn preview_sync(instance_ids: Vec<String>) -> Result<CodexInstanceSyncPreview, String> {
    let paths = InstancePaths::system()?;
    let _sync_lock = acquire_sync_lock(&paths)?;
    let _registry_lock = acquire_registry_lock(&paths)?;
    ensure_no_unfinished_transactions(&paths, &instance_ids)?;
    let registry = load_registry(&paths)?;
    let instances = select_instances(with_default_instance(registry.instances)?, &instance_ids)?;
    ensure_all_stopped(&instances)?;
    build_sync_preview(&instances)
}

pub fn sync_instances(instance_ids: Vec<String>) -> Result<CodexInstanceSyncResult, String> {
    let paths = InstancePaths::system()?;
    let _sync_lock = acquire_sync_lock(&paths)?;
    let _registry_lock = acquire_registry_lock(&paths)?;
    ensure_no_unfinished_transactions(&paths, &instance_ids)?;
    let mut registry = load_registry(&paths)?;
    let instances = select_instances(
        with_default_instance(registry.instances.clone())?,
        &instance_ids,
    )?;
    ensure_all_stopped(&instances)?;
    sync_instances_locked(&paths, &mut registry, instances)
}

fn sync_instances_locked(
    paths: &InstancePaths,
    registry: &mut CodexInstanceRegistry,
    instances: Vec<CodexInstance>,
) -> Result<CodexInstanceSyncResult, String> {
    sync_instances_locked_with_visibility(paths, registry, instances, &mut |home| {
        auto_resume::rebuild_conversation_visibility_metadata(home).map(|_| ())
    })
}

fn sync_instances_locked_with_visibility(
    paths: &InstancePaths,
    registry: &mut CodexInstanceRegistry,
    instances: Vec<CodexInstance>,
    rebuild_visibility: &mut dyn FnMut(&Path) -> Result<(), String>,
) -> Result<CodexInstanceSyncResult, String> {
    sync_instances_locked_with_visibility_and_open_file_probe(
        paths,
        registry,
        instances,
        rebuild_visibility,
        &mut |candidates| crate::platform::files_open_in_other_processes(candidates),
    )
}

fn sync_instances_locked_with_visibility_and_open_file_probe(
    paths: &InstancePaths,
    registry: &mut CodexInstanceRegistry,
    instances: Vec<CodexInstance>,
    rebuild_visibility: &mut dyn FnMut(&Path) -> Result<(), String>,
    open_file_probe: &mut dyn FnMut(&[PathBuf]) -> Result<Vec<String>, String>,
) -> Result<CodexInstanceSyncResult, String> {
    let preview = build_sync_preview(&instances)?;
    if preview.operations.is_empty() && preview.conflicts.is_empty() {
        return Ok(CodexInstanceSyncResult {
            transaction_id: None,
            operations_applied: 0,
            conflicts: Vec::new(),
            message: "所选实例的会话历史已经一致。".into(),
        });
    }
    let mut candidates = Vec::new();
    for operation in &preview.operations {
        candidates.push(PathBuf::from(&operation.source_path));
        candidates.push(PathBuf::from(&operation.destination_path));
    }
    candidates.sort();
    candidates.dedup();
    ensure_files_not_open_elsewhere_with_probe(
        &candidates,
        "实例同步",
        open_file_probe,
    )?;
    let transaction_id = Uuid::new_v4().to_string();
    let transaction_root = transaction_root(paths, &transaction_id);
    fs::create_dir_all(&transaction_root)
        .map_err(|error| format!("创建实例同步事务目录失败：{error}"))?;
    let mut transaction = SyncTransaction {
        schema_version: TRANSACTION_SCHEMA_VERSION,
        transaction_id: transaction_id.clone(),
        created_at: now_millis(),
        state: "prepared".into(),
        instance_ids: preview.instance_ids.clone(),
        operations: preview
            .operations
            .into_iter()
            .enumerate()
            .map(|(index, mut operation)| {
                if operation.destination_hash.is_some() {
                    operation.backup_path = Some(
                        transaction_root
                            .join("backups")
                            .join(format!("{index:08}.jsonl"))
                            .display()
                            .to_string(),
                    );
                }
                operation
            })
            .collect(),
        conflicts: preview.conflicts.clone(),
    };
    if let Err(error) = write_transaction(&transaction_root, &transaction) {
        let _ = fs::remove_dir_all(&transaction_root);
        return Err(error);
    }
    let apply_result = apply_transaction_with_open_file_probe(
        paths,
        &instances,
        &mut transaction,
        open_file_probe,
    );
    if let Err(error) = apply_result {
        let rollback_error = rollback_transaction_files_with_open_file_probe(
            paths,
            &instances,
            &mut transaction,
            open_file_probe,
        )
        .err();
        transaction.state = if rollback_error.is_some() {
            "failedNeedsRecovery".into()
        } else {
            "rolledBackAfterFailure".into()
        };
        let state_write_error = write_transaction(&transaction_root, &transaction).err();
        let mut message = match rollback_error {
            Some(rollback) => format!("{error}；自动回滚也失败：{rollback}"),
            None => format!("{error}；已自动回滚本次实例同步"),
        };
        if let Some(write_error) = state_write_error {
            message.push_str(&format!(
                "；事务状态未能持久化（回滚已幂等，可重试收敛）：{write_error}"
            ));
        }
        return Err(message);
    }
    transaction.state = "committed".into();
    write_transaction(&transaction_root, &transaction)?;
    merge_conflicts(&mut registry.conflicts, &transaction.conflicts);
    let registry_warning = save_registry(paths, registry).err();

    let mut warnings = rebuild_visibility_for_instances(&instances, rebuild_visibility);
    if let Some(error) = registry_warning {
        warnings.push(format!(
            "分歧摘要注册表未能保存，但会话事务已经提交：{error}"
        ));
    }
    let message = if warnings.is_empty() {
        format!(
            "实例同步完成：写入 {} 项，保留 {} 个分歧供人工处理，并已重建官方会话索引。",
            transaction.operations.len(),
            transaction.conflicts.len()
        )
    } else {
        format!(
            "实例同步完成：写入 {} 项，保留 {} 个分歧；后处理未全部完成：{}",
            transaction.operations.len(),
            transaction.conflicts.len(),
            warnings.join("；")
        )
    };
    Ok(CodexInstanceSyncResult {
        transaction_id: Some(transaction_id),
        operations_applied: transaction.operations.len(),
        conflicts: transaction.conflicts,
        message,
    })
}

fn rebuild_visibility_for_instances(
    instances: &[CodexInstance],
    rebuild_visibility: &mut dyn FnMut(&Path) -> Result<(), String>,
) -> Vec<String> {
    let mut warnings = Vec::new();
    for instance in instances {
        if let Err(error) = rebuild_visibility(Path::new(&instance.codex_home)) {
            warnings.push(format!("{}：{error}", instance.name));
        }
    }
    warnings
}

fn merge_conflicts(existing: &mut Vec<CodexInstanceConflict>, incoming: &[CodexInstanceConflict]) {
    for conflict in incoming {
        if let Some(current) = existing
            .iter_mut()
            .find(|current| !current.resolved && same_conflict(current, conflict))
        {
            current.instance_ids = conflict.instance_ids.clone();
            current.relative_paths = conflict.relative_paths.clone();
            current.hashes = conflict.hashes.clone();
            current.detected_at = conflict.detected_at;
            current.reason = conflict.reason.clone();
        } else {
            existing.push(conflict.clone());
        }
    }
}

fn same_conflict(left: &CodexInstanceConflict, right: &CodexInstanceConflict) -> bool {
    let mut left_instances = left.instance_ids.clone();
    let mut right_instances = right.instance_ids.clone();
    let mut left_hashes = left.hashes.clone();
    let mut right_hashes = right.hashes.clone();
    left_instances.sort();
    right_instances.sort();
    left_hashes.sort();
    right_hashes.sort();
    left.thread_id == right.thread_id
        && left_instances == right_instances
        && left_hashes == right_hashes
}

fn run_auto_sync_if_ready(
    paths: &InstancePaths,
    registry: &mut CodexInstanceRegistry,
) -> Result<Option<CodexInstanceSyncResult>, String> {
    let ids = auto_sync_instance_ids(registry);
    if ids.len() < 2 {
        return Ok(None);
    }
    ensure_no_unfinished_transactions(paths, &ids)?;
    let instances = select_instances(with_default_instance(registry.instances.clone())?, &ids)?;
    if instances
        .iter()
        .map(runtime_status)
        .collect::<Result<Vec<_>, _>>()?
        .iter()
        .any(|status| status.running)
    {
        return Ok(None);
    }
    sync_instances_locked(paths, registry, instances).map(Some)
}

fn auto_sync_instance_ids(registry: &CodexInstanceRegistry) -> Vec<String> {
    let mut ids = vec!["default".to_string()];
    ids.extend(
        registry
            .instances
            .iter()
            .filter(|instance| instance.auto_sync_enabled)
            .map(|instance| instance.id.clone()),
    );
    ids
}

pub fn list_sync_transactions() -> Result<Vec<CodexInstanceSyncTransactionSummary>, String> {
    let paths = InstancePaths::system()?;
    let transactions = paths.sync_root.join("transactions");
    if !transactions.exists() {
        return Ok(Vec::new());
    }
    let mut summaries = Vec::new();
    for entry in
        fs::read_dir(&transactions).map_err(|error| format!("读取实例同步事务失败：{error}"))?
    {
        let entry = entry.map_err(|error| format!("读取实例同步事务条目失败：{error}"))?;
        if !entry
            .file_type()
            .map_err(|error| error.to_string())?
            .is_dir()
        {
            continue;
        }
        if !entry.path().join("manifest.json").is_file() {
            continue;
        }
        let transaction = read_transaction(&entry.path())?;
        summaries.push(CodexInstanceSyncTransactionSummary {
            transaction_id: transaction.transaction_id,
            created_at: transaction.created_at,
            state: transaction.state,
            instance_ids: transaction.instance_ids,
            operations: transaction.operations.len(),
            conflicts: transaction.conflicts.len(),
        });
    }
    summaries.sort_by(|left, right| right.created_at.cmp(&left.created_at));
    Ok(summaries)
}

pub fn rollback_sync_transaction(transaction_id: &str) -> Result<CodexInstanceSyncResult, String> {
    let paths = InstancePaths::system()?;
    let _sync_lock = acquire_sync_lock(&paths)?;
    let _registry_lock = acquire_registry_lock(&paths)?;
    if Uuid::parse_str(transaction_id).is_err() {
        return Err("实例同步事务编号无效".into());
    }
    let root = transaction_root(&paths, transaction_id);
    let mut transaction = read_transaction(&root)?;
    if !["committed", "failedNeedsRecovery", "prepared"].contains(&transaction.state.as_str()) {
        return Err(format!("事务状态 {} 不能回滚", transaction.state));
    }
    ensure_transaction_is_latest_recoverable(&paths, &transaction)?;
    let registry = load_registry(&paths)?;
    let instances = select_instances(
        with_default_instance(registry.instances)?,
        &transaction.instance_ids,
    )?;
    ensure_all_stopped(&instances)?;
    rollback_transaction_files(&paths, &instances, &mut transaction)?;
    transaction.state = "rolledBack".into();
    write_transaction(&root, &transaction)?;
    let warnings = rebuild_visibility_for_instances(&instances, &mut |home| {
        auto_resume::rebuild_conversation_visibility_metadata(home).map(|_| ())
    });
    let visibility_suffix = if warnings.is_empty() {
        "并已重建官方会话索引。".to_string()
    } else {
        format!("但官方会话索引未全部重建：{}", warnings.join("；"))
    };
    Ok(CodexInstanceSyncResult {
        transaction_id: Some(transaction.transaction_id),
        operations_applied: transaction.operations.len(),
        conflicts: transaction.conflicts,
        message: format!(
            "实例同步事务已回滚；只恢复了仍与本事务写入值一致的文件，{visibility_suffix}"
        ),
    })
}

fn list_instances_at(paths: &InstancePaths) -> Result<CodexInstanceRegistrySnapshot, String> {
    let _registry_lock = acquire_registry_lock(paths)?;
    let registry = load_registry(paths)?;
    Ok(CodexInstanceRegistrySnapshot {
        schema_version: registry.schema_version,
        updated_at: registry.updated_at,
        instances: with_default_instance(registry.instances)?,
        conflicts: registry.conflicts,
        registry_path: paths.registry.display().to_string(),
    })
}

fn acquire_registry_lock(paths: &InstancePaths) -> Result<CrossProcessFileLock, String> {
    CrossProcessFileLock::acquire(&paths.registry.with_extension("lock"), "实例注册表")
}

fn acquire_sync_lock(paths: &InstancePaths) -> Result<CrossProcessFileLock, String> {
    CrossProcessFileLock::acquire(&paths.sync_root.join("instance-sync.lock"), "实例同步")
}

fn load_registry(paths: &InstancePaths) -> Result<CodexInstanceRegistry, String> {
    if !paths.registry.exists() {
        return Ok(CodexInstanceRegistry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            updated_at: now_millis(),
            instances: Vec::new(),
            conflicts: Vec::new(),
        });
    }
    let bytes =
        fs::read(&paths.registry).map_err(|error| format!("读取 Codex 实例注册表失败：{error}"))?;
    let registry: CodexInstanceRegistry = match serde_json::from_slice(&bytes) {
        Ok(registry) => registry,
        Err(error) => {
            let corrupt = paths
                .registry
                .with_extension(format!("corrupt-{}", now_millis()));
            fs::rename(&paths.registry, &corrupt).map_err(|rename_error| {
                format!("实例注册表损坏且无法隔离：{error}；{rename_error}")
            })?;
            return Err(format!(
                "实例注册表格式损坏，已原样隔离到 {}；没有静默重建空列表",
                corrupt.display()
            ));
        }
    };
    if registry.schema_version != REGISTRY_SCHEMA_VERSION {
        return Err(format!(
            "不支持的实例注册表版本 {}，当前支持 {}",
            registry.schema_version, REGISTRY_SCHEMA_VERSION
        ));
    }
    validate_registry(&registry)?;
    Ok(registry)
}

fn save_registry(
    paths: &InstancePaths,
    registry: &mut CodexInstanceRegistry,
) -> Result<(), String> {
    registry.schema_version = REGISTRY_SCHEMA_VERSION;
    registry.updated_at = now_millis();
    validate_registry(registry)?;
    let bytes = serde_json::to_vec_pretty(registry)
        .map_err(|error| format!("编码 Codex 实例注册表失败：{error}"))?;
    accept_committed_atomic_write(
        atomic_file::write_atomically(&paths.registry, &bytes),
        "Codex 实例注册表",
    )
}

fn validate_registry(registry: &CodexInstanceRegistry) -> Result<(), String> {
    let mut ids = HashSet::new();
    let mut homes = Vec::<PathBuf>::new();
    for instance in &registry.instances {
        if instance.is_default || instance.id == "default" {
            return Err("持久化实例注册表不能包含默认实例".into());
        }
        if Uuid::parse_str(&instance.id).is_err() {
            return Err(format!("实例 {} 的编号无效", instance.name));
        }
        if !ids.insert(instance.id.clone()) {
            return Err(format!("实例编号重复：{}", instance.id));
        }
        let normalized = canonical_or_absolute(Path::new(&instance.codex_home))?;
        for existing in &homes {
            if paths_overlap(existing, &normalized)? {
                return Err(format!(
                    "多个实例的 Codex Home 相同或相互嵌套：{}",
                    instance.codex_home
                ));
            }
        }
        homes.push(normalized);
        validate_name(&instance.name)?;
        validate_arguments(&instance.arguments)?;
    }
    Ok(())
}

fn with_default_instance(mut instances: Vec<CodexInstance>) -> Result<Vec<CodexInstance>, String> {
    let home = crate::platform::default_codex_home();
    let home_display = canonical_or_absolute(&home)?.display().to_string();
    let now = now_millis();
    instances.insert(
        0,
        CodexInstance {
            id: "default".into(),
            name: "默认 Codex".into(),
            codex_home: home_display,
            electron_data_directory: String::new(),
            working_directory: None,
            arguments: Vec::new(),
            managed: false,
            is_default: true,
            auto_sync_enabled: false,
            created_at: now,
            updated_at: now,
            controlled_process: None,
        },
    );
    Ok(instances)
}

fn validate_name(name: &str) -> Result<(), String> {
    if name.trim().is_empty() {
        Err("实例名称不能为空".into())
    } else if name.chars().any(|character| character == '\0') {
        Err("实例名称包含无效字符".into())
    } else {
        Ok(())
    }
}

fn validate_arguments(arguments: &[String]) -> Result<(), String> {
    if arguments.iter().any(|argument| argument.contains('\0')) {
        Err("启动参数包含无效的空字符".into())
    } else if arguments
        .iter()
        .any(|argument| argument.starts_with("--user-data-dir"))
    {
        Err("无需手动设置 --user-data-dir；Token Bar 会为每个实例生成独立目录".into())
    } else {
        Ok(())
    }
}

fn validate_optional_directory(path: Option<&str>) -> Result<Option<PathBuf>, String> {
    path.filter(|value| !value.trim().is_empty())
        .map(|value| canonical_directory(Path::new(value), "工作目录"))
        .transpose()
}

fn canonical_directory(path: &Path, label: &str) -> Result<PathBuf, String> {
    let canonical = path
        .canonicalize()
        .map_err(|error| format!("{label}不存在或无法访问：{error}"))?;
    if canonical.is_dir() {
        Ok(canonical)
    } else {
        Err(format!("{label}不是目录：{}", canonical.display()))
    }
}

fn canonical_existing(path: &Path) -> Result<PathBuf, String> {
    path.canonicalize()
        .map_err(|error| format!("无法解析路径 {}：{error}", path.display()))
}

fn canonical_or_absolute(path: &Path) -> Result<PathBuf, String> {
    if path.exists() {
        return canonical_existing(path);
    }
    if path.is_absolute() {
        normalize_absolute(path)
    } else {
        normalize_absolute(
            &std::env::current_dir()
                .map_err(|error| format!("读取当前目录失败：{error}"))?
                .join(path),
        )
    }
}

fn normalize_absolute(path: &Path) -> Result<PathBuf, String> {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            Component::RootDir => normalized.push(component.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                if !normalized.pop() {
                    return Err(format!("路径越过根目录：{}", path.display()));
                }
            }
            Component::Normal(value) => normalized.push(value),
        }
    }
    Ok(normalized)
}

fn comparable_path(path: &Path) -> Result<String, String> {
    let value = canonical_or_absolute(path)?.display().to_string();
    if cfg!(windows) {
        Ok(value.to_lowercase())
    } else {
        Ok(value)
    }
}

fn paths_overlap(left: &Path, right: &Path) -> Result<bool, String> {
    let left = comparable_path(left)?;
    let right = comparable_path(right)?;
    Ok(path_key_contains(&left, &right) || path_key_contains(&right, &left))
}

fn path_key_contains(parent: &str, candidate: &str) -> bool {
    if parent == candidate {
        return true;
    }
    candidate
        .strip_prefix(parent)
        .is_some_and(|suffix| suffix.starts_with(std::path::MAIN_SEPARATOR))
}

fn ensure_disjoint_from_managed_root(paths: &InstancePaths, home: &Path) -> Result<(), String> {
    if paths_overlap(&paths.managed_root, home)? {
        Err("外部 Codex Home 不能位于 Token Bar 实例目录内，也不能包含该目录".into())
    } else {
        Ok(())
    }
}

fn ensure_unique_home(
    registry: &CodexInstanceRegistry,
    home: &str,
    excluding_id: Option<&str>,
) -> Result<(), String> {
    let requested_home = Path::new(home);
    for instance in &registry.instances {
        if excluding_id != Some(instance.id.as_str())
            && paths_overlap(Path::new(&instance.codex_home), requested_home)?
        {
            return Err("该 Codex Home 与另一个实例相同或相互嵌套".into());
        }
    }
    let default = crate::platform::default_codex_home();
    if paths_overlap(requested_home, &default)? {
        Err("该 Codex Home 与只读默认实例相同或相互嵌套，无法登记".into())
    } else {
        Ok(())
    }
}

fn copy_configuration(source: &Path, destination: &Path, copy_auth: bool) -> Result<(), String> {
    let source = canonical_directory(source, "源 Codex Home")?;
    for name in CONFIGURATION_FILES {
        let from = source.join(name);
        if from.exists() {
            copy_regular_file(&from, &destination.join(name))?;
        }
    }
    if copy_auth {
        let auth = source.join("auth.json");
        if auth.exists() {
            copy_regular_file(&auth, &destination.join("auth.json"))?;
        }
    }
    for name in CONFIGURATION_DIRECTORIES {
        let from = source.join(name);
        if from.exists() {
            copy_directory_without_links(&from, &destination.join(name))?;
        }
    }
    Ok(())
}

fn copy_directory_without_links(source: &Path, destination: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(source)
        .map_err(|error| format!("读取配置目录失败 {}：{error}", source.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(format!("拒绝复制非普通配置目录：{}", source.display()));
    }
    fs::create_dir_all(destination)
        .map_err(|error| format!("创建配置目录失败 {}：{error}", destination.display()))?;
    for entry in fs::read_dir(source)
        .map_err(|error| format!("读取配置目录失败 {}：{error}", source.display()))?
    {
        let entry = entry.map_err(|error| format!("读取配置目录条目失败：{error}"))?;
        let from = entry.path();
        let to = destination.join(entry.file_name());
        let metadata = fs::symlink_metadata(&from)
            .map_err(|error| format!("读取配置条目失败 {}：{error}", from.display()))?;
        if metadata.file_type().is_symlink() {
            return Err(format!(
                "配置目录包含符号链接，已拒绝复制：{}",
                from.display()
            ));
        }
        if metadata.is_dir() {
            copy_directory_without_links(&from, &to)?;
        } else if metadata.is_file() {
            copy_regular_file(&from, &to)?;
        } else {
            return Err(format!(
                "配置目录包含特殊文件，已拒绝复制：{}",
                from.display()
            ));
        }
    }
    Ok(())
}

fn copy_regular_file(source: &Path, destination: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(source)
        .map_err(|error| format!("读取配置文件失败 {}：{error}", source.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(format!("拒绝复制非普通配置文件：{}", source.display()));
    }
    let expected = hash_file(source)?;
    copy_atomically_verified(source, destination, &expected)?;
    let _ = fs::set_permissions(destination, metadata.permissions());
    Ok(())
}

fn validate_owned_instance_root(
    paths: &InstancePaths,
    instance: &CodexInstance,
) -> Result<PathBuf, String> {
    if Uuid::parse_str(&instance.id).is_err() {
        return Err("实例编号无效，拒绝删除目录".into());
    }
    let managed_root = canonical_directory(&paths.managed_root, "托管实例根目录")?;
    let root = canonical_directory(&paths.managed_root.join(&instance.id), "托管实例目录")?;
    if root.parent() != Some(managed_root.as_path()) {
        return Err("托管实例目录不在受控根目录的直接子级，拒绝删除".into());
    }
    let expected_electron = canonical_directory(&root.join("electron-data"), "实例桌面数据目录")?;
    let actual_electron = canonical_directory(
        Path::new(&instance.electron_data_directory),
        "注册表桌面数据目录",
    )?;
    if expected_electron != actual_electron {
        return Err("注册表桌面数据路径与 Token Bar 所有目录不一致，拒绝删除".into());
    }
    if instance.managed {
        let expected_home = canonical_directory(&root.join("home"), "托管实例 Codex Home")?;
        let actual_home = canonical_directory(Path::new(&instance.codex_home), "实例 Codex Home")?;
        if expected_home != actual_home {
            return Err("实例注册表路径与托管目录不一致，拒绝删除".into());
        }
    }
    Ok(root)
}

fn runtime_status(instance: &CodexInstance) -> Result<CodexInstanceRuntimeStatus, String> {
    if instance.is_default {
        let running = crate::platform::codex_desktop_is_running()?;
        return Ok(CodexInstanceRuntimeStatus {
            id: instance.id.clone(),
            running,
            controlled: false,
            pid: None,
            message: if running {
                "默认 Codex 正在运行；实例同步将保持锁定。".into()
            } else {
                "默认 Codex 未运行。".into()
            },
        });
    }
    if let Some(process) = verified_controlled_process(instance)? {
        return Ok(CodexInstanceRuntimeStatus {
            id: instance.id.clone(),
            running: true,
            controlled: true,
            pid: Some(process.pid),
            message: "由 Token Bar 启动，进程身份与独立数据目录均已核对。".into(),
        });
    }
    if let Some(pid) = find_process_by_marker(&instance.electron_data_directory)? {
        return Ok(CodexInstanceRuntimeStatus {
            id: instance.id.clone(),
            running: true,
            controlled: false,
            pid: Some(pid),
            message: "发现使用该实例数据目录的进程，但它不是本次受控启动，不能由 Token Bar 停止。"
                .into(),
        });
    }
    if !instance.managed && crate::platform::codex_desktop_is_running()? {
        return Ok(CodexInstanceRuntimeStatus {
            id: instance.id.clone(),
            running: true,
            controlled: false,
            pid: None,
            message: "存在无法归属的 Codex 进程；外部实例按运行中处理，避免误同步。".into(),
        });
    }
    Ok(CodexInstanceRuntimeStatus {
        id: instance.id.clone(),
        running: false,
        controlled: false,
        pid: None,
        message: "实例未运行。".into(),
    })
}

fn verified_controlled_process(
    instance: &CodexInstance,
) -> Result<Option<&CodexControlledProcess>, String> {
    let Some(process) = instance.controlled_process.as_ref() else {
        return Ok(None);
    };
    let identity = match crate::platform::managed_process_identity(process.pid) {
        Ok(identity) => identity,
        Err(_) => return Ok(None),
    };
    if identity != process.process_start_identity {
        return Ok(None);
    }
    let executable = crate::platform::managed_process_executable_path(process.pid)?;
    if comparable_path(&executable)? != comparable_path(Path::new(&process.executable_path))? {
        return Ok(None);
    }
    let command = crate::platform::managed_process_command(process.pid)?;
    if !crate::platform::process_command_contains_argument(&command, &process.user_data_marker) {
        return Ok(None);
    }
    Ok(Some(process))
}

fn terminate_just_launched_process(
    launch: &crate::platform::ManagedCodexLaunch,
) -> Result<(), String> {
    match crate::platform::managed_process_identity(launch.pid) {
        Err(_) => return Ok(()),
        Ok(identity) if identity != launch.process_start_identity => {
            return Err("未登记进程编号已被复用，已拒绝停止其他进程".into());
        }
        Ok(_) => {}
    }
    crate::platform::terminate_managed_process(launch.pid)?;
    wait_for_process_exit(launch.pid, &launch.process_start_identity)
}

fn wait_for_process_exit(pid: u32, expected_identity: &str) -> Result<(), String> {
    for _ in 0..100 {
        match crate::platform::managed_process_identity(pid) {
            Err(_) => return Ok(()),
            Ok(identity) if identity != expected_identity => return Ok(()),
            Ok(_) => std::thread::sleep(std::time::Duration::from_millis(100)),
        }
    }
    Err("等待 Codex 实例退出超时；进程身份仍匹配，注册表未清除控制信息".into())
}

fn find_process_by_marker(electron_directory: &str) -> Result<Option<u32>, String> {
    if electron_directory.is_empty() {
        return Ok(None);
    }
    let marker = format!("--user-data-dir={electron_directory}");
    #[cfg(unix)]
    {
        let output = Command::new("/bin/ps")
            .args(["-axo", "pid=,command="])
            .output()
            .map_err(|error| format!("检查实例进程失败：{error}"))?;
        if !output.status.success() {
            return Err("检查实例进程失败".into());
        }
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            let trimmed = line.trim_start();
            let split = trimmed.find(char::is_whitespace);
            let Some(split) = split else { continue };
            let Ok(pid) = trimmed[..split].parse::<u32>() else {
                continue;
            };
            if crate::platform::process_command_contains_argument(&trimmed[split..], &marker) {
                return Ok(Some(pid));
            }
        }
        Ok(None)
    }
    #[cfg(windows)]
    {
        let script = "$ErrorActionPreference='Stop'; Get-CimInstance Win32_Process | ForEach-Object { [Console]::Out.WriteLine(\"$($_.ProcessId)`t$($_.CommandLine)\") }";
        let output = Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command", script])
            .output()
            .map_err(|error| format!("检查实例进程失败：{error}"))?;
        if !output.status.success() {
            return Err("检查实例进程失败，已拒绝把状态判定为停止".into());
        }
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            let Some((pid, command)) = line.split_once('\t') else {
                continue;
            };
            if crate::platform::process_command_contains_argument(command, &marker) {
                if let Ok(pid) = pid.parse() {
                    return Ok(Some(pid));
                }
            }
        }
        Ok(None)
    }
    #[cfg(not(any(unix, windows)))]
    {
        Err("当前平台无法可靠检查实例进程".into())
    }
}

fn ensure_instance_stopped(instance: &CodexInstance) -> Result<(), String> {
    let status = runtime_status(instance)?;
    if status.running {
        Err(format!(
            "{} 正在运行；停止后才能修改、删除或同步",
            instance.name
        ))
    } else {
        Ok(())
    }
}

fn ensure_all_stopped(instances: &[CodexInstance]) -> Result<(), String> {
    for instance in instances {
        ensure_instance_stopped(instance)?;
    }
    Ok(())
}

// 运行检测（受控进程 / marker / 桌面 App）覆盖不到 codex CLI 这类无 marker 的
// 进程；若同步 rename 时 CLI 仍持旧 inode 追加，事件会静默丢失。改写前对全部
// 候选文件检查打开句柄，检测到或无法检测都 fail closed。
fn ensure_files_not_open_elsewhere_with_probe(
    candidates: &[PathBuf],
    operation: &str,
    probe: &mut dyn FnMut(&[PathBuf]) -> Result<Vec<String>, String>,
) -> Result<(), String> {
    let held = probe(candidates)?;
    if held.is_empty() {
        return Ok(());
    }
    let shown = held.iter().take(3).cloned().collect::<Vec<_>>().join("；");
    let suffix = if held.len() > 3 {
        format!("；等共 {} 个文件", held.len())
    } else {
        String::new()
    };
    Err(format!(
        "{operation}已取消：检测到其他进程正打开候选会话文件（codex CLI 等非桌面进程\
         不在运行检测范围内，请先退出后重试）：{shown}{suffix}"
    ))
}

fn select_instances(all: Vec<CodexInstance>, ids: &[String]) -> Result<Vec<CodexInstance>, String> {
    let unique = ids.iter().collect::<HashSet<_>>();
    if unique.len() < 2 {
        return Err("实例同步至少需要选择两个不同实例".into());
    }
    let by_id = all
        .into_iter()
        .map(|instance| (instance.id.clone(), instance))
        .collect::<HashMap<_, _>>();
    let mut selected = Vec::new();
    for id in ids {
        if selected
            .iter()
            .any(|instance: &CodexInstance| instance.id == *id)
        {
            continue;
        }
        selected.push(
            by_id
                .get(id)
                .cloned()
                .ok_or_else(|| format!("没有找到 Codex 实例 {id}"))?,
        );
    }
    Ok(selected)
}

fn build_sync_preview(instances: &[CodexInstance]) -> Result<CodexInstanceSyncPreview, String> {
    let mut by_thread: BTreeMap<String, HashMap<String, Vec<RolloutFile>>> = BTreeMap::new();
    for instance in instances {
        for rollout in collect_rollouts(instance)? {
            by_thread
                .entry(rollout.thread_id.clone())
                .or_default()
                .entry(instance.id.clone())
                .or_default()
                .push(rollout);
        }
    }
    let mut operations = Vec::new();
    let mut conflicts = Vec::new();
    let mut unchanged_threads = 0_usize;
    for (thread_id, versions_by_instance) in by_thread {
        if versions_by_instance
            .values()
            .any(|versions| versions.len() != 1)
        {
            conflicts.push(conflict_for_versions(
                &thread_id,
                versions_by_instance.values().flatten().collect(),
                "同一实例内存在多个同编号会话文件，未自动选择",
            ));
            continue;
        }
        let versions = versions_by_instance
            .values()
            .filter_map(|versions| versions.first())
            .collect::<Vec<_>>();
        let archive_states = versions
            .iter()
            .filter_map(|version| rollout_is_archived(&version.relative_path))
            .collect::<HashSet<_>>();
        if archive_states.len() != 1 {
            conflicts.push(conflict_for_versions(
                &thread_id,
                versions.clone(),
                "同一会话在不同实例的活动/归档状态不一致，未自动移动",
            ));
            continue;
        }
        let mut candidate = versions[0];
        let mut divergent = false;
        for version in versions.iter().skip(1) {
            if version.hash == candidate.hash {
                continue;
            }
            if candidate.length <= version.length && file_is_prefix(&candidate.path, &version.path)?
            {
                candidate = version;
            } else if version.length <= candidate.length
                && file_is_prefix(&version.path, &candidate.path)?
            {
            } else {
                divergent = true;
                break;
            }
        }
        if divergent {
            conflicts.push(conflict_for_versions(
                &thread_id,
                versions.clone(),
                "同一会话存在相互分叉的事件流；已保留各版本，不做逐行拼接",
            ));
            continue;
        }
        let mut thread_operations = 0_usize;
        for instance in instances {
            match versions_by_instance
                .get(&instance.id)
                .and_then(|versions| versions.first())
            {
                None => {
                    let destination =
                        Path::new(&instance.codex_home).join(&candidate.relative_path);
                    operations.push(CodexInstanceSyncOperation {
                        thread_id: thread_id.clone(),
                        source_instance_id: candidate.instance_id.clone(),
                        destination_instance_id: instance.id.clone(),
                        source_path: candidate.path.display().to_string(),
                        destination_path: destination.display().to_string(),
                        kind: "missing".into(),
                        source_hash: candidate.hash.clone(),
                        destination_hash: None,
                        backup_path: None,
                        installed_hash: None,
                    });
                    thread_operations += 1;
                }
                Some(existing) if existing.hash == candidate.hash => {}
                Some(existing)
                    if existing.length < candidate.length
                        && file_is_prefix(&existing.path, &candidate.path)? =>
                {
                    operations.push(CodexInstanceSyncOperation {
                        thread_id: thread_id.clone(),
                        source_instance_id: candidate.instance_id.clone(),
                        destination_instance_id: instance.id.clone(),
                        source_path: candidate.path.display().to_string(),
                        destination_path: existing.path.display().to_string(),
                        kind: "fastForward".into(),
                        source_hash: candidate.hash.clone(),
                        destination_hash: Some(existing.hash.clone()),
                        backup_path: None,
                        installed_hash: None,
                    });
                    thread_operations += 1;
                }
                Some(_) => {
                    conflicts.push(conflict_for_versions(
                        &thread_id,
                        versions.clone(),
                        "会话版本无法证明为严格前缀，未自动覆盖",
                    ));
                }
            }
        }
        if thread_operations == 0 {
            unchanged_threads += 1;
        }
    }
    Ok(CodexInstanceSyncPreview {
        instance_ids: instances
            .iter()
            .map(|instance| instance.id.clone())
            .collect(),
        operations,
        conflicts,
        unchanged_threads,
    })
}

fn rollout_is_archived(relative_path: &Path) -> Option<bool> {
    match relative_path.components().next() {
        Some(Component::Normal(value)) if value == "sessions" => Some(false),
        Some(Component::Normal(value)) if value == "archived_sessions" => Some(true),
        _ => None,
    }
}

fn collect_rollouts(instance: &CodexInstance) -> Result<Vec<RolloutFile>, String> {
    let home = canonical_directory(Path::new(&instance.codex_home), "实例 Codex Home")?;
    let mut files = Vec::new();
    for directory_name in ["sessions", "archived_sessions"] {
        let root = home.join(directory_name);
        let root_metadata = match fs::symlink_metadata(&root) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(format!("读取会话根目录失败 {}：{error}", root.display()));
            }
        };
        if root_metadata.file_type().is_symlink() || !root_metadata.is_dir() {
            return Err(format!(
                "会话根目录不是 Codex Home 内的真实目录：{}",
                root.display()
            ));
        }
        let root = canonical_existing(&root)?;
        if !root.starts_with(&home) || root == home {
            return Err(format!("会话根目录越过 Codex Home：{}", root.display()));
        }
        let mut stack = vec![root];
        while let Some(directory) = stack.pop() {
            for entry in fs::read_dir(&directory)
                .map_err(|error| format!("读取会话目录失败 {}：{error}", directory.display()))?
            {
                let entry = entry.map_err(|error| format!("读取会话条目失败：{error}"))?;
                let path = entry.path();
                let metadata = fs::symlink_metadata(&path)
                    .map_err(|error| format!("读取会话条目失败 {}：{error}", path.display()))?;
                if metadata.file_type().is_symlink() {
                    continue;
                }
                if metadata.is_dir() {
                    let path = canonical_existing(&path)?;
                    if !path.starts_with(&home) || path == home {
                        return Err(format!("会话目录越过 Codex Home：{}", path.display()));
                    }
                    stack.push(path);
                } else if metadata.is_file()
                    && path.extension().and_then(|value| value.to_str()) == Some("jsonl")
                {
                    let path = canonical_existing(&path)?;
                    if !path.starts_with(&home) || path == home {
                        return Err(format!("会话路径越过 Codex Home：{}", path.display()));
                    }
                    let Some(thread_id) = canonical_thread_id(&path)? else {
                        continue;
                    };
                    files.push(RolloutFile {
                        instance_id: instance.id.clone(),
                        thread_id,
                        relative_path: path
                            .strip_prefix(&home)
                            .map_err(|_| "会话路径越过 Codex Home".to_string())?
                            .to_path_buf(),
                        length: metadata.len(),
                        hash: hash_file(&path)?,
                        path,
                    });
                }
            }
        }
    }
    Ok(files)
}

fn canonical_thread_id(path: &Path) -> Result<Option<String>, String> {
    let file = File::open(path)
        .map_err(|error| format!("打开会话文件失败 {}：{error}", path.display()))?;
    let mut line = String::new();
    let mut reader = BufReader::new(file).take(FIRST_LINE_LIMIT + 1);
    let bytes = reader
        .read_line(&mut line)
        .map_err(|error| format!("读取会话首行失败 {}：{error}", path.display()))?;
    if bytes as u64 > FIRST_LINE_LIMIT || !line.ends_with('\n') {
        return Err(format!("会话首行过大或不完整：{}", path.display()));
    }
    let value: Value = match serde_json::from_str(&line) {
        Ok(value) => value,
        Err(_) => return Ok(None),
    };
    if value.get("type").and_then(Value::as_str) != Some("session_meta") {
        return Ok(None);
    }
    Ok(value
        .get("payload")
        .and_then(|payload| payload.get("id").or_else(|| payload.get("thread_id")))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string))
}

fn conflict_for_versions(
    thread_id: &str,
    versions: Vec<&RolloutFile>,
    reason: &str,
) -> CodexInstanceConflict {
    CodexInstanceConflict {
        id: Uuid::new_v4().to_string(),
        thread_id: thread_id.to_string(),
        instance_ids: versions
            .iter()
            .map(|version| version.instance_id.clone())
            .collect(),
        relative_paths: versions
            .iter()
            .map(|version| version.relative_path.display().to_string())
            .collect(),
        hashes: versions
            .iter()
            .map(|version| version.hash.clone())
            .collect(),
        detected_at: now_millis(),
        reason: reason.to_string(),
        resolved: false,
    }
}

fn file_is_prefix(shorter: &Path, longer: &Path) -> Result<bool, String> {
    let shorter_length = fs::metadata(shorter)
        .map_err(|error| format!("读取会话文件失败 {}：{error}", shorter.display()))?
        .len();
    let longer_length = fs::metadata(longer)
        .map_err(|error| format!("读取会话文件失败 {}：{error}", longer.display()))?
        .len();
    if shorter_length > longer_length {
        return Ok(false);
    }
    let mut left = BufReader::new(File::open(shorter).map_err(|error| error.to_string())?);
    let mut right = BufReader::new(File::open(longer).map_err(|error| error.to_string())?);
    let mut left_buffer = [0_u8; 64 * 1024];
    let mut right_buffer = [0_u8; 64 * 1024];
    loop {
        let read = left
            .read(&mut left_buffer)
            .map_err(|error| format!("比较会话文件失败：{error}"))?;
        if read == 0 {
            return Ok(true);
        }
        right
            .read_exact(&mut right_buffer[..read])
            .map_err(|error| format!("比较会话文件失败：{error}"))?;
        if left_buffer[..read] != right_buffer[..read] {
            return Ok(false);
        }
    }
}

fn hash_file(path: &Path) -> Result<String, String> {
    let mut file =
        File::open(path).map_err(|error| format!("打开文件失败 {}：{error}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 128 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|error| format!("读取文件失败 {}：{error}", path.display()))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn copy_atomically_verified(
    source: &Path,
    destination: &Path,
    expected_hash: &str,
) -> Result<(), String> {
    let mut copied_hash = None;
    let write_result = atomic_file::write_atomically_streaming(destination, |output| {
        let mut input = File::open(source).map_err(|error| error.to_string())?;
        let mut hasher = Sha256::new();
        let mut buffer = [0_u8; 128 * 1024];
        loop {
            let read = input.read(&mut buffer).map_err(|error| error.to_string())?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
            output
                .write_all(&buffer[..read])
                .map_err(|error| error.to_string())?;
        }
        let actual = format!("{:x}", hasher.finalize());
        if actual != expected_hash {
            return Err("源文件在复制期间发生变化，已取消提交".into());
        }
        copied_hash = Some(actual);
        Ok(())
    });
    accept_committed_atomic_write(write_result, "实例同步文件")?;
    if copied_hash.as_deref() == Some(expected_hash) {
        Ok(())
    } else {
        Err("复制完成但未取得校验值".into())
    }
}

fn apply_transaction_with_open_file_probe(
    paths: &InstancePaths,
    instances: &[CodexInstance],
    transaction: &mut SyncTransaction,
    open_file_probe: &mut dyn FnMut(&[PathBuf]) -> Result<Vec<String>, String>,
) -> Result<(), String> {
    for index in 0..transaction.operations.len() {
        ensure_all_stopped(instances)?;
        let operation = &mut transaction.operations[index];
        validate_operation_paths(instances, operation)?;
        let source = Path::new(&operation.source_path);
        let destination = Path::new(&operation.destination_path);
        if hash_file(source)? != operation.source_hash {
            return Err(format!(
                "会话 {} 的源文件在预览后发生变化",
                operation.thread_id
            ));
        }
        match operation.destination_hash.as_deref() {
            Some(expected) => {
                if !destination.is_file() || hash_file(destination)? != expected {
                    return Err(format!(
                        "会话 {} 的目标文件在预览后发生变化",
                        operation.thread_id
                    ));
                }
                let backup = Path::new(
                    operation
                        .backup_path
                        .as_deref()
                        .ok_or_else(|| "同步事务缺少备份路径".to_string())?,
                );
                ensure_path_inside(
                    backup,
                    &transaction_root(paths, &transaction.transaction_id),
                )?;
                copy_atomically_verified(destination, backup, expected)?;
            }
            None if destination.exists() => {
                return Err(format!(
                    "会话 {} 的目标路径在预览后被占用",
                    operation.thread_id
                ));
            }
            None => {}
        }
        ensure_files_not_open_elsewhere_with_probe(
            &[source.to_path_buf(), destination.to_path_buf()],
            "实例同步",
            open_file_probe,
        )?;
        copy_atomically_verified(source, destination, &operation.source_hash)?;
        operation.installed_hash = Some(operation.source_hash.clone());
        write_transaction(
            &transaction_root(paths, &transaction.transaction_id),
            transaction,
        )?;
    }
    Ok(())
}

fn rollback_transaction_files(
    paths: &InstancePaths,
    instances: &[CodexInstance],
    transaction: &mut SyncTransaction,
) -> Result<(), String> {
    rollback_transaction_files_with_open_file_probe(
        paths,
        instances,
        transaction,
        &mut |candidates| crate::platform::files_open_in_other_processes(candidates),
    )
}

fn rollback_transaction_files_with_open_file_probe(
    paths: &InstancePaths,
    instances: &[CodexInstance],
    transaction: &mut SyncTransaction,
    open_file_probe: &mut dyn FnMut(&[PathBuf]) -> Result<Vec<String>, String>,
) -> Result<(), String> {
    let transaction_root = transaction_root(paths, &transaction.transaction_id);
    let mut failures = Vec::new();
    for index in (0..transaction.operations.len()).rev() {
        let operation = &transaction.operations[index];
        let outcome = (|| -> Result<(), String> {
            validate_operation_paths(instances, operation)?;
            let destination = Path::new(&operation.destination_path);
            let mut restore_backup = |backup_path: &str| -> Result<(), String> {
                let backup = Path::new(backup_path);
                ensure_path_inside(backup, &transaction_root)?;
                let expected = operation
                    .destination_hash
                    .as_deref()
                    .ok_or_else(|| "回滚事务缺少原始校验值".to_string())?;
                if hash_file(backup)? != expected {
                    return Err(format!("回滚备份校验失败：{}", backup.display()));
                }
                ensure_files_not_open_elsewhere_with_probe(
                    &[destination.to_path_buf()],
                    "实例回滚",
                    open_file_probe,
                )?;
                copy_atomically_verified(backup, destination, expected)
            };
            if !destination.exists() {
                return match (
                    operation.destination_hash.as_deref(),
                    operation.backup_path.as_deref(),
                ) {
                    // 新增文件的回滚就是删除：目标已不存在即为目标状态（幂等重试）。
                    (None, _) => Ok(()),
                    // 是否需要恢复由同步前状态决定，不能用 installed_hash 猜测。
                    // copy 已提交但 manifest 尚未写回时，installed_hash 仍可能为空。
                    (Some(_), Some(backup_path)) => restore_backup(backup_path),
                    (Some(_), None) => Err(format!(
                        "同步前目标存在，但回滚事务缺少备份路径：{}",
                        destination.display()
                    )),
                };
            }
            let current_hash = hash_file(destination)?;
            // 目标已是同步前内容：已回滚（或从未生效），幂等跳过。
            if operation.destination_hash.as_deref() == Some(current_hash.as_str()) {
                return Ok(());
            }
            if let Some(installed_hash) = operation.installed_hash.as_deref() {
                if installed_hash != operation.source_hash {
                    return Err("同步事务记录的安装校验值与源校验值不一致".into());
                }
            }
            if current_hash != operation.source_hash {
                return Err(format!(
                    "{} 已在同步后被修改，拒绝覆盖",
                    destination.display()
                ));
            }
            if let Some(backup_path) = operation.backup_path.as_deref() {
                restore_backup(backup_path)
            } else {
                ensure_files_not_open_elsewhere_with_probe(
                    &[destination.to_path_buf()],
                    "实例回滚",
                    open_file_probe,
                )?;
                fs::remove_file(destination).map_err(|error| {
                    format!("删除同步新增文件失败 {}：{error}", destination.display())
                })?;
                sync_parent(
                    destination
                        .parent()
                        .ok_or_else(|| "目标路径缺少父目录".to_string())?,
                )
            }
        })();
        match outcome {
            Ok(()) => {
                // 每回滚一条即清 installed_hash 并持久化，崩溃后重试可精确跳过。
                if transaction.operations[index].installed_hash.is_some() {
                    transaction.operations[index].installed_hash = None;
                    if let Err(error) = write_transaction(&transaction_root, transaction) {
                        failures.push(format!("回滚进度未能持久化：{error}"));
                    }
                }
            }
            Err(error) => failures.push(error),
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("；"))
    }
}

fn validate_operation_paths(
    instances: &[CodexInstance],
    operation: &CodexInstanceSyncOperation,
) -> Result<(), String> {
    let source_instance = instances
        .iter()
        .find(|instance| instance.id == operation.source_instance_id)
        .ok_or_else(|| "同步事务源实例不在选择范围内".to_string())?;
    let destination_instance = instances
        .iter()
        .find(|instance| instance.id == operation.destination_instance_id)
        .ok_or_else(|| "同步事务目标实例不在选择范围内".to_string())?;
    ensure_path_inside(
        Path::new(&operation.source_path),
        Path::new(&source_instance.codex_home),
    )?;
    ensure_path_inside(
        Path::new(&operation.destination_path),
        Path::new(&destination_instance.codex_home),
    )
}

fn ensure_path_inside(path: &Path, root: &Path) -> Result<(), String> {
    let root = canonical_directory(root, "受控根目录")?;
    let candidate = if path.exists() {
        canonical_existing(path)?
    } else {
        let parent = path
            .parent()
            .ok_or_else(|| "受控路径缺少父目录".to_string())?;
        fs::create_dir_all(parent).map_err(|error| format!("创建受控父目录失败：{error}"))?;
        canonical_directory(parent, "受控父目录")?.join(
            path.file_name()
                .ok_or_else(|| "受控路径缺少文件名".to_string())?,
        )
    };
    if candidate.starts_with(&root) && candidate != root {
        Ok(())
    } else {
        Err(format!(
            "路径 {} 越过受控根目录 {}",
            candidate.display(),
            root.display()
        ))
    }
}

fn transaction_root(paths: &InstancePaths, transaction_id: &str) -> PathBuf {
    paths.sync_root.join("transactions").join(transaction_id)
}

fn write_transaction(root: &Path, transaction: &SyncTransaction) -> Result<(), String> {
    fs::create_dir_all(root).map_err(|error| format!("创建同步事务目录失败：{error}"))?;
    let bytes = serde_json::to_vec_pretty(transaction)
        .map_err(|error| format!("编码同步事务失败：{error}"))?;
    accept_committed_atomic_write(
        atomic_file::write_atomically(&root.join("manifest.json"), &bytes),
        "实例同步事务",
    )
}

fn read_transaction(root: &Path) -> Result<SyncTransaction, String> {
    let bytes = fs::read(root.join("manifest.json"))
        .map_err(|error| format!("读取同步事务失败：{error}"))?;
    let transaction: SyncTransaction =
        serde_json::from_slice(&bytes).map_err(|error| format!("解析同步事务失败：{error}"))?;
    if transaction.schema_version != TRANSACTION_SCHEMA_VERSION {
        return Err(format!(
            "不支持的同步事务版本 {}",
            transaction.schema_version
        ));
    }
    Ok(transaction)
}

fn ensure_no_unfinished_transactions(
    paths: &InstancePaths,
    instance_ids: &[String],
) -> Result<(), String> {
    let selected = instance_ids.iter().collect::<HashSet<_>>();
    for transaction in read_all_transactions(paths)? {
        if ["prepared", "failedNeedsRecovery"].contains(&transaction.state.as_str())
            && transaction
                .instance_ids
                .iter()
                .any(|id| selected.contains(id))
        {
            return Err(format!(
                "实例同步事务 {} 尚未完成（{}）；请先在“同步回滚”中恢复，再继续操作",
                transaction.transaction_id, transaction.state
            ));
        }
    }
    Ok(())
}

fn ensure_transaction_is_latest_recoverable(
    paths: &InstancePaths,
    target: &SyncTransaction,
) -> Result<(), String> {
    let selected = target.instance_ids.iter().collect::<HashSet<_>>();
    if let Some(later) = read_all_transactions(paths)?.into_iter().find(|candidate| {
        candidate.created_at > target.created_at
            && ["committed", "prepared", "failedNeedsRecovery"].contains(&candidate.state.as_str())
            && candidate
                .instance_ids
                .iter()
                .any(|id| selected.contains(id))
    }) {
        return Err(format!(
            "事务 {} 之后还有关联事务 {}；请先从最新事务开始回滚",
            target.transaction_id, later.transaction_id
        ));
    }
    Ok(())
}

fn read_all_transactions(paths: &InstancePaths) -> Result<Vec<SyncTransaction>, String> {
    let root = paths.sync_root.join("transactions");
    if !root.exists() {
        return Ok(Vec::new());
    }
    let mut transactions = Vec::new();
    for entry in fs::read_dir(&root).map_err(|error| format!("读取实例同步事务失败：{error}"))?
    {
        let entry = entry.map_err(|error| format!("读取实例同步事务条目失败：{error}"))?;
        if entry
            .file_type()
            .map_err(|error| format!("读取实例同步事务类型失败：{error}"))?
            .is_dir()
        {
            if !entry.path().join("manifest.json").is_file() {
                continue;
            }
            transactions.push(read_transaction(&entry.path())?);
        }
    }
    transactions.sort_by(|left, right| right.created_at.cmp(&left.created_at));
    Ok(transactions)
}

#[cfg(unix)]
fn sync_parent(path: &Path) -> Result<(), String> {
    File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(|error| format!("同步目录失败 {}：{error}", path.display()))
}

#[cfg(not(unix))]
fn sync_parent(_path: &Path) -> Result<(), String> {
    Ok(())
}

fn now_millis() -> i64 {
    (OffsetDateTime::now_utc().unix_timestamp_nanos() / 1_000_000) as i64
}

fn accept_committed_atomic_write(
    result: Result<(), atomic_file::AtomicWriteError>,
    label: &str,
) -> Result<(), String> {
    match result {
        Ok(()) => Ok(()),
        Err(atomic_file::AtomicWriteError::NotCommitted(error)) => {
            Err(format!("{label}写入未提交：{error}"))
        }
        Err(atomic_file::AtomicWriteError::CommittedNotDurable(error)) => {
            eprintln!(
                "Codex Token Bar: {label}已提交，但父目录持久化确认失败；保留已提交状态：{error}"
            );
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_paths(label: &str) -> InstancePaths {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-instances-{label}-{}",
            Uuid::new_v4()
        ));
        InstancePaths {
            registry: root.join("support").join("codex-instances.json"),
            managed_root: root.join("support").join("instances").join("codex"),
            sync_root: root.join("support").join("instance-sync"),
        }
    }

    fn write_rollout(home: &Path, thread_id: &str, suffix: &str) -> PathBuf {
        let path = home
            .join("sessions")
            .join("2026")
            .join("07")
            .join("26")
            .join(format!("rollout-{thread_id}.jsonl"));
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{thread_id}\"}}}}\n{suffix}"
            ),
        )
        .unwrap();
        path
    }

    fn fixture_instance(id: &str, home: &Path) -> CodexInstance {
        fs::create_dir_all(home).unwrap();
        CodexInstance {
            id: id.into(),
            name: id.into(),
            codex_home: home.canonicalize().unwrap().display().to_string(),
            electron_data_directory: home.join("electron").display().to_string(),
            working_directory: None,
            arguments: Vec::new(),
            managed: false,
            is_default: false,
            auto_sync_enabled: false,
            created_at: 1,
            updated_at: 1,
            controlled_process: None,
        }
    }

    #[test]
    fn prefix_sync_preview_fast_forwards_without_merging_divergence() {
        let paths = temp_paths("preview");
        let first_home = paths.managed_root.join("a");
        let second_home = paths.managed_root.join("b");
        let first = fixture_instance("a", &first_home);
        let second = fixture_instance("b", &second_home);
        write_rollout(
            &first_home,
            "same",
            "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}\n",
        );
        write_rollout(
            &second_home,
            "same",
            "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}\n{\"type\":\"event_msg\",\"payload\":{\"n\":2}}\n",
        );
        write_rollout(
            &first_home,
            "fork",
            "{\"type\":\"event_msg\",\"payload\":{\"side\":\"a\"}}\n",
        );
        write_rollout(
            &second_home,
            "fork",
            "{\"type\":\"event_msg\",\"payload\":{\"side\":\"b\"}}\n",
        );

        let preview = build_sync_preview(&[first, second]).unwrap();
        assert_eq!(preview.operations.len(), 1);
        assert_eq!(preview.operations[0].kind, "fastForward");
        assert_eq!(preview.conflicts.len(), 1);
        assert_eq!(preview.conflicts[0].thread_id, "fork");
        let _ = fs::remove_dir_all(paths.managed_root.parent().unwrap().parent().unwrap());
    }

    #[test]
    fn active_and_archived_versions_are_not_merged_nondeterministically() {
        let paths = temp_paths("archive-state");
        let first_home = paths.managed_root.join("a");
        let second_home = paths.managed_root.join("b");
        let first = fixture_instance("a", &first_home);
        let second = fixture_instance("b", &second_home);
        let active = write_rollout(
            &first_home,
            "archive-state",
            "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}\n",
        );
        let archived = second_home
            .join("archived_sessions")
            .join("2026")
            .join("07")
            .join("26")
            .join("rollout-archive-state.jsonl");
        fs::create_dir_all(archived.parent().unwrap()).unwrap();
        fs::copy(active, archived).unwrap();

        let preview = build_sync_preview(&[first, second]).unwrap();
        assert!(preview.operations.is_empty());
        assert_eq!(preview.conflicts.len(), 1);
        assert!(preview.conflicts[0].reason.contains("活动/归档"));
        let _ = fs::remove_dir_all(paths.managed_root.parent().unwrap().parent().unwrap());
    }

    #[cfg(unix)]
    #[test]
    fn rollout_root_symlink_cannot_escape_codex_home() {
        use std::os::unix::fs::symlink;

        let paths = temp_paths("rollout-root-symlink");
        let home = paths.managed_root.join("instance");
        let instance = fixture_instance("instance", &home);
        let outside = paths
            .managed_root
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .join("outside-sessions");
        fs::create_dir_all(&outside).unwrap();
        symlink(&outside, home.join("sessions")).unwrap();

        let error = collect_rollouts(&instance).unwrap_err();
        assert!(error.contains("真实目录"), "{error}");
        let _ = fs::remove_dir_all(paths.managed_root.parent().unwrap().parent().unwrap());
    }

    #[test]
    fn missing_rollout_syncs_to_the_same_relative_path() {
        let paths = temp_paths("missing");
        let first_id = Uuid::new_v4().to_string();
        let second_id = Uuid::new_v4().to_string();
        let first_home = paths.managed_root.join(&first_id).join("home");
        let second_home = paths.managed_root.join(&second_id).join("home");
        let mut first = fixture_instance(&first_id, &first_home);
        let mut second = fixture_instance(&second_id, &second_home);
        first.managed = true;
        second.managed = true;
        fs::create_dir_all(&first.electron_data_directory).unwrap();
        fs::create_dir_all(&second.electron_data_directory).unwrap();
        let source = write_rollout(
            &second_home,
            "missing-thread",
            "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}\n",
        );
        let mut registry = CodexInstanceRegistry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            updated_at: 1,
            instances: vec![first.clone(), second.clone()],
            conflicts: Vec::new(),
        };

        let preview = build_sync_preview(&[first.clone(), second.clone()]).unwrap();
        assert_eq!(preview.operations.len(), 1);
        let destination = PathBuf::from(&preview.operations[0].destination_path);
        assert_eq!(
            destination,
            first_home
                .canonicalize()
                .unwrap()
                .join("sessions/2026/07/26/rollout-missing-thread.jsonl")
        );
        assert!(!destination.exists());

        let result = sync_instances_locked_with_visibility(
            &paths,
            &mut registry,
            vec![first, second],
            &mut |_| Ok(()),
        )
        .unwrap();
        assert_eq!(result.operations_applied, 1);
        assert_eq!(fs::read(destination).unwrap(), fs::read(source).unwrap());
        let _ = fs::remove_dir_all(paths.managed_root.parent().unwrap().parent().unwrap());
    }

    #[cfg(target_os = "macos")]
    fn spawn_file_holder(path: &Path) -> std::process::Child {
        use std::io::Read;
        let mut child = std::process::Command::new("/bin/sh")
            .args([
                "-c",
                "exec 3>>\"$0\"; echo ready; exec sleep 300",
                &path.display().to_string(),
            ])
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let mut ready = [0u8; 6];
        child
            .stdout
            .as_mut()
            .unwrap()
            .read_exact(&mut ready)
            .unwrap();
        assert_eq!(&ready, b"ready\n");
        child
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn open_file_probe_reports_other_process_but_not_self_or_exited() {
        let paths = temp_paths("open-probe");
        let file = write_rollout(
            &paths.managed_root.join("a"),
            "held",
            "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}\n",
        );
        let mut child = spawn_file_holder(&file);
        let held = crate::platform::files_open_in_other_processes(std::slice::from_ref(&file))
            .unwrap();
        assert_eq!(held.len(), 1, "{held:?}");
        assert!(held[0].contains(&child.id().to_string()), "{held:?}");
        child.kill().unwrap();
        child.wait().unwrap();
        let own_handle = fs::File::open(&file).unwrap();
        let held = crate::platform::files_open_in_other_processes(std::slice::from_ref(&file))
            .unwrap();
        assert!(held.is_empty(), "自身句柄或已退出进程被误报：{held:?}");
        drop(own_handle);
        let missing = paths.managed_root.join("a").join("no-such-file.jsonl");
        let held = crate::platform::files_open_in_other_processes(&[missing]).unwrap();
        assert!(held.is_empty());
        let _ = fs::remove_dir_all(paths.managed_root.parent().unwrap().parent().unwrap());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn sync_refuses_while_candidate_file_is_open_in_another_process() {
        let paths = temp_paths("open-gate");
        let first_home = paths.managed_root.join("a");
        let second_home = paths.managed_root.join("b");
        let mut first = fixture_instance("a", &first_home);
        let mut second = fixture_instance("b", &second_home);
        first.managed = true;
        second.managed = true;
        write_rollout(
            &first_home,
            "same",
            "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}\n",
        );
        let source = write_rollout(
            &second_home,
            "same",
            "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}\n{\"type\":\"event_msg\",\"payload\":{\"n\":2}}\n",
        );
        let mut registry = CodexInstanceRegistry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            updated_at: 1,
            instances: vec![first.clone(), second.clone()],
            conflicts: Vec::new(),
        };

        let mut child = spawn_file_holder(&source);
        let error = sync_instances_locked_with_visibility(
            &paths,
            &mut registry,
            vec![first.clone(), second.clone()],
            &mut |_| Ok(()),
        )
        .unwrap_err();
        assert!(error.contains("候选会话文件"), "{error}");
        assert!(error.contains(&child.id().to_string()), "{error}");
        child.kill().unwrap();
        child.wait().unwrap();

        let result = sync_instances_locked_with_visibility(
            &paths,
            &mut registry,
            vec![first, second],
            &mut |_| Ok(()),
        )
        .unwrap();
        assert_eq!(result.operations_applied, 1);
        let _ = fs::remove_dir_all(paths.managed_root.parent().unwrap().parent().unwrap());
    }

    #[test]
    fn sync_rechecks_open_files_immediately_before_each_replace() {
        let paths = temp_paths("late-open-gate");
        let first_home = paths.managed_root.join("a");
        let second_home = paths.managed_root.join("b");
        let mut first = fixture_instance("a", &first_home);
        let mut second = fixture_instance("b", &second_home);
        first.managed = true;
        second.managed = true;
        let destination = write_rollout(
            &first_home,
            "late-open",
            "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}\n",
        );
        let original = fs::read(&destination).unwrap();
        write_rollout(
            &second_home,
            "late-open",
            "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}\n{\"type\":\"event_msg\",\"payload\":{\"n\":2}}\n",
        );
        let mut registry = CodexInstanceRegistry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            updated_at: 1,
            instances: vec![first.clone(), second.clone()],
            conflicts: Vec::new(),
        };
        let mut calls = 0_u32;
        let error = sync_instances_locked_with_visibility_and_open_file_probe(
            &paths,
            &mut registry,
            vec![first, second],
            &mut |_| Ok(()),
            &mut |_| {
                calls += 1;
                if calls == 2 {
                    Ok(vec!["late-open.jsonl（进程 4242）".into()])
                } else {
                    Ok(Vec::new())
                }
            },
        )
        .unwrap_err();
        assert!(calls >= 2);
        assert!(error.contains("late-open.jsonl"), "{error}");
        assert_eq!(fs::read(&destination).unwrap(), original);
        let _ = fs::remove_dir_all(paths.managed_root.parent().unwrap().parent().unwrap());
    }

    #[test]
    fn registry_rejects_duplicate_canonical_homes() {
        let paths = temp_paths("duplicate");
        let home = paths.managed_root.join("same");
        let one = fixture_instance(&Uuid::new_v4().to_string(), &home);
        let mut two = one.clone();
        two.id = Uuid::new_v4().to_string();
        let registry = CodexInstanceRegistry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            updated_at: 1,
            instances: vec![one, two],
            conflicts: Vec::new(),
        };
        assert!(validate_registry(&registry).is_err());
        let _ = fs::remove_dir_all(paths.managed_root.parent().unwrap().parent().unwrap());
    }

    #[test]
    fn registry_rejects_nested_canonical_homes() {
        let paths = temp_paths("nested");
        let parent_home = paths.managed_root.join("parent");
        let child_home = parent_home.join("child");
        fs::create_dir_all(&child_home).unwrap();
        let parent = fixture_instance(&Uuid::new_v4().to_string(), &parent_home);
        let child = fixture_instance(&Uuid::new_v4().to_string(), &child_home);
        let registry = CodexInstanceRegistry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            updated_at: 1,
            instances: vec![parent, child],
            conflicts: Vec::new(),
        };
        assert!(validate_registry(&registry)
            .unwrap_err()
            .contains("相互嵌套"));
        let _ = fs::remove_dir_all(paths.managed_root.parent().unwrap().parent().unwrap());
    }

    #[test]
    fn external_instance_owned_root_is_validated_without_owning_external_home() {
        let paths = temp_paths("external-owned-root");
        let id = Uuid::new_v4().to_string();
        let external_home = paths
            .managed_root
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .join("external-home");
        let root = paths.managed_root.join(&id);
        let electron = root.join("electron-data");
        fs::create_dir_all(&external_home).unwrap();
        fs::create_dir_all(&electron).unwrap();
        let mut instance = fixture_instance(&id, &external_home);
        instance.electron_data_directory = electron.canonicalize().unwrap().display().to_string();
        assert_eq!(
            validate_owned_instance_root(&paths, &instance).unwrap(),
            root.canonicalize().unwrap()
        );
        let _ = fs::remove_dir_all(paths.managed_root.parent().unwrap().parent().unwrap());
    }

    #[test]
    fn atomic_verified_copy_rejects_hash_mismatch_without_destination() {
        let paths = temp_paths("copy");
        let source = paths.managed_root.join("source");
        let destination = paths.managed_root.join("destination");
        fs::create_dir_all(source.parent().unwrap()).unwrap();
        fs::write(&source, b"source").unwrap();
        assert!(copy_atomically_verified(&source, &destination, "wrong").is_err());
        assert!(!destination.exists());
        let _ = fs::remove_dir_all(paths.managed_root.parent().unwrap().parent().unwrap());
    }

    #[test]
    fn committed_prefix_sync_can_be_rolled_back_without_touching_divergent_data() {
        let paths = temp_paths("transaction");
        let first_id = Uuid::new_v4().to_string();
        let second_id = Uuid::new_v4().to_string();
        let first_home = paths.managed_root.join(&first_id).join("home");
        let second_home = paths.managed_root.join(&second_id).join("home");
        let mut first = fixture_instance(&first_id, &first_home);
        let mut second = fixture_instance(&second_id, &second_home);
        first.managed = true;
        second.managed = true;
        fs::create_dir_all(&first.electron_data_directory).unwrap();
        fs::create_dir_all(&second.electron_data_directory).unwrap();
        let first_path = write_rollout(
            &first_home,
            "transaction",
            "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}\n",
        );
        let original = fs::read(&first_path).unwrap();
        let second_path = write_rollout(
            &second_home,
            "transaction",
            "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}\n{\"type\":\"event_msg\",\"payload\":{\"n\":2}}\n",
        );
        let mut registry = CodexInstanceRegistry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            updated_at: 1,
            instances: vec![first.clone(), second.clone()],
            conflicts: Vec::new(),
        };

        let result = sync_instances_locked_with_visibility(
            &paths,
            &mut registry,
            vec![first.clone(), second.clone()],
            &mut |_| Ok(()),
        )
        .unwrap();
        assert_eq!(result.operations_applied, 1);
        assert_eq!(
            fs::read(&first_path).unwrap(),
            fs::read(&second_path).unwrap()
        );
        let transaction_id = result.transaction_id.unwrap();
        let mut transaction = read_transaction(&transaction_root(&paths, &transaction_id)).unwrap();
        assert_eq!(transaction.state, "committed");

        let mut held_probe = |_: &[PathBuf]| {
            Ok(vec!["transaction.jsonl（进程 4242）".to_string()])
        };
        let error = rollback_transaction_files_with_open_file_probe(
            &paths,
            &[first.clone(), second.clone()],
            &mut transaction,
            &mut held_probe,
        )
        .unwrap_err();
        assert!(error.contains("实例回滚已取消"), "{error}");
        assert_eq!(
            fs::read(&first_path).unwrap(),
            fs::read(&second_path).unwrap()
        );

        // 模拟 live replace 已提交、原目标随后缺失，但 installed_hash 尚未落盘。
        // 回滚必须依据 destination_hash + 已校验备份恢复，不能把缺失误判为成功。
        transaction.state = "prepared".into();
        transaction.operations[0].installed_hash = None;
        fs::remove_file(&first_path).unwrap();
        rollback_transaction_files(&paths, &[first, second], &mut transaction).unwrap();
        assert_eq!(fs::read(&first_path).unwrap(), original);
        let _ = fs::remove_dir_all(paths.managed_root.parent().unwrap().parent().unwrap());
    }

    #[test]
    fn rollback_retry_after_partial_rollback_is_idempotent() {
        let paths = temp_paths("rollback-idempotent");
        let first_id = Uuid::new_v4().to_string();
        let second_id = Uuid::new_v4().to_string();
        let first_home = paths.managed_root.join(&first_id).join("home");
        let second_home = paths.managed_root.join(&second_id).join("home");
        let mut first = fixture_instance(&first_id, &first_home);
        let mut second = fixture_instance(&second_id, &second_home);
        first.managed = true;
        second.managed = true;
        fs::create_dir_all(&first.electron_data_directory).unwrap();
        fs::create_dir_all(&second.electron_data_directory).unwrap();
        let first_path = write_rollout(
            &first_home,
            "idempotent",
            "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}\n",
        );
        let original = fs::read(&first_path).unwrap();
        write_rollout(
            &second_home,
            "idempotent",
            "{\"type\":\"event_msg\",\"payload\":{\"n\":1}}\n{\"type\":\"event_msg\",\"payload\":{\"n\":2}}\n",
        );
        let mut registry = CodexInstanceRegistry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            updated_at: 1,
            instances: vec![first.clone(), second.clone()],
            conflicts: Vec::new(),
        };
        sync_instances_locked_with_visibility(
            &paths,
            &mut registry,
            vec![first.clone(), second.clone()],
            &mut |_| Ok(()),
        )
        .unwrap();
        let transaction_id_root = {
            let result_root = paths.sync_root.join("transactions");
            fs::read_dir(result_root).unwrap().next().unwrap().unwrap().path()
        };
        let mut transaction = read_transaction(&transaction_id_root).unwrap();

        // 模拟"回滚已把文件恢复但进度/状态未持久化"后的重试：
        // 文件已是同步前内容，manifest 仍记录 installed_hash。
        fs::write(&first_path, &original).unwrap();
        assert!(transaction.operations[0].installed_hash.is_some());
        rollback_transaction_files(&paths, &[first.clone(), second.clone()], &mut transaction)
            .unwrap();
        assert_eq!(fs::read(&first_path).unwrap(), original);
        assert!(transaction.operations[0].installed_hash.is_none());
        // 进度已持久化：磁盘上的 manifest 同步清除了 installed_hash。
        let persisted = read_transaction(&transaction_id_root).unwrap();
        assert!(persisted.operations[0].installed_hash.is_none());

        // 再次重试仍然成功（完全幂等）。
        rollback_transaction_files(&paths, &[first, second], &mut transaction).unwrap();
        assert_eq!(fs::read(&first_path).unwrap(), original);
        let _ = fs::remove_dir_all(paths.managed_root.parent().unwrap().parent().unwrap());
    }

    #[test]
    fn unfinished_transaction_blocks_related_instance_until_recovered() {
        let paths = temp_paths("unfinished");
        let first_id = Uuid::new_v4().to_string();
        let second_id = Uuid::new_v4().to_string();
        let unrelated_id = Uuid::new_v4().to_string();
        let mut transaction = SyncTransaction {
            schema_version: TRANSACTION_SCHEMA_VERSION,
            transaction_id: Uuid::new_v4().to_string(),
            created_at: 100,
            state: "prepared".into(),
            instance_ids: vec![first_id.clone(), second_id],
            operations: Vec::new(),
            conflicts: Vec::new(),
        };
        let root = transaction_root(&paths, &transaction.transaction_id);
        write_transaction(&root, &transaction).unwrap();

        let error = ensure_no_unfinished_transactions(&paths, &[first_id])
            .expect_err("prepared transaction must block related instances");
        assert!(error.contains("尚未完成"));
        ensure_no_unfinished_transactions(&paths, &[unrelated_id]).unwrap();

        transaction.state = "rolledBack".into();
        write_transaction(&root, &transaction).unwrap();
        ensure_no_unfinished_transactions(&paths, &transaction.instance_ids).unwrap();
        let _ = fs::remove_dir_all(paths.sync_root.parent().unwrap());
    }

    #[test]
    fn overlapping_transactions_must_be_rolled_back_newest_first() {
        let paths = temp_paths("rollback-order");
        let shared_id = Uuid::new_v4().to_string();
        let older = SyncTransaction {
            schema_version: TRANSACTION_SCHEMA_VERSION,
            transaction_id: Uuid::new_v4().to_string(),
            created_at: 100,
            state: "committed".into(),
            instance_ids: vec![shared_id.clone(), Uuid::new_v4().to_string()],
            operations: Vec::new(),
            conflicts: Vec::new(),
        };
        let newer = SyncTransaction {
            schema_version: TRANSACTION_SCHEMA_VERSION,
            transaction_id: Uuid::new_v4().to_string(),
            created_at: 200,
            state: "prepared".into(),
            instance_ids: vec![shared_id, Uuid::new_v4().to_string()],
            operations: Vec::new(),
            conflicts: Vec::new(),
        };
        write_transaction(&transaction_root(&paths, &older.transaction_id), &older).unwrap();
        write_transaction(&transaction_root(&paths, &newer.transaction_id), &newer).unwrap();

        let error = ensure_transaction_is_latest_recoverable(&paths, &older)
            .expect_err("older overlapping transaction must be blocked");
        assert!(error.contains(&newer.transaction_id));
        ensure_transaction_is_latest_recoverable(&paths, &newer).unwrap();
        let _ = fs::remove_dir_all(paths.sync_root.parent().unwrap());
    }

    #[test]
    fn automatic_sync_always_includes_default_instance() {
        let home = std::env::temp_dir().join(format!("auto-sync-{}", Uuid::new_v4()));
        let mut enabled = fixture_instance(&Uuid::new_v4().to_string(), &home);
        enabled.auto_sync_enabled = true;
        let registry = CodexInstanceRegistry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            updated_at: 1,
            instances: vec![enabled.clone()],
            conflicts: Vec::new(),
        };
        assert_eq!(
            auto_sync_instance_ids(&registry),
            vec!["default".to_string(), enabled.id]
        );
        let _ = fs::remove_dir_all(home);
    }

    #[test]
    fn repeated_conflict_observation_updates_instead_of_accumulating() {
        let mut existing = Vec::new();
        let first = CodexInstanceConflict {
            id: Uuid::new_v4().to_string(),
            thread_id: "thread".into(),
            instance_ids: vec!["a".into(), "b".into()],
            relative_paths: vec!["one".into(), "two".into()],
            hashes: vec!["left".into(), "right".into()],
            detected_at: 1,
            reason: "first".into(),
            resolved: false,
        };
        let mut repeated = first.clone();
        repeated.id = Uuid::new_v4().to_string();
        repeated.instance_ids.reverse();
        repeated.hashes.reverse();
        repeated.detected_at = 2;
        repeated.reason = "updated".into();

        merge_conflicts(&mut existing, &[first]);
        merge_conflicts(&mut existing, &[repeated]);
        assert_eq!(existing.len(), 1);
        assert_eq!(existing[0].detected_at, 2);
        assert_eq!(existing[0].reason, "updated");
    }
}
