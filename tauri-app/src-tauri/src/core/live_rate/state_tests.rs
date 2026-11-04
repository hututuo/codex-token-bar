use super::*;
use std::fs;

fn fixture(schema: &str) -> tempfile::TempDir {
    let root = tempfile::tempdir().unwrap();
    let connection = Connection::open(root.path().join("state_5.sqlite")).unwrap();
    connection.execute_batch(schema).unwrap();
    root
}

// The original upstream threads schema predates first_user_message, preview,
// updated_at_ms, thread_source and name. Optional columns must be independent.
#[test]
fn legacy_options_accept_each_optional_column_combination_without_writing() {
    for mask in 0..16 {
        let root = fixture(
            "CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT, rollout_path TEXT,
             updated_at INTEGER, tokens_used INTEGER, archived INTEGER);
             INSERT INTO threads VALUES('recent','Recent','sessions/recent.jsonl',200,42,0);
             INSERT INTO threads VALUES('older','Older','sessions/older.jsonl',100,8,0);
             INSERT INTO threads VALUES('archived','Archived','/archived',300,9,1);",
        );
        let path = root.path().join("state_5.sqlite");
        let connection = Connection::open(&path).unwrap();
        for (bit, column, kind) in [
            (1, "first_user_message", "TEXT"),
            (2, "preview", "TEXT"),
            (4, "updated_at_ms", "INTEGER"),
            (8, "name", "TEXT"),
        ] {
            if mask & bit != 0 {
                connection
                    .execute_batch(&format!("ALTER TABLE threads ADD COLUMN {column} {kind};"))
                    .unwrap();
            }
        }
        drop(connection);
        let before = fs::read(&path).unwrap();
        let options = read_thread_options_result(root.path(), 20)
            .unwrap_or_else(|error| panic!("optional mask {mask}: {error}"));
        assert_eq!(
            options
                .iter()
                .map(|row| row.id.as_str())
                .collect::<Vec<_>>(),
            ["recent", "older"]
        );
        assert_eq!(options[0].title, "Recent");
        assert_eq!(options[0].tokens_used, 42);
        assert!(!options[0].updated_at.is_empty());
        assert_eq!(
            fs::read(path).unwrap(),
            before,
            "mask {mask} modified the source"
        );
    }
}

#[test]
fn legacy_rollouts_sort_seconds_and_keep_subagents_with_relative_paths() {
    let root = fixture(
        "CREATE TABLE threads(id TEXT, title TEXT, rollout_path TEXT, updated_at INTEGER);
         INSERT INTO threads VALUES('older','Older','sessions/older.jsonl',100);
         INSERT INTO threads VALUES('recent','Recent','sessions/recent.jsonl',200);
         INSERT INTO threads VALUES('missing','Missing',NULL,300);",
    );
    let rows = read_recent_rollout_threads(root.path(), 1).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].id, "recent");
    assert_eq!(
        rows[0].rollout_path,
        root.path().join("sessions/recent.jsonl")
    );
    assert_eq!(rows[0].thread_source, "user");
}

#[test]
fn legacy_single_and_batch_titles_do_not_require_first_prompt() {
    let root = fixture(
        "CREATE TABLE threads(id TEXT, title TEXT); INSERT INTO threads VALUES('a','Saved title');",
    );
    assert_eq!(
        read_thread_title(root.path(), "a").unwrap().as_deref(),
        Some("Saved title")
    );
    assert_eq!(read_thread_title(root.path(), "missing").unwrap(), None);
    let titles = read_thread_titles(root.path(), &["a".into(), "missing".into()]).unwrap();
    assert_eq!(titles.len(), 1);
    assert_eq!(titles["a"], "Saved title");
}

#[test]
fn nullable_optional_fields_preserve_names_filters_and_rollout_sources() {
    let root = fixture(
        "CREATE TABLE threads(id TEXT, title TEXT, name TEXT, first_user_message TEXT,
         preview TEXT, updated_at INTEGER, updated_at_ms INTEGER, tokens_used INTEGER,
         archived INTEGER, thread_source TEXT, rollout_path TEXT);
         INSERT INTO threads VALUES('named','prompt','Explicit','prompt',NULL,200,NULL,42,NULL,NULL,'named.jsonl');
         INSERT INTO threads VALUES('prompt','prompt',NULL,'prompt',NULL,100,NULL,NULL,0,'user','prompt.jsonl');
         INSERT INTO threads VALUES('agent',NULL,NULL,NULL,NULL,300,NULL,-1,0,'subagent','agent.jsonl');
         INSERT INTO threads VALUES('archived','Hidden',NULL,NULL,NULL,400,NULL,1,1,'user','hidden.jsonl');",
    );
    let options = read_thread_options_result(root.path(), 20).unwrap();
    assert_eq!(
        options
            .iter()
            .map(|row| row.id.as_str())
            .collect::<Vec<_>>(),
        ["named", "prompt"]
    );
    assert_eq!(options[0].title, "Explicit");
    assert_eq!(options[1].tokens_used, 0);
    assert_eq!(
        read_thread_title(root.path(), "named").unwrap().as_deref(),
        Some("Explicit")
    );
    assert_eq!(read_thread_title(root.path(), "prompt").unwrap(), None);
    let titles = read_thread_titles(root.path(), &["named".into(), "prompt".into()]).unwrap();
    assert_eq!(titles.len(), 1);
    assert_eq!(titles["named"], "Explicit");
    let rollouts = read_recent_rollout_threads(root.path(), 20).unwrap();
    assert_eq!(rollouts.len(), 3);
    assert_eq!(rollouts[0].id, "agent");
    assert_eq!(rollouts[0].thread_source, "subagent");
}

#[test]
fn timestamp_projection_handles_seconds_milliseconds_and_partial_schemas() {
    for (columns, recent, older) in [
        ("updated_at INTEGER", "2000000000", "1000000000"),
        ("updated_at INTEGER", "2000000000000", "1000000000000"),
        ("updated_at_ms INTEGER", "2000000000000", "1000000000000"),
        (
            "updated_at INTEGER, updated_at_ms INTEGER",
            "1,2000000000000",
            "1000000000,NULL",
        ),
    ] {
        let root = fixture(&format!(
            "CREATE TABLE threads(id TEXT, title TEXT, rollout_path TEXT, tokens_used INTEGER, {columns});
             INSERT INTO threads VALUES('recent','Recent','recent.jsonl',1,{recent});
             INSERT INTO threads VALUES('older','Older','older.jsonl',2,{older});"
        ));
        let options = read_thread_options_result(root.path(), 20).unwrap();
        assert_eq!(options[0].id, "recent", "{columns}");
        assert!(!options[0].updated_at.is_empty());
        assert_eq!(
            read_recent_rollout_threads(root.path(), 20).unwrap()[0].id,
            "recent"
        );
    }
}

#[test]
fn malformed_or_missing_state_stays_an_error_and_is_not_created() {
    let root = tempfile::tempdir().unwrap();
    assert!(read_thread_options_result(root.path(), 20).is_err());
    assert!(!root.path().join("state_5.sqlite").exists());
    let root = fixture(
        "CREATE TABLE threads(id TEXT, title TEXT, rollout_path TEXT, tokens_used INTEGER);",
    );
    assert!(read_thread_options_result(root.path(), 20).is_err());
    assert!(read_recent_rollout_threads(root.path(), 20).is_err());
}

#[test]
fn missing_threads_table_is_an_error_but_valid_empty_legacy_tables_stay_empty() {
    let root = fixture("CREATE TABLE unrelated(id TEXT);");
    let path = root.path().join("state_5.sqlite");
    let before = fs::read(&path).unwrap();
    assert!(read_thread_options_result(root.path(), 20).is_err());
    assert!(read_thread_title(root.path(), "a").is_err());
    assert!(read_thread_titles(root.path(), &["a".into()]).is_err());
    let error = read_recent_rollout_threads(root.path(), 20).unwrap_err();
    assert!(error.to_string().contains("missing threads table"));
    assert_eq!(fs::read(&path).unwrap(), before);

    for rollout in ["", ", rollout_path TEXT"] {
        let root = fixture(&format!(
            "CREATE TABLE threads(id TEXT, title TEXT, updated_at INTEGER, tokens_used INTEGER{rollout});"
        ));
        let path = root.path().join("state_5.sqlite");
        let before = fs::read(&path).unwrap();
        assert!(read_thread_options_result(root.path(), 20)
            .unwrap()
            .is_empty());
        assert!(read_recent_rollout_threads(root.path(), 20)
            .unwrap()
            .is_empty());
        assert!(read_thread_title(root.path(), "a").unwrap().is_none());
        assert!(read_thread_titles(root.path(), &["a".into()])
            .unwrap()
            .is_empty());
        assert_eq!(fs::read(&path).unwrap(), before);
    }
}
