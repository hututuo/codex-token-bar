use crate::core::coordination_fs::CoordinationDirectory;
use fs2::FileExt;
use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

pub(crate) struct CrossProcessFileLock {
    file: File,
}

impl CrossProcessFileLock {
    pub(crate) fn acquire(path: &Path, label: &str) -> Result<Self, String> {
        Self::try_acquire(path, label)?
            .ok_or_else(|| format!("{label}正在由另一个 Token Bar 进程执行"))
    }

    pub(crate) fn try_acquire(path: &Path, label: &str) -> Result<Option<Self>, String> {
        let parent = path
            .parent()
            .ok_or_else(|| format!("{label}锁路径缺少父目录"))?;
        fs::create_dir_all(parent)
            .map_err(|error| format!("创建{label}锁目录失败：{error}"))?;

        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true);
        #[cfg(unix)]
        options
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW);

        let file = options
            .open(path)
            .map_err(|error| format!("打开{label}锁失败：{error}"))?;
        #[cfg(unix)]
        file.set_permissions(std::fs::Permissions::from_mode(0o600))
            .map_err(|error| format!("收紧{label}锁权限失败：{error}"))?;
        match file.try_lock_exclusive() {
            Ok(()) => Ok(Some(Self { file })),
            Err(error) if is_lock_contention(&error) => Ok(None),
            Err(error) => Err(format!("获取{label}锁失败：{error}")),
        }
    }

    /// Wait for a bounded amount of time instead of turning normal owner
    /// contention into an immediate read failure. Callers should publish a
    /// waiting state before entering this loop and keep the returned guard
    /// alive for the whole mutating operation.
    pub(crate) fn acquire_wait(
        path: &Path,
        label: &str,
        timeout: Duration,
    ) -> Result<Self, String> {
        Self::acquire_wait_with_hook(path, label, timeout, || {})
    }

    pub(crate) fn acquire_wait_with_hook<F>(
        path: &Path,
        label: &str,
        timeout: Duration,
        on_contention: F,
    ) -> Result<Self, String>
    where
        F: FnOnce(),
    {
        let deadline = Instant::now() + timeout;
        let mut on_contention = Some(on_contention);
        loop {
            if let Some(lock) = Self::try_acquire(path, label)? {
                return Ok(lock);
            }
            if let Some(on_contention) = on_contention.take() {
                on_contention();
            }
            if Instant::now() >= deadline {
                return Err(format!(
                    "等待{label}超时（{} 秒），另一个 Token Bar 进程仍在执行",
                    timeout.as_secs()
                ));
            }
            thread::sleep(Duration::from_millis(80));
        }
    }

    pub(crate) fn acquire_in(
        parent: &CoordinationDirectory,
        name: &str,
        label: &str,
    ) -> Result<Self, String> {
        Self::try_acquire_in(parent, name, label)?
            .ok_or_else(|| format!("{label}正在由另一个 Token Bar 进程执行"))
    }

    pub(crate) fn try_acquire_in(
        parent: &CoordinationDirectory,
        name: &str,
        label: &str,
    ) -> Result<Option<Self>, String> {
        let file = parent.open_lock_file(name, label)?;
        match file.try_lock_exclusive() {
            Ok(()) => {
                parent.verify_current()?;
                Ok(Some(Self { file }))
            }
            Err(error) if is_lock_contention(&error) => Ok(None),
            Err(error) => Err(format!("获取{label}锁失败：{error}")),
        }
    }
}

fn is_lock_contention(error: &io::Error) -> bool {
    if error.kind() == io::ErrorKind::WouldBlock {
        return true;
    }
    #[cfg(unix)]
    {
        let code = error.raw_os_error();
        if code == Some(libc::EWOULDBLOCK) || code == Some(libc::EAGAIN) {
            return true;
        }
    }
    #[cfg(windows)]
    {
        // LockFileEx reports ERROR_LOCK_VIOLATION for a non-blocking conflict.
        if error.raw_os_error() == Some(33) {
            return true;
        }
    }
    false
}

impl Drop for CrossProcessFileLock {
    fn drop(&mut self) {
        let _ = self.file.unlock();
    }
}

#[cfg(test)]
mod tests {
    use super::CrossProcessFileLock;
    use crate::core::coordination_fs::CoordinationHome;
    use std::path::PathBuf;

    fn unique_test_root() -> PathBuf {
        std::env::temp_dir().join(format!(
            "codex-token-bar-cross-process-lock-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ))
    }

    #[test]
    fn exclusive_lock_conflicts_until_holder_is_dropped() {
        let root = unique_test_root();
        let path = root.join("nested/operation.lock");
        let first = CrossProcessFileLock::acquire(&path, "测试").unwrap();
        assert!(CrossProcessFileLock::try_acquire(&path, "测试")
            .unwrap()
            .is_none());
        let error = CrossProcessFileLock::acquire(&path, "测试")
            .err()
            .unwrap();
        assert!(error.contains("正在由另一个 Token Bar 进程执行"));
        drop(first);
        CrossProcessFileLock::acquire(&path, "测试").unwrap();
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn lock_file_is_private_and_rejects_symlinks() {
        use std::os::unix::fs::{symlink, PermissionsExt};

        let root = unique_test_root();
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("operation.lock");
        let lock = CrossProcessFileLock::acquire(&path, "测试").unwrap();
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        drop(lock);
        std::fs::remove_file(&path).unwrap();
        let target = root.join("target");
        std::fs::write(&target, b"not-a-lock").unwrap();
        symlink(&target, &path).unwrap();
        let error = CrossProcessFileLock::acquire(&path, "测试")
            .err()
            .unwrap();
        assert!(error.contains("打开测试锁失败"));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn pinned_directory_allows_exactly_one_lock_holder() {
        let root = unique_test_root();
        std::fs::create_dir_all(&root).unwrap();
        let home = CoordinationHome::open(&root).unwrap();
        let directory = home.session_lock_directory().unwrap();
        let first =
            CrossProcessFileLock::acquire_in(&directory, "session-operation.lock", "测试").unwrap();
        assert!(
            CrossProcessFileLock::try_acquire_in(
                &directory,
                "session-operation.lock",
                "测试"
            )
            .unwrap()
            .is_none()
        );
        drop(first);
        assert!(
            CrossProcessFileLock::try_acquire_in(
                &directory,
                "session-operation.lock",
                "测试"
            )
            .unwrap()
            .is_some()
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(windows)]
    #[test]
    fn windows_shared_open_reaches_lockfileex_for_arbitration() {
        let root = unique_test_root();
        std::fs::create_dir_all(&root).unwrap();
        let home = CoordinationHome::open(&root).unwrap();
        let directory = home.session_lock_directory().unwrap();
        let first =
            CrossProcessFileLock::acquire_in(&directory, "windows-arbitration.lock", "测试").unwrap();
        assert!(
            CrossProcessFileLock::try_acquire_in(
                &directory,
                "windows-arbitration.lock",
                "测试"
            )
            .unwrap()
            .is_none(),
            "the second handle must open successfully and contend in LockFileEx"
        );
        drop(first);
        assert!(
            CrossProcessFileLock::try_acquire_in(
                &directory,
                "windows-arbitration.lock",
                "测试"
            )
            .unwrap()
            .is_some()
        );
        let _ = std::fs::remove_dir_all(root);
    }
}
