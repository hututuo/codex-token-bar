use super::{read_snapshot, SourceRead};
use rusqlite::Connection;
use std::{
    fs,
    path::{Path, PathBuf},
    sync::mpsc,
    thread,
    time::{Duration, SystemTime},
};

fn temp_database(label: &str) -> (tempfile::TempDir, PathBuf) {
    let root = tempfile::tempdir().expect("create isolated SQLite fixture directory");
    let database = root.path().join(label);
    (root, database)
}

fn seed_database(path: &Path, value: i64, wal: bool) -> Connection {
    let connection = Connection::open(path).expect("open isolated fixture database");
    if wal {
        connection
            .execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
            .expect("enable WAL without automatic checkpoints");
    }
    connection
        .execute_batch("CREATE TABLE snapshot_value(value INTEGER NOT NULL);")
        .expect("create fixture table");
    connection
        .execute("INSERT INTO snapshot_value(value) VALUES(?1)", [value])
        .expect("seed fixture value");
    if wal {
        let (busy, _, _): (i64, i64, i64) = connection
            .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })
            .expect("checkpoint initial fixture state");
        assert_eq!(busy, 0, "initial fixture checkpoint should not be busy");
    }
    connection
}

fn read_value(connection: &Connection) -> Result<i64, String> {
    connection
        .query_row("SELECT value FROM snapshot_value", [], |row| row.get(0))
        .map_err(|error| error.to_string())
}

fn expect_updated<T>(result: SourceRead<T>) -> (String, T) {
    match result {
        SourceRead::Updated { token, value } => (token, value),
        SourceRead::Unchanged => panic!("expected an updated source snapshot"),
    }
}

fn main_file_stat(path: &Path) -> (u64, SystemTime) {
    let metadata = fs::metadata(path).expect("read main database metadata");
    (
        metadata.len(),
        metadata
            .modified()
            .expect("read main database modification time"),
    )
}

#[test]
fn unchanged_reads_skip_closure_and_wal_only_commits_are_visible() {
    let (_root, database) = temp_database("live-state.sqlite");
    let writer = seed_database(&database, 1, true);
    let reads = std::sync::atomic::AtomicUsize::new(0);

    let (token, first_value) = expect_updated(
        read_snapshot(&database, None, |connection| {
            reads.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            read_value(connection)
        })
        .expect("read initial snapshot"),
    );
    assert_eq!(first_value, 1);
    assert_eq!(reads.load(std::sync::atomic::Ordering::SeqCst), 1);

    let unchanged = read_snapshot(&database, Some(&token), |connection| {
        reads.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        read_value(connection)
    })
    .expect("read unchanged source");

    #[cfg(windows)]
    let token = {
        // Windows SQLite handles do not share delete access, so the source
        // reader opens a short-lived connection for every read. Equal content
        // may therefore be returned as Updated after rerunning the closure.
        let (token, unchanged_value) = expect_updated(unchanged);
        assert_eq!(unchanged_value, 1);
        assert_eq!(reads.load(std::sync::atomic::Ordering::SeqCst), 2);
        token
    };

    #[cfg(not(windows))]
    let token = {
        assert!(matches!(unchanged, SourceRead::Unchanged));
        assert_eq!(
            reads.load(std::sync::atomic::Ordering::SeqCst),
            1,
            "an unchanged token must not invoke the read closure"
        );
        token
    };

    let main_before = main_file_stat(&database);
    writer
        .execute("UPDATE snapshot_value SET value=2", [])
        .expect("commit WAL-only source update");
    assert_eq!(
        main_file_stat(&database),
        main_before,
        "the source update should remain in WAL without changing main-file stat"
    );

    let (updated_token, updated_value) = expect_updated(
        read_snapshot(&database, Some(&token), |connection| {
            reads.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            read_value(connection)
        })
        .expect("observe committed WAL-only update"),
    );
    assert_eq!(updated_value, 2);
    assert_ne!(updated_token, token);
    assert_eq!(
        reads.load(std::sync::atomic::Ordering::SeqCst),
        if cfg!(windows) { 3 } else { 2 }
    );
}

#[test]
fn snapshot_connection_rejects_writes_without_changing_source() {
    let (_root, database) = temp_database("read-only-source.sqlite");
    let writer = seed_database(&database, 7, false);
    drop(writer);

    let attempted_write = read_snapshot(&database, None, |connection| {
        connection
            .execute("UPDATE snapshot_value SET value=99", [])
            .map_err(|error| error.to_string())?;
        read_value(connection)
    });
    assert!(
        attempted_write.is_err(),
        "the persistent source connection must reject writes"
    );

    let verifier = Connection::open(&database).expect("open independent verifier connection");
    assert_eq!(
        read_value(&verifier).expect("read source after rejected write"),
        7,
        "a rejected closure write must leave the source file unchanged"
    );
}

#[test]
fn physical_source_replacement_invalidates_prior_snapshot_and_token() {
    let (root, database) = temp_database("replaceable-state.sqlite");
    drop(seed_database(&database, 11, false));

    let (old_token, old_value) =
        expect_updated(read_snapshot(&database, None, read_value).expect("read original source"));
    assert_eq!(old_value, 11);

    // Keep both physical files inside this disposable directory. Renaming the
    // open source also exercises Windows delete-sharing behavior of the reader.
    let retired = root.path().join("retired-state.sqlite");
    fs::rename(&database, &retired).expect("rename the open source within the temp directory");
    drop(seed_database(&database, 22, false));

    let (new_token, new_value) = expect_updated(
        read_snapshot(&database, Some(&old_token), read_value)
            .expect("read replacement source instead of the cached old handle"),
    );
    assert_eq!(new_value, 22);
    assert_ne!(new_token, old_token, "replacement must receive a new token");
}

#[test]
fn concurrent_wal_commit_keeps_current_read_consistent_and_next_read_current() {
    let (_root, database) = temp_database("concurrent-state.sqlite");
    drop(seed_database(&database, 1, true));

    let writer_path = database.clone();
    let (ready_tx, ready_rx) = mpsc::channel();
    let (start_tx, start_rx) = mpsc::channel();
    let (done_tx, done_rx) = mpsc::channel();
    let writer = thread::spawn(move || -> Result<(), String> {
        let connection = Connection::open(writer_path).map_err(|error| error.to_string())?;
        connection
            .execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
            .map_err(|error| error.to_string())?;
        ready_tx
            .send(())
            .map_err(|error| format!("writer readiness channel closed: {error}"))?;
        start_rx
            .recv_timeout(Duration::from_secs(5))
            .map_err(|error| format!("writer start timed out: {error}"))?;
        let commit = connection
            .execute("UPDATE snapshot_value SET value=2", [])
            .map(|_| ())
            .map_err(|error| error.to_string());
        done_tx
            .send(commit.clone())
            .map_err(|error| format!("writer completion channel closed: {error}"))?;
        commit
    });
    ready_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("WAL writer becomes ready before the reader transaction");

    let (token, (before_commit, during_commit)) = expect_updated(
        read_snapshot(&database, None, move |reader| {
            let before = read_value(reader)?;
            start_tx
                .send(())
                .map_err(|error| format!("could not release writer: {error}"))?;
            done_rx
                .recv_timeout(Duration::from_secs(5))
                .map_err(|error| format!("writer commit timed out during read: {error}"))??;
            let during = read_value(reader)?;
            Ok((before, during))
        })
        .expect("a normal concurrent WAL commit must not make the source bad"),
    );
    assert_eq!(before_commit, 1);
    assert_eq!(
        during_commit, 1,
        "the active read transaction must retain its original SQLite snapshot"
    );

    match writer.join() {
        Ok(Ok(())) => {}
        Ok(Err(error)) => panic!("writer failed: {error}"),
        Err(_) => panic!("writer thread panicked"),
    }

    let (_, after_commit) = expect_updated(
        read_snapshot(&database, Some(&token), read_value)
            .expect("the next snapshot must observe the committed value"),
    );
    assert_eq!(after_commit, 2);
}
