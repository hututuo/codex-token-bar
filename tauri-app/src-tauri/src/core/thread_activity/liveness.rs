//! Current rollout writer evidence. Never opens app-server, reads credentials,
//! acquires a writer lock, or edits a session. A terminal lifecycle always wins.
use std::path::Path;

#[derive(Default)]
pub(super) struct WriterProbe {
    #[cfg(target_os = "macos")]
    files: Option<std::collections::HashSet<(u32, u64)>>,
}

impl WriterProbe {
    pub(super) fn has_writer(&mut self, path: &Path) -> Result<bool, String> {
        #[cfg(target_os = "macos")]
        {
            use std::os::unix::fs::MetadataExt;
            if self.files.is_none() { self.files = Some(macos_snapshot()?); }
            let metadata = std::fs::symlink_metadata(path).map_err(|e| e.to_string())?;
            return Ok(metadata.is_file() && !metadata.file_type().is_symlink()
                && self.files.as_ref().unwrap().contains(&(metadata.dev() as u32, metadata.ino())));
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            // Reuse the existing file-ownership probe's sharing contract. This
            // read-only open succeeds only without an existing write handle;
            // read-only viewers, a lock file, or an unrelated process don't count.
            let metadata = std::fs::symlink_metadata(path).map_err(|e| e.to_string())?;
            if !metadata.is_file() || metadata.file_type().is_symlink() { return Ok(false); }
            return match std::fs::OpenOptions::new().read(true).share_mode(0x1 | 0x4).open(path) {
                Ok(_) => Ok(false),
                Err(error) if error.raw_os_error() == Some(32) => Ok(true),
                Err(error) => Err(format!("无法确认会话写入句柄：{error}")),
            };
        }
        #[cfg(not(any(target_os = "macos", windows)))]
        { let _ = path; Err("当前平台无法确认会话写入句柄".into()) }
    }
}

#[cfg(target_os = "macos")]
fn macos_snapshot() -> Result<std::collections::HashSet<(u32, u64)>, String> {
    let mut capacity = 1_024;
    while capacity <= 65_536 {
        let mut pids = vec![0i32; capacity];
        let count = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), (pids.len() * 4) as i32) };
        if count < 0 { return Err(std::io::Error::last_os_error().to_string()); }
        if count as usize >= capacity { capacity *= 2; continue; }
        let mut files = std::collections::HashSet::new();
        for pid in pids.into_iter().take(count as usize).filter(|pid| *pid > 0 && *pid as u32 != std::process::id()) {
            let mut path = [0u8; 4_096];
            if unsafe { libc::proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) } <= 0 { continue; }
            let end = path.iter().position(|b| *b == 0).unwrap_or(path.len());
            let executable = String::from_utf8_lossy(&path[..end]);
            if Path::new(executable.as_ref()).file_name().and_then(|s| s.to_str()) != Some("codex") { continue; }
            files.extend(macos_write_handles(pid)?);
        }
        return Ok(files);
    }
    Err("Codex 进程清单超过读取上限".into())
}

#[cfg(target_os = "macos")]
fn macos_write_handles(pid: i32) -> Result<std::collections::HashSet<(u32, u64)>, String> {
    // Darwin proc_info.h; libc exposes vnode_info_path but not its FD wrapper.
    #[repr(C)]
    struct ProcFileInfo { open_flags: u32, status: u32, offset: i64, kind: i32, guard_flags: u32 }
    #[repr(C)]
    struct VnodeFDInfo { file: ProcFileInfo, node: libc::vnode_info_path }
    let mut capacity = 256;
    while capacity <= 65_536 {
        let mut descriptors: Vec<libc::proc_fdinfo> = (0..capacity).map(|_| unsafe { std::mem::zeroed() }).collect();
        let bytes = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, descriptors.as_mut_ptr().cast(),
            (descriptors.len() * std::mem::size_of::<libc::proc_fdinfo>()) as i32) };
        if bytes <= 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) { return Ok(Default::default()); }
            return Err(error.to_string());
        }
        let count = bytes as usize / std::mem::size_of::<libc::proc_fdinfo>();
        if count >= capacity { capacity *= 2; continue; }
        let mut files = std::collections::HashSet::new();
        for descriptor in descriptors.into_iter().take(count).filter(|fd| fd.proc_fdtype == libc::PROX_FDTYPE_VNODE as u32) {
            let mut info = std::mem::MaybeUninit::<VnodeFDInfo>::zeroed();
            let size = std::mem::size_of::<VnodeFDInfo>() as i32;
            let read = unsafe { libc::proc_pidfdinfo(pid, descriptor.proc_fd, 2, info.as_mut_ptr().cast(), size) };
            if read != size {
                let error = std::io::Error::last_os_error();
                if matches!(error.raw_os_error(), Some(libc::EBADF | libc::ESRCH | libc::ENOENT)) { continue; }
                return Err(error.to_string());
            }
            let info = unsafe { info.assume_init() };
            if info.file.open_flags & 2 != 0 {
                files.insert((info.node.vip_vi.vi_stat.vst_dev, info.node.vip_vi.vi_stat.vst_ino));
            }
        }
        return Ok(files);
    }
    Err("Codex 文件句柄超过读取上限".into())
}

#[cfg(test)]
mod tests {
    #[test]
    fn writer_evidence_requires_the_rollout_write_handle() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("rollout.jsonl");
        std::fs::write(&path, b"fixture\n").unwrap();
        let has_writer = || {
            #[cfg(target_os = "macos")]
            {
                use std::os::unix::fs::MetadataExt;
                let metadata = path.metadata().unwrap();
                super::macos_write_handles(std::process::id() as i32).unwrap()
                    .contains(&(metadata.dev() as u32, metadata.ino()))
            }
            #[cfg(windows)]
            { super::WriterProbe::default().has_writer(&path).unwrap() }
            #[cfg(not(any(target_os = "macos", windows)))]
            { false }
        };
        let reader = std::fs::File::open(&path).unwrap();
        let lock = std::fs::File::create(directory.path().join("thread.lock")).unwrap();
        assert!(!has_writer());
        let writer = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        assert!(has_writer());
        drop(writer);
        assert!(!has_writer());
        drop((reader, lock));
    }
}
