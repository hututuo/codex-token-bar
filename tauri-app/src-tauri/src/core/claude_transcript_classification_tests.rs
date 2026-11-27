use super::*;
use std::{io::Write, path::PathBuf, time::SystemTime};

fn record(size: usize, entrypoint_first: bool) -> Vec<u8> {
    let (prefix, suffix) = if entrypoint_first {
        (b"{\"entrypoint\":\"claude-desktop-boundary\",\"content\":\"".as_slice(), b"\"}\n".as_slice())
    } else {
        (b"{\"content\":\"".as_slice(), b"\",\"entrypoint\":\"claude-desktop-boundary\"}\n".as_slice())
    };
    assert!(size >= prefix.len() + suffix.len());
    let mut bytes = Vec::with_capacity(size);
    bytes.extend_from_slice(prefix);
    bytes.resize(size - suffix.len(), b'x');
    bytes.extend_from_slice(suffix);
    bytes
}

fn classify_bytes(bytes: &[u8], limit: usize) -> Classification {
    let mut offset = 0usize;
    let result = classify_with_reader(limit, |count| {
        let end = bytes.len().min(offset + count);
        let chunk = bytes[offset..end].to_vec();
        offset = end;
        Ok(chunk)
    }).unwrap();
    assert_eq!(result.bytes_read, offset);
    assert!(result.delimiter_bytes_examined <= result.bytes_read);
    result
}

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let nonce = SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let directory = std::env::temp_dir().join(format!("tokenbar-classifier-{}-{nonce}", std::process::id()));
        fs::create_dir(&directory).unwrap();
        Self(directory)
    }
    fn path(&self) -> PathBuf { self.0.join("synthetic.jsonl") }
}
impl Drop for Fixture {
    fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); }
}

#[test]
fn claude_classification_short_header_keeps_one_small_read_and_first_explicit_source() {
    let header = b"{\"entrypoint\":\"cli\"}\n";
    let mut bytes = header.to_vec();
    bytes.extend_from_slice(&record(MAXIMUM_BYTES, false));
    let mut requests = Vec::new();
    let result = classify_with_reader(MAXIMUM_BYTES, |count| {
        requests.push(count);
        Ok(bytes[..count].to_vec())
    }).unwrap();
    assert_eq!(requests, [4096]);
    assert_eq!(result.evidence, Evidence::Explicit { client: "claudeCode", record_end: header.len() });
    assert_eq!(result.bytes_read, 4096);
    assert_eq!(result.delimiter_bytes_examined, header.len());
    assert_eq!(CONTRACT, "claude-entrypoint-v2");
}

#[test]
fn claude_classification_long_first_records_are_explicit_at_exact_lf_boundaries() {
    for size in [FAST_PATH_BYTES - 1, FAST_PATH_BYTES, FAST_PATH_BYTES + 1,
        1024 * 1024, 4 * 1024 * 1024, 4 * 1024 * 1024 + 1, MAXIMUM_BYTES] {
        for first in [true, false] {
            let result = classify_bytes(&record(size, first), MAXIMUM_BYTES);
            assert_eq!(result.evidence, Evidence::Explicit { client: "claudeDesktop", record_end: size }, "{size}/{first}");
            assert_eq!(result.bytes_read, size);
            assert_eq!(result.delimiter_bytes_examined, size);
        }
    }
}

#[test]
fn claude_classification_total_prefix_limit_never_resets_or_accepts_late_lf() {
    let result = classify_bytes(&record(MAXIMUM_BYTES + 1, false), usize::MAX);
    assert_eq!(result.evidence, Evidence::Incomplete(IncompleteReason::ByteLimit));
    assert_eq!(result.client(), None);
    assert_eq!(result.bytes_read, MAXIMUM_BYTES);
    assert_eq!(result.delimiter_bytes_examined, MAXIMUM_BYTES);
    let mut bytes = b"{\"metadata\":true}\n".to_vec();
    let prefix = bytes.len();
    bytes.extend_from_slice(b"{\"entrypoint\":\"claude-desktop\"}\n");
    let incomplete = classify_bytes(&bytes, bytes.len() - 1);
    assert_eq!(incomplete.evidence, Evidence::Incomplete(IncompleteReason::ByteLimit));
    let complete = classify_bytes(&bytes, bytes.len());
    assert_eq!(complete.evidence, Evidence::Explicit { client: "claudeDesktop", record_end: bytes.len() });
    assert!(complete.delimiter_bytes_examined > prefix);
    let zero = classify_with_reader(0, |_| panic!("zero budget must not read")).unwrap();
    assert_eq!(zero.evidence, Evidence::Incomplete(IncompleteReason::ByteLimit));
}

#[test]
fn claude_classification_only_clean_record_eof_uses_legacy_default() {
    for bytes in [b"".as_slice(), b"{\"metadata\":true}\n", b"not-json\n[]\n\n",
        b"{\"nested\":{\"entrypoint\":\"claude-desktop\"},\"entrypoint\":\"  \"}\n"] {
        let result = classify_bytes(bytes, MAXIMUM_BYTES);
        assert_eq!(result.evidence, Evidence::LegacyCli);
        assert_eq!(result.client(), Some("claudeCode"));
    }
    for bytes in [b"{\"entrypoint\":\"claude-desktop\"}".as_slice(), b"{\"metadata\":true}\n{", b" "] {
        let result = classify_bytes(bytes, MAXIMUM_BYTES);
        assert_eq!(result.evidence, Evidence::Incomplete(IncompleteReason::PartialRecord));
        assert_eq!(result.client(), None);
    }
}

#[test]
fn claude_classification_bom_crlf_invalid_and_nested_values_keep_top_level_contract() {
    let bytes = b"not-json\n{\"entrypoint\":42}\n{\"entrypoint\":\"\",\"nested\":{\"entrypoint\":\"cli\"}}\n\xef\xbb\xbf{\"entrypoint\":\"claude-desktop-boundary\"}\r\n{\"entrypoint\":\"cli\"}\n";
    let first_end = bytes.len() - b"{\"entrypoint\":\"cli\"}\n".len();
    let result = classify_bytes(bytes, MAXIMUM_BYTES);
    assert_eq!(result.evidence, Evidence::Explicit { client: "claudeDesktop", record_end: first_end });
    assert_eq!(result.delimiter_bytes_examined, first_end);
}

#[test]
fn claude_classification_short_reads_remain_linear_and_reader_failures_propagate() {
    let bytes = record(32 * 1024, false);
    let mut offset = 0usize;
    let result = classify_with_reader(MAXIMUM_BYTES, |count| {
        let end = bytes.len().min(offset + count.min(7));
        let chunk = bytes[offset..end].to_vec(); offset = end; Ok(chunk)
    }).unwrap();
    assert_eq!(result.evidence, Evidence::Explicit { client: "claudeDesktop", record_end: bytes.len() });
    assert_eq!(result.delimiter_bytes_examined, bytes.len());
    let failed = classify_with_reader(MAXIMUM_BYTES, |_| Err("injected-read-failure".into()));
    assert_eq!(failed, Err("injected-read-failure".into()));
    assert!(classify_with_reader(7, |count| Ok(vec![b'x'; count + 1])).is_err());
}

fn nested_record(depth: usize, entrypoint_first: bool, committed: bool) -> Vec<u8> {
    assert!(depth >= 1);
    let mut bytes = if entrypoint_first {
        b"{\"entrypoint\":\"claude-desktop\",\"content\":".to_vec()
    } else {
        b"{\"content\":".to_vec()
    };
    bytes.extend(std::iter::repeat_n(b'[', depth - 1));
    bytes.push(b'0');
    bytes.extend(std::iter::repeat_n(b']', depth - 1));
    if !entrypoint_first {
        bytes.extend_from_slice(b",\"entrypoint\":\"claude-desktop\"");
    }
    bytes.push(b'}');
    if committed { bytes.push(b'\n'); }
    bytes
}

#[test]
fn claude_classification_nesting_depth127_keeps_both_entrypoint_orders_explicit() {
    assert_eq!(MAXIMUM_NESTING_DEPTH, 127);
    for first in [true, false] {
        let bytes = nested_record(127, first, true);
        let result = classify_bytes(&bytes, MAXIMUM_BYTES);
        assert_eq!(result.evidence, Evidence::Explicit { client: "claudeDesktop", record_end: bytes.len() });
        assert_eq!(result.delimiter_bytes_examined, bytes.len());
    }
}

#[test]
fn claude_classification_depth128_never_falls_through_to_later_cli_or_eof() {
    for first in [true, false] {
        for committed in [true, false] {
            let mut bytes = nested_record(128, first, committed);
            let prefix = if first {
                b"{\"entrypoint\":\"claude-desktop\",\"content\":".len()
            } else {
                b"{\"content\":".len()
            };
            let depth128_end = prefix + 127;
            if committed { bytes.extend_from_slice(b"{\"entrypoint\":\"cli\"}\n"); }
            let result = classify_bytes(&bytes, MAXIMUM_BYTES);
            assert_eq!(result.evidence, Evidence::Incomplete(IncompleteReason::NestingLimit));
            assert_eq!(result.client(), None);
            assert_eq!(result.delimiter_bytes_examined, depth128_end);
            assert!(depth128_end < bytes.len());
        }
    }
}

#[test]
fn claude_classification_quoted_brackets_and_escaped_quotes_survive_chunk_boundaries() {
    let content = format!("{}{}", "x".repeat(4080), "[{}]\\\"".repeat(200));
    let mut bytes = serde_json::to_vec(&serde_json::json!({
        "content": content, "entrypoint": "claude-desktop"
    })).unwrap();
    bytes.push(b'\n');
    for chunk_limit in [1usize, 7, 4096] {
        let mut offset = 0usize;
        let result = classify_with_reader(MAXIMUM_BYTES, |count| {
            let end = bytes.len().min(offset + count.min(chunk_limit));
            let chunk = bytes[offset..end].to_vec();
            offset = end;
            Ok(chunk)
        }).unwrap();
        assert_eq!(result.evidence, Evidence::Explicit { client: "claudeDesktop", record_end: bytes.len() });
        assert_eq!(result.delimiter_bytes_examined, bytes.len());
        assert_eq!(result.bytes_read, offset);
    }
}

#[test]
fn claude_classification_malformed_lines_reset_depth_string_and_escape_state() {
    for prefix in [b"[[[\n\n".as_slice(), b"\"unterminated\\\n\n", b"]]]\n"] {
        let mut bytes = prefix.to_vec();
        bytes.extend_from_slice(&nested_record(127, false, true));
        let result = classify_bytes(&bytes, MAXIMUM_BYTES);
        assert_eq!(result.evidence, Evidence::Explicit { client: "claudeDesktop", record_end: bytes.len() });
        assert_eq!(result.delimiter_bytes_examined, bytes.len());
    }
}

#[test]
fn claude_classification_synthetic_file_and_pinned_handle_reject_named_replacement() {
    let fixture = Fixture::new();
    let path = fixture.path();
    let bytes = record(FAST_PATH_BYTES + 1, false);
    fs::write(&path, &bytes).unwrap();
    let pinned = fs::File::open(&path).unwrap();
    let classified = classify_file(&pinned, &path, MAXIMUM_BYTES).unwrap();
    assert_eq!(classified.evidence, Evidence::Explicit { client: "claudeDesktop", record_end: bytes.len() });
    let original = fixture.0.join("original.jsonl");
    let mut offset = 0u64;
    let mut replaced = false;
    let result = classify_verified(&pinned, &path, MAXIMUM_BYTES, |count| {
        if offset == FAST_PATH_BYTES as u64 {
            fs::rename(&path, &original).unwrap();
            fs::write(&path, b"{\"entrypoint\":\"cli\"}\n").unwrap();
            replaced = true;
        }
        let chunk = probe_uncached(&pinned, offset, count).map_err(|error| error.to_string())?;
        offset += chunk.len() as u64; Ok(chunk)
    });
    assert!(replaced);
    assert!(result.unwrap_err().contains("分类期间发生变化"));
    assert!(classify_file(&pinned, &path, MAXIMUM_BYTES).is_err());
}

#[test]
fn claude_classification_append_during_fallback_invalidates_its_observation() {
    let fixture = Fixture::new();
    let path = fixture.path();
    fs::write(&path, record(FAST_PATH_BYTES + 1, false)).unwrap();
    let pinned = fs::File::open(&path).unwrap();
    let mut offset = 0u64;
    let mut appended = false;
    let result = classify_verified(&pinned, &path, MAXIMUM_BYTES, |count| {
        if offset == FAST_PATH_BYTES as u64 {
            let mut writer = fs::OpenOptions::new().append(true).open(&path).unwrap();
            writer.write_all(b"{\"metadata\":true}\n").unwrap(); writer.flush().unwrap(); appended = true;
        }
        let chunk = probe_uncached(&pinned, offset, count).map_err(|error| error.to_string())?;
        offset += chunk.len() as u64; Ok(chunk)
    });
    assert!(appended);
    assert!(result.is_err());
}
