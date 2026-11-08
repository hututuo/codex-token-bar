use std::{fs::{self,File,OpenOptions},io::{Read,Write},path::Path};

pub(super) fn safe_directory(path:&Path)->bool {
    let mut current=std::path::PathBuf::new();
    for component in path.components() {
        if matches!(component,std::path::Component::ParentDir){return false}
        current.push(component);
        if matches!(component,std::path::Component::Prefix(_)){continue}
        let Ok(info)=fs::symlink_metadata(&current) else{return false};
        if !info.is_dir()||info.file_type().is_symlink(){return false}
        #[cfg(windows)] {use std::os::windows::fs::MetadataExt;if info.file_attributes()&0x400!=0{return false}}
    }
    true
}
fn open(path:&Path,write:bool)->Result<File,()> {
    if !path.is_absolute()||!path.parent().is_some_and(safe_directory){return Err(())}
    #[cfg(windows)] let expected=path.parent().ok_or(())?.canonicalize().map_err(|_|())?.join(path.file_name().ok_or(())?);
    #[cfg(unix)] let file={
        use std::{ffi::CString,os::{fd::{FromRawFd,AsRawFd},unix::ffi::OsStrExt}};
        let root=CString::new("/").unwrap();
        let fd=unsafe{libc::open(root.as_ptr(),libc::O_RDONLY|libc::O_DIRECTORY|libc::O_CLOEXEC)};
        if fd<0{return Err(())}
        let mut directory=unsafe{File::from_raw_fd(fd)};
        let parts:Vec<_>=path.components().filter_map(|c|if let std::path::Component::Normal(p)=c{Some(p)}else{None}).collect();
        for part in parts.iter().take(parts.len().saturating_sub(1)){
            let name=CString::new(part.as_bytes()).map_err(|_|())?;
            let next=unsafe{libc::openat(directory.as_raw_fd(),name.as_ptr(),libc::O_RDONLY|libc::O_DIRECTORY|libc::O_NOFOLLOW|libc::O_CLOEXEC)};
            if next<0{return Err(())}directory=unsafe{File::from_raw_fd(next)};
        }
        let name=CString::new(parts.last().ok_or(())?.as_bytes()).map_err(|_|())?;
        let flags=libc::O_NOFOLLOW|libc::O_NONBLOCK|libc::O_CLOEXEC|if write{libc::O_WRONLY|libc::O_CREAT|libc::O_EXCL}else{libc::O_RDONLY};
        let fd=unsafe{libc::openat(directory.as_raw_fd(),name.as_ptr(),flags,0o600)};
        if fd<0{return Err(())}unsafe{File::from_raw_fd(fd)}
    };
    #[cfg(not(unix))]
    let file={
    let mut options=OpenOptions::new();
    if write {options.write(true).create_new(true);}else{options.read(true);}
    #[cfg(windows)] {use std::os::windows::fs::OpenOptionsExt;options.custom_flags(0x0020_0000);}
    options.open(path).map_err(|_|())?
    };
    let info=file.metadata().map_err(|_|())?;
    if !info.is_file(){return Err(())}
    #[cfg(unix)] {use std::os::unix::fs::MetadataExt;if info.nlink()!=1{return Err(())}}
    #[cfg(windows)] {
        use std::os::windows::{fs::MetadataExt,io::AsRawHandle};
        use windows_sys::Win32::Storage::FileSystem::{GetFileInformationByHandle,GetFinalPathNameByHandleW,BY_HANDLE_FILE_INFORMATION};
        if info.file_attributes()&0x400!=0{return Err(())}
        let mut identity:BY_HANDLE_FILE_INFORMATION=unsafe{std::mem::zeroed()};
        if unsafe{GetFileInformationByHandle(file.as_raw_handle(),&mut identity)}==0||identity.nNumberOfLinks!=1{return Err(())}
        let mut buffer=vec![0u16;32768];
        let count=unsafe{GetFinalPathNameByHandleW(file.as_raw_handle(),buffer.as_mut_ptr(),buffer.len() as u32,0)} as usize;
        if count==0||count>=buffer.len(){return Err(())}
        if String::from_utf16_lossy(&buffer[..count]).to_lowercase()!=expected.to_string_lossy().to_lowercase(){return Err(())}
    }
    Ok(file)
}
pub(super) fn read(path:&Path,limit:u64)->Result<Vec<u8>,()> {
    let file=open(path,false)?;
    if file.metadata().map_err(|_|())?.len()>limit{return Err(())}
    let mut bytes=Vec::new();file.take(limit+1).read_to_end(&mut bytes).map_err(|_|())?;
    if bytes.len() as u64>limit{return Err(())}Ok(bytes)
}
pub(super) fn create(path:&Path,bytes:&[u8])->Result<(),()> {let mut file=open(path,true)?;file.write_all(bytes).map_err(|_|())}
pub(super) fn owned(root:&Path)->Result<(),()> {
    if !root.exists() {
        let mut parent=root.parent().ok_or(())?;
        while !parent.exists(){parent=parent.parent().ok_or(())?;}
        if !safe_directory(parent){return Err(())}
        fs::create_dir_all(root).map_err(|_|())?;
        #[cfg(unix)] {use std::os::unix::fs::PermissionsExt;fs::set_permissions(root,fs::Permissions::from_mode(0o700)).map_err(|_|())?;}
    }
    if !safe_directory(root){return Err(())}
    let marker=root.join("owner.marker");
    if !marker.exists(){create(&marker,b"tokenbar-diagnostics-v1\n")?;}
    if read(&marker,128)?!=b"tokenbar-diagnostics-v1\n"{return Err(())}Ok(())
}
pub(super) fn list(root:&Path)->Result<Vec<std::path::PathBuf>,()> {
    if !safe_directory(root){return Err(())}
    let mut files=Vec::new();
    for entry in fs::read_dir(root).map_err(|_|())?.take(2049){files.push(entry.map_err(|_|())?.path());}
    if files.len()>2048{return Err(())}files.sort();Ok(files)
}
pub(super) fn append(file:&mut File,bytes:&[u8])->Result<(),()> {file.write_all(bytes).map_err(|_|())}
pub(super) fn new_log(path:&Path)->Result<File,()> {open(path,true)}
