//! One-time import of the JSON history emitted by public releases through v0.9.7.
//! The receipt belongs to this source's body namespace, and commits with the rows.

use super::{normalized_retention_days, safe_now, BodySpeedTrendStore};
use crate::models::SpeedSample;
use rusqlite::{params, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::Read;
use std::path::{Path, PathBuf};

const MAX_JSON_BYTES: u64 = 16 * 1024 * 1024;
const RECEIPT_KEY: &str = "legacy_observed_json_import_v1";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredSamples {
    version: u32,
    samples: Vec<SpeedSample>,
    #[serde(default)]
    body_retention_days: Option<u16>,
}

#[derive(Deserialize, Serialize)]
struct Receipt {
    version: u32,
    source_path: String,
    source_digest: String,
    backup_path: String,
    imported_count: usize,
}

pub(super) fn import(store: &BodySpeedTrendStore, now: f64) -> rusqlite::Result<()> {
    if !safe_now(now) {
        return Err(rusqlite::Error::InvalidQuery);
    }
    let Some(source) = legacy_path(&store.path) else {
        return Ok(());
    };
    let source_text = source
        .to_str()
        .ok_or_else(|| rusqlite::Error::InvalidPath(source.clone()))?;
    let backup_directory = store
        .shared_path
        .as_deref()
        .unwrap_or(&store.path)
        .parent()
        .ok_or_else(|| rusqlite::Error::InvalidPath(store.path.clone()))?
        .join("backups");
    let mut connection = store.connect()?;
    let previous: Option<String> = connection
        .query_row(
            "SELECT value FROM speed_trend_meta WHERE key=?1",
            [RECEIPT_KEY],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(previous) = previous {
        return validate_receipt(&previous, source_text, &backup_directory);
    }

    match fs::symlink_metadata(&source) {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(io_error(error)),
    }
    // Only an initially absent name is optional. Disappearance/I/O failure
    // after discovery is a failed import, never proof of an empty old history.
    let bytes = read_snapshot(&source).map_err(io_error)?;
    let legacy: StoredSamples = serde_json::from_slice(&bytes)
        .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
    if legacy.version != 1 {
        return Err(rusqlite::Error::InvalidQuery);
    }
    let digest = hex_digest(&bytes);
    let backup = backup_directory.join(format!("observed-json-{digest}.json"));
    retain_backup(&backup, &bytes)?;

    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let previous: Option<String> = transaction
        .query_row(
            "SELECT value FROM speed_trend_meta WHERE key=?1",
            [RECEIPT_KEY],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(previous) = previous {
        // A concurrent importer won. Never replay its frozen JSON over new rows.
        drop(transaction);
        return validate_receipt(&previous, source_text, &backup_directory);
    }
    if read_snapshot(&source).map_err(io_error)? != bytes {
        return Err(rusqlite::Error::InvalidQuery);
    }
    let has_current_history: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM speed_samples) OR EXISTS(SELECT 1 FROM speed_sample_ids) \
         OR EXISTS(SELECT 1 FROM speed_5m)",
        [],
        |row| row.get(0),
    )?;
    let retention_days = if has_current_history {
        let stored: String = transaction.query_row(
            "SELECT value FROM speed_trend_meta WHERE key='body_retention_days'",
            [],
            |row| row.get(0),
        )?;
        match stored.as_str() {
            "15" => 15,
            "30" => 30,
            _ => return Err(rusqlite::Error::InvalidQuery),
        }
    } else {
        normalized_retention_days(legacy.body_retention_days.unwrap_or(30))
    };
    let mut seen = HashSet::new();
    let mut incoming = Vec::new();
    {
        let mut existing = transaction.prepare_cached(
            "SELECT EXISTS(SELECT 1 FROM speed_samples WHERE id=?1) \
             OR EXISTS(SELECT 1 FROM speed_sample_ids WHERE id=?1)",
        )?;
        for sample in legacy.samples {
            if sample.measurement_kind.as_deref() != Some("completed_body")
                || sample.tokenizer.as_deref() != Some("o200k_base")
                || !seen.insert(sample.id.clone())
            {
                continue;
            }
            let already_stored: bool =
                existing.query_row([sample.id.as_str()], |row| row.get(0))?;
            if !already_stored {
                // A completion receipt must not freeze a row the ordinary
                // ingestor would defer until its timestamp becomes eligible.
                if super::valid_raw_body_sample(&sample) && sample.ended_at > now {
                    return Err(rusqlite::Error::InvalidQuery);
                }
                incoming.push(sample);
            }
        }
    }
    let imported_count =
        BodySpeedTrendStore::ingest_transaction(&transaction, &incoming, now, retention_days)?;
    let receipt = Receipt {
        version: 1,
        source_path: source_text.to_owned(),
        source_digest: digest,
        backup_path: backup
            .to_str()
            .ok_or_else(|| rusqlite::Error::InvalidPath(backup.clone()))?
            .to_owned(),
        imported_count,
    };
    let json = serde_json::to_string(&receipt)
        .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
    transaction.execute(
        "INSERT INTO speed_trend_meta(key,value) VALUES(?1,?2)",
        params![RECEIPT_KEY, json],
    )?;
    transaction.commit()?;
    Ok(())
}

fn legacy_path(path: &Path) -> Option<PathBuf> {
    let identity = path
        .file_name()?
        .to_str()?
        .strip_prefix("body-speed-")?
        .strip_suffix(".sqlite")?;
    (!identity.is_empty()).then(|| path.with_file_name(format!("observed-speed-{identity}.json")))
}

fn validate_receipt(json: &str, source: &str, backup_directory: &Path) -> rusqlite::Result<()> {
    let receipt: Receipt = serde_json::from_str(json)
        .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
    if receipt.version != 1
        || receipt.source_path != source
        || receipt.source_digest.len() != 64
        || !receipt
            .source_digest
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(rusqlite::Error::InvalidQuery);
    }
    let backup = backup_directory.join(format!("observed-json-{}.json", receipt.source_digest));
    if Path::new(&receipt.backup_path) != backup
        || hex_digest(&read_snapshot(&backup).map_err(io_error)?) != receipt.source_digest
    {
        return Err(rusqlite::Error::InvalidQuery);
    }
    Ok(())
}

fn retain_backup(path: &Path, bytes: &[u8]) -> rusqlite::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(_) => {
            // A content-addressed backup is immutable evidence. Unknown/corrupt
            // content must be repaired explicitly, never overwritten in place.
            if read_snapshot(path).map_err(io_error)? != bytes {
                return Err(rusqlite::Error::InvalidQuery);
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let parent = path
                .parent()
                .ok_or_else(|| rusqlite::Error::InvalidPath(path.to_path_buf()))?;
            fs::create_dir_all(parent).map_err(io_error)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(parent, fs::Permissions::from_mode(0o700)).map_err(io_error)?;
            }
            crate::core::atomic_file::write_atomically(path, bytes).map_err(|error| {
                io_error(std::io::Error::other(format!(
                    "legacy body backup: {error}"
                )))
            })?;
        }
        Err(error) => return Err(io_error(error)),
    }
    // Check the published snapshot before its path becomes part of a receipt.
    if read_snapshot(path).map_err(io_error)? != bytes {
        return Err(rusqlite::Error::InvalidQuery);
    }
    Ok(())
}

fn read_snapshot(path: &Path) -> std::io::Result<Vec<u8>> {
    let named_before = fs::symlink_metadata(path)?;
    if !named_before.is_file()
        || named_before.file_type().is_symlink()
        || named_before.len() > MAX_JSON_BYTES
    {
        return Err(std::io::Error::other(
            "legacy body JSON is not a bounded regular file",
        ));
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT);
    }
    let file: File = options.open(path)?;
    let opened = file.metadata()?;
    if !same_snapshot(&named_before, &opened)? {
        return Err(std::io::Error::other(
            "legacy body JSON changed before reading",
        ));
    }
    let mut bytes = Vec::new();
    file.take(MAX_JSON_BYTES + 1).read_to_end(&mut bytes)?;
    let named_after = fs::symlink_metadata(path)?;
    if bytes.len() as u64 > MAX_JSON_BYTES
        || bytes.len() as u64 != opened.len()
        || !same_snapshot(&opened, &named_after)?
    {
        return Err(std::io::Error::other(
            "legacy body JSON changed while reading",
        ));
    }
    Ok(bytes)
}

fn same_snapshot(before: &Metadata, after: &Metadata) -> std::io::Result<bool> {
    if !after.is_file()
        || after.file_type().is_symlink()
        || before.len() != after.len()
        || before.modified()? != after.modified()?
    {
        return Ok(false);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if before.dev() != after.dev()
            || before.ino() != after.ino()
            || before.ctime() != after.ctime()
            || before.ctime_nsec() != after.ctime_nsec()
        {
            return Ok(false);
        }
    }
    Ok(true)
}

fn hex_digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn io_error(error: std::io::Error) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(error))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn fixture() -> (tempfile::TempDir, BodySpeedTrendStore, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("body-speed-public097.sqlite");
        let source = legacy_path(&path).unwrap();
        let store = BodySpeedTrendStore::open(&path).unwrap();
        (root, store, source)
    }

    fn sample(id: &str, ended: f64, tokens: u32) -> SpeedSample {
        serde_json::from_value(json!({
            "id":id,"threadId":"thread-a","turnId":"turn-a","itemId":"item-a",
            "model":"gpt-6.1-sol","startedAt":ended-2.0,"endedAt":ended,
            "outputTokens":tokens,"outputCharacters":200,"outputBytes":200,"chunkCount":1,
            "durationSeconds":2.0,"tokensPerSecond":f64::from(tokens)/2.0,
            "confidence":"medium","networkWarning":false,"source":"public-v097",
            "measurementKind":"completed_body","tokenizer":"o200k_base","bodyPhase":"final_answer"
        }))
        .unwrap()
    }

    fn write_source(path: &Path, samples: &[SpeedSample], retention: u16) -> Vec<u8> {
        let bytes = serde_json::to_vec(&json!({
            "version":1,"samples":samples,"bodyRetentionDays":retention
        }))
        .unwrap();
        fs::write(path, &bytes).unwrap();
        bytes
    }

    #[test]
    fn public_v097_json_import_preserves_body_rows_retention_and_original_evidence() {
        let (_root, store, source) = fixture();
        let now = 1_800_000_600.0;
        let body = sample("body", now - 60.0, 100);
        let mut stream = body.clone();
        stream.id = "legacy-stream".into();
        stream.measurement_kind = None;
        stream.tokenizer = None;
        let mut warning = serde_json::to_value(sample("warned", now - 30.0, 100)).unwrap();
        warning["networkWarning"] = Value::Bool(true);
        let bytes = serde_json::to_vec(&json!({
            "version":1,"samples":[serde_json::to_value(&body).unwrap(),serde_json::to_value(stream).unwrap(),warning],
            "bodyRetentionDays":15
        })).unwrap();
        fs::write(&source, &bytes).unwrap();

        store.import_legacy_json(now).unwrap();
        let retained = store.read_samples(now, 15).unwrap();
        assert_eq!(retained.len(), 2);
        assert_eq!(retained[0], body);
        assert!(retained[1].network_warning.is_some());
        assert_eq!(store.retention_days().unwrap(), 15);
        assert_eq!(
            store
                .read(now, 1)
                .unwrap()
                .iter()
                .map(|p| p.sample_count)
                .sum::<i64>(),
            1
        );
        assert_eq!(fs::read(&source).unwrap(), bytes);
        let backup = source
            .parent()
            .unwrap()
            .join("backups")
            .join(format!("observed-json-{}.json", hex_digest(&bytes)));
        assert_eq!(fs::read(backup).unwrap(), bytes);
    }

    #[test]
    fn current_sqlite_ids_and_retention_win_over_old_json() {
        let (_root, store, source) = fixture();
        let now = 1_800_000_600.0;
        let old = sample("same-id", now - 60.0, 100);
        let mut newer = old.clone();
        newer.output_tokens = 200;
        newer.tokens_per_second = 100.0;
        store.ingest(&[newer.clone()], now, 30).unwrap();
        let unseen = sample("old-unseen", now - 30.0, 60);
        write_source(&source, &[old, unseen.clone()], 15);
        store.import_legacy_json(now).unwrap();
        assert_eq!(store.read_samples(now, 30).unwrap(), vec![newer, unseen]);
        assert_eq!(store.retention_days().unwrap(), 30);
        assert_eq!(
            store
                .read(now, 1)
                .unwrap()
                .iter()
                .map(|p| p.output_tokens)
                .sum::<i64>(),
            260
        );
    }

    #[test]
    fn committed_receipt_survives_restart_and_never_replays_pruned_history() {
        let (_root, store, source) = fixture();
        let now = 1_800_000_600.0;
        write_source(&source, &[sample("body", now - 60.0, 100)], 15);
        store.import_legacy_json(now).unwrap();
        store.ingest(&[], now + 20.0 * 86_400.0, 15).unwrap();
        assert!(store
            .read_samples(now + 20.0 * 86_400.0, 15)
            .unwrap()
            .is_empty());
        // A retained completion receipt also fences history if its disposable
        // numeric projections have since been cleared. No old JSON replay.
        store
            .connect()
            .unwrap()
            .execute_batch(
                "DELETE FROM speed_samples; DELETE FROM speed_sample_ids; DELETE FROM speed_5m;",
            )
            .unwrap();
        let path = store.path.clone();
        drop(store);
        let reopened = BodySpeedTrendStore::open(path).unwrap();
        fs::write(
            source,
            b"old file may be archived or changed after activation",
        )
        .unwrap();
        reopened.import_legacy_json(now).unwrap();
        assert!(reopened.read_samples(now, 30).unwrap().is_empty());
        assert!(reopened.read(now, 1).unwrap().is_empty());
    }

    #[test]
    fn invalid_or_future_json_cannot_complete_an_empty_import() {
        let (_root, store, source) = fixture();
        let now = 1_800_000_600.0;
        for bytes in [
            b"{invalid".as_slice(),
            br#"{"version":2,"samples":[]}"#.as_slice(),
        ] {
            fs::write(&source, bytes).unwrap();
            assert!(store.import_legacy_json(now).is_err());
            assert_eq!(fs::read(&source).unwrap(), bytes);
            let connection = store.connect().unwrap();
            let count: i64 = connection
                .query_row(
                    "SELECT COUNT(*) FROM speed_trend_meta WHERE key=?1",
                    [RECEIPT_KEY],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(count, 0);
            assert!(store.read_samples(now, 30).unwrap().is_empty());
        }
    }

    #[test]
    fn receipt_failure_rolls_back_import_and_allows_retry() {
        let (_root, store, source) = fixture();
        let now = 1_800_000_600.0;
        write_source(&source, &[sample("body", now - 60.0, 100)], 15);
        store.connect().unwrap().execute_batch(
            "CREATE TRIGGER reject_import_receipt BEFORE INSERT ON speed_trend_meta \
             WHEN NEW.key='legacy_observed_json_import_v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;"
        ).unwrap();
        assert!(store.import_legacy_json(now).is_err());
        assert!(store.read_samples(now, 30).unwrap().is_empty());
        assert_eq!(store.retention_days().unwrap(), 30);
        store
            .connect()
            .unwrap()
            .execute_batch("DROP TRIGGER reject_import_receipt")
            .unwrap();
        store.import_legacy_json(now).unwrap();
        assert_eq!(store.read_samples(now, 15).unwrap().len(), 1);
        assert_eq!(store.retention_days().unwrap(), 15);
    }

    #[test]
    fn missing_json_is_noop_and_oversized_json_is_rejected_before_reading() {
        let (_root, store, source) = fixture();
        let now = 1_800_000_600.0;
        store.import_legacy_json(now).unwrap();
        assert!(store.read_samples(now, 30).unwrap().is_empty());
        File::create(&source)
            .unwrap()
            .set_len(MAX_JSON_BYTES + 1)
            .unwrap();
        assert!(store.import_legacy_json(now).is_err());
        assert_eq!(fs::metadata(source).unwrap().len(), MAX_JSON_BYTES + 1);
    }

    #[test]
    fn future_body_cannot_be_frozen_out_by_a_completed_receipt() {
        let (_root, store, source) = fixture();
        let now = 1_800_000_600.0;
        write_source(&source, &[sample("future", now + 5.0, 100)], 15);
        assert!(store.import_legacy_json(now).is_err());
        let count: i64 = store
            .connect()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM speed_trend_meta WHERE key=?1",
                [RECEIPT_KEY],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 0);
        store.import_legacy_json(now + 5.0).unwrap();
        assert_eq!(store.read_samples(now + 5.0, 15).unwrap().len(), 1);
    }

    #[cfg(unix)]
    #[test]
    fn unreadable_or_symlinked_legacy_json_never_becomes_empty_success() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let (_root, store, source) = fixture();
        let now = 1_800_000_600.0;
        write_source(&source, &[sample("body", now - 60.0, 100)], 15);
        if unsafe { libc::geteuid() } != 0 {
            fs::set_permissions(&source, fs::Permissions::from_mode(0o000)).unwrap();
            let result = store.import_legacy_json(now);
            fs::set_permissions(&source, fs::Permissions::from_mode(0o600)).unwrap();
            assert!(result.is_err());
        }
        let target = source.with_extension("original");
        fs::rename(&source, &target).unwrap();
        symlink(&target, &source).unwrap();
        assert!(store.import_legacy_json(now).is_err());
        assert!(store.read_samples(now, 30).unwrap().is_empty());
    }
}
