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
    let mut options=OpenOptions::new();
    if write {options.write(true).create_new(true);}else{options.read(true);}
    #[cfg(unix)] {use std::os::unix::fs::OpenOptionsExt;options.custom_flags(libc::O_NOFOLLOW|libc::O_NONBLOCK|libc::O_CLOEXEC).mode(0o600);}
    #[cfg(windows)] {use std::os::windows::fs::OpenOptionsExt;options.custom_flags(0x0020_0000);}
    let file=options.open(path).map_err(|_|())?;
    let info=file.metadata().map_err(|_|())?;
    if !info.is_file(){return Err(())}
    #[cfg(unix)] {use std::os::unix::fs::MetadataExt;if info.nlink()!=1{return Err(())}}
    #[cfg(windows)] {
        use std::os::windows::{fs::MetadataExt,io::AsRawHandle};
        use windows_sys::Win32::Storage::FileSystem::{GetFileInformationByHandle,BY_HANDLE_FILE_INFORMATION};
        if info.file_attributes()&0x400!=0{return Err(())}
        let mut identity:BY_HANDLE_FILE_INFORMATION=unsafe{std::mem::zeroed()};
        if unsafe{GetFileInformationByHandle(file.as_raw_handle(),&mut identity)}==0||identity.nNumberOfLinks!=1{return Err(())}
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
