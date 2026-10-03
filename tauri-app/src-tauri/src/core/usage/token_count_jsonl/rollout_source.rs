//! A rollout's logical JSONL identity survives lossless storage conversion.
//! Seeking compressed data is a bounded streaming skip, never a temp file.
use std::fs::{self, File, Metadata};
use std::io::{self, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::collections::HashMap;

pub(super) fn is_rollout(path: &Path) -> bool {
    path.extension().is_some_and(|e| e == "jsonl") || is_compressed(path)
}
pub(super) fn is_compressed(path: &Path) -> bool {
    path.file_name().is_some_and(|n| n.to_string_lossy().ends_with(".jsonl.zst"))
}
pub(super) fn logical_path(path: &Path) -> PathBuf {
    if is_compressed(path) { path.with_extension("") } else { path.to_path_buf() }
}
pub(super) fn physical_path(path: &Path) -> io::Result<PathBuf> {
    let logical = logical_path(path);
    match fs::metadata(&logical) {
        Ok(m) if m.is_file() => Ok(logical),
        Ok(_) => Err(invalid("rollout is not a regular file")),
        Err(e) if e.kind() == io::ErrorKind::NotFound && logical.extension().is_some_and(|x| x == "jsonl") => {
            let mut compressed = logical.as_os_str().to_os_string();
            compressed.push(".zst");
            Ok(PathBuf::from(compressed))
        }
        Err(e) => Err(e),
    }
}
pub(super) fn canonical_logical_path(path: &Path) -> io::Result<PathBuf> {
    Ok(logical_path(&fs::canonicalize(physical_path(path)?)?))
}
pub(super) fn metadata(path: &Path) -> io::Result<Metadata> {fs::metadata(physical_path(path)?)}

fn invalid(message: &str) -> io::Error { io::Error::new(io::ErrorKind::InvalidData, message) }

#[derive(Clone, Copy, Debug)]
pub(super) struct Layout { pub logical_size: Option<u64>, pub single_frame: bool, pub declared_size: bool }

// The cache is only a process-local invalidation hint, not a content proof.
// Include change time/file identity where supported; never use it to add usage.
fn cache_key(path: &Path, file: &File) -> io::Result<String> {
    let m = file.metadata()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Ok(format!("{}:{}:{}:{}:{}:{}:{}:{}",path.display(),m.dev(),m.ino(),m.len(),m.mtime(),m.mtime_nsec(),m.ctime(),m.ctime_nsec()))
    }
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::Storage::FileSystem::{FileBasicInfo, GetFileInformationByHandle, GetFileInformationByHandleEx, BY_HANDLE_FILE_INFORMATION, FILE_BASIC_INFO};
        let mut identity=BY_HANDLE_FILE_INFORMATION::default();
        let mut basic=FILE_BASIC_INFO::default();
        if unsafe { GetFileInformationByHandle(file.as_raw_handle(),&mut identity) } == 0
            || unsafe { GetFileInformationByHandleEx(file.as_raw_handle(),FileBasicInfo,(&mut basic as *mut FILE_BASIC_INFO).cast(),std::mem::size_of::<FILE_BASIC_INFO>() as u32) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(format!("{}:{}:{}:{}:{}:{}:{}:{}",path.display(),m.len(),identity.dwVolumeSerialNumber,identity.nFileIndexHigh,identity.nFileIndexLow,basic.ChangeTime,basic.LastWriteTime,basic.CreationTime))
    }
    #[cfg(not(any(unix, windows)))]
    { Ok(format!("{}:{m:?}",path.display())) }
}

fn read_number(file: &mut File, count: usize) -> io::Result<u64> {
    let mut bytes=[0;8]; file.read_exact(&mut bytes[..count])?; Ok(u64::from_le_bytes(bytes))
}
fn skip(file: &mut File, count: u64, end: u64) -> io::Result<()> {
    let position=file.stream_position()?.checked_add(count).ok_or_else(||invalid("zstd offset overflow"))?;
    if position>end { return Err(invalid("truncated zstd payload")); }
    file.seek(SeekFrom::Start(position))?; Ok(())
}
fn inspect(file: &mut File) -> io::Result<Layout> {
    let end=file.metadata()?.len();
    file.seek(SeekFrom::Start(0))?;
    let mut frames=0u64; let mut blocks=0u64; let mut total=Some(0u64); let mut skippable=false;
    while file.stream_position()?<end {
        let magic=read_number(file,4)?;
        if (0x184d2a50..=0x184d2a5f).contains(&magic) {
            let size=read_number(file,4)?; skip(file,size,end)?; skippable=true; continue;
        }
        if magic!=0xfd2fb528 { return Err(invalid("invalid zstd frame magic or trailing bytes")); }
        let descriptor=read_number(file,1)? as u8;
        if descriptor&0x18!=0 { return Err(invalid("reserved zstd frame bits")); }
        let single=descriptor&0x20!=0;
        if !single { skip(file,1,end)?; }
        skip(file,[0,1,2,4][(descriptor&3) as usize],end)?;
        let size_bytes=[if single {1}else{0},2,4,8][(descriptor>>6) as usize];
        let size=if size_bytes==0 {None} else {
            Some(read_number(file,size_bytes)?.checked_add(if descriptor>>6==1 {256}else{0}).ok_or_else(||invalid("zstd size overflow"))?)
        };
        total=match (total,size) { (Some(a),Some(b))=>Some(a.checked_add(b).ok_or_else(||invalid("zstd logical size overflow"))?), _=>None };
        loop {
            blocks+=1; if blocks>1_000_000 { return Err(invalid("zstd structural work limit exceeded")); }
            let header=read_number(file,3)?;
            let kind=(header>>1)&3; let size=header>>3;
            if kind==3 || size>128*1024 { return Err(invalid("invalid zstd block header")); }
            skip(file,if kind==1 {1}else{size},end)?;
            if header&1!=0 { break; }
        }
        if descriptor&4!=0 { skip(file,4,end)?; }
        frames+=1;
    }
    if frames==0 { return Err(invalid("no zstd data frame")); }
    Ok(Layout {logical_size:total,single_frame:frames==1 && !skippable,declared_size:total.is_some()})
}

type Decoder=zstd::stream::read::Decoder<'static,BufReader<File>>;
fn decoder(file: File) -> io::Result<Decoder> {
    let mut d=zstd::stream::read::Decoder::new(file)?;
    d.window_log_max(27)?; // at most 128 MiB, independently of I/O buffers
    Ok(d)
}
enum Storage { Plain(File), Compressed(Decoder) }
pub(super) struct RolloutReader {
    storage: Option<Storage>,
    physical: PathBuf,
    layout: Layout,
    logical_position: u64,
}
impl RolloutReader {
    pub fn open(path: &Path) -> io::Result<Self> {
        for _ in 0..3 {
            let physical = physical_path(path)?;
            let file = match File::open(&physical) {
                Ok(file) => file,
                Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error),
            };
            if is_compressed(&physical) && logical_path(path).try_exists()? {
                continue;
            }
            return Self::from_file(file, physical);
        }
        Err(io::Error::new(io::ErrorKind::NotFound, "rollout representations changed during open; retry"))
    }
    pub fn from_file(mut file: File, physical: PathBuf) -> io::Result<Self> {
        let before=cache_key(&physical,&file)?;
        let mut layout=Layout { logical_size:Some(file.metadata()?.len()),single_frame:false,declared_size:false };
        let storage=if is_compressed(&physical) {
            static CACHE: OnceLock<Mutex<HashMap<String,Layout>>>=OnceLock::new();
            let cache=CACHE.get_or_init(||Mutex::new(HashMap::new()));
            let cached=cache.lock().map_err(|_|invalid("zstd layout cache poisoned"))?.get(&before).copied();
            layout=if let Some(value)=cached {value} else {
                let value=inspect(&mut file).map_err(|e|io::Error::new(e.kind(),format!("zstd结构检查失败 {}：{e}",physical.display())))?;
                if cache_key(&physical,&file)?!=before { return Err(invalid("rollout changed during frame inspection")); }
                let mut map=cache.lock().map_err(|_|invalid("zstd layout cache poisoned"))?;
                if map.len()>=32768 {map.clear();}
                map.insert(before.clone(),value); value
            };
            file.seek(SeekFrom::Start(0))?;
            let mut d=decoder(file)?;
            if layout.logical_size.is_none() {
                // Unknown-size frames cannot use the metadata reuse lane.
                let mut bytes=[0;128*1024]; let mut size=0u64;
                loop { let n=d.read(&mut bytes).map_err(|e|io::Error::new(e.kind(),format!("zstd长度核对失败 {}：{e}",physical.display())))?; if n==0 {break;}
                    size=size.checked_add(n as u64).ok_or_else(||invalid("rollout logical size overflow"))?;
                }
                layout.logical_size=Some(size);
                if cache_key(&physical,d.get_ref().get_ref())?!=before {return Err(invalid("rollout changed during size validation"));}
                cache.lock().map_err(|_|invalid("zstd layout cache poisoned"))?.insert(before.clone(),layout);
                let mut file=d.finish().into_inner(); file.seek(SeekFrom::Start(0))?; d=decoder(file)?;
            }
            Storage::Compressed(d)
        } else {Storage::Plain(file)};
        Ok(Self {storage:Some(storage),physical,layout,logical_position:0})
    }
    pub fn raw(&self) -> &File {
        match self.storage.as_ref().expect("reader storage") {
            Storage::Plain(f)=>f,Storage::Compressed(d)=>d.get_ref().get_ref()
        }
    }
    pub fn metadata(&self) -> io::Result<Metadata> {self.raw().metadata()}
    pub fn logical_size(&self) -> u64 {self.layout.logical_size.expect("opened logical size")}
    pub fn physical_path(&self) -> &Path {&self.physical}
    pub fn compressed(&self) -> bool {matches!(self.storage,Some(Storage::Compressed(_)))}
    pub fn fast_reuse_supported(&self) -> bool {self.compressed() && self.layout.single_frame && self.layout.declared_size}
    pub fn verify_end(&mut self, size: u64) -> io::Result<()> {
        if !self.compressed() {return Ok(());}
        self.seek(SeekFrom::Start(size))?;
        let mut byte=[0;1];
        if self.read(&mut byte)?!=0 {return Err(invalid("zstd decoded length differs from declared length"));}
        Ok(())
    }
}
impl Read for RolloutReader {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        let n=match self.storage.as_mut().expect("reader storage") {Storage::Plain(f)=>f.read(bytes)?,Storage::Compressed(d)=>d.read(bytes).map_err(|e|io::Error::new(e.kind(),format!("zstd解码失败 {}：{e}",self.physical.display())))?};
        self.logical_position=self.logical_position.checked_add(n as u64).ok_or_else(||invalid("rollout offset overflow"))?;
        Ok(n)
    }
}
impl Seek for RolloutReader {
    fn seek(&mut self, offset: SeekFrom) -> io::Result<u64> {
        if let Some(Storage::Plain(file))=self.storage.as_mut() {
            self.logical_position=file.seek(offset)?; return Ok(self.logical_position);
        }
        let target=match offset {
            SeekFrom::Start(n)=>Some(n),
            SeekFrom::Current(n)=>self.logical_position.checked_add_signed(n),
            SeekFrom::End(n)=>self.logical_size().checked_add_signed(n),
        };
        // Normalize Start separately to keep checked arithmetic for signed seeks.
        let target=match offset {SeekFrom::Start(n)=>Some(n),_=>target};
        let target=target.ok_or_else(||invalid("invalid logical seek"))?;
        if target<self.logical_position {
            let Some(Storage::Compressed(d))=self.storage.take() else {unreachable!()};
            let mut file=d.finish().into_inner(); file.seek(SeekFrom::Start(0))?;
            self.storage=Some(Storage::Compressed(decoder(file)?)); self.logical_position=0;
        }
        let mut buffer=[0;64*1024];
        while self.logical_position<target {
            let want=(target-self.logical_position).min(buffer.len() as u64) as usize;
            if self.read(&mut buffer[..want])?==0 {return Err(invalid("logical seek exceeds decoded rollout"));}
        }
        Ok(target)
    }
}

pub(super) trait SourceHandle: Read + Seek {
    fn raw_file(&self) -> &File;
    fn logical_length(&self) -> io::Result<u64>;
    fn validate_decoded_end(&mut self, _size: u64) -> io::Result<()> {Ok(())}
}
impl SourceHandle for File {
    fn raw_file(&self) -> &File {self}
    fn logical_length(&self) -> io::Result<u64> {Ok(self.metadata()?.len())}
}
impl SourceHandle for RolloutReader {
    fn raw_file(&self) -> &File {self.raw()}
    fn logical_length(&self) -> io::Result<u64> {Ok(self.logical_size())}
    fn validate_decoded_end(&mut self, size: u64) -> io::Result<()> {self.verify_end(size)}
}
