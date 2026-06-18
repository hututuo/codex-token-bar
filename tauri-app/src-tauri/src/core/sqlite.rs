use rusqlite::{Connection, OpenFlags, Result as SqlResult};
use std::path::Path;
use std::time::Duration;

pub fn open_read_only(path: &Path, busy_timeout: Duration) -> SqlResult<Connection> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )?;
    connection.busy_timeout(busy_timeout)?;
    Ok(connection)
}

pub fn open_read_write(path: &Path, busy_timeout: Duration) -> SqlResult<Connection> {
    let connection = Connection::open(path)?;
    connection.busy_timeout(busy_timeout)?;
    Ok(connection)
}

pub fn open_wal(path: &Path, busy_timeout: Duration) -> SqlResult<Connection> {
    let connection = open_read_write(path, busy_timeout)?;
    connection.pragma_update(None, "journal_mode", "WAL")?;
    Ok(connection)
}

pub fn checkpoint_wal_full(connection: &Connection) {
    let _ = connection.execute("PRAGMA wal_checkpoint(FULL);", []);
}
