//! Resolve legacy migration evidence without resuming a writer on old files.
//! Only a committed main/rollback is imported; the candidate is never a source.
use super::*;

#[derive(Default)]
struct Inputs {
    sources: Vec<PathBuf>,
    manifests: Vec<(PathBuf, String)>,
}

fn regular_file(path: &Path) -> Result<bool, String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            reject_session_catalog_reparse_point(path, &metadata)?;
            if !metadata.is_file() {
                return Err(format!(
                    "旧迁移输入不是普通文件，已保留现场：{}",
                    path.display()
                ));
            }
            Ok(true)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!("无法检查旧迁移输入 {}：{error}", path.display())),
    }
}

fn sibling_identity(path: &Path) -> Result<PathBuf, String> {
    let parent = path.parent().ok_or("旧迁移路径缺少父目录")?;
    let name = path.file_name().ok_or("旧迁移路径缺少文件名")?;
    Ok(fs::canonicalize(parent)
        .map_err(|e| e.to_string())?
        .join(name))
}

fn manifest_digest(path: &Path) -> Result<String, String> {
    if !regular_file(path)? {
        return Err("旧迁移清单已移走，保留旧账并停止导入".into());
    }
    if fs::metadata(path).map_err(|e| e.to_string())?.len() > 2 * 1024 * 1024 {
        return Err(format!(
            "旧迁移清单异常过大，已保留现场：{}",
            path.display()
        ));
    }
    let bytes = fs::read(path).map_err(|e| e.to_string())?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

fn validated_manifest(
    main: &Path,
    manifest_path: &Path,
) -> Result<Schema11CandidateManifest, String> {
    let manifest = schema11_load_manifest(manifest_path)?;
    if manifest.manifest_version != SCHEMA11_CANDIDATE_MANIFEST_VERSION
        || sibling_identity(Path::new(&manifest.source_path))? != sibling_identity(main)?
        || sibling_identity(Path::new(&manifest.candidate_path))?
            != sibling_identity(&schema11_candidate_path(main))?
        || sibling_identity(Path::new(&manifest.rollback_path))?
            != sibling_identity(&schema11_rollback_path(main))?
    {
        return Err(format!(
            "旧迁移清单版本或路径不匹配，保留所有原文件：{}",
            manifest_path.display()
        ));
    }
    Ok(manifest)
}

fn resolve_manifest(main: &Path, manifest_path: &Path) -> Result<PathBuf, String> {
    let manifest = validated_manifest(main, manifest_path)?;
    // An old writer may have legitimately continued after a successful switch.
    // Import its current committed rows, not the older source_facts/candidate.
    if regular_file(main)? {
        return Ok(main.to_path_buf());
    }
    // Only Switching establishes the narrow, main-renamed-but-not-published
    // window. A missing Retained/Switched main is not permission to resurrect
    // an older rollback over possibly newer, now missing accounting.
    if manifest.phase != Schema11CandidatePhase::Switching {
        return Err(format!(
            "旧迁移活动账本缺失，拒绝重建空库或回退旧账：{}",
            main.display()
        ));
    }
    for suffix in ["-wal", "-journal"] {
        let leftover = sqlite_sidecar_path(main, suffix);
        if regular_file(&leftover)?
            && fs::metadata(&leftover).map_err(|e| e.to_string())?.len() != 0
        {
            return Err(format!(
                "旧迁移切换仍有未归位日志，需在副本中核对，已保留全部文件：{}",
                leftover.display()
            ));
        }
    }
    let rollback = schema11_rollback_path(main);
    if !regular_file(&rollback)? {
        return Err(format!(
            "旧迁移缺少活动账本及回滚库，已保留清单和候选库：{}",
            main.display()
        ));
    }
    Ok(rollback)
}

/// The initialized A ledger remains authoritative if its physical originals
/// were later deleted. New Homes still require a committed source, never a
/// candidate. This is shared by the ordinary (post-bootstrap) open path.
pub(super) fn runtime_source(
    main: &Path,
    already_imported: bool,
) -> Result<(Option<PathBuf>, Option<(PathBuf, String)>), String> {
    let manifest = schema11_manifest_path(main);
    if !regular_file(&manifest)? {
        return Ok((
            if regular_file(main)? {
                Some(main.to_path_buf())
            } else {
                None
            },
            None,
        ));
    }
    let proof = manifest_digest(&manifest)?;
    validated_manifest(main, &manifest)?;
    let source = if already_imported && !regular_file(main)? {
        None
    } else {
        Some(resolve_manifest(main, &manifest)?)
    };
    Ok((source, Some((manifest, proof))))
}

pub(super) fn verify_manifests(manifests: &[(PathBuf, String)]) -> Result<(), String> {
    for (path, expected) in manifests {
        if manifest_digest(path)? != *expected {
            return Err(format!(
                "旧迁移清单在导入期间变化，保留旧账并停止激活：{}",
                path.display()
            ));
        }
    }
    Ok(())
}

fn add_source(group: &mut Inputs, source: PathBuf) -> Result<(), String> {
    let identity = fs::canonicalize(&source).map_err(|e| e.to_string())?;
    for prior in &group.sources {
        if fs::canonicalize(prior).map_err(|e| e.to_string())? == identity {
            return Ok(());
        }
    }
    group.sources.push(source);
    Ok(())
}

pub(super) fn bootstrap_at(
    current_root: &Path,
    cache_root: &Path,
    mut import: impl FnMut(&Path, &[PathBuf], &[(PathBuf, String)]) -> Result<(), String>,
) -> Result<(), String> {
    let mut groups: HashMap<PathBuf, Inputs> = HashMap::new();
    for source_root in [current_root, cache_root] {
        let mut inputs = Vec::new();
        let mut manifests = Vec::new();
        collect_exact_legacy_inputs(source_root, current_root, &mut inputs, &mut manifests)?;
        for manifest_path in manifests {
            let digest = manifest_digest(&manifest_path)?;
            let main = PathBuf::from(
                manifest_path
                    .to_str()
                    .ok_or("旧迁移清单路径无法编码")?
                    .strip_suffix(SCHEMA11_MIGRATION_SUFFIX)
                    .ok_or("旧迁移清单文件名无效")?,
            );
            let relative = main.strip_prefix(source_root).map_err(|e| e.to_string())?;
            let target = current_root.join(relative);
            let source = resolve_manifest(&main, &manifest_path)?;
            inputs.retain(|(_, path)| path != &main);
            inputs.push((target.clone(), source));
            groups
                .entry(target)
                .or_default()
                .manifests
                .push((manifest_path, digest));
        }
        for (target, source) in inputs {
            add_source(groups.entry(target).or_default(), source)?;
        }
        if cache_root == current_root {
            break;
        }
    }
    // Discover/validate the complete batch before importing any Exact namespace.
    // The existing importer verifies SQLite backups and source proofs; these
    // additional proofs prevent a changed receipt from completing activation.
    for (target, group) in groups {
        verify_manifests(&group.manifests)?;
        import(&target, &group.sources, &group.manifests)?;
        verify_manifests(&group.manifests)?;
    }
    Ok(())
}

#[cfg(test)]
#[path = "exact_legacy_recovery_tests.rs"]
mod tests;
