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
        let unc_prefix: Vec<u16> = "UNC\\".encode_utf16().collect();
        let valid_prefixed_drive = remainder.len() >= 3
            && ((u16::from(b'A')..=u16::from(b'Z')).contains(&remainder[0])
                || (u16::from(b'a')..=u16::from(b'z')).contains(&remainder[0]))
            && remainder[1] == colon
            && remainder[2] == slash;
        let valid_prefixed_unc = remainder.starts_with(&unc_prefix)
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

#[cfg(windows)]
pub(crate) fn extended_length_path(path: &std::path::Path) -> Result<Vec<u16>, String> {
    use std::os::windows::ffi::OsStrExt;
    extended_length_path_from_wide(path.as_os_str().encode_wide().collect())
        .map_err(|error| format!("{error}：{}", path.display()))
}
