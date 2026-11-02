import Foundation

/// The current parser layout. Legacy readers retain their own column projection.
enum ExactStageSchema {
    static let tables = ["manifest", "fingerprints", "events", "chunks"]
    static let columns = ["manifest": 27, "fingerprints": 1, "events": 13, "chunks": 3]
    static let ordering = ["manifest": "complete", "fingerprints": "value", "events": "source_offset", "chunks": "chunk_index"]
    static let sql = """
                CREATE TABLE manifest (
                    complete INTEGER PRIMARY KEY CHECK(complete IN (0, 1)),
                    manifest_schema_version INTEGER NOT NULL,
                    canonical_path TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    migration_revision TEXT NOT NULL,
                    parser_revision TEXT NOT NULL,
                    artifact_id TEXT NOT NULL,
                    actual_bytes INTEGER NOT NULL,
                    integrity TEXT NOT NULL,
                    prefix_sha256 TEXT NOT NULL,
                    size_bytes INTEGER NOT NULL,
                    modified_at REAL NOT NULL,
                    content_probe TEXT NOT NULL,
                    event_count INTEGER NOT NULL,
                    resume_offset INTEGER NOT NULL,
                    previous_total_tokens INTEGER,
                    fork_replay_started_at REAL,
                    is_skipping_fork_replay INTEGER NOT NULL,
                    is_explicit_subagent_fork INTEGER NOT NULL,
                    last_skipped_fork_replay_token_at REAL,
                    current_user_prompt_offset INTEGER,
                    assistant_start_offset INTEGER,
                    current_model TEXT,
                    fingerprint_count INTEGER NOT NULL,
                    chunk_count INTEGER NOT NULL,
                    accounting_state TEXT,
                    physical_stamp TEXT
                );

                CREATE TABLE fingerprints (
                    value BLOB PRIMARY KEY
                ) WITHOUT ROWID;

                CREATE TABLE events (
                    source_offset INTEGER PRIMARY KEY,
                    timestamp REAL NOT NULL,
                    tokens INTEGER NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    reasoning_output_tokens INTEGER NOT NULL,
                    model TEXT,
                    user_prompt_offset INTEGER,
                    assistant_start_offset INTEGER,
                    accounting_kind INTEGER NOT NULL DEFAULT 0,
                    reported_total_tokens INTEGER,
                    usage_fingerprint BLOB
                ) WITHOUT ROWID;

                CREATE TABLE chunks (
                    chunk_index INTEGER PRIMARY KEY,
                    byte_count INTEGER NOT NULL,
                    sha256 TEXT NOT NULL
                ) WITHOUT ROWID;
    """
}
