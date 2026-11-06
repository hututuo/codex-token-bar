//! Verified filesystem snapshots for legacy store databases.
//!
//! Backup publication is a file-set protocol: the source is read-only, a
//! private temporary image is verified and synced, and only then is it moved
//! into place without replacing a competing publisher. The parent container
//! still owns store proofs and legacy-input meaning; this module owns only the
//! snapshot file operation and its error-safe cleanup.

use super::{BusinessStoreError, BusinessStoreResult, Container};
use crate::core::atomic_file;
use rusqlite::{backup::Backup, Connection, OpenFlags};
use std::fs::{self, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

static BACKUP_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

impl Container {
    /// Make a SQLite online-backup snapshot of an old module database. The
    /// source is opened read-only and is never removed or rewritten.
    pub(crate) fn backup_snapshot(
        source_path: impl AsRef<Path>,
        backup_path: impl AsRef<Path>,
    ) -> BusinessStoreResult<()> {
        let source_path = source_path.as_ref();
        let backup_path = backup_path.as_ref();
        let expected_digest = Self::snapshot_digest(source_path)?;
        Self::ensure_verified_backup(source_path, backup_path, &expected_digest)
    }

    /// Ensure a complete, verified backup exists at `backup_path`. Existing
    /// matching backups are reused. Any other existing destination is moved
    /// aside before rebuilding, so an interrupted or corrupt backup is never
    /// mistaken for a committed one and its bytes remain recoverable.
    pub(crate) fn ensure_verified_backup(
        source_path: impl AsRef<Path>,
        backup_path: impl AsRef<Path>,
        expected_digest: &str,
    ) -> BusinessStoreResult<()> {
        Self::ensure_verified_backup_with(
            source_path.as_ref(),
            backup_path.as_ref(),
            expected_digest,
            Self::write_backup_snapshot,
        )
    }

    pub(super) fn ensure_verified_backup_with(
        source_path: &Path,
        backup_path: &Path,
        expected_digest: &str,
        build: impl FnOnce(&Path, &Path) -> BusinessStoreResult<()>,
    ) -> BusinessStoreResult<()> {
        if backup_path.file_name().is_none() {
            return Err(BusinessStoreError::InvalidStore);
        }
        reject_backup_target_aliasing_source(source_path, backup_path)?;
        if backup_path_matches(backup_path, expected_digest) {
            return Ok(());
        }

        let parent = backup_parent(backup_path);
        fs::create_dir_all(parent)?;
        if Self::snapshot_digest(source_path)? != expected_digest {
            return Err(BusinessStoreError::ProofMismatch);
        }

        if backup_path_matches(backup_path, expected_digest) {
            return Ok(());
        }
        if backup_set_has_files(backup_path)? {
            quarantine_backup_set(backup_path)?;
        }

        let temporary = create_backup_temporary_path(backup_path)?;
        let build_result = build(source_path, &temporary);
        if let Err(error) = build_result {
            cleanup_backup_temporary(&temporary);
            return Err(error);
        }

        let verify_result = verify_backup(&temporary);
        match verify_result {
            Ok(digest) if digest == expected_digest => {}
            Ok(_) => {
                cleanup_backup_temporary(&temporary);
                return Err(BusinessStoreError::ProofMismatch);
            }
            Err(error) => {
                cleanup_backup_temporary(&temporary);
                return Err(error);
            }
        }

        let sync_result = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&temporary)
            .and_then(|file| file.sync_all());
        if let Err(error) = sync_result {
            cleanup_backup_temporary(&temporary);
            return Err(error.into());
        }

        // A no-replace publish prevents a concurrent, already-verified backup
        // from being overwritten. If another writer wins, accept its result
        // only after proving that it matches this expected snapshot.
        match rename_without_replacement(&temporary, backup_path) {
            Ok(()) => atomic_file::sync_parent(parent)?,
            Err(_error) if path_exists(backup_path)? => {
                if backup_path_matches(backup_path, expected_digest) {
                    cleanup_backup_temporary(&temporary);
                    return Ok(());
                }
                quarantine_backup_set(backup_path)?;
                if let Err(publish_error) = rename_without_replacement(&temporary, backup_path) {
                    if backup_path_matches(backup_path, expected_digest) {
                        cleanup_backup_temporary(&temporary);
                        return Ok(());
                    }
                    cleanup_backup_temporary(&temporary);
                    return Err(publish_error.into());
                }
                atomic_file::sync_parent(parent)?;
            }
            Err(error) => {
                cleanup_backup_temporary(&temporary);
                return Err(error.into());
            }
        }
        Ok(())
    }

    pub(super) fn write_backup_snapshot(source_path: &Path, backup_path: &Path) -> BusinessStoreResult<()> {
        let source = Connection::open_with_flags(
            source_path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
        )?;
        let mut target = Connection::open(backup_path)?;
        {
            let backup = Backup::new(&source, &mut target)?;
            backup.run_to_completion(128, Duration::from_millis(10), None)?;
        }
        // The backup API may copy the source's WAL journal mode. Publish a
        // self-contained image, never a main file depending on temp sidecars.
        target.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;")?;
        let check: String = target.query_row("PRAGMA quick_check(1)", [], |row| row.get(0))?;
        if check != "ok" {
            return Err(BusinessStoreError::ProofMismatch);
        }
        Ok(())
    }
}

fn backup_parent(path: &Path) -> &Path {
    path.parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."))
}

fn path_exists(path: &Path) -> std::io::Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

fn verify_backup(path: &Path) -> BusinessStoreResult<String> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() {
        return Err(BusinessStoreError::ProofMismatch);
    }
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )?;
    let check: String = connection.query_row("PRAGMA quick_check(1)", [], |row| row.get(0))?;
    if check != "ok" {
        return Err(BusinessStoreError::ProofMismatch);
    }
    drop(connection);
    Container::snapshot_digest(path)
}

fn backup_path_matches(path: &Path, expected_digest: &str) -> bool {
    verify_backup(path).is_ok_and(|digest| digest == expected_digest)
}

fn reject_backup_target_aliasing_source(
    source_path: &Path,
    backup_path: &Path,
) -> BusinessStoreResult<()> {
    if source_path == backup_path || !path_exists(source_path)? || !path_exists(backup_path)? {
        return if source_path == backup_path {
            Err(BusinessStoreError::InvalidStore)
        } else {
            Ok(())
        };
    }
    let source = match fs::canonicalize(source_path) {
        Ok(path) => path,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    let backup = match fs::canonicalize(backup_path) {
        Ok(path) => path,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    if source == backup {
        return Err(BusinessStoreError::InvalidStore);
    }
    Ok(())
}

fn backup_sidecar_paths(path: &Path) -> [PathBuf; 3] {
    let sidecar = |suffix: &str| {
        let mut name = path.as_os_str().to_os_string();
        name.push(suffix);
        PathBuf::from(name)
    };
    [sidecar("-wal"), sidecar("-shm"), sidecar("-journal")]
}

fn backup_set_has_files(path: &Path) -> std::io::Result<bool> {
    if path_exists(path)? {
        return Ok(true);
    }
    for sidecar in backup_sidecar_paths(path) {
        if path_exists(&sidecar)? {
            return Ok(true);
        }
    }
    Ok(false)
}

fn quarantine_backup_set(path: &Path) -> BusinessStoreResult<()> {
    let parent = backup_parent(path);
    let quarantine = quarantine_backup_path(path)?;
    let sources = std::iter::once(path.to_path_buf()).chain(backup_sidecar_paths(path));
    let targets = std::iter::once(quarantine.clone()).chain(backup_sidecar_paths(&quarantine));
    for (member, destination) in sources.zip(targets) {
        if !path_exists(&member)? {
            continue;
        }
        rename_without_replacement(&member, &destination)?;
        atomic_file::sync_parent(parent)?;
    }
    Ok(())
}

fn create_backup_temporary_path(backup_path: &Path) -> std::io::Result<PathBuf> {
    let parent = backup_parent(backup_path);
    // Production backup basenames already contain three SHA-256 hashes.
    // Keep temporary/quarantine names short enough for SQLite's -journal
    // suffix on filesystems with a 255-byte component limit.
    for _ in 0..64 {
        let sequence = BACKUP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let candidate = parent.join(format!(
            ".tokenbar-backup-{}-{sequence:020}.sqlite",
            std::process::id()
        ));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(file) => {
                drop(file);
                return Ok(candidate);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        "could not allocate a unique SQLite backup temporary file",
    ))
}

fn quarantine_backup_path(backup_path: &Path) -> std::io::Result<PathBuf> {
    let parent = backup_parent(backup_path);
    // Production backup basenames already contain three SHA-256 hashes.
    // Keep temporary/quarantine names short enough for SQLite's -journal
    // suffix on filesystems with a 255-byte component limit.
    for _ in 0..64 {
        let candidate = parent.join(format!(
            ".tokenbar-backup-quarantine-{}.sqlite",
            uuid::Uuid::new_v4()
        ));
        if !path_exists(&candidate)? {
            return Ok(candidate);
        }
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        "could not allocate a unique SQLite backup quarantine path",
    ))
}

fn cleanup_backup_temporary(path: &Path) {
    let _ = fs::remove_file(path);
    for suffix in ["-journal", "-wal", "-shm"] {
        let mut sidecar = path.as_os_str().to_os_string();
        sidecar.push(suffix);
        let _ = fs::remove_file(PathBuf::from(sidecar));
    }
}

fn rename_without_replacement(source: &Path, destination: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use rustix::fs::{open, renameat_with, Mode, OFlags, RenameFlags};
        let parent = backup_parent(source);
        let directory = open(
            parent,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(|error| std::io::Error::other(error.to_string()))?;
        let source_name = source
            .file_name()
            .ok_or_else(|| std::io::Error::other("source path has no filename"))?;
        let destination_name = destination
            .file_name()
            .ok_or_else(|| std::io::Error::other("destination path has no filename"))?;
        renameat_with(
            &directory,
            source_name,
            &directory,
            destination_name,
            RenameFlags::NOREPLACE,
        )
        .map_err(|error| std::io::Error::other(error.to_string()))
    }
    #[cfg(windows)]
    {
        let source = crate::core::windows_path::extended_length_path(source)
            .map_err(std::io::Error::other)?;
        let destination = crate::core::windows_path::extended_length_path(destination)
            .map_err(std::io::Error::other)?;
        // MoveFileExW without MOVEFILE_REPLACE_EXISTING is an atomic,
        // same-volume move that fails when the destination already exists.
        let moved = unsafe {
            windows_sys::Win32::Storage::FileSystem::MoveFileExW(
                source.as_ptr(),
                destination.as_ptr(),
                0,
            )
        };
        if moved == 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(())
        }
    }
    #[cfg(not(any(unix, windows)))]
    {
        if path_exists(destination)? {
            return Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                "destination already exists",
            ));
        }
        fs::rename(source, destination)
    }
}
