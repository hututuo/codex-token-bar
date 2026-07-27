use fs2::FileExt;
use std::fs::{self, File, OpenOptions};
use std::path::Path;

#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

pub(crate) struct CrossProcessFileLock {
    file: File,
}

impl CrossProcessFileLock {
    pub(crate) fn acquire(path: &Path, label: &str) -> Result<Self, String> {
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
        file.try_lock_exclusive()
            .map_err(|error| format!("{label}正在由另一个 Token Bar 进程执行：{error}"))?;
        Ok(Self { file })
    }
}

impl Drop for CrossProcessFileLock {
    fn drop(&mut self) {
        let _ = self.file.unlock();
    }
}

#[cfg(test)]
mod tests {
    use super::CrossProcessFileLock;
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
}
