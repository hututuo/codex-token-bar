//! Bounded local evidence reads for one-time legacy recovery. No source writes.
use super::rollout_source::{self, RolloutReader};
use crate::core::shared_source_io::source_file_witness;
use sha2::{Digest, Sha256};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::Path;

pub(crate) fn prefix_fragment_matches(
    path: &Path,
    offset: u64,
    count: u64,
    expected: &[u8],
) -> bool {
    if count == 0 || count > 4 * 1024 * 1024 || expected.len() != 32 {
        return false;
    }
    let check = || -> std::io::Result<bool> {
        let mut reader = RolloutReader::open(path)?;
        let before = reader.source_witness()?;
        reader.seek(SeekFrom::Start(offset))?;
        let mut bytes = vec![0; count as usize];
        reader.read_exact(&mut bytes)?;
        after_read();
        let after = reader.source_witness()?;
        let current = std::fs::File::open(rollout_source::physical_path(path)?)?;
        Ok(before == after
            && before == source_file_witness(&current)?
            && Sha256::digest(&bytes).as_slice() == expected)
    };
    check().unwrap_or(false)
}

pub(crate) fn is_paginated_without_parent(path: &Path, session: &str) -> bool {
    let check = || -> Result<bool, Box<dyn std::error::Error>> {
        let physical = rollout_source::physical_path(path)?;
        let file = std::fs::File::open(&physical)?;
        let before = source_file_witness(&file)?;
        let retained_handle = file.try_clone()?;
        if !file.metadata()?.is_file() {
            return Ok(false);
        }
        // A streaming decoder stops after this header, even when a zstd
        // frame omits logical size. Never materialize a compressed session.
        let input: Box<dyn Read> = if physical.extension().is_some_and(|x| x == "zst") {
            let mut decoder = zstd::stream::read::Decoder::new(file)?;
            decoder.window_log_max(27)?;
            Box::new(decoder)
        } else {
            Box::new(file)
        };
        let mut reader = BufReader::new(input.take(256 * 1024 + 1));
        let mut bytes = Vec::new();
        reader.read_until(b'\n', &mut bytes)?;
        if bytes.len() > 256 * 1024 {
            return Ok(false);
        }
        let value: serde_json::Value = serde_json::from_slice(&bytes)?;
        let Some(payload) = value.get("payload") else {
            return Ok(false);
        };
        let no_parent = match payload.get("forked_from_id") {
            None | Some(serde_json::Value::Null) => true,
            Some(serde_json::Value::String(text)) => text.trim().is_empty(),
            _ => false,
        };
        let timestamp = value
            .get("timestamp")
            .or_else(|| payload.get("timestamp"))
            .and_then(|x| x.as_str())
            .and_then(|s| {
                time::OffsetDateTime::parse(s, &time::format_description::well_known::Rfc3339).ok()
            });
        after_read();
        let after = source_file_witness(&retained_handle)?;
        let current = std::fs::File::open(rollout_source::physical_path(path)?)?;
        Ok(
            value.get("type").and_then(|x| x.as_str()) == Some("session_meta")
                && payload.get("id").and_then(|x| x.as_str()) == Some(session)
                && payload.get("history_mode").and_then(|x| x.as_str()) == Some("paginated")
                && timestamp.is_some()
                && no_parent
                && before == after
                && before == source_file_witness(&current)?,
        )
    };
    check().unwrap_or(false)
}

#[cfg(test)]
thread_local! {static AFTER_READ:std::cell::RefCell<Option<Box<dyn FnOnce()>>>=std::cell::RefCell::new(None);}
#[cfg(test)]
pub(crate) fn after_read_for_testing(hook: impl FnOnce() + 'static) {
    AFTER_READ.with(|slot| *slot.borrow_mut() = Some(Box::new(hook)));
}
fn after_read() {
    #[cfg(test)]
    AFTER_READ.with(|slot| {
        let hook = slot.borrow_mut().take();
        if let Some(hook) = hook {
            hook();
        }
    });
}
