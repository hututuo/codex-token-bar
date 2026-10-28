//! Bounded positioned reads shared by consumers that already hold a validated file handle.
//! It never resolves a path or owns consumer checkpoints.

use std::collections::{HashMap, VecDeque};
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::sync::Arc;
use std::sync::{Mutex, OnceLock};

const BLOCK_BYTES: usize = 64 * 1024;
const MAX_READ_BYTES: usize = 4 * 1024 * 1024;
const MAX_CACHE_BYTES: usize = 64 * 1024 * 1024;
const MAX_OWNERS: usize = 256;

#[cfg(unix)]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct FileIdentity {
    device: u64,
    inode: u64,
}

#[cfg(windows)]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct FileIdentity {
    volume: u64,
    file_id: [u8; 16],
}

#[cfg(not(any(unix, windows)))]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct FileIdentity {
    unsupported: u8,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct FileStamp {
    identity: FileIdentity,
    len: u64,
    modified: i128,
    changed: i128,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct BlockKey {
    identity: FileIdentity,
    index: u64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct BrokerSnapshotStats {
    pub(crate) physical_reads: u64,
    pub(crate) cache_hits: u64,
    pub(crate) cached_bytes: usize,
    pub(crate) cached_blocks: usize,
    pub(crate) owners: usize,
}

#[derive(Default)]
struct State {
    owners: HashMap<FileIdentity, FileStamp>,
    owner_lru: VecDeque<FileIdentity>,
    blocks: HashMap<BlockKey, Arc<[u8]>>,
    block_lru: VecDeque<BlockKey>,
    cached_bytes: usize,
    physical_reads: u64,
    cache_hits: u64,
}

pub(crate) struct SourceReadBroker {
    state: Mutex<State>,
}

impl SourceReadBroker {
    pub(crate) fn new() -> Self {
        Self {
            state: Mutex::new(State::default()),
        }
    }

    pub(crate) fn read_range(&self, file: &File, offset: u64, max: usize) -> io::Result<Vec<u8>> {
        self.read(file, offset, max, true)
    }

    pub(crate) fn probe_uncached(
        &self,
        file: &File,
        offset: u64,
        max: usize,
    ) -> io::Result<Vec<u8>> {
        self.read(file, offset, max, false)
    }

    pub(crate) fn snapshot_stats(&self) -> BrokerSnapshotStats {
        let state = self.lock();
        BrokerSnapshotStats {
            physical_reads: state.physical_reads,
            cache_hits: state.cache_hits,
            cached_bytes: state.cached_bytes,
            cached_blocks: state.blocks.len(),
            owners: state.owners.len(),
        }
    }

    fn read(&self, file: &File, offset: u64, max: usize, cached: bool) -> io::Result<Vec<u8>> {
        if max == 0 {
            return Ok(Vec::new());
        }
        let before = file_stamp(file)?;
        let mut state = self.lock();
        let current = match file_stamp(file) {
            Ok(stamp) => stamp,
            Err(error) => {
                state.remove_owner(before.identity);
                return Err(error);
            }
        };
        if current != before {
            if current.identity != before.identity {
                state.remove_owner(before.identity);
            }
            state.ensure_owner(current);
            return Err(changed_during_read());
        }
        state.ensure_owner(before);
        let read = if cached {
            Self::read_cached(&mut state, file, before, offset, max.min(MAX_READ_BYTES))
        } else {
            let direct_max = max.min(MAX_READ_BYTES);
            if requested_len(before.len, offset, direct_max) > 0 {
                state.physical_reads = state.physical_reads.saturating_add(1);
            }
            read_at_range(file, offset, before.len, direct_max)
        };
        match file_stamp(file) {
            Ok(after) if after == before => match read {
                Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
                    state.remove_owner(before.identity);
                    Err(changed_during_read())
                }
                result => result,
            },
            Ok(after) => {
                if after.identity != before.identity {
                    state.remove_owner(before.identity);
                }
                state.ensure_owner(after);
                Err(changed_during_read())
            }
            Err(error) => {
                state.remove_owner(before.identity);
                Err(error)
            }
        }
    }

    fn read_cached(
        state: &mut State,
        file: &File,
        stamp: FileStamp,
        offset: u64,
        max: usize,
    ) -> io::Result<Vec<u8>> {
        let length = requested_len(stamp.len, offset, max);
        if length == 0 {
            return Ok(Vec::new());
        }
        let end = offset + length as u64;
        let mut cursor = offset;
        let mut output = Vec::with_capacity(length);
        while cursor < end {
            let block_start = cursor / BLOCK_BYTES as u64 * BLOCK_BYTES as u64;
            let key = BlockKey {
                identity: stamp.identity,
                index: block_start / BLOCK_BYTES as u64,
            };
            let block = if let Some(block) = state.blocks.get(&key).cloned() {
                state.cache_hits = state.cache_hits.saturating_add(1);
                state.touch_block(key);
                block
            } else {
                let block_len = (stamp.len - block_start).min(BLOCK_BYTES as u64) as usize;
                state.physical_reads = state.physical_reads.saturating_add(1);
                let block: Arc<[u8]> = read_exact_at(file, block_start, block_len)?.into();
                state.insert_block(key, block.clone());
                block
            };
            let within = (cursor - block_start) as usize;
            let take = (block.len() - within).min((end - cursor) as usize);
            if take == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "short source block",
                ));
            }
            output.extend_from_slice(&block[within..within + take]);
            cursor += take as u64;
        }
        Ok(output)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

impl State {
    fn ensure_owner(&mut self, stamp: FileStamp) {
        let identity = stamp.identity;
        if self.owners.get(&identity).is_some_and(|old| *old != stamp) {
            self.remove_owner_blocks(identity);
        }
        self.owners.insert(identity, stamp);
        self.touch_owner(identity);
        while self.owners.len() > MAX_OWNERS {
            if let Some(evicted) = self.owner_lru.pop_front() {
                self.remove_owner(evicted);
            }
        }
    }

    fn touch_owner(&mut self, identity: FileIdentity) {
        self.owner_lru.retain(|candidate| *candidate != identity);
        self.owner_lru.push_back(identity);
    }

    fn touch_block(&mut self, key: BlockKey) {
        self.block_lru.retain(|candidate| *candidate != key);
        self.block_lru.push_back(key);
    }

    fn insert_block(&mut self, key: BlockKey, block: Arc<[u8]>) {
        while self.cached_bytes + block.len() > MAX_CACHE_BYTES {
            let Some(oldest) = self.block_lru.pop_front() else {
                break;
            };
            self.remove_block(oldest);
        }
        self.cached_bytes += block.len();
        self.blocks.insert(key, block);
        self.touch_block(key);
    }

    fn remove_block(&mut self, key: BlockKey) {
        if let Some(block) = self.blocks.remove(&key) {
            self.cached_bytes = self.cached_bytes.saturating_sub(block.len());
        }
        self.block_lru.retain(|candidate| *candidate != key);
    }

    fn remove_owner_blocks(&mut self, identity: FileIdentity) {
        let keys: Vec<_> = self
            .blocks
            .keys()
            .filter(|key| key.identity == identity)
            .copied()
            .collect();
        for key in keys {
            self.remove_block(key);
        }
    }

    fn remove_owner(&mut self, identity: FileIdentity) {
        self.owners.remove(&identity);
        self.owner_lru.retain(|candidate| *candidate != identity);
        self.remove_owner_blocks(identity);
    }
}

static BROKER: OnceLock<SourceReadBroker> = OnceLock::new();

fn global_broker() -> &'static SourceReadBroker {
    BROKER.get_or_init(SourceReadBroker::new)
}

/// Reads up to 4 MiB from the supplied handle without moving its cursor; data is cached in 64 KiB blocks.
pub(crate) fn read_range(file: &File, offset: u64, max: usize) -> io::Result<Vec<u8>> {
    global_broker().read_range(file, offset, max)
}

/// Reads up to 4 MiB directly from the supplied handle, bypassing and not populating the cache.
pub(crate) fn probe_uncached(file: &File, offset: u64, max: usize) -> io::Result<Vec<u8>> {
    global_broker().probe_uncached(file, offset, max)
}

pub(crate) fn snapshot_stats() -> BrokerSnapshotStats {
    global_broker().snapshot_stats()
}

/// Optional `Read + Seek` facade with a cursor owned by this consumer, not by the shared handle.
pub(crate) struct SourceReader {
    file: File,
    position: u64,
}

impl SourceReader {
    pub(crate) fn new(file: &File) -> io::Result<Self> {
        Ok(Self {
            file: file.try_clone()?,
            position: 0,
        })
    }
}

impl Read for SourceReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        let bytes = read_range(&self.file, self.position, buffer.len())?;
        buffer[..bytes.len()].copy_from_slice(&bytes);
        self.position += bytes.len() as u64;
        Ok(bytes.len())
    }
}

impl Seek for SourceReader {
    fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
        let target = match position {
            SeekFrom::Start(offset) => i128::from(offset),
            SeekFrom::Current(delta) => i128::from(self.position) + i128::from(delta),
            SeekFrom::End(delta) => i128::from(self.file.metadata()?.len()) + i128::from(delta),
        };
        if !(0..=i128::from(u64::MAX)).contains(&target) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "seek before start or beyond u64",
            ));
        }
        self.position = target as u64;
        Ok(self.position)
    }
}

fn requested_len(file_len: u64, offset: u64, max: usize) -> usize {
    if offset >= file_len {
        0
    } else {
        (file_len - offset).min(max as u64) as usize
    }
}

fn read_at_range(file: &File, offset: u64, file_len: u64, max: usize) -> io::Result<Vec<u8>> {
    let length = requested_len(file_len, offset, max);
    if length == 0 {
        return Ok(Vec::new());
    }
    read_exact_at(file, offset, length)
}

fn read_exact_at(file: &File, offset: u64, length: usize) -> io::Result<Vec<u8>> {
    let mut bytes = vec![0; length];
    let mut done = 0;
    while done < length {
        let count = match positioned_read(file, &mut bytes[done..], offset + done as u64) {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            result => result?,
        };
        if count == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "source shortened during positioned read",
            ));
        }
        done += count;
    }
    Ok(bytes)
}

#[cfg(unix)]
fn positioned_read(file: &File, buffer: &mut [u8], offset: u64) -> io::Result<usize> {
    use std::os::unix::fs::FileExt;
    file.read_at(buffer, offset)
}

#[cfg(windows)]
fn positioned_read(file: &File, buffer: &mut [u8], offset: u64) -> io::Result<usize> {
    use std::os::windows::fs::FileExt;
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{SetFilePointerEx, FILE_BEGIN, FILE_CURRENT};

    // Windows seek_read moves the shared handle cursor; broker reads are
    // serialized, so save and restore it to keep consumer positions isolated.
    let handle = file.as_raw_handle() as _;
    let mut original_position = 0_i64;
    if unsafe { SetFilePointerEx(handle, 0, &mut original_position, FILE_CURRENT) } == 0 {
        return Err(io::Error::last_os_error());
    }

    let read_result = file.seek_read(buffer, offset);
    let restore_succeeded =
        unsafe { SetFilePointerEx(handle, original_position, std::ptr::null_mut(), FILE_BEGIN) }
            != 0;
    if !restore_succeeded {
        return Err(io::Error::last_os_error());
    }
    read_result
}

#[cfg(not(any(unix, windows)))]
fn positioned_read(_file: &File, _buffer: &mut [u8], _offset: u64) -> io::Result<usize> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "positioned file reads are unsupported",
    ))
}

#[cfg(unix)]
fn file_stamp(file: &File) -> io::Result<FileStamp> {
    use std::os::unix::fs::MetadataExt;
    let metadata = file.metadata()?;
    let stamp = FileStamp {
        identity: FileIdentity {
            device: metadata.dev(),
            inode: metadata.ino(),
        },
        len: metadata.len(),
        modified: i128::from(metadata.mtime())
            .saturating_mul(1_000_000_000)
            .saturating_add(i128::from(metadata.mtime_nsec())),
        changed: i128::from(metadata.ctime())
            .saturating_mul(1_000_000_000)
            .saturating_add(i128::from(metadata.ctime_nsec())),
    };
    Ok(stamp)
}

#[cfg(windows)]
fn file_stamp(file: &File) -> io::Result<FileStamp> {
    use std::mem::MaybeUninit;
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        FileBasicInfo, FileIdInfo, GetFileInformationByHandleEx, FILE_BASIC_INFO, FILE_ID_INFO,
    };
    let handle = file.as_raw_handle() as _;
    let mut id = FILE_ID_INFO::default();
    let mut basic = MaybeUninit::<FILE_BASIC_INFO>::zeroed();
    let id_ok = unsafe {
        GetFileInformationByHandleEx(
            handle,
            FileIdInfo,
            (&mut id as *mut FILE_ID_INFO).cast(),
            std::mem::size_of::<FILE_ID_INFO>() as u32,
        )
    };
    if id_ok == 0 {
        return Err(io::Error::last_os_error());
    }
    let basic_ok = unsafe {
        GetFileInformationByHandleEx(
            handle,
            FileBasicInfo,
            basic.as_mut_ptr().cast(),
            std::mem::size_of::<FILE_BASIC_INFO>() as u32,
        )
    };
    if basic_ok == 0 {
        return Err(io::Error::last_os_error());
    }
    let basic = unsafe { basic.assume_init() };
    Ok(FileStamp {
        identity: FileIdentity {
            volume: id.VolumeSerialNumber,
            file_id: id.FileId.Identifier,
        },
        len: file.metadata()?.len(),
        modified: i128::from(basic.LastWriteTime).saturating_mul(100),
        changed: i128::from(basic.ChangeTime).saturating_mul(100),
    })
}

#[cfg(not(any(unix, windows)))]
fn file_stamp(_file: &File) -> io::Result<FileStamp> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "stable file identity is unsupported",
    ))
}

fn changed_during_read() -> io::Error {
    io::Error::new(
        io::ErrorKind::Interrupted,
        "source changed during positioned read; retry with a fresh snapshot",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, OpenOptions};
    use std::io::Write;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{Duration, SystemTime};

    static NEXT_DIR: AtomicU64 = AtomicU64::new(0);

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> io::Result<Self> {
            let id = NEXT_DIR.fetch_add(1, Ordering::Relaxed);
            let path =
                std::env::temp_dir().join(format!("shared-source-io-{}-{id}", std::process::id()));
            fs::create_dir_all(&path)?;
            Ok(Self(path))
        }

        fn path(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }

        fn write(&self, name: &str, bytes: &[u8]) -> io::Result<PathBuf> {
            let path = self.path(name);
            fs::write(&path, bytes)?;
            Ok(path)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn consumers_share_blocks_without_sharing_seek_positions() -> io::Result<()> {
        let fixture = Fixture::new()?;
        let path = fixture.write("source", &(0..=255).collect::<Vec<u8>>())?;
        let mut file = File::open(path)?;
        let broker = SourceReadBroker::new();
        assert_eq!(
            broker.read_range(&file, 0, 13)?,
            (0..13).collect::<Vec<u8>>()
        );
        assert_eq!(file.stream_position()?, 0);
        assert_eq!(
            broker.read_range(&file, 0, 128)?,
            (0..128).collect::<Vec<u8>>()
        );
        let stats = broker.snapshot_stats();
        assert_eq!(stats.physical_reads, 1);
        assert_eq!(stats.cache_hits, 1);

        let mut first = SourceReader::new(&file)?;
        let mut second = SourceReader::new(&file)?;
        assert_eq!(first.seek(SeekFrom::Start(5))?, 5);
        assert_eq!(second.seek(SeekFrom::Start(40))?, 40);
        let mut a = [0; 3];
        let mut b = [0; 4];
        first.read_exact(&mut a)?;
        second.read_exact(&mut b)?;
        assert_eq!(a, [5, 6, 7]);
        assert_eq!(b, [40, 41, 42, 43]);
        assert_eq!(first.stream_position()?, 8);
        assert_eq!(second.stream_position()?, 44);
        Ok(())
    }

    #[test]
    fn positioned_reads_preserve_a_nonzero_file_cursor() -> io::Result<()> {
        let fixture = Fixture::new()?;
        let bytes: Vec<u8> = (0..=255).collect();
        let path = fixture.write("source", &bytes)?;
        let mut file = File::open(path)?;
        let broker = SourceReadBroker::new();
        file.seek(SeekFrom::Start(17))?;

        assert_eq!(broker.read_range(&file, 23, 13)?, bytes[23..36].to_vec());
        assert_eq!(file.stream_position()?, 17);
        Ok(())
    }

    #[test]
    fn overlapping_cross_block_ranges_reuse_each_physical_block() -> io::Result<()> {
        let fixture = Fixture::new()?;
        let data: Vec<u8> = (0..BLOCK_BYTES * 3)
            .map(|index| (index % 251) as u8)
            .collect();
        let path = fixture.write("source", &data)?;
        let file = File::open(path)?;
        let broker = SourceReadBroker::new();
        let first_offset = BLOCK_BYTES as u64 - 32;
        let first_len = BLOCK_BYTES + 128;
        let first = broker.read_range(&file, first_offset, first_len)?;
        assert_eq!(
            first,
            data[first_offset as usize..first_offset as usize + first_len]
        );
        let second_offset = BLOCK_BYTES as u64 - 16;
        let second_len = BLOCK_BYTES + 64;
        let second = broker.read_range(&file, second_offset, second_len)?;
        assert_eq!(
            second,
            data[second_offset as usize..second_offset as usize + second_len]
        );
        let stats = broker.snapshot_stats();
        assert_eq!(stats.physical_reads, 3);
        assert_eq!(stats.cache_hits, 3);
        Ok(())
    }

    #[cfg(any(unix, windows))]
    #[test]
    fn hard_links_share_physical_identity() -> io::Result<()> {
        let fixture = Fixture::new()?;
        let first_path = fixture.write("first", b"same physical file")?;
        let second_path = fixture.path("second");
        fs::hard_link(&first_path, &second_path)?;
        let first = File::open(first_path)?;
        let second = File::open(second_path)?;
        let broker = SourceReadBroker::new();
        assert_eq!(broker.read_range(&first, 0, 5)?, b"same ");
        assert_eq!(broker.read_range(&second, 0, 15)?, b"same physical f");
        assert_eq!(broker.snapshot_stats().physical_reads, 1);
        assert_eq!(broker.snapshot_stats().cache_hits, 1);
        Ok(())
    }

    #[test]
    fn same_length_rewrite_with_new_timestamp_invalidates_cache() -> io::Result<()> {
        let fixture = Fixture::new()?;
        let path = fixture.write("source", b"old-bytes")?;
        let mut file = OpenOptions::new().read(true).write(true).open(path)?;
        let broker = SourceReadBroker::new();
        assert_eq!(broker.read_range(&file, 0, 9)?, b"old-bytes");
        file.seek(SeekFrom::Start(0))?;
        (&file).write_all(b"new-bytes")?;
        file.set_times(
            std::fs::FileTimes::new().set_modified(SystemTime::now() + Duration::from_secs(5)),
        )?;
        assert_eq!(broker.read_range(&file, 0, 9)?, b"new-bytes");
        assert_eq!(broker.snapshot_stats().physical_reads, 2);
        Ok(())
    }

    #[test]
    fn append_and_truncate_invalidate_cached_version() -> io::Result<()> {
        let fixture = Fixture::new()?;
        let path = fixture.write("source", b"abc")?;
        let mut file = OpenOptions::new().read(true).write(true).open(path)?;
        let broker = SourceReadBroker::new();
        assert_eq!(broker.read_range(&file, 0, 8)?, b"abc");
        file.seek(SeekFrom::End(0))?;
        (&file).write_all(b"def")?;
        assert_eq!(broker.read_range(&file, 3, 3)?, b"def");
        file.set_len(2)?;
        assert_eq!(broker.read_range(&file, 0, 8)?, b"ab");
        assert_eq!(broker.snapshot_stats().physical_reads, 3);
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn atomic_replace_uses_the_new_handle_identity() -> io::Result<()> {
        let fixture = Fixture::new()?;
        let path = fixture.write("source", b"old-data")?;
        let old = File::open(&path)?;
        let broker = SourceReadBroker::new();
        assert_eq!(broker.read_range(&old, 0, 8)?, b"old-data");
        let replacement = fixture.write("replacement", b"new-data")?;
        fs::rename(replacement, &path)?;
        let new = File::open(path)?;
        assert_eq!(broker.read_range(&new, 0, 8)?, b"new-data");
        assert_eq!(broker.snapshot_stats().physical_reads, 2);
        Ok(())
    }

    #[test]
    fn eof_partial_reads_and_uncached_probes_are_bounded() -> io::Result<()> {
        let fixture = Fixture::new()?;
        let path = fixture.write("source", b"abc")?;
        let file = File::open(path)?;
        let broker = SourceReadBroker::new();
        assert_eq!(broker.read_range(&file, 1, 64)?, b"bc");
        assert!(broker.read_range(&file, 3, 64)?.is_empty());
        let stats = broker.snapshot_stats();
        assert_eq!(stats.physical_reads, 1);
        assert_eq!(stats.cache_hits, 0);
        assert_eq!(broker.probe_uncached(&file, 1, 64)?, b"bc");
        let after = broker.snapshot_stats();
        assert_eq!(after.physical_reads, 2);
        assert_eq!(after.cache_hits, 0);
        assert_eq!(after.cached_bytes, 3);
        Ok(())
    }

    #[test]
    fn block_lru_is_bounded_and_eviction_never_changes_source_files() -> io::Result<()> {
        let fixture = Fixture::new()?;
        let path = fixture.path("sparse");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)?;
        file.set_len((MAX_CACHE_BYTES + BLOCK_BYTES) as u64)?;
        let broker = SourceReadBroker::new();
        for index in 0..=(MAX_CACHE_BYTES / BLOCK_BYTES) {
            broker.read_range(&file, (index * BLOCK_BYTES) as u64, 1)?;
        }
        let full = broker.snapshot_stats();
        assert_eq!(
            full.physical_reads,
            (MAX_CACHE_BYTES / BLOCK_BYTES + 1) as u64
        );
        assert!(full.cached_bytes <= MAX_CACHE_BYTES);
        broker.read_range(&file, 0, 1)?;
        let after = broker.snapshot_stats();
        assert_eq!(after.physical_reads, full.physical_reads + 1);
        assert_eq!(
            fs::metadata(path)?.len(),
            (MAX_CACHE_BYTES + BLOCK_BYTES) as u64
        );
        Ok(())
    }

    #[test]
    fn large_request_is_capped_at_four_megabytes() -> io::Result<()> {
        let fixture = Fixture::new()?;
        let path = fixture.path("sparse");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)?;
        file.set_len((MAX_READ_BYTES * 2) as u64)?;
        let broker = SourceReadBroker::new();
        let bytes = broker.read_range(&file, 0, usize::MAX)?;
        assert_eq!(bytes.len(), MAX_READ_BYTES);
        assert!(bytes.iter().all(|byte| *byte == 0));
        assert_eq!(
            broker.snapshot_stats().cached_blocks,
            MAX_READ_BYTES / BLOCK_BYTES
        );
        Ok(())
    }

    #[test]
    fn owner_lru_is_bounded_to_256_files() -> io::Result<()> {
        let fixture = Fixture::new()?;
        let mut files = Vec::new();
        for index in 0..=MAX_OWNERS {
            let path = fixture.write(&format!("file-{index}"), &[index as u8])?;
            files.push(File::open(path)?);
        }
        let broker = SourceReadBroker::new();
        for file in &files {
            broker.read_range(file, 0, 1)?;
        }
        let before = broker.snapshot_stats();
        assert_eq!(before.owners, MAX_OWNERS);
        assert_eq!(before.cached_blocks, MAX_OWNERS);
        broker.read_range(&files[0], 0, 1)?;
        let after = broker.snapshot_stats();
        assert_eq!(after.physical_reads, before.physical_reads + 1);
        assert_eq!(after.owners, MAX_OWNERS);
        assert_eq!(fs::read(fixture.path("file-0"))?, [0]);
        Ok(())
    }
}
