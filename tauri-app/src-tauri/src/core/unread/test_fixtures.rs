use serde_json::json;
use std::fs;
use std::path::Path;

/// Write the smallest complete native unread snapshot used by tests that
/// exercise a pinned Codex Home.  The unread atom is only authoritative after
/// the initialized sidebar snapshot supplies the complete visible set.
pub(crate) fn write_initialized_sidebar_state(root: &Path, unread_ids: &[&str]) {
    fs::write(
        root.join(".codex-global-state.json"),
        serde_json::to_vec(&json!({
            "electron-persisted-atom-state": {
                "unread-thread-ids-by-host-v1": {
                    "localhost": unread_ids,
                },
                "flat-project-sidebar-preferences-v1": {
                    "initialized": true,
                    "mode": "project",
                },
            },
            "sidebar-project-thread-orders": {
                "local-project": {
                    "sortKey": "updated_at",
                    "threadIds": unread_ids,
                },
            },
            "pinned-thread-ids": [],
            "projectless-thread-ids": [],
        }))
        .unwrap(),
    )
    .unwrap();
}
