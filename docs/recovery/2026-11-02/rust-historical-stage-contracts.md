# Historical Rust private-stage schema contracts

## Evidence and scope

The local release tags `v0.9.1` through `v0.9.11` were read directly from Git,
including their exact commit and source-blob IDs. All 111 revisions of
`exact_usage_index.rs` reachable from `v0.9.11` were also inspected. Eleven
distinct producer DDL strings were found. Their SQL was executed only in an
in-memory SQLite database to record `table_xinfo`, index metadata, foreign keys,
and object definitions. No old Rust executable or native recovery flow was
executed by this audit.

The complete, ordered contracts are in
[rust-historical-stage-contracts.json](rust-historical-stage-contracts.json).
Every column records `cid`, name, declared type, NOT NULL, default, primary-key
position, and hidden/generated status. Every layout includes the original DDL,
producer commit IDs and subjects, parser/manifest constants, and release tags.
The SQL-text SHA-256 in that file is an evidence identifier, **not** the Rust
`StoreProof.schema_digest`.

Reproduce the extraction with:

```sh
python scripts/audit_rust_stage_contracts.py
```

## Released layouts

Only two private-stage layouts occur in the eleven release tags:

| Tags | Producer layout | Manifest | Events | Manifest version |
|---|---|---:|---:|---|
| v0.9.1 | `5016724afa9e…` | 29 columns | 12 columns | Version field absent; current reader treats it as 1 |
| v0.9.2–v0.9.11 | `6ddf943986dd…` | 35 columns | 16 columns | Constant and writer use 3 |

The v0.9.2–v0.9.11 DDL is byte-identical after replacing the later Rust
`{create_table}` placeholder with `TABLE`. A representation through TEMP before
materialization changes the write mechanism, not the durable column contract.
Parser revisions change across those tags without changing this DDL. Schema
recognition must not replace parser-revision and manifest-content validation.

All producer layouts contain exactly the four user tables `manifest`, `events`,
`fingerprints`, and `chunks`, all `WITHOUT ROWID`. There are no producer-created
user indexes, views, triggers or foreign keys. Internal primary-key indexes are
recorded in the JSON; they must not be confused with additional user objects.

All columns have no default except the later
`accounting_kind INTEGER NOT NULL DEFAULT 0`. Primary-key columns report
`notnull=1` under `table_xinfo`, because the tables are WITHOUT ROWID, even where
the original SQL does not explicitly spell NOT NULL. No hidden/generated
column occurs. `reasoning_output_tokens` in the stage is INTEGER NOT NULL; the
main index's optional-column compatibility must not be copied into this schema.

The common tables are:

```sql
CREATE TABLE fingerprints (fingerprint BLOB PRIMARY KEY) WITHOUT ROWID;
CREATE TABLE chunks (
    chunk_index INTEGER PRIMARY KEY,
    byte_count INTEGER NOT NULL,
    sha256 BLOB NOT NULL
) WITHOUT ROWID;
```

### v0.9.1 manifest

The ordered fields are:

```text
complete, path, session_id, migration_revision, parser_revision,
target_building_generation, artifact_id, actual_bytes, integrity, size,
modified_ns, device_id, file_id, changed_ns, prefix_sha256, resume_offset,
previous_total_tokens, fork_replay_started_ns, fork_replay_active,
is_explicit_subagent_fork, last_skipped_fork_replay_token_ns, current_model,
current_user_prompt_start, current_user_prompt_end, assistant_response_start,
assistant_response_end, event_count, fingerprint_count, chunk_count
```

`complete` is INTEGER PRIMARY KEY with `CHECK(complete IN (0, 1))`.
`prefix_sha256` is BLOB NOT NULL. The nullable fields are
`previous_total_tokens` (INTEGER), `fork_replay_started_ns` (TEXT),
`last_skipped_fork_replay_token_ns` (TEXT), `current_model` (TEXT), and the four
prompt/response offsets (INTEGER). Other numeric fields are INTEGER NOT NULL;
the remaining fields are TEXT NOT NULL. In particular the three physical
identity fields are **middle columns with no defaults**, not columns appended
to the end of a modern manifest.

### Modern manifest

The ordered 35 fields are:

```text
complete, manifest_schema_version, staging_mode, source_id, base_generation,
base_resume_offset, base_prefix_sha256, fingerprint_codec_version, path,
session_id, migration_revision, parser_revision, target_building_generation,
artifact_id, actual_bytes, integrity, size, modified_ns, prefix_sha256,
resume_offset, previous_total_tokens, fork_replay_started_ns, fork_replay_active,
is_explicit_subagent_fork, last_skipped_fork_replay_token_ns, current_model,
current_user_prompt_start, current_user_prompt_end, assistant_response_start,
assistant_response_end, event_count, fingerprint_count, chunk_count,
accounting_state, physical_stamp
```

`complete` retains the primary key and CHECK. `staging_mode` is TEXT NOT NULL
with `CHECK(staging_mode IN ('full', 'delta'))`. Nullable additions are
`base_resume_offset INTEGER`, `base_prefix_sha256 BLOB`,
`accounting_state TEXT`, and `physical_stamp TEXT`. Other field contracts follow
the v0.9.1 definitions, with the removed physical fields absent. New version,
source/base generation and codec columns are INTEGER NOT NULL. No manifest
column has a default.

### Events

The first 12 columns, in exact order, are:

```text
ordinal, timestamp, tokens, input_tokens, cached_input_tokens, output_tokens,
reasoning_output_tokens, model, user_prompt_start, user_prompt_end,
assistant_response_start, assistant_response_end
```

`ordinal` is INTEGER PRIMARY KEY. The remaining numeric fields before `model`
are INTEGER NOT NULL. `model` is nullable TEXT; the four following offsets are
nullable INTEGER. The modern layout appends exactly:

```sql
accounting_kind INTEGER NOT NULL DEFAULT 0,
reported_total_tokens INTEGER,
token_source_offset INTEGER,
usage_fingerprint BLOB
```

## Real intermediate producer layouts

These are actual ancestor producer definitions, not arbitrary combinations of
optional columns. They can explain retained development-build artifacts even
though no requested release tag has the intermediate shape.

| First producer | Manifest fields | Events fields | Exact change |
|---|---:|---:|---|
| `acc82f523a` | 29 | 12 | Released v0.9.1 form above |
| `4efd97f7d5` | 27 | 12 | Version 2: add `manifest_schema_version` immediately after `complete`; remove `device_id,file_id,changed_ns` |
| `5ce004190e` | 33 | 12 | Version 3: insert `staging_mode,source_id,base_generation,base_resume_offset,base_prefix_sha256,fingerprint_codec_version` after version |
| `9c0f098b65` | 34 | 15 | Append manifest `accounting_state`; append events `accounting_kind,reported_total_tokens,token_source_offset` together |
| `2069d6d0d6` | 34 | 16 | Append events `usage_fingerprint` |
| `42894d2cda` | 35 | 16 | Append manifest `physical_stamp`; released v0.9.2–v0.9.11 shape |

The earlier five DDL shapes are also recorded in the JSON: M21/E10, M22/E11,
M23/E11, M24/E11 and M24/E12. They predate the complete artifact/target-generation
manifest contract. Recording a known old shape is not sufficient to authorize
its direct import under the current pipeline. Preserve those artifacts and
their published history; a separate proven rebuild or recovery route is needed
if the required identity evidence is absent.

The producer's schema transition is creation of a new private stage under its
contract. The audit found no production migration that mutates an existing
private manifest by appending a subset of these optional fields. Do not create
a Cartesian product such as physical_stamp without accounting_state, or
usage_fingerprint without the accounting trio.

## Fixture distinctions from independent review

`exact_index_reuses_v091_staging_manifest_while_ignoring_physical_fields` is a
manually shaped unit fixture. It builds a current stage, appends
`device_id TEXT NOT NULL DEFAULT 'legacy-device'`,
`file_id TEXT NOT NULL DEFAULT 'legacy-file'`, and
`changed_ns TEXT NOT NULL DEFAULT '0'`, then drops the version column. Its modern
base/codec/accounting fields remain. This is **not** the v0.9.1 producer schema
and must not enlarge a production legacy-seal allowlist merely to keep the test
green. Replace that fixture's construction with actual historical DDL when
testing historical schema recognition.

`business_store_fixture::seed_stage` creates an empty, intentionally incomplete
ROWID four-table fixture. Its manifest has only version/parser/complete/mode/
accounting columns, and its other tables contain only their key. It exercises
`restartable_private_stage` preservation and rebuild, not valid seal promotion
or direct historical import. The empty-current-stage test has a legitimate
current structure but no complete manifest; it is likewise not an imported
complete artifact.

The restart, bounded-stage, runtime-recovery and source-count fixtures that call
the current builder all inherit the current four-table contract. Tests that add
`release_expected` or other audit tables add them to main indexes, not private
stages. Unknown parser/version mutation fixtures are negative tests and do not
establish another accepted structure.

## Narrow legacy-seal recognition

1. Select one exact known producer layout. Compare ordered columns including
   declared type, NOT NULL, default, primary-key position and hidden status.
   Compare table flags, CHECK constraints, collations, foreign keys and indexes;
   reject unexpected user objects. Canonicalizing each known DDL in an isolated
   in-memory reference database and comparing the complete normalized schema
   proof is preferable to substring checks.
2. Require the manifest version's value and parser/migration contract to agree
   with that layout. All existing artifact, source/base generation, original
   raw-prefix, codec, checkpoint, count and completeness checks still apply.
3. For an old seal without a schema witness, compare the actual row proof and
   footprint to the already saved seal in the same read transaction. An exact
   known schema is an additional prerequisite; it is not permission to reseal
   rows that no longer match. Unknown schemas remain preserved and blocked.
4. Publish the versioned complete seal only in a write transaction that repeats
   the same observed owner, legacy seal, complete schema/row proof and footprint
   comparison. Never compute a schema hash from an unknown current schema and
   label it historical evidence. Do not update an existing mismatched witness.
5. Bind the proof retained by the caller to final import under its write lock.
   A later valid-looking replacement seal must not substitute for the earlier
   accepted artifact. The schema digest is part of this identity, including the
   validation-to-import window.

This rejects a three-rename input/output column exchange because the ordered
column identities and full schema change even if row values, rows_digest and
footprint do not. Recognition of a legacy layout provides a path to validating
it; it does not by itself assert successful native import. Native positive cases
must instantiate real producer DDL, and negative cases must retain original
stages, raw files, seal evidence and the last published ledger.

An additional in-memory SQLite check performed the three renames against every
one of the eleven extracted producer DDLs. All remained `quick_check=ok`, and
none of the resulting ordered event-column contracts matched any known layout.
This validates the proposed structural discriminator, not the Rust acceptance
or publication implementation.
