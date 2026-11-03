//! Exact-only path compatibility. The global v1 source hash is deliberately
//! unchanged: published owners, receipts and private SQL prefixes keep their
//! original identities. New Exact addresses resolve the nearest existing
//! ancestor, including when several cache/staging directories do not exist.
//!
//! A lookup considers only spellings derivable from this requested path. It
//! never searches manifests from other Homes or guesses a removed/retargeted
//! symlink. Catalog reads use primary-key probes on the caller's connection.
use super::*;
use std::collections::BTreeSet;
use std::ffi::OsString;

#[derive(Clone, Debug)]
pub(super) struct ExactAddress {
    pub(super) preferred: StoreSpec,
    candidates: Vec<StoreSpec>,
}

fn identity(text: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(b"tokenbar-business-source-v1\0exact\0");
    digest.update(text.as_bytes());
    hex_digest(&digest.finalize())
}

/// Preserve filesystem semantics: do not lexically collapse `..` through a
/// missing directory or follow a symlink in the database leaf itself.
fn stable_path(path: &Path) -> Result<PathBuf, String> {
    if !path.is_absolute() {
        return Err("Exact 业务分区路径必须是绝对路径；已保留既有分区".into());
    }
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            return Err("拒绝以符号链接数据库文件定位 Exact 业务分区".into());
        }
        Ok(metadata) if !metadata.is_file() => {
            return Err("Exact 业务分区数据库路径不是普通文件".into());
        }
        Ok(_) => return std::fs::canonicalize(path).map_err(|error| error.to_string()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(format!(
                "无法确认 Exact 业务分区路径 {}：{error}",
                path.display()
            ))
        }
    }
    let mut ancestor = path;
    let mut suffix: Vec<OsString> = Vec::new();
    loop {
        match std::fs::canonicalize(ancestor) {
            Ok(mut resolved) => {
                for component in suffix.iter().rev() {
                    resolved.push(component);
                }
                return Ok(resolved);
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("无法解析 Exact 业务分区父目录：{error}")),
        }
        let leaf = ancestor
            .file_name()
            .ok_or_else(|| "Exact 业务分区缺少可确认的物理祖先，拒绝猜测路径身份".to_string())?;
        suffix.push(leaf.to_os_string());
        ancestor = ancestor
            .parent()
            .ok_or_else(|| "Exact 业务分区缺少可确认的物理祖先，拒绝猜测路径身份".to_string())?;
    }
}

fn text(path: &Path) -> Result<String, String> {
    path.to_str()
        .map(str::to_owned)
        .ok_or_else(|| "Exact 业务分区路径无法编码；已保留既有分区".to_string())
}

fn add_spellings(paths: &mut BTreeSet<String>, path: &Path) -> Result<(), String> {
    let value = text(path)?;
    paths.insert(value.clone());
    #[cfg(windows)]
    {
        // Released PathBuf::join could preserve a forward-slash relative
        // parent under a native prefix, then append the leaf with '\'. A
        // later canonical caller loses that spelling. Enumerate only this
        // filesystem-equivalent join family, linear in the component count;
        // do not guess arbitrary directory names or follow other Homes.
        let ordinary = if let Some(unc) = value.strip_prefix(r"\\?\UNC\") {
            format!(r"\\{unc}")
        } else if let Some(disk) = value.strip_prefix(r"\\?\") {
            disk.to_owned()
        } else {
            value.clone()
        };
        let native = ordinary.replace('/', r"\");
        paths.insert(native.clone());
        paths.insert(native.replace('\\', "/"));
        if let Some((parent, leaf)) = native.rsplit_once('\\') {
            for (boundary, _) in parent.match_indices('\\') {
                let split = boundary + 1;
                paths.insert(format!(
                    "{}{}\\{}",
                    &parent[..split],
                    parent[split..].replace('\\', "/"),
                    leaf
                ));
            }
        }
        // Canonical Windows paths use the verbatim prefix. Old virtual
        // owners could instead have been created from an ordinary absolute
        // path before either of the two immediate parents existed.
        if let Some(unc) = value.strip_prefix(r"\\?\UNC\") {
            paths.insert(format!(r"\\{unc}"));
        } else if let Some(disk) = value.strip_prefix(r"\\?\") {
            if disk.as_bytes().get(1) == Some(&b':') {
                paths.insert(disk.to_owned());
            }
        } else if let Some(unc) = value.strip_prefix(r"\\") {
            paths.insert(format!(r"\\?\UNC\{unc}"));
        } else if value.as_bytes().get(1) == Some(&b':') {
            paths.insert(format!(r"\\?\{value}"));
        }
    }
    Ok(())
}

/// Windows can expose an 8.3 spelling in TEMP/LOCALAPPDATA while
/// canonicalize returns the long profile name. Only reuse a configured root
/// after the OS proves that it resolves to an ancestor of this exact request.
/// This is bounded root equivalence, never a search through other Homes.
#[cfg(windows)]
fn add_configured_root_spellings(
    paths: &mut BTreeSet<String>,
    resolved: &Path,
) -> Result<(), String> {
    let roots = std::iter::once(std::env::temp_dir()).chain(
        ["LOCALAPPDATA", "APPDATA", "USERPROFILE"]
            .into_iter()
            .filter_map(|name| std::env::var_os(name))
            .map(PathBuf::from),
    );
    for configured in roots {
        if !configured.is_absolute() || !configured.is_dir() {
            continue;
        }
        let Ok(physical) = std::fs::canonicalize(&configured) else {
            continue;
        };
        if let Ok(relative) = resolved.strip_prefix(&physical) {
            add_spellings(paths, &configured.join(relative))?;
        }
    }
    Ok(())
}

fn identities(path: &Path) -> Result<(String, Vec<String>), String> {
    let resolved = stable_path(path)?;
    let preferred = identity(&text(&resolved)?);
    let mut spellings = BTreeSet::new();
    add_spellings(&mut spellings, path)?;
    add_spellings(&mut spellings, &resolved)?;
    #[cfg(windows)]
    add_configured_root_spellings(&mut spellings, &resolved)?;
    // Reproduce the old fallback's parent.join(leaf), including native
    // separator rules, without creating the missing parent as a side effect.
    if let (Some(parent), Some(leaf)) = (path.parent(), path.file_name()) {
        add_spellings(&mut spellings, &parent.join(leaf))?;
        if let Ok(parent) = std::fs::canonicalize(parent) {
            add_spellings(&mut spellings, &parent.join(leaf))?;
        }
    }
    let mut aliases = spellings
        .into_iter()
        .map(|value| identity(&value))
        .collect::<Vec<_>>();
    aliases.push(super::source_identity("exact", path)?);
    aliases.push(preferred.clone());
    aliases.sort();
    aliases.dedup();
    Ok((preferred, aliases))
}

pub(super) fn candidate_parts(path: &Path) -> Option<(PathBuf, String)> {
    let name = path.file_name()?.to_str()?;
    let (source, contract) = name
        .strip_suffix(".sqlite3")?
        .split_once(".candidate-v2-")?;
    let hash = |value: &str| {
        value.len() == 64
            && value
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    };
    if !hash(source) || !hash(contract) {
        return None;
    }
    let directory = path.parent()?;
    let index_name = directory.file_name()?.to_str()?.strip_suffix(".staging")?;
    if index_name.is_empty() {
        return None;
    }
    Some((directory.with_file_name(index_name), name.to_owned()))
}

fn candidate_spec(family: &str, name: &str) -> Result<StoreSpec, String> {
    let mut digest = Sha256::new();
    digest.update(b"tokenbar-exact-stage-candidate-v2\0");
    digest.update(family.as_bytes());
    digest.update(b"\0");
    digest.update(name.as_bytes());
    StoreSpec::new(
        "exact",
        format!("{:x}", digest.finalize()),
        format!("exact/staging/{family}/{name}"),
    )
    .map_err(|error| error.to_string())
}

fn plain_spec(source: String) -> Result<StoreSpec, String> {
    StoreSpec::new("exact", source.clone(), format!("exact/index/{source}"))
        .map_err(|error| error.to_string())
}

impl ExactAddress {
    pub(super) fn new(path: &Path) -> Result<Self, String> {
        match std::fs::symlink_metadata(path) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err("拒绝以符号链接数据库文件定位 Exact 业务分区".into());
            }
            Ok(metadata) if !metadata.is_file() => {
                return Err("Exact 业务分区数据库路径不是普通文件".into());
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(format!(
                    "无法确认 Exact 业务分区路径 {}：{error}",
                    path.display()
                ))
            }
        }
        let (preferred, mut candidates) = if let Some((index, name)) = candidate_parts(path) {
            let (preferred, aliases) = identities(&index)?;
            (
                candidate_spec(&preferred, &name)?,
                aliases
                    .iter()
                    .map(|family| candidate_spec(family, &name))
                    .collect::<Result<Vec<_>, _>>()?,
            )
        } else {
            let (preferred, aliases) = identities(path)?;
            (
                plain_spec(preferred)?,
                aliases
                    .into_iter()
                    .map(plain_spec)
                    .collect::<Result<Vec<_>, _>>()?,
            )
        };
        candidates.sort_by(|a, b| a.id.cmp(&b.id));
        candidates.dedup_by(|a, b| a.id == b.id);
        Ok(Self {
            preferred,
            candidates,
        })
    }

    /// This never registers, imports, changes a receipt, or opens another A.
    /// Every historical candidate is an exact primary-key lookup, not a
    /// `substr` catalog scan or a search through every namespace's manifest.
    pub(super) fn registered(&self, connection: &Connection) -> Result<Vec<StoreSpec>, String> {
        let mut statement = connection.prepare_cached(
            "SELECT module,source_identity,logical_path,namespace_prefix FROM tb_stores WHERE store_id=?1"
        ).map_err(|error| error.to_string())?;
        let mut found = Vec::new();
        for candidate in &self.candidates {
            let row: Option<(String, String, String, String)> = statement
                .query_row([&candidate.id], |row| {
                    Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
                })
                .optional()
                .map_err(|error| error.to_string())?;
            if let Some((module, source, logical, prefix)) = row {
                if module != candidate.module
                    || source != candidate.source_identity
                    || logical != candidate.logical_path
                    || prefix != candidate.prefix
                {
                    return Err(format!(
                        "Exact 旧路径分区目录身份不一致；已保留全部分区：{}",
                        candidate.id
                    ));
                }
                found.push(candidate.clone());
            }
        }
        Ok(found)
    }

    pub(super) fn resolve(
        &self,
        connection: &Connection,
        writing: bool,
    ) -> Result<Option<StoreSpec>, String> {
        if connection.is_autocommit() {
            let snapshot = connection
                .unchecked_transaction()
                .map_err(|error| error.to_string())?;
            let result = self.resolve_in_snapshot(&snapshot, writing);
            snapshot.commit().map_err(|error| error.to_string())?;
            result
        } else {
            self.resolve_in_snapshot(connection, writing)
        }
    }

    fn resolve_in_snapshot(
        &self,
        connection: &Connection,
        writing: bool,
    ) -> Result<Option<StoreSpec>, String> {
        let mut found = self.registered(connection)?;
        if found.len() <= 1 {
            return Ok(found.into_iter().next());
        }
        // A previous router could register its new spelling and then stop
        // before materializing any table. That untouched reservation has no
        // competing history. Keep the row, but continue using the one owner
        // that actually contains the historical database.
        let mut populated = Vec::new();
        for store in &found {
            if !unused_reservation(connection, store)? {
                populated.push(store.clone());
            }
        }
        if populated.len() == 1 {
            return Ok(populated.pop());
        }
        if populated.is_empty() {
            return Ok(Some(
                found
                    .iter()
                    .find(|store| store.id == self.preferred.id)
                    .unwrap_or(&found[0])
                    .clone(),
            ));
        }
        found = populated;
        // Equivalent historical owners are sufficient for a read. A writer
        // needs an explicit convergence receipt before either copy diverges;
        // selecting one silently here would merely defer the conflict.
        if !writing {
            let first = crate::core::business_store_container::store_proof_in_transaction(
                connection, &found[0],
            )
            .map_err(|error| error.to_string())?;
            let equivalent = found.iter().skip(1).try_fold(true, |same, store| {
                crate::core::business_store_container::store_proof_in_transaction(connection, store)
                    .map(|proof| same && proof == first)
                    .map_err(|error| error.to_string())
            })?;
            if equivalent {
                return Ok(Some(
                    found
                        .iter()
                        .find(|store| store.id == self.preferred.id)
                        .unwrap_or(&found[0])
                        .clone(),
                ));
            }
        }
        Err(format!(
            "Exact 路径对应多个历史分区，需完整历史接续后才能写入；已保留全部分区：{}",
            found
                .iter()
                .map(|store| store.id.as_str())
                .collect::<Vec<_>>()
                .join(",")
        ))
    }
}

fn unused_reservation(connection: &Connection, store: &StoreSpec) -> Result<bool, String> {
    let unused: bool = connection
        .query_row(
            "SELECT user_version=0 AND revision=0 AND state='ready' \
         AND NOT EXISTS(SELECT 1 FROM tb_store_imports WHERE store_id=?1) \
         AND NOT EXISTS(SELECT 1 FROM tb_store_objects WHERE store_id=?1) \
         AND NOT EXISTS(SELECT 1 FROM tb_store_seals WHERE store_id=?1) \
         AND NOT EXISTS(SELECT 1 FROM tb_legacy_inputs WHERE store_id=?1) \
         AND NOT EXISTS(SELECT 1 FROM tb_container_meta WHERE key IN (?2,?3)) \
         FROM tb_stores WHERE store_id=?1",
            rusqlite::params![
                store.id,
                format!("migration_pending_store_v1:{}", store.id),
                format!("{LEGACY_EXACT_MIGRATION_KEY}{}", store.id)
            ],
            |row| row.get(0),
        )
        .map_err(|error| error.to_string())?;
    if !unused {
        return Ok(false);
    }
    let objects: bool = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM main.sqlite_master WHERE name>=?1 AND name<?2)",
            rusqlite::params![store.prefix, format!("{}~", store.prefix)],
            |row| row.get(0),
        )
        .map_err(|error| error.to_string())?;
    Ok(!objects)
}

pub(super) fn candidate_families(index: &Path) -> Result<Vec<String>, String> {
    identities(index).map(|(_, aliases)| aliases)
}

#[cfg(test)]
#[path = "path_identity_tests.rs"]
mod tests;
