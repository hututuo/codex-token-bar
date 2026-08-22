//! Windows process inspection that cannot be expressed through the portable
//! process APIs.  This module deliberately reads only the target's
//! `CODEX_HOME` value and never persists the remote environment block.

use std::ffi::c_void;
use std::mem::{size_of, MaybeUninit};
use std::path::PathBuf;

use windows_sys::Wdk::System::Threading::{
    NtQueryInformationProcess, ProcessBasicInformation, PROCESSINFOCLASS,
};
use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, HANDLE};
use windows_sys::Win32::System::Diagnostics::Debug::ReadProcessMemory;
use windows_sys::Win32::System::SystemInformation::IMAGE_FILE_MACHINE_UNKNOWN;
use windows_sys::Win32::System::Threading::{
    IsWow64Process2, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_VM_READ,
};

const MAX_ENVIRONMENT_BYTES: usize = 1024 * 1024;
const ENVIRONMENT_READ_CHUNK_BYTES: usize = 4096;

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct RawProcessBasicInformation {
    exit_status: i32,
    peb_base_address: *mut c_void,
    affinity_mask: usize,
    base_priority: i32,
    unique_process_id: usize,
    inherited_from_unique_process_id: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct RawPebPrefix {
    reserved1: [u8; 2],
    being_debugged: u8,
    reserved2: [u8; 1],
    reserved3: [*mut c_void; 2],
    ldr: *mut c_void,
    process_parameters: *mut c_void,
}

struct OwnedProcessHandle(HANDLE);

impl Drop for OwnedProcessHandle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }
}

/// Reads one environment variable from a live process without invoking a
/// shell or relying on PowerShell/WMI.  The caller must still perform its
/// identity-before/after check around this operation.
pub(crate) fn read_codex_home(pid: u32) -> Result<Option<PathBuf>, String> {
    let process = open_process(pid)?;
    ensure_matching_process_architecture(process.0, pid)?;

    let mut basic = RawProcessBasicInformation::default();
    let mut returned = 0_u32;
    let status = unsafe {
        NtQueryInformationProcess(
            process.0,
            ProcessBasicInformation as PROCESSINFOCLASS,
            (&mut basic as *mut RawProcessBasicInformation).cast(),
            size_of::<RawProcessBasicInformation>() as u32,
            &mut returned,
        )
    };
    if status != 0 || basic.peb_base_address.is_null() {
        return Err(format!(
            "读取 Windows 进程 {pid} 的 PEB 失败（NTSTATUS 0x{status:08x}）"
        ));
    }

    let peb: RawPebPrefix = read_remote(process.0, basic.peb_base_address.cast())
        .map_err(|error| format!("读取 Windows 进程 {pid} 的 PEB 失败：{error}"))?;
    if peb.process_parameters.is_null() {
        return Err(format!("Windows 进程 {pid} 缺少有效的进程参数块"));
    }

    // RTL_USER_PROCESS_PARAMETERS places Environment immediately after the
    // two UNICODE_STRING values (ImagePathName and CommandLine).  The pointer
    // offset is architecture dependent; x64 and ARM64 share the 0x80 layout,
    // while a 32-bit build uses 0x48.  WOW64 targets are rejected above.
    let environment_offset = if cfg!(target_pointer_width = "64") {
        0x80
    } else {
        0x48
    };
    let environment_address: *mut c_void = read_remote(
        process.0,
        (peb.process_parameters as usize + environment_offset) as *const c_void,
    )?;
    if environment_address.is_null() {
        return Ok(None);
    }

    let environment = read_environment_block(process.0, environment_address, pid)?;
    Ok(find_environment_value(&environment, "CODEX_HOME").map(PathBuf::from))
}

fn open_process(pid: u32) -> Result<OwnedProcessHandle, String> {
    let desired = PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ;
    let handle = unsafe { OpenProcess(desired, 0, pid) };
    if handle.is_null() {
        return Err(format!(
            "无法读取 Windows 进程 {pid} 的环境（Windows error {}）",
            unsafe { GetLastError() }
        ));
    }
    Ok(OwnedProcessHandle(handle))
}

fn ensure_matching_process_architecture(handle: HANDLE, pid: u32) -> Result<(), String> {
    let mut process_machine = IMAGE_FILE_MACHINE_UNKNOWN;
    let mut native_machine = IMAGE_FILE_MACHINE_UNKNOWN;
    let ok = unsafe { IsWow64Process2(handle, &mut process_machine, &mut native_machine) };
    if ok == 0 {
        return Err(format!(
            "无法确认 Windows 进程 {pid} 的架构（Windows error {}）",
            unsafe { GetLastError() }
        ));
    }
    if process_machine != IMAGE_FILE_MACHINE_UNKNOWN {
        return Err(format!(
            "Windows 进程 {pid} 是 WOW64/32 位进程，当前版本拒绝跨指针宽度读取 CODEX_HOME"
        ));
    }
    let _ = native_machine;
    Ok(())
}

fn read_remote<T: Copy>(handle: HANDLE, address: *const c_void) -> Result<T, String> {
    if address.is_null() {
        return Err("目标进程地址为空".into());
    }
    let mut value = MaybeUninit::<T>::zeroed();
    let mut read = 0_usize;
    let ok = unsafe {
        ReadProcessMemory(
            handle,
            address,
            value.as_mut_ptr().cast(),
            size_of::<T>(),
            &mut read,
        )
    };
    if ok == 0 || read != size_of::<T>() {
        return Err(format!(
            "远程内存读取失败（Windows error {}，读取 {read}/{} 字节）",
            unsafe { GetLastError() },
            size_of::<T>()
        ));
    }
    Ok(unsafe { value.assume_init() })
}

fn read_environment_block(
    handle: HANDLE,
    address: *mut c_void,
    pid: u32,
) -> Result<Vec<u16>, String> {
    let mut bytes = Vec::with_capacity(ENVIRONMENT_READ_CHUNK_BYTES);
    let mut offset = 0_usize;
    while offset < MAX_ENVIRONMENT_BYTES {
        let requested = ENVIRONMENT_READ_CHUNK_BYTES.min(MAX_ENVIRONMENT_BYTES - offset);
        let mut chunk = vec![0_u8; requested];
        let mut read = 0_usize;
        let ok = unsafe {
            ReadProcessMemory(
                handle,
                (address as usize + offset) as *const c_void,
                chunk.as_mut_ptr().cast(),
                requested,
                &mut read,
            )
        };
        if ok == 0 || read == 0 {
            return Err(format!(
                "读取 Windows 进程 {pid} 的环境块失败（Windows error {}）",
                unsafe { GetLastError() }
            ));
        }
        bytes.extend_from_slice(&chunk[..read]);
        if bytes.len() >= 4 {
            let end = bytes.len() - 4;
            if bytes[end..].iter().all(|byte| *byte == 0) {
                break;
            }
        }
        offset = offset.saturating_add(read);
        if read < requested {
            return Err(format!("Windows 进程 {pid} 的环境块在终止符前被截断"));
        }
    }
    if bytes.len() == MAX_ENVIRONMENT_BYTES
        && !bytes
            .windows(4)
            .any(|window| window.iter().all(|byte| *byte == 0))
    {
        return Err(format!("Windows 进程 {pid} 的环境块超过安全读取上限"));
    }
    if bytes.len() % 2 != 0 {
        return Err(format!("Windows 进程 {pid} 的环境块不是偶数字节"));
    }
    Ok(bytes
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
        .collect())
}

fn find_environment_value(environment: &[u16], key: &str) -> Option<String> {
    environment
        .split(|unit| *unit == 0)
        .take_while(|entry| !entry.is_empty())
        .filter_map(|entry| String::from_utf16(entry).ok())
        .find_map(|entry| {
            let (name, value) = entry.split_once('=')?;
            if name.eq_ignore_ascii_case(key) && !value.is_empty() {
                Some(value.to_string())
            } else {
                None
            }
        })
}

#[cfg(test)]
mod tests {
    use super::{find_environment_value, read_codex_home};

    #[test]
    fn environment_lookup_is_case_insensitive_and_does_not_leak_other_values() {
        let block = "Path=C:\\Windows\0codex_home=C:\\Users\\Test User\\.codex\0SECRET=hidden\0\0";
        let units = block.encode_utf16().collect::<Vec<_>>();
        assert_eq!(
            find_environment_value(&units, "CODEX_HOME").as_deref(),
            Some("C:\\Users\\Test User\\.codex")
        );
        assert_eq!(
            find_environment_value(&units, "SECRET"),
            Some("hidden".into())
        );
        assert_eq!(find_environment_value(&units, "MISSING"), None);
    }

    #[cfg(windows)]
    #[test]
    fn reads_codex_home_from_a_live_child_environment() {
        use std::process::Command;

        let mut child = Command::new("cmd.exe")
            .args(["/C", "ping", "127.0.0.1", "-n", "6"])
            .env("CODEX_HOME", r"C:\Users\Test User\.codex")
            .spawn()
            .expect("spawn Windows child process");

        let result = read_codex_home(child.id());
        let _ = child.kill();
        let _ = child.wait();

        assert_eq!(
            result.expect("read child environment").as_deref(),
            Some(std::path::Path::new(r"C:\Users\Test User\.codex"))
        );
    }

    #[cfg(windows)]
    #[test]
    fn missing_codex_home_is_a_readable_none_result() {
        use std::process::Command;

        let mut child = Command::new("cmd.exe")
            .args(["/C", "ping", "127.0.0.1", "-n", "6"])
            .env_remove("CODEX_HOME")
            .spawn()
            .expect("spawn Windows child process");

        let result = read_codex_home(child.id());
        let _ = child.kill();
        let _ = child.wait();

        assert_eq!(result.expect("read child environment"), None);
    }
}
