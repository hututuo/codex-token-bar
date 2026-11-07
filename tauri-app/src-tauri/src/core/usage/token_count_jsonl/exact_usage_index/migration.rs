//! Proof-only schema11 migration support.

mod proof;

pub(super) use proof::{
    schema11_legacy_generation_state, schema11_lineage, schema11_migration_facts,
    Schema11MigrationFacts,
};
