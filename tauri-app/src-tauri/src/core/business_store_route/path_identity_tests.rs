use super::*;
use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "tokenbar-exact-path-{}-{}-{}",
            std::process::id(),
            now_unix(),
            SEQUENCE.fetch_add(1, Ordering::SeqCst)
        ));
        fs::create_dir_all(&root).unwrap();
        Self(root)
    }
    fn roots(&self) -> (PathBuf, PathBuf) {
        let physical = self.0.join("physical");
        fs::create_dir_all(&physical).unwrap();
        #[cfg(unix)]
        {
            let configured = self.0.join("configured");
            std::os::unix::fs::symlink(&physical, &configured).unwrap();
            (physical, configured)
        }
        #[cfg(not(unix))]
        {
            (physical.clone(), physical)
        }
    }
    fn container(&self) -> PathBuf {
        let path = self.0.join("codex-ledger.sqlite");
        drop(Container::open(&path).unwrap());
        fs::write(
            initialized_marker_path(&path),
            b"tokenbar-codex-ledger-v1\n",
        )
        .unwrap();
        path
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn seed(container: &Path, store: &StoreSpec, tokens: i64) -> StoreProof {
    let a = Container::open_existing(container).unwrap();
    a.register(store).unwrap();
    let connection = a.into_store_connection(store).unwrap();
    connection.execute_batch("CREATE TABLE history(id INTEGER PRIMARY KEY AUTOINCREMENT,tokens INTEGER NOT NULL,note BLOB); \
        INSERT INTO history(id,tokens,note) VALUES(1,0,X'0001ff');").unwrap();
    connection
        .execute("UPDATE history SET tokens=?1 WHERE id=1", [tokens])
        .unwrap();
    drop(connection);
    Container::open_existing(container)
        .unwrap()
        .proof(store)
        .unwrap()
}

fn raw_spec(path: &Path) -> StoreSpec {
    let source = super::super::source_identity("exact", path).unwrap();
    plain_spec(source).unwrap()
}

fn catalog_version(witness: &Connection) -> i64 {
    witness
        .query_row("PRAGMA data_version", [], |row| row.get(0))
        .unwrap()
}

#[test]
fn new_exact_addresses_do_not_change_when_two_missing_parents_materialize_or_disappear() {
    let f = Fixture::new();
    let (_, configured) = f.roots();
    let index = configured.join("missing/cache/index.sqlite3");
    let primary = index
        .with_file_name("index.sqlite3.staging")
        .join(format!("{}.sqlite3", "1".repeat(64)));
    let candidate = primary.with_file_name(format!(
        "{}.candidate-v2-{}.sqlite3",
        "1".repeat(64),
        "2".repeat(64)
    ));
    let paths = [&index, &primary, &candidate];
    let before = paths
        .iter()
        .map(|path| exact_store_spec(path).unwrap())
        .collect::<Vec<_>>();
    fs::create_dir_all(primary.parent().unwrap()).unwrap();
    for path in paths {
        fs::write(path, b"isolated path spelling fixture").unwrap();
    }
    assert_eq!(
        before,
        paths
            .iter()
            .map(|path| exact_store_spec(path).unwrap())
            .collect::<Vec<_>>()
    );
    fs::remove_dir_all(configured.join("missing")).unwrap();
    assert_eq!(
        before,
        paths
            .iter()
            .map(|path| exact_store_spec(path).unwrap())
            .collect::<Vec<_>>()
    );
}

#[test]
fn old_a_only_primary_owner_is_read_without_registration_after_directory_creation() {
    let f = Fixture::new();
    let (_, configured) = f.roots();
    let a = f.container();
    let stage = configured
        .join("missing/cache/index.sqlite3.staging")
        .join(format!("{}.sqlite3", "1".repeat(64)));
    let old = raw_spec(&stage);
    let original = seed(&a, &old, 465);
    fs::create_dir_all(stage.parent().unwrap()).unwrap();
    let preferred = exact_store_spec(&stage).unwrap();
    #[cfg(any(unix, windows))]
    assert_ne!(
        old.id, preferred.id,
        "fixture must form the released raw-path owner before parents exist"
    );
    assert!(!stage.exists(), "the only data must be in A");
    let witness = Connection::open(&a).unwrap();
    let before = catalog_version(&witness);
    #[cfg(windows)]
    {
        let canonical = fs::canonicalize(stage.parent().unwrap())
            .unwrap()
            .join(stage.file_name().unwrap());
        let reader = open_exact_registered_read_only_at(&a, &canonical, Duration::from_secs(1))
            .unwrap()
            .unwrap();
        assert_eq!(
            reader.bound_store_spec().unwrap(),
            old,
            "verbatim callers must retain the released ordinary-path owner"
        );
    }
    for _ in 0..2 {
        let connection = open_exact_registered_read_only_at(&a, &stage, Duration::from_secs(1))
            .unwrap()
            .unwrap();
        assert_eq!(connection.bound_store_spec().unwrap(), old);
        assert_eq!(
            connection
                .query_row("SELECT tokens FROM history", [], |row| row.get::<_, i64>(0))
                .unwrap(),
            465
        );
        assert!(
            connection.execute("DELETE FROM history", []).is_err(),
            "read-only recovery must not acquire a writer"
        );
        drop(connection);
        fs::remove_dir_all(configured.join("missing")).ok();
    }
    assert_eq!(catalog_version(&witness), before);
    let container = Container::open_read_only_existing(&a, Duration::from_secs(1)).unwrap();
    assert_eq!(container.proof(&old).unwrap(), original);
    assert_eq!(
        container
            .connection()
            .query_row("SELECT COUNT(*) FROM tb_stores", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert!(!container.is_registered(&preferred).unwrap());
}

#[test]
fn old_candidate_family_is_reused_without_changing_its_catalog_identity() {
    let f = Fixture::new();
    let (_, configured) = f.roots();
    let a = f.container();
    let index = configured.join("missing/cache/index.sqlite3");
    let name = format!("{}.candidate-v2-{}.sqlite3", "3".repeat(64), "4".repeat(64));
    let stage = index.with_file_name("index.sqlite3.staging").join(&name);
    let old_family = super::super::source_identity("exact", &index).unwrap();
    let old = candidate_spec(&old_family, &name).unwrap();
    let original = seed(&a, &old, 175);
    fs::create_dir_all(stage.parent().unwrap()).unwrap();
    let connection = open_exact_registered_read_only_at(&a, &stage, Duration::from_secs(1))
        .unwrap()
        .unwrap();
    assert_eq!(connection.bound_store_spec().unwrap(), old);
    assert_eq!(
        connection
            .query_row("SELECT tokens FROM history", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        175
    );
    drop(connection);
    assert_eq!(
        Container::open_existing(&a).unwrap().proof(&old).unwrap(),
        original
    );
}

#[test]
fn writer_resumes_the_old_owner_instead_of_registering_a_new_empty_copy() {
    let f = Fixture::new();
    let (_, configured) = f.roots();
    let a = f.container();
    let path = configured.join("missing/cache/index.sqlite3");
    let old = raw_spec(&path);
    seed(&a, &old, 465);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let connection = open_exact_store_at(&a, &path, &[], false).unwrap();
    assert_eq!(connection.bound_store_spec().unwrap(), old);
    connection
        .execute("INSERT INTO history(tokens,note) VALUES(11,X'0102')", [])
        .unwrap();
    drop(connection);
    let a = Container::open_existing(&a).unwrap();
    assert_eq!(
        a.connection()
            .query_row("SELECT COUNT(*) FROM tb_stores", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(a.proof(&old).unwrap().table_counts["history"], 2);
    assert!(!path.exists());
}

#[test]
fn unknown_read_only_address_creates_neither_namespace_nor_directories() {
    let f = Fixture::new();
    let (_, configured) = f.roots();
    let a = f.container();
    let path = configured.join("missing/cache/unknown.sqlite3");
    let witness = Connection::open(&a).unwrap();
    let before = catalog_version(&witness);
    assert!(
        open_exact_registered_read_only_at(&a, &path, Duration::from_secs(1))
            .unwrap()
            .is_none()
    );
    assert!(!configured.join("missing").exists());
    assert_eq!(catalog_version(&witness), before);
    assert_eq!(
        witness
            .query_row("SELECT COUNT(*) FROM tb_stores", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
}

#[test]
fn two_different_legacy_owners_are_not_silently_selected_or_overwritten() {
    let f = Fixture::new();
    let (_, configured) = f.roots();
    let a = f.container();
    let path = configured.join("missing/cache/index.sqlite3");
    let old = raw_spec(&path);
    let original = seed(&a, &old, 120);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let current = exact_store_spec(&path).unwrap();
    let newer = seed(&a, &current, 175);
    let error = open_exact_registered_read_only_at(&a, &path, Duration::from_secs(1))
        .err()
        .unwrap();
    assert!(error.contains("多个历史分区"));
    assert!(open_exact_store_at(&a, &path, &[], false).is_err());
    let a = Container::open_existing(&a).unwrap();
    assert_eq!(a.proof(&old).unwrap(), original);
    assert_eq!(a.proof(&current).unwrap(), newer);
}

#[test]
fn empty_new_spelling_reservation_cannot_hide_the_only_historical_owner() {
    let f = Fixture::new();
    let (_, configured) = f.roots();
    let a = f.container();
    let path = configured.join("missing/cache/index.sqlite3");
    let old = raw_spec(&path);
    seed(&a, &old, 465);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let current = exact_store_spec(&path).unwrap();
    Container::open_existing(&a)
        .unwrap()
        .register(&current)
        .unwrap();
    let reader = open_exact_registered_read_only_at(&a, &path, Duration::from_secs(1))
        .unwrap()
        .unwrap();
    assert_eq!(reader.bound_store_spec().unwrap(), old);
    drop(reader);
    let writer = open_exact_store_at(&a, &path, &[], false).unwrap();
    assert_eq!(writer.bound_store_spec().unwrap(), old);
    writer
        .execute("INSERT INTO history(tokens,note) VALUES(11,X'01')", [])
        .unwrap();
    drop(writer);
    let a = Container::open_existing(&a).unwrap();
    assert_eq!(a.proof(&old).unwrap().table_counts["history"], 2);
    assert!(
        a.is_registered(&current).unwrap(),
        "even empty historical reservations remain intact"
    );
    assert!(!a.has_imported_objects(&current).unwrap());
}

#[test]
fn identical_aliases_support_reading_but_need_convergence_before_either_writer_advances() {
    let f = Fixture::new();
    let (_, configured) = f.roots();
    let a = f.container();
    let path = configured.join("missing/cache/index.sqlite3");
    let old = raw_spec(&path);
    let original = seed(&a, &old, 465);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let current = exact_store_spec(&path).unwrap();
    assert_eq!(seed(&a, &current, 465), original);
    let connection = open_exact_registered_read_only_at(&a, &path, Duration::from_secs(1))
        .unwrap()
        .unwrap();
    assert_eq!(connection.bound_store_spec().unwrap(), current);
    drop(connection);
    assert!(open_exact_store_at(&a, &path, &[], false).is_err());
    let a = Container::open_existing(&a).unwrap();
    assert_eq!(a.proof(&old).unwrap(), original);
    assert_eq!(a.proof(&current).unwrap(), original);
}

#[test]
fn catalog_owner_mismatch_does_not_fall_through_to_a_new_namespace() {
    let f = Fixture::new();
    let (_, configured) = f.roots();
    let a = f.container();
    let path = configured.join("missing/cache/index.sqlite3");
    let old = raw_spec(&path);
    seed(&a, &old, 465);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let raw = Connection::open(&a).unwrap();
    raw.execute(
        "UPDATE tb_stores SET logical_path='exact/unrelated-owner' WHERE store_id=?1",
        [&old.id],
    )
    .unwrap();
    let error = ExactAddress::new(&path)
        .unwrap()
        .resolve(&raw, false)
        .unwrap_err();
    assert!(error.contains("身份不一致"));
    assert_eq!(
        raw.query_row("SELECT COUNT(*) FROM tb_stores", [], |row| row
            .get::<_, i64>(0))
            .unwrap(),
        1
    );
}

#[test]
fn opened_connection_keeps_its_full_owner_when_catalog_logical_path_changes() {
    let f = Fixture::new();
    let (_, configured) = f.roots();
    let a = f.container();
    let path = configured.join("missing/cache/index.sqlite3");
    let old = raw_spec(&path);
    let proof = seed(&a, &old, 465);
    let reader = open_exact_registered_read_only_at(&a, &path, Duration::from_secs(1))
        .unwrap()
        .unwrap();
    assert_eq!(reader.bound_store_spec().unwrap(), old);
    let raw = Connection::open(&a).unwrap();
    raw.execute(
        "UPDATE tb_stores SET logical_path='exact/changed-after-open' WHERE store_id=?1",
        [&old.id],
    )
    .unwrap();
    assert!(
        reader.bound_store_spec().is_err(),
        "an already opened handle must not adopt a changed owner"
    );
    raw.execute(
        "UPDATE tb_stores SET logical_path=?1 WHERE store_id=?2",
        rusqlite::params![old.logical_path, old.id],
    )
    .unwrap();
    assert_eq!(reader.bound_store_spec().unwrap(), old);
    drop(reader);
    drop(raw);
    assert_eq!(
        Container::open_existing(&a).unwrap().proof(&old).unwrap(),
        proof
    );
}

#[cfg(unix)]
#[test]
fn database_leaf_symlink_cannot_redirect_an_existing_owner() {
    let f = Fixture::new();
    let (_, configured) = f.roots();
    let path = configured.join("missing/cache/index.sqlite3");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let other = f.0.join("other.sqlite3");
    fs::write(&other, b"other").unwrap();
    std::os::unix::fs::symlink(&other, &path).unwrap();
    assert!(ExactAddress::new(&path)
        .unwrap_err()
        .contains("符号链接数据库文件"));
    assert_eq!(fs::read(other).unwrap(), b"other");
}
