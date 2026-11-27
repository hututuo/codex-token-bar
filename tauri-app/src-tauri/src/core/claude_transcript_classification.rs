//! Bounded classification evidence, independent of ledger ownership.
//! Adoption by the scanner requires durable legacy-conflict handling first.

use crate::core::shared_source_io::{probe_uncached, source_file_witness};
use serde_json::Value;
use std::{fs, path::Path};

pub(super) const CONTRACT: &str = "claude-entrypoint-v2";
pub(super) const FAST_PATH_BYTES: usize = 64 * 1024;
pub(super) const MAXIMUM_BYTES: usize = 16 * 1024 * 1024;
/// Root containers count as one. Matches the default serde_json Value decoder bound.
pub(super) const MAXIMUM_NESTING_DEPTH: usize = 127;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum IncompleteReason {
    ByteLimit,
    PartialRecord,
    NestingLimit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Evidence {
    /// The end includes the LF committing the first entrypoint-bearing record.
    Explicit { client: &'static str, record_end: usize },
    /// Clean EOF after complete records: a compatibility default, not explicit evidence.
    LegacyCli,
    Incomplete(IncompleteReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Classification {
    pub(super) evidence: Evidence,
    pub(super) bytes_read: usize,
    pub(super) delimiter_bytes_examined: usize,
}

impl Classification {
    pub(super) fn client(self) -> Option<&'static str> {
        match self.evidence {
            Evidence::Explicit { client, .. } => Some(client),
            Evidence::LegacyCli => Some("claudeCode"),
            Evidence::Incomplete(_) => None,
        }
    }
}

pub(super) fn classify_file(
    file: &fs::File,
    path: &Path,
    byte_limit: usize,
) -> Result<Classification, String> {
    let mut offset = 0u64;
    classify_verified(file, path, byte_limit, |count| {
        let bytes = probe_uncached(file, offset, count).map_err(|error| error.to_string())?;
        offset += bytes.len() as u64;
        Ok(bytes)
    })
}

fn classify_verified(
    file: &fs::File,
    path: &Path,
    byte_limit: usize,
    read: impl FnMut(usize) -> Result<Vec<u8>, String>,
) -> Result<Classification, String> {
    let witness = source_file_witness(file).map_err(|error| error.to_string())?;
    let named_before = fs::File::open(path).map_err(|error| error.to_string())?;
    if witness != source_file_witness(&named_before).map_err(|error| error.to_string())? {
        return Err("源文件在分类期间发生变化，断点未前移".into());
    }
    let result = classify_with_reader(byte_limit, read)?;
    let named_after = fs::File::open(path).map_err(|error| error.to_string())?;
    if witness != source_file_witness(file).map_err(|error| error.to_string())?
        || witness != source_file_witness(&named_after).map_err(|error| error.to_string())?
    {
        return Err("源文件在分类期间发生变化，断点未前移".into());
    }
    Ok(result)
}

/// Each returned byte is inspected for LF at most once. The limit applies to
/// the entire prefix, including skipped records and the terminating LF.
pub(super) fn classify_with_reader(
    byte_limit: usize,
    mut read: impl FnMut(usize) -> Result<Vec<u8>, String>,
) -> Result<Classification, String> {
    let limit = byte_limit.min(MAXIMUM_BYTES);
    let mut bytes_read = 0usize;
    let mut examined = 0usize;
    let mut line = Vec::new();
    let mut depth = 0usize;
    let mut in_string = false;
    let mut escaped = false;
    while bytes_read < limit {
        let chunk_size = if bytes_read < FAST_PATH_BYTES {
            (4 * 1024).min(FAST_PATH_BYTES - bytes_read)
        } else {
            FAST_PATH_BYTES
        };
        let requested = chunk_size.min(limit - bytes_read);
        let chunk = read(requested)?;
        if chunk.len() > requested {
            return Err("分类读取超过请求上限".into());
        }
        if chunk.is_empty() {
            return Ok(Classification {
                evidence: if line.is_empty() {
                    Evidence::LegacyCli
                } else {
                    Evidence::Incomplete(IncompleteReason::PartialRecord)
                },
                bytes_read,
                delimiter_bytes_examined: examined,
            });
        }
        let offset = bytes_read;
        bytes_read += chunk.len();
        let mut segment = 0usize;
        for (index, byte) in chunk.iter().enumerate() {
            examined += 1;
            if *byte != b'\n' {
                if in_string {
                    if escaped {
                        escaped = false;
                    } else if *byte == b'\\' {
                        escaped = true;
                    } else if *byte == b'"' {
                        in_string = false;
                    }
                } else if *byte == b'"' {
                    in_string = true;
                } else if *byte == b'{' || *byte == b'[' {
                    depth += 1;
                    if depth > MAXIMUM_NESTING_DEPTH {
                        return Ok(Classification {
                            evidence: Evidence::Incomplete(IncompleteReason::NestingLimit),
                            bytes_read,
                            delimiter_bytes_examined: examined,
                        });
                    }
                } else if *byte == b'}' || *byte == b']' {
                    depth = depth.saturating_sub(1);
                }
                continue;
            }
            line.extend_from_slice(&chunk[segment..index]);
            if let Some(client) = source_in_complete_line(&line) {
                return Ok(Classification {
                    evidence: Evidence::Explicit { client, record_end: offset + index + 1 },
                    bytes_read,
                    delimiter_bytes_examined: examined,
                });
            }
            line.clear();
            depth = 0;
            in_string = false;
            escaped = false;
            segment = index + 1;
        }
        line.extend_from_slice(&chunk[segment..]);
    }
    Ok(Classification {
        evidence: Evidence::Incomplete(IncompleteReason::ByteLimit),
        bytes_read,
        delimiter_bytes_examined: examined,
    })
}

fn source_in_complete_line(raw: &[u8]) -> Option<&'static str> {
    let line = raw.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(raw);
    let value = serde_json::from_slice::<Value>(line).ok()?;
    let entrypoint = value.get("entrypoint")?.as_str()?;
    if entrypoint.trim().is_empty() {
        return None;
    }
    Some(if entrypoint.starts_with("claude-desktop") {
        "claudeDesktop"
    } else {
        "claudeCode"
    })
}

#[cfg(test)]
#[path = "claude_transcript_classification_tests.rs"]
mod tests;
