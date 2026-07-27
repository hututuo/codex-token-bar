#[cfg(any(test, windows))]
pub(crate) fn extended_length_path_from_wide(mut path: Vec<u16>) -> Result<Vec<u16>, String> {
    if path.is_empty() || path.contains(&0) {
        return Err("Windows 文件操作路径无效".into());
    }
    for unit in &mut path {
        if *unit == u16::from(b'/') {
            *unit = u16::from(b'\\');
        }
    }

    let slash = u16::from(b'\\');
    let question = u16::from(b'?');
    let dot = u16::from(b'.');
    let colon = u16::from(b':');
    let has_verbatim_prefix = path.starts_with(&[slash, slash, question, slash]);
    let has_device_prefix = path.starts_with(&[slash, slash, dot, slash]);
    let is_unc = path.starts_with(&[slash, slash]);
    let is_drive_absolute = path.len() >= 3
        && ((u16::from(b'A')..=u16::from(b'Z')).contains(&path[0])
            || (u16::from(b'a')..=u16::from(b'z')).contains(&path[0]))
        && path[1] == colon
        && path[2] == slash;
    if !has_verbatim_prefix && !has_device_prefix && !is_unc && !is_drive_absolute {
        return Err("Windows 文件操作要求绝对路径".into());
    }
    if has_verbatim_prefix {
        let remainder = &path[4..];
        let unc_prefix = "UNC\\".encode_utf16().collect::<Vec<_>>();
        let valid_prefixed_drive = remainder.len() >= 3
            && ((u16::from(b'A')..=u16::from(b'Z')).contains(&remainder[0])
                || (u16::from(b'a')..=u16::from(b'z')).contains(&remainder[0]))
            && remainder[1] == colon
            && remainder[2] == slash;
        let valid_prefixed_unc = starts_with_ascii_case_insensitive(remainder, &unc_prefix)
            && remainder[unc_prefix.len()..]
                .split(|unit| *unit == slash)
                .filter(|part| !part.is_empty())
                .take(2)
                .count()
                == 2;
        if !valid_prefixed_drive && !valid_prefixed_unc {
            return Err("Windows 扩展路径不是合法的本地盘或 UNC 绝对路径".into());
        }
    }
    if path
        .split(|unit| *unit == slash)
        .any(|component| component == [dot] || component == [dot, dot])
    {
        return Err("Windows 文件操作路径不能包含点组件".into());
    }
    if is_unc && !has_verbatim_prefix {
        let mut components = path.split(|unit| *unit == slash).filter(|part| !part.is_empty());
        if components.next().is_none() || components.next().is_none() {
            return Err("Windows UNC 路径缺少服务器或共享名".into());
        }
    }

    let mut extended = if has_verbatim_prefix || has_device_prefix {
        path
    } else if is_unc {
        "\\\\?\\UNC\\"
            .encode_utf16()
            .chain(path.into_iter().skip(2))
            .collect()
    } else {
        "\\\\?\\".encode_utf16().chain(path).collect()
    };
    extended.push(0);
    Ok(extended)
}

#[cfg(any(test, windows))]
fn starts_with_ascii_case_insensitive(value: &[u16], prefix: &[u16]) -> bool {
    value.len() >= prefix.len()
        && value[..prefix.len()]
            .iter()
            .zip(prefix)
            .all(|(left, right)| ascii_uppercase(*left) == ascii_uppercase(*right))
}

#[cfg(any(test, windows))]
fn ascii_uppercase(value: u16) -> u16 {
    if (u16::from(b'a')..=u16::from(b'z')).contains(&value) {
        value - u16::from(b'a') + u16::from(b'A')
    } else {
        value
    }
}

#[cfg(windows)]
pub(crate) fn extended_length_path(path: &std::path::Path) -> Result<Vec<u16>, String> {
    use std::os::windows::ffi::OsStrExt;
    extended_length_path_from_wide(path.as_os_str().encode_wide().collect())
        .map_err(|error| format!("{error}：{}", path.display()))
}

#[cfg(any(test, windows))]
pub(crate) fn retry_missing_replace_target(
    replace_error: std::io::Error,
    retry: impl FnOnce() -> std::io::Result<()>,
) -> std::io::Result<()> {
    if replace_error.kind() == std::io::ErrorKind::NotFound {
        retry()
    } else {
        Err(replace_error)
    }
}

#[cfg(test)]
mod tests {
    use super::{extended_length_path_from_wide, retry_missing_replace_target};
    use std::sync::atomic::{AtomicBool, Ordering};

    #[test]
    fn accepts_case_insensitive_extended_unc_prefixes() {
        for path in [
            r"\\?\unc\server\share\ack.json",
            r"\\?\UnC\server\share\ack.json",
        ] {
            let converted = extended_length_path_from_wide(path.encode_utf16().collect()).unwrap();
            assert_eq!(
                String::from_utf16(&converted[..converted.len() - 1]).unwrap(),
                path
            );
        }
        assert!(extended_length_path_from_wide(r"\\?\unc\server".encode_utf16().collect())
            .is_err());
    }

    #[test]
    fn retries_only_when_replace_target_disappeared() {
        let retried = AtomicBool::new(false);
        retry_missing_replace_target(
            std::io::Error::from(std::io::ErrorKind::NotFound),
            || {
                retried.store(true, Ordering::Release);
                Ok(())
            },
        )
        .unwrap();
        assert!(retried.load(Ordering::Acquire));

        let retried = AtomicBool::new(false);
        let error = retry_missing_replace_target(
            std::io::Error::from(std::io::ErrorKind::PermissionDenied),
            || {
                retried.store(true, Ordering::Release);
                Ok(())
            },
        )
        .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
        assert!(!retried.load(Ordering::Acquire));
    }
}
