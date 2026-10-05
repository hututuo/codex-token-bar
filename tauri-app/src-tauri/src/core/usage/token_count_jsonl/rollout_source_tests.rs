use super::rollout_source::{self, RolloutReader};
use std::fs::{self, File, FileTimes};
use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, UNIX_EPOCH};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct FixtureDir(PathBuf);

impl FixtureDir {
    fn new() -> Self {
        let id = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "codex-rollout-source-test-{}-{id}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn write(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let path = self.0.join(name);
        fs::write(&path, bytes).unwrap();
        path
    }
}

impl Drop for FixtureDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn raw_frame(payload: &[u8], single_segment: bool) -> Vec<u8> {
    assert!(payload.len() < 256, "fixture uses one-byte content size");
    let mut frame = vec![0x28, 0xB5, 0x2F, 0xFD];
    if single_segment {
        frame.push(0x20); // single-segment frame with one-byte content size
        frame.push(payload.len() as u8);
    } else {
        frame.push(0x00); // no content-size field
        frame.push(0x00); // window descriptor
    }
    let block_header = ((payload.len() as u32) << 3) | 1; // last raw block
    frame.push((block_header & 0xff) as u8);
    frame.push(((block_header >> 8) & 0xff) as u8);
    frame.push(((block_header >> 16) & 0xff) as u8);
    frame.extend_from_slice(payload);
    frame
}

fn read_all(reader: &mut RolloutReader) -> Vec<u8> {
    let mut bytes = Vec::new();
    reader.read_to_end(&mut bytes).unwrap();
    bytes
}

#[test]
fn plain_jsonl_is_read_and_preferred_over_compressed_sibling() {
    let fixture = FixtureDir::new();
    let logical = fixture.write("rollout.jsonl", b"plain source\n");
    let compressed = fixture.write(
        "rollout.jsonl.zst",
        &raw_frame(b"compressed source\n", true),
    );

    assert!(rollout_source::is_rollout(&logical));
    assert!(rollout_source::is_rollout(&compressed));
    assert_eq!(rollout_source::logical_path(&compressed), logical);
    assert_eq!(rollout_source::physical_path(&compressed).unwrap(), logical);
    assert_eq!(
        rollout_source::canonical_logical_path(&compressed).unwrap(),
        fs::canonicalize(&logical).unwrap()
    );
    rollout_source::reset_work_counters_for_current_thread();
    assert_eq!(RolloutReader::cached_logical_length(&compressed).unwrap(), Some(b"plain source\n".len() as u64));
    let counters = rollout_source::work_counters_for_current_thread();
    assert_eq!(counters.open, 1);
    assert_eq!(counters.decoded_bytes, 0);
    assert_eq!(counters.structure_blocks, 0);

    let mut reader = RolloutReader::open(&compressed).unwrap();
    assert!(!reader.compressed());
    assert_eq!(reader.physical_path(), logical);
    assert_eq!(read_all(&mut reader), b"plain source\n");
}

#[test]
fn unknown_size_cache_miss_does_not_inspect_or_decode() {
    let fixture = FixtureDir::new();
    let payload = b"{\"unknown\":true}\n";
    let path = fixture.write("cold-unknown.jsonl.zst", &raw_frame(payload, false));

    rollout_source::reset_work_counters_for_current_thread();
    assert_eq!(RolloutReader::cached_logical_length(&path).unwrap(), None);
    let counters = rollout_source::work_counters_for_current_thread();
    assert_eq!(counters.open, 1);
    assert_eq!(counters.decoded_bytes, 0);
    assert_eq!(counters.structure_blocks, 0);
}

#[test]
fn cached_compressed_size_is_metadata_only() {
    let fixture = FixtureDir::new();
    let payload = b"known size\n";
    let path = fixture.write("cached-known.jsonl.zst", &raw_frame(payload, true));
    let reader = RolloutReader::open(&path).unwrap();
    assert_eq!(reader.logical_size(), payload.len() as u64);
    drop(reader);

    rollout_source::reset_work_counters_for_current_thread();
    assert_eq!(RolloutReader::cached_logical_length(&path).unwrap(), Some(payload.len() as u64));
    let counters = rollout_source::work_counters_for_current_thread();
    assert_eq!(counters.open, 1);
    assert_eq!(counters.decoded_bytes, 0);
    assert_eq!(counters.structure_blocks, 0);
}

#[test]
fn unsafe_plain_entry_does_not_fall_back_to_compressed_sibling() {
    let fixture = FixtureDir::new();
    let plain = fixture.0.join("unsafe.jsonl");
    fs::create_dir(&plain).unwrap();
    fixture.write("unsafe.jsonl.zst", &raw_frame(b"compressed\n", true));

    rollout_source::reset_work_counters_for_current_thread();
    assert!(RolloutReader::cached_logical_length(&plain).is_err());
    let counters = rollout_source::work_counters_for_current_thread();
    assert_eq!(counters.open, 0);
    assert_eq!(counters.decoded_bytes, 0);
    assert_eq!(counters.structure_blocks, 0);
}

#[cfg(unix)]
#[test]
fn dangling_entries_are_unreadable_not_deleted_and_never_fall_back() {
    let fixture = FixtureDir::new();
    let plain = fixture.0.join("dangling.jsonl");
    let compressed = fixture.write("dangling.jsonl.zst", &raw_frame(b"cold\n", true));
    std::os::unix::fs::symlink(fixture.0.join("absent.jsonl"), &plain).unwrap();
    for path in [&plain, &compressed] {
        assert_eq!(rollout_source::physical_path(path).unwrap_err().kind(), std::io::ErrorKind::InvalidData);
        assert_eq!(RolloutReader::cached_logical_length(path).unwrap_err().kind(), std::io::ErrorKind::InvalidData);
        assert_eq!(RolloutReader::open(path).err().unwrap().kind(), std::io::ErrorKind::InvalidData);
    }
    fs::remove_file(&plain).unwrap();
    fs::remove_file(&compressed).unwrap();
    std::os::unix::fs::symlink(fixture.0.join("absent.zst"), &compressed).unwrap();
    assert_eq!(rollout_source::physical_path(&plain).unwrap_err().kind(), std::io::ErrorKind::InvalidData);
    fs::remove_file(&compressed).unwrap();
    assert_eq!(rollout_source::physical_path(&plain).unwrap_err().kind(), std::io::ErrorKind::NotFound);
}

#[test]
fn known_size_frame_streams_seeks_and_validates_decoded_end() {
    let fixture = FixtureDir::new();
    let payload = b"{}\n{\"x\":1}\n";
    let path = fixture.write("known.jsonl.zst", &raw_frame(payload, true));
    let mut reader = RolloutReader::open(&path).unwrap();

    assert!(reader.compressed());
    assert_eq!(reader.logical_size(), payload.len() as u64);
    assert!(reader.fast_reuse_supported());
    let mut prefix = [0; 6];
    reader.read_exact(&mut prefix).unwrap();
    assert_eq!(&prefix, &payload[..6]);
    assert_eq!(reader.seek(SeekFrom::Start(2)).unwrap(), 2);
    let mut sought = [0; 5];
    reader.read_exact(&mut sought).unwrap();
    assert_eq!(&sought, &payload[2..7]);
    reader.seek(SeekFrom::Start(0)).unwrap();
    assert_eq!(read_all(&mut reader), payload);
    reader.verify_end(payload.len() as u64).unwrap();
}

#[test]
fn unknown_size_frame_measures_logical_length_and_rewinds() {
    let fixture = FixtureDir::new();
    let payload = b"{\"unknown\":true}\n";
    let path = fixture.write("unknown.jsonl.zst", &raw_frame(payload, false));
    let mut reader = RolloutReader::open(&path).unwrap();

    assert!(reader.compressed());
    assert_eq!(reader.logical_size(), payload.len() as u64);
    assert!(!reader.fast_reuse_supported());
    let mut prefix = [0; 4];
    reader.read_exact(&mut prefix).unwrap();
    assert_eq!(&prefix, &payload[..4]);
    reader.seek(SeekFrom::Start(0)).unwrap();
    assert_eq!(read_all(&mut reader), payload);
}

#[test]
fn concatenated_frames_sum_sizes_and_seek_across_boundary() {
    let fixture = FixtureDir::new();
    let first = b"{\"a\":1}\n";
    let second = b"{\"b\":2}\n";
    let mut bytes = raw_frame(first, true);
    bytes.extend(raw_frame(second, true));
    let path = fixture.write("multi.jsonl.zst", &bytes);
    let mut reader = RolloutReader::open(&path).unwrap();

    let expected = [first.as_slice(), second.as_slice()].concat();
    assert_eq!(reader.logical_size(), expected.len() as u64);
    assert!(!reader.fast_reuse_supported());
    assert_eq!(read_all(&mut reader), expected);
    reader.seek(SeekFrom::Start((first.len() + 1) as u64)).unwrap();
    let mut across = [0; 4];
    reader.read_exact(&mut across).unwrap();
    assert_eq!(&across, &expected[first.len() + 1..first.len() + 5]);
}

#[test]
fn truncated_raw_block_is_rejected() {
    let fixture = FixtureDir::new();
    let mut bytes = raw_frame(b"{\"truncated\":true}\n", true);
    bytes.pop();
    let path = fixture.write("truncated.jsonl.zst", &bytes);
    let error = match RolloutReader::open(&path) {
        Ok(_) => panic!("truncated frame unexpectedly opened"),
        Err(error) => error,
    };
    assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
}

#[test]
fn physical_modification_time_is_preserved_while_logical_size_stays_decoded() {
    let fixture = FixtureDir::new();
    let payload = b"{\"logical\":\"size\"}\n";
    let frame = raw_frame(payload, true);
    let path = fixture.write("mtime.jsonl.zst", &frame);
    let first_time = UNIX_EPOCH + Duration::from_secs(1_700_000_000);
    let second_time = UNIX_EPOCH + Duration::from_secs(1_700_000_120);

    File::options().write(true).open(&path)
        .unwrap()
        .set_times(FileTimes::new().set_modified(first_time))
        .unwrap();
    let first = RolloutReader::open(&path).unwrap();
    assert_eq!(first.logical_size(), payload.len() as u64);
    let first_metadata = first.metadata().unwrap();
    assert_eq!(first_metadata.len(), frame.len() as u64);
    assert_eq!(rollout_source::metadata(&path).unwrap().len(), frame.len() as u64);
    assert_eq!(first_metadata.modified().unwrap(), first_time);
    drop(first);

    File::options().write(true).open(&path)
        .unwrap()
        .set_times(FileTimes::new().set_modified(second_time))
        .unwrap();
    let second = RolloutReader::open(&path).unwrap();
    assert_eq!(second.logical_size(), payload.len() as u64);
    assert_eq!(second.metadata().unwrap().modified().unwrap(), second_time);
}

#[test]
fn unused_descriptor_bit_is_ignored_but_reserved_bit_is_rejected() {
    let fixture = FixtureDir::new();
    let payload = b"{}\n";
    let mut frame = raw_frame(payload, true);
    frame[4] |= 0x10; // official decoder ignores descriptor bit 4
    let path = fixture.write("unused.jsonl.zst", &frame);
    let mut reader = RolloutReader::open(&path).unwrap();
    assert_eq!(read_all(&mut reader), payload);
    reader.verify_end(payload.len() as u64).unwrap();
    frame[4] |= 0x08; // descriptor bit 3 is reserved and must be zero
    let reserved = fixture.write("reserved.jsonl.zst", &frame);
    assert!(RolloutReader::open(&reserved).is_err());
}
